#!/usr/bin/env ucode

'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';

function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function truthy(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes'; }
function find_iface(iface) {
    iface = `${iface ?? ''}`;
    if (!valid_iface(iface)) return { ok: false, error: 'invalid interface name' };
    let ctx = cursor(), matches = [];
    try {
        ctx.foreach('wireless', 'wifi-iface', function(section) {
            let mode = `${section.mode || 'ap'}`;
            if (mode != 'ap' && mode != 'ap-wds') return;
            if (`${section.ifname || ''}` != iface) return;
            push(matches, {
                section: `${section['.name'] || ''}`,
                iface,
                ssid: `${section.ssid || ''}`,
                device: `${section.device || ''}`,
                disabled: truthy(section.disabled)
            });
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (!length(matches)) return { ok: false, error: `interface "${iface}" was not found in wireless configuration` };
    if (length(matches) > 1) return { ok: false, error: `interface "${iface}" matches multiple wireless sections` };
    let result = matches[0];
    result.ok = true;
    return result;
}
function hostapd_status(iface) {
    let found = find_iface(iface);
    if (!found.ok) return found;
    try {
        let ubus = connect();
        if (!ubus) return { ok: false, error: 'unable to connect to ubus' };
        let status = ubus.call(`hostapd.${found.iface}`, 'get_status', {});
        return { ok: type(status) == 'object', status: status || {}, section: found.section, iface: found.iface };
    } catch (e) { return { ok: false, error: `${e}`, section: found.section, iface: found.iface }; }
}
function dispatch(command, args) {
    if (command == 'find') return find_iface(args[0]);
    if (command == 'status') return hostapd_status(args[0]);
    return { ok: false, error: `unsupported AP command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
