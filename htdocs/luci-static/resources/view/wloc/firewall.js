'use strict';
'require view';
'require rpc';
'require poll';
'require wloc.ui as wlocUi';
'require wloc.editor as wlocEditor';
'require wloc.nftformat as wlocNftFormat';

var callRead = rpc.declare({ object: 'luci.wloc', method: 'firewall_read', expect: { '': {} } });
var callValidate = rpc.declare({ object: 'luci.wloc', method: 'firewall_validate', params: [ 'config' ], expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc', method: 'firewall_save', params: [ 'expected_applied_hash' ], expect: { '': {} } });
var callApply = rpc.declare({ object: 'luci.wloc', method: 'firewall_apply', params: [ 'config' ], expect: { '': {} } });
var callDefault = rpc.declare({ object: 'luci.wloc.defaults', method: 'firewall', expect: { '': {} } });

var RUNTIME_REFRESH_INTERVAL = 10;

function firewallError(result, fallback) {
    var messages = {
        firewall_busy: 'Another firewall operation is already in progress. Please retry.',
        stale_applied_revision: 'The applied firewall configuration changed. Refresh the page before saving.',
        no_applied_snapshot: 'No successfully applied firewall rules are available to save.',
        snapshot_stage_failed: 'The runtime snapshot could not be staged.',
        nft_check_failed: 'The nftables syntax check failed.',
        unsupported_firewall_command: 'Only table bridge wloc and table inet wloc definitions are supported.',
        nft_apply_failed: 'The nftables transaction failed.',
        snapshot_promote_failed: 'The runtime snapshot could not be committed.',
        persistent_save_failed: 'The applied firewall rules could not be saved persistently.'
    };
    var code = result && result.error_code;
    var message = code && messages[code] ? _(messages[code]) :
        !code && result && result.error ? _(result.error) : '';

    return [ message, result && result.detail && result.detail !== message ? result.detail : '' ]
        .filter(Boolean).join(': ') || fallback;
}

return view.extend({
    load: function() {
        return L.resolveDefault(callRead(), { ok: false, error: _('Unable to read nftables rules.') });
    },

    render: function(result) {
        document.title = 'OpenWrt | ' + _('Firewall');

        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Auto refresh every 10 seconds'));
        var runtimeRequest = null;
        var pageVisible = true;
        var appliedRevision = String(result && result.applied_hash || '');
        var editor;
        var activeEditor = wlocEditor.create({
            id: 'wloc-firewall-runtime',
            label: _('Current runtime rules'),
            minHeight: '18em',
            rows: 18,
            readonly: true
        });

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function updateRuntime(next) {
            appliedRevision = String(next && next.applied_hash || appliedRevision || '');
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No WLOC nftables tables are active.\n'));
            wlocUi.setState(runtimeState, next && next.recovering === true ? 'warn' : 'ok',
                next && next.recovering === true
                    ? (next.warning || _('Recovering · auto refresh every 10 seconds'))
                    : _('Live · auto refresh every 10 seconds'));
        }

        function refreshRuntime(manual) {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            if (manual)
                wlocUi.setState(runtimeState, 'notice', _('Refreshing...'));

            runtimeRequest = callRead().then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to read runtime nftables rules.')));
                updateRuntime(next);
                return next;
            }).catch(function(error) {
                wlocUi.setState(runtimeState, 'warn', wlocUi.errorMessage(error, _('Runtime refresh failed.')));
                return false;
            }).then(function(next) {
                runtimeRequest = null;
                return next;
            });

            return runtimeRequest;
        }

        function reloadFirewall(current) {
            setMessage('notice', _('Reloading the saved Firewall file...'));
            return callRead().then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to read the Firewall file.')));
                current.markSaved(next.config || '');
                updateRuntime(next);
                setMessage('ok', _('Saved Firewall file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to read the Firewall file.')));
                return false;
            });
        }

        function loadDefaultFirewall(current) {
            setMessage('notice', _('Loading default Firewall template...'));
            return callDefault().then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to read the default Firewall template.')));
                current.setValue(next.config || '');
                current.focus();
                setMessage('notice', _('Default Firewall template loaded in the editor. Review before applying.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to read the default Firewall template.')));
                return false;
            });
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;
            current.focus();
            setMessage('error', _('The Firewall file is larger than 32 KiB.'));
            return false;
        }

        function formatFirewall(current) {
            current.setValue(wlocNftFormat.format(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before applying.'));
            return Promise.resolve(true);
        }

        function checkFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);
            setMessage('notice', _('Checking Firewall syntax...'));
            return callValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(firewallError(next, _('Firewall syntax check failed.')));
                setMessage('ok', _('Firewall syntax check passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Firewall syntax check failed.')));
                return false;
            });
        }

        function applyFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);
            setMessage('notice', _('Applying Firewall rules to runtime...'));
            return callApply(current.getValue()).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to apply Firewall rules.')));
                updateRuntime(next);
                setMessage(next.recovering === true ? 'warn' : 'ok', next.recovering === true
                    ? (next.warning || _('Applied to runtime; dynamic state is recovering automatically.'))
                    : _('Applied to runtime; the saved file was not changed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to apply Firewall rules.')));
                return false;
            });
        }

        function applySaveFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var value = current.getValue();
            var applied = false;
            setMessage('notice', _('Applying Firewall rules and saving the file...'));

            return callApply(value).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to apply Firewall rules.')));
                applied = true;
                updateRuntime(next);
                if (!appliedRevision)
                    throw new Error(_('No applied Firewall revision is available to save.'));
                return callSave(appliedRevision);
            }).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('The Firewall file could not be saved.')));
                appliedRevision = String(next.applied_hash || appliedRevision);
                current.markSaved(value);
                setMessage('ok', _('Applied to runtime and saved to the Firewall file.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, applied
                    ? _('Applied to runtime, but the Firewall file could not be saved.')
                    : _('Unable to apply Firewall rules.')));
                return false;
            });
        }

        editor = wlocEditor.create({
            id: 'wloc-firewall-editor',
            label: _('nftables ruleset'),
            minHeight: '32em',
            rows: 32,
            format: formatFirewall,
            check: checkFirewall,
            loadDefault: loadDefaultFirewall,
            reload: reloadFirewall,
            apply: applyFirewall,
            applySave: applySaveFirewall
        });

        if (result && result.ok === true) {
            editor.markSaved(result.config || '');
            updateRuntime(result);
        } else {
            setMessage('error', wlocUi.errorMessage(result, _('Unable to read the Firewall file.')));
        }

        var refreshButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Refresh'));
        refreshButton.addEventListener('click', function() {
            refreshRuntime(true);
        });

        poll.add(refreshRuntime, RUNTIME_REFRESH_INTERVAL);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshRuntime);
        }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Edit the nftables source. Apply changes temporarily or apply and save them permanently.')),
            E('div', { 'class': 'cbi-section' }, [ editor.root, message ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                E('div', { 'class': 'cbi-section-descr' }, [ runtimeState, ' ', refreshButton ]),
                activeEditor.root
            ])
        ]);
    }
});
