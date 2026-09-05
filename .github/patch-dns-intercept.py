from pathlib import Path
import re


def read(path):
    return Path(path).read_text()


def write(path, text):
    Path(path).write_text(text)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, got {count}")
    return text.replace(old, new, 1)


def sub_once(text, pattern, replacement, label):
    updated, count = re.subn(pattern, lambda _m: replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, got {count}")
    return updated


# Capture AP DNS in WLOC itself. The handled bit prevents the same client DNS packet
# from falling through into NftFlow after WLOC has claimed it.
path = "root/usr/share/wloc/defaults/firewall.nft"
text = read(path)
text = replace_once(
    text,
    '        meta l4proto { tcp, udp } th dport 53 jump ap_tproxy_dispatch\n',
    '        meta l4proto { tcp, udp } th dport 53 ct mark set ct mark | 0x00010000 meta mark set meta mark | 0x40010000 counter tproxy to :%port% accept comment "wloc dns"\n',
    "DNS TPROXY rule",
)
write(path, text)


# Replace proactive DNS resolution with the client-DNS interception module.
path = "src/wloc-rs/src/lib.rs"
text = read(path)
text = replace_once(text, "pub mod config;\n", "pub mod config;\npub mod dns;\n", "DNS module export")
text = replace_once(text, "pub mod resolver;\n", "", "resolver module removal")
write(path, text)


dns_rs = r'''use std::collections::{BTreeSet, HashMap};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use socket2::{Domain, Protocol, Socket, Type};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{Mutex, Semaphore};

use crate::config::LocationRule;
use crate::outbound;
use crate::proxy::Proxy;

const DNS_TIMEOUT: Duration = Duration::from_secs(5);
const DNS_TCP_IDLE_TIMEOUT: Duration = Duration::from_secs(15);
const DNS_UDP_DISPATCH_LIMIT: usize = 64;
const UDP_REPLY_SOCKET_MAX: usize = 64;
const MAX_DNS_MESSAGE: usize = u16::MAX as usize;
const IP_RECVORIGDSTADDR: libc::c_int = 20;
const IPV6_RECVORIGDSTADDR: libc::c_int = 74;

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

#[derive(Clone, Debug)]
struct DnsQuestion {
    id: u16,
    name: String,
    qtype: u16,
}

struct TrackerInner {
    domains: Vec<String>,
    rules_helper: PathBuf,
    debug: bool,
    targets: Mutex<BTreeSet<IpAddr>>,
}

#[derive(Clone)]
pub struct DnsTracker {
    inner: Arc<TrackerInner>,
}

impl DnsTracker {
    pub fn new(domains: Vec<String>, rules_helper: PathBuf, debug: bool) -> Self {
        Self {
            inner: Arc::new(TrackerInner {
                domains,
                rules_helper,
                debug,
                targets: Mutex::new(BTreeSet::new()),
            }),
        }
    }

    pub async fn handle_tcp(
        &self,
        mut client: TcpStream,
        peer: SocketAddr,
        destination: SocketAddr,
        rule: &LocationRule,
    ) -> Result<(), String> {
        let mut upstream = tokio::time::timeout(
            DNS_TIMEOUT,
            outbound::connect_tcp_addr(&rule.outbound, destination),
        )
        .await
        .map_err(|_| "DNS TCP connect timed out".to_owned())?
        .map_err(io_message)?;

        loop {
            let query = match read_tcp_message(&mut client).await? {
                Some(message) => message,
                None => return Ok(()),
            };
            if self.inner.debug {
                log_query("tcp", peer, destination, rule, &query);
            }
            upstream
                .write_all(&(query.len() as u16).to_be_bytes())
                .await
                .map_err(io_message)?;
            upstream.write_all(&query).await.map_err(io_message)?;
            let response = read_tcp_message(&mut upstream)
                .await?
                .ok_or_else(|| "DNS TCP upstream closed before response".to_owned())?;
            self.update_from_response(rule, &query, &response).await?;
            client
                .write_all(&(response.len() as u16).to_be_bytes())
                .await
                .map_err(io_message)?;
            client.write_all(&response).await.map_err(io_message)?;
        }
    }

    async fn forward_udp(
        &self,
        client: SocketAddr,
        destination: SocketAddr,
        rule: &LocationRule,
        query: &[u8],
    ) -> Result<Vec<u8>, String> {
        if self.inner.debug {
            log_query("udp", client, destination, rule, query);
        }
        let upstream = outbound::bind_udp(&rule.outbound, destination).map_err(io_message)?;
        upstream.send_to(query, destination).await.map_err(io_message)?;
        let mut response = vec![0_u8; 65_535];
        let (size, _) = tokio::time::timeout(DNS_TIMEOUT, upstream.recv_from(&mut response))
            .await
            .map_err(|_| "DNS UDP query timed out".to_owned())?
            .map_err(io_message)?;
        response.truncate(size);
        self.update_from_response(rule, query, &response).await?;
        Ok(response)
    }

    async fn update_from_response(
        &self,
        rule: &LocationRule,
        query: &[u8],
        response: &[u8],
    ) -> Result<(), String> {
        let Ok(question) = dns_question(query) else {
            return Ok(());
        };
        if !crate::approved_host(&question.name, &self.inner.domains)
            || (question.qtype != 1 && question.qtype != 28)
        {
            return Ok(());
        }
        let Some(addresses) = response_addresses(response, question.id, question.qtype)? else {
            return Ok(());
        };
        if addresses.is_empty() {
            return Ok(());
        }

        let mut current = self.inner.targets.lock().await;
        let mut next = current.clone();
        next.extend(addresses.iter().copied());
        if next.len() == current.len() {
            return Ok(());
        }
        let next_values = next.iter().copied().collect::<Vec<_>>();
        update_runtime_targets(self.inner.rules_helper.clone(), next_values.clone()).await?;
        let added = next.len() - current.len();
        *current = next;
        if self.inner.debug {
            eprintln!(
                "wlocd: debug=dns event=location_targets_updated rule={} name={} qtype={} added={} targets={} action=firewall_reloaded",
                rule.id,
                question.name,
                question.qtype,
                added,
                next_values.len()
            );
        }
        Ok(())
    }
}

type ReplySockets = Arc<Mutex<HashMap<SocketAddr, Arc<UdpSocket>>>>;

pub struct DnsProxy {
    proxy: Arc<Proxy>,
    tracker: DnsTracker,
    dispatch: Arc<Semaphore>,
    reply_sockets: ReplySockets,
}

impl DnsProxy {
    pub fn new(proxy: Arc<Proxy>, tracker: DnsTracker) -> Self {
        Self {
            proxy,
            tracker,
            dispatch: Arc::new(Semaphore::new(DNS_UDP_DISPATCH_LIMIT)),
            reply_sockets: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn run_udp(self: Arc<Self>, socket: UdpSocket) -> io::Result<()> {
        let family = match socket.local_addr()? {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        };
        let socket = Arc::new(socket);
        let mut buffer = vec![0_u8; 65_535];
        loop {
            let (size, client, destination) = match recv_original_datagram(&socket, family, &mut buffer).await {
                Ok(packet) => packet,
                Err(error) => {
                    eprintln!(
                        "wlocd: dns_udp_receive=failed family={} recovery=continue error={error}",
                        family.label()
                    );
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    continue;
                }
            };
            let permit = match Arc::clone(&self.dispatch).acquire_owned().await {
                Ok(permit) => permit,
                Err(_) => return Ok(()),
            };
            let query = buffer[..size].to_vec();
            let worker = Arc::clone(&self);
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = worker.handle_udp(client, destination, query).await {
                    eprintln!(
                        "wlocd: dns_udp=failed client={client} destination={destination} error={error}"
                    );
                }
            });
        }
    }

    async fn handle_udp(
        &self,
        client: SocketAddr,
        destination: SocketAddr,
        query: Vec<u8>,
    ) -> Result<(), String> {
        let rule = self
            .proxy
            .target_for(client.ip())
            .await?
            .ok_or_else(|| format!("no matching WLOC rule for DNS client {client}"))?;
        let response = self
            .tracker
            .forward_udp(client, destination, &rule, &query)
            .await?;
        send_spoofed_udp(&self.reply_sockets, destination, client, &response)
            .await
            .map_err(io_message)
    }
}

pub fn listener_v4(port: u16) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v4(true)?;
    enable_original_destination(&socket, AddressFamily::V4)?;
    socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

pub fn listener_v6(port: u16) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    socket.set_only_v6(true)?;
    #[cfg(target_os = "linux")]
    socket.set_ip_transparent_v6(true)?;
    enable_original_destination(&socket, AddressFamily::V6)?;
    socket.bind(&SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0).into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

fn enable_original_destination(socket: &Socket, family: AddressFamily) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        let enabled: libc::c_int = 1;
        let (level, option) = match family {
            AddressFamily::V4 => (libc::SOL_IP, IP_RECVORIGDSTADDR),
            AddressFamily::V6 => (libc::SOL_IPV6, IPV6_RECVORIGDSTADDR),
        };
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                level,
                option,
                (&enabled as *const libc::c_int).cast(),
                std::mem::size_of_val(&enabled) as libc::socklen_t,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (socket, family);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "original UDP destinations require Linux",
        ))
    }
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
    let mut control = [0_u8; 128];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_name = (&mut source as *mut libc::sockaddr_in).cast();
    message.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
    message.msg_iov = &mut iovec;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = control.len();
    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, libc::MSG_DONTWAIT) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    let client = SocketAddr::V4(raw_socket_v4(source)?);
    let mut destination = None;
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let current = unsafe { &*header };
        if current.cmsg_level == libc::SOL_IP && current.cmsg_type == IP_RECVORIGDSTADDR {
            let raw = unsafe {
                std::ptr::read_unaligned(libc::CMSG_DATA(header) as *const libc::sockaddr_in)
            };
            destination = Some(SocketAddr::V4(raw_socket_v4(raw)?));
            break;
        }
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }
    Ok((
        size as usize,
        client,
        destination.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "original IPv4 DNS destination is unavailable",
            )
        })?,
    ))
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
    let mut control = [0_u8; 160];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_name = (&mut source as *mut libc::sockaddr_in6).cast();
    message.msg_namelen = std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t;
    message.msg_iov = &mut iovec;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = control.len();
    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, libc::MSG_DONTWAIT) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    let client = SocketAddr::V6(raw_socket_v6(source)?);
    let mut destination = None;
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let current = unsafe { &*header };
        if current.cmsg_level == libc::SOL_IPV6 && current.cmsg_type == IPV6_RECVORIGDSTADDR {
            let raw = unsafe {
                std::ptr::read_unaligned(libc::CMSG_DATA(header) as *const libc::sockaddr_in6)
            };
            destination = Some(SocketAddr::V6(raw_socket_v6(raw)?));
            break;
        }
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }
    Ok((
        size as usize,
        client,
        destination.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "original IPv6 DNS destination is unavailable",
            )
        })?,
    ))
}

fn raw_socket_v4(address: libc::sockaddr_in) -> io::Result<SocketAddrV4> {
    if address.sin_family != libc::AF_INET as libc::sa_family_t {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "non-IPv4 socket address",
        ));
    }
    Ok(SocketAddrV4::new(
        Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)),
        u16::from_be(address.sin_port),
    ))
}

fn raw_socket_v6(address: libc::sockaddr_in6) -> io::Result<SocketAddrV6> {
    if address.sin6_family != libc::AF_INET6 as libc::sa_family_t {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "non-IPv6 socket address",
        ));
    }
    Ok(SocketAddrV6::new(
        Ipv6Addr::from(address.sin6_addr.s6_addr),
        u16::from_be(address.sin6_port),
        address.sin6_flowinfo,
        address.sin6_scope_id,
    ))
}

fn transparent_reply_socket(source: SocketAddr) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::for_address(source), Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    match source {
        SocketAddr::V4(_) => {
            #[cfg(target_os = "linux")]
            socket.set_ip_transparent_v4(true)?;
        }
        SocketAddr::V6(_) => {
            socket.set_only_v6(true)?;
            #[cfg(target_os = "linux")]
            socket.set_ip_transparent_v6(true)?;
        }
    }
    socket.bind(&source.into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

async fn send_spoofed_udp(
    cache: &ReplySockets,
    source: SocketAddr,
    client: SocketAddr,
    payload: &[u8],
) -> io::Result<()> {
    let socket = {
        let mut sockets = cache.lock().await;
        if let Some(socket) = sockets.get(&source) {
            Arc::clone(socket)
        } else {
            if sockets.len() >= UDP_REPLY_SOCKET_MAX {
                if let Some(key) = sockets.keys().next().copied() {
                    sockets.remove(&key);
                }
            }
            let socket = Arc::new(transparent_reply_socket(source)?);
            sockets.insert(source, Arc::clone(&socket));
            socket
        }
    };
    socket.send_to(payload, client).await.map(|_| ())
}

async fn read_tcp_message(stream: &mut TcpStream) -> Result<Option<Vec<u8>>, String> {
    let mut length = [0_u8; 2];
    match tokio::time::timeout(DNS_TCP_IDLE_TIMEOUT, stream.read_exact(&mut length)).await {
        Ok(Ok(_)) => {}
        Ok(Err(error)) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Ok(Err(error)) => return Err(io_message(error)),
        Err(_) => return Ok(None),
    }
    let length = u16::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_DNS_MESSAGE {
        return Err("invalid DNS TCP message length".into());
    }
    let mut message = vec![0_u8; length];
    tokio::time::timeout(DNS_TIMEOUT, stream.read_exact(&mut message))
        .await
        .map_err(|_| "DNS TCP message timed out".to_owned())?
        .map_err(io_message)?;
    Ok(Some(message))
}

fn dns_question(packet: &[u8]) -> Result<DnsQuestion, String> {
    if packet.len() < 12 || read_u16(packet, 4)? == 0 {
        return Err("DNS query has no question".into());
    }
    let (name, offset) = read_name(packet, 12)?;
    let qtype = read_u16(packet, offset)?;
    let qclass = read_u16(packet, offset + 2)?;
    if qclass != 1 {
        return Err("DNS question class is not IN".into());
    }
    Ok(DnsQuestion {
        id: read_u16(packet, 0)?,
        name: name.trim_end_matches('.').to_ascii_lowercase(),
        qtype,
    })
}

fn read_name(packet: &[u8], start: usize) -> Result<(String, usize), String> {
    let mut labels = Vec::new();
    let mut offset = start;
    let mut next = None;
    let mut jumps = 0;
    loop {
        let length = *packet
            .get(offset)
            .ok_or_else(|| "truncated DNS name".to_owned())?;
        if length & 0xc0 == 0xc0 {
            let second = *packet
                .get(offset + 1)
                .ok_or_else(|| "truncated DNS pointer".to_owned())?;
            let pointer = (((length & 0x3f) as usize) << 8) | second as usize;
            if next.is_none() {
                next = Some(offset + 2);
            }
            offset = pointer;
            jumps += 1;
            if jumps > 16 {
                return Err("DNS compression pointer loop".into());
            }
            continue;
        }
        if length & 0xc0 != 0 {
            return Err("invalid DNS label".into());
        }
        offset += 1;
        if length == 0 {
            return Ok((labels.join("."), next.unwrap_or(offset)));
        }
        let end = offset
            .checked_add(length as usize)
            .ok_or_else(|| "invalid DNS name length".to_owned())?;
        let label = packet
            .get(offset..end)
            .ok_or_else(|| "truncated DNS label".to_owned())?;
        labels.push(String::from_utf8_lossy(label).into_owned());
        offset = end;
    }
}

fn skip_name(packet: &[u8], mut offset: usize) -> Result<usize, String> {
    loop {
        let length = *packet
            .get(offset)
            .ok_or_else(|| "truncated DNS name".to_owned())?;
        if length & 0xc0 == 0xc0 {
            packet
                .get(offset + 1)
                .ok_or_else(|| "truncated DNS pointer".to_owned())?;
            return Ok(offset + 2);
        }
        if length & 0xc0 != 0 {
            return Err("invalid DNS label".into());
        }
        offset += 1;
        if length == 0 {
            return Ok(offset);
        }
        offset = offset
            .checked_add(length as usize)
            .ok_or_else(|| "invalid DNS name length".to_owned())?;
        if offset > packet.len() {
            return Err("truncated DNS label".into());
        }
    }
}

fn response_addresses(
    packet: &[u8],
    expected_id: u16,
    expected_type: u16,
) -> Result<Option<Vec<IpAddr>>, String> {
    if packet.len() < 12 || read_u16(packet, 0)? != expected_id {
        return Err("DNS response ID does not match query".into());
    }
    let flags = read_u16(packet, 2)?;
    if flags & 0x8000 == 0 {
        return Err("DNS response bit is not set".into());
    }
    if flags & 0x0200 != 0 || flags & 0x000f != 0 {
        return Ok(None);
    }
    let questions = read_u16(packet, 4)? as usize;
    let answers = read_u16(packet, 6)? as usize;
    let mut offset = 12;
    for _ in 0..questions {
        offset = skip_name(packet, offset)?;
        offset = offset
            .checked_add(4)
            .ok_or_else(|| "invalid DNS question length".to_owned())?;
        if offset > packet.len() {
            return Err("truncated DNS question".into());
        }
    }
    let mut addresses = BTreeSet::new();
    for _ in 0..answers {
        offset = skip_name(packet, offset)?;
        let rr_type = read_u16(packet, offset)?;
        let class = read_u16(packet, offset + 2)?;
        let data_len = read_u16(packet, offset + 8)? as usize;
        offset = offset
            .checked_add(10)
            .ok_or_else(|| "invalid DNS answer length".to_owned())?;
        let end = offset
            .checked_add(data_len)
            .ok_or_else(|| "invalid DNS record length".to_owned())?;
        let data = packet
            .get(offset..end)
            .ok_or_else(|| "truncated DNS record".to_owned())?;
        if class == 1 && rr_type == expected_type {
            if rr_type == 1 && data_len == 4 {
                addresses.insert(IpAddr::V4(Ipv4Addr::new(data[0], data[1], data[2], data[3])));
            } else if rr_type == 28 && data_len == 16 {
                let bytes: [u8; 16] = data
                    .try_into()
                    .map_err(|_| "invalid IPv6 DNS record".to_owned())?;
                addresses.insert(IpAddr::V6(Ipv6Addr::from(bytes)));
            }
        }
        offset = end;
    }
    Ok(Some(addresses.into_iter().collect()))
}

async fn update_runtime_targets(helper: PathBuf, targets: Vec<IpAddr>) -> Result<(), String> {
    tokio::task::spawn_blocking(move || run_rules(&helper, &targets))
        .await
        .map_err(|error| format!("DNS target update task failed: {error}"))?
}

fn run_rules(helper: &Path, targets: &[IpAddr]) -> Result<(), String> {
    let mut command = std::process::Command::new(helper);
    command.arg("update-targets");
    for target in targets {
        command.arg(target.to_string());
    }
    command.stdout(std::process::Stdio::null());
    command.stderr(std::process::Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|error| format!("rules helper: {}", error.kind()))?;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("rules helper: {}", error.kind()))?
        {
            return if status.success() {
                Ok(())
            } else {
                Err("rules helper update-targets failed".into())
            };
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("rules helper update-targets timed out".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn read_u16(packet: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = packet
        .get(offset..offset + 2)
        .ok_or_else(|| "truncated DNS packet".to_owned())?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn log_query(
    transport: &str,
    client: SocketAddr,
    destination: SocketAddr,
    rule: &LocationRule,
    query: &[u8],
) {
    match dns_question(query) {
        Ok(question) => eprintln!(
            "wlocd: debug=dns event=query transport={transport} client={client} destination={destination} rule={} outbound={} id={} name={} qtype={} action=proxy",
            rule.id,
            rule.outbound.label(),
            question.id,
            question.name,
            question.qtype
        ),
        Err(error) => eprintln!(
            "wlocd: debug=dns event=query transport={transport} client={client} destination={destination} rule={} outbound={} parse_error={error:?} action=proxy",
            rule.id,
            rule.outbound.label()
        ),
    }
}

fn io_message(error: io::Error) -> String {
    error.to_string()
}
'''
write("src/wloc-rs/src/dns.rs", dns_rs)
Path("src/wloc-rs/src/resolver.rs").unlink()


# Give DNS TCP interception access to the selected AP rule and tracker.
path = "src/wloc-rs/src/proxy.rs"
text = read(path)
text = replace_once(
    text,
    "use crate::client_hello::peek_sni;\n",
    "use crate::client_hello::peek_sni;\nuse crate::dns::DnsTracker;\n",
    "proxy DNS import",
)
text = replace_once(
    text,
    "    stream_limit: Arc<tokio::sync::Semaphore>,\n    followers: HashMap<String, Arc<tokio::sync::Mutex<LocationFollower>>>,\n",
    "    stream_limit: Arc<tokio::sync::Semaphore>,\n    dns: DnsTracker,\n    followers: HashMap<String, Arc<tokio::sync::Mutex<LocationFollower>>>,\n",
    "proxy DNS field",
)
text = replace_once(
    text,
    "        domains: Vec<String>,\n        debug: bool,\n        status: Arc<Status>,\n",
    "        domains: Vec<String>,\n        debug: bool,\n        dns: DnsTracker,\n        status: Arc<Status>,\n",
    "proxy DNS constructor parameter",
)
text = replace_once(
    text,
    "            stream_limit: Arc::new(tokio::sync::Semaphore::new(GLOBAL_STREAM_LIMIT)),\n            followers,\n",
    "            stream_limit: Arc::new(tokio::sync::Semaphore::new(GLOBAL_STREAM_LIMIT)),\n            dns,\n            followers,\n",
    "proxy DNS initialization",
)
text = replace_once(
    text,
    "    async fn target_for(&self, peer: IpAddr) -> Result<Option<LocationRule>, String> {\n",
    "    pub(crate) async fn target_for(&self, peer: IpAddr) -> Result<Option<LocationRule>, String> {\n",
    "proxy target visibility",
)
text = replace_once(
    text,
    "        };\n        self.handle_target(stream, rule, peer_address.ip()).await\n    }\n",
    "        };\n        let destination = passthrough_destination(&stream).map_err(ProxyError::io)?;\n        if destination.port() == 53 {\n            return self\n                .dns\n                .handle_tcp(stream, peer_address, destination, &rule)\n                .await\n                .map_err(|error| ProxyError::Protocol(format!(\"dns_proxy_failed: {error}\")));\n        }\n        self.handle_target(stream, rule, peer_address.ip()).await\n    }\n",
    "proxy TCP DNS dispatch",
)
write(path, text)


# Daemon startup: no proactive DNS or refresh loop. Start a UDP transparent DNS listener
# on the same numeric port as the existing TCP location listener.
path = "src/wloc-rs/src/main.rs"
text = read(path)
text = replace_once(
    text,
    "use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};\n",
    "use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};\n",
    "main IP import",
)
text = replace_once(
    text,
    "use wloc_rs::config::Config;\nuse wloc_rs::proxy::Proxy;\nuse wloc_rs::resolver;\n",
    "use wloc_rs::config::Config;\nuse wloc_rs::dns::{self, DnsProxy, DnsTracker};\nuse wloc_rs::proxy::Proxy;\n",
    "main DNS imports",
)
text = replace_once(
    text,
    "const TOKIO_WORKER_STACK_SIZE: usize = 1024 * 1024;\nconst LOCATION_DNS_REFRESH_INTERVAL: Duration = Duration::from_secs(60);\n",
    "const TOKIO_WORKER_STACK_SIZE: usize = 1024 * 1024;\n",
    "DNS refresh constant removal",
)
text = sub_once(
    text,
    r"fn update_location_targets\(helper: &Path, targets: &\[IpAddr\]\) -> Result<\(\), String> \{.*?\n\}\n\nasync fn update_location_targets_async\(helper: PathBuf, targets: Vec<IpAddr>\) -> Result<\(\), String> \{.*?\n\}\n\n",
    "",
    "startup target helper removal",
)
replacement = r'''        let bootstrap = bootstrap_rules_async(config.rules_helper.clone(), config.listen_port).await;
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
        } else {
            status.update_detail(
                "interception_armed",
                &format!(
                    "rules={} hosts={} targets=0 protocol=tcp,dns mode=dns-learned-ip listen_port={}",
                    config.rules.len(),
                    config.domains.join(","),
                    config.listen_port
                ),
                None,
                |c| c.armed(true),
            );
            true
        };
        eprintln!(
            "wlocd: daemon=ready interception={} targets=0 dns_mode=intercept ca_generated={generated}",
            initially_armed
        );

        let dns_tracker = DnsTracker::new(
            config.domains.clone(),
            config.rules_helper.clone(),
            config.debug,
        );
        let dns_udp_v4 = dns::listener_v4(config.listen_port)?;
        let dns_udp_v6 = dns::listener_v6(config.listen_port)?;
        let proxy = Arc::new(Proxy::new('''
text = sub_once(
    text,
    r"        let bootstrap = bootstrap_rules_async\(config\.rules_helper\.clone\(\), config\.listen_port\)\.await;.*?        let proxy = Arc::new\(Proxy::new\(",
    replacement,
    "startup proactive DNS replacement",
)
text = replace_once(
    text,
    "            config.domains,\n            config.debug,\n            Arc::clone(&status),\n        ));\n        let connection_limit",
    "            config.domains,\n            config.debug,\n            dns_tracker.clone(),\n            Arc::clone(&status),\n        ));\n        let dns_proxy = Arc::new(DnsProxy::new(Arc::clone(&proxy), dns_tracker));\n        for (family, socket) in [(\"ipv4\", dns_udp_v4), (\"ipv6\", dns_udp_v6)] {\n            let dns_proxy = Arc::clone(&dns_proxy);\n            tokio::spawn(async move {\n                if let Err(error) = dns_proxy.run_udp(socket).await {\n                    eprintln!(\"wlocd: dns_listener=failed family={family} error={error}\");\n                }\n            });\n        }\n        let connection_limit",
    "UDP DNS listener startup",
)
text = replace_once(
    text,
    '                "transparent_tcp=0.0.0.0,[::]:{} dual_stack=true tcp_limit={} backlog={}",\n',
    '                "transparent_tcp=0.0.0.0,[::]:{} transparent_udp=0.0.0.0,[::]:{} dual_stack=true tcp_limit={} backlog={}",\n',
    "listener status format",
)
text = replace_once(
    text,
    "                config.listen_port, tcp_connection_limit, tcp_listen_backlog\n",
    "                config.listen_port, config.listen_port, tcp_connection_limit, tcp_listen_backlog\n",
    "listener status arguments",
)
write(path, text)
