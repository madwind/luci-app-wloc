#!/usr/bin/env ucode

'use strict';

import { access, chmod, mkdtemp, mkdir, open, popen, rmdir, unlink } from 'fs';

const FIREWALL = '/etc/wloc/firewall.nft';
const FIREWALL_DEFAULT = '/usr/share/wloc/defaults/firewall.nft';
const FIREWALL_HELPER = '/usr/libexec/wloc/firewall.sh';
const RUNTIME_DIR = '/var/run/wloc';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 1024 * 1024;

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
    if (!fd)
        return { ok: false, output: '', error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let status = fd.close();
    let ok = status === 0 || status === true;
    return { ok: ok, output: output, error: ok ? null : (trim(output) || 'command failed') };
}

function run_helper(args) {
    let command = `/bin/sh ${shellquote(FIREWALL_HELPER)}`;
    for (let arg in args)
        command += ` ${shellquote(arg)}`;
    return run_command(command);
}

function create_payload(value, prefix) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES)
        return null;
    if (access(RUNTIME_DIR, 'f') !== true && mkdir(RUNTIME_DIR, RPC_DIRECTORY_MODE) !== true && access(RUNTIME_DIR, 'f') !== true)
        return null;
    let directory = mkdtemp(`${RUNTIME_DIR}/${prefix}-XXXXXX`);
    if (!directory)
        return null;
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

function firewall_read() {
    let source = FIREWALL;
    let config = read_file(source);
    let using_default = false;
    if (config == null) {
        source = FIREWALL_DEFAULT;
        config = read_file(source);
        using_default = true;
    }
    if (config == null)
        return { ok: false, error: 'Unable to read the Firewall file.' };

    let active_result = run_helper([ 'active' ]);
    let active = active_result.ok ? active_result.output : '';
    return {
        ok: true,
        path: FIREWALL,
        config: config,
        using_default: using_default,
        active: active || '# No WLOC nftables tables are active.',
        active_found: !!active,
        recovering: false,
        warning: ''
    };
}

function firewall_validate(value) {
    let payload = create_payload(value, 'rpc-firewall-validate');
    if (!payload)
        return { ok: false, valid: false, error: 'nftables syntax check failed', detail: 'unable to stage Firewall rules' };
    let result = run_helper([ 'validate', payload.path ]);
    remove_payload(payload);
    if (!result.ok)
        return { ok: false, valid: false, error: 'nftables syntax check failed', detail: result.error || 'validation failed' };
    return { ok: true, valid: true };
}

function firewall_apply(value) {
    let payload = create_payload(value, 'rpc-firewall-apply');
    if (!payload)
        return { ok: false, error: 'Unable to stage Firewall rules.' };
    let result = run_helper([ 'apply', payload.path ]);
    remove_payload(payload);
    if (!result.ok)
        return { ok: false, error: 'The nftables transaction failed.', detail: result.error || 'apply failed' };
    return firewall_read();
}

function firewall_save(value) {
    let valid = firewall_validate(value);
    if (!valid.ok)
        return { ok: false, error: 'The Firewall file could not be saved.', detail: valid.detail || 'validation failed' };

    let payload = create_payload(value, 'rpc-firewall-save');
    if (!payload)
        return { ok: false, error: 'The Firewall file could not be saved.', detail: 'unable to create temporary file' };

    let result = run_command(`mkdir -p /etc/wloc && chmod 0700 /etc/wloc && mv -f ${shellquote(payload.path)} ${shellquote(FIREWALL)} && chmod 0600 ${shellquote(FIREWALL)}`);
    payload.path = null;
    remove_payload(payload);
    if (!result.ok)
        return { ok: false, error: 'The Firewall file could not be saved.', detail: result.error || 'atomic file replacement failed' };
    return firewall_read();
}

function request_args(request) {
    return request && request.args ? request.args : {};
}

const methods = {
    read: { args: {}, call: function() { return firewall_read(); } },
    validate: { args: { config: '' }, call: function(request) { return firewall_validate(request_args(request).config || ''); } },
    apply: { args: { config: '' }, call: function(request) { return firewall_apply(request_args(request).config || ''); } },
    save: { args: { config: '' }, call: function(request) { return firewall_save(request_args(request).config || ''); } }
};

return { 'luci.wloc.firewall': methods };
