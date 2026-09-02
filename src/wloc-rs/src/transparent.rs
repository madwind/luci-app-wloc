use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
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
const UDP_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const IP_RECVORIGDSTADDR: libc::c_int = 20;
const IPV6_RECVORIGDSTADDR: libc::c_int = 74;

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

#[derive(Clone)]
struct UdpRequest {
    payload: Vec<u8>,
}

#[derive(Clone)]
pub struct TransparentProxy {
    rules: Vec<LocationRule>,
    arp_path: PathBuf,
    dhcp_leases_path: PathBuf,
    peer_cache: Arc<tokio::sync::Mutex<HashMap<IpAddr, PeerCacheEntry>>>,
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

    async fn target_for(&self, peer: IpAddr) -> Result<Option<LocationRule>, String> {
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
        let destination = client.local_addr().map_err(io_message)?;
        let rule = self.target_for(peer.ip()).await?;
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
            let (size, client, destination) =
                recv_original_datagram(&socket, family, &mut buffer).await?;
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
        client: SocketAddr,
        destination: SocketAddr,
        payload: Vec<u8>,
    ) -> Result<(), String> {
        let rule = self.target_for(client.ip()).await?;
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
    original_destination: SocketAddr,
    upstream_destination: SocketAddr,
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
    client: SocketAddr,
    original_destination: SocketAddr,
    upstream_destination: SocketAddr,
    mut receiver: mpsc::Receiver<UdpRequest>,
) -> Result<(), String> {
    let upstream = UdpSocket::bind(unspecified_for(upstream_destination)).await.map_err(io_message)?;
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
                let reply_source = if original_destination.port() == 53 { original_destination } else { source };
                send_spoofed_udp(reply_source, client, &buffer[..size]).await.map_err(io_message)?;
                idle.as_mut().reset(tokio::time::Instant::now() + UDP_IDLE_TIMEOUT);
            }
            _ = &mut idle => return Ok(()),
        }
    }
}

async fn run_socks_udp_session(
    client: SocketAddr,
    original_destination: SocketAddr,
    upstream_destination: SocketAddr,
    host: &str,
    port: u16,
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
                let reply_source = if original_destination.port() == 53 { original_destination } else { source };
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

async fn send_spoofed_udp(source: SocketAddr, client: SocketAddr, payload: &[u8]) -> io::Result<()> {
    if source.is_ipv4() != client.is_ipv4() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "UDP reply address families differ"));
    }
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
    let socket = UdpSocket::from_std(socket.into())?;
    socket.send_to(payload, client).await?;
    Ok(())
}

async fn connect_tcp_outbound(outbound: &OutboundProxy, destination: SocketAddr) -> Result<TcpStream, String> {
    match outbound {
        OutboundProxy::Direct => TcpStream::connect(destination).await.map_err(io_message),
        OutboundProxy::Http { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port)).await.map_err(io_message)?;
            http_connect(&mut stream, destination).await?;
            Ok(stream)
        }
        OutboundProxy::Socks5 { host, port } => {
            let mut stream = TcpStream::connect((host.as_str(), *port)).await.map_err(io_message)?;
            socks5_connect(&mut stream, destination).await?;
            Ok(stream)
        }
    }
}

async fn http_connect(stream: &mut TcpStream, destination: SocketAddr) -> Result<(), String> {
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
        if response.ends_with(b"\r\n\r\n") { break; }
    }
    let status = std::str::from_utf8(&response)
        .ok()
        .and_then(|text| text.lines().next())
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "invalid HTTP proxy CONNECT response".to_owned())?;
    if status != 200 { return Err(format!("HTTP proxy CONNECT status {status}")); }
    Ok(())
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

fn rewrite_destination(destination: SocketAddr) -> SocketAddr {
    if destination.port() != 53 {
        return destination;
    }
    match destination {
        SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(8, 8, 4, 4), 53)),
        SocketAddr::V6(_) => SocketAddr::V6(SocketAddrV6::new(
            "2001:4860:4860::8844".parse::<Ipv6Addr>().expect("valid built-in IPv6 DNS address"),
            53,
            0,
            0,
        )),
    }
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
