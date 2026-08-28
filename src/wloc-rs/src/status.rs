use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

const MAX_LOG_LINES: usize = 240;
const MAX_LOG_BYTES: usize = 96 * 1024;
const MAX_LOG_LINE_CHARS: usize = 600;

#[derive(Clone, Default, Serialize)]
struct Snapshot {
    running: bool,
    armed: bool,
    configured_aps: usize,
    ca_fingerprint: String,
    accepted_connections: u64,
    passthrough_connections: u64,
    tls_intercepted: u64,
    wloc_requests: u64,
    patched_responses: u64,
    delivered_responses: u64,
    patch_failures: u64,
    last_event: String,
    last_error: Option<String>,
    session_started_at: u64,
    updated_at: u64,
    runtime_log_enabled: bool,
    runtime_log_revision: u64,
    ap_activity: Vec<ApActivity>,
}

#[derive(Clone, Serialize)]
struct ApActivity {
    ap_id: String,
    latitude: f64,
    longitude: f64,
    last_location_at: u64,
    success: bool,
    last_error: String,
}

struct Inner {
    snapshot: Snapshot,
    logs: VecDeque<String>,
    log_bytes: usize,
}

struct PendingWrite {
    snapshot: Snapshot,
    runtime_log: Option<String>,
}

pub struct Status {
    started: Instant,
    inner: Mutex<Inner>,
    pending: Arc<Mutex<Option<PendingWrite>>>,
    notify: mpsc::SyncSender<()>,
}

fn epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn safe_text(value: &str, limit: usize) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(limit)
        .collect()
}

impl Status {
    pub fn new(
        path: PathBuf,
        log_path: PathBuf,
        configured_aps: usize,
        runtime_log_enabled: bool,
        fingerprint: String,
    ) -> std::io::Result<Self> {
        let now = epoch_seconds();
        let mut logs = VecDeque::new();
        if runtime_log_enabled {
            logs.push_back(format!(
                "[+000.000s] event=session_started configured_aps={configured_aps}"
            ));
        }
        let initial_log_bytes = logs.iter().map(|entry| entry.len() + 1).sum();
        let snapshot = Snapshot {
            running: true,
            configured_aps,
            runtime_log_enabled,
            ca_fingerprint: fingerprint,
            last_event: "session_started".into(),
            session_started_at: now,
            updated_at: now,
            runtime_log_revision: u64::from(runtime_log_enabled),
            ..Snapshot::default()
        };
        let initial = serde_json::to_vec_pretty(&snapshot).map_err(std::io::Error::other)?;
        let pending = Arc::new(Mutex::new(None));
        let (notify, receiver) = mpsc::sync_channel(1);
        spawn_writer(
            path.clone(),
            log_path.clone(),
            Arc::clone(&pending),
            receiver,
        )?;
        write_atomic(&path, &initial)?;
        if runtime_log_enabled {
            write_atomic(
                &log_path,
                logs.iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("\n")
                    .as_bytes(),
            )?;
        } else {
            let _ = std::fs::remove_file(log_path);
        }
        Ok(Self {
            started: Instant::now(),
            inner: Mutex::new(Inner {
                snapshot,
                logs,
                log_bytes: initial_log_bytes,
            }),
            pending,
            notify,
        })
    }

    pub fn runtime_log_enabled(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .snapshot
            .runtime_log_enabled
    }

    pub fn update_detail(
        &self,
        event: &str,
        detail: &str,
        error: Option<&str>,
        mutate: impl FnOnce(&mut Counters<'_>),
    ) {
        self.update_detail_lines(event, detail, &[], error, mutate);
    }

    pub fn update_detail_lines(
        &self,
        event: &str,
        detail: &str,
        extra_lines: &[String],
        error: Option<&str>,
        mutate: impl FnOnce(&mut Counters<'_>),
    ) {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mutate(&mut Counters {
            snapshot: &mut inner.snapshot,
        });
        inner.snapshot.last_event = safe_text(event, 80);
        inner.snapshot.last_error = error.map(|value| safe_text(value, 360));
        inner.snapshot.updated_at = epoch_seconds();

        let runtime_log = if inner.snapshot.runtime_log_enabled {
            push_log(
                &mut inner,
                format_log_line(self.started, event, detail, error),
            );
            for line in extra_lines {
                push_log(
                    &mut inner,
                    format_log_line(self.started, "wloc_location_patched", line, None),
                );
            }
            inner.snapshot.runtime_log_revision =
                inner.snapshot.runtime_log_revision.saturating_add(1);
            Some(inner.logs.iter().cloned().collect::<Vec<_>>().join("\n"))
        } else {
            None
        };
        let snapshot = inner.snapshot.clone();
        drop(inner);
        *self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(PendingWrite {
            snapshot,
            runtime_log,
        });
        let _ = self.notify.try_send(());
    }
}

fn format_log_line(started: Instant, event: &str, detail: &str, error: Option<&str>) -> String {
    let elapsed = started.elapsed().as_secs_f64();
    let mut line = format!("[+{elapsed:07.3}s] event={}", safe_text(event, 80));
    if !detail.is_empty() {
        line.push(' ');
        line.push_str(&safe_text(detail, MAX_LOG_LINE_CHARS));
    }
    if let Some(error) = error {
        line.push_str(" error=");
        line.push_str(&safe_text(error, 360));
    }
    line
}

fn push_log(inner: &mut Inner, line: String) {
    inner.log_bytes = inner.log_bytes.saturating_add(line.len() + 1);
    inner.logs.push_back(line);
    while inner.logs.len() > MAX_LOG_LINES || inner.log_bytes > MAX_LOG_BYTES {
        if let Some(removed) = inner.logs.pop_front() {
            inner.log_bytes = inner.log_bytes.saturating_sub(removed.len() + 1);
        }
    }
}

fn spawn_writer(
    path: PathBuf,
    log_path: PathBuf,
    pending: Arc<Mutex<Option<PendingWrite>>>,
    receiver: mpsc::Receiver<()>,
) -> std::io::Result<()> {
    std::thread::Builder::new()
        .name("wloc-status".into())
        .spawn(move || {
            let mut last_error = None;
            while receiver.recv().is_ok() {
                std::thread::sleep(Duration::from_millis(25));
                while receiver.try_recv().is_ok() {}
                let snapshot = pending
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
                if let Some(pending) = snapshot {
                    let result = pending
                        .runtime_log
                        .as_deref()
                        .map_or(Ok(()), |log| write_atomic(&log_path, log.as_bytes()))
                        .and_then(|_| {
                            serde_json::to_vec_pretty(&pending.snapshot)
                                .map_err(std::io::Error::other)
                        })
                        .and_then(|data| write_atomic(&path, &data));
                    if let Err(error) = result {
                        let now = Instant::now();
                        if last_error.is_none_or(|previous| {
                            now.duration_since(previous) >= Duration::from_secs(60)
                        }) {
                            eprintln!("wlocd: status_write_failed error={}", error.kind());
                            last_error = Some(now);
                        }
                    }
                }
            }
        })
        .map(|_| ())
}

fn write_atomic(path: &PathBuf, data: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(data)?;
    std::fs::rename(temporary, path)
}

pub struct Counters<'a> {
    snapshot: &'a mut Snapshot,
}

impl Counters<'_> {
    pub fn accepted(&mut self) {
        self.snapshot.accepted_connections += 1;
    }
    pub fn passthrough(&mut self) {
        self.snapshot.passthrough_connections += 1;
    }
    pub fn tls(&mut self) {
        self.snapshot.tls_intercepted += 1;
    }
    pub fn wloc(&mut self) {
        self.snapshot.wloc_requests += 1;
    }
    pub fn patched(&mut self) {
        self.snapshot.patched_responses += 1;
    }
    pub fn delivered(&mut self) {
        self.snapshot.delivered_responses += 1;
    }
    pub fn delivered_for(&mut self, ap_id: &str, latitude: f64, longitude: f64) {
        self.snapshot.delivered_responses += 1;
        let now = epoch_seconds();
        if let Some(activity) = self
            .snapshot
            .ap_activity
            .iter_mut()
            .find(|activity| activity.ap_id == ap_id)
        {
            activity.latitude = latitude;
            activity.longitude = longitude;
            activity.last_location_at = now;
            activity.success = true;
            activity.last_error.clear();
        } else {
            self.snapshot.ap_activity.push(ApActivity {
                ap_id: safe_text(ap_id, 80),
                latitude,
                longitude,
                last_location_at: now,
                success: true,
                last_error: String::new(),
            });
        }
    }

    fn mark_failed(&mut self, ap_id: &str, error: &str) {
        let now = epoch_seconds();
        let error = safe_text(error, 360);
        if let Some(activity) = self
            .snapshot
            .ap_activity
            .iter_mut()
            .find(|activity| activity.ap_id == ap_id)
        {
            activity.last_location_at = now;
            activity.success = false;
            activity.last_error = error;
        } else {
            self.snapshot.ap_activity.push(ApActivity {
                ap_id: safe_text(ap_id, 80),
                latitude: 0.0,
                longitude: 0.0,
                last_location_at: now,
                success: false,
                last_error: error,
            });
        }
    }

    pub fn request_failed_for(&mut self, ap_id: &str, error: &str) {
        self.mark_failed(ap_id, error);
    }

    pub fn patch_failed_for(&mut self, ap_id: &str, error: &str) {
        self.snapshot.patch_failures += 1;
        self.mark_failed(ap_id, error);
    }
    pub fn armed(&mut self, value: bool) {
        self.snapshot.armed = value;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_snapshot(path: &PathBuf, event: &str) -> serde_json::Value {
        for _ in 0..100 {
            if let Ok(data) = std::fs::read(path) {
                if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) {
                    if value["last_event"] == event {
                        return value;
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("status snapshot did not reach event {event}");
    }

    fn read_log_until(path: &PathBuf, marker: &str) -> String {
        for _ in 0..200 {
            if let Ok(log) = std::fs::read_to_string(path) {
                if log.contains(marker) {
                    return log;
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("runtime log did not reach marker {marker}");
    }

    #[test]
    fn a_new_session_replaces_old_runtime_logs() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        std::fs::write(&path, br#"{"runtime_log":"old session"}"#).unwrap();
        let status = Status::new(
            path.clone(),
            log_path.clone(),
            2,
            true,
            "fingerprint".into(),
        )
        .unwrap();
        status.update_detail_lines(
            "response_delivered",
            "kind=1 mode=upstream_patched bytes=42",
            &[
                "rule=ap_a source=wifi index=1".into(),
                "rule=ap_a source=wifi index=2".into(),
            ],
            None,
            |c| {
                c.accepted();
                c.patched();
                c.delivered_for("ap_a", 51.5074, -0.1277);
            },
        );
        let value = read_snapshot(&path, "response_delivered");
        let log = std::fs::read_to_string(&log_path).unwrap();
        assert!(log.contains("event=session_started"));
        assert!(log.contains("event=response_delivered"));
        assert_eq!(log.matches("event=wloc_location_patched").count(), 2);
        assert!(!log.contains("old session"));
        assert_eq!(value["accepted_connections"], 1);
        assert_eq!(value["patched_responses"], 1);
        assert_eq!(value["delivered_responses"], 1);
        assert_eq!(value["configured_aps"], 2);
        assert_eq!(value["ap_activity"][0]["ap_id"], "ap_a");
        assert_eq!(value["ap_activity"][0]["success"], true);
        assert_eq!(value["ap_activity"][0]["last_error"], "");
        assert!(value.get("runtime_log").is_none());
        assert!(value["runtime_log_revision"].as_u64().unwrap() >= 2);
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn disabled_runtime_log_does_not_accumulate_events() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-disabled-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        let status = Status::new(
            path.clone(),
            log_path.clone(),
            1,
            false,
            "fingerprint".into(),
        )
        .unwrap();
        status.update_detail("request_received", "body_bytes=42", None, |_| {});
        let value = read_snapshot(&path, "request_received");
        assert_eq!(value["runtime_log_enabled"], false);
        assert_eq!(value["runtime_log_revision"], 0);
        assert!(!log_path.exists());
        assert_eq!(value["last_event"], "request_received");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn ap_failure_is_visible_until_a_successful_response() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-ap-failure-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        let status = Status::new(path.clone(), log_path, 1, false, "fingerprint".into()).unwrap();
        status.update_detail(
            "ap_failed",
            "rule=ap_a category=upstream",
            Some("upstream: timeout"),
            |c| c.request_failed_for("ap_a", "upstream: timeout"),
        );
        let failed = read_snapshot(&path, "ap_failed");
        assert_eq!(failed["ap_activity"][0]["success"], false);
        assert_eq!(failed["ap_activity"][0]["last_error"], "upstream: timeout");

        status.update_detail("response_delivered", "rule=ap_a", None, |c| {
            c.delivered_for("ap_a", 51.5074, -0.1277);
        });
        let recovered = read_snapshot(&path, "response_delivered");
        assert_eq!(recovered["ap_activity"][0]["success"], true);
        assert_eq!(recovered["ap_activity"][0]["last_error"], "");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn runtime_log_stays_within_line_and_byte_limits() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-bounded-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        let status = Status::new(
            path.clone(),
            log_path.clone(),
            1,
            true,
            "fingerprint".into(),
        )
        .unwrap();

        for index in 0..(MAX_LOG_LINES + 32) {
            status.update_detail("bounded_lines", &format!("index={index}"), None, |_| {});
        }
        let last_line = format!("index={}", MAX_LOG_LINES + 31);
        let log = read_log_until(&log_path, &last_line);
        assert!(log.lines().count() <= MAX_LOG_LINES);
        assert!(log.lines().any(|line| line.contains(&last_line)));

        for index in 0..MAX_LOG_LINES {
            let detail = format!("byte_marker={index} {}", "x".repeat(MAX_LOG_LINE_CHARS));
            status.update_detail("bounded_bytes", &detail, None, |_| {});
        }
        let last_bytes = format!("byte_marker={}", MAX_LOG_LINES - 1);
        let log = read_log_until(&log_path, &last_bytes);
        assert!(log.lines().count() <= MAX_LOG_LINES);
        assert!(log.len() <= MAX_LOG_BYTES);
        assert!(log.contains(&last_bytes));

        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn runtime_log_revision_advances_for_each_runtime_event() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-revision-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        let status = Status::new(
            path.clone(),
            log_path.clone(),
            1,
            true,
            "fingerprint".into(),
        )
        .unwrap();

        status.update_detail("revision_one", "", None, |_| {});
        let first = read_snapshot(&path, "revision_one");
        assert_eq!(first["runtime_log_revision"], 2);

        status.update_detail("revision_two", "", None, |_| {});
        let second = read_snapshot(&path, "revision_two");
        assert_eq!(second["runtime_log_revision"], 3);

        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn rapid_status_updates_keep_snapshots_valid() {
        let path = std::env::temp_dir().join(format!(
            "luci-app-wloc-status-atomic-{}-{}.json",
            std::process::id(),
            epoch_seconds()
        ));
        let log_path = path.with_extension("log");
        let status = Status::new(
            path.clone(),
            log_path.clone(),
            1,
            true,
            "fingerprint".into(),
        )
        .unwrap();

        for index in 0..128 {
            status.update_detail("atomic_update", &format!("index={index}"), None, |_| {});
            if let Ok(data) = std::fs::read(&path) {
                serde_json::from_slice::<serde_json::Value>(&data)
                    .expect("status snapshot must always be valid JSON");
            }
        }
        let snapshot = read_snapshot(&path, "atomic_update");
        assert!(snapshot["runtime_log_revision"].as_u64().unwrap() >= 129);

        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(log_path);
    }
}
