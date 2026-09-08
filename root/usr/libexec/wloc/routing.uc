#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';

const SOURCE = '/etc/wloc/routing.conf';
const RUNTIME = '/var/run/wloc';
const APPLIED = `${RUNTIME}/routing.applied.conf`;
const MAX_BYTES = 32 * 1024;
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
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function pid() {
    let proc = fs.popen('echo $PPID', 'r');
    if (!proc) return 0;
    let value = int(trim(proc.read('all') || '0'));
    proc.close();
    return value;
}
function temporary(prefix) { sequence++; return `${prefix}.${pid()}.${time()}.${sequence}`; }
function atomic_write(path, value) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    let tmp = temporary(`${path}.tmp`);
    let written = fs.writefile(tmp, value);
    if (written == null || written != length(value)) { fs.unlink(tmp); return { ok: false, error: 'cannot write temporary routing file' }; }
    if (fs.chmod(tmp, 0o600) !== true) { fs.unlink(tmp); return { ok: false, error: 'cannot secure temporary routing file' }; }
    if (fs.rename(tmp, path) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot replace ${path}` }; }
    fs.chmod(path, 0o600);
    return { ok: true };
}
function number(value) {
    if (value == null) return null;
    let text = `${value}`;
    if (match(text, /^0[xX][0-9A-Fa-f]+$/)) return int(substr(text, 2), 16);
    let value_number = +text;
    return value_number == value_number ? value_number : null;
}
function parse_config(raw) {
    raw = `${raw ?? ''}`;
    if (length(raw) > MAX_BYTES) return { ok: false, error: 'routing file is larger than 32 KiB' };
    if (index(raw, '\0') >= 0) return { ok: false, error: 'routing file contains a NUL byte' };
    raw = replace(replace(raw, /\r\n/g, '\n'), /\r/g, '\n');

    let routes = {}, rules = {}, lines = [];
    for (let source_line in split(raw, '\n')) {
        let line = trim(source_line || '');
        if (!line || substr(line, 0, 1) == '#') continue;

        let route = match(line, /^ip\s+-([46])\s+route\s+replace\s+local\s+(\S+)\s+dev\s+lo\s+table\s+(\d+)$/);
        if (route) {
            let family = route[1];
            if (routes[family]) return { ok: false, error: `duplicate IPv${family} route` };
            routes[family] = { family, prefix: route[2], table: int(route[3]), route: line };
            push(lines, line);
            continue;
        }

        let rule = match(line, /^ip\s+-([46])\s+rule\s+add\s+fwmark\s+([^\/\s]+)\/([^\s]+)\s+lookup\s+(\d+)$/);
        if (!rule) return { ok: false, error: `unsupported routing command: ${line}` };
        let family = rule[1];
        if (rules[family]) return { ok: false, error: `duplicate IPv${family} rule` };
        let mark = number(rule[2]), mask = number(rule[3]), table = int(rule[4]);
        if (mark == null || mask == null || mark < 1 || mask < 1 || mark > 0xffffffff || mask > 0xffffffff)
            return { ok: false, error: 'invalid firewall mark or mask' };
        rules[family] = { family, mark, mask, table, rule: line };
        push(lines, line);
    }

    for (let family in [ '4', '6' ])
        if (!!routes[family] != !!rules[family])
            return { ok: false, error: `routing file must declare both IPv${family} route and rule` };
    if (!routes['4'] && !routes['6'])
        return { ok: false, error: 'routing file must declare at least one route and rule pair' };

    let state = { normalized: join('\n', lines) + '\n', ipv6_enabled: !!routes['6'] };
    for (let family in [ '4', '6' ]) {
        if (!routes[family]) continue;
        if (routes[family].table != rules[family].table) return { ok: false, error: `IPv${family} route and rule must use the same table` };
        state[`ipv${family}`] = {
            family,
            prefix: routes[family].prefix,
            table: routes[family].table,
            mark: rules[family].mark,
            mask: rules[family].mask,
            route: routes[family].route,
            rule: rules[family].rule
        };
    }
    return { ok: true, state };
}
function run_command(command, label) {
    let result = capture(command);
    if (result.ok) return { ok: true };
    return { ok: false, error: `${label}: ${trim(result.output || '') || result.error || 'command failed'}` };
}
function delete_rule(spec) {
    return run_command(`ip -${spec.family} rule del fwmark ${spec.mark}/${spec.mask} lookup ${spec.table}`,
        `unable to remove the IPv${spec.family} TPROXY policy rule`);
}
function delete_route(spec) {
    return run_command(`ip -${spec.family} route del local ${q(spec.prefix)} dev lo table ${spec.table}`,
        `unable to remove the IPv${spec.family} TPROXY local route`);
}
function remove_state(state) {
    if (!state) return { ok: true };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let removed = delete_rule(spec);
        if (!removed.ok) return removed;
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let removed = delete_route(spec);
        if (!removed.ok) return removed;
    }
    return { ok: true };
}
function cleanup_created(created) {
    let errors = [];
    for (let i = length(created.rules) - 1; i >= 0; i--) {
        let removed = delete_rule(created.rules[i]);
        if (!removed.ok) push(errors, removed.error);
    }
    for (let i = length(created.routes) - 1; i >= 0; i--) {
        let removed = delete_route(created.routes[i]);
        if (!removed.ok) push(errors, removed.error);
    }
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true };
}
function install_state(state) {
    let created = { routes: [], rules: [] };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let installed = run_command(spec.route, `unable to install the IPv${family} TPROXY local route`);
        if (!installed.ok) return { ok: false, error: installed.error, created };
        push(created.routes, spec);
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let installed = run_command(spec.rule, `unable to install the IPv${family} TPROXY policy rule`);
        if (!installed.ok) return { ok: false, error: installed.error, created };
        push(created.rules, spec);
    }
    return { ok: true, created };
}
function apply_failure(error, created) {
    let cleaned = cleanup_created(created || { routes: [], rules: [] });
    return cleaned.ok
        ? { ok: false, error }
        : { ok: false, error, detail: `partial routing cleanup failed: ${cleaned.error}` };
}
function snapshot_status(raw) {
    if (!raw) return { ok: true, active: false, ipv4: false, ipv6: false, state: null };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: `invalid applied routing snapshot: ${parsed.error}` };
    return { ok: true, active: true, ipv4: !!parsed.state.ipv4, ipv6: !!parsed.state.ipv6, state: parsed.state };
}
function runtime_text(state) {
    let output = [];
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let rules = capture(`ip -${family} rule show`);
        if (!rules.ok) return { ok: false, error: `unable to read IPv${family} policy rules: ${trim(rules.output || '') || rules.error || 'command failed'}` };
        let routes = capture(`ip -${family} route show table ${spec.table}`);
        if (!routes.ok) return { ok: false, error: `unable to read IPv${family} routing table ${spec.table}: ${trim(routes.output || '') || routes.error || 'command failed'}` };
        push(output, `# ip -${family} rule show\n${trim(rules.output || '')}`);
        push(output, `# ip -${family} route show table ${spec.table}\n${trim(routes.output || '')}`);
    }
    return { ok: true, active: join('\n\n', output) + '\n' };
}
function read_current() {
    let raw = read_text(SOURCE);
    if (raw == null) return { ok: false, error: `cannot read ${SOURCE}`, path: SOURCE };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error, path: SOURCE };
    let state = parsed.state, applied_raw = read_text(APPLIED), status = snapshot_status(applied_raw);
    if (!status.ok) return status;
    return {
        ok: true,
        path: SOURCE,
        config: state.normalized,
        bytes: length(state.normalized),
        ipv6_enabled: state.ipv6_enabled,
        route_active: status.active,
        route_ipv4: status.ipv4,
        route_ipv6: status.ipv6,
        applied_config: applied_raw || '',
        applied_path: APPLIED
    };
}
function runtime_current() {
    let status = snapshot_status(read_text(APPLIED));
    if (!status.ok) return status;
    if (!status.active)
        return { ok: true, active: '# No active policy routing commands are installed.\n', route_active: false, route_ipv4: false, route_ipv6: false };
    let runtime = runtime_text(status.state);
    if (!runtime.ok) return runtime;
    return {
        ok: true,
        active: runtime.active,
        route_active: true,
        route_ipv4: status.ipv4,
        route_ipv6: status.ipv6,
        ipv6_enabled: status.state.ipv6_enabled
    };
}
function save(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let result = atomic_write(SOURCE, parsed.state.normalized);
    return result.ok
        ? { ok: true, valid: true, path: SOURCE, config: parsed.state.normalized, bytes: length(parsed.state.normalized) }
        : { ok: false, valid: true, error: result.error };
}
function applied_result(state) {
    return { ok: true, valid: true, applied: true, config: state.normalized, applied_config: state.normalized, ipv6_enabled: state.ipv6_enabled };
}
function apply(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;

    let previous_raw = read_text(APPLIED);
    if (previous_raw) {
        let previous = parse_config(previous_raw);
        if (!previous.ok) return { ok: false, error: `invalid applied routing snapshot: ${previous.error}` };
        if (previous.state.normalized == state.normalized) return applied_result(state);
        let removed = remove_state(previous.state);
        if (!removed.ok) return removed;
        fs.unlink(APPLIED);
    }

    let installed = install_state(state);
    if (!installed.ok) return apply_failure(installed.error, installed.created);
    let saved = atomic_write(APPLIED, state.normalized);
    if (!saved.ok) return apply_failure(saved.error, installed.created);
    return applied_result(state);
}
function apply_effective() {
    let raw = read_text(SOURCE);
    if (raw == null) return { ok: false, error: `cannot read ${SOURCE}` };
    return apply(raw);
}
function deactivate() {
    let raw = read_text(APPLIED);
    if (!raw) return { ok: true, route_active: false };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    let removed = remove_state(parsed.state);
    if (!removed.ok) return removed;
    fs.unlink(APPLIED);
    return { ok: true, route_active: false };
}
function file_input(path) {
    let raw = read_text(`${path ?? ''}`);
    return raw == null ? { ok: false, error: `cannot read ${path ?? ''}` } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'read') return read_current();
    if (command == 'active') return runtime_current();
    if (command == 'apply-effective') return apply_effective();
    if (command == 'deactivate') return deactivate();
    if (command == 'save-file') {
        let input = file_input(args[0]);
        if (!input.ok) return input;
        return save(input.raw);
    }
    return { ok: false, error: `unsupported routing command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
