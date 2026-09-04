#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';

const SOURCE = '/etc/wloc/routing.conf';
const DEFAULT_SOURCE = '/usr/share/wloc/defaults/routing.conf';
const RUNTIME = '/var/run/wloc';
const APPLIED = `${RUNTIME}/routing.applied.conf`;
const CANDIDATE = `${APPLIED}.next`;
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
function fields(value) { return split(trim(`${value ?? ''}`), /[[:space:]]+/); }
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
    if (!match(text, /^[0-9]+$/)) return null;
    return int(text);
}
function hex(value) { return sprintf('0x%x', value); }
function valid_ipv4_prefix(value) {
    let found = match(`${value ?? ''}`, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\/([0-9]+)$/);
    if (!found) return false;
    for (let i = 1; i <= 4; i++) {
        let octet = int(found[i]);
        if (octet < 0 || octet > 255) return false;
    }
    let prefix = int(found[5]);
    return prefix >= 0 && prefix <= 32;
}
function valid_ipv6_prefix(value) {
    let found = match(`${value ?? ''}`, /^([0-9A-Fa-f:]+)\/([0-9]+)$/);
    if (!found || index(found[1], ':') < 0) return false;
    let prefix = int(found[2]);
    return prefix >= 0 && prefix <= 128;
}
function normalized_prefix(family, prefix) {
    if (prefix == 'default') return family == '4' ? '0.0.0.0/0' : '::/0';
    return prefix;
}
function parse_route(parts) {
    if (length(parts) != 10 || parts[0] != 'ip' || (parts[1] != '-4' && parts[1] != '-6') ||
        parts[2] != 'route' || parts[3] != 'replace' || parts[4] != 'local' ||
        parts[6] != 'dev' || parts[7] != 'lo' || parts[8] != 'table') return null;
    let family = substr(parts[1], 1), table = number(parts[9]), prefix = parts[5];
    if (table == null || table < 1 || table > 4294967295) return { error: `IPv${family} routing table is outside 1..4294967295` };
    if (family == '4' ? !valid_ipv4_prefix(prefix) : !valid_ipv6_prefix(prefix)) return { error: `invalid IPv${family} local route prefix` };
    return { family, table, prefix };
}
function parse_rule(parts) {
    if (length(parts) != 10 || parts[0] != 'ip' || (parts[1] != '-4' && parts[1] != '-6') ||
        parts[2] != 'rule' || parts[3] != 'add' || parts[4] != 'priority' || parts[6] != 'fwmark' || parts[8] != 'lookup') return null;
    let family = substr(parts[1], 1), priority = number(parts[5]), table = number(parts[9]);
    let markmask = split(parts[7], '/');
    if (length(markmask) != 2) return { error: `IPv${family} fwmark must include a hexadecimal mask` };
    let mark = number(markmask[0]), mask = number(markmask[1]);
    if (priority == null || priority < 1 || priority > 4294967295) return { error: `IPv${family} routing rule priority is outside 1..4294967295` };
    if (table == null || table < 1 || table > 4294967295) return { error: `IPv${family} routing table is outside 1..4294967295` };
    if (mark == null || mark < 1 || mark > 0xffffffff) return { error: `IPv${family} fwmark must be a non-zero hexadecimal value up to 32 bits` };
    if (mask == null || mask < 1 || mask > 0xffffffff) return { error: `IPv${family} fwmark mask must be a non-zero hexadecimal value up to 32 bits` };
    return { family, priority, mark, mask, table };
}
function parse_config(raw) {
    raw = `${raw ?? ''}`;
    if (length(raw) > MAX_BYTES) return { ok: false, error: 'routing file is larger than 32 KiB' };
    if (index(raw, '\0') >= 0) return { ok: false, error: 'routing file contains a NUL byte' };
    raw = replace(replace(raw, /\r\n/g, '\n'), /\r/g, '\n');

    let routes = {}, rules = {};
    for (let source_line in split(raw, '\n')) {
        let line = trim(source_line || '');
        if (!line || substr(line, 0, 1) == '#') continue;
        let parts = fields(line), route = parse_route(parts);
        if (route) {
            if (route.error) return { ok: false, error: route.error };
            if (routes[route.family]) return { ok: false, error: `routing file declares more than one IPv${route.family} local route command` };
            routes[route.family] = route;
            continue;
        }
        let rule = parse_rule(parts);
        if (!rule) return { ok: false, error: `unsupported routing command: ${line}` };
        if (rule.error) return { ok: false, error: rule.error };
        if (rules[rule.family]) return { ok: false, error: `routing file declares more than one IPv${rule.family} fwmark rule command` };
        rules[rule.family] = rule;
    }

    if (!routes['4'] || !rules['4']) return { ok: false, error: 'routing file must declare one IPv4 local route and one IPv4 fwmark rule' };
    if (!!routes['6'] != !!rules['6']) return { ok: false, error: 'routing file must declare both IPv6 route and rule commands' };

    let state = { commands: [], route_commands: [], rule_commands: [], ipv6_enabled: !!routes['6'] };
    for (let family in [ '4', '6' ]) {
        if (!routes[family]) continue;
        if (routes[family].table != rules[family].table) return { ok: false, error: `IPv${family} route and rule must use the same routing table` };
        let spec = {
            family,
            prefix: routes[family].prefix,
            table: routes[family].table,
            priority: rules[family].priority,
            mark: rules[family].mark,
            mask: rules[family].mask
        };
        spec.route = `ip -${family} route replace local ${spec.prefix} dev lo table ${spec.table}`;
        spec.rule = `ip -${family} rule add priority ${spec.priority} fwmark ${hex(spec.mark)}/${hex(spec.mask)} lookup ${spec.table}`;
        state[`ipv${family}`] = spec;
        push(state.route_commands, spec.route);
        push(state.rule_commands, spec.rule);
        push(state.commands, spec.route);
        push(state.commands, spec.rule);
    }
    state.normalized = join('\n', state.commands) + '\n';
    state.mark = state.ipv4.mark;
    state.mask = state.ipv4.mask;
    state.table = state.ipv4.table;
    return { ok: true, state };
}
function rule_present(spec) {
    let result = capture(`ip -${spec.family} rule show`);
    if (!result.ok) return false;
    for (let line in split(result.output || '', '\n')) {
        let parts = fields(line);
        if (length(parts) < 7) continue;
        let priority_text = parts[0] || '';
        if (substr(priority_text, -1) == ':') priority_text = substr(priority_text, 0, length(priority_text) - 1);
        if (number(priority_text) != spec.priority || parts[1] != 'from' || parts[2] != 'all' || parts[3] != 'fwmark') continue;
        let markmask = split(parts[4] || '', '/');
        let mark = number(markmask[0]), mask = number(length(markmask) > 1 ? markmask[1] : '0xffffffff');
        if (parts[5] == 'lookup' && mark == spec.mark && mask == spec.mask && number(parts[6]) == spec.table) return true;
    }
    return false;
}
function route_state(spec) {
    let result = capture(`ip -${spec.family} route show table ${spec.table}`);
    if (!result.ok) return { exact: false, conflict: false };
    let expected = normalized_prefix(spec.family, spec.prefix);
    let exact = false, conflict = false;
    for (let line in split(result.output || '', '\n')) {
        let parts = fields(line);
        if (length(parts) < 2 || normalized_prefix(spec.family, parts[1]) != expected) continue;
        let local = parts[0] == 'local', loopback = false;
        for (let i = 2; i + 1 < length(parts); i++) if (parts[i] == 'dev' && parts[i + 1] == 'lo') loopback = true;
        if (local && loopback) exact = true;
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
        if (count++ >= 64 || !quiet(`ip -${spec.family} rule del priority ${spec.priority} fwmark ${hex(spec.mark)}/${hex(spec.mask)} lookup ${spec.table}`)) return false;
    }
    return true;
}
function delete_route(spec) {
    if (!route_state(spec).exact) return true;
    return quiet(`ip -${spec.family} route del local ${q(spec.prefix)} dev lo table ${spec.table}`);
}
function ensure_route(spec) {
    let current = route_state(spec);
    if (current.conflict) return { ok: false, error: `refusing to replace existing IPv${spec.family} route ${spec.prefix}` };
    if (!current.exact && !quiet(`ip -${spec.family} route add local ${q(spec.prefix)} dev lo table ${spec.table}`))
        return { ok: false, error: `unable to install the IPv${spec.family} TPROXY local route` };
    if (!route_state(spec).exact) return { ok: false, error: `IPv${spec.family} TPROXY local route verification failed` };
    return { ok: true };
}
function ensure_rule(spec) {
    if (!rule_present(spec) && !quiet(spec.rule)) return { ok: false, error: `unable to install the IPv${spec.family} TPROXY policy rule` };
    if (!rule_present(spec)) return { ok: false, error: `IPv${spec.family} TPROXY policy rule verification failed` };
    return { ok: true };
}
function install_state(state) {
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_route(spec);
        if (!result.ok) return result;
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_rule(spec);
        if (!result.ok) return result;
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && !active(spec)) return { ok: false, error: `IPv${family} TPROXY policy route verification failed` };
    }
    return { ok: true };
}
function remove_state(state, keep_routes) {
    if (!state) return { ok: true };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && !delete_rules(spec)) return { ok: false, error: `unable to remove the IPv${family} TPROXY policy rule` };
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        let keep = keep_routes ? keep_routes[`ipv${family}`] : null;
        if (spec && !same_route_spec(spec, keep) && route_state(spec).exact && !delete_route(spec))
            return { ok: false, error: `unable to remove the IPv${family} TPROXY local route` };
    }
    return { ok: true };
}
function rollback(previous, current) {
    let errors = [];
    let removed = remove_state(current, previous);
    if (!removed.ok) push(errors, removed.error);
    if (previous) {
        let restored = install_state(previous);
        if (!restored.ok) push(errors, restored.error);
    }
    return { ok: length(errors) == 0, error: join('; ', errors) };
}
function state_status(state) {
    let ipv4 = !!state && !!state.ipv4 && active(state.ipv4);
    let ipv6 = !!state && !!state.ipv6 && active(state.ipv6);
    return { active: ipv4 && (!state || !state.ipv6_enabled || ipv6), ipv4, ipv6 };
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
function effective_raw() {
    let raw = read_text(SOURCE);
    if (raw != null) return { raw, using_default: false };
    raw = read_text(DEFAULT_SOURCE);
    return raw == null ? null : { raw, using_default: true };
}
function validate(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;
    return {
        ok: true, valid: true, config: state.normalized, bytes: length(state.normalized), commands: state.commands,
        route_commands: state.route_commands, rule_commands: state.rule_commands, ipv6_enabled: state.ipv6_enabled,
        firewall_mark: hex(state.mark), routing_table: state.table
    };
}
function read_current() {
    let effective = effective_raw();
    if (!effective) return { ok: false, error: `cannot read ${SOURCE} or ${DEFAULT_SOURCE}`, path: SOURCE };
    let parsed = parse_config(effective.raw);
    if (!parsed.ok) return { ok: false, error: parsed.error, path: SOURCE };
    let state = parsed.state;
    let applied_raw = read_text(APPLIED);
    let applied = applied_raw ? parse_config(applied_raw) : null;
    let runtime_state = applied && applied.ok ? applied.state : state;
    let status = state_status(runtime_state);
    return {
        ok: true, path: SOURCE, config: state.normalized, bytes: length(state.normalized), using_default: effective.using_default,
        active: runtime_text(runtime_state), route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        ipv6_enabled: state.ipv6_enabled, firewall_mark: hex(state.mark), routing_table: state.table,
        applied_config: applied_raw || '', applied_path: APPLIED
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
function apply(raw, stage) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;
    if (stage) {
        let staged = atomic_write(CANDIDATE, state.normalized);
        if (!staged.ok) return staged;
    }

    let previous_raw = read_text(APPLIED), previous = null;
    if (previous_raw) {
        let checked = parse_config(previous_raw);
        if (!checked.ok) { if (stage) fs.unlink(CANDIDATE); return { ok: false, error: `invalid applied routing snapshot: ${checked.error}` }; }
        previous = checked.state;
    }
    if (previous && previous.normalized != state.normalized) {
        let removed = remove_state(previous, state);
        if (!removed.ok) { if (stage) fs.unlink(CANDIDATE); return removed; }
    }

    let installed = install_state(state);
    if (!installed.ok) {
        let restored = rollback(previous, state);
        if (!restored.ok) installed.error += `; rollback failed: ${restored.error}`;
        if (stage) fs.unlink(CANDIDATE);
        return installed;
    }

    let saved = atomic_write(APPLIED, state.normalized);
    if (!saved.ok) {
        let restored = rollback(previous, state);
        if (!restored.ok) saved.error += `; rollback failed: ${restored.error}`;
        if (stage) fs.unlink(CANDIDATE);
        return saved;
    }
    if (stage) fs.unlink(CANDIDATE);
    let status = state_status(state);
    return {
        ok: true, valid: true, applied: true, config: state.normalized, applied_config: state.normalized,
        active: runtime_text(state), route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        ipv6_enabled: state.ipv6_enabled, commands: state.commands, firewall_mark: hex(state.mark), routing_table: state.table
    };
}
function apply_effective() {
    let applied_raw = read_text(APPLIED);
    if (applied_raw) {
        let parsed = parse_config(applied_raw);
        if (!parsed.ok) return { ok: false, error: `invalid applied routing snapshot: ${parsed.error}` };
        let installed = install_state(parsed.state);
        if (!installed.ok) return installed;
        let status = state_status(parsed.state);
        return { ok: status.active, active: status.active, text: runtime_text(parsed.state) };
    }
    let effective = effective_raw();
    if (!effective) return { ok: false, error: `cannot read ${SOURCE} or ${DEFAULT_SOURCE}` };
    return apply(effective.raw, false);
}
function deactivate(reset) {
    let raw = read_text(APPLIED);
    if (!raw) {
        let effective = effective_raw();
        raw = effective ? effective.raw : null;
    }
    if (!raw) {
        if (reset) { fs.unlink(APPLIED); fs.unlink(CANDIDATE); }
        return { ok: true, route_active: false };
    }
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    let removed = remove_state(parsed.state, null);
    if (!removed.ok) return removed;
    if (reset) { fs.unlink(APPLIED); fs.unlink(CANDIDATE); }
    return { ok: true, route_active: false };
}
function file_input(path) {
    let raw = read_text(`${path ?? ''}`);
    return raw == null ? { ok: false, error: `cannot read ${path ?? ''}` } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'read') return read_current();
    if (command == 'active') return read_current();
    if (command == 'ready') {
        let current = read_current();
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
        return apply(input.raw, true);
    }
    return { ok: false, error: `unsupported routing command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
