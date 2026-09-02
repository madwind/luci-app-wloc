'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';

var callSoftwareStatus = rpc.declare({ object: 'luci.wloc.update', method: 'status', expect: { '': {} }, reject: true });
var callSoftwareInstall = rpc.declare({ object: 'luci.wloc.update', method: 'install', expect: { '': {} }, reject: true });
var callSoftwareStop = rpc.declare({ object: 'luci.wloc.update', method: 'stop', expect: { '': {} }, reject: true });

var SOFTWARE_RECONCILE_ATTEMPTS = 8;
var SOFTWARE_RECONCILE_DELAY = 1000;

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds) return '—';

    var delta = seconds - Date.now() / 1000;
    var absolute = Math.abs(delta);
    var unit = 'second';
    var divisor = 1;

    if (absolute >= 365 * 86400) {
        unit = 'year';
        divisor = 365 * 86400;
    } else if (absolute >= 30 * 86400) {
        unit = 'month';
        divisor = 30 * 86400;
    } else if (absolute >= 86400) {
        unit = 'day';
        divisor = 86400;
    } else if (absolute >= 3600) {
        unit = 'hour';
        divisor = 3600;
    } else if (absolute >= 60) {
        unit = 'minute';
        divisor = 60;
    }

    var amount = Math.round(delta / divisor);
    var locale = document.documentElement && document.documentElement.getAttribute('lang') || 'en';
    try {
        if (typeof Intl !== 'undefined' && typeof Intl.RelativeTimeFormat === 'function')
            return new Intl.RelativeTimeFormat(locale, { numeric: 'always' }).format(amount, unit);
    } catch (e) {}

    var count = Math.abs(amount);
    var label = unit + (count === 1 ? '' : 's');
    return amount < 0 ? '%d %s ago'.format(count, label) : 'in %d %s'.format(count, label);
}

function valueRow(label, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

function softwarePhase(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'checking') return _('Checking for updates...');
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    return _('Updating...');
}

function activeStatus(status) {
    return [ 'starting', 'running', 'stopping' ].indexOf(status) >= 0;
}

function terminalStatus(status) {
    return [ 'done', 'failed', 'stopped' ].indexOf(status) >= 0;
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return L.resolveDefault(callSoftwareStatus(), { ok: false, error: _('Unable to read software update status.') });
    },

    render: function(initial) {
        document.title = _('WLOC | Updates');

        var pageVisible = true;
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var version = E('span');
        var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
        var history = E('div', { 'class': 'cbi-section-descr' });
        var update = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Update'));
        var stop = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop'));
        var software = {
            installedVersion: '',
            latestVersion: '',
            updateAvailable: null,
            checkedAt: 0,
            lastUpdateAt: 0,
            operationStarted: 0,
            operationFinished: 0,
            updateLocked: false
        };

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function renderVersion() {
            version.replaceChildren(E('code', {}, software.installedVersion || _('Unknown')));
            if (software.latestVersion && software.latestVersion !== software.installedVersion) {
                version.appendChild(document.createTextNode(' → '));
                version.appendChild(E('code', {}, software.latestVersion));
            }
        }

        function setMeta(checked, lastUpdate) {
            if (checked != null) software.checkedAt = Number(checked) || 0;
            if (lastUpdate != null) software.lastUpdateAt = Number(lastUpdate) || 0;
            var values = [];
            if (software.checkedAt) values.push(_('Last check: %s').format(formatTimestamp(software.checkedAt)));
            if (software.lastUpdateAt) values.push(_('Last update: %s').format(formatTimestamp(software.lastUpdateAt)));
            wlocUi.setText(history, values.join(' · '));
            history.hidden = values.length === 0;
        }

        function setIdle(available, fallback) {
            if (available === true) wlocUi.setState(status, 'warn', _('Update available'));
            else if (available === false) wlocUi.setState(status, 'ok', _('Up to date'));
            else wlocUi.setState(status, 'notice', fallback || _('Ready'));
        }

        function applySoftware(result) {
            result = result || {};
            var operation = result.operation || {};
            if (result.installed_version) software.installedVersion = String(result.installed_version);
            if (result.latest_version) software.latestVersion = String(result.latest_version);
            if (result.update_available !== undefined && result.update_available !== null)
                software.updateAvailable = result.update_available === true;
            if (operation.started != null) software.operationStarted = Number(operation.started) || 0;
            if (operation.finished != null) software.operationFinished = Number(operation.finished) || 0;
            setMeta(result.checked, result.last_update);
            renderVersion();

            if (activeStatus(operation.status)) {
                software.updateLocked = true;
                wlocUi.setState(status, 'notice', operation.status === 'stopping' ? _('Stopping...') : softwarePhase(operation));
                update.disabled = true;
                stop.disabled = operation.phase === 'installing' || operation.status === 'stopping';
            } else {
                if (terminalStatus(operation.status)) software.updateLocked = false;
                if (operation.status === 'failed') wlocUi.setState(status, 'error', operation.error || _('Update failed'));
                else if (operation.status === 'stopped') wlocUi.setState(status, 'notice', _('Stopped'));
                else if (operation.status === 'done' && operation.updated === true && result.post_check_error)
                    wlocUi.setState(status, 'warn', _('Updated') + ' · ' + result.post_check_error);
                else if (result.check_ok === false && result.last_check_error)
                    wlocUi.setState(status, 'error', result.last_check_error);
                else setIdle(software.updateAvailable, _('Ready'));
                update.disabled = software.updateLocked;
                stop.disabled = true;
            }
            return result;
        }

        function refresh() {
            if (!pageVisible) return Promise.resolve();
            return callSoftwareStatus().then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(wlocUi.errorMessage(result, _('Unable to read software update status.')));
                applySoftware(result);
                return result;
            }).catch(function(error) {
                if (!software.updateLocked)
                    wlocUi.setState(status, 'error', wlocUi.errorMessage(error, _('Unable to read software update status.')));
                return false;
            });
        }

        function delay(milliseconds) {
            return new Promise(function(resolve) {
                window.setTimeout(resolve, milliseconds);
            });
        }

        function reconcileSoftware(previousStarted, previousFinished, attempt) {
            if (!pageVisible) return Promise.resolve(false);
            return delay(SOFTWARE_RECONCILE_DELAY).then(function() {
                return callSoftwareStatus();
            }).then(function(result) {
                if (!result || result.ok !== true) return false;
                var operation = result.operation || {};
                var started = Number(operation.started || 0);
                var finished = Number(operation.finished || 0);
                var active = activeStatus(operation.status);
                var changed = (started > 0 && started !== previousStarted) || (finished > 0 && finished !== previousFinished);
                if (!active && (!terminalStatus(operation.status) || !changed)) return false;
                applySoftware(result);
                return true;
            }).catch(function() {
                return false;
            }).then(function(recovered) {
                if (recovered || attempt + 1 >= SOFTWARE_RECONCILE_ATTEMPTS) return recovered;
                return reconcileSoftware(previousStarted, previousFinished, attempt + 1);
            });
        }

        function runSoftwareUpdate() {
            var fallback = _('Unable to update WLOC.');
            var previousStarted = software.operationStarted;
            var previousFinished = software.operationFinished;
            software.updateLocked = true;
            update.disabled = true;
            stop.disabled = true;
            setMessage('notice', '');
            wlocUi.setState(status, 'notice', _('Checking for updates...'));

            return callSoftwareInstall().then(function(result) {
                return { result: wlocUi.requireOk(result, fallback), recovered: false };
            }, function(error) {
                return reconcileSoftware(previousStarted, previousFinished, 0).then(function(recovered) {
                    if (recovered) return { result: null, recovered: true };
                    throw error;
                });
            }).then(function(outcome) {
                if (!outcome.recovered) applySoftware(outcome.result);
                return refresh();
            }).catch(function(error) {
                software.updateLocked = false;
                update.disabled = false;
                stop.disabled = true;
                setMessage('error', wlocUi.errorMessage(error, fallback));
                return refresh();
            });
        }

        function stopSoftwareUpdate() {
            if (!software.updateLocked) return Promise.resolve();
            stop.disabled = true;
            wlocUi.setState(status, 'notice', _('Stopping...'));
            return callSoftwareStop().then(function(result) {
                return wlocUi.requireOk(result, _('Unable to stop WLOC update.'));
            }).then(applySoftware).then(refresh).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to stop WLOC update.')));
                return refresh();
            });
        }

        update.addEventListener('click', ui.createHandlerFn(update, runSoftwareUpdate));
        stop.addEventListener('click', ui.createHandlerFn(stop, stopSoftwareUpdate));
        history.hidden = true;

        if (initial && initial.ok === true) applySoftware(initial);
        else wlocUi.setState(status, 'error', wlocUi.errorMessage(initial, _('Unable to read software update status.')));

        poll.add(refresh, 2);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refresh);
        }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Check and install WLOC package updates.')),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'class': 'cbi-section-node' }, [
                    E('h4', {}, _('WLOC')),
                    valueRow(_('Version'), version),
                    valueRow(_('Status'), status),
                    valueRow(_('Actions'), E('span', {}, [ update, ' ', stop ])),
                    history
                ]),
                message
            ])
        ]);
    }
});
