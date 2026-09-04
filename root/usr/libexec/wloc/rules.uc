#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const RUNTIME = '/var/run/wloc';
const FAMILY = 'bridge';
const TABLE = 'wloc';
const SET = 'target_ingress_interfaces';
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
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
function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function valid_port(value) {
    let text = `${value ?? ''}`;
    if (!match(text, /^[0-9]+$/)) return false;
    let port = int(text);
    return port >= 1 && port <= 65535;
}
function clear_ingress() {
    if (!quiet(`nft list set ${FAMILY} ${TABLE} ${SET}`)) return { ok: true };
    if (!quiet(`nft flush set ${FAMILY} ${TABLE} ${SET}`)) return { ok: false, error: 'unable to clear WLOC ingress interface set' };
    return { ok: true };
}
function configured_interfaces() {
    let ctx = cursor(), values = [], seen = {}, error = null;
    try {
        ctx.foreach('wloc', 'wifi', function(section) {
            if (error) return;
            let enabled = section.enabled == null ? true : (`${section.enabled}` == '1' || section.enabled === true);
            if (!enabled) return;
            let iface = `${section.iface || ''}`;
            if (!valid_iface(iface)) {
                error = `invalid interface in enabled rule ${section['.name'] || ''}`;
                return;
            }
            if (!seen[iface]) { seen[iface] = true; push(values, iface); }
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (error) return { ok: false, error };
    if (!length(values)) return { ok: false, error: 'no enabled ingress interfaces are configured' };
    return { ok: true, interfaces: values };
}
function sync_ingress() {
    if (!quiet(`nft list set ${FAMILY} ${TABLE} ${SET}`)) return { ok: false, error: 'target ingress interface set is missing' };
    let configured = configured_interfaces();
    if (!configured.ok) return configured;
    if (!quiet(`mkdir -p ${q(RUNTIME)}`)) return { ok: false, error: 'unable to create WLOC runtime directory' };
    sequence++;
    let path = `${RUNTIME}/ingress-set.${time()}.${sequence}.nft`;
    let lines = [ `flush set ${FAMILY} ${TABLE} ${SET}` ];
    for (let iface in configured.interfaces) push(lines, `add element ${FAMILY} ${TABLE} ${SET} { "${iface}" }`);
    let content = join('\n', lines) + '\n';
    let written = fs.writefile(path, content);
    if (written == null || written != length(content)) { fs.unlink(path); return { ok: false, error: 'unable to stage WLOC ingress set transaction' }; }
    fs.chmod(path, 0o600);
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    if (!applied.ok) return { ok: false, error: trim(applied.output || '') || 'unable to refresh ingress set; custom rules were left unchanged' };
    return { ok: true, interfaces: configured.interfaces };
}
function reconcile(port) {
    if (!valid_port(port)) return { ok: false, error: 'listen port must be between 1 and 65535 for the transparent proxy' };
    let route = run_routing('apply-effective');
    if (!route.ok) return { ok: false, error: route.error || 'unable to ensure TPROXY policy routing' };
    let ingress = sync_ingress();
    if (!ingress.ok) return { ok: false, error: `ingress-set reconciliation failed: ${ingress.error}` };
    return { ok: true, interfaces: ingress.interfaces, route_active: true };
}
function cleanup(reset) {
    let errors = [];
    let cleared = clear_ingress();
    if (!cleared.ok) push(errors, cleared.error);
    let route = run_routing(reset ? 'reset' : 'deactivate');
    if (!route.ok) push(errors, route.error || `unable to ${reset ? 'reset' : 'deactivate'} TPROXY policy routing`);
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true, route_active: false };
}
function dispatch(command, args) {
    if (command == 'reconcile') return reconcile(args[0]);
    if (command == 'cleanup') return cleanup(false);
    if (command == 'reset') return cleanup(true);
    if (command == 'sync-ingress') return sync_ingress();
    return { ok: false, error: `unsupported rules command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
