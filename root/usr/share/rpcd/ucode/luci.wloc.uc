#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Non-blocking rpcd bridge for WLOC operations.

'use strict';

import { access, chmod, mkdtemp, mkdir, open, rmdir, unlink } from 'fs';
import { cursor } from 'uci';

let ubus = require('ubus').connect();

const RPC_CONTROLLER = '/usr/libexec/wloc/rpc.uc';
const FIREWALL_CONTROLLER = '/usr/libexec/wloc/firewall.uc';
const ROUTING_CONTROLLER = '/usr/libexec/wloc/routing.uc';
const UPDATE_CONTROLLER = '/usr/libexec/wloc/update.uc';
const INIT = '/etc/init.d/wloc';
const RUNTIME = '/var/run/wloc';
const FIREWALL_SOURCE = '/etc/wloc/firewall.nft';
const FIREWALL_APPLIED = `${RUNTIME}/firewall.applied.nft`;
const STATUS = `${RUNTIME}/status.json`;
const START_ERROR = `${RUNTIME}/start-error`;
const STARTUP_GRACE_SECONDS = 20;
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

function request_args(request) {
    return request && request.args ? request.args : {};
}

function defer_ucode(request, controller, parameters, label, cleanup) {
    if (!ubus) {
        if (cleanup) cleanup();
        return { ok: false, error: 'unable to connect to ubus' };
    }

    let params = [ controller ];
    for (let parameter in parameters) push(params, `${parameter}`);

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

function read_text(path) {
    let file = open(path, 'r');
    if (!file) return null;
    let value = file.read('all') || '';
    file.close();
    return value;
}

function read_json(path) {
    let raw = read_text(path);
    if (raw == null || !trim(raw)) return null;
    try {
        let value = json(raw);
        return type(value) == 'object' ? value : null;
    } catch (e) {
        return null;
    }
}

function service_enabled() {
    let uci = cursor();
    let value = null;
    try { value = uci.get('wloc', 'main', 'enabled'); } catch (e) {}
    return value === true || value === 1 || value === '1';
}

function service_running() {
    if (!ubus) return false;
    try {
        let result = ubus.call('service', 'list', { name: 'wloc' });
        let service = result && result.wloc;
        let instance = service && service.instances && service.instances.daemon;
        return type(instance) == 'object' && (instance.running === true || instance.running === 1);
    } catch (e) {
        return false;
    }
}

function firewall_ready() {
    let status = read_json(STATUS) || {};
    let running = service_running();
    if (!running) {
        let error = trim(read_text(START_ERROR) || '');
        if (error)
            return { ok: false, running: false, ready: false, busy: false, state: 'failed', error };
    }
    let armed = status.armed === true || status.armed === 1 || status.armed == '1' || status.armed == 'true';
    let started = int(status.session_started_at || 0);
    let now = time();
    let age = started > 0 && now >= started ? now - started : 0;
    let starting = running && !armed && started > 0 && age < STARTUP_GRACE_SECONDS;
    let state = !running ? 'stopped' : armed ? 'ready' : starting ? 'starting' : 'unready';
    return { ok: true, running, ready: running && armed, busy: starting, state };
}

function firewall_read() {
    let config = read_text(FIREWALL_SOURCE);
    if (config == null)
        return { ok: false, error: 'Unable to read the Firewall file.', path: FIREWALL_SOURCE };

    let applied = read_text(FIREWALL_APPLIED);
    return {
        ok: true,
        path: FIREWALL_SOURCE,
        config,
        bytes: length(config),
        applied_config: applied || '',
        applied_path: FIREWALL_APPLIED
    };
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
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

function defer_payload(request, controller, command, value, prefix, label, too_large_error) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES)
        return { ok: false, error: too_large_error };

    let payload = create_payload(content, prefix);
    if (!payload)
        return { ok: false, error: 'unable to create secure RPC temporary file' };

    return defer_ucode(request, controller, [ `${command}-file`, payload.path ], label, function() {
        remove_payload(payload);
    });
}

function firewall_apply(request) {
    let current = firewall_ready();
    if (current.ready !== true)
        return {
            ok: false,
            error: current.busy
                ? 'WLOC is changing state. Apply the Firewall after the service is ready.'
                : 'WLOC must be running and ready before Firewall rules can be applied.',
            state: current.state
        };

    return defer_payload(
        request,
        FIREWALL_CONTROLLER,
        'apply',
        request_args(request).config || '',
        'rpc-firewall-apply',
        'Firewall apply',
        'Firewall file is larger than 32 KiB.'
    );
}

function sync_boot() {
    let enabled = service_enabled();
    let action = enabled ? 'enable' : 'disable';
    if (system(`${INIT} ${action} >/dev/null 2>&1`) !== 0)
        return { ok: false, enabled, error: `Unable to ${action} WLOC at boot.` };
    return { ok: true, enabled };
}

function defer_service_action(request, action) {
    if (action !== 'start' && action !== 'stop' && action !== 'restart')
        return { ok: false, error: 'Unsupported WLOC service action.' };

    if ((action === 'start' || action === 'restart') && !service_enabled())
        return { ok: false, error: 'Enable service in Settings before starting WLOC.' };

    if (action === 'restart' && !service_running())
        return { ok: false, error: 'WLOC is stopped. Use Start to start the service.' };

    if (!ubus) return { ok: false, error: 'unable to connect to ubus' };

    try {
        return ubus.defer('file', 'exec', {
            command: INIT,
            params: [ action ]
        }, function(code, reply) {
            let result;
            if (code !== UBUS_STATUS_OK) {
                result = { ok: false, error: `Unable to ${action} the WLOC service: ubus status ${code}.` };
            } else if (type(reply) != 'object') {
                result = { ok: false, error: `Unable to ${action} the WLOC service: no execution result.` };
            } else if (int(reply.code || 0) !== 0) {
                let detail = trim(`${reply.stderr || reply.stdout || ''}`);
                result = { ok: false, error: detail || `Unable to ${action} the WLOC service.` };
            } else {
                result = {
                    ok: true,
                    state: action === 'start' ? 'starting' : action === 'stop' ? 'stopping' : 'restarting'
                };
            }
            request.reply(result, UBUS_STATUS_OK);
        });
    } catch (e) {
        return { ok: false, error: `Unable to ${action} the WLOC service: ${e}` };
    }
}

const methods = {
    status: {
        args: {},
        call: request => defer_ucode(request, RPC_CONTROLLER, [ 'status' ], 'WLOC status')
    },
    configured_access_points: {
        args: {},
        call: request => defer_ucode(request, RPC_CONTROLLER, [ 'configured-access-points' ], 'WLOC access point status')
    },
    regenerate_ca: {
        args: {},
        call: request => defer_ucode(request, RPC_CONTROLLER, [ 'regenerate-ca' ], 'WLOC CA regeneration')
    }
};

const firewall_methods = {
    read: {
        args: {},
        call: () => firewall_read()
    },
    ready: {
        args: {},
        call: () => firewall_ready()
    },
    runtime: {
        args: {},
        call: request => defer_ucode(request, FIREWALL_CONTROLLER, [ 'active' ], 'Firewall runtime read')
    },
    validate: {
        args: { config: '' },
        call: request => defer_payload(
            request,
            FIREWALL_CONTROLLER,
            'validate',
            request_args(request).config || '',
            'rpc-firewall-validate',
            'Firewall validate',
            'Firewall file is larger than 32 KiB.'
        )
    },
    apply: {
        args: { config: '' },
        call: request => firewall_apply(request)
    },
    save: {
        args: { config: '' },
        call: request => defer_payload(
            request,
            FIREWALL_CONTROLLER,
            'save',
            request_args(request).config || '',
            'rpc-firewall-save',
            'Firewall save',
            'Firewall file is larger than 32 KiB.'
        )
    }
};

const routing_methods = {
    read: {
        args: {},
        call: request => defer_ucode(request, ROUTING_CONTROLLER, [ 'read' ], 'Routing read')
    },
    runtime: {
        args: {},
        call: request => defer_ucode(request, ROUTING_CONTROLLER, [ 'active' ], 'Routing runtime read')
    },
    validate: {
        args: { config: '' },
        call: request => defer_payload(
            request,
            ROUTING_CONTROLLER,
            'validate',
            request_args(request).config || '',
            'rpc-routing',
            'Routing validate',
            'routing file is larger than 32 KiB'
        )
    },
    save: {
        args: { config: '' },
        call: request => defer_payload(
            request,
            ROUTING_CONTROLLER,
            'save',
            request_args(request).config || '',
            'rpc-routing',
            'Routing save',
            'routing file is larger than 32 KiB'
        )
    },
    apply: {
        args: { config: '' },
        call: request => defer_payload(
            request,
            ROUTING_CONTROLLER,
            'apply',
            request_args(request).config || '',
            'rpc-routing',
            'Routing apply',
            'routing file is larger than 32 KiB'
        )
    }
};

const service_methods = {
    sync: { args: {}, call: () => sync_boot() },
    start: { args: {}, call: request => defer_service_action(request, 'start') },
    stop: { args: {}, call: request => defer_service_action(request, 'stop') },
    restart: { args: {}, call: request => defer_service_action(request, 'restart') }
};

const update_methods = {
    status: {
        args: {},
        call: request => defer_ucode(request, UPDATE_CONTROLLER, [ 'status' ], 'Update status')
    },
    check: {
        args: {},
        call: request => defer_ucode(request, UPDATE_CONTROLLER, [ 'check' ], 'Update check')
    },
    install: {
        args: {},
        call: request => defer_ucode(request, UPDATE_CONTROLLER, [ 'install' ], 'Update start')
    },
    stop: {
        args: {},
        call: request => defer_ucode(request, UPDATE_CONTROLLER, [ 'stop' ], 'Update stop')
    },
    settings: {
        args: {},
        call: request => defer_ucode(request, UPDATE_CONTROLLER, [ 'auto-status' ], 'Update settings')
    },
    set_check: {
        args: { enabled: 0 },
        call: request => defer_ucode(
            request,
            UPDATE_CONTROLLER,
            [ 'auto-set-check', request_args(request).enabled ? 1 : 0 ],
            'Automatic update check setting'
        )
    },
    set_auto: {
        args: { enabled: 0 },
        call: request => defer_ucode(
            request,
            UPDATE_CONTROLLER,
            [ 'auto-set', request_args(request).enabled ? 1 : 0 ],
            'Automatic update setting'
        )
    }
};

return {
    'luci.wloc': methods,
    'luci.wloc.firewall': firewall_methods,
    'luci.wloc.routing': routing_methods,
    'luci.wloc.service': service_methods,
    'luci.wloc.update': update_methods
};
