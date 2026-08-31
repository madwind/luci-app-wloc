'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'luci.wloc.update', method: 'status', expect: { '': {} }, reject: true });
var callCheck = rpc.declare({ object: 'luci.wloc.update', method: 'check', expect: { '': {} }, reject: true });
var callInstall = rpc.declare({ object: 'luci.wloc.update', method: 'install', expect: { '': {} }, reject: true });

function setText(node, value) {
    node.textContent = value == null || value === '' ? '—' : String(value);
}

function statusText(result) {
    if (!result)
        return _('Unknown');
    if (result.status === 'downloading')
        return _('Downloading...');
    if (result.status === 'installing')
        return _('Installing...');
    if (result.status === 'failed')
        return result.error || _('Update failed');
    if (result.update_available === true)
        return _('Update available');
    if (result.update_available === false && result.latest_version)
        return _('Up to date');
    return result.checked ? _('Checked') : _('Not checked');
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
        return L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read update status.') });
    },

    render: function(initial) {
        var installed = E('code');
        var latest = E('code');
        var state = E('span', { 'aria-live': 'polite' });
        var check = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button' }, _('Check for updates'));
        var update = E('button', { 'class': 'cbi-button cbi-button-apply', 'type': 'button' }, _('Update'));

        function apply(result) {
            result = result || {};
            setText(installed, result.installed_version);
            setText(latest, result.latest_version);
            setText(state, statusText(result));
            update.disabled = result.update_available !== true;
            check.disabled = result.status === 'downloading' || result.status === 'installing';
            return result;
        }

        function failed(error) {
            ui.addNotification(null, E('p', {}, error && error.message ? error.message : String(error)), 'error');
        }

        check.addEventListener('click', ui.createHandlerFn(check, function() {
            check.disabled = true;
            update.disabled = true;
            setText(state, _('Checking...'));
            return callCheck().then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(result && result.error || _('Update check failed.'));
                apply(result);
            }).catch(failed).finally(function() {
                check.disabled = false;
            });
        }));

        update.addEventListener('click', ui.createHandlerFn(update, function() {
            check.disabled = true;
            update.disabled = true;
            setText(state, _('Updating...'));
            return callInstall().then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(result && result.error || _('Update failed.'));
                apply(result);
                if (result.status === 'done')
                    ui.addNotification(null, E('p', {}, _('WLOC was updated successfully. Reload this page to use the new LuCI files.')), 'info');
            }).catch(failed).finally(function() {
                check.disabled = false;
            });
        }));

        apply(initial);

        return E('div', {}, [
            E('h2', {}, _('WLOC Updates')),
            E('div', { 'class': 'cbi-section-descr' }, _('Check the latest GitHub release for this OpenWrt target and install the matching SHA256-verified APK.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Software')),
                valueRow(_('Installed version'), installed),
                valueRow(_('Latest version'), latest),
                valueRow(_('Status'), state),
                valueRow(_('Actions'), E('span', {}, [ check, ' ', update ]))
            ])
        ]);
    }
});
