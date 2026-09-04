#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
// Composite WLOC RPC operations. rpcd invokes this controller asynchronously.

'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import { open, popen, unlink } from 'fs';

const INIT = '/etc/init.d/wloc';
const RULES = '/usr/libexec/wloc/rules.uc';
const FIREWALL = '/usr/libexec/wloc/firewall.uc';
const STATE = '/var/run/wloc/status.json';
const START_ERROR = '/var/run/wloc/start-error';
const CAINFO = '/etc/wloc/ca.info.json';
const CA_KEY = '/etc/wloc/ca.key';
const CA_DER = '/etc/wloc/ca.der';
const CA_PEM = '/etc/wloc/ca.pem';
const CA_PROFILE = '/www/wloc-ca.mobileconfig';
const VERSION_CACHE = '/var/run/wloc/package.version';
const INSTALLED_VERSION = '/usr/share/wloc/installed-version';
const FIREWALL_CONFIG = '/etc/wloc/firewall.nft';
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

function package_version() {
    for (let path in [ INSTALLED_VERSION, VERSION_CACHE ]) {
        let cached = trim(read_file(path) || '');
        if (cached && match(cached, /^[A-Za-z0-9._+~-]+$/)) return cached;
    }

    let result = run_command("apk list --installed luci-app-wloc 2>/dev/null | sed -n 's/^luci-app-wloc-\\([^ ]*\\).*/\\1/p' | head -n 1");
    let version = trim(result.output || '');
    if (!version || !match(version, /^[A-Za-z0-9._+~-]+$/)) return '';
    system(`printf '%s\\n' ${q(version)} > ${q(VERSION_CACHE)} 2>/dev/null`);
    return version;
}

function firewall_status() {
    let present = read_file(FIREWALL_RUNTIME) != null || read_file(FIREWALL_CONFIG) != null;
    let result = run_ucode(FIREWALL, [ 'active' ]);
    return {
        present,
        active: !!(result && result.ok === true && result.active_found === true)
    };
}

function status() {
    let state = read_json(STATE) || {}, ctx = cursor(), configured = false;
    try { ctx.foreach('wloc', 'wifi', function() { configured = true; }); } catch (e) {}

    let enabled = false;
    try { enabled = truthy(ctx.get('wloc', 'main', 'enabled')); } catch (e) {}

    let running = daemon_running(), firewall = firewall_status();
    let accepted = integer(state.accepted_connections, 0);
    let reason = '';

    if (!running) {
        reason = trim(read_file(START_ERROR) || '');
        if (!reason && enabled) reason = 'service is not running; check the system log';
    } else if (!truthy(state.armed)) {
        if (state.last_event === 'lease_failed')
            reason = 'Runtime rule refresh failed' + (state.last_error ? `: ${state.last_error}` : '');
        else if (state.last_event === 'cleanup_failed')
            reason = 'Runtime rule cleanup failed' + (state.last_error ? `: ${state.last_error}` : '');
    }

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
        version: package_version(),
        running,
        rules_present: firewall.present,
        firewall_active: firewall.active,
        armed: truthy(state.armed),
        configured_aps: integer(state.configured_aps, 0),
        accepted_connections: accepted,
        passthrough_connections: integer(state.passthrough_connections, 0),
        tls_intercepted: integer(state.tls_intercepted, 0),
        wloc_requests: integer(state.wloc_requests, 0),
        patched_responses: integer(state.patched_responses, 0),
        delivered_responses: integer(state.delivered_responses, 0),
        patch_failures: integer(state.patch_failures, 0),
        last_event: `${state.last_event || ''}`,
        last_error: `${state.last_error || ''}`,
        service_reason: reason,
        session_started_at: integer(state.session_started_at, 0),
        updated_at: integer(state.updated_at, 0),
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
