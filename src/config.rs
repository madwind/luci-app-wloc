use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;

use crate::wloc::PatchTarget;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutboundProxy {
    Direct,
    Http { host: String, port: u16 },
    Socks5 { host: String, port: u16 },
}

impl OutboundProxy {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Http { .. } => "http",
            Self::Socks5 { .. } => "socks5",
        }
    }

    pub fn pool_key(&self, destination: &str) -> String {
        match self {
            Self::Direct => format!("direct|{destination}"),
            Self::Http { host, port } => format!("http|{host}:{port}|{destination}"),
            Self::Socks5 { host, port } => format!("socks5|{host}:{port}|{destination}"),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClientSelector {
    Mac([u8; 6]),
    Ipv4(Ipv4Addr),
}

impl ClientSelector {
    pub fn parse_mac(value: &str) -> Result<Self, String> {
        let mut bytes = [0_u8; 6];
        let parts = value.split(':').collect::<Vec<_>>();
        if parts.len() != 6 {
            return Err("invalid client MAC address".into());
        }
        for (index, part) in parts.iter().enumerate() {
            if part.len() != 2 {
                return Err("invalid client MAC address".into());
            }
            bytes[index] = u8::from_str_radix(part, 16)
                .map_err(|_| "invalid client MAC address".to_owned())?;
        }
        if bytes == [0; 6] || bytes == [0xff; 6] || bytes[0] & 1 != 0 {
            return Err("client MAC must be an individual unicast address".into());
        }
        Ok(Self::Mac(bytes))
    }

    pub fn label(&self) -> String {
        match self {
            Self::Mac(bytes) => bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<Vec<_>>()
                .join(":"),
            Self::Ipv4(address) => address.to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClientTarget {
    pub id: String,
    pub name: String,
    pub selector: ClientSelector,
    pub target: PatchTarget,
    pub outbound: OutboundProxy,
}

impl ClientTarget {
    fn safe_log_name(&self) -> String {
        self.name
            .chars()
            .map(|character| {
                if character == '"' || character == '\\' || character.is_control() {
                    ' '
                } else {
                    character
                }
            })
            .take(80)
            .collect::<String>()
    }

    pub fn log_context(&self) -> String {
        let name = self.safe_log_name();
        match &self.selector {
            ClientSelector::Mac(_) => {
                let mac = self.selector.label().to_uppercase();
                format!("device=\"{name}\" mac={mac}")
            }
            ClientSelector::Ipv4(_) => {
                let selector = self.selector.label();
                format!("device=\"{name}\" selector={selector}")
            }
        }
    }

    pub fn log_context_with_ip(&self, ip: IpAddr) -> String {
        let name = self.safe_log_name();
        match &self.selector {
            ClientSelector::Mac(_) => {
                let mac = self.selector.label().to_uppercase();
                format!("device=\"{name}\" mac={mac} ip={ip}")
            }
            ClientSelector::Ipv4(_) => {
                let selector = self.selector.label();
                format!("device=\"{name}\" selector={selector} ip={ip}")
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub listen_port: u16,
    pub runtime_log: bool,
    pub clients: Vec<ClientTarget>,
    pub state_dir: PathBuf,
    pub rules_helper: PathBuf,
}

fn parse_target<I>(args: &mut I, flag: &str) -> Result<PatchTarget, String>
where
    I: Iterator<Item = String>,
{
    let missing = || format!("{flag} requires SELECTOR LATITUDE LONGITUDE");
    let latitude = args
        .next()
        .ok_or_else(missing)?
        .parse::<f64>()
        .map_err(|_| "invalid latitude")?;
    let longitude = args
        .next()
        .ok_or_else(missing)?
        .parse::<f64>()
        .map_err(|_| "invalid longitude")?;
    PatchTarget::new(latitude, longitude).map_err(|error| error.to_string())
}

impl Config {
    pub fn from_args() -> Result<Self, String> {
        Self::from_iter(std::env::args().skip(1))
    }

    fn from_iter<I>(arguments: I) -> Result<Self, String>
    where
        I: IntoIterator<Item = String>,
    {
        let mut listen_port = 61520_u16;
        let mut runtime_log = false;
        let mut clients = Vec::new();
        let mut state_dir = PathBuf::from("/etc/wloc");
        let mut rules_helper = PathBuf::from("/usr/libexec/wloc/rules.sh");
        let mut args = arguments.into_iter();
        while let Some(flag) = args.next() {
            let value = || format!("missing value for {flag}");
            match flag.as_str() {
                "--listen-port" => {
                    listen_port = args
                        .next()
                        .ok_or_else(value)?
                        .parse()
                        .map_err(|_| "invalid listen port")?
                }
                "--runtime-log" => runtime_log = true,
                "--client" => {
                    let id = parse_client_id(&args.next().ok_or_else(value)?)?;
                    let selector = ClientSelector::parse_mac(&args.next().ok_or_else(value)?)?;
                    let target = parse_target(&mut args, &flag)?;
                    clients.push(ClientTarget {
                        name: id.clone(),
                        id,
                        selector,
                        target,
                        outbound: OutboundProxy::Direct,
                    });
                }
                "--client-ip" => {
                    let id = parse_client_id(&args.next().ok_or_else(value)?)?;
                    let selector = ClientSelector::Ipv4(
                        args.next()
                            .ok_or_else(value)?
                            .parse()
                            .map_err(|_| "invalid client IPv4")?,
                    );
                    let target = parse_target(&mut args, &flag)?;
                    clients.push(ClientTarget {
                        name: id.clone(),
                        id,
                        selector,
                        target,
                        outbound: OutboundProxy::Direct,
                    });
                }
                "--client-name" => {
                    let id = parse_client_id(&args.next().ok_or_else(value)?)?;
                    let name = args.next().ok_or_else(value)?;
                    let client = clients
                        .iter_mut()
                        .find(|client| client.id == id)
                        .ok_or_else(|| format!("name refers to unknown client rule ID: {id}"))?;
                    client.name = name;
                }
                "--client-proxy" => {
                    let id = parse_client_id(&args.next().ok_or_else(value)?)?;
                    let proxy_type = args.next().ok_or_else(value)?;
                    let host = parse_proxy_host(&args.next().ok_or_else(value)?)?;
                    let port = args
                        .next()
                        .ok_or_else(value)?
                        .parse::<u16>()
                        .map_err(|_| "invalid proxy port")?;
                    if port == 0 {
                        return Err("invalid proxy port".into());
                    }
                    let outbound = match proxy_type.as_str() {
                        "http" => OutboundProxy::Http { host, port },
                        "socks5" => OutboundProxy::Socks5 { host, port },
                        _ => return Err("proxy type must be http or socks5".into()),
                    };
                    let client = clients
                        .iter_mut()
                        .find(|client| client.id == id)
                        .ok_or_else(|| format!("proxy refers to unknown client rule ID: {id}"))?;
                    if client.outbound != OutboundProxy::Direct {
                        return Err(format!("duplicate proxy for client rule ID: {id}"));
                    }
                    client.outbound = outbound;
                }
                "--state-dir" => state_dir = PathBuf::from(args.next().ok_or_else(value)?),
                "--rules-helper" => rules_helper = PathBuf::from(args.next().ok_or_else(value)?),
                "--help" | "-h" => return Err(Self::usage().to_owned()),
                _ => return Err(format!("unknown argument: {flag}\n{}", Self::usage())),
            }
        }
        if clients.is_empty() {
            return Err("at least one --client or --client-ip is required".into());
        }
        clients.sort_by_key(|client| client.selector.label());
        for pair in clients.windows(2) {
            if pair[0].selector == pair[1].selector {
                return Err(format!(
                    "duplicate client selector: {}",
                    pair[0].selector.label()
                ));
            }
        }
        let mut ids = clients
            .iter()
            .map(|client| client.id.as_str())
            .collect::<Vec<_>>();
        ids.sort_unstable();
        if ids.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err("duplicate client rule ID".into());
        }
        Ok(Self {
            listen_port,
            runtime_log,
            clients,
            state_dir,
            rules_helper,
        })
    }

    pub const fn usage() -> &'static str {
        "wlocd --client ID MAC LATITUDE LONGITUDE [--client-name ID NAME] [--client ...] [--client-proxy ID TYPE HOST PORT] [--client-ip ID IPv4 LATITUDE LONGITUDE] [--listen-port PORT] [--runtime-log]"
    }
}

fn parse_proxy_host(value: &str) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 253
        || value
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return Err("invalid proxy host".into());
    }
    Ok(value.to_owned())
}

fn parse_client_id(value: &str) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("invalid client rule ID".into());
    }
    Ok(value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_the_default_listen_port() {
        let config = Config::from_iter(
            ["--client", "client_a", "02:11:22:33:44:55", "1", "2"]
                .into_iter()
                .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(config.listen_port, 61520);
    }

    #[test]
    fn parses_multiple_clients_and_normalizes_mac() {
        let config = Config::from_iter(
            [
                "--client",
                "client_a",
                "AA:BB:CC:DD:EE:02",
                "51.5074",
                "-0.1277",
                "--client",
                "client_b",
                "02:11:22:33:44:55",
                "22.3193",
                "114.1694",
                "--client-name",
                "client_b",
                "iPhone SE 3",
            ]
            .into_iter()
            .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(config.clients.len(), 2);
        assert_eq!(config.clients[1].selector.label(), "aa:bb:cc:dd:ee:02");
        assert_eq!(config.clients[1].target.latitude, 51.5074);
        let named = config
            .clients
            .iter()
            .find(|client| client.id == "client_b")
            .unwrap();
        assert_eq!(named.name, "iPhone SE 3");
        assert_eq!(
            named.log_context(),
            "device=\"iPhone SE 3\" mac=02:11:22:33:44:55"
        );
        assert_eq!(
            named.log_context_with_ip("192.0.2.10".parse().unwrap()),
            "device=\"iPhone SE 3\" mac=02:11:22:33:44:55 ip=192.0.2.10"
        );
        let default_named = config
            .clients
            .iter()
            .find(|client| client.id == "client_a")
            .unwrap();
        assert!(default_named
            .log_context()
            .contains("mac=AA:BB:CC:DD:EE:02"));
    }

    #[test]
    fn rejects_duplicate_and_multicast_mac() {
        let duplicate = Config::from_iter(
            [
                "--client",
                "client_a",
                "02:11:22:33:44:55",
                "1",
                "2",
                "--client",
                "client_b",
                "02:11:22:33:44:55",
                "4",
                "5",
            ]
            .into_iter()
            .map(str::to_owned),
        );
        assert!(duplicate.unwrap_err().contains("duplicate"));
        assert!(ClientSelector::parse_mac("01:00:5e:00:00:01").is_err());

        let duplicate_id = Config::from_iter(
            [
                "--client",
                "same",
                "02:11:22:33:44:55",
                "1",
                "2",
                "--client",
                "same",
                "02:11:22:33:44:56",
                "4",
                "5",
            ]
            .into_iter()
            .map(str::to_owned),
        );
        assert!(duplicate_id.unwrap_err().contains("rule ID"));
        assert!(parse_client_id("contains space").is_err());
    }

    #[test]
    fn parses_per_client_http_and_socks5_proxies() {
        let config = Config::from_iter(
            [
                "--client",
                "direct",
                "02:11:22:33:44:51",
                "1",
                "2",
                "--client",
                "proxied",
                "02:11:22:33:44:52",
                "4",
                "5",
                "--client-proxy",
                "proxied",
                "socks5",
                "192.0.2.10",
                "1080",
            ]
            .into_iter()
            .map(str::to_owned),
        )
        .unwrap();
        let direct = config
            .clients
            .iter()
            .find(|client| client.id == "direct")
            .unwrap();
        assert_eq!(direct.outbound, OutboundProxy::Direct);
        let proxied = config
            .clients
            .iter()
            .find(|client| client.id == "proxied")
            .unwrap();
        assert_eq!(
            proxied.outbound,
            OutboundProxy::Socks5 {
                host: "192.0.2.10".into(),
                port: 1080
            }
        );
    }
}
