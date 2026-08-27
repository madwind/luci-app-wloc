use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::config::MacAddress;

const CACHE_TTL: Duration = Duration::from_secs(2);
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(5);
const SYNC_LOOKUP_BUDGET: Duration = Duration::from_secs(4);
const UBUS_TIMEOUT_SECONDS: &str = "1";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccessPoint {
    pub ssid: String,
    pub bssid: MacAddress,
    pub interface: String,
}

#[derive(Clone)]
pub struct HostapdNetworkSource {
    ubus_path: PathBuf,
    state: Arc<tokio::sync::Mutex<LookupState>>,
}

#[derive(Default)]
struct LookupState {
    results: HashMap<MacAddress, CachedAccessPoint>,
    in_flight: HashMap<MacAddress, Arc<tokio::sync::Mutex<()>>>,
}

#[derive(Clone)]
struct CachedAccessPoint {
    result: Result<Option<AccessPoint>, String>,
    expires_at: Instant,
}

impl HostapdNetworkSource {
    pub fn new() -> Self {
        Self {
            ubus_path: std::env::var_os("WLOC_UBUS_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("ubus")),
            state: Arc::new(tokio::sync::Mutex::new(LookupState::default())),
        }
    }

    /// Coalesce simultaneous lookups and retain only a short runtime snapshot.
    pub async fn current_for(&self, mac: MacAddress) -> Result<Option<AccessPoint>, String> {
        let lookup_gate = {
            let mut state = self.state.lock().await;
            let now = Instant::now();
            state.results.retain(|_, entry| entry.expires_at > now);
            state
                .in_flight
                .retain(|_, gate| Arc::strong_count(gate) > 1);
            if let Some(entry) = state.results.get(&mac) {
                return entry.result.clone();
            }
            Arc::clone(
                state
                    .in_flight
                    .entry(mac)
                    .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(()))),
            )
        };

        let _lookup = lookup_gate.lock().await;
        {
            let mut state = self.state.lock().await;
            let now = Instant::now();
            state.results.retain(|_, entry| entry.expires_at > now);
            if let Some(entry) = state.results.get(&mac) {
                return entry.result.clone();
            }
        }

        let ubus_path = self.ubus_path.clone();
        let task = tokio::task::spawn_blocking(move || current_for_sync(&ubus_path, mac));
        let result = match tokio::time::timeout(LOOKUP_TIMEOUT, task).await {
            Ok(Ok(result)) => result,
            Ok(Err(error)) => Err(format!("hostapd lookup task failed: {error}")),
            Err(_) => Err("hostapd lookup timed out".to_owned()),
        };

        let mut state = self.state.lock().await;
        state.results.insert(
            mac,
            CachedAccessPoint {
                result: result.clone(),
                expires_at: Instant::now() + CACHE_TTL,
            },
        );
        let owns_gate = state
            .in_flight
            .get(&mac)
            .is_some_and(|gate| Arc::ptr_eq(gate, &lookup_gate));
        if owns_gate {
            state.in_flight.remove(&mac);
        }
        result
    }
}

impl Default for HostapdNetworkSource {
    fn default() -> Self {
        Self::new()
    }
}

fn current_for_sync(ubus: &Path, mac: MacAddress) -> Result<Option<AccessPoint>, String> {
    let deadline = Instant::now() + SYNC_LOOKUP_BUDGET;
    let objects = command_output(
        ubus,
        &["-S", "-t", UBUS_TIMEOUT_SECONDS, "list", "hostapd.*"],
    )?;
    for object in objects
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if Instant::now() >= deadline {
            return Err("hostapd lookup exceeded its time budget".into());
        }
        if !object.starts_with("hostapd.") || !safe_object_name(object) {
            continue;
        }
        let Ok(clients) = call_json(ubus, object, "get_clients") else {
            continue;
        };
        if !has_client(&clients, mac) {
            continue;
        }
        let status = call_json(ubus, object, "get_status")?;
        return access_point_from_status(object, &status).map(Some);
    }
    Ok(None)
}

fn command_output(program: &Path, arguments: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|error| format!("ubus unavailable: {}", error.kind()))?;
    if !output.status.success() {
        return Err(format!("ubus exited with {}", output.status));
    }
    String::from_utf8(output.stdout).map_err(|_| "ubus returned non-UTF-8 output".into())
}

fn call_json(ubus: &Path, object: &str, method: &str) -> Result<Value, String> {
    let output = command_output(
        ubus,
        &[
            "-S",
            "-t",
            UBUS_TIMEOUT_SECONDS,
            "call",
            object,
            method,
            "{}",
        ],
    )?;
    serde_json::from_str(&output)
        .map_err(|error| format!("invalid {object}.{method} JSON: {error}"))
}

fn safe_object_name(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn has_client(value: &Value, mac: MacAddress) -> bool {
    let expected = mac.label();
    value
        .get("clients")
        .and_then(Value::as_object)
        .or_else(|| value.as_object())
        .is_some_and(|clients| {
            clients
                .keys()
                .any(|candidate| candidate.eq_ignore_ascii_case(&expected))
        })
}

fn access_point_from_status(object: &str, value: &Value) -> Result<AccessPoint, String> {
    let bssid = value
        .get("bssid")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{object}.get_status omitted BSSID"))?;
    let interface = ["interface", "ifname"]
        .iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| object.trim_start_matches("hostapd."));
    if interface.is_empty()
        || !interface
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(format!("{object}.get_status returned an invalid interface"));
    }
    Ok(AccessPoint {
        ssid: value
            .get("ssid")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        bssid: MacAddress::parse(bssid)?,
        interface: interface.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_client_case_insensitively() {
        let value: Value =
            serde_json::from_str(r#"{"clients":{"AA:BB:CC:DD:EE:01":{"signal":-40}}}"#)
                .unwrap();
        assert!(has_client(
            &value,
            MacAddress::parse("aa:bb:cc:dd:ee:01").unwrap()
        ));
    }

    #[test]
    fn status_exposes_bssid_and_ssid_for_runtime_matching() {
        let value: Value = serde_json::from_str(
            r#"{"ssid":"Shared name","bssid":"AA:BB:CC:DD:EE:02","ifname":"wlan1"}"#,
        )
        .unwrap();
        let access_point = access_point_from_status("hostapd.wlan1", &value).unwrap();
        assert_eq!(access_point.ssid, "Shared name");
        assert_eq!(access_point.bssid.label(), "aa:bb:cc:dd:ee:02");
        assert_eq!(access_point.interface, "wlan1");
    }
}
