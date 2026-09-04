#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const RUNTIME = '/var/run/wloc';
const SOURCE = '/etc/wloc/firewall.nft';
const DEFAULT_SOURCE = '/usr/share/wloc/defaults/firewall.nft';
const APPLIED = `${RUNTIME}/firewall.applied.nft`;
const NEXT = `${APPLIED}.next`;
const RULES = '/usr/libexec/wloc/rules.uc';
const STATUS = '/var/run/wloc/status.json';
const MAX_BYTES = 1024 * 1024;
const FAMILIES = [ 'bridge', 'inet' ];
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
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    let tmp = temporary(`${path}.tmp`);
    let written = fs.writefile(tmp, value);
    if (written == null || written != length(value)) { fs.unlink(tmp); return { ok: false, error: `cannot write temporary file for ${path}` }; }
    if (mode != null && fs.chmod(tmp, mode) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot chmod temporary file for ${path}` }; }
    if (fs.rename(tmp, path) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function normalize(raw) {
    raw = replace(`${raw ?? ''}`, /\r\n/g, '\n');
    raw = replace(raw, /\r/g, '\n');
    if (raw && substr(raw, -1) != '\n') raw += '\n';
    return raw;
}
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
function run_ucode(path, args) {
    let command = `/usr/bin/ucode ${q(path)}`;
    for (let arg in args) command += ` ${q(arg)}`;
    let result = capture(command);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true) return { ok: false, error: result.error || 'controller failed' };
    return parsed;
}
function mask(raw) {
    let output = '', quoted = false, escaped = false, comment = false;
    for (let i = 0; i < length(raw); i++) {
        let c = substr(raw, i, 1);
        if (comment) {
            if (c == '\n') { comment = false; output += '\n'; } else output += ' ';
        } else if (quoted) {
            output += c == '\n' ? '\n' : ' ';
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') quoted = false;
        } else if (c == '#') {
            comment = true; output += ' ';
        } else if (c == '"') {
            quoted = true; output += ' ';
        } else output += c;
    }
    return output;
}
function ownership(raw) {
    let stream = replace(mask(raw), /[;}]/g, '\n');
    let table_count = 0;
    for (let line in split(stream, '\n')) {
        line = trim(line || '');
        if (!line) continue;
        if (match(line, /^(add|create|flush|include|delete|destroy|reset|insert|replace|rename)(\s|$)/))
            return { ok: false, error_code: 'unsupported_firewall_command', error: 'Only declarative definitions of table bridge wloc and table inet wloc are supported.' };
        let table = match(line, /^table\s+(\S+)\s+(\S+)(\s|$)/);
        if (!table) continue;
        table_count++;
        if ((table[1] != 'bridge' && table[1] != 'inet') || table[2] != 'wloc')
            return { ok: false, error_code: 'unsupported_firewall_command', error: 'WLOC owns only table bridge wloc and table inet wloc.' };
    }
    if (!table_count) return { ok: false, error_code: 'unsupported_firewall_command', error: 'Firewall configuration does not declare a WLOC table.' };
    return { ok: true };
}
function table_deletes() {
    let lines = [];
    for (let family in FAMILIES)
        if (quiet(`nft list table ${family} wloc`)) push(lines, `delete table ${family} wloc`);
    return length(lines) ? join('\n', lines) + '\n' : '';
}
function active() {
    let dumps = [], bridge = '', inet = '', count = 0;
    for (let family in FAMILIES) {
        let result = capture(`nft list table ${family} wloc`);
        if (!result.ok) continue;
        count++;
        let text = result.output || '';
        if (family == 'bridge') bridge = text;
        else inet = text;
        push(dumps, trim(text));
    }
    let text = length(dumps) ? join('\n\n', dumps) + '\n' : '# No WLOC nftables tables are active.\n';
    return {
        ok: true,
        active: text,
        active_found: count == 2,
        table_count: 2,
        active_table_count: count,
        bridge_active: bridge,
        inet_active: inet
    };
}
function validate(raw) {
    raw = normalize(raw);
    if (length(raw) > MAX_BYTES) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'Firewall file is larger than 1 MiB.' };
    let owned = ownership(raw);
    if (!owned.ok) return { ok: false, valid: false, error_code: owned.error_code, error: owned.error };
    if (!mkdirp(RUNTIME)) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'Unable to create WLOC runtime directory.' };
    let check = temporary(`${RUNTIME}/firewall-check`);
    let tx = table_deletes() + raw;
    let written = atomic_write(check, tx, 0o600);
    if (!written.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: written.error };
    let result = capture(`nft --check --file ${q(check)}`);
    fs.unlink(check);
    if (!result.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'nftables syntax check failed', detail: trim(result.output || '') || 'validation failed' };
    return { ok: true, valid: true, config: raw, bytes: length(raw) };
}
function remove_tables() {
    let errors = [];
    for (let family in FAMILIES) {
        if (!quiet(`nft list table ${family} wloc`)) continue;
        if (!quiet(`nft delete table ${family} wloc`)) push(errors, `failed to remove nftables table ${family} wloc`);
    }
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true };
}
function rules(command, args) {
    let argv = [ command ];
    for (let arg in (args || [])) push(argv, arg);
    return run_ucode(RULES, argv);
}
function daemon_ready() {
    let st = fs.stat(STATUS);
    return quiet('pidof wlocd') && type(st) == 'object' && int(st.size || 0) > 0;
}
function listen_port() {
    try {
        let ctx = cursor();
        return `${ctx.get('wloc', 'main', 'listen_port') || ''}`;
    } catch (e) { return ''; }
}
function apply(raw) {
    raw = normalize(raw);
    if (!mkdirp(RUNTIME)) return { ok: false, error_code: 'nft_apply_failed', error: 'Unable to create WLOC runtime directory.' };
    fs.unlink(NEXT);
    let staged = atomic_write(NEXT, raw, 0o600);
    if (!staged.ok) return { ok: false, error_code: 'snapshot_stage_failed', error: staged.error };
    let checked = validate(raw);
    if (!checked.ok) { fs.unlink(NEXT); return checked; }

    let transaction = temporary(`${RUNTIME}/firewall-apply`);
    let tx = table_deletes() + raw;
    let written = atomic_write(transaction, tx, 0o600);
    if (!written.ok) { fs.unlink(NEXT); return { ok: false, error_code: 'nft_apply_failed', error: written.error }; }
    let applied = capture(`nft --file ${q(transaction)}`);
    fs.unlink(transaction);
    if (!applied.ok) {
        fs.unlink(NEXT);
        return { ok: false, error_code: 'nft_apply_failed', error: 'The nftables transaction failed.', detail: trim(applied.output || '') || 'apply failed' };
    }

    if (fs.rename(NEXT, APPLIED) !== true || read_text(APPLIED) == null) {
        let errors = [ 'fatal consistency error: nftables transaction succeeded but the applied snapshot could not be promoted' ];
        let removed = remove_tables();
        if (!removed.ok) push(errors, `rollback failed: ${removed.error}`);
        fs.unlink(APPLIED); fs.unlink(NEXT);
        let cleaned = rules('cleanup', []);
        if (!cleaned.ok) push(errors, `fail-open cleanup failed: ${cleaned.error || 'unable to clear runtime state'}`);
        return { ok: false, error_code: 'snapshot_promote_failed', error: join('; ', errors) };
    }
    fs.chmod(APPLIED, 0o600);

    let recovering = false, warning = '';
    if (daemon_ready()) {
        let port = listen_port();
        let reconciled = port ? rules('reconcile', [ port ]) : { ok: false, error: 'the WLOC listen port is empty' };
        if (!reconciled.ok) {
            let cleaned = rules('cleanup', []);
            recovering = true;
            warning = cleaned.ok
                ? 'Runtime rule refresh failed; WLOC will retry automatically.'
                : 'Runtime rule refresh failed and fail-open cleanup also failed; WLOC will retry automatically.';
        }
    } else {
        let cleaned = rules('cleanup', []);
        recovering = true;
        warning = cleaned.ok
            ? 'Runtime dynamic sets are waiting for the WLOC listener; WLOC will retry automatically.'
            : 'WLOC listener is not ready and fail-open cleanup failed; WLOC will retry automatically.';
    }

    let runtime = active();
    return {
        ok: true, valid: true, applied: true, path: SOURCE, config: raw, bytes: length(raw),
        active: runtime.active, active_found: runtime.active_found, recovering, warning,
        applied_config: raw, applied_path: APPLIED
    };
}
function save(raw) {
    raw = normalize(raw);
    let checked = validate(raw);
    if (!checked.ok) return { ok: false, valid: false, error: 'The Firewall file could not be saved.', detail: checked.detail || checked.error };
    let saved = atomic_write(SOURCE, raw, 0o600);
    if (!saved.ok) return { ok: false, valid: true, error: 'The Firewall file could not be saved.', detail: saved.error };
    return read_current();
}
function read_current() {
    let config = read_text(SOURCE), using_default = false;
    if (config == null) { config = read_text(DEFAULT_SOURCE); using_default = true; }
    if (config == null) return { ok: false, error: 'Unable to read the Firewall file.', path: SOURCE };
    config = normalize(config);
    let runtime = active();
    return {
        ok: true, path: SOURCE, config, bytes: length(config), using_default,
        active: runtime.active, active_found: runtime.active_found,
        recovering: false, warning: '', applied_config: read_text(APPLIED) || '', applied_path: APPLIED
    };
}
function remove_runtime() {
    let errors = [];
    let removed = remove_tables();
    if (!removed.ok) push(errors, removed.error);
    fs.unlink(APPLIED); fs.unlink(NEXT);
    let reset = rules('reset', []);
    if (!reset.ok) push(errors, reset.error || 'unable to reset runtime rules');
    return length(errors) ? { ok: false, error: join('; ', errors) } : { ok: true };
}
function file_input(path) {
    path = `${path ?? ''}`;
    if (!path) return { ok: false, error: 'input file path is empty' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: `cannot read ${path}` } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'read') return read_current();
    if (command == 'active') return active();
    if (command == 'remove-runtime') return remove_runtime();
    if (command == 'validate-file' || command == 'apply-file' || command == 'save-file') {
        let input = file_input(args[0]);
        if (!input.ok) return input;
        if (command == 'validate-file') return validate(input.raw);
        if (command == 'apply-file') return apply(input.raw);
        return save(input.raw);
    }
    return { ok: false, error: `unsupported firewall command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
