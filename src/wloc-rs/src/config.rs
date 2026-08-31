use std::net::IpAddr;
use std::path::PathBuf;

use crate::wloc::PatchTarget;
use crate::DEFAULT_DOMAINS;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutboundProxy {
    Direct,
    Http { host: String, port: u16 },
    Socks5 { host: String, port: u16 },
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct MacAddress([u8; 6]);

impl MacAddress {
    pub fn parse(value: &str) -> Result<Self, String> {
        let mut bytes = [0_u8; 6];
        let parts = value.split(':').collect::<Vec<_>>();
        if parts.len() != 6 {
            return Err("invalid MAC address".into());
        }
        for (index, part) in parts.iter().enumerate() {
            if part.len() != 2 {
                return Err("invalid MAC address".into());
            }
            bytes[index] =
                u8::from_str_radix(part, 16).map_err(|_| "invalid MAC address".to_owned())?;
        }
        if bytes == [0; 6] || bytes == [0xff; 6] || bytes[0] & 1 != 0 {
            return Err("MAC must be an individual unicast address".into());
        }
        Ok(Self(bytes))
    }

    pub fn label(self) -> String {
        self.0
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<Vec<_>>()
            .join(":")
    }
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

#[derive(Clone, Debug, PartialEq)]
pub struct LocationRule {
    pub id: String,
    pub name: String,
    pub iface: String,
    pub target: PatchTarget,
    pub outbound: OutboundProxy,
}

impl LocationRule {
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
            .collect()
    }

    pub fn log_context(&self) -> String {
        format!(
            "rule_name=\"{}\" iface=\"{}\"",
            self.safe_log_name(),
            safe_log_value(&self.iface)
        )
    }

    pub fn log_context_with_ip(&self, ip: IpAddr) -> String {
        format!("{} ip={ip}", self.log_context())
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub listen_port: u16,
    pub domains: Vec<String>,
    pub debug: bool,
    /// Enabled rules in exact UCI order. Never sort this vector.
    pub rules: Vec<LocationRule>,
    pub state_dir: PathBuf,
    pub rules_helper: PathBuf,
}

fn parse_target<I>(args: &mut I, flag: &str) -> Result<PatchTarget, String>
where
    I: Iterator<Item = String>,
{
    let missing = || format!("{flag} requires ID IFACE LATITUDE LONGITUDE");
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
        let domains = DEFAULT_DOMAINS
            .iter()
            .map(|domain| (*domain).to_owned())
            .collect::<Vec<_>>();
        let mut debug = false;
        let mut rules = Vec::new();
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
                "--debug" => debug = true,
                "--rule" => {
                    let id = parse_rule_id(&args.next().ok_or_else(value)?)?;
                    if rules.iter().any(|rule: &LocationRule| rule.id == id) {
                        return Err(format!("duplicate rule ID: {id}"));
                    }
                    let iface = parse_iface(&args.next().ok_or_else(value)?)?;
                    if rules.iter().any(|rule: &LocationRule| rule.iface == iface) {
                        return Err(format!("duplicate interface: {iface}"));
                    }
                    let target = parse_target(&mut args, &flag)?;
                    rules.push(LocationRule {
                        name: id.clone(),
                        id,
                        iface,
                        target,
                        outbound: OutboundProxy::Direct,
                    });
                }
                "--rule-name" => {
                    let id = parse_rule_id(&args.next().ok_or_else(value)?)?;
                    rule_mut(&mut rules, &id, "name")?.name = args.next().ok_or_else(value)?;
                }
                "--rule-proxy" => {
                    let id = parse_rule_id(&args.next().ok_or_else(value)?)?;
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
                        "socks5" => OutboundProxy::Socks5 { host, port },
                        _ => return Err("proxy type must be socks5".into()),
                    };
                    let rule = rule_mut(&mut rules, &id, "proxy")?;
                    if rule.outbound != OutboundProxy::Direct {
                        return Err(format!("duplicate proxy for rule ID: {id}"));
                    }
                    rule.outbound = outbound;
                }
                "--state-dir" => state_dir = PathBuf::from(args.next().ok_or_else(value)?),
                "--rules-helper" => rules_helper = PathBuf::from(args.next().ok_or_else(value)?),
                "--help" | "-h" => return Err(Self::usage().to_owned()),
                _ => return Err(format!("unknown argument: {flag}\n{}", Self::usage())),
            }
        }
        if rules.is_empty() {
            return Err("at least one --rule is required".into());
        }
        Ok(Self {
            listen_port,
            domains,
            debug,
            rules,
            state_dir,
            rules_helper,
        })
    }

    pub const fn usage() -> &'static str {
        "wlocd --rule ID IFACE LATITUDE LONGITUDE [--rule-name ID NAME] [--rule-proxy ID socks5 HOST PORT] [--rule ...] [--listen-port PORT] [--debug]"
    }
}

fn rule_mut<'a>(
    rules: &'a mut [LocationRule],
    id: &str,
    attribute: &str,
) -> Result<&'a mut LocationRule, String> {
    rules
        .iter_mut()
        .find(|rule| rule.id == id)
        .ok_or_else(|| format!("{attribute} refers to unknown rule ID: {id}"))
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

fn parse_rule_id(value: &str) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("invalid rule ID".into());
    }
    Ok(value.to_owned())
}

fn parse_iface(value: &str) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 15
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("invalid interface".into());
    }
    Ok(value.to_owned())
}

fn safe_log_value(value: &str) -> String {
    value
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
