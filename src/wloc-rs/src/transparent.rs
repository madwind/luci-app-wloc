use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use http::{Method, Request, StatusCode, Uri};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio_rustls::TlsConnector;
use wloc_rs::config::{LocationRule, MacAddress, OutboundProxy};
use wloc_rs::network_source::HostapdNetworkSource;

const PEER_CACHE_TTL: Duration = Duration::from_secs(5);
const PEER_CACHE_MAX: usize = 256;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const DNS_TCP_IDLE_TIMEOUT: Duration = Duration::from_secs(15);
const UDP_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const UDP_DISPATCH_LIMIT: usize = 256;
const DNS_DISPATCH_LIMIT: usize = 32;
const UDP_ASSOCIATION_MAX: usize = 256;
const UDP_ASSOCIATION_QUEUE: usize = 64;
const UDP_REPLY_SOCKET_MAX: usize = 256;
const UDP_REPLY_SOCKET_TTL: Duration = Duration::from_secs(60);
const UDP_ERROR_LOG_INTERVAL: Duration = Duration::from_secs(1);
const DOH_POOL_MAX: usize = 64;
const DOH_ENDPOINT_TIMEOUT: Duration = Duration::from_secs(3);
const DOH_QUERY_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_DNS_MESSAGE: usize = u16::MAX as usize;
const DOH_ENDPOINTS: [Ipv4Addr; 2] = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(8, 8, 8, 8)];
const IP_RECVORIGDSTADDR: libc::c_int = 20;
const IPV6_RECVORIGDSTADDR: libc::c_int = 74;

static DOH_GENERATION: AtomicU64 = AtomicU64::new(1);
static UDP_ASSOCIATION_GENERATION: AtomicU64 = AtomicU64::new(1);

type UdpErrorLog = Arc<Mutex<Instant>>;

#[derive(Clone)]
struct DohEntry {
    generation: u64,
    sender: h2::client::SendRequest<Bytes>,
}

type DohPool = Arc<Mutex<HashMap<String, DohEntry>>>;
type DohConnectGates = Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>;

#[derive(Clone, Copy)]
enum AddressFamily {
    V4,
    V6,
}

impl AddressFamily {
    fn label(self) -> &'static str {
        match self {
            Self::V4 => "ipv4",
            Self::V6 => "ipv6",
        }
    }
}

#[derive(Clone)]
struct PeerCacheEntry {
    rule: Option<LocationRule>,
    expires_at: Instant,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct UdpAssociationKey {
    client: SocketAddr,
    rule_id: String,
}

struct UdpAssociationEntry {
    generation: u64,
    sender: mpsc::Sender<UdpRequest>,
    last_used: Instant,
}

type UdpAssociations = Arc<Mutex<HashMap<UdpAssociationKey, UdpAssociationEntry>>>;

struct UdpRequest {
    destination: SocketAddr,
    payload: Vec<u8>,
}

struct UdpReplySocketEntry {
    socket: Arc<UdpSocket>,
    last_used: Instant,
}

type UdpReplySockets = Arc<Mutex<HashMap<SocketAddr, UdpReplySocketEntry>>>;

struct DnsQuestion {
    id: u16,
    name: String,
    qtype: u16,
}

struct DnsResponseSummary {
    rcode: u8,
    answer_count: u16,
    answers: Vec<String>,
}

struct DnsDebugContext {
    transport: &'static str,
    client: SocketAddr,
    destination: SocketAddr,
    rule_id: String,
    outbound: &'static str,
    question: Option<DnsQuestion>,
    parse_error: Option<String>,
}

impl DnsDebugContext {
    fn new(
        transport: &'static str,
        client: SocketAddr,
        destination: SocketAddr,
        rule_id: &str,
        outbound: &OutboundProxy,
        query: &[u8],
    ) -> Self {
        let (question, parse_error) = match dns_question(query) {
            Ok(question) => (Some(question), None),
            Err(error) => (None, Some(error)),
        };
        Self {
            transport,
            client,
            destination,
            rule_id: rule_id.to_owned(),
            outbound: outbound.label(),
            question,
            parse_error,
        }
    }

    fn context(&self) -> String {
        if let Some(question) = self.question.as_ref() {
            format!(
                "transport={} client={} destination={} rule={} outbound={} id={} name={} type={} qtype={}",
                self.transport,
                self.client,
                self.destination,
                self.rule_id,
                self.outbound,
                question.id,
                question.name,
                dns_type_label(question.qtype),
                question.qtype
            )
        } else {
            format!(
                "transport={} client={} destination={} rule={} outbound={} id=unknown name=unknown type=unknown parse_error={:?}",
                self.transport,
                self.client,
                self.destination,
                self.rule_id,
                self.outbound,
                self.parse_error.as_deref().unwrap_or("unknown")
            )
        }
    }

    fn log_query(&self) {
        eprintln!("wlocd: debug=dns event=query {} action=doh", self.context());
    }

    fn log_endpoint(&self, endpoint: Ipv4Addr, result: &str, error: Option<&str>) {
        if let Some(error) = error {
            eprintln!(
                "wlocd: debug=dns event=endpoint {} endpoint={endpoint} result={result} error={error:?}",
                self.context()
            );
        } else {
            eprintln!(
                "wlocd: debug=dns event=endpoint {} endpoint={endpoint} result={result}",
                self.context()
            );
        }
    }

    fn log_result(&self, endpoint: Ipv4Addr, response: &[u8]) {
        match dns_response_summary(response) {
            Ok(summary) => {
                let answers = if summary.answers.is_empty() {
                    "none".to_owned()
                } else {
                    summary.answers.join(",")
                };
                eprintln!(
                    "wlocd: debug=dns event=result {} endpoint={endpoint} result=ok rcode={} answer_count={} answers={} bytes={}",
                    self.context(),
                    dns_rcode_label(summary.rcode),
                    summary.answer_count,
                    answers,
                    response.len()
                );
            }
            Err(error) => eprintln!(
                "wlocd: debug=dns event=result {} endpoint={endpoint} result=ok rcode=unknown answers=unparsed bytes={} parse_error={error:?}",
                self.context(),
                response.len()
            ),
        }
    }

    fn log_failure(&self, error: &str) {
        eprintln!(
            "wlocd: debug=dns event=result {} result=failed error={error:?}",
            self.context()
        );
    }
}

#[derive(Clone)]
pub struct TransparentProxy {
    rules: Vec<LocationRule>,
    arp_path: PathBuf,
    dhcp_leases_path: PathBuf,
    peer_cache: Arc<Mutex<HashMap<IpAddr, PeerCacheEntry>>>,
    network_source: HostapdNetworkSource,
    udp_associations: UdpAssociations,
    udp_dispatch: Arc<Semaphore>,
    dns_dispatch: Arc<Semaphore>,
    udp_reply_sockets: UdpReplySockets,
    udp_error_log: UdpErrorLog,
    doh_pool: DohPool,
    doh_connect_gates: DohConnectGates,
    debug_log: bool,
}

impl TransparentProxy {
    pub fn new(rules: Vec<LocationRule>) -> Self {
        let now = Instant::now();
        let log_start = now.checked_sub(UDP_ERROR_LOG_INTERVAL).unwrap_or(now);
        Self {
            rules,
            arp_path: std::env::var_os("WLOC_ARP_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/proc/net/arp")),
            dhcp_leases_path: std::env::var_os("WLOC_DHCP_LEASES_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp/dhcp.leases")),
            peer_cache: Arc::new(Mutex::new(HashMap::new())),
            network_source: HostapdNetworkSource::new(),
            udp_associations: Arc::new(Mutex::new(HashMap::new())),
            udp_dispatch: Arc::new(Semaphore::new(UDP_DISPATCH_LIMIT)),
            dns_dispatch: Arc::new(Semaphore::new(DNS_DISPATCH_LIMIT)),
            udp_reply_sockets: Arc::new(Mutex::new(HashMap::new())),
            udp_error_log: Arc::new(Mutex::new(log_start)),
            doh_pool: Arc::new(Mutex::new(HashMap::new())),
            doh_connect_gates: Arc::new(Mutex::new(HashMap::new())),
            debug_log: std::env::var("WLOC_DEBUG_LOG").as_deref() == Ok("1"),
        }
    }

    async fn target_for(&self, peer: IpAddr) -> Result<Option<LocationRule>, String> {
        let now = Instant::now();
        {
            let mut cache = self.peer_cache.lock().await;
            cache.retain(|_, entry| entry.expires_at > now);
            if let Some(entry) = cache.get(&peer).cloned() {
                return Ok(entry.rule);
            }
        }

        let arp_path = self.arp_path.clone();
        let dhcp_leases_path = self.dhcp_leases_path.clone();
        let mac = tokio::task::spawn_blocking(move || {
            neighbor_mac_for(&arp_path, &dhcp_leases_path, peer)
        })
        .await
        .map_err(|error| format!("neighbor lookup task failed: {error}"))?;

        let rule = if let Some(mac) = mac {
            self.network_source
                .current_for(mac)
                .await?
                .and_then(|access_point| {
                    self.rules
                        .iter()
                        .find(|rule| rule.iface == access_point.iface)
                        .cloned()
                })
        } else {
            None
        };

        let mut cache = self.peer_cache.lock().await;
        cache.retain(|_, entry| entry.expires_at > Instant::now());
        if cache.len() >= PEER_CACHE_MAX {
            if let Some(key) = cache.keys().next().copied() {
                cache.remove(&key);
            }
        }
        cache.insert(
            peer,
            PeerCacheEntry {
                rule: rule.clone(),
                expires_at: Instant::now() + PEER_CACHE_TTL,
            },
        );
        Ok(rule)
    }

    pub async fn handle_tcp(&self, mut client: TcpStream) -> Result<(), String> {
        let peer = client.peer_addr().map_err(io_message)?;
        let destination = client.local_addr().map_err(io_message)?;
        client.set_nodelay(true).map_err(io_message)?;
        let rule = self
            .target_for(peer.ip())
            .await?
            .ok_or_else(|| format!("no matching WLOC rule for client {peer}"))?;
        let rule_id = rule.id;
        let outbound = rule.outbound;

        if destination.port() == 53 {
            return handle_dns_tcp(
                &mut client,
                peer,
                destination,
                &rule_id,
                &outbound,
                self.debug_log,
                &self.doh_pool,
                &self.doh_connect_gates,
            )
            .await;
        }

        let mut upstream = tokio::time::timeout(
            CONNECT_TIMEOUT,
            connect_tcp_outbound(&outbound, destination),
        )
        .await
        .map_err(|_| "transparent TCP connect timed out".to_owned())??;

        tokio::io::copy_bidirectional(&mut client, &mut upstream)
            .await
            .map_err(io_message)?;
        Ok(())
    }

    pub async fn run_udp(self: Arc<Self>, socket: UdpSocket) -> io::Result<()> {
        let family = match socket.local_addr()? {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        };
        let mut buffer = vec![0_u8; 65_535];
        loop {
            let (size, client, destination) = match recv_original_datagram(&socket, family, &mut buffer).await {
                Ok(packet) => packet,
                Err(error) => {
                    if error_log_allowed(&self.udp_error_log).await {
                        eprintln!(
                            "wlocd: udp_receive=failed family={} recovery=continue error={error}",
                            family.label()
                        );
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    continue;
                }
            };
            let limiter = if destination.port() == 53 {
                Arc::clone(&self.dns_dispatch)
            } else {
                Arc::clone(&self.udp_dispatch)
            };
            let permit = match limiter.try_acquire_owned() {
                Ok(permit) => permit,
                Err(_) => {
                    if error_log_allowed(&self.udp_error_log).await {
                        eprintln!(
                            "wlocd: udp_dispatch=full client={client} destination={destination} recovery=drop"
                        );
                    }
                    continue;
                }
            };
            let payload = buffer[..size].to_vec();
            let proxy = Arc::clone(&self);
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = proxy
                    .handle_udp_datagram(client, destination, payload)
                    .await
                {
                    if error_log_allowed(&proxy.udp_error_log).await {
                        eprintln!(
                            "wlocd: udp=failed client={client} destination={destination} error={error}"
                        );
                    }
                }
            });
        }
    }

    async fn handle_udp_datagram(
        &self,
        client: SocketAddr,
        destination: SocketAddr,
        payload: Vec<u8>,
    ) -> Result<(), String> {
        let rule = self
            .target_for(client.ip())
            .await?
            .ok_or_else(|| format!("no matching WLOC rule for client {client}"))?;
        let rule_id = rule.id;
        let outbound = rule.outbound;

        if destination.port() == 53 {
            let debug = if self.debug_log {
                Some(DnsDebugContext::new(
                    "udp",
                    client,
                    destination,
                    &rule_id,
                    &outbound,
                    &payload,
                ))
            } else {
                None
            };
            if let Some(debug) = debug.as_ref() {
                debug.log_query();
            }
            let (response, endpoint) = match doh_query(
                &self.doh_pool,
                &self.doh_connect_gates,
                &outbound,
                &payload,
                debug.as_ref(),
            )
            .await
            {
                Ok(result) => result,
                Err(error) => {
                    if let Some(debug) = debug.as_ref() {
                        debug.log_failure(&error);
                    }
                    return Err(error);
                }
            };
            if let Some(debug) = debug.as_ref() {
                debug.log_result(endpoint, &response);
            }
            send_spoofed_udp(&self.udp_reply_sockets, destination, client, &response)
                .await
                .map_err(io_message)?;
            return Ok(());
        }

        let key = UdpAssociationKey { client, rule_id };
        let mut request = UdpRequest {
            destination,
            payload,
        };

        for _ in 0..2 {
            let (sender, generation) = {
                let mut associations = self.udp_associations.lock().await;
                let now = Instant::now();
                if let Some(entry) = associations.get_mut(&key) {
                    entry.last_used = now;
                    (entry.sender.clone(), entry.generation)
                } else {
                    if associations.len() >= UDP_ASSOCIATION_MAX {
                        if let Some(oldest) = associations
                            .iter()
                            .min_by_key(|(_, entry)| entry.last_used)
                            .map(|(key, _)| key.clone())
                        {
                            associations.remove(&oldest);
                        }
                    }
                    let generation = UDP_ASSOCIATION_GENERATION.fetch_add(1, Ordering::Relaxed);
                    let (sender, receiver) = mpsc::channel(UDP_ASSOCIATION_QUEUE);
                    associations.insert(
                        key.clone(),
                        UdpAssociationEntry {
                            generation,
                            sender: sender.clone(),
                            last_used: now,
                        },
                    );
                    let association_key = key.clone();
                    let associations = Arc::clone(&self.udp_associations);
                    let association_outbound = outbound.clone();
                    let reply_sockets = Arc::clone(&self.udp_reply_sockets);
                    let error_log = Arc::clone(&self.udp_error_log);
                    tokio::spawn(async move {
                        let result = run_udp_association(
                            client,
                            association_outbound,
                            reply_sockets,
                            receiver,
                        )
                        .await;
                        remove_udp_association(&associations, &association_key, generation).await;
                        if let Err(error) = result {
                            if error_log_allowed(&error_log).await {
                                eprintln!(
                                    "wlocd: udp_association=failed client={client} rule={} error={error}",
                                    association_key.rule_id
                                );
                            }
                        }
                    });
                    (sender, generation)
                }
            };

            match sender.try_send(request) {
                Ok(()) => return Ok(()),
                Err(mpsc::error::TrySendError::Full(_)) => {
                    return Err("UDP association queue full".into());
                }
                Err(mpsc::error::TrySendError::Closed(returned)) => {
                    request = returned;
                    remove_udp_association(&self.udp_associations, &key, generation).await;
                }
            }
        }
        Err("unable to queue UDP datagram".into())
    }
}

async fn remove_udp_association(
    associations: &UdpAssociations,
    key: &UdpAssociationKey,
    generation: u64,
) {
    let mut associations = associations.lock().await;
    if associations
        .get(key)
        .is_some_and(|entry| entry.generation == generation)
    {
        associations.remove(key);
    }
}

async fn error_log_allowed(last_log: &UdpErrorLog) -> bool {
    let mut last = last_log.lock().await;
    let now = Instant::now();
    if now.duration_since(*last) < UDP_ERROR_LOG_INTERVAL {
        return false;
    }
    *last = now;
    true
}

async fn handle_dns_tcp(
    client: &mut TcpStream,
    client_address: SocketAddr,
    destination: SocketAddr,
    rule_id: &str,
    outbound: &OutboundProxy,
    debug_log: bool,
    pool: &DohPool,
    connect_gates: &DohConnectGates,
) -> Result<(), String> {
    loop {
        let mut length = [0_u8; 2];
        let length_read = tokio::time::timeout(DNS_TCP_IDLE_TIMEOUT, client.read_exact(&mut length))
            .await
            .map_err(|_| "TCP DNS idle timed out".to_owned())?;
        if let Err(error) = length_read {
            if error.kind() == io::ErrorKind::UnexpectedEof {
                return Ok(());
            }
            return Err(io_message(error));
        }
        let query_len = usize::from(u16::from_be_bytes(length));
        if query_len == 0 {
            return Err("empty TCP DNS query".into());
        }
        let mut query = vec![0_u8; query_len];
        tokio::time::timeout(DNS_TCP_IDLE_TIMEOUT, client.read_exact(&mut query))
            .await
            .map_err(|_| "TCP DNS query timed out".to_owned())?
            .map_err(io_message)?;
        let debug = if debug_log {
            Some(DnsDebugContext::new(
                "tcp",
                client_address,
                destination,
                rule_id,
                outbound,
                &query,
            ))
        } else {
            None
        };
        if let Some(debug) = debug.as_ref() {
            debug.log_query();
        }
        let (response, endpoint) = match doh_query(
            pool,
            connect_gates,
            outbound,
            &query,
            debug.as_ref(),
        )
        .await
        {
            Ok(result) => result,
            Err(error) => {
                if let Some(debug) = debug.as_ref() {
                    debug.log_failure(&error);
                }
                return Err(error);
            }
        };
        if let Some(debug) = debug.as_ref() {
            debug.log_result(endpoint, &response);
        }
        let response_len = u16::try_from(response.len())
            .map_err(|_| "DoH response exceeds TCP DNS framing limit".to_owned())?;
        tokio::time::timeout(
            DNS_TCP_IDLE_TIMEOUT,
            client.write_all(&response_len.to_be_bytes()),
        )
        .await
        .map_err(|_| "TCP DNS response timed out".to_owned())?
        .map_err(io_message)?;
        tokio::time::timeout(DNS_TCP_IDLE_TIMEOUT, client.write_all(&response))
            .await
            .map_err(|_| "TCP DNS response timed out".to_owned())?
            .map_err(io_message)?;
    }
}

async fn doh_query(
    pool: &DohPool,
    connect_gates: &DohConnectGates,
    outbound: &OutboundProxy,
    query: &[u8],
    debug: Option<&DnsDebugContext>,
) -> Result<(Vec<u8>, Ipv4Addr), String> {
    validate_dns_message(query, "query")?;
    let deadline = Instant::now() + DOH_QUERY_TIMEOUT;
    let mut last_error = String::new();

    for endpoint in DOH_ENDPOINTS {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        let endpoint_timeout = remaining.min(DOH_ENDPOINT_TIMEOUT);
        match doh_query_endpoint(
            pool,
            connect_gates,
            outbound,
            endpoint,
            query,
            endpoint_timeout,
        )
        .await
        {
            Ok(response) if dns_servfail(&response) => {
                if let Some(debug) = debug {
                    debug.log_endpoint(endpoint, "servfail", None);
                }
                last_error = format!("{endpoint} returned SERVFAIL");
            }
            Ok(response) => return Ok((response, endpoint)),
            Err(error) => {
                if let Some(debug) = debug {
                    debug.log_endpoint(endpoint, "failed", Some(&error));
                }
                last_error = format!("{endpoint}: {error}");
            }
        }
    }

    if last_error.is_empty() {
        Err("DoH query timed out".to_owned())
    } else {
        Err(format!("DoH query failed: {last_error}"))
    }
}

async fn doh_connect_gate(connect_gates: &DohConnectGates, key: &str) -> Arc<Mutex<()>> {
    let mut gates = connect_gates.lock().await;
    Arc::clone(
        gates
            .entry(key.to_owned())
            .or_insert_with(|| Arc::new(Mutex::new(()))),
    )
}

async fn doh_query_endpoint(
    pool: &DohPool,
    connect_gates: &DohConnectGates,
    outbound: &OutboundProxy,
    endpoint: Ipv4Addr,
    query: &[u8],
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let key = outbound.pool_key(&format!("doh:{endpoint}"));
    let mut active_generation = None;
    let result = tokio::time::timeout(timeout, async {
        if let Some(entry) = pool.lock().await.get(&key).cloned() {
            active_generation = Some(entry.generation);
            match doh_exchange(entry.sender, endpoint, query).await {
                Ok(response) => return Ok(response),
                Err(_) => {
                    remove_doh_generation(pool, &key, entry.generation).await;
                    active_generation = None;
                }
            }
        }

        let connect_gate = doh_connect_gate(connect_gates, &key).await;
        let connect_guard = connect_gate.lock().await;
        if let Some(entry) = pool.lock().await.get(&key).cloned() {
            active_generation = Some(entry.generation);
            drop(connect_guard);
            match doh_exchange(entry.sender, endpoint, query).await {
                Ok(response) => return Ok(response),
                Err(error) => {
                    remove_doh_generation(pool, &key, entry.generation).await;
                    active_generation = None;
                    return Err(error);
                }
            }
        }

        let destination = SocketAddr::V4(SocketAddrV4::new(endpoint, 443));
        let tcp = connect_tcp_outbound(outbound, destination).await?;
        let server_name = rustls::pki_types::ServerName::try_from(endpoint.to_string())
            .map_err(|_| "invalid DoH TLS server name".to_owned())?;
        let tls = doh_connector()
            .connect(server_name, tcp)
            .await
            .map_err(|error| format!("DoH TLS failed: {error}"))?;
        if tls.get_ref().1.alpn_protocol() != Some(b"h2") {
            return Err("DoH endpoint did not negotiate HTTP/2".into());
        }

        let (sender, connection) = h2::client::Builder::new()
            .initial_window_size(64 * 1024)
            .max_frame_size(16 * 1024)
            .max_header_list_size(32 * 1024)
            .handshake::<_, Bytes>(tls)
            .await
            .map_err(|error| format!("DoH HTTP/2 handshake failed: {error}"))?;
        let generation = DOH_GENERATION.fetch_add(1, Ordering::Relaxed);
        {
            let mut connections = pool.lock().await;
            if connections.len() >= DOH_POOL_MAX && !connections.contains_key(&key) {
                if let Some(oldest) = connections.keys().next().cloned() {
                    connections.remove(&oldest);
                }
            }
            connections.insert(
                key.clone(),
                DohEntry {
                    generation,
                    sender: sender.clone(),
                },
            );
        }
        active_generation = Some(generation);
        drop(connect_guard);
        let driver_pool = Arc::clone(pool);
        let driver_key = key.clone();
        tokio::spawn(async move {
            let _ = connection.await;
            remove_doh_generation(&driver_pool, &driver_key, generation).await;
        });
        match doh_exchange(sender, endpoint, query).await {
            Ok(response) => Ok(response),
            Err(error) => {
                remove_doh_generation(pool, &key, generation).await;
                active_generation = None;
                Err(error)
            }
        }
    })
    .await;

    match result {
        Ok(result) => result,
        Err(_) => {
            if let Some(generation) = active_generation {
                remove_doh_generation(pool, &key, generation).await;
            }
            Err("DoH request timed out".to_owned())
        }
    }
}

async fn remove_doh_generation(pool: &DohPool, key: &str, generation: u64) {
    let mut connections = pool.lock().await;
    if connections
        .get(key)
        .is_some_and(|entry| entry.generation == generation)
    {
        connections.remove(key);
    }
}

async fn doh_exchange(
    sender: h2::client::SendRequest<Bytes>,
    endpoint: Ipv4Addr,
    query: &[u8],
) -> Result<Vec<u8>, String> {
    let mut sender = sender
        .ready()
        .await
        .map_err(|error| format!("DoH HTTP/2 connection failed: {error}"))?;
    let uri = format!("https://{endpoint}/dns-query")
        .parse::<Uri>()
        .map_err(|error| format!("invalid DoH URI: {error}"))?;
    let request = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header(http::header::CONTENT_TYPE, "application/dns-message")
        .header(http::header::ACCEPT, "application/dns-message")
        .body(())
        .map_err(|error| format!("invalid DoH HTTP/2 request: {error}"))?;
    let (response, mut send) = sender
        .send_request(request, false)
        .map_err(|error| format!("DoH HTTP/2 request failed: {error}"))?;
    send_doh_h2_data(&mut send, query).await?;

    let mut response = response
        .await
        .map_err(|error| format!("DoH HTTP/2 response failed: {error}"))?;
    if response.status() != StatusCode::OK {
        return Err(format!("DoH HTTP status {}", response.status().as_u16()));
    }
    let content_type = response
        .headers()
        .get(http::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim)
        .unwrap_or("");
    if !content_type.eq_ignore_ascii_case("application/dns-message") {
        return Err(format!("DoH response content type is {content_type:?}"));
    }

    let mut body = Vec::new();
    while let Some(chunk) = response.body_mut().data().await {
        let chunk = chunk.map_err(|error| format!("DoH HTTP/2 body failed: {error}"))?;
        if body.len().saturating_add(chunk.len()) > MAX_DNS_MESSAGE {
            return Err("DNS response exceeds 65535 bytes".into());
        }
        body.extend_from_slice(&chunk);
        response
            .body_mut()
            .flow_control()
            .release_capacity(chunk.len())
            .map_err(|error| format!("DoH HTTP/2 flow control failed: {error}"))?;
    }
    validate_dns_message(&body, "response")?;
    if body[..2] != query[..2] {
        return Err("DoH response transaction ID mismatch".into());
    }
    Ok(body)
}

async fn send_doh_h2_data(
    sender: &mut h2::SendStream<Bytes>,
    body: &[u8],
) -> Result<(), String> {
    let mut offset = 0;
    while offset < body.len() {
        sender.reserve_capacity((body.len() - offset).min(16 * 1024));
        let capacity = std::future::poll_fn(|context| sender.poll_capacity(context))
            .await
            .ok_or_else(|| "DoH HTTP/2 stream closed while sending request".to_owned())?
            .map_err(|error| format!("DoH HTTP/2 send failed: {error}"))?;
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
            .map_err(|error| format!("DoH HTTP/2 send failed: {error}"))?;
        offset += count;
    }
    Ok(())
}

fn doh_connector() -> TlsConnector {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    let config = CONFIG.get_or_init(|| {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let versions = [&rustls::version::TLS13, &rustls::version::TLS12];
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&versions)
            .expect("built-in TLS versions are supported")
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec()];
        Arc::new(config)
    });
    TlsConnector::from(Arc::clone(config))
}

fn validate_dns_message(message: &[u8], kind: &str) -> Result<(), String> {
    if message.len() < 12 {
        return Err(format!("DNS {kind} is shorter than the header"));
    }
    if message.len() > MAX_DNS_MESSAGE {
        return Err(format!("DNS {kind} exceeds 65535 bytes"));
    }
    Ok(())
}

fn dns_u16(message: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = message
        .get(offset..offset + 2)
        .ok_or_else(|| "DNS field exceeds message length".to_owned())?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn dns_name(message: &[u8], offset: &mut usize) -> Result<String, String> {
    let mut cursor = *offset;
    let mut resume = None;
    let mut jumps = 0usize;
    let mut name = String::new();

    loop {
        let length = *message
            .get(cursor)
            .ok_or_else(|| "DNS name exceeds message length".to_owned())?;
        if length & 0xc0 == 0xc0 {
            let next = *message
                .get(cursor + 1)
                .ok_or_else(|| "DNS compression pointer is truncated".to_owned())?;
            let pointer = (usize::from(length & 0x3f) << 8) | usize::from(next);
            if pointer >= message.len() {
                return Err("DNS compression pointer is out of range".into());
            }
            if resume.is_none() {
                resume = Some(cursor + 2);
            }
            cursor = pointer;
            jumps += 1;
            if jumps > 16 {
                return Err("DNS compression pointer loop".into());
            }
            continue;
        }
        if length & 0xc0 != 0 {
            return Err("invalid DNS label length".into());
        }
        cursor += 1;
        if length == 0 {
            *offset = resume.unwrap_or(cursor);
            return Ok(if name.is_empty() { ".".into() } else { name });
        }
        let end = cursor
            .checked_add(usize::from(length))
            .filter(|end| *end <= message.len())
            .ok_or_else(|| "DNS label exceeds message length".to_owned())?;
        if !name.is_empty() {
            name.push('.');
        }
        for byte in &message[cursor..end] {
            let character = if byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_') {
                char::from(*byte).to_ascii_lowercase()
            } else {
                '?'
            };
            name.push(character);
        }
        if name.len() > 253 {
            return Err("DNS name exceeds 253 characters".into());
        }
        cursor = end;
    }
}

fn dns_question(message: &[u8]) -> Result<DnsQuestion, String> {
    validate_dns_message(message, "query")?;
    if dns_u16(message, 4)? == 0 {
        return Err("DNS query has no question".into());
    }
    let id = dns_u16(message, 0)?;
    let mut offset = 12usize;
    let name = dns_name(message, &mut offset)?;
    let qtype = dns_u16(message, offset)?;
    let _qclass = dns_u16(message, offset + 2)?;
    Ok(DnsQuestion { id, name, qtype })
}

fn dns_response_summary(message: &[u8]) -> Result<DnsResponseSummary, String> {
    validate_dns_message(message, "response")?;
    let rcode = message[3] & 0x0f;
    let question_count = dns_u16(message, 4)?;
    let answer_count = dns_u16(message, 6)?;
    let mut offset = 12usize;

    for _ in 0..question_count {
        let _ = dns_name(message, &mut offset)?;
        offset = offset
            .checked_add(4)
            .filter(|offset| *offset <= message.len())
            .ok_or_else(|| "DNS question exceeds message length".to_owned())?;
    }

    let mut answers = Vec::new();
    for _ in 0..usize::from(answer_count).min(64) {
        let _ = dns_name(message, &mut offset)?;
        let rr_type = dns_u16(message, offset)?;
        let class = dns_u16(message, offset + 2)?;
        offset = offset
            .checked_add(8)
            .filter(|offset| *offset <= message.len())
            .ok_or_else(|| "DNS answer header exceeds message length".to_owned())?;
        let rdlength = usize::from(dns_u16(message, offset)?);
        offset += 2;
        let rdata_start = offset;
        let rdata_end = rdata_start
            .checked_add(rdlength)
            .filter(|end| *end <= message.len())
            .ok_or_else(|| "DNS answer data exceeds message length".to_owned())?;

        if answers.len() < 4 && class == 1 {
            match (rr_type, rdlength) {
                (1, 4) => answers.push(
                    Ipv4Addr::new(
                        message[rdata_start],
                        message[rdata_start + 1],
                        message[rdata_start + 2],
                        message[rdata_start + 3],
                    )
                    .to_string(),
                ),
                (28, 16) => {
                    let mut octets = [0_u8; 16];
                    octets.copy_from_slice(&message[rdata_start..rdata_end]);
                    answers.push(Ipv6Addr::from(octets).to_string());
                }
                (5, _) => {
                    let mut cname_offset = rdata_start;
                    if let Ok(cname) = dns_name(message, &mut cname_offset) {
                        answers.push(format!("cname:{cname}"));
                    }
                }
                _ => {}
            }
        }
        offset = rdata_end;
    }

    Ok(DnsResponseSummary {
        rcode,
        answer_count,
        answers,
    })
}

fn dns_type_label(qtype: u16) -> &'static str {
    match qtype {
        1 => "A",
        2 => "NS",
        5 => "CNAME",
        6 => "SOA",
        12 => "PTR",
        15 => "MX",
        16 => "TXT",
        28 => "AAAA",
        33 => "SRV",
        64 => "SVCB",
        65 => "HTTPS",
        255 => "ANY",
        _ => "OTHER",
    }
}

fn dns_rcode_label(rcode: u8) -> &'static str {
    match rcode {
        0 => "NOERROR",
        1 => "FORMERR",
        2 => "SERVFAIL",
        3 => "NXDOMAIN",
        4 => "NOTIMP",
        5 => "REFUSED",
        9 => "NOTAUTH",
        10 => "NOTZONE",
        _ => "OTHER",
    }
}

fn dns_servfail(message: &[u8]) -> bool {
    message.len() >= 4 && message[3] & 0x0f == 2
}

pub fn udp_listeners(port: u16) -> io::Result<(UdpSocket, UdpSocket)> {
    Ok((udp_listener_v4(port)?, udp_listener_v6(port)?))
}

fn udp_listener_v4(port: u16) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v4(true)?;
    let enabled: libc::c_int = 1;
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_IP,
            IP_RECVORIGDSTADDR,
            (&enabled as *const libc::c_int).cast(),
            std::mem::size_of_val(&enabled) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

fn udp_listener_v6(port: u16) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    socket.set_only_v6(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v6(true)?;
    let enabled: libc::c_int = 1;
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_IPV6,
            IPV6_RECVORIGDSTADDR,
            (&enabled as *const libc::c_int).cast(),
            std::mem::size_of_val(&enabled) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    socket.bind(&SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0).into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

async fn recv_original_datagram(
    socket: &UdpSocket,
    family: AddressFamily,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddr, SocketAddr)> {
    loop {
        socket.readable().await?;
        let result = socket.try_io(tokio::io::Interest::READABLE, || match family {
            AddressFamily::V4 => recv_original_datagram_v4_now(socket, buffer),
            AddressFamily::V6 => recv_original_datagram_v6_now(socket, buffer),
        });
        match result {
            Ok(result) => return Ok(result),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
            Err(error) => return Err(error),
        }
    }
}

fn recv_original_datagram_v4_now(
    socket: &UdpSocket,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddr, SocketAddr)> {
    let mut source: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    let mut iovec = libc::iovec {
        iov_base: buffer.as_mut_ptr().cast(),
        iov_len: buffer.len(),
    };
    let mut control = [0_usize; 16];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_name = (&mut source as *mut libc::sockaddr_in).cast();
    message.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
    message.msg_iov = &mut iovec;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = std::mem::size_of_val(&control) as libc::socklen_t;

    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, 0) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    if message.msg_flags & libc::MSG_TRUNC != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "UDP datagram truncated"));
    }
    let client = SocketAddr::V4(raw_socket_v4(source)?);
    let mut destination = None;
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let current = unsafe { &*header };
        if current.cmsg_level == libc::SOL_IP && current.cmsg_type == IP_RECVORIGDSTADDR {
            let raw = unsafe { *(libc::CMSG_DATA(header) as *const libc::sockaddr_in) };
            destination = Some(SocketAddr::V4(raw_socket_v4(raw)?));
            break;
        }
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }
    let destination = destination.ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "original UDP destination is unavailable")
    })?;
    Ok((size as usize, client, destination))
}

fn recv_original_datagram_v6_now(
    socket: &UdpSocket,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddr, SocketAddr)> {
    let mut source: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
    let mut iovec = libc::iovec {
        iov_base: buffer.as_mut_ptr().cast(),
        iov_len: buffer.len(),
    };
    let mut control = [0_usize; 32];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_name = (&mut source as *mut libc::sockaddr_in6).cast();
    message.msg_namelen = std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t;
    message.msg_iov = &mut iovec;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = std::mem::size_of_val(&control) as libc::socklen_t;

    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, 0) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    if message.msg_flags & libc::MSG_TRUNC != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "UDP datagram truncated"));
    }
    let client = SocketAddr::V6(raw_socket_v6(source)?);
    let mut destination = None;
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let current = unsafe { &*header };
        if current.cmsg_level == libc::SOL_IPV6
            && current.cmsg_type == IPV6_RECVORIGDSTADDR
        {
            let raw = unsafe { *(libc::CMSG_DATA(header) as *const libc::sockaddr_in6) };
            destination = Some(SocketAddr::V6(raw_socket_v6(raw)?));
            break;
        }
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }
    let destination = destination.ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "original IPv6 UDP destination is unavailable")
    })?;
    Ok((size as usize, client, destination))
}

async fn run_udp_association(
    client: SocketAddr,
    outbound: OutboundProxy,
    reply_sockets: UdpReplySockets,
    receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    match outbound {
        OutboundProxy::Direct => run_direct_udp_association(client, reply_sockets, receiver).await,
        OutboundProxy::Socks5 { host, port } => {
            run_socks_udp_association(client, &host, port, reply_sockets, receiver).await
        }
    }
}

async fn run_direct_udp_association(
    client: SocketAddr,
    reply_sockets: UdpReplySockets,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let upstream = UdpSocket::bind(unspecified_for(client)).await.map_err(io_message)?;
    let mut buffer = vec![0_u8; 65_535];
    let idle = tokio::time::sleep(UDP_IDLE_TIMEOUT);
    tokio::pin!(idle);

    loop {
        tokio::select! {
            request = receiver.recv() => {
                let Some(request) = request else { return Ok(()); };
                upstream.send_to(&request.payload, request.destination).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            response = upstream.recv_from(&mut buffer) => {
                let (size, source) = response.map_err(io_message)?;
                send_spoofed_udp(&reply_sockets, source, client, &buffer[..size]).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn run_socks_udp_association(
    client: SocketAddr,
    host: &str,
    port: u16,
    reply_sockets: UdpReplySockets,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let (control, relay) = tokio::time::timeout(CONNECT_TIMEOUT, socks5_udp_associate(host, port))
        .await
        .map_err(|_| "SOCKS5 UDP association timed out".to_owned())??;
    let _control = control;
    let upstream = UdpSocket::bind(unspecified_for(relay)).await.map_err(io_message)?;
    upstream.connect(relay).await.map_err(io_message)?;
    let mut buffer = vec![0_u8; 65_535];
    let idle = tokio::time::sleep(UDP_IDLE_TIMEOUT);
    tokio::pin!(idle);

    loop {
        tokio::select! {
            request = receiver.recv() => {
                let Some(request) = request else { return Ok(()); };
                let packet = encode_socks_udp(request.destination, &request.payload);
                upstream.send(&packet).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            response = upstream.recv(&mut buffer) => {
                let size = response.map_err(io_message)?;
                let (source, payload) = decode_socks_udp(&buffer[..size])?;
                send_spoofed_udp(&reply_sockets, source, client, payload).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn socks5_udp_associate(host: &str, port: u16) -> Result<(TcpStream, SocketAddr), String> {
    let mut control = TcpStream::connect((host, port)).await.map_err(io_message)?;
    control.set_nodelay(true).map_err(io_message)?;
    control.write_all(&[0x05, 0x01, 0x00]).await.map_err(io_message)?;
    let mut greeting = [0_u8; 2];
    control.read_exact(&mut greeting).await.map_err(io_message)?;
    if greeting != [0x05, 0x00] {
        return Err("SOCKS5 proxy requires unsupported authentication".into());
    }
    control
        .write_all(&[0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
        .map_err(io_message)?;
    let mut reply = [0_u8; 4];
    control.read_exact(&mut reply).await.map_err(io_message)?;
    if reply[0] != 0x05 || reply[1] != 0x00 {
        return Err(format!("SOCKS5 UDP ASSOCIATE failed with code {}", reply[1]));
    }
    let mut relay = read_socks_socket_addr(&mut control, reply[3]).await?;
    if relay.ip().is_unspecified() {
        relay = SocketAddr::new(control.peer_addr().map_err(io_message)?.ip(), relay.port());
    }
    Ok((control, relay))
}

async fn read_socks_socket_addr(stream: &mut TcpStream, atyp: u8) -> Result<SocketAddr, String> {
    let ip = match atyp {
        0x01 => {
            let mut address = [0_u8; 4];
            stream.read_exact(&mut address).await.map_err(io_message)?;
            IpAddr::V4(Ipv4Addr::from(address))
        }
        0x04 => {
            let mut address = [0_u8; 16];
            stream.read_exact(&mut address).await.map_err(io_message)?;
            IpAddr::V6(Ipv6Addr::from(address))
        }
        0x03 => return Err("SOCKS5 UDP relay returned a domain address".into()),
        _ => return Err("invalid SOCKS5 address type".into()),
    };
    let mut port_bytes = [0_u8; 2];
    stream.read_exact(&mut port_bytes).await.map_err(io_message)?;
    Ok(SocketAddr::new(ip, u16::from_be_bytes(port_bytes)))
}

fn encode_socks_udp(destination: SocketAddr, payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::with_capacity(payload.len() + 22);
    packet.extend_from_slice(&[0x00, 0x00, 0x00]);
    match destination {
        SocketAddr::V4(address) => {
            packet.push(0x01);
            packet.extend_from_slice(&address.ip().octets());
        }
        SocketAddr::V6(address) => {
            packet.push(0x04);
            packet.extend_from_slice(&address.ip().octets());
        }
    }
    packet.extend_from_slice(&destination.port().to_be_bytes());
    packet.extend_from_slice(payload);
    packet
}

fn decode_socks_udp(packet: &[u8]) -> Result<(SocketAddr, &[u8]), String> {
    if packet.len() < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
        return Err("invalid SOCKS5 UDP packet".into());
    }
    match packet[3] {
        0x01 if packet.len() >= 10 => {
            let source = SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::new(packet[4], packet[5], packet[6], packet[7]),
                u16::from_be_bytes([packet[8], packet[9]]),
            ));
            Ok((source, &packet[10..]))
        }
        0x04 if packet.len() >= 22 => {
            let mut octets = [0_u8; 16];
            octets.copy_from_slice(&packet[4..20]);
            let source = SocketAddr::V6(SocketAddrV6::new(
                Ipv6Addr::from(octets),
                u16::from_be_bytes([packet[20], packet[21]]),
                0,
                0,
            ));
            Ok((source, &packet[22..]))
        }
        0x03 => Err("SOCKS5 UDP response uses an unsupported domain address".into()),
        _ => Err("invalid SOCKS5 UDP response address".into()),
    }
}

fn create_spoofed_udp_socket(source: SocketAddr) -> io::Result<UdpSocket> {
    let socket = match source {
        SocketAddr::V4(_) => {
            let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
            socket.set_reuse_address(true)?;
            #[cfg(target_os = "linux")]
            socket.set_ip_transparent_v4(true)?;
            socket
        }
        SocketAddr::V6(_) => {
            let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
            socket.set_reuse_address(true)?;
            socket.set_only_v6(true)?;
            #[cfg(target_os = "linux")]
            socket.set_ip_transparent_v6(true)?;
            socket
        }
    };
    socket.bind(&source.into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

async fn send_spoofed_udp(
    cache: &UdpReplySockets,
    source: SocketAddr,
    client: SocketAddr,
    payload: &[u8],
) -> io::Result<()> {
    if source.is_ipv4() != client.is_ipv4() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "UDP reply address families differ"));
    }

    let socket = {
        let mut sockets = cache.lock().await;
        let now = Instant::now();
        sockets.retain(|_, entry| {
            now.duration_since(entry.last_used) < UDP_REPLY_SOCKET_TTL
                || Arc::strong_count(&entry.socket) > 1
        });
        if let Some(entry) = sockets.get_mut(&source) {
            entry.last_used = now;
            Arc::clone(&entry.socket)
        } else {
            if sockets.len() >= UDP_REPLY_SOCKET_MAX {
                if let Some(oldest) = sockets
                    .iter()
                    .filter(|(_, entry)| Arc::strong_count(&entry.socket) == 1)
                    .min_by_key(|(_, entry)| entry.last_used)
                    .map(|(address, _)| *address)
                {
                    sockets.remove(&oldest);
                }
            }
            let socket = Arc::new(create_spoofed_udp_socket(source)?);
            if sockets.len() < UDP_REPLY_SOCKET_MAX {
                sockets.insert(
                    source,
                    UdpReplySocketEntry {
                        socket: Arc::clone(&socket),
                        last_used: now,
                    },
                );
            }
            socket
        }
    };

    socket.send_to(payload, client).await?;
    Ok(())
}

async fn connect_tcp_outbound(outbound: &OutboundProxy, destination: SocketAddr) -> Result<TcpStream, String> {
    match outbound {
        OutboundProxy::Direct => {
            let stream = TcpStream::connect(destination).await.map_err(io_message)?;
            stream.set_nodelay(true).map_err(io_message)?;
            Ok(stream)
        }
        OutboundProxy::Socks5 { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port)).await.map_err(io_message)?;
            stream.set_nodelay(true).map_err(io_message)?;
            socks5_connect(&mut stream, destination).await?;
            Ok(stream)
        }
    }
}

async fn socks5_connect(stream: &mut TcpStream, destination: SocketAddr) -> Result<(), String> {
    stream.write_all(&[0x05, 0x01, 0x00]).await.map_err(io_message)?;
    let mut greeting = [0_u8; 2];
    stream.read_exact(&mut greeting).await.map_err(io_message)?;
    if greeting != [0x05, 0x00] {
        return Err("SOCKS5 proxy requires unsupported authentication".into());
    }
    let mut request = vec![0x05, 0x01, 0x00];
    match destination {
        SocketAddr::V4(address) => {
            request.push(0x01);
            request.extend_from_slice(&address.ip().octets());
        }
        SocketAddr::V6(address) => {
            request.push(0x04);
            request.extend_from_slice(&address.ip().octets());
        }
    }
    request.extend_from_slice(&destination.port().to_be_bytes());
    stream.write_all(&request).await.map_err(io_message)?;
    let mut reply = [0_u8; 4];
    stream.read_exact(&mut reply).await.map_err(io_message)?;
    if reply[0] != 0x05 || reply[1] != 0x00 {
        return Err(format!("SOCKS5 CONNECT failed with code {}", reply[1]));
    }
    discard_socks_address(stream, reply[3]).await
}

async fn discard_socks_address(stream: &mut TcpStream, atyp: u8) -> Result<(), String> {
    let address_len = match atyp {
        0x01 => 4,
        0x04 => 16,
        0x03 => {
            let mut length = [0_u8; 1];
            stream.read_exact(&mut length).await.map_err(io_message)?;
            usize::from(length[0])
        }
        _ => return Err("invalid SOCKS5 CONNECT response".into()),
    };
    let mut discard = vec![0_u8; address_len + 2];
    stream.read_exact(&mut discard).await.map_err(io_message)?;
    Ok(())
}

fn unspecified_for(address: SocketAddr) -> SocketAddr {
    match address {
        SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)),
        SocketAddr::V6(_) => SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0)),
    }
}

fn raw_socket_v4(address: libc::sockaddr_in) -> io::Result<SocketAddrV4> {
    if address.sin_family != libc::AF_INET as libc::sa_family_t {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "non-IPv4 socket address"));
    }
    Ok(SocketAddrV4::new(
        Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)),
        u16::from_be(address.sin_port),
    ))
}

fn raw_socket_v6(address: libc::sockaddr_in6) -> io::Result<SocketAddrV6> {
    if address.sin6_family != libc::AF_INET6 as libc::sa_family_t {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "non-IPv6 socket address"));
    }
    Ok(SocketAddrV6::new(
        Ipv6Addr::from(address.sin6_addr.s6_addr),
        u16::from_be(address.sin6_port),
        address.sin6_flowinfo,
        address.sin6_scope_id,
    ))
}

fn io_message(error: io::Error) -> String {
    error.to_string()
}

fn arp_mac_for(path: &Path, address: Ipv4Addr) -> Option<MacAddress> {
    let table = std::fs::read_to_string(path).ok()?;
    for line in table.lines().skip(1) {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 4 || columns[0].parse::<Ipv4Addr>().ok() != Some(address) { continue; }
        if let Ok(mac) = MacAddress::parse(columns[3]) { return Some(mac); }
    }
    None
}

fn dhcp_lease_mac_for(path: &Path, address: Ipv4Addr) -> Option<MacAddress> {
    let table = std::fs::read_to_string(path).ok()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    table.lines().rev().find_map(|line| {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 3 || columns[2].parse::<Ipv4Addr>().ok() != Some(address) { return None; }
        let expires = columns[0].parse::<u64>().ok()?;
        if expires != 0 && expires <= now { return None; }
        MacAddress::parse(columns[1]).ok()
    })
}

fn ip_neigh_mac_for(address: IpAddr) -> Option<MacAddress> {
    let address_text = address.to_string();
    let family = if address.is_ipv4() { "-4" } else { "-6" };
    let output = std::process::Command::new("ip")
        .args([family, "neigh", "show", &address_text])
        .output()
        .ok()?;
    if !output.status.success() { return None; }
    let output = String::from_utf8_lossy(&output.stdout);
    let columns = output.split_whitespace().collect::<Vec<_>>();
    columns
        .windows(2)
        .find(|pair| pair[0] == "lladdr")
        .and_then(|pair| MacAddress::parse(pair[1]).ok())
}

fn neighbor_mac_for(arp_path: &Path, dhcp_leases_path: &Path, address: IpAddr) -> Option<MacAddress> {
    match address {
        IpAddr::V4(address) => dhcp_lease_mac_for(dhcp_leases_path, address)
            .or_else(|| arp_mac_for(arp_path, address))
            .or_else(|| ip_neigh_mac_for(IpAddr::V4(address))),
        IpAddr::V6(address) => ip_neigh_mac_for(IpAddr::V6(address)),
    }
}
