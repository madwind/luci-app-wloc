#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';

const CONTROLLERS = {
    firewall: '/usr/libexec/wloc/firewall.uc',
    routing: '/usr/libexec/wloc/routing.uc'
};

const COMMANDS = {
    firewall: { active: true, 'validate-file': true, 'apply-file': true, 'save-file': true },
    routing: { read: true, active: true, 'validate-file': true, 'apply-file': true, 'save-file': true }
};

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }

function fail(error) {
    printf('%J\n', { ok: false, error });
    exit(1);
}

function valid_payload(controller, command, path) {
    path = `${path ?? ''}`;
    if (controller == 'firewall') {
        if (command == 'validate-file') return match(path, /^\/var\/run\/wloc\/rpc-firewall-validate-[A-Za-z0-9]+\/payload$/) != null;
        if (command == 'apply-file') return match(path, /^\/var\/run\/wloc\/rpc-firewall-apply-[A-Za-z0-9]+\/payload$/) != null;
        if (command == 'save-file') return match(path, /^\/var\/run\/wloc\/rpc-firewall-save-[A-Za-z0-9]+\/payload$/) != null;
        return false;
    }
    if (controller == 'routing')
        return match(path, /^\/var\/run\/wloc\/rpc-routing-[A-Za-z0-9]+\/payload$/) != null;
    return false;
}

let controller = `${ARGV[0] ?? ''}`;
let command = `${ARGV[1] ?? ''}`;
let helper = CONTROLLERS[controller];
if (!helper || !COMMANDS[controller] || COMMANDS[controller][command] !== true)
    fail('unsupported internal RPC controller command');

let args = slice(ARGV, 2);
if (match(command, /-file$/)) {
    if (length(args) != 1 || !valid_payload(controller, command, args[0]))
        fail('invalid internal RPC input path');
}

let shell = `/usr/bin/ucode ${q(helper)} ${q(command)}`;
for (let arg in args) shell += ` ${q(arg)}`;
let proc = fs.popen(`${shell} 2>&1`, 'r');
if (!proc) fail('unable to execute controller');
let output = proc.read('all') || '';
let rc = proc.close();
printf('%s', output);
exit(rc === 0 ? 0 : 1);
