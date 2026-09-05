from pathlib import Path


def replace_once(path, old, new, label):
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, got {count}")
    file.write_text(text.replace(old, new, 1))


replace_once(
    "root/usr/share/wloc/defaults/firewall.nft",
    '        meta l4proto { tcp, udp } th dport 53 ct mark set ct mark | 0x00010000 meta mark set meta mark | 0x40010000 counter tproxy to :%port% accept comment "wloc dns"\n',
    '        meta l4proto { tcp, udp } th dport 53 ct mark set ct mark | 0x00010000 meta mark set 0x40010000 counter tproxy to :%port% accept comment "wloc dns"\n',
    "clean DNS packet mark",
)

replace_once(
    "src/wloc-rs/src/outbound.rs",
    '            "TPROXY outbound marks require Linux",\n',
    '            "WLOC outbound marks require Linux",\n',
    "outbound mark error",
)

replace_once(
    "src/wloc-rs/src/dns.rs",
    "use crate::proxy::Proxy;\n",
    "use crate::proxy::Proxy;\nuse crate::status::Status;\n",
    "DNS status import",
)
replace_once(
    "src/wloc-rs/src/dns.rs",
    "    rules_helper: PathBuf,\n    debug: bool,\n",
    "    rules_helper: PathBuf,\n    status: Arc<Status>,\n    debug: bool,\n",
    "DNS status field",
)
replace_once(
    "src/wloc-rs/src/dns.rs",
    "    pub fn new(domains: Vec<String>, rules_helper: PathBuf, debug: bool) -> Self {\n",
    "    pub fn new(\n        domains: Vec<String>,\n        rules_helper: PathBuf,\n        status: Arc<Status>,\n        debug: bool,\n    ) -> Self {\n",
    "DNS status constructor",
)
replace_once(
    "src/wloc-rs/src/dns.rs",
    "                rules_helper,\n                debug,\n",
    "                rules_helper,\n                status,\n                debug,\n",
    "DNS status initialization",
)
replace_once(
    "src/wloc-rs/src/dns.rs",
    '''        *current = next;
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
''',
    '''        *current = next;
        let detail = format!(
            "rule={} name={} qtype={} added={} targets={} action=firewall_reloaded",
            rule.id,
            question.name,
            question.qtype,
            added,
            next_values.len()
        );
        self.inner.status.update_detail(
            "location_targets_updated",
            &detail,
            None,
            |c| c.armed(true),
        );
        if self.inner.debug {
            eprintln!("wlocd: debug=dns event=location_targets_updated {detail}");
        }
''',
    "DNS status update",
)
replace_once(
    "src/wloc-rs/src/main.rs",
    '''        let dns_tracker = DnsTracker::new(
            config.domains.clone(),
            config.rules_helper.clone(),
            config.debug,
        );
''',
    '''        let dns_tracker = DnsTracker::new(
            config.domains.clone(),
            config.rules_helper.clone(),
            Arc::clone(&status),
            config.debug,
        );
''',
    "DNS tracker status argument",
)
