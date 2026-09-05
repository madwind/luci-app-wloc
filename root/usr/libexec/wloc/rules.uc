#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const FIREWALL = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const LOCATION_STATE = `${RUNTIME}/location.targets`;
const BRIDGE_FAMILY = 'bridge';
const TABLE = 'wloc';
const INGRESS_SET = 'ap_interfaces';
const AP_MARK_CHAIN = 'ap_tproxy_marks';
const LOCATION_SET4 = 'location_v4';
const LOCATION_SET6 = 'location_v6';
const AP_TPROXY_CHAIN = 'ap_tproxy_dispatch';
const OUTBOUND_CHAIN = 'outbound_prerouting';
const XRAY_ROUTE_MARK = 0x00000001;
const WLOC_ROUTE_MARK = 0x00000002;
const PROFILE_SHIFT = 8;
const MAX_PROFILE = 0xff;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: '', error: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output, error: rc === 0 ? null : (trim(output) || 'command failed') };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        try {
            let value = json(trim(lines[i]));
            if (type(value) == 'object') return value;
        } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}
function run_routing(command) {
    let result = capture(`/usr/bin/ucode ${q(ROUTING)} ${q(command)}`);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true) return { ok: false, error: result.error || 'routing controller failed' };
    return parsed;
}
function run_firewall(command) {
    let result = capture(`/usr/bin/ucode ${q(FIREWALL)} ${q(command)}`);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true) return { ok: false, error: result.error || 'firewall controller failed' };
    return parsed;
}
function number(value) {
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
function valid_ipv4(value) {
    let fields = split(`${value ?? ''}`, '.');
    if (length(fields) != 4) return false;
    for (let field in fields) {
        if (!match(field, /^[0-9]{1,3}$/) || int(field) < 0 || int(field) > 255) return false;
    }
    return true;
}
function target_sets(values) {
    let v4 = [], v6 = [], seen = {};
    for (let value in (values || [])) {
        let target = trim(`${value || ''}`);
        if (!target) continue;
        let family = null;
        if (valid_ipv4(target)) family = '4';
        else if (index(target, ':') >= 0 && match(target, /^[0-9A-Fa-f:]+$/)) family = '6';
        else return { ok: false, error: `invalid location target: ${target}` };
        let key = `${family}:${lc(target)}`;
        if (seen[key]) continue;
        seen[key] = true;
        push(family == '4' ? v4 : v6, target);
    }
    return { ok: true, v4, v6 };
}
function read_location_targets() {
    let raw = fs.readfile(LOCATION_STATE);
    return raw ? split(trim(raw), /\r?\n/) : [];
}
function write_location_targets(targets) {
    let values = [];
    for (let target in targets.v4) push(values, target);
    for (let target in targets.v6) push(values, target);
    if (!length(values)) { fs.unlink(LOCATION_STATE); return { ok: true }; }
    let content = join('\n', values) + '\n';
    let written = fs.writefile(LOCATION_STATE, content);
    if (written == null || written != length(content)) return { ok: false, error: 'unable to save WLOC location target state' };
    fs.chmod(LOCATION_STATE, 0o600);
    return { ok: true };
}
function resource_present(command) { return quiet(command); }
function clear_set(family, name) {
    if (!resource_present(`nft list set ${family} ${TABLE} ${name}`)) return { ok: true };
    return quiet(`nft flush set ${family} ${TABLE} ${name}`)
        ? { ok: true }
        : { ok: false, error: `unable to clear WLOC set ${name}` };
}
function clear_chain(family, name) {
    if (!resource_present(`nft list chain ${family} ${TABLE} ${name}`)) return { ok: true };
    return quiet(`nft flush chain ${family} ${TABLE} ${name}`)
        ? { ok: true }
        : { ok: false, error: `unable to clear WLOC chain ${name}` };
}
function configured_rules() {
    let ctx = cursor(), interfaces = [], outbounds = [], seen_ifaces = {}, error = null, index = -1;
    try {
        ctx.foreach('wloc', 'wifi', function(section) {
            index++;
            if (error) return;
            let enabled = section.enabled == null ? true : (`${section.enabled}` == '1' || section.enabled === true);
            if (!enabled) return;
            let iface = `${section.iface || ''}`;
            if (!valid_iface(iface)) { error = `invalid interface in enabled rule ${section['.name'] || ''}`; return; }
            if (!seen_ifaces[iface]) { seen_ifaces[iface] = true; push(interfaces, iface); }
            let outbound = `${section.outbound || 'direct'}`;
            if (outbound == 'direct') return;
            if (outbound != 'tproxy') { error = `invalid outbound type in enabled rule ${section['.name'] || ''}`; return; }
            let profile = index + 1;
            if (profile > MAX_PROFILE) { error = `TPROXY profile limit exceeded in enabled rule ${section['.name'] || ''}`; return; }
            let port = section.tproxy_port == null || `${section.tproxy_port}` == '' ? 12345 + index : number(section.tproxy_port);
            if (!valid_port(port)) { error = `invalid TPROXY port in enabled rule ${section['.name'] || ''}`; return; }
            push(outbounds, { iface, port, profile });
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (error) return { ok: false, error };
    if (!length(interfaces)) return { ok: false, error: 'no enabled ingress interfaces are configured' };
    return { ok: true, interfaces, outbounds };
}
function add_rule(family, chain, expression) {
    return quiet(`nft add rule ${family} ${TABLE} ${chain} ${expression}`)
        ? { ok: true }
        : { ok: false, error: `unable to add WLOC rule to ${chain}` };
}
function sync_runtime_rules(configured) {
    let errors = [];
    for (let item in [
        clear_chain(BRIDGE_FAMILY, AP_MARK_CHAIN),
        clear_chain('inet', AP_TPROXY_CHAIN),
        clear_chain('inet', OUTBOUND_CHAIN)
    ]) if (!item.ok) push(errors, item.error);
    if (length(errors)) return { ok: false, error: join('; ', errors) };

    for (let outbound in configured.outbounds) {
        let profile_mark = outbound.profile << PROFILE_SHIFT;
        let outbound_mark = profile_mark | WLOC_ROUTE_MARK;
        let ap = add_rule(BRIDGE_FAMILY, AP_MARK_CHAIN,
            `iifname ${q(outbound.iface)} meta mark set ${hex32(profile_mark)} return comment ${q(`wloc ap mark ${outbound.profile}`)}`);
        if (!ap.ok) { clear_chain(BRIDGE_FAMILY, AP_MARK_CHAIN); return ap; }
        let dispatch = add_rule('inet', AP_TPROXY_CHAIN,
            `meta mark ${hex32(profile_mark)} meta l4proto { tcp, udp } meta mark set ${hex32(XRAY_ROUTE_MARK)} counter tproxy to :${outbound.port} accept comment ${q(`wloc ap tproxy ${outbound.profile}`)}`);
        if (!dispatch.ok) { clear_chain(BRIDGE_FAMILY, AP_MARK_CHAIN); clear_chain('inet', AP_TPROXY_CHAIN); return dispatch; }
        let outbound_rule = add_rule('inet', OUTBOUND_CHAIN,
            `meta mark ${hex32(outbound_mark)} meta l4proto { tcp, udp } meta mark set ${hex32(XRAY_ROUTE_MARK)} counter tproxy to :${outbound.port} accept comment ${q(`wloc outbound ${outbound.profile}`)}`);
        if (!outbound_rule.ok) {
            clear_chain(BRIDGE_FAMILY, AP_MARK_CHAIN);
            clear_chain('inet', AP_TPROXY_CHAIN);
            clear_chain('inet', OUTBOUND_CHAIN);
            return outbound_rule;
        }
    }
    return { ok: true };
}
function location_state_text(targets) {
    let values = [];
    for (let target in targets.v4) push(values, target);
    for (let target in targets.v6) push(values, target);
    return length(values) ? join('\n', values) + '\n' : '';
}
function location_state_matches(targets) {
    return `${fs.readfile(LOCATION_STATE) || ''}` == location_state_text(targets);
}
function update_targets(target_args) {
    let targets = target_sets(target_args);
    if (!targets.ok) return targets;
    if (location_state_matches(targets)) return { ok: true, changed: false, location_count: length(targets.v4) + length(targets.v6) };
    let previous = target_sets(read_location_targets());
    if (!previous.ok) return previous;
    let configured = configured_rules();
    if (!configured.ok) return configured;
    let saved = write_location_targets(targets);
    if (!saved.ok) return saved;
    let refreshed = run_firewall('refresh-runtime');
    let synced = refreshed.ok ? sync_runtime_rules(configured) : { ok: false, error: refreshed.error };
    if (!refreshed.ok || !synced.ok) {
        let restored_state = write_location_targets(previous);
        let restored_firewall = restored_state.ok ? run_firewall('refresh-runtime') : { ok: false, error: restored_state.error };
        let restored_rules = restored_firewall.ok ? sync_runtime_rules(configured) : { ok: false, error: restored_firewall.error };
        let rollback = restored_rules.ok ? '' : `; rollback failed: ${restored_rules.error || 'unable to restore previous firewall'}`;
        return { ok: false, error: `firewall target refresh failed: ${(refreshed.ok ? synced.error : refreshed.error) || 'unable to render location targets'}${rollback}` };
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
    let synced = sync_runtime_rules(configured);
    if (!synced.ok) return { ok: false, error: `runtime rule setup failed: ${synced.error}` };
    return { ok: true, interfaces: configured.interfaces, route_active: true, outbound_count: length(configured.outbounds), location_count: 0 };
}
function cleanup(reset) {
    let errors = [];
    for (let item in [
        clear_set(BRIDGE_FAMILY, INGRESS_SET),
        clear_chain(BRIDGE_FAMILY, AP_MARK_CHAIN),
        clear_set('inet', LOCATION_SET4),
        clear_set('inet', LOCATION_SET6),
        clear_chain('inet', AP_TPROXY_CHAIN),
        clear_chain('inet', OUTBOUND_CHAIN)
    ]) if (!item.ok) push(errors, item.error);
    fs.unlink(LOCATION_STATE);
    let route = run_routing(reset ? 'reset' : 'deactivate');
    if (!route.ok) push(errors, route.error || `unable to ${reset ? 'reset' : 'deactivate'} TPROXY policy routing`);
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true, route_active: false };
}
function dispatch(command, args) {
    if (command == 'bootstrap') return bootstrap(args[0]);
    if (command == 'update-targets') return update_targets(args);
    if (command == 'cleanup') return cleanup(false);
    if (command == 'reset') return cleanup(true);
    return { ok: false, error: `unsupported rules command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
