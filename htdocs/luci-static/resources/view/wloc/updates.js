'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';

var callSoftwareStatus = rpc.declare({ object: 'luci.wloc.update', method: 'status', expect: { '': {} }, reject: true });
var callSoftwareCheck = rpc.declare({ object: 'luci.wloc.update', method: 'check', expect: { '': {} }, reject: true });
var callSoftwareInstall = rpc.declare({ object: 'luci.wloc.update', method: 'install', expect: { '': {} }, reject: true });
var callSoftwareStop = rpc.declare({ object: 'luci.wloc.update', method: 'stop', expect: { '': {} }, reject: true });
var callGeoStatus = rpc.declare({ object: 'luci.wloc.geo', method: 'status', expect: { '': {} }, reject: true });
var callGeoCheck = rpc.declare({ object: 'luci.wloc.geo', method: 'check', expect: { '': {} }, reject: true });
var callGeoUpdate = rpc.declare({ object: 'luci.wloc.geo', method: 'update', expect: { '': {} }, reject: true });
var callGeoStop = rpc.declare({ object: 'luci.wloc.geo', method: 'stop', expect: { '': {} }, reject: true });

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

function softwarePhase(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'checking') return _('Checking...');
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    if (phase === 'starting') return _('Starting update...');
    return _('Updating...');
}

function progressText(result) {
    var downloaded = Number(result && result.downloaded || 0);
    return downloaded > 0
        ? _('Downloading · %s').format(wlocUi.formatBytes(downloaded))
        : _('Downloading...');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callSoftwareStatus(), { ok: false, error: _('Unable to read software update status.') }),
            L.resolveDefault(callGeoStatus(), { ok: false, error: _('Unable to read GeoIP update status.') })
        ]);
    },

    render: function(data) {
        document.title = _('WLOC | Updates');

        var softwareInitial = data && data[0] || {};
        var geoInitial = data && data[1] || {};
        var rows = {};
        var pageVisible = true;
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function createRow(kind, label) {
            var version = E('span');
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var history = E('div', { 'class': 'cbi-section-descr' });
            var check = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Check'));
            var update = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Update'));
            var stop = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop'));
            var row = {
                kind: kind,
                version: version,
                status: status,
                history: history,
                check: check,
                update: update,
                stop: stop,
                installedVersion: '',
                latestVersion: '',
                checkedAt: 0,
                lastUpdateAt: 0,
                updateAvailable: null
            };
            history.hidden = true;
            row.root = E('div', { 'class': 'cbi-section-node' }, [
                E('h4', {}, label),
                valueRow(_('Version'), version),
                valueRow(_('Status'), status),
                valueRow(_('Actions'), E('span', {}, [ check, ' ', update, ' ', stop ])),
                history
            ]);
            rows[kind] = row;
            return row;
        }

        function renderVersion(row) {
            row.version.replaceChildren(E('code', {}, row.installedVersion || _('Unknown')));
            if (row.latestVersion && row.latestVersion !== row.installedVersion) {
                row.version.appendChild(document.createTextNode(' → '));
                row.version.appendChild(E('code', {}, row.latestVersion));
            }
        }

        function setMeta(row, checked, lastUpdate) {
            if (checked != null) row.checkedAt = Number(checked) || 0;
            if (lastUpdate != null) row.lastUpdateAt = Number(lastUpdate) || 0;
            var values = [];
            if (row.checkedAt)
                values.push(_('Last check: %s').format(formatTimestamp(row.checkedAt)));
            if (row.lastUpdateAt)
                values.push(_('Last update: %s').format(formatTimestamp(row.lastUpdateAt)));
            wlocUi.setText(row.history, values.join(' · '));
            row.history.hidden = values.length === 0;
        }

        function setIdle(row, available, fallback) {
            if (available === true)
                wlocUi.setState(row.status, 'warn', _('Update available'));
            else if (available === false)
                wlocUi.setState(row.status, 'ok', _('Up to date'));
            else
                wlocUi.setState(row.status, 'notice', fallback || _('Not checked'));
        }

        var softwareRow = createRow('software', _('WLOC'));
        var geoRow = createRow('geoip', _('GeoIP'));

        function applySoftware(result) {
            result = result || {};
            var operation = result.operation || {};
            if (result.installed_version) softwareRow.installedVersion = String(result.installed_version);
            if (result.latest_version) softwareRow.latestVersion = String(result.latest_version);
            if (result.update_available !== undefined && result.update_available !== null)
                softwareRow.updateAvailable = result.update_available === true;
            setMeta(softwareRow, result.checked, result.last_update);
            renderVersion(softwareRow);

            if ([ 'starting', 'running', 'stopping' ].indexOf(operation.status) >= 0) {
                wlocUi.setState(softwareRow.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : softwarePhase(operation));
                softwareRow.check.disabled = true;
                softwareRow.update.disabled = true;
                softwareRow.stop.disabled = operation.phase === 'installing' || operation.status === 'stopping';
            } else {
                if (operation.status === 'failed')
                    wlocUi.setState(softwareRow.status, 'error', operation.error || _('Update failed'));
                else if (operation.status === 'stopped')
                    wlocUi.setState(softwareRow.status, 'notice', _('Stopped'));
                else if (result.check_ok === false && result.last_check_error)
                    wlocUi.setState(softwareRow.status, 'error', result.last_check_error);
                else
                    setIdle(softwareRow, softwareRow.updateAvailable, result.checked ? null : _('Not checked'));
                softwareRow.check.disabled = false;
                softwareRow.update.disabled = softwareRow.updateAvailable === false;
                softwareRow.stop.disabled = true;
            }
            return result;
        }

        function applyGeo(result) {
            result = result || {};
            geoRow.installedVersion = result.local_version || (result.ready === true ? _('Installed') : '');
            geoRow.latestVersion = result.latest_version || '';
            geoRow.updateAvailable = result.update_known === true || result.update_known === 1
                ? result.update_available === true : null;
            setMeta(geoRow, result.checked, result.last_update);
            renderVersion(geoRow);

            if ([ 'starting', 'running', 'stopping' ].indexOf(result.status) >= 0) {
                wlocUi.setState(geoRow.status, 'notice', result.status === 'stopping' ? _('Stopping...') : progressText(result));
                geoRow.check.disabled = true;
                geoRow.update.disabled = true;
                geoRow.stop.disabled = result.status === 'stopping';
            } else {
                if (result.status === 'failed')
                    wlocUi.setState(geoRow.status, 'error', result.error || _('Update failed'));
                else if (result.status === 'stopped')
                    wlocUi.setState(geoRow.status, 'notice', _('Stopped'));
                else if (result.check_ok === false && result.last_check_error)
                    wlocUi.setState(geoRow.status, 'error', result.last_check_error);
                else if (result.status === 'done')
                    wlocUi.setState(geoRow.status, 'ok', _('Updated'));
                else
                    setIdle(geoRow, geoRow.updateAvailable, result.ready === true ? _('Not checked') : _('Missing'));
                geoRow.check.disabled = false;
                geoRow.update.disabled = geoRow.updateAvailable === false;
                geoRow.stop.disabled = true;
            }
            return result;
        }

        function refresh() {
            if (!pageVisible)
                return Promise.resolve();
            return Promise.all([
                callSoftwareStatus().then(applySoftware).catch(function(error) {
                    wlocUi.setState(softwareRow.status, 'error', wlocUi.errorMessage(error, _('Unable to read software update status.')));
                }),
                callGeoStatus().then(applyGeo).catch(function(error) {
                    wlocUi.setState(geoRow.status, 'error', wlocUi.errorMessage(error, _('Unable to read GeoIP update status.')));
                })
            ]);
        }

        function run(row, text, request, apply, fallback) {
            row.check.disabled = true;
            row.update.disabled = true;
            row.stop.disabled = true;
            wlocUi.setState(row.status, 'notice', text);
            return request().then(function(result) {
                return wlocUi.requireOk(result, fallback);
            }).then(apply).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, fallback));
                return refresh();
            });
        }

        softwareRow.check.addEventListener('click', ui.createHandlerFn(softwareRow.check, function() {
            return run(softwareRow, _('Checking...'), callSoftwareCheck, applySoftware, _('WLOC update check failed.'));
        }));
        softwareRow.update.addEventListener('click', ui.createHandlerFn(softwareRow.update, function() {
            return run(softwareRow, _('Starting update...'), callSoftwareInstall, applySoftware, _('Unable to start WLOC update.'));
        }));
        softwareRow.stop.addEventListener('click', ui.createHandlerFn(softwareRow.stop, function() {
            return run(softwareRow, _('Stopping...'), callSoftwareStop, applySoftware, _('Unable to stop WLOC update.'));
        }));

        geoRow.check.addEventListener('click', ui.createHandlerFn(geoRow.check, function() {
            return run(geoRow, _('Checking...'), callGeoCheck, applyGeo, _('GeoIP update check failed.'));
        }));
        geoRow.update.addEventListener('click', ui.createHandlerFn(geoRow.update, function() {
            return run(geoRow, _('Starting update...'), callGeoUpdate, applyGeo, _('Unable to start GeoIP update.'));
        }));
        geoRow.stop.addEventListener('click', ui.createHandlerFn(geoRow.stop, function() {
            return run(geoRow, _('Stopping...'), callGeoStop, applyGeo, _('Unable to stop GeoIP update.'));
        }));

        if (softwareInitial && softwareInitial.ok === true)
            applySoftware(softwareInitial);
        else
            wlocUi.setState(softwareRow.status, 'error', wlocUi.errorMessage(softwareInitial, _('Unable to read software update status.')));
        if (geoInitial && geoInitial.ok === true)
            applyGeo(geoInitial);
        else
            wlocUi.setState(geoRow.status, 'error', wlocUi.errorMessage(geoInitial, _('Unable to read GeoIP update status.')));

        poll.add(refresh, 2);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refresh);
        }, { once: true });

        return E('div', {}, [
            E('h2', {}, _('WLOC Updates')),
            E('div', { 'class': 'cbi-section-descr' }, _('Check and update WLOC software and the GeoIP database used by nftables macros.')),
            E('div', { 'class': 'cbi-section' }, [ softwareRow.root, geoRow.root ]),
            message
        ]);
    }
});
