use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

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

#[derive(Clone, Default)]
struct UpstreamTarget {
    domain: Option<String>,
    upstream_ip: Option<String>,
    proxy_ip: Option<String>,
}

struct Inner {
    snapshot: Snapshot,
    upstream_targets: HashMap<String, UpstreamTarget>,
}

pub struct Status {
    started: Instant,
    inner: Mutex<Inner>,
    pending: Arc<Mutex<Option<Snapshot>>>,
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
        .map(|character| if character.is_control() { ' ' } else { character })
        .take(limit)
        .collect()
}

fn detail_token(detail: &str, name: &str) -> Option<String> {
    let prefix = format!("{name}=");
    detail
        .split_whitespace()
        .find_map(|token| token.strip_prefix(&prefix))
        .filter(|value| !value.is_empty())
        .map(|value| safe_text(value, 255))
}

impl Status {
    pub fn new(
        path: PathBuf,
        configured_aps: usize,
        fingerprint: String,
    ) -> std::io::Result<Self> {
        let now = epoch_seconds();
        let snapshot = Snapshot {
            running: true,
            configured_aps,
            ca_fingerprint: fingerprint,
            last_event: "session_started".into(),
            session_started_at: now,
            updated_at: now,
            ..Snapshot::default()
        };
        let initial = serde_json::to_vec_pretty(&snapshot).map_err(std::io::Error::other)?;
        let pending = Arc::new(Mutex::new(None));
        let (notify, receiver) = mpsc::sync_channel(1);
        spawn_writer(path.clone(), Arc::clone(&pending), receiver)?;
        write_atomic(&path, &initial)?;
        eprintln!("wlocd: [+000.000s] event=session_started configured_aps={configured_aps}");

        Ok(Self {
            started: Instant::now(),
            inner: Mutex::new(Inner {
                snapshot,
                upstream_targets: HashMap::new(),
            }),
            pending,
            notify,
        })
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

    fn update_counters_silent(&self, mutate: impl FnOnce(&mut Counters<'_>)) {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mutate(&mut Counters {
            snapshot: &mut inner.snapshot,
        });
        inner.snapshot.updated_at = epoch_seconds();
        let snapshot = inner.snapshot.clone();
        drop(inner);
        *self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(snapshot);
        let _ = self.notify.try_send(());
    }

    pub fn count_passthrough_connection(&self) {
        self.update_counters_silent(|counters| {
            counters.accepted();
            counters.passthrough();
        });
    }

    pub fn count_tls_intercepted(&self) {
        self.update_counters_silent(|counters| counters.tls());
    }

    pub fn count_patched_response(&self) {
        self.update_counters_silent(|counters| counters.patched());
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

        let rule_id = detail_token(detail, "rule");
        if let Some(rule_id) = rule_id.as_ref() {
            let domain = detail_token(detail, "host");
            let upstream_ip = detail_token(detail, "upstream_ip");
            let proxy_ip = detail_token(detail, "proxy_ip");
            if domain.is_some() || upstream_ip.is_some() || proxy_ip.is_some() {
                let target = inner.upstream_targets.entry(rule_id.clone()).or_default();
                if let Some(domain) = domain {
                    target.domain = Some(domain);
                }
                if let Some(upstream_ip) = upstream_ip {
                    target.upstream_ip = Some(upstream_ip);
                }
                if let Some(proxy_ip) = proxy_ip {
                    target.proxy_ip = Some(proxy_ip);
                }
            }
        }

        let enriched_error = error.map(|value| {
            let base = safe_text(value, 240);
            if event != "ap_failed" {
                return base;
            }
            let Some(target) = rule_id
                .as_ref()
                .and_then(|rule| inner.upstream_targets.get(rule))
            else {
                return base;
            };

            let mut message = base;
            if !message.contains("domain=") {
                if let Some(domain) = target.domain.as_deref() {
                    message.push_str(" · domain=");
                    message.push_str(domain);
                }
            }
            if !message.contains("upstream_ip=") {
                if let Some(upstream_ip) = target.upstream_ip.as_deref() {
                    message.push_str(" · upstream_ip=");
                    message.push_str(upstream_ip);
                }
            }
            if target.upstream_ip.is_none() && !message.contains("proxy_ip=") {
                if let Some(proxy_ip) = target.proxy_ip.as_deref() {
                    message.push_str(" · proxy_ip=");
                    message.push_str(proxy_ip);
                }
            }
            safe_text(&message, 360)
        });

        mutate(&mut Counters {
            snapshot: &mut inner.snapshot,
        });

        if event == "ap_failed" {
            if let (Some(rule_id), Some(error)) = (rule_id.as_deref(), enriched_error.as_deref()) {
                if let Some(activity) = inner
                    .snapshot
                    .ap_activity
                    .iter_mut()
                    .find(|activity| activity.ap_id == rule_id)
                {
                    activity.last_error = error.to_owned();
                }
            }
        }

        inner.snapshot.last_event = safe_text(event, 80);
        inner.snapshot.last_error = enriched_error.clone();
        inner.snapshot.updated_at = epoch_seconds();

        eprintln!(
            "wlocd: {}",
            format_log_line(self.started, event, detail, enriched_error.as_deref())
        );
        for line in extra_lines {
            eprintln!(
                "wlocd: {}",
                format_log_line(self.started, "wloc_location_patched", line, None)
            );
        }

        let snapshot = inner.snapshot.clone();
        drop(inner);
        *self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(snapshot);
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

fn spawn_writer(
    path: PathBuf,
    pending: Arc<Mutex<Option<Snapshot>>>,
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
                if let Some(snapshot) = snapshot {
                    let result = serde_json::to_vec_pretty(&snapshot)
                        .map_err(std::io::Error::other)
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
