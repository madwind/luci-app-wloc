'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';

var callSoftwareStatus = rpc.declare({ object: 'luci.wloc.update', method: 'status', expect: { '': {} }, reject: true });
var callSoftwareInstall = rpc.declare({ object: 'luci.wloc.update', method: 'install', expect: { '': {} }, reject: true });
var callSoftwareStop = rpc.declare({ object: 'luci.wloc.update', method: 'stop', expect: { '': {} }, reject: true });
var callGeoStatus = rpc.declare({ object: 'luci.wloc.geo', method: 'status', expect: { '': {} }, reject: true });
var callGeoUpdate = rpc.declare({ object: 'luci.wloc.geo', method: 'update', expect: { '': {} }, reject: true });
var callGeoStop = rpc.declare({ object: 'luci.wloc.geo', method: 'stop', expect: { '': {} }, reject: true });
var callGeoAutoStatus = rpc.declare({ object: 'luci.wloc.geoauto', method: 'status', expect: { '': {} }, reject: true });
var callGeoAutoSet = rpc.declare({ object: 'luci.wloc.geoauto', method: 'set_auto', params: [ 'enabled' ], expect: { '': {} }, reject: true });

var SOFTWARE_RECONCILE_ATTEMPTS = 5;
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

function progressText(result) {
    var downloaded = Number(result && result.downloaded || 0);
    return downloaded > 0 ? _('Downloading · %s').format(wlocUi.formatBytes(downloaded)) : _('Downloading...');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callSoftwareStatus(), { ok: false, error: _('Unable to read software update status.') }),
            L.resolveDefault(callGeoStatus(), { ok: false, error: _('Unable to read GeoIP update status.') }),
            L.resolveDefault(callGeoAutoStatus(), { ok: false, error: _('Unable to read automatic GeoIP update setting.') })
        ]);
    },

    render: function(data) {
        document.title = _('WLOC | Updates');

        var softwareInitial = data && data[0] || {};
        var geoInitial = data && data[1] || {};
        var autoInitial = data && data[2] || {};
        var rows = {};
        var pageVisible = true;
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var componentGrid = E('div', { 'class': 'wloc-update-grid' });

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function createRow(kind, label, automatic) {
            var version = E('span');
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var history = E('div', { 'class': 'cbi-section-descr' });
            var update = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Update'));
            var stop = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop'));
            var row = {
                kind: kind,
                version: version,
                status: status,
                history: history,
                update: update,
                stop: stop,
                installedVersion: '',
                latestVersion: '',
                checkedAt: 0,
                lastUpdateAt: 0,
                updateAvailable: null,
                operationStarted: 0,
                operationFinished: 0
            };
            var children = [
                E('h4', {}, label),
                valueRow(_('Version'), version),
                valueRow(_('Status'), status)
            ];
            history.hidden = true;
            if (automatic) {
                row.auto = E('input', { 'type': 'checkbox', 'disabled': '' });
                children.push(valueRow(_('Automatic update'), E('label', {}, [ row.auto, ' ', _('Weekly') ])));
            }
            children.push(valueRow(_('Actions'), E('span', {}, [ update, ' ', stop ])));
            children.push(history);
            row.root = E('div', { 'class': 'cbi-section-node' }, children);
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
            if (row.checkedAt) values.push(_('Last check: %s').format(formatTimestamp(row.checkedAt)));
            if (row.lastUpdateAt) values.push(_('Last update: %s').format(formatTimestamp(row.lastUpdateAt)));
            wlocUi.setText(row.history, values.join(' · '));
            row.history.hidden = values.length === 0;
        }

        function setIdle(row, available, fallback) {
            if (available === true) wlocUi.setState(row.status, 'warn', _('Update available'));
            else if (available === false) wlocUi.setState(row.status, 'ok', _('Up to date'));
            else wlocUi.setState(row.status, 'notice', fallback || _('Ready'));
        }

        var softwareRow = createRow('software', _('WLOC'), false);
        var geoRow = createRow('geoip', _('GeoIP'), true);
        componentGrid.appendChild(softwareRow.root);
        componentGrid.appendChild(geoRow.root);

        function applySoftware(result) {
            result = result || {};
            var operation = result.operation || {};
            if (result.installed_version) softwareRow.installedVersion = String(result.installed_version);
            if (result.latest_version) softwareRow.latestVersion = String(result.latest_version);
            if (result.update_available !== undefined && result.update_available !== null) softwareRow.updateAvailable = result.update_available === true;
            if (operation.started != null) softwareRow.operationStarted = Number(operation.started) || 0;
            if (operation.finished != null) softwareRow.operationFinished = Number(operation.finished) || 0;
            setMeta(softwareRow, result.checked, result.last_update);
            renderVersion(softwareRow);

            if ([ 'starting', 'running', 'stopping' ].indexOf(operation.status) >= 0) {
                wlocUi.setState(softwareRow.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : softwarePhase(operation));
                softwareRow.update.disabled = true;
                softwareRow.stop.disabled = operation.phase === 'installing' || operation.status === 'stopping';
            } else {
                if (operation.status === 'failed') wlocUi.setState(softwareRow.status, 'error', operation.error || _('Update failed'));
                else if (operation.status === 'stopped') wlocUi.setState(softwareRow.status, 'notice', _('Stopped'));
                else if (result.check_ok === false && result.last_check_error) wlocUi.setState(softwareRow.status, 'error', result.last_check_error);
                else setIdle(softwareRow, softwareRow.updateAvailable, _('Ready'));
                softwareRow.update.disabled = false;
                softwareRow.stop.disabled = true;
            }
            return result;
        }

        function applyGeo(result) {
            result = result || {};
            if (result.ready === false) {
                geoRow.installedVersion = '';
                geoRow.updateAvailable = null;
            } else {
                geoRow.installedVersion = result.local_version || (result.ready === true ? _('Installed') : geoRow.installedVersion || '');
                if (result.update_known === true || result.update_known === 1)
                    geoRow.updateAvailable = result.update_available === true;
                else
                    geoRow.updateAvailable = null;
            }
            geoRow.latestVersion = result.latest_version || geoRow.latestVersion || '';
            setMeta(geoRow, result.checked, result.last_update);
            renderVersion(geoRow);

            if ([ 'starting', 'running', 'stopping' ].indexOf(result.status) >= 0) {
                wlocUi.setState(geoRow.status, 'notice', result.status === 'stopping' ? _('Stopping...') : progressText(result));
                geoRow.update.disabled = true;
                geoRow.stop.disabled = result.status === 'stopping';
            } else {
                if (result.status === 'failed') wlocUi.setState(geoRow.status, 'error', result.error || _('Update failed'));
                else if (result.status === 'stopped') wlocUi.setState(geoRow.status, 'notice', _('Stopped'));
                else if (result.check_ok === false && result.last_check_error) wlocUi.setState(geoRow.status, 'error', result.last_check_error);
                else setIdle(geoRow, geoRow.updateAvailable, result.ready === true ? _('Ready') : _('Missing'));
                geoRow.update.disabled = false;
                geoRow.stop.disabled = true;
            }
            return result;
        }

        function applyAuto(result) {
            if (!result || result.ok !== true) throw new Error(wlocUi.errorMessage(result, _('Unable to read automatic GeoIP update setting.')));
            geoRow.auto.checked = result.enabled === true || result.enabled === 1;
            geoRow.auto.disabled = false;
            return result;
        }

        function refresh() {
            if (!pageVisible) return Promise.resolve();
            return Promise.all([
                callSoftwareStatus().then(applySoftware).catch(function(error) { wlocUi.setState(softwareRow.status, 'error', wlocUi.errorMessage(error, _('Unable to read software update status.'))); }),
                callGeoStatus().then(applyGeo).catch(function(error) { wlocUi.setState(geoRow.status, 'error', wlocUi.errorMessage(error, _('Unable to read GeoIP update status.'))); })
            ]);
        }

        function delay(milliseconds) {
            return new Promise(function(resolve) {
                window.setTimeout(resolve, milliseconds);
            });
        }

        function reconcileSoftwareStart(previousStarted, previousFinished, attempt) {
            if (!pageVisible)
                return Promise.resolve(false);

            return delay(SOFTWARE_RECONCILE_DELAY).then(function() {
                return callSoftwareStatus();
            }).then(function(result) {
                if (!result || result.ok !== true)
                    return false;

                var operation = result.operation || {};
                var started = Number(operation.started || 0);
                var finished = Number(operation.finished || 0);
                var active = [ 'starting', 'running', 'stopping' ].indexOf(operation.status) >= 0;
                var changed = (started > 0 && started !== previousStarted) || (finished > 0 && finished !== previousFinished);
                var known = active || [ 'done', 'failed', 'stopped' ].indexOf(operation.status) >= 0;
                if (!known || (!active && !changed))
                    return false;

                applySoftware(result);
                return true;
            }).catch(function() {
                return false;
            }).then(function(recovered) {
                if (recovered || attempt + 1 >= SOFTWARE_RECONCILE_ATTEMPTS)
                    return recovered;
                return reconcileSoftwareStart(previousStarted, previousFinished, attempt + 1);
            });
        }

        function runSoftwareUpdate() {
            var fallback = _('Unable to update WLOC.');
            var previousStarted = softwareRow.operationStarted;
            var previousFinished = softwareRow.operationFinished;
            softwareRow.update.disabled = true;
            softwareRow.stop.disabled = true;
            wlocUi.setState(softwareRow.status, 'notice', _('Checking for updates...'));

            return callSoftwareInstall().then(function(result) {
                return { result: wlocUi.requireOk(result, fallback), recovered: false };
            }, function(error) {
                return reconcileSoftwareStart(previousStarted, previousFinished, 0).then(function(recovered) {
                    if (recovered)
                        return { result: null, recovered: true };
                    throw error;
                });
            }).then(function(outcome) {
                if (!outcome.recovered)
                    applySoftware(outcome.result);
                return refresh();
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, fallback));
                softwareRow.update.disabled = false;
                return refresh();
            });
        }

        function runUpdate(row, request, apply, fallback) {
            row.update.disabled = true;
            row.stop.disabled = true;
            wlocUi.setState(row.status, 'notice', _('Checking for updates...'));
            return request().then(function(result) { return wlocUi.requireOk(result, fallback); }).then(apply).then(function() { return refresh(); }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, fallback));
                row.update.disabled = false;
                return refresh();
            });
        }

        function runStop(row, request, apply, fallback) {
            row.stop.disabled = true;
            wlocUi.setState(row.status, 'notice', _('Stopping...'));
            return request().then(function(result) { return wlocUi.requireOk(result, fallback); }).then(apply).then(function() { return refresh(); }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, fallback));
                return refresh();
            });
        }

        softwareRow.update.addEventListener('click', ui.createHandlerFn(softwareRow.update, function() {
            return runSoftwareUpdate();
        }));
        softwareRow.stop.addEventListener('click', ui.createHandlerFn(softwareRow.stop, function() {
            return runStop(softwareRow, callSoftwareStop, applySoftware, _('Unable to stop WLOC update.'));
        }));
        geoRow.update.addEventListener('click', ui.createHandlerFn(geoRow.update, function() {
            return runUpdate(geoRow, callGeoUpdate, applyGeo, _('Unable to update GeoIP.'));
        }));
        geoRow.stop.addEventListener('click', ui.createHandlerFn(geoRow.stop, function() {
            return runStop(geoRow, callGeoStop, applyGeo, _('Unable to stop GeoIP update.'));
        }));
        geoRow.auto.addEventListener('change', function() {
            var desired = geoRow.auto.checked;
            geoRow.auto.disabled = true;
            callGeoAutoSet(desired ? 1 : 0).then(function(result) { return wlocUi.requireOk(result, _('Unable to change automatic GeoIP update setting.')); }).then(applyAuto).catch(function(error) {
                geoRow.auto.checked = !desired;
                geoRow.auto.disabled = false;
                setMessage('error', wlocUi.errorMessage(error, _('Unable to change automatic GeoIP update setting.')));
            });
        });

        if (softwareInitial && softwareInitial.ok === true) applySoftware(softwareInitial);
        else wlocUi.setState(softwareRow.status, 'error', wlocUi.errorMessage(softwareInitial, _('Unable to read software update status.')));
        if (geoInitial && geoInitial.ok === true) applyGeo(geoInitial);
        else wlocUi.setState(geoRow.status, 'error', wlocUi.errorMessage(geoInitial, _('Unable to read GeoIP update status.')));
        if (autoInitial && autoInitial.ok === true) applyAuto(autoInitial);
        else setMessage('error', wlocUi.errorMessage(autoInitial, _('Unable to read automatic GeoIP update setting.')));

        poll.add(refresh, 2);
        window.addEventListener('pagehide', function() { pageVisible = false; poll.remove(refresh); }, { once: true });

        var layoutStyle = E('style', { 'type': 'text/css' }, [
            '#wloc-updates .wloc-update-grid {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1em;}' +
            '#wloc-updates .wloc-update-grid > .cbi-section-node {min-width:0;}' +
            '@media (max-width:800px) {#wloc-updates .wloc-update-grid {grid-template-columns:1fr;}}'
        ]);

        return E('div', { 'class': 'cbi-map', 'id': 'wloc-updates' }, [
            layoutStyle,
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Update WLOC and GeoIP. Each Update checks for a newer version first. Update sources and local paths are configured in Settings.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Components')),
                message,
                componentGrid
            ])
        ]);
    }
});
