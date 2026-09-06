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
function normalized_prefix(family, prefix) {
    if (prefix == 'default') return family == '4' ? '0.0.0.0/0' : '::/0';
    return prefix;
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

    let state = { normalized: join('\n', lines) + '\n', commands: lines, route_commands: [], rule_commands: [], ipv6_enabled: !!routes['6'] };
    for (let family in [ '4', '6' ]) {
        if (!routes[family]) continue;
        if (routes[family].table != rules[family].table) return { ok: false, error: `IPv${family} route and rule must use the same table` };
        let spec = {
            family,
            prefix: routes[family].prefix,
            table: routes[family].table,
            mark: rules[family].mark,
            mask: rules[family].mask,
            route: routes[family].route,
            rule: rules[family].rule
        };
        state[`ipv${family}`] = spec;
        push(state.route_commands, spec.route);
        push(state.rule_commands, spec.rule);
    }
    let primary = state.ipv4 || state.ipv6;
    state.mark = primary.mark;
    state.mask = primary.mask;
    state.table = primary.table;
    return { ok: true, state };
}
function rule_present(spec) {
    let result = capture(`ip -${spec.family} rule show`);
    if (!result.ok) return false;
    for (let source_line in split(result.output || '', '\n')) {
        let body = trim(replace(source_line, /^\s*\d+:\s*/, ''));
        let found = match(body, /^from\s+all\s+fwmark\s+(\S+)\s+[Ll]ookup\s+(\S+)$/);
        if (!found) continue;
        let markmask = split(found[1], '/');
        let mark = number(markmask[0]), mask = number(length(markmask) > 1 ? markmask[1] : '0xffffffff');
        if (mark == spec.mark && mask == spec.mask && number(found[2]) == spec.table) return true;
    }
    return false;
}
function route_state(spec) {
    let result = capture(`ip -${spec.family} route show table ${spec.table}`);
    if (!result.ok) return { exact: false, conflict: false };
    let expected = normalized_prefix(spec.family, spec.prefix);
    let exact = false, conflict = false;
    for (let line in split(result.output || '', '\n')) {
        let fields = split(trim(line), /\s+/);
        if (length(fields) < 2 || normalized_prefix(spec.family, fields[1]) != expected) continue;
        if (fields[0] == 'local' && match(line, /\sdev\s+lo(\s|$)/)) exact = true;
        else conflict = true;
    }
    return { exact, conflict };
}
function active(spec) { return route_state(spec).exact && rule_present(spec); }
function same_route_spec(a, b) {
    return !!a && !!b && a.family == b.family && normalized_prefix(a.family, a.prefix) == normalized_prefix(b.family, b.prefix) && a.table == b.table;
}
function delete_rules(spec) {
    let count = 0;
    while (rule_present(spec)) {
        if (count++ >= 64 || !quiet(`ip -${spec.family} rule del fwmark ${spec.mark}/${spec.mask} lookup ${spec.table}`)) return false;
    }
    return true;
}
function delete_route(spec) {
    if (!route_state(spec).exact) return true;
    return quiet(`ip -${spec.family} route del local ${q(spec.prefix)} dev lo table ${spec.table}`);
}
function ensure_route(spec) {
    let current = route_state(spec), added = false;
    if (current.conflict) return { ok: false, added, error: `refusing to replace existing IPv${spec.family} route ${spec.prefix}` };
    if (!current.exact) {
        let executed = capture(`ip -${spec.family} route add local ${q(spec.prefix)} dev lo table ${spec.table}`);
        if (!executed.ok) {
            let detail = trim(executed.output || '') || executed.error || 'command failed';
            return { ok: false, added, error: `unable to install the IPv${spec.family} TPROXY local route: ${detail}` };
        }
        added = true;
    }
    if (!route_state(spec).exact) return { ok: false, added, error: `IPv${spec.family} TPROXY local route verification failed` };
    return { ok: true, added };
}
function ensure_rule(spec) {
    let added = false;
    if (!rule_present(spec)) {
        let executed = capture(spec.rule);
        if (!executed.ok) {
            let detail = trim(executed.output || '') || executed.error || 'command failed';
            return { ok: false, added, error: `unable to install the IPv${spec.family} TPROXY policy rule: ${detail}` };
        }
        added = true;
    }
    if (!rule_present(spec)) return { ok: false, added, error: `IPv${spec.family} TPROXY policy rule verification failed` };
    return { ok: true, added };
}
function remove_state(state, keep_routes) {
    if (!state) return { ok: true };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && rule_present(spec) && !delete_rules(spec)) return { ok: false, error: `unable to remove the IPv${family} TPROXY policy rule` };
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        let keep = keep_routes ? keep_routes[`ipv${family}`] : null;
        if (spec && !same_route_spec(spec, keep) && route_state(spec).exact && !delete_route(spec))
            return { ok: false, error: `unable to remove the IPv${family} TPROXY local route` };
    }
    return { ok: true };
}
function cleanup_created(created) {
    let errors = [];
    for (let i = length(created.rules) - 1; i >= 0; i--) {
        let spec = created.rules[i];
        if (rule_present(spec) && !delete_rules(spec)) push(errors, `unable to remove newly added IPv${spec.family} TPROXY policy rule`);
    }
    for (let i = length(created.routes) - 1; i >= 0; i--) {
        let spec = created.routes[i];
        if (route_state(spec).exact && !delete_route(spec)) push(errors, `unable to remove newly added IPv${spec.family} TPROXY local route`);
    }
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true };
}
function install_state(state) {
    let created = { routes: [], rules: [] };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_route(spec);
        if (result.added) push(created.routes, spec);
        if (!result.ok) return { ok: false, error: result.error, created };
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_rule(spec);
        if (result.added) push(created.rules, spec);
        if (!result.ok) return { ok: false, error: result.error, created };
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && !active(spec)) return { ok: false, error: `IPv${family} TPROXY policy route verification failed`, created };
    }
    return { ok: true, created };
}
function apply_failure(error, created) {
    let cleaned = cleanup_created(created || { routes: [], rules: [] });
    return cleaned.ok
        ? { ok: false, error }
        : { ok: false, error, detail: `partial routing cleanup failed: ${cleaned.error}` };
}
function state_status(state) {
    let has4 = !!state && !!state.ipv4;
    let has6 = !!state && !!state.ipv6;
    let ipv4 = has4 && active(state.ipv4);
    let ipv6 = has6 && active(state.ipv6);
    return { active: (has4 || has6) && (!has4 || ipv4) && (!has6 || ipv6), ipv4, ipv6 };
}
function runtime_text(state) {
    if (!state) return '# No active policy routing commands are installed.\n';
    let output = [];
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let rules = capture(`ip -${family} rule show`).output || '';
        let routes = capture(`ip -${family} route show table ${spec.table}`).output || '';
        push(output, `# ip -${family} rule show\n${trim(rules)}`);
        push(output, `# ip -${family} route show table ${spec.table}\n${trim(routes)}`);
    }
    return join('\n\n', output) + '\n';
}
function validate(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;
    return {
        ok: true, valid: true, config: state.normalized, bytes: length(state.normalized), commands: state.commands,
        route_commands: state.route_commands, rule_commands: state.rule_commands, ipv6_enabled: state.ipv6_enabled,
        firewall_mark: state.mark, routing_table: state.table
    };
}
function read_current() {
    let raw = read_text(SOURCE);
    if (raw == null) return { ok: false, error: `cannot read ${SOURCE}`, path: SOURCE };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error, path: SOURCE };
    let state = parsed.state, applied_raw = read_text(APPLIED), status = state_status(state);
    return {
        ok: true, path: SOURCE, config: state.normalized, bytes: length(state.normalized),
        ipv6_enabled: state.ipv6_enabled, firewall_mark: state.mark, routing_table: state.table,
        route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        commands: state.commands, route_commands: state.route_commands, rule_commands: state.rule_commands,
        applied_config: applied_raw || '', applied_path: APPLIED
    };
}
function runtime_current() {
    let raw = read_text(APPLIED);
    if (!raw) return { ok: true, active: '# No active policy routing commands are installed.\n', route_active: false, route_ipv4: false, route_ipv6: false };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    let state = parsed.state, status = state_status(state);
    return {
        ok: true, active: runtime_text(state), route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        ipv6_enabled: state.ipv6_enabled, firewall_mark: state.mark, routing_table: state.table
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
function apply(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;

    let previous_raw = read_text(APPLIED);
    if (previous_raw) {
        let checked = parse_config(previous_raw);
        if (!checked.ok) return { ok: false, error: `invalid applied routing snapshot: ${checked.error}` };
        if (checked.state.normalized != state.normalized) {
            let removed = remove_state(checked.state, state);
            if (!removed.ok) return removed;
        }
    }

    fs.unlink(APPLIED);
    let installed = install_state(state);
    if (!installed.ok) return apply_failure(installed.error, installed.created);

    let saved = atomic_write(APPLIED, state.normalized);
    if (!saved.ok) return apply_failure(saved.error, installed.created);

    return {
        ok: true, valid: true, applied: true, config: state.normalized, applied_config: state.normalized,
        ipv6_enabled: state.ipv6_enabled, commands: state.commands, route_commands: state.route_commands,
        rule_commands: state.rule_commands, firewall_mark: state.mark, routing_table: state.table
    };
}
function apply_effective() {
    let raw = read_text(SOURCE);
    if (raw == null) return { ok: false, error: `cannot read ${SOURCE}` };
    return apply(raw);
}
function deactivate(reset) {
    let raw = read_text(APPLIED);
    if (!raw) raw = read_text(SOURCE);
    if (!raw) {
        if (reset) fs.unlink(APPLIED);
        return { ok: true, route_active: false };
    }
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    let removed = remove_state(parsed.state, null);
    if (!removed.ok) return removed;
    if (reset) fs.unlink(APPLIED);
    return { ok: true, route_active: false };
}
function file_input(path) {
    let raw = read_text(`${path ?? ''}`);
    return raw == null ? { ok: false, error: `cannot read ${path ?? ''}` } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'read') return read_current();
    if (command == 'active') return runtime_current();
    if (command == 'ready') {
        let current = runtime_current();
        return current.ok ? { ok: current.route_active === true, active: current.route_active === true } : current;
    }
    if (command == 'apply-effective') return apply_effective();
    if (command == 'deactivate') return deactivate(false);
    if (command == 'reset') return deactivate(true);
    if (command == 'validate-file' || command == 'save-file' || command == 'apply-file') {
        let input = file_input(args[0]);
        if (!input.ok) return input;
        if (command == 'validate-file') return validate(input.raw);
        if (command == 'save-file') return save(input.raw);
        return apply(input.raw);
    }
    return { ok: false, error: `unsupported routing command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
