#!/usr/bin/env ucode

'use strict';

import { access, chmod, mkdtemp, mkdir, open, popen, rmdir, unlink } from 'fs';

const HELPER = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 1024 * 1024;

function q(value) { return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'"; }
function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(lines[i] || '');
        if (!line) continue;
        try {
            let value = json(line);
            if (type(value) == 'object') return value;
        } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}
function run_helper(args) {
    let command = `/usr/bin/ucode ${q(HELPER)}`;
    for (let arg in args) command += ` ${q(arg)}`;
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, error: 'unable to execute Firewall controller' };
    let output = fd.read('all') || '';
    let rc = fd.close();
    let result = parse_result(output);
    if (rc !== 0 && result.ok === true) return { ok: false, error: trim(output || '') || 'Firewall controller exited with an error' };
    return result;
}
function create_payload(value, prefix) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES) return null;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true) return null;
    let directory = mkdtemp(`${RUNTIME}/${prefix}-XXXXXX`);
    if (!directory) return null;
    let path = `${directory}/payload`;
    let file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) { rmdir(directory); return null; }
    let written = file.write(content), closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path); rmdir(directory); return null;
    }
    return { directory, path };
}
function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}
function run_payload(command, value) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES) return { ok: false, error: 'Firewall file is larger than 1 MiB.' };
    let payload = create_payload(content, `rpc-firewall-${command}`);
    if (!payload) return { ok: false, error: 'unable to create secure RPC temporary file' };
    let result;
    try { result = run_helper([ `${command}-file`, payload.path ]); }
    catch (e) { result = { ok: false, error: `${e}` }; }
    remove_payload(payload);
    return result;
}
function args(request) { return request && request.args ? request.args : {}; }

const methods = {
    read: { args: {}, call: function() { return run_helper([ 'read' ]); } },
    validate: { args: { config: '' }, call: function(request) { return run_payload('validate', args(request).config || ''); } },
    apply: { args: { config: '' }, call: function(request) { return run_payload('apply', args(request).config || ''); } },
    save: { args: { config: '' }, call: function(request) { return run_payload('save', args(request).config || ''); } }
};

return { 'luci.wloc.firewall': methods };
