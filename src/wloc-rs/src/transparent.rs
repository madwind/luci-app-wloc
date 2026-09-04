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
const UDP_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const UDP_DISPATCH_LIMIT: usize = 64;
const UDP_SESSION_MAX: usize = 256;
const UDP_REPLY_SOCKET_MAX: usize = 64;
const DOH_POOL_MAX: usize = 64;
const DOH_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_DNS_MESSAGE: usize = u16::MAX as usize;
const DOH_ENDPOINTS: [Ipv4Addr; 2] = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(8, 8, 8, 8)];
const IP_RECVORIGDSTADDR: libc::c_int = 20;
const IPV6_RECVORIGDSTADDR: libc::c_int = 74;

static DOH_GENERATION: AtomicU64 = AtomicU64::new(1);

type UdpReplySockets = Arc<Mutex<HashMap<SocketAddr, Arc<UdpSocket>>>>;

#[derive(Clone)]
struct DohEntry {
    generation: u64,
    sender: h2::client::SendRequest<Bytes>,
}

type DohPool = Arc<Mutex<HashMap<String, DohEntry>>>;

#[derive(Clone, Copy)]
enum AddressFamily {
    V4,
    V6,
}

#[derive(Clone)]
struct PeerCacheEntry {
    rule: Option<LocationRule>,
    expires_at: Instant,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct UdpSessionKey {
    client: SocketAddr,
    destination: SocketAddr,
    rule_id: String,
}

struct UdpRequest {
    payload: Vec<u8>,
}

#[derive(Clone)]
pub struct TransparentProxy {
    rules: Vec<LocationRule>,
    arp_path: PathBuf,
    dhcp_leases_path: PathBuf,
    peer_cache: Arc<Mutex<HashMap<IpAddr, PeerCacheEntry>>>,
    network_source: HostapdNetworkSource,
    udp_sessions: Arc<Mutex<HashMap<UdpSessionKey, mpsc::Sender<UdpRequest>>>>,
    udp_dispatch: Arc<Semaphore>,
    udp_reply_sockets: UdpReplySockets,
    doh_pool: DohPool,
}

impl TransparentProxy {
    pub fn new(rules: Vec<LocationRule>) -> Self {
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
            udp_sessions: Arc::new(Mutex::new(HashMap::new())),
            udp_dispatch: Arc::new(Semaphore::new(UDP_DISPATCH_LIMIT)),
            udp_reply_sockets: Arc::new(Mutex::new(HashMap::new())),
            doh_pool: Arc::new(Mutex::new(HashMap::new())),
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
        let rule = self.target_for(peer.ip()).await?;
        let outbound = rule
            .as_ref()
            .map(|rule| rule.outbound.clone())
            .unwrap_or(OutboundProxy::Direct);

        if destination.port() == 53 {
            return handle_dns_tcp(&mut client, &outbound, &self.doh_pool).await;
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
            let permit = Arc::clone(&self.udp_dispatch)
                .acquire_owned()
                .await
                .map_err(|_| io::Error::other("UDP dispatch limiter closed"))?;
            let (size, client, destination) =
                recv_original_datagram(&socket, family, &mut buffer).await?;
            let payload = buffer[..size].to_vec();
            let proxy = Arc::clone(&self);
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = proxy
                    .handle_udp_datagram(client, destination, payload)
                    .await
                {
                    eprintln!(
                        "wlocd: udp=failed client={client} destination={destination} error={error}"
                    );
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
        let rule = self.target_for(client.ip()).await?;
        let (rule_id, outbound) = match rule {
            Some(rule) => (rule.id, rule.outbound),
            None => ("direct".to_owned(), OutboundProxy::Direct),
        };

        if destination.port() == 53 {
            let response = doh_query(&self.doh_pool, &outbound, &payload).await?;
            send_spoofed_udp(&self.udp_reply_sockets, destination, client, &response)
                .await
                .map_err(io_message)?;
            return Ok(());
        }

        let key = UdpSessionKey {
            client,
            destination,
            rule_id,
        };
        let mut request = UdpRequest { payload };

        for _ in 0..2 {
            let sender = {
                let mut sessions = self.udp_sessions.lock().await;
                if let Some(sender) = sessions.get(&key) {
                    sender.clone()
                } else {
                    if sessions.len() >= UDP_SESSION_MAX {
                        return Err("UDP session limit reached".into());
                    }
                    let (sender, receiver) = mpsc::channel(128);
                    sessions.insert(key.clone(), sender.clone());
                    let session_key = key.clone();
                    let sessions = Arc::clone(&self.udp_sessions);
                    let session_outbound = outbound.clone();
                    let reply_sockets = Arc::clone(&self.udp_reply_sockets);
                    tokio::spawn(async move {
                        let result = run_udp_session(
                            client,
                            destination,
                            session_outbound,
                            reply_sockets,
                            receiver,
                        )
                        .await;
                        sessions.lock().await.remove(&session_key);
                        if let Err(error) = result {
                            eprintln!(
                                "wlocd: udp_session=failed client={client} destination={destination} error={error}"
                            );
                        }
                    });
                    sender
                }
            };

            match sender.send(request).await {
                Ok(()) => return Ok(()),
                Err(error) => request = error.0,
            }
            self.udp_sessions.lock().await.remove(&key);
        }
        Err("unable to queue UDP datagram".into())
    }
}

async fn handle_dns_tcp(
    client: &mut TcpStream,
    outbound: &OutboundProxy,
    pool: &DohPool,
) -> Result<(), String> {
    loop {
        let mut length = [0_u8; 2];
        if let Err(error) = client.read_exact(&mut length).await {
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
        client.read_exact(&mut query).await.map_err(io_message)?;
        let response = doh_query(pool, outbound, &query).await?;
        let response_len = u16::try_from(response.len())
            .map_err(|_| "DoH response exceeds TCP DNS framing limit".to_owned())?;
        client
            .write_all(&response_len.to_be_bytes())
            .await
            .map_err(io_message)?;
        client.write_all(&response).await.map_err(io_message)?;
    }
}

async fn doh_query(
    pool: &DohPool,
    outbound: &OutboundProxy,
    query: &[u8],
) -> Result<Vec<u8>, String> {
    validate_dns_message(query, "query")?;
    let mut last_error = String::new();

    for endpoint in DOH_ENDPOINTS {
        match doh_query_endpoint(pool, outbound, endpoint, query).await {
            Ok(response) if dns_servfail(&response) => {
                last_error = format!("{endpoint} returned SERVFAIL");
            }
            Ok(response) => return Ok(response),
            Err(error) => {
                last_error = format!("{endpoint}: {error}");
            }
        }
    }

    Err(format!("DoH query failed: {last_error}"))
}

async fn doh_query_endpoint(
    pool: &DohPool,
    outbound: &OutboundProxy,
    endpoint: Ipv4Addr,
    query: &[u8],
) -> Result<Vec<u8>, String> {
    let key = outbound.pool_key(&format!("doh:{endpoint}"));
    let mut active_generation = None;
    let result = tokio::time::timeout(DOH_TIMEOUT, async {
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
            if connections.len() >= DOH_POOL_MAX {
                connections.clear();
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

async fn run_udp_session(
    client: SocketAddr,
    upstream_destination: SocketAddr,
    outbound: OutboundProxy,
    reply_sockets: UdpReplySockets,
    receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    match outbound {
        OutboundProxy::Direct => {
            run_direct_udp_session(client, upstream_destination, reply_sockets, receiver).await
        }
        OutboundProxy::Socks5 { host, port } => {
            run_socks_udp_session(
                client,
                upstream_destination,
                &host,
                port,
                reply_sockets,
                receiver,
            )
            .await
        }
    }
}

async fn run_direct_udp_session(
    client: SocketAddr,
    upstream_destination: SocketAddr,
    reply_sockets: UdpReplySockets,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let upstream = UdpSocket::bind(unspecified_for(upstream_destination)).await.map_err(io_message)?;
    upstream.connect(upstream_destination).await.map_err(io_message)?;
    let mut buffer = vec![0_u8; 65_535];
    let idle = tokio::time::sleep(UDP_IDLE_TIMEOUT);
    tokio::pin!(idle);

    loop {
        tokio::select! {
            request = receiver.recv() => {
                let Some(request) = request else { return Ok(()); };
                upstream.send(&request.payload).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            response = upstream.recv(&mut buffer) => {
                let size = response.map_err(io_message)?;
                send_spoofed_udp(&reply_sockets, upstream_destination, client, &buffer[..size]).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn run_socks_udp_session(
    client: SocketAddr,
    upstream_destination: SocketAddr,
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
    let mut buffer = vec![0_u8; 65_535];
    let idle = tokio::time::sleep(UDP_IDLE_TIMEOUT);
    tokio::pin!(idle);

    loop {
        tokio::select! {
            request = receiver.recv() => {
                let Some(request) = request else { return Ok(()); };
                let packet = encode_socks_udp(upstream_destination, &request.payload);
                upstream.send_to(&packet, relay).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            response = upstream.recv_from(&mut buffer) => {
                let (size, sender) = response.map_err(io_message)?;
                if sender != relay { continue; }
                let (source, payload) = decode_socks_udp(&buffer[..size])?;
                if source != upstream_destination { continue; }
                send_spoofed_udp(&reply_sockets, source, client, payload).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn socks5_udp_associate(host: &str, port: u16) -> Result<(TcpStream, SocketAddr), String> {
    let mut control = TcpStream::connect((host, port)).await.map_err(io_message)?;
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
        if let Some(socket) = sockets.get(&source) {
            Arc::clone(socket)
        } else {
            if sockets.len() >= UDP_REPLY_SOCKET_MAX {
                let removable = sockets
                    .iter()
                    .find(|(_, socket)| Arc::strong_count(socket) == 1)
                    .map(|(address, _)| *address);
                if let Some(address) = removable {
                    sockets.remove(&address);
                }
            }
            let socket = Arc::new(create_spoofed_udp_socket(source)?);
            if sockets.len() < UDP_REPLY_SOCKET_MAX {
                sockets.insert(source, Arc::clone(&socket));
            }
            socket
        }
    };

    socket.send_to(payload, client).await?;
    Ok(())
}

async fn connect_tcp_outbound(outbound: &OutboundProxy, destination: SocketAddr) -> Result<TcpStream, String> {
    match outbound {
        OutboundProxy::Direct => TcpStream::connect(destination).await.map_err(io_message),
        OutboundProxy::Socks5 { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port)).await.map_err(io_message)?;
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
