use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use socket2::{Domain, Protocol, Socket, Type};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::mpsc;
use wloc_rs::config::{LocationRule, MacAddress, OutboundProxy};
use wloc_rs::network_source::HostapdNetworkSource;

const PEER_CACHE_TTL: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const TCP_IDLE_TIMEOUT: Duration = Duration::from_secs(300);
const UDP_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const IP_RECVORIGDSTADDR: libc::c_int = 20;

#[derive(Clone)]
struct PeerCacheEntry {
    rule: Option<LocationRule>,
    expires_at: Instant,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct UdpSessionKey {
    client: SocketAddrV4,
    destination: SocketAddrV4,
    rule_id: String,
}

#[derive(Clone)]
struct UdpRequest {
    payload: Vec<u8>,
}

#[derive(Clone)]
pub struct TransparentProxy {
    rules: Vec<LocationRule>,
    arp_path: PathBuf,
    dhcp_leases_path: PathBuf,
    peer_cache: Arc<tokio::sync::Mutex<HashMap<Ipv4Addr, PeerCacheEntry>>>,
    network_source: HostapdNetworkSource,
    udp_sessions: Arc<tokio::sync::Mutex<HashMap<UdpSessionKey, mpsc::Sender<UdpRequest>>>>,
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
            peer_cache: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            network_source: HostapdNetworkSource::new(),
            udp_sessions: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
        }
    }

    async fn target_for(&self, peer: Ipv4Addr) -> Result<Option<LocationRule>, String> {
        if let Some(entry) = self
            .peer_cache
            .lock()
            .await
            .get(&peer)
            .cloned()
            .filter(|entry| entry.expires_at > Instant::now())
        {
            return Ok(entry.rule);
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

        self.peer_cache.lock().await.insert(
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
        let destination = socket_v4(client.local_addr().map_err(io_message)?)?;
        let rule = self.target_for(socket_v4(peer)?.ip().to_owned()).await?;
        let outbound = rule
            .as_ref()
            .map(|rule| rule.outbound.clone())
            .unwrap_or(OutboundProxy::Direct);
        let upstream_destination = rewrite_destination(destination);

        let mut upstream = tokio::time::timeout(
            CONNECT_TIMEOUT,
            connect_tcp_outbound(&outbound, upstream_destination),
        )
        .await
        .map_err(|_| "transparent TCP connect timed out".to_owned())??;

        tokio::time::timeout(
            TCP_IDLE_TIMEOUT,
            tokio::io::copy_bidirectional(&mut client, &mut upstream),
        )
        .await
        .map_err(|_| "transparent TCP session timed out".to_owned())?
        .map_err(io_message)?;
        Ok(())
    }

    pub async fn run_udp(self: Arc<Self>, socket: UdpSocket) -> io::Result<()> {
        let mut buffer = vec![0_u8; 65_535];
        loop {
            let (size, client, destination) = recv_original_datagram(&socket, &mut buffer).await?;
            let payload = buffer[..size].to_vec();
            let proxy = Arc::clone(&self);
            tokio::spawn(async move {
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
        client: SocketAddrV4,
        destination: SocketAddrV4,
        payload: Vec<u8>,
    ) -> Result<(), String> {
        let rule = self.target_for(*client.ip()).await?;
        let (rule_id, outbound) = match rule {
            Some(rule) => (rule.id, rule.outbound),
            None => ("direct".to_owned(), OutboundProxy::Direct),
        };
        let key = UdpSessionKey {
            client,
            destination,
            rule_id,
        };
        let request = UdpRequest { payload };

        for _ in 0..2 {
            let sender = {
                let mut sessions = self.udp_sessions.lock().await;
                if let Some(sender) = sessions.get(&key) {
                    sender.clone()
                } else {
                    let (sender, receiver) = mpsc::channel(128);
                    sessions.insert(key.clone(), sender.clone());
                    let session_key = key.clone();
                    let sessions = Arc::clone(&self.udp_sessions);
                    let session_outbound = outbound.clone();
                    tokio::spawn(async move {
                        let result = run_udp_session(
                            client,
                            destination,
                            rewrite_destination(destination),
                            session_outbound,
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

            if sender.send(request.clone()).await.is_ok() {
                return Ok(());
            }
            self.udp_sessions.lock().await.remove(&key);
        }
        Err("unable to queue UDP datagram".into())
    }
}

pub fn udp_listener(port: u16) -> io::Result<UdpSocket> {
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

async fn recv_original_datagram(
    socket: &UdpSocket,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddrV4, SocketAddrV4)> {
    loop {
        socket.readable().await?;
        match recv_original_datagram_now(socket, buffer) {
            Ok(result) => return Ok(result),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
            Err(error) => return Err(error),
        }
    }
}

fn recv_original_datagram_now(
    socket: &UdpSocket,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddrV4, SocketAddrV4)> {
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
    message.msg_controllen = std::mem::size_of_val(&control)
        .try_into()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "control buffer too large"))?;

    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, 0) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    if message.msg_flags & libc::MSG_TRUNC != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "UDP datagram truncated"));
    }
    let client = raw_socket_v4(source)?;
    let mut destination = None;
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let current = unsafe { &*header };
        if current.cmsg_level == libc::SOL_IP && current.cmsg_type == IP_RECVORIGDSTADDR {
            let raw = unsafe { *(libc::CMSG_DATA(header) as *const libc::sockaddr_in) };
            destination = Some(raw_socket_v4(raw)?);
            break;
        }
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }
    let destination = destination.ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "original UDP destination is unavailable")
    })?;
    Ok((size as usize, client, destination))
}

async fn run_udp_session(
    client: SocketAddrV4,
    original_destination: SocketAddrV4,
    upstream_destination: SocketAddrV4,
    outbound: OutboundProxy,
    receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    match outbound {
        OutboundProxy::Direct => {
            run_direct_udp_session(client, original_destination, upstream_destination, receiver).await
        }
        OutboundProxy::Socks5 { host, port } => {
            run_socks_udp_session(
                client,
                original_destination,
                upstream_destination,
                &host,
                port,
                receiver,
            )
            .await
        }
        OutboundProxy::Http { .. } => Err("HTTP proxy does not support UDP relay".into()),
    }
}

async fn run_direct_udp_session(
    client: SocketAddrV4,
    original_destination: SocketAddrV4,
    upstream_destination: SocketAddrV4,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let upstream = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))
        .await
        .map_err(io_message)?;
    let mut buffer = vec![0_u8; 65_535];
    let idle = tokio::time::sleep(UDP_IDLE_TIMEOUT);
    tokio::pin!(idle);

    loop {
        tokio::select! {
            request = receiver.recv() => {
                let Some(request) = request else { return Ok(()); };
                upstream.send_to(&request.payload, upstream_destination).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            response = upstream.recv_from(&mut buffer) => {
                let (size, source) = response.map_err(io_message)?;
                let source = socket_v4(source)?;
                let reply_source = if original_destination.port() == 53 {
                    original_destination
                } else {
                    source
                };
                send_spoofed_udp(reply_source, client, &buffer[..size]).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn run_socks_udp_session(
    client: SocketAddrV4,
    original_destination: SocketAddrV4,
    upstream_destination: SocketAddrV4,
    host: &str,
    port: u16,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let (control, relay) = tokio::time::timeout(CONNECT_TIMEOUT, socks5_udp_associate(host, port))
        .await
        .map_err(|_| "SOCKS5 UDP association timed out".to_owned())??;
    let _control = control;
    let upstream = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))
        .await
        .map_err(io_message)?;
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
                if sender != relay {
                    continue;
                }
                let (source, payload) = decode_socks_udp(&buffer[..size])?;
                let reply_source = if original_destination.port() == 53 {
                    original_destination
                } else {
                    source
                };
                send_spoofed_udp(reply_source, client, payload).await.map_err(io_message)?;
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
    if reply[3] != 0x01 {
        return Err("SOCKS5 UDP relay returned a non-IPv4 address".into());
    }
    let mut address = [0_u8; 4];
    let mut port_bytes = [0_u8; 2];
    control.read_exact(&mut address).await.map_err(io_message)?;
    control.read_exact(&mut port_bytes).await.map_err(io_message)?;
    let mut relay_ip = Ipv4Addr::from(address);
    if relay_ip.is_unspecified() {
        relay_ip = *socket_v4(control.peer_addr().map_err(io_message)?)?.ip();
    }
    let relay = SocketAddr::V4(SocketAddrV4::new(relay_ip, u16::from_be_bytes(port_bytes)));
    Ok((control, relay))
}

fn encode_socks_udp(destination: SocketAddrV4, payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::with_capacity(payload.len() + 10);
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
    packet.extend_from_slice(&destination.ip().octets());
    packet.extend_from_slice(&destination.port().to_be_bytes());
    packet.extend_from_slice(payload);
    packet
}

fn decode_socks_udp(packet: &[u8]) -> Result<(SocketAddrV4, &[u8]), String> {
    if packet.len() < 10 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
        return Err("invalid SOCKS5 UDP packet".into());
    }
    if packet[3] != 0x01 {
        return Err("SOCKS5 UDP response is not IPv4".into());
    }
    let source = SocketAddrV4::new(
        Ipv4Addr::new(packet[4], packet[5], packet[6], packet[7]),
        u16::from_be_bytes([packet[8], packet[9]]),
    );
    Ok((source, &packet[10..]))
}

async fn send_spoofed_udp(
    source: SocketAddrV4,
    client: SocketAddrV4,
    payload: &[u8],
) -> io::Result<()> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v4(true)?;
    socket.bind(&source.into())?;
    socket.set_nonblocking(true)?;
    let socket = UdpSocket::from_std(socket.into())?;
    socket.send_to(payload, client).await?;
    Ok(())
}

async fn connect_tcp_outbound(
    outbound: &OutboundProxy,
    destination: SocketAddrV4,
) -> Result<TcpStream, String> {
    match outbound {
        OutboundProxy::Direct => TcpStream::connect(destination).await.map_err(io_message),
        OutboundProxy::Http { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port))
                .await
                .map_err(io_message)?;
            http_connect(&mut stream, destination).await?;
            Ok(stream)
        }
        OutboundProxy::Socks5 { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port))
                .await
                .map_err(io_message)?;
            socks5_connect(&mut stream, destination).await?;
            Ok(stream)
        }
    }
}

async fn http_connect(stream: &mut TcpStream, destination: SocketAddrV4) -> Result<(), String> {
    let authority = destination.to_string();
    let request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: keep-alive\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).await.map_err(io_message)?;
    let mut response = Vec::with_capacity(256);
    let mut byte = [0_u8; 1];
    while response.len() < 8192 {
        if stream.read(&mut byte).await.map_err(io_message)? == 0 {
            return Err("HTTP proxy closed during CONNECT".into());
        }
        response.push(byte[0]);
        if response.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    let status = std::str::from_utf8(&response)
        .ok()
        .and_then(|text| text.lines().next())
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "invalid HTTP proxy CONNECT response".to_owned())?;
    if status != 200 {
        return Err(format!("HTTP proxy CONNECT status {status}"));
    }
    Ok(())
}

async fn socks5_connect(stream: &mut TcpStream, destination: SocketAddrV4) -> Result<(), String> {
    stream.write_all(&[0x05, 0x01, 0x00]).await.map_err(io_message)?;
    let mut greeting = [0_u8; 2];
    stream.read_exact(&mut greeting).await.map_err(io_message)?;
    if greeting != [0x05, 0x00] {
        return Err("SOCKS5 proxy requires unsupported authentication".into());
    }

    let mut request = vec![0x05, 0x01, 0x00, 0x01];
    request.extend_from_slice(&destination.ip().octets());
    request.extend_from_slice(&destination.port().to_be_bytes());
    stream.write_all(&request).await.map_err(io_message)?;

    let mut reply = [0_u8; 4];
    stream.read_exact(&mut reply).await.map_err(io_message)?;
    if reply[0] != 0x05 || reply[1] != 0x00 {
        return Err(format!("SOCKS5 CONNECT failed with code {}", reply[1]));
    }
    let address_len = match reply[3] {
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

fn rewrite_destination(destination: SocketAddrV4) -> SocketAddrV4 {
    if destination.port() == 53 {
        SocketAddrV4::new(Ipv4Addr::new(8, 8, 4, 4), 53)
    } else {
        destination
    }
}

fn socket_v4(address: SocketAddr) -> Result<SocketAddrV4, String> {
    match address {
        SocketAddr::V4(address) => Ok(address),
        SocketAddr::V6(_) => Err("IPv6 is not supported by the WLOC transparent relay yet".into()),
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

fn io_message(error: io::Error) -> String {
    error.to_string()
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

fn dhcp_lease_mac_for(path: &Path, address: Ipv4Addr) -> Option<MacAddress> {
    let table = std::fs::read_to_string(path).ok()?;
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
        MacAddress::parse(columns[1]).ok()
    })
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

fn neighbor_mac_for(
    arp_path: &Path,
    dhcp_leases_path: &Path,
    address: Ipv4Addr,
) -> Option<MacAddress> {
    dhcp_lease_mac_for(dhcp_leases_path, address)
        .or_else(|| arp_mac_for(arp_path, address))
        .or_else(|| ip_neigh_mac_for(address))
}
