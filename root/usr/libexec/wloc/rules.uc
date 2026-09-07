#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const ROUTING = '/usr/libexec/wloc/routing.uc';
const FIREWALL = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const LOCATION_STATE = `${RUNTIME}/location.targets`;
const FIREWALL_APPLIED = `${RUNTIME}/firewall.applied.nft`;
const COMPONENTS = {
    firewall: { init: '/etc/init.d/wloc-firewall', option: 'firewall_installed' },
    routing: { init: '/etc/init.d/wloc-routing', option: 'routing_installed' }
};
const MAX_PROFILE = 0xff;

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
function run_firewall(command, args) {
    let shell = `/usr/bin/ucode ${q(FIREWALL)} ${q(command)}`;
    for (let arg in (args || [])) shell += ` ${q(arg)}`;
    let result = capture(shell);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true) return { ok: false, error: result.error || 'firewall controller failed' };
    return parsed;
}
function component_enabled(kind) {
    let spec = COMPONENTS[kind], value = null;
    if (!spec) return false;
    try { value = cursor().get('wloc', 'main', spec.option); } catch (e) {}
    return value === true || value === 1 || value == '1';
}
function set_component_flag(option, enabled) {
    let ctx = cursor();
    ctx.set('wloc', 'main', option, enabled ? '1' : '0');
    return ctx.commit('wloc') === true;
}
function component_action(kind, installing) {
    if (kind == 'firewall')
        return run_firewall(installing ? 'apply-effective' : 'remove-runtime');
    if (kind == 'routing')
        return run_routing(installing ? 'apply-effective' : 'deactivate');
    return { ok: false, error: 'unsupported component action' };
}
function component(kind, operation) {
    let spec = COMPONENTS[kind];
    if (!spec || (operation != 'install' && operation != 'uninstall'))
        return { ok: false, error: 'unsupported component action' };

    let installing = operation == 'install';
    let result = component_action(kind, installing);
    if (result.ok !== true) return result;

    if (!set_component_flag(spec.option, installing)) {
        if (installing) component_action(kind, false);
        return { ok: false, error: `cannot save ${kind} installation state` };
    }

    if (!quiet(`${q(spec.init)} ${installing ? 'enable' : 'disable'}`)) {
        set_component_flag(spec.option, !installing);
        if (installing) component_action(kind, false);
        return { ok: false, error: `cannot ${installing ? 'enable' : 'disable'} ${kind} startup` };
    }

    result.installed = installing;
    return result;
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
    let configured = configured_rules();
    if (!configured.ok) return configured;
    let saved = write_location_targets(targets);
    if (!saved.ok) return saved;
    if (fs.readfile(FIREWALL_APPLIED) == null)
        return { ok: true, changed: true, location_count: length(targets.v4) + length(targets.v6) };
    let refreshed = run_firewall('refresh-runtime');
    if (!refreshed.ok)
        return { ok: false, error: `firewall target refresh failed: ${refreshed.error || 'unable to render location targets'}` };
    return { ok: true, changed: true, location_count: length(targets.v4) + length(targets.v6) };
}
function bootstrap_result(configured, route_active, firewall_active) {
    return { ok: true, interfaces: configured.interfaces, route_active, firewall_active, outbound_count: length(configured.outbounds), location_count: 0 };
}
function cleanup() {
    fs.unlink(LOCATION_STATE);
    if (fs.readfile(FIREWALL_APPLIED) == null) return { ok: true, firewall_active: false };
    let refreshed = run_firewall('refresh-runtime');
    return refreshed.ok
        ? { ok: true, firewall_active: true }
        : { ok: false, error: `firewall dynamic-state cleanup failed: ${refreshed.error || 'unable to render empty location targets'}` };
}
function bootstrap(port) {
    if (!valid_port(port)) return { ok: false, error: 'listen port must be between 1 and 65535 for the transparent proxy' };
    let configured = configured_rules();
    if (!configured.ok) return configured;
    fs.unlink(LOCATION_STATE);

    let route_active = component_enabled('routing');
    if (route_active) {
        let route = run_routing('apply-effective');
        if (!route.ok)
            return { ok: false, error: `routing refresh failed: ${route.error || 'unable to ensure TPROXY policy routing'}` };
    }

    let firewall_active = component_enabled('firewall');
    if (firewall_active) {
        let firewall = run_firewall('apply-effective');
        if (!firewall.ok)
            return { ok: false, error: `firewall refresh failed: ${firewall.detail || firewall.error || 'unable to load WLOC firewall'}` };
    }

    return bootstrap_result(configured, route_active, firewall_active);
}
function dispatch(command, args) {
    if (command == 'bootstrap') return bootstrap(args[0]);
    if (command == 'update-targets') return update_targets(args);
    if (command == 'cleanup') return cleanup();
    if (command == 'component') return component(args[0], args[1]);
    return { ok: false, error: `unsupported rules command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
