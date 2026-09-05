macro_rules! eprintln {
    ($($arg:tt)*) => {{
        wloc_rs::logging::write(format_args!($($arg)*));
    }};
}

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use socket2::{Domain, Protocol, Socket, Type};
use wloc_rs::ca::{default_profile_path, write_mobileconfig, CaBundle};
use wloc_rs::config::Config;
use wloc_rs::proxy::Proxy;
use wloc_rs::resolver;
use wloc_rs::status::Status;

const TCP_CONNECTION_LIMIT_MIN: usize = 64;
const TCP_CONNECTION_LIMIT_MAX: usize = 1024;
const TCP_CONNECTION_MEMORY_KIB: usize = 256;
const TCP_FD_RESERVE: usize = 384;
const TOKIO_WORKER_STACK_SIZE: usize = 1024 * 1024;

fn total_memory_kib() -> Option<usize> {
    let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
    meminfo.lines().find_map(|line| {
        line.strip_prefix("MemTotal:")?
            .split_whitespace()
            .next()?
            .parse::<usize>()
            .ok()
    })
}

fn nofile_soft_limit() -> Option<usize> {
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0
        || limit.rlim_cur == libc::RLIM_INFINITY
    {
        return None;
    }
    usize::try_from(limit.rlim_cur).ok()
}

fn tcp_connection_limit() -> usize {
    let memory_limit = total_memory_kib()
        .map(|memory_kib| (memory_kib / 4) / TCP_CONNECTION_MEMORY_KIB)
        .unwrap_or(256)
        .clamp(TCP_CONNECTION_LIMIT_MIN, TCP_CONNECTION_LIMIT_MAX);
    let fd_limit = nofile_soft_limit()
        .map(|limit| limit.saturating_sub(TCP_FD_RESERVE) / 2)
        .unwrap_or(TCP_CONNECTION_LIMIT_MAX)
        .max(32);
    memory_limit.min(fd_limit).max(32)
}

fn tcp_listen_backlog(connection_limit: usize) -> i32 {
    connection_limit.saturating_mul(2).clamp(128, 1024) as i32
}

fn run_rules(helper: &Path, action: &str, selectors: &[String]) -> Result<(), String> {
    let mut command = std::process::Command::new(helper);
    command.arg(action);
    for selector in selectors {
        command.arg(selector);
    }
    command.stdout(std::process::Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|e| format!("rules helper: {}", e.kind()))?;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|e| format!("rules helper: {}", e.kind()))?
        {
            return if status.success() {
                Ok(())
            } else {
                Err(format!("rules helper {action} failed"))
            };
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("rules helper {action} timed out"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn reconcile_rules(helper: &Path, port: u16, targets: &[IpAddr]) -> Result<(), String> {
    let mut selectors = Vec::with_capacity(targets.len() + 1);
    selectors.push(port.to_string());
    selectors.extend(targets.iter().map(ToString::to_string));
    run_rules(helper, "reconcile", &selectors)
}

async fn reconcile_rules_async(
    helper: PathBuf,
    port: u16,
    targets: Vec<IpAddr>,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || reconcile_rules(&helper, port, &targets))
        .await
        .map_err(|error| format!("rules task failed: {error}"))?
}

async fn bootstrap_rules_async(helper: PathBuf, port: u16) -> Result<(), String> {
    tokio::task::spawn_blocking(move || run_rules(&helper, "bootstrap", &[port.to_string()]))
        .await
        .map_err(|error| format!("rules task failed: {error}"))?
}

async fn cleanup_rules_async(helper: PathBuf) -> Result<(), String> {
    tokio::task::spawn_blocking(move || run_rules(&helper, "cleanup", &[]))
        .await
        .map_err(|error| format!("cleanup rules task failed: {error}"))?
}

fn record_startup_error(error: &str) {
    if let Some(path) = std::env::var_os("WLOC_START_ERROR_PATH") {
        let _ = std::fs::write(path, error);
    }
}

fn listener_v4(port: u16, backlog: i32) -> std::io::Result<tokio::net::TcpListener> {
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_address(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v4(true)?;
    socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
    socket.listen(backlog)?;
    socket.set_nonblocking(true)?;
    tokio::net::TcpListener::from_std(socket.into())
}

fn listener_v6(port: u16, backlog: i32) -> std::io::Result<tokio::net::TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_address(true)?;
    socket.set_only_v6(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v6(true)?;
    socket.bind(&SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0).into())?;
    socket.listen(backlog)?;
    socket.set_nonblocking(true)?;
    tokio::net::TcpListener::from_std(socket.into())
}

fn write_ca_info(dir: &Path, fingerprint: &str) -> std::io::Result<()> {
    let value = serde_json::json!({ "fingerprint_sha256": fingerprint, "profile_url": "/wloc-ca.mobileconfig" });
    let path = dir.join("ca.info.json");
    let data = serde_json::to_vec_pretty(&value)?;
    if std::fs::read(&path).ok().as_deref() == Some(data.as_slice()) {
        return Ok(());
    }
    let temporary = dir.join(format!("ca.info.tmp.{}", std::process::id()));
    std::fs::write(&temporary, data)?;
    std::fs::rename(temporary, path)
}

fn main() {
    if let Err(error) = real_main() {
        let error = error.to_string();
        record_startup_error(&error);
        eprintln!("wlocd: fatal category=startup error={error}");
        std::process::exit(1);
    }
}

fn real_main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = Config::from_args().map_err(|e| format!("configuration: {e}"))?;
    let (ca, generated) = CaBundle::load_or_generate(&config.state_dir)?;
    let ca = Arc::new(ca);
    let fingerprint = ca.fingerprint();
    write_ca_info(&config.state_dir, &fingerprint)?;
    let profile = std::env::var_os("WLOC_PROFILE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(default_profile_path);
    write_mobileconfig(&ca, &profile)?;

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let versions = [&rustls::version::TLS13, &rustls::version::TLS12];
    let mut server = rustls::ServerConfig::builder_with_provider(Arc::clone(&provider))
        .with_protocol_versions(&versions)?
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(ca.resolver(config.domains.clone())?));
    server.alpn_protocols = vec![b"h2".to_vec()];
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut client = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&versions)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    client.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    let tcp_connection_limit = tcp_connection_limit();
    let tcp_listen_backlog = tcp_listen_backlog(tcp_connection_limit);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .max_blocking_threads(2)
        .thread_stack_size(TOKIO_WORKER_STACK_SIZE)
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let transparent_tcp_listener_v4 = listener_v4(config.listen_port, tcp_listen_backlog)?;
        let transparent_tcp_listener_v6 = listener_v6(config.listen_port, tcp_listen_backlog)?;
        let status_path = std::env::var_os("WLOC_STATUS_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/run/wloc/status.json"));
        let status = Arc::new(Status::new(
            status_path,
            config.rules.len(),
            fingerprint,
        )?);
        for (priority, configured) in config.rules.iter().enumerate() {
            status.update_detail(
                "rule_configured",
                &format!(
                    "{} rule={} priority={}",
                    configured.log_context(),
                    configured.id,
                    priority + 1
                ),
                None,
                |_| {},
            );
        }
        status.update_detail(
            "listener_ready",
            &format!(
                "transparent_tcp=0.0.0.0,[::]:{} dual_stack=true tcp_limit={} backlog={}",
                config.listen_port, tcp_connection_limit, tcp_listen_backlog
            ),
            None,
            |_| {},
        );
        let bootstrap = bootstrap_rules_async(config.rules_helper.clone(), config.listen_port).await;
        let resolution = if bootstrap.is_ok() {
            resolver::resolve_location_targets(&config.rules, &config.domains).await
        } else {
            resolver::Resolution {
                addresses: Vec::new(),
                complete: false,
                errors: vec!["runtime bootstrap failed before DNS resolution".into()],
            }
        };
        for error in &resolution.errors {
            eprintln!("wlocd: location_dns=failed {error}");
        }
        let location_targets = resolution.addresses;
        let initially_armed = if let Err(error) = bootstrap {
            match cleanup_rules_async(config.rules_helper.clone()).await {
                Ok(()) => status.update_detail(
                    "lease_failed",
                    "action=rules_removed fail_open=true phase=initial_start",
                    Some(&error),
                    |c| c.armed(false),
                ),
                Err(cleanup_error) => {
                    let detail = format!(
                        "initial rules bootstrap failed: {error}; cleanup failed: {cleanup_error}"
                    );
                    status.update_detail(
                        "cleanup_failed",
                        "armed=false phase=initial_start",
                        Some(&detail),
                        |c| c.armed(false),
                    );
                }
            }
            false
        } else if location_targets.is_empty() {
            status.update_detail(
                "location_resolution_failed",
                "armed=false targets=0 action=tproxy-pass-through",
                Some("No location-service IP addresses were resolved at startup."),
                |c| c.armed(false),
            );
            false
        } else {
            match reconcile_rules_async(
                config.rules_helper.clone(),
                config.listen_port,
                location_targets.clone(),
            )
            .await
            {
                Ok(()) => {
                    status.update_detail(
                        "interception_armed",
                        &format!(
                            "rules={} hosts={} targets={} protocol=tcp mode=targeted-ip listen_port={}",
                            config.rules.len(),
                            config.domains.join(","),
                            location_targets.len(),
                            config.listen_port
                        ),
                        None,
                        |c| c.armed(true),
                    );
                    true
                }
                Err(error) => {
                    status.update_detail(
                        "lease_failed",
                        "armed=false action=tproxy-pass-through phase=target_apply",
                        Some(&error),
                        |c| c.armed(false),
                    );
                    false
                }
            }
        };
        eprintln!(
            "wlocd: daemon=ready interception={} targets={} dns_complete={} ca_generated={generated}",
            initially_armed,
            location_targets.len(),
            resolution.complete
        );

        let armed = Arc::new(AtomicBool::new(initially_armed));
        let lease_armed = Arc::clone(&armed);
        let lease_status = Arc::clone(&status);
        let lease_helper = config.rules_helper.clone();
        let lease_port = config.listen_port;
        let lease_targets = location_targets.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            interval.tick().await;
            loop {
                interval.tick().await;
                if lease_targets.is_empty() {
                    continue;
                }
                if let Err(error) = reconcile_rules_async(
                    lease_helper.clone(),
                    lease_port,
                    lease_targets.clone(),
                )
                .await
                {
                    let was_armed = lease_armed.swap(false, Ordering::SeqCst);
                    if was_armed {
                        lease_status.update_detail(
                            "lease_failed",
                            "armed=false action=keep-last-routing retry_seconds=10",
                            Some(&error),
                            |c| c.armed(false),
                        );
                        eprintln!("wlocd: interception=false error=lease_refresh retry_seconds=10");
                    }
                } else if !lease_armed.swap(true, Ordering::SeqCst) {
                    lease_status.update_detail(
                        "interception_rearmed",
                        "action=rules_rebuilt recovery=true",
                        None,
                        |c| c.armed(true),
                    );
                    eprintln!("wlocd: interception=true recovery=rules_rebuilt");
                }
            }
        });

        let proxy = Arc::new(Proxy::new(
            server,
            client,
            config.rules,
            config.listen_port,
            config.domains,
            config.debug,
            Arc::clone(&status),
        ));
        let connection_limit = Arc::new(tokio::sync::Semaphore::new(tcp_connection_limit));
        loop {
            let permit = Arc::clone(&connection_limit)
                .acquire_owned()
                .await
                .map_err(std::io::Error::other)?;
            let (stream, _) = tokio::select! {
            accepted = transparent_tcp_listener_v4.accept() => accepted?,
            accepted = transparent_tcp_listener_v6.accept() => accepted?,
        };
            let proxy = Arc::clone(&proxy);
            let status = Arc::clone(&status);
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = proxy.handle(stream).await {
                    let category = error.category();
                    let detail = error.to_string();
                    status.update_detail(
                        "connection_failed",
                        &format!("category={category}"),
                        Some(&detail),
                        |_| {},
                    );
                    eprintln!("wlocd: request=failed category={category} error={detail}");
                }
            });
        }
        #[allow(unreachable_code)]
        Ok::<(), std::io::Error>(())
    })?;
    Ok(())
}
