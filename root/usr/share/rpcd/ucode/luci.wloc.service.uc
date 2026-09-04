#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Non-blocking rpcd bridge for WLOC service actions.

'use strict';

import { cursor } from 'uci';

let ubus = require('ubus').connect();

const INIT = '/etc/init.d/wloc';

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

function defer_action(request, action) {
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
    start: { args: {}, call: request => defer_action(request, 'start') },
    stop: { args: {}, call: request => defer_action(request, 'stop') },
    restart: { args: {}, call: request => defer_action(request, 'restart') }
};

return { 'luci.wloc.service': methods };
