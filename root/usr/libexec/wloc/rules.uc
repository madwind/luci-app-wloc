#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const FIREWALL = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const OUTBOUND_STATE = `${RUNTIME}/outbound.rules`;
const LOCATION_STATE = `${RUNTIME}/location.targets`;
const RUNTIME_STATE = `${RUNTIME}/runtime.rules`;
const BRIDGE_FAMILY = 'bridge';
const TABLE = 'wloc';
const INGRESS_SET = 'ap_interfaces';
const AP_MARK_CHAIN = 'ap_tproxy_marks';
const LOCATION_SET4 = 'location_v4';
const LOCATION_SET6 = 'location_v6';
const AP_TPROXY_CHAIN = 'ap_tproxy_dispatch';
const OUTBOUND_CHAIN = 'outbound_prerouting';
const RESERVED_MARK_MASK = 0xc0010000;
const INGRESS_MARK = 0x80000000;
const HANDLED_MARK = 0x00010000;
const OUTBOUND_POLICY_MASK = 0xfffeffff;
const OUTBOUND_RULE_PRIORITY = 90;
let sequence = 0;

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
function runtime_signature(configured, targets) {
    let lines = [];
    for (let iface in configured.interfaces) push(lines, `iface ${iface}`);
    for (let outbound in configured.outbounds) push(lines, `outbound ${outbound.iface} ${outbound.port} ${outbound.mark}`);
    for (let target in targets.v4) push(lines, `v4 ${target}`);
    for (let target in targets.v6) push(lines, `v6 ${lc(target)}`);
    return join('\n', lines) + '\n';
}
function chain_comment_count(family, chain, prefix) {
    let result = capture(`nft list chain ${family} ${TABLE} ${chain}`);
    if (!result.ok) return -1;
    let count = 0;
    for (let line in split(result.output || '', '\n')) if (index(line, `comment "${prefix}`) >= 0) count++;
    return count;
}
function set_contains(family, name, values) {
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
function runtime_matches(configured, targets) {
    if (fs.readfile(RUNTIME_STATE) != runtime_signature(configured, targets)) return false;
    if (!firewall_sets_match(configured, targets)) return false;
    if (chain_comment_count(BRIDGE_FAMILY, AP_MARK_CHAIN, 'wloc ap mark ') != length(configured.outbounds)) return false;
    if (chain_comment_count('inet', AP_TPROXY_CHAIN, 'wloc ap tproxy ') != length(configured.outbounds)) return false;
    return true;
}
function sync_runtime(configured, targets) {
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
function outbound_chain_matches(outbounds) {
    let result = capture(`nft list chain inet ${TABLE} ${OUTBOUND_CHAIN}`);
    if (!result.ok) return false;
    let found = {}, count = 0;
    for (let line in split(result.output || '', '\n')) {
        let comment = match(line, /comment "wloc outbound ([0-9]+)"/);
        if (!comment) continue;
        let port_match = match(line, /tproxy to :([0-9]+)/);
        if (!port_match) return false;
        let mark = number(comment[1]), port = number(port_match[1]);
        if (mark == null || port == null || found[`${mark}`] != null) return false;
        found[`${mark}`] = port;
        count++;
    }
    if (count != length(outbounds)) return false;
    for (let outbound in outbounds) if (found[`${outbound.mark}`] != outbound.port) return false;
    return true;
}
function sync_outbound(configured, route) {
    let table = number(route.routing_table);
    if (table == null) return { ok: false, error: 'TPROXY routing table is unavailable' };
    let ipv6 = route.ipv6_enabled === true;
    if (outbound_state_matches(configured.outbounds, table, ipv6) && outbound_chain_matches(configured.outbounds)) return { ok: true, changed: false };
    let removed = remove_outbound_policy();
    if (!removed.ok) return removed;
    let cleared = clear_chain('inet', OUTBOUND_CHAIN);
    if (!cleared.ok) return cleared;
    if (!length(configured.outbounds)) return { ok: true, changed: true };
    if (!resource_present(`nft list chain inet ${TABLE} ${OUTBOUND_CHAIN}`)) return { ok: false, error: 'WLOC outbound dispatch chain is missing' };
    sequence++;
    let path = `${RUNTIME}/outbound-chain.${time()}.${sequence}.nft`;
    let lines = [ `flush chain inet ${TABLE} ${OUTBOUND_CHAIN}` ];
    for (let outbound in configured.outbounds) {
        let handled = HANDLED_MARK | outbound.mark;
        push(lines, `add rule inet ${TABLE} ${OUTBOUND_CHAIN} meta mark ${hex32(outbound.mark)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc outbound ${outbound.mark}"`);
    }
    let content = join('\n', lines) + '\n';
    let written = fs.writefile(path, content);
    if (written == null || written != length(content)) { fs.unlink(path); return { ok: false, error: 'unable to stage WLOC outbound dispatch rules' }; }
    fs.chmod(path, 0o600);
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    if (!applied.ok) return { ok: false, error: trim(applied.output || '') || 'unable to apply WLOC outbound dispatch rules' };
    let installed = [];
    for (let outbound in configured.outbounds) {
        if (!quiet(`ip -4 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {
            clear_chain('inet', OUTBOUND_CHAIN);
            for (let item in installed) delete_policy_rule('4', item.mark, table);
            return { ok: false, error: `unable to install IPv4 outbound policy for mark ${outbound.mark}` };
        }
        if (ipv6 && !quiet(`ip -6 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {
            clear_chain('inet', OUTBOUND_CHAIN);
            delete_policy_rule('4', outbound.mark, table);
            for (let item in installed) { delete_policy_rule('4', item.mark, table); delete_policy_rule('6', item.mark, table); }
            return { ok: false, error: `unable to install IPv6 outbound policy for mark ${outbound.mark}` };
        }
        push(installed, outbound);
    }
    let saved = write_outbound_state(configured.outbounds, table, ipv6);
    if (!saved.ok) {
        clear_chain('inet', OUTBOUND_CHAIN);
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
function reconcile_with_targets(port, target_args, save_targets) {
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
    fs.unlink(RUNTIME_STATE);
    fs.unlink(LOCATION_STATE);
    let outbound_policy = remove_outbound_policy();
    if (!outbound_policy.ok) push(errors, outbound_policy.error);
    let route = run_routing(reset ? 'reset' : 'deactivate');
    if (!route.ok) push(errors, route.error || `unable to ${reset ? 'reset' : 'deactivate'} TPROXY policy routing`);
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true, route_active: false };
}
function dispatch(command, args) {
    if (command == 'bootstrap') return bootstrap(args[0]);
    if (command == 'reconcile') return reconcile(args[0], slice(args, 1));
    if (command == 'cleanup') return cleanup(false);
    if (command == 'reset') return cleanup(true);
    return { ok: false, error: `unsupported rules command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
