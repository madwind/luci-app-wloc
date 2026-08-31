'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';

var callStatus = rpc.declare({
    object: 'luci.wloc.update',
    method: 'status',
    expect: { '': {} },
    reject: true
});

var callCheck = rpc.declare({
    object: 'luci.wloc.update',
    method: 'check',
    expect: { '': {} },
    reject: true
});

var callInstall = rpc.declare({
    object: 'luci.wloc.update',
    method: 'install',
    expect: { '': {} },
    reject: true
});

var callStop = rpc.declare({
    object: 'luci.wloc.update',
    method: 'stop',
    expect: { '': {} },
    reject: true
});

function phaseText(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'checking') return _('Checking...');
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    if (phase === 'starting') return _('Starting update...');
    return _('Updating...');
}

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds)
        return '—';
    try {
        return new Date(seconds * 1000).toLocaleString();
    } catch (e) {
        return '—';
    }
}

function valueRow(label, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return L.resolveDefault(callStatus(), {
            ok: false,
            error: _('Unable to read software update status.')
        });
    },

    render: function(initial) {
        document.title = _('WLOC | Updates');

        var version = E('span');
        var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
        var history = E('div', { 'class': 'cbi-section-descr' });
        var check = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Check'));
        var update = E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'type': 'button'
        }, _('Update'));
        var stop = E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'type': 'button',
            'disabled': ''
        }, _('Stop'));
        var installedVersion = '';
        var latestVersion = '';
        var checkedAt = 0;
        var lastUpdateAt = 0;
        var updateAvailable = null;

        history.hidden = true;

        function renderVersion() {
            version.replaceChildren(E('code', {}, installedVersion || _('Unknown')));
            if (latestVersion && latestVersion !== installedVersion) {
                version.appendChild(document.createTextNode(' → '));
                version.appendChild(E('code', {}, latestVersion));
            }
        }

        function renderHistory() {
            var values = [];
            if (checkedAt)
                values.push(_('Last check: %s').format(formatTimestamp(checkedAt)));
            if (lastUpdateAt)
                values.push(_('Last update: %s').format(formatTimestamp(lastUpdateAt)));
            wlocUi.setText(history, values.join(' · '));
            history.hidden = values.length === 0;
        }

        function canStop(operation) {
            if (!operation || [ 'starting', 'running', 'stopping' ].indexOf(operation.status) < 0)
                return false;
            return operation.phase !== 'installing' && operation.status !== 'stopping';
        }

        function apply(result) {
            result = result || {};
            var operation = result.operation || {};

            if (result.installed_version)
                installedVersion = String(result.installed_version);
            if (result.latest_version)
                latestVersion = String(result.latest_version);
            if (result.checked != null)
                checkedAt = Number(result.checked) || 0;
            if (result.last_update != null)
                lastUpdateAt = Number(result.last_update) || 0;
            if (result.update_available !== undefined && result.update_available !== null)
                updateAvailable = result.update_available === true;

            renderVersion();
            renderHistory();

            if (operation.status === 'starting' || operation.status === 'running' || operation.status === 'stopping') {
                wlocUi.setState(status, 'notice', operation.status === 'stopping' ? _('Stopping...') : phaseText(operation));
                check.disabled = true;
                update.disabled = true;
                stop.disabled = !canStop(operation);
                return result;
            }

            if (operation.status === 'failed') {
                wlocUi.setState(status, 'error', operation.error || _('Update failed'));
            } else if (operation.status === 'stopped') {
                wlocUi.setState(status, 'notice', _('Stopped'));
            } else if (operation.status === 'done' && operation.updated === true && result.post_check_error) {
                wlocUi.setState(status, 'warn', _('Updated · verification check failed'));
            } else if (result.check_ok === false && result.last_check_error) {
                wlocUi.setState(status, 'error', result.last_check_error);
            } else if (updateAvailable === true) {
                wlocUi.setState(status, 'warn', _('Update available'));
            } else if (updateAvailable === false) {
                wlocUi.setState(status, 'ok', _('Up to date'));
            } else {
                wlocUi.setState(status, 'notice', checkedAt ? _('Checked') : _('Not checked'));
            }

            check.disabled = false;
            update.disabled = updateAvailable === false;
            stop.disabled = true;
            return result;
        }

        function refresh() {
            return callStatus().then(function(result) {
                return wlocUi.requireOk(result, _('Unable to read software update status.'));
            }).then(apply).catch(function(error) {
                wlocUi.notifyFatal(error, _('Unable to read software update status.'));
            });
        }

        function runAction(message, request, fallback) {
            check.disabled = true;
            update.disabled = true;
            stop.disabled = true;
            wlocUi.setState(status, 'notice', message);
            return request().then(function(result) {
                return wlocUi.requireOk(result, fallback);
            }).then(function() {
                return refresh();
            }).catch(function(error) {
                wlocUi.notifyFatal(error, fallback);
                return refresh();
            });
        }

        check.addEventListener('click', ui.createHandlerFn(check, function() {
            return runAction(_('Checking...'), callCheck, _('WLOC update check failed.'));
        }));

        update.addEventListener('click', ui.createHandlerFn(update, function() {
            return runAction(_('Starting update...'), callInstall, _('Unable to start WLOC update.'));
        }));

        stop.addEventListener('click', ui.createHandlerFn(stop, function() {
            return runAction(_('Stopping...'), callStop, _('Unable to stop WLOC update.'));
        }));

        if (initial && initial.ok === true)
            apply(initial);
        else
            wlocUi.setState(status, 'error', wlocUi.errorMessage(initial, _('Unable to read software update status.')));

        poll.add(refresh, 2);

        return E('div', {}, [
            E('h2', {}, _('WLOC Updates')),
            E('div', { 'class': 'cbi-section-descr' }, _('Check and install the latest SHA256-verified WLOC package for this OpenWrt target.')),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'class': 'cbi-section-node' }, [
                    E('h4', {}, _('WLOC')),
                    valueRow(_('Version'), version),
                    valueRow(_('Status'), status),
                    valueRow(_('Actions'), E('span', {}, [ check, ' ', update, ' ', stop ])),
                    history
                ])
            ])
        ]);
    }
});
