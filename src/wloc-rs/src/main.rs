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

fn reconcile_rules(helper: &Path, port: u16) -> Result<(), String> {
    run_rules(helper, "reconcile", &[port.to_string()])
}

async fn reconcile_rules_async(helper: PathBuf, port: u16) -> Result<(), String> {
    tokio::task::spawn_blocking(move || reconcile_rules(&helper, port))
        .await
        .map_err(|error| format!("rules task failed: {error}"))?
}

async fn cleanup_rules_async(helper: PathBuf) -> Result<(), String> {
    tokio::task::spawn_blocking(move || run_rules(&helper, "cleanup", &[]))
        .await
        .map_err(|error| format!("cleanup rules task failed: {error}"))?
}

fn cleanup_recovery_should_report(was_armed: bool, cleanup_was_failed: &mut bool) -> bool {
    let should_report = was_armed || *cleanup_was_failed;
    *cleanup_was_failed = false;
    should_report
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

    let runtime = tokio::runtime::Builder::new_current_thread()
        .max_blocking_threads(2)
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let listener = listener(config.listen_port)?;
        let status_path = std::env::var_os("WLOC_STATUS_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/run/wloc/status.json"));
        let runtime_log_path = std::env::var_os("WLOC_RUNTIME_LOG_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/run/wloc/runtime.log"));
        let status = Arc::new(Status::new(
            status_path,
            runtime_log_path,
            config.rules.len(),
            config.runtime_log,
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
            &format!("listen=0.0.0.0:{} transparent=true", config.listen_port),
            None,
            |_| {},
        );
        let mut cleanup_was_failed = false;
        let initially_armed = match reconcile_rules_async(
            config.rules_helper.clone(),
            config.listen_port,
        )
        .await
        {
            Ok(()) => {
                status.update_detail(
                    "interception_armed",
                    &format!(
                        "rules={} hosts={} protocol=tcp/443 dynamic_sets=optional",
                        config.rules.len(),
                        config.domains.join(",")
                    ),
                    None,
                    |c| c.armed(true),
                );
                true
            }
            Err(error) => {
                match cleanup_rules_async(config.rules_helper.clone()).await {
                    Ok(()) => status.update_detail(
                        "lease_failed",
                        "action=rules_removed fail_open=true retry_seconds=10 phase=initial_start",
                        Some(&error),
                        |c| c.armed(false),
                    ),
                    Err(cleanup_error) => {
                        cleanup_was_failed = true;
                        let detail = format!(
                            "initial rules reconcile failed: {error}; cleanup failed: {cleanup_error}"
                        );
                        status.update_detail(
                            "cleanup_failed",
                            "armed=false retry_seconds=10 phase=initial_start",
                            Some(&detail),
                            |c| c.armed(false),
                        );
                    }
                }
                eprintln!(
                    "wlocd: daemon=ready interception=false error=initial_rules phase=start retry_seconds=10 ca_generated={generated}"
                );
                false
            }
        };
        if initially_armed {
            eprintln!("wlocd: daemon=ready interception=true ca_generated={generated}");
        }

        let armed = Arc::new(AtomicBool::new(initially_armed));
        let lease_armed = Arc::clone(&armed);
        let lease_status = Arc::clone(&status);
        let lease_helper = config.rules_helper.clone();
        let lease_port = config.listen_port;
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                if let Err(error) = reconcile_rules_async(
                    lease_helper.clone(),
                    lease_port,
                )
                .await
                {
                    let was_armed = lease_armed.swap(false, Ordering::SeqCst);
                    match cleanup_rules_async(lease_helper.clone()).await {
                        Ok(()) => {
                            if cleanup_recovery_should_report(was_armed, &mut cleanup_was_failed) {
                                lease_status.update_detail(
                                    "lease_failed",
                                    "action=rules_removed fail_open=true retry_seconds=10",
                                    Some(&error),
                                    |c| c.armed(false),
                                );
                                eprintln!(
                                    "wlocd: interception=false error=lease_refresh retry_seconds=10"
                                );
                            }
                        }
                        Err(cleanup_error) => {
                            if !cleanup_was_failed {
                                let detail = format!(
                                    "rules reconcile failed: {error}; cleanup failed: {cleanup_error}"
                                );
                                lease_status.update_detail(
                                    "cleanup_failed",
                                    "armed=false retry_seconds=10",
                                    Some(&detail),
                                    |c| c.armed(false),
                                );
                                eprintln!(
                                    "wlocd: interception=false error=cleanup_failed retry_seconds=10"
                                );
                            }
                            cleanup_was_failed = true;
                        }
                    }
                } else {
                    cleanup_was_failed = false;
                    if !lease_armed.swap(true, Ordering::SeqCst) {
                        lease_status.update_detail(
                            "interception_rearmed",
                            "action=rules_rebuilt recovery=true",
                            None,
                            |c| c.armed(true),
                        );
                        eprintln!("wlocd: interception=true recovery=rules_rebuilt");
                    }
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
