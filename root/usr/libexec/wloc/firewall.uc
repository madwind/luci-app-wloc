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
const FOLD_THRESHOLD = 10;
const OWNED_TABLE = 'wloc';
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
function is_space(c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'; }
function ident_start(c) { return c != null && match(c, /^[A-Za-z_]$/) != null; }
function ident_char(c) { return c != null && match(c, /^[A-Za-z0-9_.-]$/) != null; }
function skip_space(text, pos) { while (pos < length(text) && is_space(substr(text, pos, 1))) pos++; return pos; }
function read_ident(text, pos) {
    pos = skip_space(text, pos);
    if (pos >= length(text) || !ident_start(substr(text, pos, 1))) return null;
    let start = pos++;
    while (pos < length(text) && ident_char(substr(text, pos, 1))) pos++;
    return { value: substr(text, start, pos - start), start, end: pos };
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
function matching_brace(text, open_pos, limit) {
    let depth = 0, last = min(limit == null ? length(text) : limit, length(text));
    for (let pos = open_pos; pos < last; pos++) {
        let c = substr(text, pos, 1);
        if (c == '{') depth++;
        else if (c == '}') {
            depth--;
            if (depth == 0) return pos;
            if (depth < 0) return null;
        }
    }
    return null;
}
function parse_source(raw) {
    raw = `${raw ?? ''}`;
    let text = mask(raw), tables = [], pos = 0;
    while (true) {
        pos = skip_space(text, pos);
        if (pos >= length(text)) break;
        let table_kw = read_ident(text, pos);
        if (!table_kw || table_kw.value != 'table' || table_kw.start != pos)
            return { ok: false, error: 'unsupported top-level nft statement' };
        let family = read_ident(text, table_kw.end);
        let name = family ? read_ident(text, family.end) : null;
        if (!family || !name) return { ok: false, error: 'invalid nft table declaration' };
        let open_pos = skip_space(text, name.end);
        if (substr(text, open_pos, 1) != '{') return { ok: false, error: 'invalid nft table declaration' };
        let close_pos = matching_brace(text, open_pos);
        if (close_pos == null) return { ok: false, error: 'unbalanced nft table block' };
        push(tables, {
            family: family.value,
            name: name.value,
            key: `${family.value}|${name.value}`,
            start_position: table_kw.start,
            open_position: open_pos,
            close_position: close_pos
        });
        pos = close_pos + 1;
    }
    return { ok: true, raw, text, tables };
}
function inspect_source(raw) {
    let parsed = parse_source(raw);
    if (!parsed.ok) return parsed;
    if (match(parsed.text, /(^|\s)include(\s|$)/))
        return { ok: false, error: 'firewall file must not use include directives' };
    for (let table in parsed.tables)
        if (table.name != OWNED_TABLE)
            return { ok: false, error: `firewall file may only manage tables named ${OWNED_TABLE}` };
    return parsed;
}
function runtime_token_visible(raw, position) {
    let line = position, quote = null, escaped = false;
    while (line > 0 && substr(raw, line - 1, 1) != '\n') line--;
    for (let i = line; i < position; i++) {
        let c = substr(raw, i, 1);
        if (quote != null) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == quote) quote = null;
            continue;
        }
        if (c == '#') return false;
        if (c == '"' || c == "'") quote = c;
    }
    return quote == null;
}
function scan_runtime_elements(raw, open_position) {
    let depth = 1, count = 0, has_item = false;
    let quote = null, escaped = false, comment = false;
    for (let pos = open_position + 1; pos < length(raw); pos++) {
        let c = substr(raw, pos, 1);
        if (comment) {
            if (c == '\n') comment = false;
            continue;
        }
        if (quote != null) {
            if (depth == 1) has_item = true;
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == quote) quote = null;
            continue;
        }
        if (c == '#') { comment = true; continue; }
        if (c == '"' || c == "'") { quote = c; if (depth == 1) has_item = true; continue; }
        if (c == '{') { if (depth == 1) has_item = true; depth++; continue; }
        if (c == '}') {
            depth--;
            if (depth == 0) {
                if (has_item) count++;
                return { ok: true, close: pos, count };
            }
            if (depth < 0) return { ok: false };
            continue;
        }
        if (depth != 1) continue;
        if (c == ',') {
            if (has_item) count++;
            has_item = false;
            continue;
        }
        if (!is_space(c)) has_item = true;
    }
    return { ok: false };
}
function fold_runtime(raw) {
    raw = `${raw ?? ''}`;
    let replacements = [], search_position = 0;
    while (search_position < length(raw)) {
        let rel = index(substr(raw, search_position), 'elements');
        if (rel == null || rel < 0) break;
        let start = search_position + rel, finish = start + 8;
        search_position = finish;
        let before = start > 0 ? substr(raw, start - 1, 1) : '';
        let after = finish < length(raw) ? substr(raw, finish, 1) : '';
        if ((before && ident_char(before)) || (after && ident_char(after)) || !runtime_token_visible(raw, start)) continue;
        let open = skip_space(raw, finish);
        if (substr(raw, open, 1) != '=') continue;
        open = skip_space(raw, open + 1);
        if (substr(raw, open, 1) != '{') continue;
        let scanned = scan_runtime_elements(raw, open);
        if (!scanned.ok) return raw;
        if (scanned.count > FOLD_THRESHOLD) push(replacements, { open, close: scanned.close, count: scanned.count });
        search_position = scanned.close + 1;
    }
    for (let i = length(replacements) - 1; i >= 0; i--) {
        let replacement = replacements[i];
        raw = substr(raw, 0, replacement.open + 1) + ` # ${replacement.count} entries ` + substr(raw, replacement.close);
    }
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
function table_command(verb, spec) { return `${verb} table ${spec.family} ${spec.name}`; }
function table_active(spec) { return quiet(table_command('nft list', spec)); }
function managed_tables() {
    let result = capture('nft list tables');
    let tables = [], seen = {};
    if (!result.ok) return tables;
    for (let line in split(result.output || '', '\n')) {
        let found = match(trim(line), /^table\s+(\S+)\s+(\S+)$/);
        if (!found || found[2] != OWNED_TABLE) continue;
        let key = `${found[1]} ${found[2]}`;
        if (!seen[key]) { seen[key] = true; push(tables, { family: found[1], name: found[2], key }); }
    }
    return tables;
}
function active_firewall(tables, fold) {
    tables = tables || managed_tables();
    let output = [], missing = [], bridge = '', inet = '';
    for (let spec in tables) {
        let listed = capture(table_command('nft list', spec));
        if (!listed.ok || !trim(listed.output || '')) {
            push(missing, spec.key);
            continue;
        }
        let text = fold ? fold_runtime(trim(listed.output)) : trim(listed.output);
        push(output, text);
        if (spec.family == 'bridge') bridge = text;
        else if (spec.family == 'inet') inet = text;
    }
    let active = length(output) ? join('\n\n', output) + '\n' : '# No WLOC nftables tables are active.\n';
    return {
        ok: true,
        active,
        active_found: length(tables) > 0 && !length(missing),
        missing_tables: missing,
        table_count: length(tables),
        active_table_count: length(output),
        bridge_active: bridge,
        inet_active: inet
    };
}
function active() { return active_firewall(managed_tables(), true); }
function transaction(current_tables, desired, desired_tables) {
    let lines = [], targets = {};
    function add_deletes(tables) {
        for (let spec in (tables || [])) {
            let key = `${spec.family} ${spec.name}`;
            if (spec.name == OWNED_TABLE && !targets[key]) {
                targets[key] = true;
                if (table_active(spec)) push(lines, table_command('delete', spec));
            }
        }
    }
    add_deletes(current_tables);
    add_deletes(desired_tables);
    if (trim(desired || '')) push(lines, desired);
    return join('\n', lines);
}
function run_transaction(content) {
    if (!trim(content || '')) return { ok: true, detail: '' };
    let path = temporary(`${RUNTIME}/firewall-apply`);
    let saved = atomic_write(path, content, 0o600);
    if (!saved.ok) return { ok: false, detail: saved.error };
    let checked = capture(`nft --check --file ${q(path)}`);
    if (!checked.ok) { fs.unlink(path); return { ok: false, detail: trim(checked.output || '') }; }
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    return applied.ok ? { ok: true, detail: '' } : { ok: false, detail: trim(applied.output || '') };
}
function listen_port() {
    try {
        let ctx = cursor();
        return `${ctx.get('wloc', 'main', 'listen_port') || '61520'}`;
    } catch (e) { return '61520'; }
}
function compile_runtime(raw) {
    raw = normalize(raw);
    let port_text = listen_port();
    if (!match(port_text, /^[0-9]+$/)) return { ok: false, error: 'WLOC listen port is invalid.' };
    let port = int(port_text);
    if (port < 1 || port > 65535) return { ok: false, error: 'WLOC listen port must be between 1 and 65535.' };
    return { ok: true, source: raw, compiled: replace(raw, /%port%/g, `${port}`) };
}
function prepare(raw) {
    let runtime = compile_runtime(raw);
    if (!runtime.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: runtime.error };
    if (length(runtime.source) > MAX_BYTES) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'Firewall file is larger than 1 MiB.' };
    let parsed = inspect_source(runtime.source);
    if (!parsed.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: parsed.error };
    if (!mkdirp(RUNTIME)) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'Unable to create WLOC runtime directory.' };
    let check = temporary(`${RUNTIME}/firewall-check`);
    let written = atomic_write(check, runtime.compiled, 0o600);
    if (!written.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: written.error };
    let result = capture(`nft --check --file ${q(check)}`);
    fs.unlink(check);
    if (!result.ok) return { ok: false, valid: false, error_code: 'nft_check_failed', error: 'nftables syntax check failed', detail: trim(result.output || '') || 'validation failed' };
    return { ok: true, valid: true, config: runtime.source, compiled: runtime.compiled, bytes: length(runtime.source), tables: parsed.tables };
}
function validate(raw) {
    let checked = prepare(raw);
    if (type(checked) == 'object') delete checked.compiled;
    return checked;
}
function remove_tables() {
    let tables = managed_tables();
    let removed = run_transaction(transaction(tables, '', []));
    if (!removed.ok) return { ok: false, error: removed.detail || 'failed to remove WLOC nftables tables' };
    return length(managed_tables())
        ? { ok: false, error: 'some WLOC nftables tables are still active' }
        : { ok: true };
}
function rules(command, args) {
    let argv = [ command ];
    for (let arg in (args || [])) push(argv, arg);
    return run_ucode(RULES, argv);
}
function fail_open(error_code, error, detail) {
    let errors = [];
    if (detail) push(errors, detail);
    let removed = remove_tables();
    if (!removed.ok) push(errors, `firewall cleanup failed: ${removed.error}`);
    fs.unlink(APPLIED); fs.unlink(NEXT);
    let cleaned = rules('cleanup', []);
    if (!cleaned.ok) push(errors, `runtime cleanup failed: ${cleaned.error || 'unable to clear runtime state'}`);
    return {
        ok: false,
        valid: false,
        error_code,
        error,
        detail: join('; ', errors)
    };
}
function daemon_ready() {
    let st = fs.stat(STATUS);
    return quiet('pidof wlocd') && type(st) == 'object' && int(st.size || 0) > 0;
}
function apply(raw) {
    let checked = prepare(raw);
    if (!checked.ok) return checked;
    if (!mkdirp(RUNTIME)) return { ok: false, error_code: 'nft_apply_failed', error: 'Unable to create WLOC runtime directory.' };
    fs.unlink(NEXT);
    let staged = atomic_write(NEXT, checked.config, 0o600);
    if (!staged.ok) return { ok: false, error_code: 'snapshot_stage_failed', error: staged.error };

    let current_tables = managed_tables();
    let loaded = run_transaction(transaction(current_tables, checked.compiled, checked.tables));
    if (!loaded.ok)
        return fail_open('nft_apply_failed', 'The nftables transaction failed.', loaded.detail || 'apply failed');

    let runtime_tables = managed_tables();
    let verified = length(runtime_tables) == length(checked.tables);
    if (verified) {
        for (let spec in checked.tables) {
            if (!table_active(spec)) {
                return fail_open('nft_apply_failed', 'The nftables transaction failed verification.', `missing runtime table ${spec.family} ${spec.name}`);
            }
        }
    } else {
        return fail_open('nft_apply_failed', 'The nftables transaction failed verification.', 'runtime table count does not match the configured tables');
    }

    if (fs.rename(NEXT, APPLIED) !== true || read_text(APPLIED) == null)
        return fail_open('snapshot_promote_failed', 'The applied firewall snapshot could not be promoted.', 'nftables transaction succeeded but the applied snapshot could not be promoted');
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

    return {
        ok: true, valid: true, applied: true, path: SOURCE, config: checked.config, bytes: length(checked.config),
        recovering, warning, applied_config: checked.config, applied_path: APPLIED
    };
}
function save(raw) {
    let checked = prepare(raw);
    if (!checked.ok) return { ok: false, valid: false, error: 'The Firewall file could not be saved.', detail: checked.detail || checked.error };
    let saved = atomic_write(SOURCE, checked.config, 0o600);
    if (!saved.ok) return { ok: false, valid: true, error: 'The Firewall file could not be saved.', detail: saved.error };
    return read_current();
}
function read_current() {
    let config = read_text(SOURCE), using_default = false;
    if (config == null) { config = read_text(DEFAULT_SOURCE); using_default = true; }
    if (config == null) return { ok: false, error: 'Unable to read the Firewall file.', path: SOURCE };
    config = normalize(config);
    return {
        ok: true, path: SOURCE, config, bytes: length(config), using_default,
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
