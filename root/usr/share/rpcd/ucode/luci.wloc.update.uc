#!/usr/bin/env ucode

'use strict';

import { popen } from 'fs';

const CONTROLLER = '/usr/libexec/wloc/update.uc';

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
function run(args) {
    let command = `/usr/bin/ucode ${q(CONTROLLER)}`;
    for (let arg in args) command += ` ${q(arg)}`;
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, error: 'unable to execute update controller' };
    let output = fd.read('all') || '';
    let rc = fd.close();
    let result = parse_result(output);
    if (rc !== 0 && result.ok === true) return { ok: false, error: trim(output || '') || 'update controller exited with an error' };
    return result;
}
function args(request) { return request && request.args ? request.args : {}; }

const methods = {
    status: { args: {}, call: function() { return run([ 'status' ]); } },
    check: { args: {}, call: function() { return run([ 'check' ]); } },
    install: { args: {}, call: function() { return run([ 'install' ]); } },
    stop: { args: {}, call: function() { return run([ 'stop' ]); } },
    settings: { args: {}, call: function() { return run([ 'auto-status' ]); } },
    set_check: {
        args: { enabled: 0 },
        call: function(request) { return run([ 'auto-set-check', args(request).enabled ? 1 : 0 ]); }
    },
    set_auto: {
        args: { enabled: 0 },
        call: function(request) { return run([ 'auto-set', args(request).enabled ? 1 : 0 ]); }
    }
};

return { 'luci.wloc.update': methods };
