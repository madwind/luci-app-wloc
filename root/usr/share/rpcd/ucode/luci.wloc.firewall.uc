#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Non-blocking rpcd bridge for the WLOC firewall controller.

'use strict';

import { access, chmod, mkdtemp, mkdir, open, rmdir, unlink } from 'fs';

let ubus = require('ubus').connect();

const HELPER = '/usr/libexec/wloc/firewall.uc';
const RUNTIME = '/var/run/wloc';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 32 * 1024;

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

function exec_result(code, reply, label) {
    if (code !== UBUS_STATUS_OK)
        return { ok: false, error: `${label} request failed with ubus status ${code}` };
    if (type(reply) != 'object')
        return { ok: false, error: `${label} returned no execution result` };

    let stdout = `${reply.stdout || ''}`;
    let stderr = trim(`${reply.stderr || ''}`);
    let exit_code = int(reply.code || 0);
    let result = parse_result(stdout);

    if (exit_code !== 0 && result.ok === true)
        return { ok: false, error: stderr || `${label} exited with status ${exit_code}` };
    if (result.ok === false && stderr && !result.detail)
        result.detail = stderr;
    return result;
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}

function defer_helper(request, args, label, cleanup) {
    if (!ubus) {
        if (cleanup) cleanup();
        return { ok: false, error: 'unable to connect to ubus' };
    }

    let params = [ HELPER ];
    for (let arg in args) push(params, `${arg}`);

    try {
        return ubus.defer('file', 'exec', {
            command: '/usr/bin/ucode',
            params
        }, function(code, reply) {
            let result;
            try {
                result = exec_result(code, reply, label);
            } catch (e) {
                result = { ok: false, error: `${label}: ${e}` };
            }
            if (cleanup) cleanup();
            request.reply(result, UBUS_STATUS_OK);
        });
    } catch (e) {
        if (cleanup) cleanup();
        return { ok: false, error: `${label}: ${e}` };
    }
}

function create_payload(value, prefix) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES) return null;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true) return null;

    let directory = mkdtemp(`${RUNTIME}/${prefix}-XXXXXX`);
    if (!directory) return null;

    let path = `${directory}/payload`;
    let file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) {
        rmdir(directory);
        return null;
    }

    let written = file.write(content), closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path);
        rmdir(directory);
        return null;
    }

    return { directory, path };
}

function defer_payload(request, command, value) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES)
        return { ok: false, error: 'Firewall file is larger than 32 KiB.' };

    let payload = create_payload(content, `rpc-firewall-${command}`);
    if (!payload)
        return { ok: false, error: 'unable to create secure RPC temporary file' };

    return defer_helper(request, [ `${command}-file`, payload.path ], `Firewall ${command}`, function() {
        remove_payload(payload);
    });
}

function args(request) {
    return request && request.args ? request.args : {};
}

const methods = {
    read: {
        args: {},
        call: request => defer_helper(request, [ 'read' ], 'Firewall read')
    },
    validate: {
        args: { config: '' },
        call: request => defer_payload(request, 'validate', args(request).config || '')
    },
    apply: {
        args: { config: '' },
        call: request => defer_payload(request, 'apply', args(request).config || '')
    },
    save: {
        args: { config: '' },
        call: request => defer_payload(request, 'save', args(request).config || '')
    }
};

return { 'luci.wloc.firewall': methods };
