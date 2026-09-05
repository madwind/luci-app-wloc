use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Duration;

use crate::config::{LocationRule, Outbound};
use crate::outbound;

const DNS_TIMEOUT: Duration = Duration::from_secs(3);
const LOCAL_DNS: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 53));
const TPROXY_DNS: [Ipv4Addr; 2] = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(8, 8, 8, 8)];
static NEXT_ID: AtomicU16 = AtomicU16::new(1);

pub struct Resolution {
    pub addresses: Vec<IpAddr>,
    pub complete: bool,
    pub errors: Vec<String>,
}

pub async fn resolve_location_targets(rules: &[LocationRule], domains: &[String]) -> Resolution {
    let mut addresses = BTreeSet::new();
    let mut errors = Vec::new();

    resolve_scope(
        "local",
        &Outbound::Direct,
        &[LOCAL_DNS],
        domains,
        &mut addresses,
        &mut errors,
    )
    .await;

    for rule in rules {
        let Outbound::Tproxy { .. } = rule.outbound else {
            continue;
        };
        let servers = TPROXY_DNS.map(|address| SocketAddr::V4(SocketAddrV4::new(address, 53)));
        resolve_scope(
            &format!("rule={} iface={}", rule.id, rule.iface),
            &rule.outbound,
            &servers,
            domains,
            &mut addresses,
            &mut errors,
        )
        .await;
    }

    let addresses = addresses.into_iter().collect::<Vec<_>>();
    Resolution {
        complete: errors.is_empty() && !addresses.is_empty(),
        addresses,
        errors,
    }
}

async fn resolve_scope(
    scope: &str,
    outbound: &Outbound,
    servers: &[SocketAddr],
    domains: &[String],
    addresses: &mut BTreeSet<IpAddr>,
    errors: &mut Vec<String>,
) {
    for domain in domains {
        for qtype in [1_u16, 28_u16] {
            let mut last_error = None;
            let mut succeeded = false;
            for server in servers {
                match query(outbound, *server, domain, qtype).await {
                    Ok(found) => {
                        addresses.extend(found);
                        succeeded = true;
                        break;
                    }
                    Err(error) => last_error = Some(error),
                }
            }
            if !succeeded {
                errors.push(format!(
                    "{scope} domain={domain} qtype={qtype} error={}",
                    last_error.unwrap_or_else(|| "no DNS endpoint available".into())
                ));
            }
        }
    }
}

async fn query(
    outbound: &Outbound,
    server: SocketAddr,
    domain: &str,
    qtype: u16,
) -> Result<Vec<IpAddr>, String> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let request = build_query(id, domain, qtype)?;
    let socket = outbound::bind_udp(outbound, server).map_err(|error| format!("bind: {error}"))?;
    socket
        .send_to(&request, server)
        .await
        .map_err(|error| format!("send: {error}"))?;
    let mut response = [0_u8; 4096];
    let received = tokio::time::timeout(DNS_TIMEOUT, socket.recv_from(&mut response))
        .await
        .map_err(|_| "timeout".to_owned())?
        .map_err(|error| format!("receive: {error}"))?;
    parse_response(&response[..received.0], id)
}

fn build_query(id: u16, domain: &str, qtype: u16) -> Result<Vec<u8>, String> {
    let mut packet = Vec::with_capacity(64);
    packet.extend_from_slice(&id.to_be_bytes());
    packet.extend_from_slice(&0x0100_u16.to_be_bytes());
    packet.extend_from_slice(&1_u16.to_be_bytes());
    packet.extend_from_slice(&0_u16.to_be_bytes());
    packet.extend_from_slice(&0_u16.to_be_bytes());
    packet.extend_from_slice(&0_u16.to_be_bytes());
    for label in domain.trim_end_matches('.').split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err("invalid DNS name".into());
        }
        packet.push(label.len() as u8);
        packet.extend_from_slice(label.as_bytes());
    }
    packet.push(0);
    packet.extend_from_slice(&qtype.to_be_bytes());
    packet.extend_from_slice(&1_u16.to_be_bytes());
    Ok(packet)
}

fn read_u16(packet: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = packet
        .get(offset..offset + 2)
        .ok_or_else(|| "truncated DNS response".to_owned())?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
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

fn parse_response(packet: &[u8], expected_id: u16) -> Result<Vec<IpAddr>, String> {
    if packet.len() < 12 || read_u16(packet, 0)? != expected_id {
        return Err("invalid DNS response ID".into());
    }
    let flags = read_u16(packet, 2)?;
    if flags & 0x8000 == 0 {
        return Err("DNS response bit is not set".into());
    }
    if flags & 0x0200 != 0 {
        return Err("truncated DNS response".into());
    }
    let rcode = flags & 0x000f;
    if rcode != 0 {
        return Err(format!("DNS rcode={rcode}"));
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
    let mut addresses = Vec::new();
    for _ in 0..answers {
        offset = skip_name(packet, offset)?;
        let rr_type = read_u16(packet, offset)?;
        let class = read_u16(packet, offset + 2)?;
        let data_len = read_u16(packet, offset + 8)? as usize;
        offset += 10;
        let data = packet
            .get(offset..offset + data_len)
            .ok_or_else(|| "truncated DNS record".to_owned())?;
        if class == 1 && rr_type == 1 && data_len == 4 {
            addresses.push(IpAddr::V4(Ipv4Addr::new(data[0], data[1], data[2], data[3])));
        } else if class == 1 && rr_type == 28 && data_len == 16 {
            let bytes: [u8; 16] = data
                .try_into()
                .map_err(|_| "invalid IPv6 DNS record".to_owned())?;
            addresses.push(IpAddr::V6(Ipv6Addr::from(bytes)));
        }
        offset += data_len;
    }
    Ok(addresses)
}
