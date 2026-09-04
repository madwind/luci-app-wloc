#!/usr/bin/env ucode

'use strict';

import { popen } from 'fs';

const UPDATER = '/usr/libexec/wloc/update.sh';
const AUTO = '/usr/libexec/wloc/update-auto.sh';

function shellquote(value) {
    return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'";
}

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(lines[i] || '');
        if (!line) continue;
        try { return json(line); } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}

function run_json(path, args) {
    let command = `/bin/sh ${shellquote(path)}`;
    for (let arg in args)
        command += ` ${shellquote(arg)}`;

    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd)
        return { ok: false, error: 'unable to execute update controller' };

    let output = fd.read('all') || '';
    let status = fd.close();
    let result = parse_result(output);
    let success = status === 0 || status === true;

    if (!success && result.ok === true) {
        result.ok = false;
        result.error = trim(output || '') || 'update controller exited with an error';
    }
    return result;
}

function request_args(request) {
    return request && request.args ? request.args : {};
}

const methods = {
    status: { args: {}, call: function() { return run_json(UPDATER, [ 'status' ]); } },
    check: { args: {}, call: function() { return run_json(UPDATER, [ 'check' ]); } },
    install: { args: {}, call: function() { return run_json(UPDATER, [ 'install' ]); } },
    stop: { args: {}, call: function() { return run_json(UPDATER, [ 'stop' ]); } },
    settings: { args: {}, call: function() { return run_json(AUTO, [ 'status' ]); } },
    set_check: {
        args: { enabled: 0 },
        call: function(request) {
            let args = request_args(request);
            return run_json(AUTO, [ 'set-check', args.enabled ? 1 : 0 ]);
        }
    },
    set_auto: {
        args: { enabled: 0 },
        call: function(request) {
            let args = request_args(request);
            return run_json(AUTO, [ 'set-auto', args.enabled ? 1 : 0 ]);
        }
    }
};

return { 'luci.wloc.update': methods };
