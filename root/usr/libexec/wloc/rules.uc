#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const RUNTIME = '/var/run/wloc';
const OUTBOUND_STATE = `${RUNTIME}/outbound.rules`;
const BRIDGE_FAMILY = 'bridge';
const TABLE = 'wloc';
const INGRESS_SET = 'target_ingress_interfaces';
const OUTBOUND_CHAIN = 'outbound_prerouting';
const RESERVED_MARK_MASK = 0xc0010000;
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
function number(value) {
    if (value == null) return null;
    let text = `${value}`;
    if (match(text, /^0[xX][0-9A-Fa-f]+$/)) return int(substr(text, 2), 16);
    if (!match(text, /^[0-9]+$/)) return null;
    let result = +text;
    return result == result ? result : null;
}
function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function valid_port(value) {
    let port = number(value);
    return port != null && port >= 1 && port <= 65535;
}
function valid_mark(value) {
    let mark = number(value);
    return mark != null && mark >= 1 && mark <= 0xffffffff && (mark & RESERVED_MARK_MASK) == 0;
}
function clear_ingress() {
    if (!quiet(`nft list set ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET}`)) return { ok: true };
    if (!quiet(`nft flush set ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET}`)) return { ok: false, error: 'unable to clear WLOC ingress interface set' };
    return { ok: true };
}
function clear_outbound_chain() {
    if (!quiet(`nft list chain inet ${TABLE} ${OUTBOUND_CHAIN}`)) return { ok: true };
    if (!quiet(`nft flush chain inet ${TABLE} ${OUTBOUND_CHAIN}`)) return { ok: false, error: 'unable to clear WLOC outbound dispatch chain' };
    return { ok: true };
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
            push(outbounds, { port, mark });
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (error) return { ok: false, error };
    if (!length(interfaces)) return { ok: false, error: 'no enabled ingress interfaces are configured' };
    return { ok: true, interfaces, outbounds };
}
function sync_ingress(configured) {
    if (!quiet(`nft list set ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET}`)) return { ok: false, error: 'target ingress interface set is missing' };
    if (!quiet(`mkdir -p ${q(RUNTIME)}`)) return { ok: false, error: 'unable to create WLOC runtime directory' };
    sequence++;
    let path = `${RUNTIME}/ingress-set.${time()}.${sequence}.nft`;
    let lines = [ `flush set ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET}` ];
    for (let iface in configured.interfaces) push(lines, `add element ${BRIDGE_FAMILY} ${TABLE} ${INGRESS_SET} { "${iface}" }`);
    let content = join('
', lines) + '
';
    let written = fs.writefile(path, content);
    if (written == null || written != length(content)) { fs.unlink(path); return { ok: false, error: 'unable to stage WLOC ingress set transaction' }; }
    fs.chmod(path, 0o600);
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    if (!applied.ok) return { ok: false, error: trim(applied.output || '') || 'unable to refresh ingress set' };
    return { ok: true };
}
function rule_present(family, mark, table) {
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
        if (current_mark == mark && current_mask == 0xffffffff && number(found[2]) == table) return true;
    }
    return false;
}
function delete_policy_rule(family, mark, table) {
    let count = 0;
    while (rule_present(family, mark, table)) {
        if (count++ >= 16 || !quiet(`ip -${family} rule del priority ${OUTBOUND_RULE_PRIORITY} fwmark ${mark}/0xffffffff lookup ${table}`)) return false;
    }
    return true;
}
function read_outbound_state() {
    let raw = fs.readfile(OUTBOUND_STATE);
    if (!raw) return [];
    let state = [];
    for (let line in split(raw, '
')) {
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
    let content = join('
', lines) + '
';
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
            if (item.mark == outbound.mark && item.table == table && item.ipv6 == ipv6) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
        if (!rule_present('4', outbound.mark, table)) return false;
        if (ipv6 && !rule_present('6', outbound.mark, table)) return false;
    }
    return true;
}
function outbound_chain_matches(outbounds) {
    let result = capture(`nft list chain inet ${TABLE} ${OUTBOUND_CHAIN}`);
    if (!result.ok) return false;
    let found = {};
    let count = 0;
    for (let line in split(result.output || '', '\n')) {
        if (index(line, 'comment "wloc outbound"') < 0) continue;
        let mark_match = match(line, /meta mark (\S+)/);
        let port_match = match(line, /tproxy to :([0-9]+)/);
        if (!mark_match || !port_match) return false;
        let mark = number(mark_match[1]), port = number(port_match[1]);
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
    if (outbound_state_matches(configured.outbounds, table, ipv6) && outbound_chain_matches(configured.outbounds))
        return { ok: true, changed: false };

    let removed = remove_outbound_policy();
    if (!removed.ok) return removed;
    let cleared = clear_outbound_chain();
    if (!cleared.ok) return cleared;
    if (!length(configured.outbounds)) return { ok: true, changed: true };
    if (!quiet(`nft list chain inet ${TABLE} ${OUTBOUND_CHAIN}`)) return { ok: false, error: 'WLOC outbound dispatch chain is missing' };

    sequence++;
    let path = `${RUNTIME}/outbound-chain.${time()}.${sequence}.nft`;
    let lines = [ `flush chain inet ${TABLE} ${OUTBOUND_CHAIN}` ];
    for (let outbound in configured.outbounds)
        push(lines, `add rule inet ${TABLE} ${OUTBOUND_CHAIN} meta mark ${outbound.mark} meta l4proto { tcp, udp } counter tproxy to :${outbound.port} accept comment "wloc outbound"`);
    let content = join('\n', lines) + '\n';
    let written = fs.writefile(path, content);
    if (written == null || written != length(content)) { fs.unlink(path); return { ok: false, error: 'unable to stage WLOC outbound dispatch transaction' }; }
    fs.chmod(path, 0o600);
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    if (!applied.ok) return { ok: false, error: trim(applied.output || '') || 'unable to apply WLOC outbound dispatch rules' };

    let installed = [];
    for (let outbound in configured.outbounds) {
        if (!quiet(`ip -4 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/0xffffffff lookup ${table}`)) {
            clear_outbound_chain();
            for (let item in installed) delete_policy_rule('4', item.mark, table);
            return { ok: false, error: `unable to install IPv4 outbound policy for mark ${outbound.mark}` };
        }
        if (ipv6 && !quiet(`ip -6 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/0xffffffff lookup ${table}`)) {
            clear_outbound_chain();
            delete_policy_rule('4', outbound.mark, table);
            for (let item in installed) { delete_policy_rule('4', item.mark, table); delete_policy_rule('6', item.mark, table); }
            return { ok: false, error: `unable to install IPv6 outbound policy for mark ${outbound.mark}` };
        }
        push(installed, outbound);
    }
    let saved = write_outbound_state(configured.outbounds, table, ipv6);
    if (!saved.ok) {
        clear_outbound_chain();
        for (let item in installed) { delete_policy_rule('4', item.mark, table); if (ipv6) delete_policy_rule('6', item.mark, table); }
        return saved;
    }
    return { ok: true, changed: true };
}
function reconcile(port) {
    if (!valid_port(port)) return { ok: false, error: 'listen port must be between 1 and 65535 for the transparent proxy' };
    let configured = configured_rules();
    if (!configured.ok) return configured;
    let route = run_routing('apply-effective');
    if (!route.ok) return { ok: false, error: route.error || 'unable to ensure TPROXY policy routing' };
    let ingress = sync_ingress(configured);
    if (!ingress.ok) return { ok: false, error: `ingress-set reconciliation failed: ${ingress.error}` };
    let outbound = sync_outbound(configured, route);
    if (!outbound.ok) return { ok: false, error: `outbound reconciliation failed: ${outbound.error}` };
    return { ok: true, interfaces: configured.interfaces, route_active: true, outbound_count: length(configured.outbounds) };
}
function cleanup(reset) {
    let errors = [];
    let cleared = clear_ingress();
    if (!cleared.ok) push(errors, cleared.error);
    let outbound_chain = clear_outbound_chain();
    if (!outbound_chain.ok) push(errors, outbound_chain.error);
    let outbound_policy = remove_outbound_policy();
    if (!outbound_policy.ok) push(errors, outbound_policy.error);
    let route = run_routing(reset ? 'reset' : 'deactivate');
    if (!route.ok) push(errors, route.error || `unable to ${reset ? 'reset' : 'deactivate'} TPROXY policy routing`);
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true, route_active: false };
}
function dispatch(command, args) {
    if (command == 'reconcile') return reconcile(args[0]);
    if (command == 'cleanup') return cleanup(false);
    if (command == 'reset') return cleanup(true);
    if (command == 'sync-ingress') {
        let configured = configured_rules();
        return configured.ok ? sync_ingress(configured) : configured;
    }
    return { ok: false, error: `unsupported rules command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
