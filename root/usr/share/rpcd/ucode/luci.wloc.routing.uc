#!/usr/bin/env ucode

'use strict';

import { access, chmod, mkdtemp, mkdir, open, popen, rmdir, unlink } from 'fs';

const RUNTIME = '/var/run/wloc';
const SOURCE = '/etc/wloc/routing.conf';
const DEFAULT_SOURCE = '/usr/share/wloc/defaults/routing.conf';
const APPLIED = '/var/run/wloc/routing.applied.conf';
const HELPER = '/usr/libexec/wloc/routing.sh';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 32 * 1024;

function trim_value(value) {
    return trim(`${value == null ? '' : value}`);
}

function shellquote(value) {
    return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'";
}

function read_file(path) {
    let file = open(path, 'r');
    if (!file) return null;
    let value = file.read('all') || '';
    file.close();
    return value;
}

function run_command(command) {
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, output: '', error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let success = fd.close();
    let ok = success === true || success === 0;
    return {
        ok: ok,
        output: output,
        error: ok ? null : (trim_value(output) || 'command failed')
    };
}

function run_helper(args) {
    let command = `/bin/sh ${shellquote(HELPER)}`;
    for (let arg in args) command += ` ${shellquote(arg)}`;
    return run_command(command);
}

function create_payload(value) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES) return null;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true)
        return null;
    let directory = mkdtemp(`${RUNTIME}/rpc-routing-XXXXXX`);
    if (!directory) return null;
    let path = `${directory}/payload`;
    let file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) {
        rmdir(directory);
        return null;
    }
    let written = file.write(content);
    let closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path);
        rmdir(directory);
        return null;
    }
    return { directory: directory, path: path };
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}

function normalize_helper_config(output) {
    let value = replace(`${output == null ? '' : output}`, /\r\n?/g, '\n');
    value = trim(value);
    return value ? `${value}\n` : '';
}

function run_payload(command, value) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES)
        return { ok: false, error: 'routing file is larger than 32 KiB' };
    let payload = create_payload(content);
    if (!payload) return { ok: false, error: 'unable to create secure RPC temporary file' };
    let result;
    try {
        result = run_helper([ command, payload.path ]);
    } catch (e) {
        result = { ok: false, output: '', error: `${e}` };
    }
    remove_payload(payload);
    return result;
}

function routing_read() {
    let config = read_file(SOURCE);
    let using_default = false;
    if (config == null) {
        config = read_file(DEFAULT_SOURCE);
        using_default = true;
    }
    if (config == null) return { ok: false, error: `cannot read ${SOURCE} or ${DEFAULT_SOURCE}`, path: SOURCE };

    let active = run_helper([ 'active' ]);
    if (!active.ok && using_default && read_file(APPLIED) == null)
        active = { ok: true, output: '# No active policy routing commands are installed.\n' };
    if (!active.ok) return { ok: false, error: active.error || 'unable to inspect policy routing', path: SOURCE };
    let ready = run_helper([ 'ready' ]);
    let applied = read_file(APPLIED) || '';

    return {
        ok: true,
        path: SOURCE,
        config: config,
        bytes: length(config),
        using_default: using_default,
        active: active.output || '# No active policy routing commands are installed.\n',
        route_active: ready.ok === true,
        applied_config: applied,
        applied_path: APPLIED
    };
}

function routing_validate(value) {
    let result = run_payload('validate', value);
    if (!result.ok) return { ok: false, valid: false, error: result.error || 'routing validation failed' };
    let config = normalize_helper_config(result.output);
    return { ok: true, valid: true, config: config, bytes: length(config) };
}

function routing_save(value) {
    let result = run_payload('save', value);
    if (!result.ok) return { ok: false, error: result.error || 'unable to save routing configuration' };
    let config = read_file(SOURCE);
    if (config == null) return { ok: false, error: `cannot read ${SOURCE}`, path: SOURCE };
    return { ok: true, valid: true, path: SOURCE, config: config, bytes: length(config) };
}

function routing_apply(value) {
    let result = run_payload('apply', value);
    if (!result.ok) return { ok: false, error: result.error || 'unable to apply routing configuration' };
    return routing_read();
}

const methods = {
    read: { args: {}, call: () => routing_read() },
    validate: {
        args: { config: '' },
        call: request => routing_validate(request && request.args ? request.args.config || '' : '')
    },
    save: {
        args: { config: '' },
        call: request => routing_save(request && request.args ? request.args.config || '' : '')
    },
    apply: {
        args: { config: '' },
        call: request => routing_apply(request && request.args ? request.args.config || '' : '')
    }
};

return { 'luci.wloc.routing': methods };
