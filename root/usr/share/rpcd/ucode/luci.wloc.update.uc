#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Non-blocking rpcd bridge for the WLOC update controller.

'use strict';

let ubus = require('ubus').connect();

const CONTROLLER = '/usr/libexec/wloc/update.uc';

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

function defer_update(request, args, label) {
    if (!ubus) return { ok: false, error: 'unable to connect to ubus' };

    let params = [ CONTROLLER ];
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
            request.reply(result, UBUS_STATUS_OK);
        });
    } catch (e) {
        return { ok: false, error: `${label}: ${e}` };
    }
}

function args(request) {
    return request && request.args ? request.args : {};
}

const methods = {
    status: {
        args: {},
        call: request => defer_update(request, [ 'status' ], 'Update status')
    },
    check: {
        args: {},
        call: request => defer_update(request, [ 'check' ], 'Update check')
    },
    install: {
        args: {},
        call: request => defer_update(request, [ 'install' ], 'Update start')
    },
    stop: {
        args: {},
        call: request => defer_update(request, [ 'stop' ], 'Update stop')
    },
    settings: {
        args: {},
        call: request => defer_update(request, [ 'auto-status' ], 'Update settings')
    },
    set_check: {
        args: { enabled: 0 },
        call: request => defer_update(request, [ 'auto-set-check', args(request).enabled ? 1 : 0 ], 'Automatic update check setting')
    },
    set_auto: {
        args: { enabled: 0 },
        call: request => defer_update(request, [ 'auto-set', args(request).enabled ? 1 : 0 ], 'Automatic update setting')
    }
};

return { 'luci.wloc.update': methods };
