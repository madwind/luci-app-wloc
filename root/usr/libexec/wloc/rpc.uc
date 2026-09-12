#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Composite WLOC RPC operations. rpcd invokes this controller asynchronously.

'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import { open, popen, unlink } from 'fs';

const INIT = '/etc/init.d/wloc';
const RULES = '/usr/libexec/wloc/rules.uc';
const STATE = '/var/run/wloc/status.json';
const CAINFO = '/etc/wloc/ca.info.json';
const CA_KEY = '/etc/wloc/ca.key';
const CA_DER = '/etc/wloc/ca.der';
const CA_PEM = '/etc/wloc/ca.pem';
const CA_PROFILE = '/www/wloc-ca.mobileconfig';
const FIREWALL_RUNTIME = '/var/run/wloc/firewall.applied.nft';

function q(value) {
    return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'";
}

function read_file(path) {
    let file = open(path, 'r');
    if (!file) return null;
    let value = file.read('all') || '';
    file.close();
    return value;
}

function read_json(path) {
    let raw = read_file(path);
    if (raw == null || !trim(raw)) return null;
    try { return json(raw); } catch (e) { return null; }
}

function run_command(command) {
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, output: '', error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let rc = fd.close();
    let ok = rc === true || rc === 0;
    return { ok, output, error: ok ? null : (trim(output) || 'command failed') };
}

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

function run_ucode(path, args) {
    let command = `/usr/bin/ucode ${q(path)}`;
    for (let arg in args) command += ` ${q(arg)}`;
    let result = run_command(command);
    let parsed = parse_result(result.output || '');
    if (!result.ok && parsed.ok === true)
        return { ok: false, error: result.error || 'controller failed' };
    return parsed;
}

function truthy(value) {
    return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes';
}

function integer(value, fallback) {
    let number = +value;
    return number >= 0 ? number : fallback;
}

function daemon_running() {
    try {
        let ubus = connect();
        if (!ubus) return false;
        let result = ubus.call('service', 'list', { name: 'wloc' });
        return truthy(result && result.wloc && result.wloc.instances && result.wloc.instances.daemon && result.wloc.instances.daemon.running);
    } catch (e) {
        return system('pidof wlocd >/dev/null 2>&1') === 0;
    }
}

function firewall_active() {
    return read_file(FIREWALL_RUNTIME) != null;
}

function status() {
    let state = read_json(STATE) || {}, ctx = cursor(), configured = false;
    try { ctx.foreach('wloc', 'wifi', function() { configured = true; }); } catch (e) {}

    let enabled = false;
    try { enabled = truthy(ctx.get('wloc', 'main', 'enabled')); } catch (e) {}

    let fingerprint = state.ca_fingerprint || '';
    if (!fingerprint) {
        let info = read_json(CAINFO) || {};
        fingerprint = info.fingerprint_sha256 || '';
    }

    let activity = [];
    if (type(state.ap_activity) == 'array') {
        for (let row in state.ap_activity) {
            if (!row || !match(`${row.ap_id || ''}`, /^[A-Za-z0-9_-]+$/)) continue;
            push(activity, {
                ap_id: `${row.ap_id}`,
                latitude: `${row.latitude == null ? 0 : row.latitude}`,
                longitude: `${row.longitude == null ? 0 : row.longitude}`,
                last_location_at: integer(row.last_location_at, 0),
                success: truthy(row.success),
                last_error: `${row.last_error || ''}`
            });
        }
    }

    return {
        configured,
        enabled,
        running: daemon_running(),
        firewall_active: firewall_active(),
        armed: truthy(state.armed),
        session_started_at: integer(state.session_started_at, 0),
        fingerprint,
        profile_url: '/wloc-ca.mobileconfig',
        ap_activity: activity
    };
}

function configured_access_points() {
    let ctx = cursor();
    let hostapd = run_command("ubus -S list 'hostapd.*' 2>/dev/null");
    let active = {}, rows = [];

    for (let line in split(hostapd.output || '', /\r?\n/)) {
        line = trim(line);
        if (match(line, /^hostapd\.[A-Za-z0-9_.-]{1,15}$/)) active[substr(line, 8)] = true;
    }

    try {
        ctx.foreach('wireless', 'wifi-iface', function(section) {
            let ifname = `${section.ifname || ''}`;
            let mode = `${section.mode || 'ap'}`;
            if (!match(ifname, /^[A-Za-z0-9_.-]{1,15}$/) || (mode !== 'ap' && mode !== 'ap-wds')) return;
            push(rows, {
                section: `${section['.name'] || ''}`,
                iface: ifname,
                ssid: `${section.ssid || ''}`,
                disabled: truthy(section.disabled),
                active: active[ifname] === true
            });
        });
    } catch (e) {}

    return { access_points: rows };
}

function regenerate_ca() {
    let ctx = cursor(), enabled = false;
    try { enabled = truthy(ctx.get('wloc', 'main', 'enabled')); } catch (e) {}
    if (!enabled)
        return {
            ok: false,
            error: 'Unable to regenerate CA while WLOC is disabled.',
            error_code: 'service_disabled',
            detail: 'Enable WLOC before regenerating the CA.'
        };
    if (!daemon_running())
        return {
            ok: false,
            error: 'Unable to regenerate CA while WLOC is stopped.',
            error_code: 'service_stopped',
            detail: 'Start WLOC before regenerating the CA.'
        };

    let cleanup = run_ucode(RULES, [ 'cleanup' ]);
    if (!cleanup.ok)
        return {
            ok: false,
            error: 'Unable to clean up WLOC firewall rules.',
            error_code: 'cleanup_failed',
            detail: cleanup.error || 'The WLOC firewall cleanup command failed.'
        };

    let old_info = read_json(CAINFO) || {};
    let old_fingerprint = old_info.fingerprint_sha256 || '';

    if (system(`${INIT} stop >/dev/null 2>&1`) !== 0)
        return {
            ok: false,
            error: 'Unable to regenerate the WLOC Root CA.',
            error_code: 'ca_regeneration_failed',
            detail: 'Unable to stop the WLOC service.'
        };

    for (let path in [ CA_KEY, CA_DER, CA_PEM, CAINFO, CA_PROFILE ]) unlink(path);

    if (system(`${INIT} start >/dev/null 2>&1`) !== 0)
        return {
            ok: false,
            error: 'Unable to regenerate the WLOC Root CA.',
            error_code: 'ca_regeneration_failed',
            detail: 'WLOC did not restart after CA removal.'
        };

    let fingerprint = '';
    for (let attempt = 0; attempt < 15; attempt++) {
        if (daemon_running()) {
            let info = read_json(CAINFO) || {};
            fingerprint = info.fingerprint_sha256 || '';
            if (fingerprint && (!old_fingerprint || fingerprint !== old_fingerprint) &&
                read_file(CA_KEY) != null && read_file(CA_DER) != null &&
                read_file(CA_PEM) != null && read_file(CA_PROFILE) != null)
                return { ok: true, status: 'ready', fingerprint, profile_url: '/wloc-ca.mobileconfig' };
        }
        system('sleep 1');
    }

    return {
        ok: false,
        error: 'Unable to regenerate the WLOC Root CA.',
        error_code: 'ca_regeneration_failed',
        detail: fingerprint === old_fingerprint && old_fingerprint
            ? 'The replacement CA fingerprint did not change.'
            : 'The replacement CA was not generated before the timeout.'
    };
}

function dispatch(command) {
    switch (command) {
    case 'status':
        return status();
    case 'configured-access-points':
        return configured_access_points();
    case 'regenerate-ca':
        return regenerate_ca();
    default:
        return { ok: false, error: `unsupported WLOC RPC helper command: ${command}` };
    }
}

let result;
try {
    result = dispatch(ARGV[0] || '');
} catch (e) {
    result = { ok: false, error: `${e}` };
}

printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
