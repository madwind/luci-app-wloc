from pathlib import Path


def replace_between(text, start_marker, end_marker, replacement):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[:start] + replacement + text[end:]


firewall_path = Path('root/usr/libexec/wloc/firewall.uc')
firewall = firewall_path.read_text()
firewall = firewall.replace(
    "const RUNTIME = '/var/run/wloc';\n",
    "const RUNTIME = '/var/run/wloc';\nconst LOCATION_STATE = `${RUNTIME}/location.targets`;\n",
    1,
)

firewall_compile = r'''function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function valid_ipv4(value) {
    let fields = split(`${value ?? ''}`, '.');
    if (length(fields) != 4) return false;
    for (let field in fields)
        if (!match(field, /^[0-9]{1,3}$/) || int(field) < 0 || int(field) > 255) return false;
    return true;
}
function configured_ap_interfaces() {
    let values = [], seen = {}, error = null;
    try {
        let ctx = cursor();
        ctx.foreach('wloc', 'wifi', function(section) {
            if (error) return;
            let enabled = section.enabled == null ? true : (`${section.enabled}` == '1' || section.enabled === true);
            if (!enabled) return;
            let iface = `${section.iface || ''}`;
            if (!valid_iface(iface)) { error = `invalid interface in enabled rule ${section['.name'] || ''}`; return; }
            if (!seen[iface]) { seen[iface] = true; push(values, `"${iface}"`); }
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    return error ? { ok: false, error } : { ok: true, values };
}
function runtime_location_targets() {
    let raw = read_text(LOCATION_STATE);
    if (!raw) return { ok: true, v4: [], v6: [] };
    let v4 = [], v6 = [], seen = {};
    for (let line in split(raw, /\r?\n/)) {
        let value = trim(line || '');
        if (!value) continue;
        let family = null;
        if (valid_ipv4(value)) family = '4';
        else if (index(value, ':') >= 0 && match(value, /^[0-9A-Fa-f:]+$/)) family = '6';
        else return { ok: false, error: `invalid runtime location target: ${value}` };
        let key = `${family}:${lc(value)}`;
        if (seen[key]) continue;
        seen[key] = true;
        push(family == '4' ? v4 : v6, value);
    }
    return { ok: true, v4, v6 };
}
function compile_runtime(raw) {
    raw = normalize(raw);
    let port_text = listen_port();
    if (!match(port_text, /^[0-9]+$/)) return { ok: false, error: 'WLOC listen port is invalid.' };
    let port = int(port_text);
    if (port < 1 || port > 65535) return { ok: false, error: 'WLOC listen port must be between 1 and 65535.' };
    let interfaces = configured_ap_interfaces();
    if (!interfaces.ok) return interfaces;
    let locations = runtime_location_targets();
    if (!locations.ok) return locations;
    let compiled = replace(raw, /%port%/g, `${port}`);
    if (length(interfaces.values)) compiled = replace(compiled, /%ap_interfaces%/g, join(', ', interfaces.values));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%ap_interfaces%[ \t]*\}[ \t]*\n/g, '');
    if (length(locations.v4)) compiled = replace(compiled, /%location_ipv4%/g, join(', ', locations.v4));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%location_ipv4%[ \t]*\}[ \t]*\n/g, '');
    if (length(locations.v6)) compiled = replace(compiled, /%location_ipv6%/g, join(', ', locations.v6));
    else compiled = replace(compiled, /[ \t]*elements[ \t]*=[ \t]*\{[ \t]*%location_ipv6%[ \t]*\}[ \t]*\n/g, '');
    compiled = replace(compiled, /%ap_interfaces%/g, '');
    compiled = replace(compiled, /%location_ipv4%/g, '');
    compiled = replace(compiled, /%location_ipv6%/g, '');
    compiled = replace(compiled, /%ap_tproxy_mark_rules%/g, '');
    compiled = replace(compiled, /%ap_tproxy_dispatch_rules%/g, '');
    compiled = replace(compiled, /%outbound_tproxy_rules%/g, '');
    return { ok: true, source: raw, compiled };
}
'''
firewall = replace_between(firewall, 'function compile_runtime(raw) {', 'function prepare(raw) {', firewall_compile)

refresh = r'''function refresh_runtime() {
    let raw = read_text(APPLIED);
    if (raw == null) return { ok: false, error: 'The applied firewall snapshot is unavailable.' };
    let checked = prepare(raw);
    if (!checked.ok) return { ok: false, error: checked.detail || checked.error || 'Unable to render the WLOC firewall.' };
    let loaded = run_transaction(transaction(managed_tables(), checked.compiled, checked.tables));
    if (!loaded.ok) return { ok: false, error: loaded.detail || 'Unable to refresh the WLOC firewall.' };
    for (let spec in checked.tables)
        if (!table_active(spec)) return { ok: false, error: `missing runtime table ${spec.family} ${spec.name}` };
    return { ok: true, refreshed: true };
}
'''
firewall = firewall.replace('function save(raw) {', refresh + 'function save(raw) {', 1)
firewall = firewall.replace(
    "    if (command == 'remove-runtime') return remove_runtime();\n",
    "    if (command == 'remove-runtime') return remove_runtime();\n    if (command == 'refresh-runtime') return refresh_runtime();\n",
    1,
)
firewall_path.write_text(firewall)

rules_path = Path('root/usr/libexec/wloc/rules.uc')
rules = rules_path.read_text()
rules = rules.replace(
    "const ROUTING = '/usr/libexec/wloc/routing.uc';\n",
    "const ROUTING = '/usr/libexec/wloc/routing.uc';\nconst FIREWALL = '/usr/libexec/wloc/firewall.uc';\n",
    1,
)
run_firewall = r'''function run_firewall(command) {
    let result = capture(`/usr/bin/ucode ${q(FIREWALL)} ${q(command)}`);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true) return { ok: false, error: result.error || 'firewall controller failed' };
    return parsed;
}
'''
rules = rules.replace('function number(value) {', run_firewall + 'function number(value) {', 1)

set_helpers = r'''function set_contains(family, name, values) {
    let result = capture(`nft list set ${family} ${TABLE} ${name}`);
    if (!result.ok) return false;
    for (let value in values) if (index(result.output || '', value) < 0) return false;
    return true;
}
function set_element_count(family, name) {
    let result = capture(`nft list set ${family} ${TABLE} ${name}`);
    if (!result.ok) return -1;
    let found = match(result.output || '', /elements\s*=\s*\{([^}]*)\}/);
    if (!found) return 0;
    let count = 0;
    for (let item in split(found[1] || '', ',')) if (trim(item || '')) count++;
    return count;
}
function firewall_sets_match(configured, targets) {
    return set_contains(BRIDGE_FAMILY, INGRESS_SET, configured.interfaces)
        && set_element_count(BRIDGE_FAMILY, INGRESS_SET) == length(configured.interfaces)
        && set_contains('inet', LOCATION_SET4, targets.v4)
        && set_contains('inet', LOCATION_SET6, targets.v6);
}
'''
rules = replace_between(rules, 'function set_contains(family, name, values) {', 'function runtime_matches(configured, targets) {', set_helpers)
rules = rules.replace(
    "    if (!set_contains(BRIDGE_FAMILY, INGRESS_SET, configured.interfaces)) return false;\n    if (!set_contains('inet', LOCATION_SET4, targets.v4) || !set_contains('inet', LOCATION_SET6, targets.v6)) return false;\n",
    "    if (!firewall_sets_match(configured, targets)) return false;\n",
    1,
)

sync_runtime = r'''function sync_runtime(configured, targets) {
    if (runtime_matches(configured, targets)) return { ok: true, changed: false };
    if (!resource_present(`nft list set ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET}`)) return { ok: false, error: 'AP interface set is missing' };
    if (!resource_present(`nft list chain ${BRIDGE_FAMILY} ${TABLE} ${AP_MARK_CHAIN}`)) return { ok: false, error: 'AP TPROXY mark chain is missing' };
    if (!resource_present(`nft list set inet ${TABLE} ${LOCATION_SET4}`) || !resource_present(`nft list set inet ${TABLE} ${LOCATION_SET6}`)) return { ok: false, error: 'location target set is missing' };
    if (!resource_present(`nft list chain inet ${TABLE} ${AP_TPROXY_CHAIN}`)) return { ok: false, error: 'AP TPROXY dispatch chain is missing' };
    if (!quiet(`mkdir -p ${q(RUNTIME)}`)) return { ok: false, error: 'unable to create WLOC runtime directory' };
    sequence++;
    let path = `${RUNTIME}/runtime-rules.${time()}.${sequence}.nft`;
    let lines = [
        `flush chain ${BRIDGE_FAMILY} ${TABLE} ${AP_MARK_CHAIN}`,
        `flush chain inet ${TABLE} ${AP_TPROXY_CHAIN}`
    ];
    for (let outbound in configured.outbounds) {
        let ingress = INGRESS_MARK | outbound.mark;
        push(lines, `add rule ${BRIDGE_FAMILY} ${TABLE} ${AP_MARK_CHAIN} iifname "${outbound.iface}" meta mark set ${hex32(ingress)} return comment "wloc ap mark ${outbound.mark}"`);
    }
    for (let outbound in configured.outbounds) {
        let ingress = INGRESS_MARK | outbound.mark;
        let handled = HANDLED_MARK | outbound.mark;
        push(lines, `add rule inet ${TABLE} ${AP_TPROXY_CHAIN} meta mark ${hex32(ingress)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc ap tproxy ${outbound.mark}"`);
    }
    let content = join('\n', lines) + '\n';
    let written = fs.writefile(path, content);
    if (written == null || written != length(content)) { fs.unlink(path); return { ok: false, error: 'unable to stage WLOC runtime rules' }; }
    fs.chmod(path, 0o600);
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    if (!applied.ok) return { ok: false, error: trim(applied.output || '') || 'unable to apply WLOC runtime rules' };
    let signature = runtime_signature(configured, targets);
    if (fs.writefile(RUNTIME_STATE, signature) != length(signature)) return { ok: false, error: 'unable to save WLOC runtime rule state' };
    fs.chmod(RUNTIME_STATE, 0o600);
    return { ok: true, changed: true };
}
'''
rules = replace_between(rules, 'function sync_runtime(configured, targets) {', 'function policy_rule_present(family, mark, mask, table) {', sync_runtime)

state_helpers = r'''function location_state_text(targets) {
    let values = [];
    for (let target in targets.v4) push(values, target);
    for (let target in targets.v6) push(values, target);
    return length(values) ? join('\n', values) + '\n' : '';
}
function location_state_matches(targets) {
    return `${fs.readfile(LOCATION_STATE) || ''}` == location_state_text(targets);
}
'''
rules = rules.replace('function reconcile_with_targets(port, target_args, save_targets) {', state_helpers + 'function reconcile_with_targets(port, target_args, save_targets) {', 1)

reconcile = r'''function reconcile_with_targets(port, target_args, save_targets) {
    if (!valid_port(port)) return { ok: false, error: 'listen port must be between 1 and 65535 for the transparent proxy' };
    let configured = configured_rules();
    if (!configured.ok) return configured;
    let targets = target_sets(target_args);
    if (!targets.ok) return targets;
    let locations_changed = save_targets && !location_state_matches(targets);
    if (save_targets) {
        let saved = write_location_targets(targets);
        if (!saved.ok) return saved;
    }
    if (locations_changed || !firewall_sets_match(configured, targets)) {
        let refreshed = run_firewall('refresh-runtime');
        if (!refreshed.ok) return { ok: false, error: `firewall placeholder refresh failed: ${refreshed.error || 'unable to render dynamic sets'}` };
        if (!firewall_sets_match(configured, targets)) return { ok: false, error: 'firewall placeholder refresh did not apply the expected dynamic sets' };
    }
    let route = run_routing('apply-effective');
    if (!route.ok) return { ok: false, error: route.error || 'unable to ensure TPROXY policy routing' };
    let runtime = sync_runtime(configured, targets);
    if (!runtime.ok) return { ok: false, error: `runtime rule reconciliation failed: ${runtime.error}` };
    let outbound = sync_outbound(configured, route);
    if (!outbound.ok) return { ok: false, error: `outbound reconciliation failed: ${outbound.error}` };
    return { ok: true, interfaces: configured.interfaces, route_active: true, outbound_count: length(configured.outbounds), location_count: length(targets.v4) + length(targets.v6) };
}
function reconcile(port, target_args) {
    let targets = length(target_args) ? target_args : read_location_targets();
    return reconcile_with_targets(port, targets, length(target_args) > 0);
}
function bootstrap(port) {
    fs.unlink(LOCATION_STATE);
    let refreshed = run_firewall('refresh-runtime');
    if (!refreshed.ok) return { ok: false, error: `firewall placeholder refresh failed: ${refreshed.error || 'unable to clear dynamic location sets'}` };
    return reconcile_with_targets(port, [], false);
}
'''
rules = replace_between(rules, 'function reconcile_with_targets(port, target_args, save_targets) {', 'function cleanup(reset) {', reconcile)
rules = rules.replace(
    "    if (command == 'sync-ingress') {\n        let configured = configured_rules();\n        return configured.ok ? sync_ingress(configured) : configured;\n    }\n",
    '',
    1,
)
rules_path.write_text(rules)
