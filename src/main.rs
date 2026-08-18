use std::net::{Ipv4Addr, SocketAddrV4};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use socket2::{Domain, Protocol, Socket, Type};
use wloc_rs::ca::{default_profile_path, write_mobileconfig, CaBundle};
use wloc_rs::config::Config;
use wloc_rs::proxy::Proxy;
use wloc_rs::status::Status;

fn run_rules(helper: &Path, action: &str, selectors: &[String]) -> Result<(), String> {
    let mut command = std::process::Command::new(helper);
    command.arg(action);
    for selector in selectors {
        command.arg(selector);
    }
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

fn reconcile_rules(helper: &Path, port: u16, selectors: &[String]) -> Result<(), String> {
    let mut arguments = Vec::with_capacity(selectors.len() + 1);
    arguments.push(port.to_string());
    arguments.extend_from_slice(selectors);
    run_rules(helper, "reconcile", &arguments)
}

async fn reconcile_rules_async(
    helper: PathBuf,
    port: u16,
    selectors: Vec<String>,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || reconcile_rules(&helper, port, &selectors))
        .await
        .map_err(|error| format!("rules task failed: {error}"))?
}

async fn cleanup_rules_async(helper: PathBuf) {
    let _ = tokio::task::spawn_blocking(move || run_rules(&helper, "cleanup", &[])).await;
}

fn runtime_file(path: &str) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn record_startup_error(error: &str) {
    if let Some(path) = std::env::var_os("WLOC_START_ERROR_PATH") {
        let _ = std::fs::write(path, error);
    }
}

fn listener(port: u16) -> std::io::Result<tokio::net::TcpListener> {
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_address(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v4(true)?;
    socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
    socket.listen(128)?;
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
    let selectors = config
        .clients
        .iter()
        .map(|client| client.selector.label())
        .collect::<Vec<_>>();
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
        .with_cert_resolver(Arc::new(ca.resolver()?));
    server.alpn_protocols = vec![b"h2".to_vec()];
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut client = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&versions)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    client.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    let runtime = tokio::runtime::Builder::new_current_thread()
        .max_blocking_threads(2)
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let listener = listener(config.listen_port)?;
        let status_path = std::env::var_os("WLOC_STATUS_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/run/wloc/status.json"));
        let status = Arc::new(Status::new(
            status_path,
            config.clients.len(),
            config.runtime_log,
            fingerprint,
        )?);
        status.update_detail(
            "listener_ready",
            &format!("listen=0.0.0.0:{} transparent=true", config.listen_port),
            None,
            |_| {},
        );
        reconcile_rules_async(
            config.rules_helper.clone(),
            config.listen_port,
            selectors.clone(),
        )
        .await
        .map_err(std::io::Error::other)?;
        status.update_detail(
            "interception_armed",
            &format!(
                "clients={} hosts=gs-loc.apple.com,gs-loc-cn.apple.com protocol=tcp/443 priority={} detected_proxy_priorities={}",
                config.clients.len(),
                runtime_file("/var/run/wloc/prerouting.priority"),
                runtime_file("/var/run/wloc/prerouting.details"),
            ),
            None,
            |c| c.armed(true),
        );
        eprintln!("wlocd: daemon=ready interception=true ca_generated={generated}");

        let armed = Arc::new(AtomicBool::new(true));
        let lease_armed = Arc::clone(&armed);
        let lease_status = Arc::clone(&status);
        let lease_helper = config.rules_helper.clone();
        let lease_selectors = selectors.clone();
        let lease_port = config.listen_port;
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                if let Err(error) =
                    reconcile_rules_async(lease_helper.clone(), lease_port, lease_selectors.clone())
                        .await
                {
                    let was_armed = lease_armed.swap(false, Ordering::SeqCst);
                    cleanup_rules_async(lease_helper.clone()).await;
                    if was_armed {
                        lease_status.update_detail(
                            "lease_failed",
                            "action=rules_removed fail_open=true retry_seconds=10",
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
            config.clients,
            config.listen_port,
            Arc::clone(&status),
        ));
        let connection_limit = Arc::new(tokio::sync::Semaphore::new(16));
        loop {
            let permit = Arc::clone(&connection_limit)
                .acquire_owned()
                .await
                .map_err(std::io::Error::other)?;
            let (stream, _) = listener.accept().await?;
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
