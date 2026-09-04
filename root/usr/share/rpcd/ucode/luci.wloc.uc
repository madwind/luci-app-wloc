#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Non-blocking rpcd bridge for WLOC composite operations.

'use strict';

let ubus = require('ubus').connect();

const CONTROLLER = '/usr/libexec/wloc/rpc.uc';

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

function defer_controller(request, command, label) {
    if (!ubus) return { ok: false, error: 'unable to connect to ubus' };

    try {
        return ubus.defer('file', 'exec', {
            command: '/usr/bin/ucode',
            params: [ CONTROLLER, command ]
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

const methods = {
    status: {
        args: {},
        call: request => defer_controller(request, 'status', 'WLOC status')
    },
    configured_access_points: {
        args: {},
        call: request => defer_controller(request, 'configured-access-points', 'WLOC access point status')
    },
    regenerate_ca: {
        args: {},
        call: request => defer_controller(request, 'regenerate-ca', 'WLOC CA regeneration')
    }
};

return { 'luci.wloc': methods };
