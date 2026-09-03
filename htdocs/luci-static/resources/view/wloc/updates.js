'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';

var callStatus = rpc.declare({ object: 'luci.wloc.update', method: 'status', expect: { '': {} }, reject: true });
var callCheck = rpc.declare({ object: 'luci.wloc.update', method: 'check', expect: { '': {} }, reject: true });
var callInstall = rpc.declare({ object: 'luci.wloc.update', method: 'install', expect: { '': {} }, reject: true });
var callStop = rpc.declare({ object: 'luci.wloc.update', method: 'stop', expect: { '': {} }, reject: true });
var callSettings = rpc.declare({ object: 'luci.wloc.update', method: 'settings', expect: { '': {} }, reject: true });
var callSetCheck = rpc.declare({ object: 'luci.wloc.update', method: 'set_check', params: [ 'enabled' ], expect: { '': {} }, reject: true });
var callSetAuto = rpc.declare({ object: 'luci.wloc.update', method: 'set_auto', params: [ 'enabled' ], expect: { '': {} }, reject: true });

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds) return '—';
    var delta = seconds - Date.now() / 1000;
    var absolute = Math.abs(delta);
    var unit = 'second', divisor = 1;
    if (absolute >= 365 * 86400) { unit = 'year'; divisor = 365 * 86400; }
    else if (absolute >= 30 * 86400) { unit = 'month'; divisor = 30 * 86400; }
    else if (absolute >= 86400) { unit = 'day'; divisor = 86400; }
    else if (absolute >= 3600) { unit = 'hour'; divisor = 3600; }
    else if (absolute >= 60) { unit = 'minute'; divisor = 60; }
    var amount = Math.round(delta / divisor);
    var locale = document.documentElement && document.documentElement.getAttribute('lang') || 'en';
    try {
        if (typeof Intl !== 'undefined' && typeof Intl.RelativeTimeFormat === 'function')
            return new Intl.RelativeTimeFormat(locale, { numeric: 'always' }).format(amount, unit);
    } catch (e) {}
    var count = Math.abs(amount), label = unit + (count === 1 ? '' : 's');
    return amount < 0 ? '%d %s ago'.format(count, label) : 'in %d %s'.format(count, label);
}

function valueRow(label, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

function activeStatus(status) { return [ 'starting', 'running', 'stopping' ].indexOf(status) >= 0; }
function phaseText(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    return _('Updating...');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read software update status.') }),
            L.resolveDefault(callSettings(), { ok: false, error: _('Unable to read update settings.') })
        ]);
    },

    render: function(data) {
        document.title = _('WLOC | Updates');

        var initial = data && data[0];
        var initialSettings = data && data[1];
        var pageVisible = true;
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var version = E('span');
        var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
        var history = E('div', { 'class': 'cbi-section-descr' });
        var checkEnabled = E('input', { 'type': 'checkbox', 'disabled': '' });
        var autoUpdate = E('input', { 'type': 'checkbox', 'disabled': '' });
        var checkButton = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Check updates'));
        var updateButton = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button', 'disabled': '' }, _('Update'));
        var stopButton = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop'));
        var state = { installed: '', latest: '', available: null, checked: 0, lastUpdate: 0, locked: false, checking: false };

        function setMessage(kind, text) { wlocUi.setState(message, kind, text || ''); }
        function renderVersion() {
            version.replaceChildren(E('code', {}, state.installed || _('Unknown')));
            if (state.latest && state.latest !== state.installed) {
                version.appendChild(document.createTextNode(' → '));
                version.appendChild(E('code', {}, state.latest));
            }
        }
        function renderHistory() {
            var parts = [];
            if (state.checked) parts.push(_('Last check: %s').format(formatTimestamp(state.checked)));
            if (state.lastUpdate) parts.push(_('Last update: %s').format(formatTimestamp(state.lastUpdate)));
            wlocUi.setText(history, parts.join(' · '));
            history.hidden = parts.length === 0;
        }
        function renderIdle() {
            if (state.available === true) wlocUi.setState(status, 'warn', _('Update available'));
            else if (state.available === false) wlocUi.setState(status, 'ok', _('Up to date'));
            else wlocUi.setState(status, 'notice', _('Not checked'));
        }
        function updateButtons(operation) {
            var active = activeStatus(operation && operation.status);
            updateButton.disabled = active || state.checking || state.available !== true;
            stopButton.disabled = !active || operation.phase === 'installing' || operation.status === 'stopping';
            checkButton.disabled = active || state.checking;
        }
        function applyStatus(result) {
            if (!result || result.ok !== true) throw new Error(wlocUi.errorMessage(result, _('Unable to read software update status.')));
            var operation = result.operation || {};
            if (result.installed_version) state.installed = String(result.installed_version);
            if (result.latest_version) state.latest = String(result.latest_version);
            if (result.check_ok === false) state.available = null;
            else if (result.update_available !== undefined && result.update_available !== null) state.available = result.update_available === true;
            if (result.checked != null) state.checked = Number(result.checked) || 0;
            if (result.last_update != null) state.lastUpdate = Number(result.last_update) || 0;
            state.locked = activeStatus(operation.status);
            renderVersion(); renderHistory();
            if (state.checking) wlocUi.setState(status, 'notice', _('Checking for updates...'));
            else if (activeStatus(operation.status)) wlocUi.setState(status, 'notice', phaseText(operation));
            else if (operation.status === 'failed') wlocUi.setState(status, 'error', operation.error || _('Update failed'));
            else if (operation.status === 'stopped') wlocUi.setState(status, 'notice', _('Stopped'));
            else if (operation.status === 'done' && operation.updated === true && result.post_check_error)
                wlocUi.setState(status, 'warn', _('Updated') + ' · ' + result.post_check_error);
            else if (result.check_ok === false && result.last_check_error) wlocUi.setState(status, 'error', result.last_check_error);
            else renderIdle();
            updateButtons(operation);
            return result;
        }
        function applySettings(result) {
            if (!result || result.ok !== true) throw new Error(wlocUi.errorMessage(result, _('Unable to read update settings.')));
            checkEnabled.checked = result.check_enabled === true || result.check_enabled === 1;
            autoUpdate.checked = result.wloc === true || result.wloc === 1;
            checkEnabled.disabled = false;
            autoUpdate.disabled = false;
            return result;
        }
        function refresh() {
            if (!pageVisible || state.checking) return Promise.resolve();
            return callStatus().then(applyStatus).catch(function(error) {
                if (!state.locked) wlocUi.setState(status, 'error', wlocUi.errorMessage(error, _('Unable to read software update status.')));
                return false;
            });
        }
        function runCheck() {
            state.checking = true;
            checkButton.disabled = true; updateButton.disabled = true; stopButton.disabled = true;
            setMessage('notice', _('Checking WLOC for updates...'));
            wlocUi.setState(status, 'notice', _('Checking for updates...'));
            return callCheck().then(function(result) {
                state.checking = false;
                applyStatus(wlocUi.requireOk(result, _('Unable to check WLOC updates.')));
                setMessage('ok', _('Update check completed.'));
                return result;
            }).catch(function(error) {
                state.checking = false;
                state.available = null;
                setMessage('error', wlocUi.errorMessage(error, _('Unable to check WLOC updates.')));
                return refresh();
            });
        }
        function runUpdate() {
            if (state.available !== true) return Promise.resolve();
            updateButton.disabled = true; checkButton.disabled = true;
            return callInstall().then(function(result) {
                applyStatus(wlocUi.requireOk(result, _('Unable to start WLOC update.')));
                setMessage('notice', _('WLOC update started.'));
                return result;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to start WLOC update.')));
                return refresh();
            });
        }
        function stopUpdate() {
            stopButton.disabled = true;
            return callStop().then(function(result) {
                applyStatus(wlocUi.requireOk(result, _('Unable to stop WLOC update.')));
                return result;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to stop WLOC update.')));
                return refresh();
            });
        }
        function setCheckSetting() {
            var desired = checkEnabled.checked;
            checkEnabled.disabled = true;
            return callSetCheck(desired ? 1 : 0).then(function(result) {
                applySettings(wlocUi.requireOk(result, _('Unable to change automatic check setting.')));
            }).catch(function(error) {
                checkEnabled.checked = !desired; checkEnabled.disabled = false;
                setMessage('error', wlocUi.errorMessage(error, _('Unable to change automatic check setting.')));
            });
        }
        function setAutoSetting() {
            var desired = autoUpdate.checked;
            autoUpdate.disabled = true;
            return callSetAuto(desired ? 1 : 0).then(function(result) {
                applySettings(wlocUi.requireOk(result, _('Unable to change automatic update setting.')));
            }).catch(function(error) {
                autoUpdate.checked = !desired; autoUpdate.disabled = false;
                setMessage('error', wlocUi.errorMessage(error, _('Unable to change automatic update setting.')));
            });
        }

        checkButton.addEventListener('click', ui.createHandlerFn(checkButton, runCheck));
        updateButton.addEventListener('click', ui.createHandlerFn(updateButton, runUpdate));
        stopButton.addEventListener('click', ui.createHandlerFn(stopButton, stopUpdate));
        checkEnabled.addEventListener('change', setCheckSetting);
        autoUpdate.addEventListener('change', setAutoSetting);
        history.hidden = true;

        if (initial && initial.ok === true) applyStatus(initial);
        else wlocUi.setState(status, 'error', wlocUi.errorMessage(initial, _('Unable to read software update status.')));
        if (initialSettings && initialSettings.ok === true) applySettings(initialSettings);
        else setMessage('error', wlocUi.errorMessage(initialSettings, _('Unable to read update settings.')));

        poll.add(refresh, 2);
        window.setInterval(function() { if (pageVisible) renderHistory(); }, 60000);
        window.addEventListener('pagehide', function() { pageVisible = false; poll.remove(refresh); }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Check WLOC on demand or weekly. Automatic update only installs a version already found by a check.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Update checks')),
                valueRow(_('Automatic update checks'), E('label', {}, [ checkEnabled, ' ', _('Weekly') ])),
                valueRow(_('Actions'), checkButton),
                message
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Components')),
                E('div', { 'class': 'cbi-section-node' }, [
                    E('h4', {}, _('WLOC')),
                    valueRow(_('Version'), version),
                    valueRow(_('Status'), status),
                    valueRow(_('Automatic update'), autoUpdate),
                    valueRow(_('Actions'), E('span', {}, [ updateButton, ' ', stopButton ])),
                    history
                ])
            ])
        ]);
    }
});
