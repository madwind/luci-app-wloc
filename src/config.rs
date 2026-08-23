use std::net::IpAddr;
use std::path::PathBuf;

use crate::wloc::PatchTarget;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceSelector {
    All,
    Mac(MacAddress),
}

impl DeviceSelector {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "*" => Ok(Self::All),
            value => MacAddress::parse(value).map(Self::Mac),
        }
    }

    pub fn matches(&self, mac: MacAddress) -> bool {
        matches!(self, Self::All) || matches!(self, Self::Mac(expected) if *expected == mac)
    }

    pub fn label(&self) -> String {
        match self {
            Self::All => "all".into(),
            Self::Mac(mac) => mac.label(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NetworkSelector {
    Any,
    Ssid(String),
    Bssid(MacAddress),
}

impl NetworkSelector {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "*" => Ok(Self::Any),
            value if value.starts_with("ssid:") => {
                let ssid = &value["ssid:".len()..];
                if ssid.is_empty()
                    || ssid.len() > 32
                    || ssid
                        .chars()
                        .any(|character| character == '\0' || character.is_control())
                {
                    return Err("invalid SSID".into());
                }
                Ok(Self::Ssid(ssid.into()))
            }
            value => MacAddress::parse(value).map(Self::Bssid),
        }
    }

    pub fn matches(&self, bssid: Option<MacAddress>, ssid: Option<&str>) -> bool {
        match self {
            Self::Any => true,
            Self::Ssid(expected) => ssid == Some(expected.as_str()),
            Self::Bssid(expected) => bssid == Some(*expected),
        }
    }

    pub fn label(&self) -> String {
        match self {
            Self::Any => "any".into(),
            Self::Ssid(ssid) => format!("ssid:{ssid}"),
            Self::Bssid(bssid) => bssid.label(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LocationRule {
    pub id: String,
    pub name: String,
    pub device: DeviceSelector,
    pub network: NetworkSelector,
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
            "rule_name=\"{}\" device={} network={}",
            self.safe_log_name(),
            self.device.label().to_uppercase(),
            self.network.label().to_uppercase()
        )
    }

    pub fn log_context_with_ip(&self, ip: IpAddr) -> String {
        format!("{} ip={ip}", self.log_context())
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub listen_port: u16,
    pub runtime_log: bool,
    /// Enabled rules in exact UCI order. Never sort this vector.
    pub rules: Vec<LocationRule>,
    pub state_dir: PathBuf,
    pub rules_helper: PathBuf,
}

fn parse_target<I>(args: &mut I, flag: &str) -> Result<PatchTarget, String>
where
    I: Iterator<Item = String>,
{
    let missing = || format!("{flag} requires ID DEVICE NETWORK LATITUDE LONGITUDE");
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
                "--runtime-log" => runtime_log = true,
                "--rule" => {
                    let id = parse_rule_id(&args.next().ok_or_else(value)?)?;
                    if rules.iter().any(|rule: &LocationRule| rule.id == id) {
                        return Err(format!("duplicate rule ID: {id}"));
                    }
                    let device = DeviceSelector::parse(&args.next().ok_or_else(value)?)?;
                    let network = NetworkSelector::parse(&args.next().ok_or_else(value)?)?;
                    let target = parse_target(&mut args, &flag)?;
                    rules.push(LocationRule {
                        name: id.clone(),
                        id,
                        device,
                        network,
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
                        "http" => OutboundProxy::Http { host, port },
                        "socks5" => OutboundProxy::Socks5 { host, port },
                        _ => return Err("proxy type must be http or socks5".into()),
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
            runtime_log,
            rules,
            state_dir,
            rules_helper,
        })
    }

    pub fn capture_selectors(&self) -> Vec<String> {
        let mut selectors = Vec::new();
        for rule in &self.rules {
            let selector = match (rule.device, &rule.network) {
                (DeviceSelector::Mac(mac), _) => format!("mac:{}", mac.label()),
                (DeviceSelector::All, NetworkSelector::Bssid(bssid)) => {
                    format!("bssid:{}", bssid.label())
                }
                (DeviceSelector::All, NetworkSelector::Any | NetworkSelector::Ssid(_)) => {
                    "wireless:any".into()
                }
            };
            if !selectors.contains(&selector) {
                selectors.push(selector);
            }
        }
        selectors
    }

    pub const fn usage() -> &'static str {
        "wlocd --rule ID MAC_OR_* NETWORK_OR_* LATITUDE LONGITUDE [--rule-name ID NAME] [--rule-proxy ID TYPE HOST PORT] [--rule ...] [--listen-port PORT] [--runtime-log]"
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

#[cfg(test)]
mod tests {
    use super::*;

    fn args<'a>(values: &'a [&'a str]) -> impl Iterator<Item = String> + 'a {
        values.iter().map(|value| (*value).to_owned())
    }

    #[test]
    fn preserves_rule_order_without_implicit_priority() {
        let config = Config::from_iter(args(&[
            "--rule",
            "iphone_ap1",
            "02:11:22:33:44:55",
            "aa:bb:cc:dd:ee:01",
            "1",
            "2",
            "--rule",
            "all_ap1",
            "*",
            "aa:bb:cc:dd:ee:01",
            "3",
            "4",
            "--rule",
            "fallback",
            "*",
            "*",
            "5",
            "6",
        ]))
        .unwrap();
        assert_eq!(
            config
                .rules
                .iter()
                .map(|rule| rule.id.as_str())
                .collect::<Vec<_>>(),
            ["iphone_ap1", "all_ap1", "fallback"]
        );
        assert_eq!(
            config.capture_selectors(),
            [
                "mac:02:11:22:33:44:55",
                "bssid:aa:bb:cc:dd:ee:01",
                "wireless:any"
            ]
        );
    }

    #[test]
    fn parses_rule_metadata_and_proxy() {
        let config = Config::from_iter(args(&[
            "--rule",
            "phone",
            "02:11:22:33:44:55",
            "*",
            "51.5074",
            "-0.1277",
            "--rule-name",
            "phone",
            "iPhone 16",
            "--rule-proxy",
            "phone",
            "socks5",
            "192.0.2.10",
            "1080",
        ]))
        .unwrap();
        let rule = &config.rules[0];
        assert_eq!(rule.name, "iPhone 16");
        assert_eq!(
            rule.outbound,
            OutboundProxy::Socks5 {
                host: "192.0.2.10".into(),
                port: 1080
            }
        );
    }

    #[test]
    fn accepts_overlapping_rules_but_rejects_duplicate_ids() {
        let overlapping = Config::from_iter(args(&[
            "--rule",
            "first",
            "02:11:22:33:44:55",
            "*",
            "1",
            "2",
            "--rule",
            "second",
            "02:11:22:33:44:55",
            "*",
            "3",
            "4",
        ]));
        assert!(overlapping.is_ok());

        let duplicate_id = Config::from_iter(args(&[
            "--rule", "same", "*", "*", "1", "2", "--rule", "same", "*", "*", "3", "4",
        ]));
        assert!(duplicate_id.unwrap_err().contains("duplicate rule ID"));
        assert!(MacAddress::parse("01:00:5e:00:00:01").is_err());
    }

    #[test]
    fn network_and_device_matchers_are_explicit() {
        let phone = MacAddress::parse("02:11:22:33:44:55").unwrap();
        let ap = MacAddress::parse("aa:bb:cc:dd:ee:01").unwrap();
        assert!(DeviceSelector::All.matches(phone));
        assert!(DeviceSelector::Mac(phone).matches(phone));
        assert!(NetworkSelector::Any.matches(None, None));
        assert!(NetworkSelector::Bssid(ap).matches(Some(ap), Some("Diablo")));
        assert!(!NetworkSelector::Bssid(ap).matches(None, Some("Diablo")));
        assert!(NetworkSelector::Ssid("Diablo".into()).matches(Some(ap), Some("Diablo")));
        assert!(!NetworkSelector::Ssid("Diablo".into()).matches(Some(ap), Some("diablo")));
    }

    #[test]
    fn ssid_network_selectors_capture_all_wireless_interfaces() {
        let config =
            Config::from_iter(args(&["--rule", "diablo", "*", "ssid:Diablo", "1", "2"])).unwrap();
        assert_eq!(config.capture_selectors(), ["wireless:any"]);
        assert_eq!(config.rules[0].network.label(), "ssid:Diablo");
    }
}
