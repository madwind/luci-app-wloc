use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use http::{HeaderMap, Method, Request, Response, StatusCode, Uri};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::client_hello::peek_sni;
use crate::config::{LocationRule, MacAddress, OutboundProxy};
use crate::network_source::HostapdNetworkSource;
use crate::status::Status;
use crate::wloc::{
    patch_response_following, request_wifi_devices, valid_request, LocationFollower, PatchTarget,
};

const MAX_BODY: usize = 512 * 1024;
const HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const CONNECTION_IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);
const GLOBAL_STREAM_LIMIT: usize = 2;
const PEER_CACHE_TTL: Duration = Duration::from_secs(30);
const UPSTREAM_TLS_ATTEMPTS: usize = 2;

#[derive(Clone)]
struct PeerIdentity {
    mac: MacAddress,
    hostname: Option<String>,
}

#[derive(Clone)]
struct PeerCacheEntry {
    identity: PeerIdentity,
    expires_at: Instant,
}

#[cfg(target_os = "linux")]
fn original_destination(stream: &TcpStream) -> std::io::Result<SocketAddrV4> {
    use std::os::fd::AsRawFd;

    const SO_ORIGINAL_DST: libc::c_int = 80;
    let mut address: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_IP,
            SO_ORIGINAL_DST,
            (&mut address as *mut libc::sockaddr_in).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if address.sin_family != libc::AF_INET as libc::sa_family_t
        || usize::try_from(length).unwrap_or(0) < std::mem::size_of::<libc::sockaddr_in>()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid SO_ORIGINAL_DST address",
        ));
    }
    Ok(SocketAddrV4::new(
        Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)),
        u16::from_be(address.sin_port),
    ))
}

fn passthrough_destination(stream: &TcpStream) -> std::io::Result<SocketAddrV4> {
    #[cfg(target_os = "linux")]
    if let Ok(destination) = original_destination(stream) {
        return Ok(destination);
    }
    match stream.local_addr()? {
        SocketAddr::V4(destination) => Ok(destination),
        SocketAddr::V6(_) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "IPv6 destination on IPv4 listener",
        )),
    }
}

pub struct UpstreamResponse {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
    pub wloc: bool,
    pub response_mode: &'static str,
    pub request_kind: Option<u8>,
    pub patched_target: Option<PatchTarget>,
}

#[derive(Clone)]
struct H2Entry {
    generation: u64,
    sender: h2::client::SendRequest<Bytes>,
}

#[derive(Clone)]
pub struct Proxy {
    acceptor: TlsAcceptor,
    connector: TlsConnector,
    rules: Vec<LocationRule>,
    domains: Vec<String>,
    debug: bool,
    arp_path: PathBuf,
    dhcp_leases_path: PathBuf,
    peer_cache: Arc<tokio::sync::Mutex<HashMap<Ipv4Addr, PeerCacheEntry>>>,
    network_source: HostapdNetworkSource,
    listen_port: u16,
    status: Arc<Status>,
    h2_pool: Arc<tokio::sync::Mutex<HashMap<String, H2Entry>>>,
    h2_generation: Arc<AtomicU64>,
    stream_limit: Arc<tokio::sync::Semaphore>,
    followers: HashMap<String, Arc<tokio::sync::Mutex<LocationFollower>>>,
}

impl Proxy {
    pub fn new(
        server: rustls::ServerConfig,
        client: rustls::ClientConfig,
        rules: Vec<LocationRule>,
        listen_port: u16,
        domains: Vec<String>,
        debug: bool,
        status: Arc<Status>,
    ) -> Self {
        let followers = rules
            .iter()
            .map(|rule| {
                (
                    rule.id.clone(),
                    Arc::new(tokio::sync::Mutex::new(LocationFollower::new(rule.target))),
                )
            })
            .collect();
        Self {
            acceptor: TlsAcceptor::from(Arc::new(server)),
            connector: TlsConnector::from(Arc::new(client)),
            rules,
            domains,
            debug,
            arp_path: std::env::var_os("WLOC_ARP_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/proc/net/arp")),
            dhcp_leases_path: std::env::var_os("WLOC_DHCP_LEASES_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp/dhcp.leases")),
            peer_cache: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            network_source: HostapdNetworkSource::new(),
            listen_port,
            status,
            h2_pool: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            h2_generation: Arc::new(AtomicU64::new(1)),
            stream_limit: Arc::new(tokio::sync::Semaphore::new(GLOBAL_STREAM_LIMIT)),
            followers,
        }
    }

    fn rule_detail(&self, rule_id: &str, ip: IpAddr, detail: String) -> String {
        let rule = self.rules.iter().find(|target| target.id == rule_id);
        let rule_token = format!("rule={rule_id}");
        let detail = if detail.split_whitespace().any(|token| token == rule_token) {
            detail
        } else {
            format!("{detail} {rule_token}")
        };
        match rule {
            Some(rule) => format!("{} {detail}", rule.log_context_with_ip(ip)),
            None => format!(
                "{} {detail}",
                unmatched_context(None, None, ip, "configured_rule_missing")
            ),
        }
    }

    async fn identity_for(&self, peer: Ipv4Addr) -> Result<Option<PeerIdentity>, String> {
        let cached = self.peer_cache.lock().await.get(&peer).cloned();
        if let Some(entry) = cached.filter(|entry| entry.expires_at > Instant::now()) {
            return Ok(Some(entry.identity));
        }
        let arp_path = self.arp_path.clone();
        let dhcp_leases_path = self.dhcp_leases_path.clone();
        let resolved = tokio::task::spawn_blocking(move || {
            neighbor_mac_for(&arp_path, &dhcp_leases_path, peer)
        })
        .await
        .map_err(|error| format!("neighbor lookup task failed: {error}"))?;
        let Some((identity, _lookup)) = resolved else {
            return Ok(None);
        };
        self.peer_cache.lock().await.insert(
            peer,
            PeerCacheEntry {
                identity: identity.clone(),
                expires_at: Instant::now() + PEER_CACHE_TTL,
            },
        );
        Ok(Some(identity))
    }

    async fn target_for(&self, peer: IpAddr) -> Result<Option<LocationRule>, String> {
        let IpAddr::V4(peer) = peer else {
            return Ok(None);
        };
        let Some(identity) = self.identity_for(peer).await? else {
            return Ok(None);
        };
        let access_point = match self.network_source.current_for(identity.mac).await {
            Ok(access_point) => access_point,
            Err(error) => {
                self.status.update_detail(
                    "network_source_failed",
                    &unmatched_context(
                        identity.hostname.as_deref(),
                        Some(identity.mac),
                        peer,
                        "hostapd",
                    ),
                    Some(&error),
                    |_| {},
                );
                None
            }
        };
        Ok(first_matching_rule(
            &self.rules,
            access_point
                .as_ref()
                .map(|access_point| access_point.iface.as_str()),
        )
        .cloned())
    }

    pub async fn handle(&self, stream: TcpStream) -> Result<(), ProxyError> {
        let peer_address = stream.peer_addr().map_err(ProxyError::io)?;
        let rule = match self.target_for(peer_address.ip()).await {
            Ok(rule) => rule,
            Err(error) => {
                self.status.update_detail(
                    "rule_lookup_failed",
                    &unmatched_context(None, None, peer_address.ip(), "hostapd"),
                    Some(&error),
                    |c| c.passthrough(),
                );
                None
            }
        };
        let Some(rule) = rule else {
            self.status.update_detail(
                "rule_passthrough",
                &format!("matched=false ip={} action=passthrough", peer_address.ip()),
                None,
                |c| c.passthrough(),
            );
            return self.tunnel(stream, &OutboundProxy::Direct).await;
        };
        let ap_id = rule.id.clone();
        let result = self.handle_target(stream, rule, peer_address.ip()).await;
        if let Err(ProxyError::ClientClosed(reason)) = &result {
            self.status.update_detail(
                "client_cancelled",
                &self.rule_detail(
                    &ap_id,
                    peer_address.ip(),
                    format!("rule={ap_id} action=cancelled reason={reason}"),
                ),
                None,
                |_| {},
            );
            return Ok(());
        }
        if let Err(error) = &result {
            let reason = error.to_string();
            self.status.update_detail(
                "ap_failed",
                &self.rule_detail(
                    &ap_id,
                    peer_address.ip(),
                    format!("rule={ap_id} category={}", error.category()),
                ),
                Some(&reason),
                |c| c.request_failed_for(&ap_id, &reason),
            );
        }
        result
    }

    async fn handle_target(
        &self,
        stream: TcpStream,
        rule: LocationRule,
        ip: IpAddr,
    ) -> Result<(), ProxyError> {
        let client = rule.id;
        let follower = self
            .followers
            .get(&client)
            .cloned()
            .ok_or_else(|| ProxyError::Protocol("location_follower_missing".into()))?;
        let outbound = rule.outbound;
        self.status.update_detail(
            "connection_accepted",
            &self.rule_detail(&client, ip, format!("rule={client}")),
            None,
            |c| c.accepted(),
        );
        let sni = tokio::time::timeout(HANDSHAKE_TIMEOUT, peek_sni(&stream))
            .await
            .map_err(|_| ProxyError::ClientTls("client_hello_timeout".into()))?
            .map_err(|e| ProxyError::ClientTls(format!("client_hello_{e:?}")))?;
        let approved = sni
            .as_deref()
            .is_some_and(|host| crate::approved_host(host, &self.domains));
        self.status.update_detail(
            "client_hello",
            &self.rule_detail(
                &client,
                ip,
                format!(
                    "rule={client} sni={} approved={approved}",
                    sni.as_deref().unwrap_or("missing")
                ),
            ),
            None,
            |_| {},
        );
        if !approved {
            self.status.update_detail(
                "sni_passthrough",
                &self.rule_detail(
                    &client,
                    ip,
                    format!("rule={client} reason=hostname_not_approved"),
                ),
                None,
                |c| c.passthrough(),
            );
            return self.tunnel(stream, &outbound).await;
        }
        let hostname = sni.unwrap();
        let tls = tokio::time::timeout(HANDSHAKE_TIMEOUT, self.acceptor.accept(stream))
            .await
            .map_err(|_| ProxyError::ClientTls("handshake_timeout".into()))?
            .map_err(|e| ProxyError::ClientTls(e.to_string()))?;
        if tls.get_ref().1.alpn_protocol() != Some(b"h2") {
            return Err(ProxyError::ClientTls("h2_alpn_required".into()));
        }
        self.status.update_detail(
            "tls_intercepted",
            &self.rule_detail(
                &client,
                ip,
                format!("rule={client} host={hostname} alpn=h2"),
            ),
            None,
            |c| c.tls(),
        );
        let mut h2 = h2::server::Builder::new()
            .initial_window_size(64 * 1024)
            .max_frame_size(16 * 1024)
            .max_concurrent_streams(2)
            .max_header_list_size(32 * 1024)
            .handshake::<_, Bytes>(tls)
            .await
            .map_err(ProxyError::h2)?;
        let mut streams = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                accepted = tokio::time::timeout(CONNECTION_IDLE_TIMEOUT, h2.accept()) => {
                    let Some(accepted) = accepted
                        .map_err(|_| ProxyError::ClientTls("h2_idle_timeout".into()))?
                    else {
                        break;
                    };
                    let (request, respond) = accepted.map_err(ProxyError::h2)?;
                    let proxy = self.clone();
                    let hostname = hostname.clone();
                    let client = client.clone();
                    let outbound = outbound.clone();
                    let follower = Arc::clone(&follower);
                    streams.spawn(async move {
                        proxy
                            .handle_h2_stream(request, respond, &hostname, follower, &client, ip, &outbound)
                            .await
                    });
                }
                completed = streams.join_next(), if !streams.is_empty() => {
                    let completed = completed
                        .ok_or_else(|| ProxyError::Protocol("stream_task_missing".into()))?;
                    handle_stream_completion(completed)?;
                }
            }
        }
        while let Some(completed) = streams.join_next().await {
            handle_stream_completion(completed)?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn handle_h2_stream(
        &self,
        request: Request<h2::RecvStream>,
        mut respond: h2::server::SendResponse<Bytes>,
        hostname: &str,
        follower: Arc<tokio::sync::Mutex<LocationFollower>>,
        client: &str,
        ip: IpAddr,
        outbound: &OutboundProxy,
    ) -> Result<(), ProxyError> {
        let permit_result = tokio::select! {
            reset = std::future::poll_fn(|context| respond.poll_reset(context)) => {
                let reason = match reset {
                    Ok(reason) => format!("phase=queue rst_stream={reason:?}"),
                    Err(error) => format!("phase=queue h2_connection={error}"),
                };
                return Err(ProxyError::ClientClosed(reason));
            }
            permit = tokio::time::timeout(REQUEST_TIMEOUT, self.stream_limit.acquire()) => permit,
        };
        let _stream_permit = permit_result
            .map_err(|_| ProxyError::Protocol("stream_queue_timeout".into()))?
            .map_err(|_| ProxyError::Protocol("stream_limit_closed".into()))?;

        let forward_result = tokio::select! {
            reset = std::future::poll_fn(|context| respond.poll_reset(context)) => {
                let reason = match reset {
                    Ok(reason) => format!("phase=upstream rst_stream={reason:?}"),
                    Err(error) => format!("phase=upstream h2_connection={error}"),
                };
                return Err(ProxyError::ClientClosed(reason));
            }
            upstream = tokio::time::timeout(
                REQUEST_TIMEOUT,
                self.forward(request, hostname, &follower, client, ip, outbound),
            ) => upstream,
        };
        let upstream = forward_result
            .map_err(|_| ProxyError::Upstream("request_timeout".into()))??;
        let end = upstream.body.is_empty();
        let delivered_bytes = upstream.body.len();
        let delivered_status = upstream.status.as_u16();
        let delivered_wloc = upstream.wloc;
        let response_mode = upstream.response_mode;
        let request_kind = upstream.request_kind;
        let patched_target = upstream.patched_target;
        let mut response = Response::builder().status(upstream.status);
        if let Some(headers) = response.headers_mut() {
            for (name, value) in upstream.headers.iter() {
                if ![
                    "connection",
                    "proxy-connection",
                    "keep-alive",
                    "transfer-encoding",
                    "upgrade",
                    "content-length",
                ]
                .contains(&name.as_str())
                {
                    headers.append(name.clone(), value.clone());
                }
            }
            headers.insert(
                "content-length",
                http::HeaderValue::from_str(&upstream.body.len().to_string())
                    .map_err(ProxyError::h2)?,
            );
        }
        let response = response.body(()).map_err(ProxyError::h2)?;
        let mut sender = respond
            .send_response(response, end)
            .map_err(ProxyError::client_h2)?;
        if !end {
            tokio::time::timeout(
                REQUEST_TIMEOUT,
                send_h2_data(&mut sender, &upstream.body, false),
            )
            .await
            .map_err(|_| ProxyError::Protocol("response_timeout".into()))??;
        }
        if delivered_wloc || response_mode == "debug" {
            self.status.update_detail(
                "response_delivered",
                &self.rule_detail(
                    client,
                    ip,
                    format!(
                        "rule={client} host={hostname} status={delivered_status} bytes={delivered_bytes} mode={response_mode} kind={}",
                        request_kind
                            .map(|kind| kind.to_string())
                            .unwrap_or_else(|| "unknown".into())
                    ),
                ),
                None,
                |c| {
                    if let Some(target) = patched_target {
                        c.delivered_for(client, target.latitude, target.longitude);
                    } else if response_mode == "debug" {
                        c.delivered();
                    }
                },
            );
        }
        Ok(())
    }

    async fn tunnel(
        &self,
        mut client: TcpStream,
        outbound: &OutboundProxy,
    ) -> Result<(), ProxyError> {
        let destination = passthrough_destination(&client).map_err(ProxyError::io)?;
        if destination.port() == self.listen_port || destination.ip().is_unspecified() {
            return Err(ProxyError::ClientTls(
                "original_destination_unavailable".into(),
            ));
        }
        let mut upstream = tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            connect_outbound(outbound, &destination.ip().to_string(), destination.port()),
        )
        .await
        .map_err(|_| ProxyError::Upstream("passthrough_connect_timeout".into()))??;
        tokio::time::timeout(
            std::time::Duration::from_secs(300),
            tokio::io::copy_bidirectional(&mut client, &mut upstream),
        )
        .await
        .map_err(|_| ProxyError::Upstream("passthrough_timeout".into()))?
        .map_err(ProxyError::io)?;
        Ok(())
    }

    async fn forward(
        &self,
        request: Request<h2::RecvStream>,
        tls_sni: &str,
        follower: &tokio::sync::Mutex<LocationFollower>,
        client: &str,
        ip: IpAddr,
        outbound: &OutboundProxy,
    ) -> Result<UpstreamResponse, ProxyError> {
        let authority = request
            .uri()
            .authority()
            .map(|a| a.host())
            .ok_or_else(|| ProxyError::Protocol("missing_authority".into()))?;
        if !crate::approved_host(authority, &self.domains)
            || !authority.eq_ignore_ascii_case(tls_sni)
        {
            return Err(ProxyError::Protocol("authority_sni_mismatch".into()));
        }
        let method = request.method().clone();
        let uri = request.uri().clone();
        let headers = request.headers().clone();
        let mut body_stream = request.into_body();
        let mut body = Vec::new();
        while let Some(chunk) = body_stream.data().await {
            let chunk = chunk.map_err(ProxyError::client_h2)?;
            if body.len().saturating_add(chunk.len()) > MAX_BODY {
                return Err(ProxyError::Protocol("request_body_too_large".into()));
            }
            body.extend_from_slice(&chunk);
            body_stream
                .flow_control()
                .release_capacity(chunk.len())
                .map_err(ProxyError::h2)?;
        }
        let is_wloc = method == Method::POST && uri.path() == "/clls/wloc" && valid_request(&body);
        self.status.update_detail(
            "request_received",
            &self.rule_detail(
                client,
                ip,
                format!(
                    "rule={client} host={tls_sni} method={method} path={} body_bytes={} valid_wloc={is_wloc}",
                    uri.path(),
                    body.len()
                ),
            ),
            None,
            |_| {},
        );
        if self.debug {
            self.status.update_detail(
                "debug_response",
                &self.rule_detail(
                    client,
                    ip,
                    format!("rule={client} host={tls_sni} action=fixed_json"),
                ),
                None,
                |_| {},
            );
            return Ok(debug_response());
        }
        if is_wloc {
            let request_kind = crate::wloc::request_kind(&body)
                .map(|kind| kind.to_string())
                .unwrap_or_else(|| "unknown".into());
            let wifi_devices = request_wifi_devices(&body)
                .map(|count| count.to_string())
                .unwrap_or_else(|| "unknown".into());
            self.status.update_detail(
                "wloc_request",
                &self.rule_detail(
                    client,
                    ip,
                    format!(
                        "rule={client} host={tls_sni} kind={request_kind} wifi_devices={wifi_devices} body_bytes={}",
                        body.len()
                    ),
                ),
                None,
                |c| c.wloc(),
            );
        }

        let (mut response, upstream_protocol) = self
            .exchange_upstream(
                &method, &uri, &headers, tls_sni, &body, client, ip, outbound,
            )
            .await?;
        self.status.update_detail(
            "upstream_response",
            &self.rule_detail(
                client,
                ip,
                format!(
                    "host={tls_sni} protocol={upstream_protocol} status={} body_bytes={}",
                    response.status.as_u16(),
                    response.body.len()
                ),
            ),
            None,
            |_| {},
        );
        let mut response_mode = "forwarded";
        let mut patched_target = None;
        if is_wloc && response.status == StatusCode::OK {
            let mut follower = follower.lock().await;
            match patch_response_following(&response.body, &mut follower) {
                Ok((patched, target)) => {
                    let before = response.body.len();
                    response.body = patched.body;
                    response_mode = "upstream_patched";
                    patched_target = Some(target);
                    let location_lines = if self.status.runtime_log_enabled() {
                        patched
                            .changes
                            .iter()
                            .enumerate()
                            .map(|(index, change)| {
                                let before_accuracy = change
                                    .accuracy_before
                                    .map(|value| value.to_string())
                                    .unwrap_or_else(|| "absent".into());
                                let after_accuracy = change
                                    .accuracy_after
                                    .map(|value| value.to_string())
                                    .unwrap_or_else(|| "absent".into());
                                self.rule_detail(
                                    client,
                                    ip,
                                    format!(
                                        "rule={client} host={tls_sni} source={} index={} before={:.8},{:.8},accuracy_m={} after={:.8},{:.8},accuracy_m={}",
                                        change.source,
                                        index + 1,
                                        change.latitude_before_e8 as f64 / 100_000_000.0,
                                        change.longitude_before_e8 as f64 / 100_000_000.0,
                                        before_accuracy,
                                        change.latitude_after_e8 as f64 / 100_000_000.0,
                                        change.longitude_after_e8 as f64 / 100_000_000.0,
                                        after_accuracy
                                    ),
                                )
                            })
                            .collect::<Vec<_>>()
                    } else {
                        Vec::new()
                    };
                    self.status.update_detail_lines(
                        "wloc_upstream_patched",
                        &self.rule_detail(
                            client,
                            ip,
                            format!(
                                "rule={client} host={tls_sni} bytes_before={before} bytes_after={} wifi_devices={} cell_responses={} locations={} skipped={} changed_fields=latitude,longitude preserved=accuracy,all_other_fields",
                                response.body.len(),
                                patched.wifi_devices,
                                patched.cell_responses,
                                patched.locations,
                                patched.skipped_locations
                            ),
                        ),
                        &location_lines,
                        None,
                        |c| c.patched(),
                    );
                }
                Err(error) => {
                    let reason = format!("protocol_{error}");
                    self.status.update_detail(
                        "wloc_passthrough",
                        &self.rule_detail(
                            client,
                            ip,
                            format!("host={tls_sni} action=original_response"),
                        ),
                        Some(&reason),
                        |c| c.patch_failed_for(client, &reason),
                    );
                }
            }
        }
        let request_kind = if is_wloc {
            crate::wloc::request_kind(&body)
        } else {
            None
        };
        response.wloc = is_wloc;
        response.response_mode = response_mode;
        response.request_kind = request_kind;
        response.patched_target = patched_target;
        Ok(response)
    }

    #[allow(clippy::too_many_arguments)]
    async fn exchange_upstream(
        &self,
        method: &Method,
        uri: &Uri,
        headers: &HeaderMap,
        hostname: &str,
        body: &[u8],
        client: &str,
        ip: IpAddr,
        outbound: &OutboundProxy,
    ) -> Result<(UpstreamResponse, &'static str), ProxyError> {
        let pool_key = outbound.pool_key(hostname);
        if let Some(entry) = self.h2_pool.lock().await.get(&pool_key).cloned() {
            match entry.sender.ready().await {
                Ok(sender) => {
                    self.status.update_detail(
                        "upstream_reused",
                        &self.rule_detail(client, ip, format!("host={hostname} protocol=h2")),
                        None,
                        |_| {},
                    );
                    return exchange_h2(sender, method, uri, headers, hostname, body)
                        .await
                        .map(|response| (response, "h2"));
                }
                Err(_) => {
                    remove_h2_generation(&self.h2_pool, &pool_key, entry.generation).await;
                }
            }
        }

        self.status.update_detail(
            "upstream_connect",
            &self.rule_detail(
                client,
                ip,
                format!("host={hostname} port=443 outbound={}", outbound.label()),
            ),
            None,
            |_| {},
        );
        let server_name = rustls::pki_types::ServerName::try_from(hostname.to_owned())
            .map_err(|_| ProxyError::Upstream("invalid_hostname".into()))?;
        let mut tls_attempt = 1usize;
        let tls = loop {
            let tcp = tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                connect_outbound(outbound, hostname, 443),
            )
            .await
            .map_err(|_| ProxyError::Upstream("connect_timeout".into()))??;
            match tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                self.connector.connect(server_name.clone(), tcp),
            )
            .await
            {
                Ok(Ok(tls)) => break tls,
                Ok(Err(error))
                    if tls_attempt < UPSTREAM_TLS_ATTEMPTS
                        && retryable_tls_handshake_error(&error) =>
                {
                    self.status.update_detail(
                        "upstream_retry",
                        &self.rule_detail(
                            client,
                            ip,
                            format!(
                                "host={hostname} stage=tls attempt={tls_attempt} next_attempt={} reason={}",
                                tls_attempt + 1,
                                error.kind()
                            ),
                        ),
                        None,
                        |_| {},
                    );
                    tls_attempt += 1;
                }
                Ok(Err(error)) => {
                    return Err(ProxyError::Upstream(format!("tls_verify: {error}")));
                }
                Err(_) if tls_attempt < UPSTREAM_TLS_ATTEMPTS => {
                    self.status.update_detail(
                        "upstream_retry",
                        &self.rule_detail(
                            client,
                            ip,
                            format!(
                                "host={hostname} stage=tls attempt={tls_attempt} next_attempt={} reason=timeout",
                                tls_attempt + 1
                            ),
                        ),
                        None,
                        |_| {},
                    );
                    tls_attempt += 1;
                }
                Err(_) => return Err(ProxyError::Upstream("tls_timeout".into())),
            }
        };
        let alpn = tls.get_ref().1.alpn_protocol().map(|value| value.to_vec());
        match alpn.as_deref() {
            Some(b"h2") => {
                let (sender, connection) = h2::client::Builder::new()
                    .initial_window_size(64 * 1024)
                    .max_frame_size(16 * 1024)
                    .max_header_list_size(32 * 1024)
                    .handshake::<_, Bytes>(tls)
                    .await
                    .map_err(ProxyError::upstream_h2)?;
                let generation = self.h2_generation.fetch_add(1, Ordering::Relaxed);
                self.h2_pool.lock().await.insert(
                    pool_key.clone(),
                    H2Entry {
                        generation,
                        sender: sender.clone(),
                    },
                );
                let pool = Arc::clone(&self.h2_pool);
                let driver_key = pool_key;
                tokio::spawn(async move {
                    let _ = connection.await;
                    remove_h2_generation(&pool, &driver_key, generation).await;
                });
                let sender = sender.ready().await.map_err(ProxyError::upstream_h2)?;
                exchange_h2(sender, method, uri, headers, hostname, body)
                    .await
                    .map(|response| (response, "h2"))
            }
            Some(b"http/1.1") | None => {
                crate::http1::exchange(tls, method, uri, headers, hostname, body)
                    .await
                    .map(|response| (response, "http/1.1"))
            }
            _ => Err(ProxyError::Upstream("unsupported_upstream_alpn".into())),
        }
    }
}

fn handle_stream_completion(
    completed: Result<Result<(), ProxyError>, tokio::task::JoinError>,
) -> Result<(), ProxyError> {
    match completed.map_err(|error| ProxyError::Protocol(format!("stream_task: {error}")))? {
        Ok(()) | Err(ProxyError::ClientClosed(_)) => Ok(()),
        Err(error) => Err(error),
    }
}

fn retryable_tls_handshake_error(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::UnexpectedEof
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::BrokenPipe
    )
}

async fn connect_outbound(
    outbound: &OutboundProxy,
    destination: &str,
    port: u16,
) -> Result<TcpStream, ProxyError> {
    match outbound {
        OutboundProxy::Direct => TcpStream::connect((destination, port))
            .await
            .map_err(ProxyError::io),
        OutboundProxy::Http {
            host,
            port: proxy_port,
        } => {
            let mut stream = TcpStream::connect((host.as_str(), *proxy_port))
                .await
                .map_err(ProxyError::io)?;
            http_connect(&mut stream, destination, port).await?;
            Ok(stream)
        }
        OutboundProxy::Socks5 {
            host,
            port: proxy_port,
        } => {
            let mut stream = TcpStream::connect((host.as_str(), *proxy_port))
                .await
                .map_err(ProxyError::io)?;
            socks5_connect(&mut stream, destination, port).await?;
            Ok(stream)
        }
    }
}

async fn http_connect(
    stream: &mut TcpStream,
    destination: &str,
    port: u16,
) -> Result<(), ProxyError> {
    let authority = match destination.parse::<IpAddr>() {
        Ok(IpAddr::V6(_)) => format!("[{destination}]:{port}"),
        _ => format!("{destination}:{port}"),
    };
    let request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: keep-alive\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(ProxyError::io)?;
    let mut response = Vec::with_capacity(256);
    let mut byte = [0_u8; 1];
    while response.len() < 8192 {
        if stream.read(&mut byte).await.map_err(ProxyError::io)? == 0 {
            return Err(ProxyError::Upstream(
                "HTTP proxy closed during CONNECT".into(),
            ));
        }
        response.push(byte[0]);
        if response.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    if !response.ends_with(b"\r\n\r\n") {
        return Err(ProxyError::Upstream(
            "HTTP proxy CONNECT headers exceed bound".into(),
        ));
    }
    let status = std::str::from_utf8(&response)
        .ok()
        .and_then(|text| text.lines().next())
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| ProxyError::Upstream("invalid HTTP proxy CONNECT response".into()))?;
    if status != 200 {
        return Err(ProxyError::Upstream(format!(
            "HTTP proxy CONNECT status {status}"
        )));
    }
    Ok(())
}

async fn socks5_connect(
    stream: &mut TcpStream,
    destination: &str,
    port: u16,
) -> Result<(), ProxyError> {
    stream
        .write_all(&[0x05, 0x01, 0x00])
        .await
        .map_err(ProxyError::io)?;
    let mut greeting = [0_u8; 2];
    stream
        .read_exact(&mut greeting)
        .await
        .map_err(ProxyError::io)?;
    if greeting != [0x05, 0x00] {
        return Err(ProxyError::Upstream(
            "SOCKS5 proxy requires unsupported authentication".into(),
        ));
    }

    let mut request = vec![0x05, 0x01, 0x00];
    match destination.parse::<IpAddr>() {
        Ok(IpAddr::V4(address)) => {
            request.push(0x01);
            request.extend_from_slice(&address.octets());
        }
        Ok(IpAddr::V6(address)) => {
            request.push(0x04);
            request.extend_from_slice(&address.octets());
        }
        Err(_) => {
            let name = destination.as_bytes();
            if name.is_empty() || name.len() > u8::MAX as usize {
                return Err(ProxyError::Upstream(
                    "destination hostname is invalid for SOCKS5".into(),
                ));
            }
            request.extend_from_slice(&[0x03, name.len() as u8]);
            request.extend_from_slice(name);
        }
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await.map_err(ProxyError::io)?;

    let mut reply = [0_u8; 4];
    stream
        .read_exact(&mut reply)
        .await
        .map_err(ProxyError::io)?;
    if reply[0] != 0x05 || reply[1] != 0x00 {
        return Err(ProxyError::Upstream(format!(
            "SOCKS5 proxy CONNECT failed with code {}",
            reply[1]
        )));
    }
    let address_len = match reply[3] {
        0x01 => 4,
        0x04 => 16,
        0x03 => {
            let mut length = [0_u8; 1];
            stream
                .read_exact(&mut length)
                .await
                .map_err(ProxyError::io)?;
            usize::from(length[0])
        }
        _ => return Err(ProxyError::Upstream("invalid SOCKS5 proxy response".into())),
    };
    let mut bound_address_and_port = vec![0_u8; address_len + 2];
    stream
        .read_exact(&mut bound_address_and_port)
        .await
        .map_err(ProxyError::io)?;
    Ok(())
}

async fn remove_h2_generation(
    pool: &tokio::sync::Mutex<HashMap<String, H2Entry>>,
    hostname: &str,
    generation: u64,
) {
    let mut pool = pool.lock().await;
    if pool
        .get(hostname)
        .is_some_and(|entry| entry.generation == generation)
    {
        pool.remove(hostname);
    }
}

fn first_matching_rule<'a>(
    rules: &'a [LocationRule],
    iface: Option<&str>,
) -> Option<&'a LocationRule> {
    iface.and_then(|iface| rules.iter().find(|rule| rule.iface == iface))
}

fn arp_mac_for(path: &Path, address: Ipv4Addr) -> Option<MacAddress> {
    let table = std::fs::read_to_string(path).ok()?;
    for line in table.lines().skip(1) {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 4 || columns[0].parse::<Ipv4Addr>().ok() != Some(address) {
            continue;
        }
        if let Ok(mac) = MacAddress::parse(columns[3]) {
            return Some(mac);
        }
    }
    None
}

fn ip_neigh_mac_for(address: Ipv4Addr) -> Option<MacAddress> {
    let output = std::process::Command::new("ip")
        .args(["neigh", "show", &address.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let output = String::from_utf8_lossy(&output.stdout);
    let columns = output.split_whitespace().collect::<Vec<_>>();
    columns
        .windows(2)
        .find(|pair| pair[0] == "lladdr")
        .and_then(|pair| MacAddress::parse(pair[1]).ok())
}

fn dhcp_lease_identity_from(table: &str, address: Ipv4Addr) -> Option<PeerIdentity> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    table.lines().rev().find_map(|line| {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 3 || columns[2].parse::<Ipv4Addr>().ok() != Some(address) {
            return None;
        }
        let expires = columns[0].parse::<u64>().ok()?;
        if expires != 0 && expires <= now {
            return None;
        }
        let mac = MacAddress::parse(columns[1]).ok()?;
        let hostname = columns
            .get(3)
            .filter(|value| !value.is_empty() && **value != "*")
            .map(|value| (*value).to_owned());
        Some(PeerIdentity { mac, hostname })
    })
}

fn dhcp_lease_identity_for(path: &Path, address: Ipv4Addr) -> Option<PeerIdentity> {
    let table = std::fs::read_to_string(path).ok()?;
    dhcp_lease_identity_from(&table, address)
}

fn mac_label(mac: MacAddress) -> String {
    mac.label().to_uppercase()
}

fn safe_device_name(hostname: Option<&str>) -> String {
    hostname
        .filter(|value| !value.is_empty() && *value != "*")
        .unwrap_or("unknown")
        .chars()
        .map(|character| {
            if character == '"' || character == '\\' || character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(80)
        .collect()
}

fn unmatched_context(
    hostname: Option<&str>,
    mac: Option<MacAddress>,
    ip: impl std::fmt::Display,
    lookup: &str,
) -> String {
    let device = safe_device_name(hostname);
    let mac = mac.map(mac_label).unwrap_or_else(|| "unknown".into());
    format!("device=\"{device}\" matched=false mac={mac} ip={ip} lookup={lookup}")
}

fn neighbor_mac_for(
    arp_path: &Path,
    dhcp_leases_path: &Path,
    address: Ipv4Addr,
) -> Option<(PeerIdentity, &'static str)> {
    dhcp_lease_identity_for(dhcp_leases_path, address)
        .map(|identity| (identity, "dhcp_lease"))
        .or_else(|| {
            arp_mac_for(arp_path, address).map(|mac| {
                (
                    PeerIdentity {
                        mac,
                        hostname: None,
                    },
                    "arp",
                )
            })
        })
        .or_else(|| {
            ip_neigh_mac_for(address).map(|mac| {
                (
                    PeerIdentity {
                        mac,
                        hostname: None,
                    },
                    "ip_neigh",
                )
            })
        })
}

fn debug_response() -> UpstreamResponse {
    let mut headers = HeaderMap::new();
    headers.insert(
        "content-type",
        http::HeaderValue::from_static("application/json"),
    );
    UpstreamResponse {
        status: StatusCode::OK,
        headers,
        body: br#"{"wloc":"ok"}"#.to_vec(),
        wloc: false,
        response_mode: "debug",
        request_kind: None,
        patched_target: None,
    }
}

async fn exchange_h2(
    mut sender: h2::client::SendRequest<Bytes>,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    hostname: &str,
    body: &[u8],
) -> Result<UpstreamResponse, ProxyError> {
    let full_uri: Uri = format!(
        "https://{hostname}{}",
        uri.path_and_query().map(|v| v.as_str()).unwrap_or("/")
    )
    .parse()
    .map_err(|_| ProxyError::Protocol("invalid_uri".into()))?;
    let mut request = Request::builder().method(method.clone()).uri(full_uri);
    if let Some(out) = request.headers_mut() {
        for (name, value) in headers.iter() {
            if ![
                "connection",
                "proxy-connection",
                "keep-alive",
                "transfer-encoding",
                "upgrade",
                "host",
                "content-length",
                "accept-encoding",
            ]
            .contains(&name.as_str())
            {
                out.append(name.clone(), value.clone());
            }
        }
        if !body.is_empty() {
            out.insert(
                "content-length",
                http::HeaderValue::from_str(&body.len().to_string()).map_err(ProxyError::h2)?,
            );
        }
    }
    let request = request.body(()).map_err(ProxyError::h2)?;
    let (response, mut send) = sender
        .send_request(request, body.is_empty())
        .map_err(ProxyError::upstream_h2)?;
    if !body.is_empty() {
        send_h2_data(&mut send, body, true).await?;
    }
    let mut response = response.await.map_err(ProxyError::upstream_h2)?;
    let status = response.status();
    let headers = response.headers().clone();
    let mut response_body = Vec::new();
    while let Some(chunk) = response.body_mut().data().await {
        let chunk = chunk.map_err(ProxyError::upstream_h2)?;
        if response_body.len().saturating_add(chunk.len()) > MAX_BODY {
            return Err(ProxyError::Upstream("h2_response_too_large".into()));
        }
        response_body.extend_from_slice(&chunk);
        response
            .body_mut()
            .flow_control()
            .release_capacity(chunk.len())
            .map_err(ProxyError::upstream_h2)?;
    }
    Ok(UpstreamResponse {
        status,
        headers,
        body: response_body,
        wloc: false,
        response_mode: "forwarded",
        request_kind: None,
        patched_target: None,
    })
}

async fn send_h2_data(
    sender: &mut h2::SendStream<Bytes>,
    body: &[u8],
    upstream: bool,
) -> Result<(), ProxyError> {
    let mut offset = 0;
    while offset < body.len() {
        sender.reserve_capacity((body.len() - offset).min(16 * 1024));
        let capacity = std::future::poll_fn(|context| sender.poll_capacity(context))
            .await
            .ok_or_else(|| {
                if upstream {
                    ProxyError::Upstream("h2: stream closed".into())
                } else {
                    ProxyError::ClientClosed("phase=response_body h2_stream_closed".into())
                }
            })?
            .map_err(|error| {
                if upstream {
                    ProxyError::upstream_h2(error)
                } else {
                    ProxyError::client_h2(error)
                }
            })?;
        if capacity == 0 {
            continue;
        }
        let count = capacity.min(body.len() - offset).min(16 * 1024);
        let end_stream = offset + count == body.len();
        sender
            .send_data(
                Bytes::copy_from_slice(&body[offset..offset + count]),
                end_stream,
            )
            .map_err(|error| {
                if upstream {
                    ProxyError::upstream_h2(error)
                } else {
                    ProxyError::client_h2(error)
                }
            })?;
        offset += count;
    }
    Ok(())
}

#[derive(Debug)]
pub enum ProxyError {
    ClientTls(String),
    ClientClosed(String),
    Protocol(String),
    Upstream(String),
}

impl ProxyError {
    pub fn io(error: std::io::Error) -> Self {
        Self::Upstream(error.kind().to_string())
    }
    pub fn h2(error: impl std::fmt::Display) -> Self {
        Self::Protocol(error.to_string())
    }
    pub fn client_h2(error: h2::Error) -> Self {
        let message = error.to_string();
        if error.is_reset()
            || error.is_remote()
            || message.contains("inactive stream")
            || message.contains("unexpected frame type")
        {
            Self::ClientClosed(format!("h2: {message}"))
        } else {
            Self::Protocol(message)
        }
    }
    pub fn upstream_h2(error: impl std::fmt::Display) -> Self {
        Self::Upstream(format!("h2: {error}"))
    }
    pub fn category(&self) -> &'static str {
        match self {
            Self::ClientTls(_) => "client_tls",
            Self::ClientClosed(_) => "client_closed",
            Self::Protocol(_) => "protocol",
            Self::Upstream(_) => "upstream",
        }
    }
}
impl std::fmt::Display for ProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ClientTls(v) => write!(f, "client TLS: {v}"),
            Self::ClientClosed(v) => write!(f, "client closed: {v}"),
            Self::Protocol(v) => write!(f, "protocol: {v}"),
            Self::Upstream(v) => write!(f, "upstream: {v}"),
        }
    }
}
impl std::error::Error for ProxyError {}
