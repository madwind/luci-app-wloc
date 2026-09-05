#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const FIREWALL = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const OUTBOUND_STATE = `${RUNTIME}/outbound.rules`;
const LOCATION_STATE = `${RUNTIME}/location.targets`;
const BRIDGE_FAMILY = 'bridge';
const TABLE = 'wloc';
const INGRESS_SET = 'ap_interfaces';
const AP_MARK_CHAIN = 'ap_tproxy_marks';
const LOCATION_SET4 = 'location_v4';
const LOCATION_SET6 = 'location_v6';
const AP_TPROXY_CHAIN = 'ap_tproxy_dispatch';
const OUTBOUND_CHAIN = 'outbound_prerouting';
const RESERVED_MARK_MASK = 0xc0010000;
const OUTBOUND_POLICY_MASK = 0xfffeffff;
const OUTBOUND_RULE_PRIORITY = 90;

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
function valid_mark(value) {
    let mark = number(value);
    return mark != null && mark >= 1 && mark <= 0xffffffff && (mark & RESERVED_MARK_MASK) == 0;
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
function suggested_outbound(index) {
    return {
        port: 12345 + index,
        mark: 1 + ((index & 0xff) * 0x100) + (int(index / 0x100) * 0x20000)
    };
}
function configured_rules() {
    let ctx = cursor(), interfaces = [], outbounds = [], seen_ifaces = {}, seen_marks = {}, error = null, index = -1;
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
            let suggested = suggested_outbound(index);
            let port = section.tproxy_port == null || `${section.tproxy_port}` == '' ? suggested.port : number(section.tproxy_port);
            let mark = section.tproxy_mark == null || `${section.tproxy_mark}` == '' ? suggested.mark : number(section.tproxy_mark);
            if (!valid_port(port) || !valid_mark(mark)) { error = `invalid TPROXY port or mark in enabled rule ${section['.name'] || ''}`; return; }
            if (seen_marks[`${mark}`]) { error = `duplicate TPROXY mark ${mark}`; return; }
            seen_marks[`${mark}`] = true;
            push(outbounds, { iface, port, mark });
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (error) return { ok: false, error };
    if (!length(interfaces)) return { ok: false, error: 'no enabled ingress interfaces are configured' };
    return { ok: true, interfaces, outbounds };
}
function policy_rule_present(family, mark, mask, table) {
    let result = capture(`ip -${family} rule show`);
    if (!result.ok) return false;
    for (let source_line in split(result.output || '', '\n')) {
        let line = match(source_line, /^\s*(\d+):\s*(.*)$/);
        if (!line || number(line[1]) != OUTBOUND_RULE_PRIORITY) continue;
        let found = match(trim(line[2]), /^from\s+all\s+fwmark\s+(\S+)\s+[Ll]ookup\s+(\S+)$/);
        if (!found) continue;
        let markmask = split(found[1], '/');
        let current_mark = number(markmask[0]);
        let current_mask = number(length(markmask) > 1 ? markmask[1] : '0xffffffff');
        if (current_mark == mark && current_mask == mask && number(found[2]) == table) return true;
    }
    return false;
}
function rule_present(family, mark, table) { return policy_rule_present(family, mark, OUTBOUND_POLICY_MASK, table); }
function delete_policy_rule(family, mark, table) {
    for (let mask in [ OUTBOUND_POLICY_MASK, 0xffffffff ]) {
        let count = 0;
        while (policy_rule_present(family, mark, mask, table)) {
            if (count++ >= 16 || !quiet(`ip -${family} rule del priority ${OUTBOUND_RULE_PRIORITY} fwmark ${mark}/${hex32(mask)} lookup ${table}`)) return false;
        }
    }
    return true;
}
function read_outbound_state() {
    let raw = fs.readfile(OUTBOUND_STATE);
    if (!raw) return [];
    let state = [];
    for (let line in split(raw, '\n')) {
        let fields = split(trim(line || ''), /\s+/);
        if (length(fields) != 3) continue;
        let mark = number(fields[0]), table = number(fields[1]), ipv6 = fields[2] == '1';
        if (mark != null && table != null) push(state, { mark, table, ipv6 });
    }
    return state;
}
function remove_outbound_policy() {
    let errors = [];
    for (let item in read_outbound_state()) {
        if (!delete_policy_rule('4', item.mark, item.table)) push(errors, `unable to remove IPv4 outbound rule for mark ${item.mark}`);
        if (item.ipv6 && !delete_policy_rule('6', item.mark, item.table)) push(errors, `unable to remove IPv6 outbound rule for mark ${item.mark}`);
    }
    if (length(errors)) return { ok: false, error: join('; ', errors) };
    fs.unlink(OUTBOUND_STATE);
    return { ok: true };
}
function write_outbound_state(outbounds, table, ipv6) {
    if (!length(outbounds)) { fs.unlink(OUTBOUND_STATE); return { ok: true }; }
    let lines = [];
    for (let outbound in outbounds) push(lines, `${outbound.mark} ${table} ${ipv6 ? 1 : 0}`);
    let content = join('\n', lines) + '\n';
    let written = fs.writefile(OUTBOUND_STATE, content);
    if (written == null || written != length(content)) return { ok: false, error: 'unable to save WLOC outbound policy state' };
    fs.chmod(OUTBOUND_STATE, 0o600);
    return { ok: true };
}
function outbound_state_matches(outbounds, table, ipv6) {
    let state = read_outbound_state();
    if (length(state) != length(outbounds)) return false;
    for (let outbound in outbounds) {
        let matched = false;
        for (let item in state) {
            if (item.mark == outbound.mark && item.table == table && item.ipv6 == ipv6) { matched = true; break; }
        }
        if (!matched || !rule_present('4', outbound.mark, table)) return false;
        if (ipv6 && !rule_present('6', outbound.mark, table)) return false;
    }
    return true;
}
function sync_outbound(configured, route) {
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
    let outbound_policy = remove_outbound_policy();
    if (!outbound_policy.ok) push(errors, outbound_policy.error);
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
