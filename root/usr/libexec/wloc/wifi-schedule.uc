#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: '' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output };
}
function truthy(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function valid_iface(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_.-]{1,15}$/) != null; }
function valid_device(value) { return match(`${value ?? ''}`, /^[A-Za-z0-9_-]+$/) != null; }
function valid_country(value) { return match(`${value ?? ''}`, /^[A-Za-z]{2}$/) != null; }
function valid_time(value) { return match(`${value ?? ''}`, /^([01][0-9]|2[0-3]):[0-5][0-9]$/) != null; }
function time_minutes(value) {
    if (!valid_time(value)) return null;
    let fields = split(`${value}`, ':');
    return int(fields[0]) * 60 + int(fields[1]);
}
function now_minutes() {
    let result = capture("date '+%H:%M'");
    return result.ok ? time_minutes(trim(result.output || '')) : null;
}
function window_active(start, end, current) {
    let a = time_minutes(start), b = time_minutes(end), now = current == null ? now_minutes() : current;
    if (a == null || b == null || now == null) return false;
    if (a == b) return true;
    if (a < b) return now >= a && now < b;
    return now >= a || now < b;
}
function log_error(message) { system(`logger -t wlocd ${q(`wifi schedule: ${message}`)} >/dev/null 2>&1`); }
function find_wireless(ctx, iface) {
    if (!valid_iface(iface)) return { ok: false, error: `interface "${iface || '<empty>'}" is unavailable` };
    let matches = [];
    try {
        ctx.foreach('wireless', 'wifi-iface', function(section) {
            let mode = `${section.mode || 'ap'}`;
            if ((mode == 'ap' || mode == 'ap-wds') && `${section.ifname || ''}` == iface)
                push(matches, section);
        });
    } catch (e) { return { ok: false, error: `${e}` }; }
    if (!length(matches)) return { ok: false, error: `interface "${iface}" is unavailable` };
    if (length(matches) > 1) return { ok: false, error: `interface "${iface}" matches multiple wireless sections` };
    let section = matches[0];
    return { ok: true, section: `${section['.name'] || ''}`, device: `${section.device || ''}`, disabled: section.disabled };
}
function hostapd_active(iface) {
    if (!valid_iface(iface)) return false;
    try {
        let ubus = connect();
        if (!ubus) return false;
        return type(ubus.call(`hostapd.${iface}`, 'get_status', {})) == 'object';
    } catch (e) { return false; }
}
function reload_wifi() {
    if (system('wifi reload >/dev/null 2>&1') === 0) return true;
    log_error('wifi reload failed; committed wireless state could not be applied');
    return false;
}
function set_value(ctx, section, option, value, state) {
    let current = ctx.get('wireless', section, option);
    if (`${current == null ? '' : current}` == `${value}`) return true;
    try {
        ctx.set('wireless', section, option, `${value}`);
        state.changed = true;
        return true;
    } catch (e) {
        state.failed = true;
        log_error(`unable to set wireless.${section}.${option}; scheduled state will be retried`);
        return false;
    }
}
function configured_rules(ctx) {
    let rows = [];
    try {
        ctx.foreach('wloc', 'wifi', function(section) {
            if (section.enabled != null && !truthy(section.enabled)) return;
            if (!truthy(section.schedule_enabled)) return;
            push(rows, section);
        });
    } catch (e) {}
    return rows;
}
function reconcile() {
    let ctx = cursor(), state = { changed: false, failed: false, runtime_mismatch: false }, current = now_minutes();
    if (current == null) return { ok: false, error: 'unable to determine local time' };
    let rules = configured_rules(ctx);

    for (let rule in rules) {
        let name = `${rule['.name'] || ''}`, start = `${rule.schedule_start || ''}`, end = `${rule.schedule_end || ''}`;
        if (!valid_time(start) || !valid_time(end)) { state.failed = true; log_error(`invalid schedule for WLOC rule ${name}`); continue; }
        let iface = `${rule.iface || ''}`, found = find_wireless(ctx, iface);
        if (!found.ok) { state.failed = true; log_error(`${found.error}; scheduled state was not changed`); continue; }
        if (!valid_device(found.device)) { state.failed = true; log_error(`wireless.${found.section} has no valid wifi-device; scheduled state was not changed`); continue; }

        let scheduled_off = window_active(start, end, current);
        if (scheduled_off) {
            set_value(ctx, found.section, 'disabled', '1', state);
            continue;
        }

        let disabled = ctx.get('wireless', found.section, 'disabled');
        if (truthy(disabled)) set_value(ctx, found.section, 'disabled', '0', state);
        let country = `${rule.country || ''}`;
        if (!country) continue;
        if (!valid_country(country)) { state.failed = true; log_error(`invalid country code for WLOC rule ${name}: ${country}`); continue; }
        country = uc(country);
        if (`${ctx.get('wireless', found.device, 'country') || ''}` != country)
            set_value(ctx, found.device, 'country', country, state);
    }

    if (state.changed) {
        if (ctx.commit('wireless') !== true) { log_error('unable to commit wireless configuration; scheduled state will be retried'); return { ok: false, error: 'unable to commit wireless configuration' }; }
        if (!reload_wifi()) state.failed = true;
    } else {
        for (let rule in rules) {
            let start = `${rule.schedule_start || ''}`, end = `${rule.schedule_end || ''}`, iface = `${rule.iface || ''}`;
            if (!valid_time(start) || !valid_time(end) || !valid_iface(iface)) continue;
            let expected_active = !window_active(start, end, current);
            let runtime_active = hostapd_active(iface);
            if (runtime_active == expected_active) continue;
            state.runtime_mismatch = true;
            log_error(`runtime state mismatch for ${iface}: expected ${expected_active ? 'enabled' : 'disabled'}; reloading WiFi`);
        }
        if (state.runtime_mismatch && !reload_wifi()) state.failed = true;
    }

    return { ok: !state.failed, changed: state.changed, runtime_mismatch: state.runtime_mismatch };
}
function seconds_until_next_check() {
    let result = capture("date '+%M %S'");
    let fields = result.ok ? split(trim(result.output || ''), /[[:space:]]+/) : [];
    if (length(fields) != 2) return 1800;
    let minute = int(fields[0]), second = int(fields[1]);
    let elapsed = (minute % 30) * 60 + second;
    let delay = 1800 - elapsed;
    return delay >= 1 ? delay : 1800;
}
function run_loop() {
    while (true) {
        reconcile();
        let delay = seconds_until_next_check();
        if (system(`sleep ${delay}`) !== 0) break;
    }
    return { ok: true };
}
function dispatch(command) {
    if (command == 'run') return run_loop();
    if (command == 'reconcile') return reconcile();
    return { ok: false, error: `unsupported WiFi schedule command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || ''); }
catch (e) { result = { ok: false, error: `${e}` }; }
if ((ARGV[0] || '') != 'run') printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
