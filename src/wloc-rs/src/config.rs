use std::net::IpAddr;
use std::path::PathBuf;

use crate::wloc::PatchTarget;

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
    pub ssid: String,
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
            "rule_name=\"{}\" ssid=\"{}\"",
            self.safe_log_name(),
            safe_log_value(&self.ssid)
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
    let missing = || format!("{flag} requires ID SSID LATITUDE LONGITUDE");
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
                    let ssid = parse_ssid(&args.next().ok_or_else(value)?)?;
                    if rules
                        .iter()
                        .any(|rule: &LocationRule| rule.ssid == ssid)
                    {
                        return Err(format!("duplicate SSID: {ssid}"));
                    }
                    let target = parse_target(&mut args, &flag)?;
                    rules.push(LocationRule {
                        name: id.clone(),
                        id,
                        ssid,
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

    pub const fn usage() -> &'static str {
        "wlocd --rule ID SSID LATITUDE LONGITUDE [--rule-name ID NAME] [--rule-proxy ID TYPE HOST PORT] [--rule ...] [--listen-port PORT] [--runtime-log]"
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

fn parse_ssid(value: &str) -> Result<String, String> {
    if value.is_empty() || value.len() > 32 || value.chars().any(char::is_control) {
        return Err("invalid SSID".into());
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
            "ap1",
            "SSID-US",
            "1",
            "2",
            "--rule",
            "ap2",
            "SSID-EU",
            "3",
            "4",
        ]))
        .unwrap();
        assert_eq!(
            config
                .rules
                .iter()
                .map(|rule| rule.id.as_str())
                .collect::<Vec<_>>(),
            ["ap1", "ap2"]
        );
    }

    #[test]
    fn parses_rule_metadata_and_proxy() {
        let config = Config::from_iter(args(&[
            "--rule",
            "ap",
            "SSID-London",
            "51.5074",
            "-0.1277",
            "--rule-name",
            "ap",
            "Living room",
            "--rule-proxy",
            "ap",
            "socks5",
            "192.0.2.10",
            "1080",
        ]))
        .unwrap();
        let rule = &config.rules[0];
        assert_eq!(rule.name, "Living room");
        assert_eq!(
            rule.outbound,
            OutboundProxy::Socks5 {
                host: "192.0.2.10".into(),
                port: 1080
            }
        );
    }

    #[test]
    fn rejects_duplicate_ssids_and_ids() {
        let duplicate_ssid = Config::from_iter(args(&[
            "--rule",
            "first",
            "SSID-US",
            "1",
            "2",
            "--rule",
            "second",
            "SSID-US",
            "3",
            "4",
        ]));
        assert!(duplicate_ssid.unwrap_err().contains("duplicate SSID"));

        let duplicate_id = Config::from_iter(args(&[
            "--rule",
            "same",
            "SSID-US",
            "1",
            "2",
            "--rule",
            "same",
            "SSID-EU",
            "3",
            "4",
        ]));
        assert!(duplicate_id.unwrap_err().contains("duplicate rule ID"));
    }

    #[test]
    fn ssid_is_exact_and_preserves_case_and_spaces() {
        let config =
            Config::from_iter(args(&["--rule", "diablo", "Home WiFi", "1", "2"])).unwrap();
        assert_eq!(config.rules[0].ssid, "Home WiFi");
        assert!(Config::from_iter(args(&["--rule", "bad", "", "1", "2"])).is_err());
        assert!(Config::from_iter(args(&["--rule", "bad", "Home\nWiFi", "1", "2"])).is_err());
        assert!(Config::from_iter(args(&["--rule", "bad", &"x".repeat(33), "1", "2"])).is_err());
    }
}
