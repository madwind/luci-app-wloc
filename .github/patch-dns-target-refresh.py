from pathlib import Path
import re


def read(path):
    return Path(path).read_text()


def write(path, text):
    Path(path).write_text(text)


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"missing marker: {label}")
    if text.count(old) != 1:
        raise SystemExit(f"ambiguous marker: {label}")
    return text.replace(old, new, 1)


def sub_once(text, pattern, replacement, label):
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"regex marker failed: {label} ({count})")
    return updated


# firewall.uc: render all config-derived nft rules and dynamic sets from placeholders.
path = "root/usr/libexec/wloc/firewall.uc"
text = read(path)
text = replace_once(
    text,
    "const OWNED_TABLE = 'wloc';\nlet sequence = 0;",
    "const OWNED_TABLE = 'wloc';\nconst RESERVED_MARK_MASK = 0xc0010000;\nconst INGRESS_MARK = 0x80000000;\nconst HANDLED_MARK = 0x00010000;\nlet sequence = 0;",
    "firewall constants",
)
new_config = r'''function number(value) {
    if (value == null) return null;
    let text = `${value}`;
    if (match(text, /^0[xX][0-9A-Fa-f]+$/)) return int(substr(text, 2), 16);
    if (!match(text, /^[0-9]+$/)) return null;
    let result = +text;
    return result == result ? result : null;
}
function hex32(value) { return sprintf('0x%08x', value); }
function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function valid_port(value) {
    let port = number(value);
    return port != null && port >= 1 && port <= 65535;
}
function valid_mark(value) {
    let mark = number(value);
    return mark != null && mark >= 1 && mark <= 0xffffffff && (mark & RESERVED_MARK_MASK) == 0;
}
function valid_ipv4(value) {
    let fields = split(`${value ?? ''}`, '.');
    if (length(fields) != 4) return false;
    for (let field in fields)
        if (!match(field, /^[0-9]{1,3}$/) || int(field) < 0 || int(field) > 255) return false;
    return true;
}
function suggested_outbound(index) {
    return {
        port: 12345 + index,
        mark: 1 + ((index & 0xff) * 0x100) + (int(index / 0x100) * 0x20000)
    };
}
function configured_firewall() {
    let interfaces = [], outbounds = [], seen_ifaces = {}, seen_marks = {}, error = null, index = -1;
    try {
        let ctx = cursor();
        ctx.foreach('wloc', 'wifi', function(section) {
            index++;
            if (error) return;
            let enabled = section.enabled == null ? true : (`${section.enabled}` == '1' || section.enabled === true);
            if (!enabled) return;
            let iface = `${section.iface || ''}`;
            if (!valid_iface(iface)) { error = `invalid interface in enabled rule ${section['.name'] || ''}`; return; }
            if (!seen_ifaces[iface]) { seen_ifaces[iface] = true; push(interfaces, `"${iface}"`); }
            let outbound = `${section.outbound || 'direct'}`;
            if (outbound == 'direct') return;
            if (outbound != 'tproxy') { error = `invalid outbound type in enabled rule ${section['.name'] || ''}`; return; }
            let suggested = suggested_outbound(index);
            let port = section.tproxy_port == null || `${section.tproxy_port}` == '' ? suggested.port : number(section.tproxy_port);
            let mark = section.tproxy_mark == null || `${section.tproxy_mark}` == '' ? suggested.mark : number(section.tproxy_mark);
            if (!valid_port(port) || !valid_mark(mark)) { error = `invalid TPROXY port or mark in enabled rule ${section['.name'] || ''}`; return; }
            if (seen_marks[`${mark}`]) { error = `duplicate TPROXY mark ${mark}`; return; }
            seen_marks[`${mark}`] = true;
            push(outbounds, { iface, port, mark });
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    return error ? { ok: false, error } : { ok: true, interfaces, outbounds };
}
function render_rules(values) { return length(values) ? join('\n        ', values) : ''; }
function runtime_location_targets() {'''
text = sub_once(
    text,
    r"function valid_iface\(value\).*?function runtime_location_targets\(\) \{",
    new_config,
    "firewall config parser",
)
compile_replacement = r'''    let configured = configured_firewall();
    if (!configured.ok) return configured;
    let locations = runtime_location_targets();
    if (!locations.ok) return locations;
    let compiled = replace(raw, /%port%/g, `${port}`);
    if (length(configured.interfaces)) compiled = replace(compiled, /%ap_interfaces%/g, join(', ', configured.interfaces));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%ap_interfaces%[ \t]*\}[ \t]*\n/g, '');
    if (length(locations.v4)) compiled = replace(compiled, /%location_ipv4%/g, join(', ', locations.v4));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%location_ipv4%[ \t]*\}[ \t]*\n/g, '');
    if (length(locations.v6)) compiled = replace(compiled, /%location_ipv6%/g, join(', ', locations.v6));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%location_ipv6%[ \t]*\}[ \t]*\n/g, '');
    let ap_marks = [], ap_dispatch = [], outbound_dispatch = [];
    for (let outbound in configured.outbounds) {
        let ingress = INGRESS_MARK | outbound.mark;
        let handled = HANDLED_MARK | outbound.mark;
        push(ap_marks, `iifname "${outbound.iface}" meta mark set ${hex32(ingress)} return comment "wloc ap mark ${outbound.mark}"`);
        push(ap_dispatch, `meta mark ${hex32(ingress)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc ap tproxy ${outbound.mark}"`);
        push(outbound_dispatch, `meta mark ${hex32(outbound.mark)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc outbound ${outbound.mark}"`);
    }
    compiled = replace(compiled, /%ap_tproxy_mark_rules%/g, render_rules(ap_marks));
    compiled = replace(compiled, /%ap_tproxy_dispatch_rules%/g, render_rules(ap_dispatch));
    compiled = replace(compiled, /%outbound_tproxy_rules%/g, render_rules(outbound_dispatch));
    compiled = replace(compiled, /%ap_interfaces%/g, '');
    compiled = replace(compiled, /%location_ipv4%/g, '');
    compiled = replace(compiled, /%location_ipv6%/g, '');
    return { ok: true, source: raw, compiled };'''
text = sub_once(
    text,
    r"    let interfaces = configured_ap_interfaces\(\);.*?    return \{ ok: true, source: raw, compiled \};",
    compile_replacement,
    "firewall compile runtime",
)
write(path, text)


# rules.uc: stop rebuilding nft state; only manage policy routing and target-triggered firewall reloads.
path = "root/usr/libexec/wloc/rules.uc"
text = read(path)
for old in [
    "const RUNTIME_STATE = `${RUNTIME}/runtime.rules`;\n",
    "const INGRESS_MARK = 0x80000000;\n",
    "const HANDLED_MARK = 0x00010000;\n",
    "let sequence = 0;\n",
]:
    if old not in text:
        raise SystemExit(f"missing rules constant: {old.strip()}")
    text = text.replace(old, "", 1)
text = sub_once(
    text,
    r"function runtime_signature\(configured, targets\) \{.*?\nfunction policy_rule_present\(family, mark, mask, table\) \{",
    "function policy_rule_present(family, mark, mask, table) {",
    "remove nft runtime reconciliation",
)
text = sub_once(
    text,
    r"function outbound_chain_matches\(outbounds\) \{.*?\nfunction sync_outbound\(configured, route\) \{.*?\n\}\nfunction location_state_text\(targets\) \{",
    r'''function sync_outbound(configured, route) {
    let table = number(route.routing_table);
    if (table == null) return { ok: false, error: 'TPROXY routing table is unavailable' };
    let ipv6 = route.ipv6_enabled === true;
    if (outbound_state_matches(configured.outbounds, table, ipv6)) return { ok: true, changed: false };
    let removed = remove_outbound_policy();
    if (!removed.ok) return removed;
    if (!length(configured.outbounds)) return { ok: true, changed: true };
    let installed = [];
    for (let outbound in configured.outbounds) {
        if (!quiet(`ip -4 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {
            for (let item in installed) delete_policy_rule('4', item.mark, table);
            return { ok: false, error: `unable to install IPv4 outbound policy for mark ${outbound.mark}` };
        }
        if (ipv6 && !quiet(`ip -6 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {
            delete_policy_rule('4', outbound.mark, table);
            for (let item in installed) { delete_policy_rule('4', item.mark, table); delete_policy_rule('6', item.mark, table); }
            return { ok: false, error: `unable to install IPv6 outbound policy for mark ${outbound.mark}` };
        }
        push(installed, outbound);
    }
    let saved = write_outbound_state(configured.outbounds, table, ipv6);
    if (!saved.ok) {
        for (let item in installed) { delete_policy_rule('4', item.mark, table); if (ipv6) delete_policy_rule('6', item.mark, table); }
        return saved;
    }
    return { ok: true, changed: true };
}
function location_state_text(targets) {''',
    "policy-only outbound sync",
)
text = sub_once(
    text,
    r"function reconcile_with_targets\(port, target_args, save_targets\) \{.*?\nfunction cleanup\(reset\) \{",
    r'''function update_targets(target_args) {
    let targets = target_sets(target_args);
    if (!targets.ok) return targets;
    if (location_state_matches(targets)) return { ok: true, changed: false, location_count: length(targets.v4) + length(targets.v6) };
    let previous = target_sets(read_location_targets());
    if (!previous.ok) return previous;
    let saved = write_location_targets(targets);
    if (!saved.ok) return saved;
    let refreshed = run_firewall('refresh-runtime');
    if (!refreshed.ok) {
        let restored_state = write_location_targets(previous);
        let restored_firewall = restored_state.ok ? run_firewall('refresh-runtime') : { ok: false, error: restored_state.error };
        let rollback = restored_firewall.ok ? '' : `; rollback failed: ${restored_firewall.error || 'unable to restore previous firewall'}`;
        return { ok: false, error: `firewall target refresh failed: ${refreshed.error || 'unable to render location targets'}${rollback}` };
    }
    return { ok: true, changed: true, location_count: length(targets.v4) + length(targets.v6) };
}
function bootstrap(port) {
    if (!valid_port(port)) return { ok: false, error: 'listen port must be between 1 and 65535 for the transparent proxy' };
    let configured = configured_rules();
    if (!configured.ok) return configured;
    fs.unlink(LOCATION_STATE);
    let refreshed = run_firewall('refresh-runtime');
    if (!refreshed.ok) return { ok: false, error: `firewall placeholder refresh failed: ${refreshed.error || 'unable to render startup firewall'}` };
    let route = run_routing('apply-effective');
    if (!route.ok) return { ok: false, error: route.error || 'unable to ensure TPROXY policy routing' };
    let outbound = sync_outbound(configured, route);
    if (!outbound.ok) return { ok: false, error: `outbound policy setup failed: ${outbound.error}` };
    return { ok: true, interfaces: configured.interfaces, route_active: true, outbound_count: length(configured.outbounds), location_count: 0 };
}
function cleanup(reset) {''',
    "replace reconcile with target update",
)
text = replace_once(text, "    fs.unlink(RUNTIME_STATE);\n", "", "remove runtime state cleanup")
text = replace_once(
    text,
    "    if (command == 'bootstrap') return bootstrap(args[0]);\n    if (command == 'reconcile') return reconcile(args[0], slice(args, 1));\n",
    "    if (command == 'bootstrap') return bootstrap(args[0]);\n    if (command == 'update-targets') return update_targets(args);\n",
    "rules dispatch",
)
write(path, text)


# resolver.rs: distinguish a complete empty answer from a DNS failure.
path = "src/wloc-rs/src/resolver.rs"
text = read(path)
text = replace_once(
    text,
    "        complete: errors.is_empty() && !addresses.is_empty(),",
    "        complete: errors.is_empty(),",
    "resolver completion",
)
write(path, text)


# main.rs: replace 10-second reconcile loop with DNS-only change detection.
path = "src/wloc-rs/src/main.rs"
text = read(path)
text = replace_once(text, "use std::sync::atomic::{AtomicBool, Ordering};\n", "", "atomic import")
text = replace_once(
    text,
    "const TOKIO_WORKER_STACK_SIZE: usize = 1024 * 1024;",
    "const TOKIO_WORKER_STACK_SIZE: usize = 1024 * 1024;\nconst LOCATION_DNS_REFRESH_INTERVAL: Duration = Duration::from_secs(60);",
    "DNS refresh interval",
)
text = sub_once(
    text,
    r"fn reconcile_rules\(helper: &Path, port: u16, targets: &\[IpAddr\]\) -> Result<\(\), String> \{.*?\nasync fn bootstrap_rules_async",
    r'''fn update_location_targets(helper: &Path, targets: &[IpAddr]) -> Result<(), String> {
    let selectors = targets.iter().map(ToString::to_string).collect::<Vec<_>>();
    run_rules(helper, "update-targets", &selectors)
}

async fn update_location_targets_async(helper: PathBuf, targets: Vec<IpAddr>) -> Result<(), String> {
    tokio::task::spawn_blocking(move || update_location_targets(&helper, &targets))
        .await
        .map_err(|error| format!("rules task failed: {error}"))?
}

async fn bootstrap_rules_async''',
    "main rules helper",
)
new_runtime = r'''        let bootstrap_ready = bootstrap.is_ok();
        let resolution = if bootstrap_ready {
            resolver::resolve_location_targets(&config.rules, &config.domains).await
        } else {
            resolver::Resolution {
                addresses: Vec::new(),
                complete: false,
                errors: vec!["runtime bootstrap failed before DNS resolution".into()],
            }
        };
        for error in &resolution.errors {
            eprintln!("wlocd: location_dns=failed {error}");
        }
        let location_targets = resolution.addresses;
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
        } else if location_targets.is_empty() {
            status.update_detail(
                "location_resolution_failed",
                "armed=false targets=0 action=tproxy-pass-through",
                Some("No location-service IP addresses were resolved at startup."),
                |c| c.armed(false),
            );
            false
        } else {
            match update_location_targets_async(
                config.rules_helper.clone(),
                location_targets.clone(),
            )
            .await
            {
                Ok(()) => {
                    status.update_detail(
                        "interception_armed",
                        &format!(
                            "rules={} hosts={} targets={} protocol=tcp mode=targeted-ip listen_port={}",
                            config.rules.len(),
                            config.domains.join(","),
                            location_targets.len(),
                            config.listen_port
                        ),
                        None,
                        |c| c.armed(true),
                    );
                    true
                }
                Err(error) => {
                    status.update_detail(
                        "lease_failed",
                        "armed=false action=tproxy-pass-through phase=target_apply",
                        Some(&error),
                        |c| c.armed(false),
                    );
                    false
                }
            }
        };
        eprintln!(
            "wlocd: daemon=ready interception={} targets={} dns_complete={} ca_generated={generated}",
            initially_armed,
            location_targets.len(),
            resolution.complete
        );

        if bootstrap_ready {
            let refresh_rules = config.rules.clone();
            let refresh_domains = config.domains.clone();
            let refresh_helper = config.rules_helper.clone();
            let refresh_status = Arc::clone(&status);
            let mut current_targets = location_targets.clone();
            let mut refresh_armed = initially_armed;
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(LOCATION_DNS_REFRESH_INTERVAL);
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                interval.tick().await;
                loop {
                    interval.tick().await;
                    let refresh = resolver::resolve_location_targets(&refresh_rules, &refresh_domains).await;
                    for error in &refresh.errors {
                        eprintln!("wlocd: location_dns_refresh=failed {error}");
                    }
                    if !refresh.complete {
                        eprintln!("wlocd: location_dns_refresh=incomplete action=keep_previous_targets");
                        continue;
                    }
                    if refresh.addresses == current_targets {
                        continue;
                    }
                    let next_targets = refresh.addresses;
                    match update_location_targets_async(refresh_helper.clone(), next_targets.clone()).await {
                        Ok(()) => {
                            let previous_count = current_targets.len();
                            current_targets = next_targets;
                            refresh_armed = !current_targets.is_empty();
                            refresh_status.update_detail(
                                "location_targets_updated",
                                &format!(
                                    "previous_targets={} targets={} action=firewall_reloaded",
                                    previous_count,
                                    current_targets.len()
                                ),
                                None,
                                |c| c.armed(refresh_armed),
                            );
                            eprintln!(
                                "wlocd: location_targets=updated previous={} current={} interception={}",
                                previous_count,
                                current_targets.len(),
                                refresh_armed
                            );
                        }
                        Err(error) => {
                            refresh_status.update_detail(
                                "location_targets_update_failed",
                                "action=keep_previous_targets",
                                Some(&error),
                                |c| c.armed(refresh_armed),
                            );
                            eprintln!("wlocd: location_targets=update_failed action=keep_previous_targets error={error}");
                        }
                    }
                }
            });
        }

'''
text = sub_once(
    text,
    r"        let resolution = if bootstrap\.is_ok\(\) \{.*?\n        let proxy = Arc::new\(Proxy::new\(",
    new_runtime + "        let proxy = Arc::new(Proxy::new(",
    "main startup and refresh loop",
)
write(path, text)
