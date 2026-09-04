#!/usr/bin/env ucode

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const STATE_DIR = '/tmp/wloc-update';
const STATE_PATH = `${STATE_DIR}/wloc.json`;
const LOCK = `${STATE_DIR}/wloc.lock`;
const LOG = `${STATE_DIR}/wloc.log`;
const VERSION_CACHE = '/usr/share/wloc/installed-version';
const STATUS_PATH = '/var/run/wloc/status.json';
const PACKAGE = 'luci-app-wloc';
const REPO = 'madwind/luci-app-wloc';
const API_URL = `https://api.github.com/repos/${REPO}/releases/latest`;
const FETCH = '/bin/uclient-fetch';
const SELF = '/usr/libexec/wloc/update.uc';
const CRONTAB = '/etc/crontabs/root';
const CRON_TAG = 'wloc-update-weekly';
const SCHEDULE = '17 4 * * 0';
const SCHEDULE_MINUTE = 17;
const SCHEDULE_HOUR = 4;
const SCHEDULE_DOW = 0;
const LOCK_STALE_SECONDS = 30;
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: '', code: 1 };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output, code: rc === 0 ? 0 : int(rc || 1) };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function now() { return time(); }
function pid() {
    let proc = fs.popen('echo $PPID', 'r');
    if (!proc) return 0;
    let value = int(trim(proc.read('all') || '0'));
    proc.close();
    return value;
}
function temporary(prefix) { sequence++; return `${prefix}.${pid()}.${now()}.${sequence}`; }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    let tmp = temporary(`${path}.tmp`);
    let written = fs.writefile(tmp, value);
    if (written == null || written != length(value)) { fs.unlink(tmp); return { ok: false, error: `cannot write temporary file for ${path}` }; }
    if (mode != null && fs.chmod(tmp, mode) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot chmod temporary file for ${path}` }; }
    if (fs.rename(tmp, path) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function compact_error(output) {
    let lines = [];
    for (let line in split(`${output ?? ''}`, /\r?\n/)) if (trim(line)) push(lines, trim(line));
    if (length(lines) > 6) lines = slice(lines, length(lines) - 6);
    return join(' | ', lines);
}
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function cached_version() { let value = trim(read_text(VERSION_CACHE) || ''); return value || null; }
function installed_version() {
    let cached = cached_version();
    if (cached) return cached;
    let result = capture(`apk list -I ${q(PACKAGE)}`);
    if (!result.ok) return null;
    let prefix = `${PACKAGE}-`;
    for (let line in split(result.output || '', /\r?\n/)) {
        let parts = split(trim(line || ''), /[[:space:]]+/), token = length(parts) ? parts[0] : '';
        if (substr(token, 0, length(prefix)) == prefix) return substr(token, length(prefix));
    }
    return null;
}
function version_relation(left, right) {
    if (!left || !right) return null;
    let result = capture(`apk version -t ${q(left)} ${q(right)}`);
    if (!result.ok) return null;
    let found = match(trim(result.output || ''), /[<=>]/);
    return found ? found[0] : null;
}
function board_target() {
    try {
        let ubus = connect();
        if (!ubus) return null;
        let board = ubus.call('system', 'board', {});
        return board && board.release ? `${board.release.target || ''}` : null;
    } catch (e) { return null; }
}
function asset_suffix() { let target = board_target(); return target ? replace(target, /\//g, '-') : null; }
function fetch_to(url, path, timeout) {
    if (!match(`${url ?? ''}`, /^https:\/\//)) return { ok: false, error: 'download URL must use HTTPS' };
    fs.unlink(path);
    let result = capture(`${q(FETCH)} -T ${int(timeout || 20)} -O ${q(path)} ${q(url)}`);
    if (result.ok) return { ok: true };
    fs.unlink(path);
    return { ok: false, error: compact_error(result.output) || `uclient-fetch exited with status ${result.code}` };
}
function daemon_running() {
    try {
        let ubus = connect();
        if (!ubus) return false;
        let value = ubus.call('service', 'list', { name: 'wloc' });
        return bool(value && value.wloc && value.wloc.instances && value.wloc.instances.daemon && value.wloc.instances.daemon.running);
    } catch (e) { return quiet('pidof wlocd'); }
}
function daemon_armed() {
    let state = parse_json(read_text(STATUS_PATH) || '');
    return type(state) == 'object' && bool(state.running) && bool(state.armed);
}
function wait_daemon_running() {
    let stable = 0;
    for (let i = 0; i < 20; i++) {
        if (daemon_running()) { stable++; if (stable >= 2) return true; }
        else stable = 0;
        system('sleep 1');
    }
    return false;
}
function default_state() {
    return {
        kind: 'wloc', status: 'idle', phase: null, pid: null, started: null, finished: null,
        installed_version: installed_version(), latest_version: null, update_available: null,
        checked: null, check_ok: null, last_check_error: null, last_update: null,
        updated: false, post_check_error: null, error: null, message: null,
        release_tag: null, asset: null
    };
}
function read_state() {
    let value = parse_json(read_text(STATE_PATH) || '');
    let state = type(value) == 'object' ? value : default_state();
    state.kind = 'wloc';
    state.status = state.status || 'idle';
    let cached = cached_version();
    if (cached && state.status != 'starting' && state.status != 'running' && state.status != 'stopping') state.installed_version = cached;
    else if (cached && !state.installed_version) state.installed_version = cached;
    return state;
}
function save_state(state) {
    state.kind = 'wloc';
    if (!mkdirp(STATE_DIR)) return { ok: false, error: 'Unable to create the WLOC update directory.' };
    return atomic_write(STATE_PATH, sprintf('%J\n', state), 0o600);
}
function process_alive(process_pid) { process_pid = int(process_pid || 0); return process_pid > 1 && quiet(`kill -0 ${process_pid}`); }
function active_status(state) { return state && (state.status == 'starting' || state.status == 'running' || state.status == 'stopping'); }
function operation_active(state) { return active_status(state) && process_alive(state.pid); }
function operation_claimed(state) {
    if (!active_status(state)) return false;
    if (process_alive(state.pid)) return true;
    let started = int(state.started || 0);
    return state.status == 'starting' && started > 0 && now() - started < LOCK_STALE_SECONDS;
}
function lock_recent() {
    let stat = fs.stat(LOCK);
    return type(stat) == 'object' && now() - int(stat.mtime || 0) < LOCK_STALE_SECONDS;
}
function acquire_update_lock(state) {
    if (quiet(`mkdir ${q(LOCK)}`)) return true;
    if (operation_claimed(state) || lock_recent()) return false;
    quiet(`rmdir ${q(LOCK)}`);
    return quiet(`mkdir ${q(LOCK)}`);
}
function normalize_state(state) {
    let stale_start = state.status == 'starting' && !state.pid && int(state.started || 0) > 0 && now() - int(state.started || 0) >= LOCK_STALE_SECONDS;
    if ((active_status(state) && state.pid && !process_alive(state.pid)) || stale_start) {
        state.status = 'failed'; state.phase = 'failed'; state.finished = now(); state.pid = null; state.updated = false;
        state.error = 'The WLOC update worker exited unexpectedly.'; state.message = 'Update failed';
        save_state(state); quiet(`rmdir ${q(LOCK)}`);
    }
    return state;
}
function status_result() {
    let state = normalize_state(read_state());
    return {
        ok: true,
        installed_version: state.installed_version || null,
        latest_version: state.latest_version || null,
        update_available: state.update_available,
        checked: int(state.checked || 0) || null,
        check_ok: state.check_ok,
        last_check_error: state.last_check_error || null,
        last_update: int(state.last_update || 0) || null,
        post_check_error: state.post_check_error || null,
        operation: {
            status: state.status || 'idle', phase: state.phase || null, pid: int(state.pid || 0) || null,
            started: int(state.started || 0) || null, finished: int(state.finished || 0) || null,
            updated: state.updated === true, error: state.error || null, message: state.message || null
        }
    };
}
function probe_release() {
    let installed = installed_version();
    if (!installed) return { ok: false, error: 'Unable to determine installed WLOC version.' };
    let suffix = asset_suffix();
    if (!suffix) return { ok: false, error: 'Unable to determine OpenWrt target.' };
    if (!mkdirp(STATE_DIR)) return { ok: false, error: 'Unable to create the WLOC update directory.' };
    let release_path = temporary(`${STATE_DIR}/release.json`);
    let fetched = fetch_to(API_URL, release_path, 20);
    if (!fetched.ok) return { ok: false, error: 'Unable to fetch the latest WLOC release metadata.' };
    let release = parse_json(read_text(release_path) || ''); fs.unlink(release_path);
    if (type(release) != 'object') return { ok: false, error: 'The latest WLOC release metadata is invalid.' };
    let tag = `${release.tag_name || ''}`;
    if (!match(tag, /^v[A-Za-z0-9._+~-]+$/)) return { ok: false, error: 'The latest WLOC release tag is invalid.' };
    let latest = substr(tag, 1), asset = `${PACKAGE}-${latest}-${suffix}.apk`;
    let sha_path = temporary(`${STATE_DIR}/check.sha256`);
    fetched = fetch_to(`https://github.com/${REPO}/releases/download/${tag}/${asset}.sha256`, sha_path, 20);
    fs.unlink(sha_path);
    if (!fetched.ok) return { ok: false, error: `The latest release does not provide a package for target ${suffix}.` };
    let relation = version_relation(latest, installed);
    if (!relation) return { ok: false, error: 'Unable to compare WLOC package versions.' };
    return { ok: true, installed_version: installed, latest_version: latest, update_available: relation == '>', release_tag: tag, asset };
}
function check_update() {
    let state = normalize_state(read_state());
    if (operation_claimed(state) || lock_recent()) return { ok: false, error: 'A WLOC update is already in progress.' };
    state.status = 'idle'; state.phase = null; state.error = null; state.message = null; state.updated = false; state.finished = null;
    let probe = probe_release();
    state.checked = now(); state.check_ok = probe.ok === true; state.installed_version = probe.installed_version || installed_version() || state.installed_version;
    if (probe.ok) {
        state.latest_version = probe.latest_version; state.update_available = probe.update_available;
        state.release_tag = probe.release_tag; state.asset = probe.asset; state.last_check_error = null;
    } else state.last_check_error = probe.error || 'Update check failed.';
    save_state(state);
    return probe.ok ? status_result() : { ok: false, error: state.last_check_error };
}
function set_phase(state, phase, message) {
    state.status = 'running'; state.phase = phase; state.pid = pid(); state.message = message; state.error = null;
    save_state(state);
}
function fail_worker(state, message) {
    state.status = 'failed'; state.phase = 'failed'; state.finished = now(); state.error = message; state.message = 'Update failed'; state.pid = null; state.updated = false;
    save_state(state); quiet(`rmdir ${q(LOCK)}`); return state;
}
function append_post_error(state, message) { state.post_check_error = state.post_check_error ? `${state.post_check_error} ${message}` : message; }
function done_worker(state, message) {
    state.status = 'done'; state.phase = 'done'; state.finished = now(); state.pid = null; state.updated = true; state.error = null; state.message = message;
    state.installed_version = installed_version() || state.installed_version;
    if (state.installed_version && state.latest_version) {
        let relation = version_relation(state.latest_version, state.installed_version);
        if (relation) state.update_available = relation == '>';
    }
    state.last_update = state.finished; save_state(state); quiet(`rmdir ${q(LOCK)}`); return state;
}
function worker_update() {
    let state = read_state(); state.pid = pid();
    if (state.check_ok !== true || state.update_available !== true || !state.release_tag || !state.asset)
        return fail_worker(state, 'No checked WLOC update is available. Run Check updates first.');
    let apk = temporary(`${STATE_DIR}/${state.asset}.tmp`), sha = `${apk}.sha256`;
    set_phase(state, 'downloading', 'Downloading WLOC package');
    let fetched = fetch_to(`https://github.com/${REPO}/releases/download/${state.release_tag}/${state.asset}`, apk, 30);
    if (!fetched.ok) { fs.unlink(apk); return fail_worker(state, 'Unable to download the WLOC update package.'); }
    fetched = fetch_to(`https://github.com/${REPO}/releases/download/${state.release_tag}/${state.asset}.sha256`, sha, 20);
    if (!fetched.ok) { fs.unlink(apk); fs.unlink(sha); return fail_worker(state, 'Unable to download the WLOC update package checksum.'); }

    set_phase(state, 'verifying', 'Verifying WLOC package');
    let expected_match = match(trim(read_text(sha) || ''), /^([0-9A-Fa-f]{64})/);
    let hash = capture(`sha256sum ${q(apk)}`), actual_match = hash.ok ? match(hash.output || '', /^([0-9A-Fa-f]{64})/) : null;
    let expected = expected_match ? lc(expected_match[1]) : '', actual = actual_match ? lc(actual_match[1]) : '';
    if (!expected || !actual || expected != actual) { fs.unlink(apk); fs.unlink(sha); return fail_worker(state, 'WLOC update SHA256 verification failed.'); }
    let simulated = capture(`apk --network=no add --allow-untrusted --simulate --upgrade ${q(apk)}`);
    if (!simulated.ok) { fs.unlink(apk); fs.unlink(sha); return fail_worker(state, 'WLOC update dependencies cannot be satisfied without network access after download.'); }

    let was_running = daemon_running();
    if (was_running) {
        set_phase(state, 'stopping', 'Stopping WLOC before package installation');
        if (!quiet('/etc/init.d/wloc stop')) { fs.unlink(apk); fs.unlink(sha); return fail_worker(state, 'Unable to stop WLOC before package installation.'); }
    }

    set_phase(state, 'installing', 'Installing WLOC package');
    let installed = capture(`WLOC_DEFER_RESTART=1 apk --network=no add --allow-untrusted --upgrade ${q(apk)}`);
    fs.unlink(apk); fs.unlink(sha);
    if (!installed.ok) {
        let detail = compact_error(installed.output || '');
        if (was_running) {
            set_phase(state, 'restarting', 'Restoring WLOC after failed package installation');
            if (!quiet('/etc/init.d/wloc start') || !wait_daemon_running()) {
                quiet('/etc/init.d/wloc stop');
                detail += ' WLOC did not remain running after the failed package install.';
            } else if (!daemon_armed()) {
                detail += ' WLOC restarted, but interception is not armed yet.';
            }
        }
        return fail_worker(state, `APK install failed: ${trim(detail)}`);
    }

    state.post_check_error = null;
    if (was_running) {
        set_phase(state, 'restarting', 'Starting WLOC after package update');
        if (!quiet('/etc/init.d/wloc start') || !wait_daemon_running()) {
            quiet('/etc/init.d/wloc stop');
            append_post_error(state, 'WLOC did not remain running after update; the service was left stopped.');
        } else if (!daemon_armed()) {
            append_post_error(state, 'WLOC restarted, but interception is not armed yet; runtime recovery will continue automatically.');
        }
    }
    state.installed_version = installed_version() || state.installed_version;
    if (!state.installed_version) append_post_error(state, 'Unable to verify the installed WLOC version after update.');
    else if (state.latest_version && version_relation(state.installed_version, state.latest_version) == '<') append_post_error(state, 'The installed WLOC version is still older than the checked release version.');
    return done_worker(state, 'WLOC updated successfully');
}
function spawn_worker() {
    let command = `/usr/bin/ucode ${q(SELF)} worker </dev/null >>${q(LOG)} 2>&1 & echo $!`;
    let result = capture(command), worker_pid = int(trim(result.output || '0'));
    return result.ok && worker_pid > 1 ? worker_pid : 0;
}
function start_update() {
    if (!mkdirp(STATE_DIR)) return { ok: false, error: 'Unable to create the WLOC update directory.' };
    let state = normalize_state(read_state());
    if (operation_claimed(state)) return status_result();
    if (state.check_ok !== true || state.update_available !== true || !state.release_tag || !state.asset)
        return { ok: false, error: 'No checked WLOC update is available. Run Check updates first.' };
    if (!acquire_update_lock(state)) return { ok: false, error: 'Another WLOC update is starting.' };
    state.status = 'starting'; state.phase = 'starting'; state.started = now(); state.finished = null; state.pid = null; state.updated = false;
    state.post_check_error = null; state.error = null; state.message = 'Update started';
    let saved = save_state(state);
    if (!saved.ok) { quiet(`rmdir ${q(LOCK)}`); return saved; }
    let worker_pid = spawn_worker();
    if (worker_pid <= 1) { quiet(`rmdir ${q(LOCK)}`); state.status = 'failed'; state.phase = 'failed'; state.error = 'Unable to start the WLOC update worker.'; save_state(state); return { ok: false, error: state.error }; }
    state = read_state();
    if (state.status == 'starting' && int(state.pid || 0) <= 1) { state.pid = worker_pid; save_state(state); }
    return status_result();
}
function worker_matches(process_pid) {
    let raw = read_text(`/proc/${process_pid}/cmdline`) || '';
    let command = replace(raw, /\0/g, ' ');
    return index(command, SELF) >= 0 && index(command, 'worker') >= 0;
}
function collect_children(parent, output) {
    let raw = trim(read_text(`/proc/${parent}/task/${parent}/children`) || '');
    for (let value in split(raw, /[[:space:]]+/)) {
        let child = int(value || 0);
        if (child <= 1) continue;
        collect_children(child, output); push(output, child);
    }
}
function any_alive(process_pid, children) {
    if (process_alive(process_pid)) return true;
    for (let child in children) if (process_alive(child)) return true;
    return false;
}
function terminate_tree(process_pid) {
    let children = []; collect_children(process_pid, children);
    for (let child in children) quiet(`kill -TERM ${child}`);
    quiet(`kill -TERM ${process_pid}`);
    for (let attempt = 0; attempt < 3; attempt++) { if (!any_alive(process_pid, children)) return true; system('sleep 1'); }
    for (let child in children) if (process_alive(child)) quiet(`kill -KILL ${child}`);
    if (process_alive(process_pid)) quiet(`kill -KILL ${process_pid}`);
    return !any_alive(process_pid, children);
}
function stop_update() {
    let state = normalize_state(read_state()), process_pid = int(state.pid || 0);
    if (!operation_active(state)) return { ok: false, error: 'No active WLOC update to stop.' };
    if (state.phase != 'starting' && state.phase != 'downloading' && state.phase != 'verifying')
        return { ok: false, error: 'WLOC update cannot be stopped after the maintenance phase has started.' };
    if (!worker_matches(process_pid)) return { ok: false, error: 'Refusing to stop an unexpected process.' };
    state.status = 'stopping'; state.phase = 'stopping'; state.message = 'Stopping update'; state.error = null; save_state(state);
    if (!terminate_tree(process_pid)) {
        state.status = 'running'; state.phase = 'stopping'; state.pid = process_pid;
        state.error = 'Unable to stop the WLOC update worker.'; state.message = 'Unable to stop update';
        save_state(state); return { ok: false, error: state.error };
    }
    quiet(`rm -f ${q(STATE_DIR)}/*.tmp.${process_pid}.* ${q(STATE_DIR)}/apk-install.log.${process_pid}`);
    quiet(`rmdir ${q(LOCK)}`);
    state.status = 'stopped'; state.phase = 'stopped'; state.finished = now(); state.pid = null; state.updated = false; state.error = null; state.message = 'Update stopped'; save_state(state);
    return status_result();
}

function flag(option) {
    try { let ctx = cursor(); return bool(ctx.get('wloc', 'main', option)); }
    catch (e) { return false; }
}
function set_flag(option, enabled) {
    try {
        let ctx = cursor(); ctx.set('wloc', 'main', option, enabled ? '1' : '0');
        return ctx.commit('wloc') === true;
    } catch (e) { return false; }
}
function days_in_month(year, month) {
    if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) return 31;
    if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
    if (month == 2) return (year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)) ? 29 : 28;
    return 0;
}
function next_check_local() {
    let result = capture("date '+%Y %m %d %w %H %M'");
    let fields = result.ok ? split(trim(result.output || ''), /[[:space:]]+/) : [];
    if (length(fields) != 6) return '';
    let year = int(fields[0]), month = int(fields[1]), day = int(fields[2]), dow = int(fields[3]), hour = int(fields[4]), minute = int(fields[5]);
    let days = (SCHEDULE_DOW - dow + 7) % 7;
    if (days == 0 && (hour > SCHEDULE_HOUR || (hour == SCHEDULE_HOUR && minute >= SCHEDULE_MINUTE))) days = 7;
    while (days-- > 0) {
        day++;
        let dim = days_in_month(year, month);
        if (day > dim) { day = 1; month++; if (month > 12) { month = 1; year++; } }
    }
    return sprintf('%04d-%02d-%02d %02d:%02d', year, month, day, SCHEDULE_HOUR, SCHEDULE_MINUTE);
}
function reload_cron() {
    if (!quiet('pidof crond')) return;
    if (!quiet('/etc/init.d/cron reload')) quiet('/etc/init.d/cron restart');
}
function cron_without_tag() {
    let output = [];
    for (let line in split(read_text(CRONTAB) || '', /\r?\n/)) {
        if (index(line, CRON_TAG) >= 0) continue;
        if (line || length(output)) push(output, line);
    }
    while (length(output) && output[length(output) - 1] == '') pop(output);
    return length(output) ? join('\n', output) + '\n' : '';
}
function sync_schedule() {
    if (!mkdirp('/etc/crontabs')) return { ok: false, error: 'Unable to create crontab directory.' };
    let content = cron_without_tag();
    if (flag('update_check_enabled')) content += `${SCHEDULE} /usr/bin/ucode ${SELF} auto-run >/dev/null 2>&1 # ${CRON_TAG}\n`;
    let saved = atomic_write(CRONTAB, content, 0o600);
    if (!saved.ok) return saved;
    reload_cron(); return auto_status();
}
function remove_schedule() {
    if (read_text(CRONTAB) != null) {
        let saved = atomic_write(CRONTAB, cron_without_tag(), 0o600);
        if (!saved.ok) return saved;
    }
    reload_cron(); return auto_status();
}
function auto_status() {
    let scheduled = index(read_text(CRONTAB) || '', `# ${CRON_TAG}`) >= 0;
    let next = scheduled ? next_check_local() : '';
    let timezone = '';
    if (next) { let result = capture(`date -d ${q(`${next}:00`)} +%Z`); if (!result.ok) result = capture('date +%Z'); timezone = trim(result.output || ''); }
    return { ok: true, check_enabled: flag('update_check_enabled'), wloc: flag('wloc_auto_update'), scheduled, schedule: SCHEDULE, next_check: next, timezone };
}
function auto_set(option, enabled) {
    if (!set_flag(option, bool(enabled))) return { ok: false, error: 'Unable to save automatic update setting.' };
    return option == 'update_check_enabled' ? sync_schedule() : auto_status();
}
function auto_run() {
    let checked = check_update();
    if (!checked.ok) { system(`logger -t wloc-update ${q(`scheduled update check failed: ${checked.error || 'unknown error'}`)}`); return checked; }
    if (!flag('wloc_auto_update')) return { ok: true };
    let status = status_result();
    if (status.update_available !== true) return { ok: true };
    let started = start_update();
    if (!started.ok) system(`logger -t wloc-update ${q('automatic WLOC update could not start')}`);
    return started;
}
function dispatch(command, args) {
    if (command == 'status') return status_result();
    if (command == 'check') return check_update();
    if (command == 'install' || command == 'start') return start_update();
    if (command == 'stop') return stop_update();
    if (command == 'worker') { let state = worker_update(); return { ok: state.status == 'done', state }; }
    if (command == 'auto-status') return auto_status();
    if (command == 'auto-set-check') return auto_set('update_check_enabled', args[0]);
    if (command == 'auto-set') return auto_set('wloc_auto_update', args[0]);
    if (command == 'auto-sync') return sync_schedule();
    if (command == 'auto-remove') return remove_schedule();
    if (command == 'auto-run') return auto_run();
    return { ok: false, error: `Unknown update command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
