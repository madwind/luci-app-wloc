#!/usr/bin/env ucode

'use strict';

import { cursor } from 'uci';

const INIT = '/etc/init.d/wloc';

function service_enabled() {
    let uci = cursor();
    let value = null;
    try { value = uci.get('wloc', 'main', 'enabled'); } catch (e) {}
    return value === true || value === 1 || value === '1';
}

function run_action(action) {
    if (action !== 'start' && action !== 'stop' && action !== 'restart')
        return { ok: false, error: 'Unsupported WLOC service action.' };

    if ((action === 'start' || action === 'restart') && !service_enabled())
        return { ok: false, error: 'Enable service in Settings before starting WLOC.' };

    let rc = system(`${INIT} ${action} >/dev/null 2>&1`);
    if (rc !== 0)
        return { ok: false, error: `Unable to ${action} the WLOC service.` };

    return {
        ok: true,
        state: action === 'start' ? 'starting' : action === 'stop' ? 'stopping' : 'restarting'
    };
}

const methods = {
    start: { args: {}, call: function() { return run_action('start'); } },
    stop: { args: {}, call: function() { return run_action('stop'); } },
    restart: { args: {}, call: function() { return run_action('restart'); } }
};

return { 'luci.wloc.service': methods };
