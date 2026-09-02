'use strict';
'require view';
'require rpc';
'require poll';
'require wloc.ui as wlocUi';
'require wloc.editor as wlocEditor';
'require wloc.nftformat as wlocNftFormat';

var callRead = rpc.declare({ object: 'luci.wloc.firewall', method: 'read', expect: { '': {} } });
var callValidate = rpc.declare({ object: 'luci.wloc.firewall', method: 'validate', params: [ 'config' ], expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc.firewall', method: 'save', params: [ 'config' ], expect: { '': {} } });
var callApply = rpc.declare({ object: 'luci.wloc.firewall', method: 'apply', params: [ 'config' ], expect: { '': {} } });
var callDefault = rpc.declare({ object: 'luci.wloc.defaults', method: 'firewall', expect: { '': {} } });

var RUNTIME_REFRESH_INTERVAL = 10;

function firewallError(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
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
            activeEditor.markSaved(next && next.active ? next.active : _('# No WLOC nftables tables are active.\n'));
            wlocUi.setState(runtimeState, next && next.recovering === true ? 'warn' : 'ok',
                next && next.recovering === true
                    ? (next.warning || _('Recovering · auto refresh every 10 seconds'))
                    : _('Live · auto refresh every 10 seconds'));
        }

        function refreshRuntime(manual) {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();
            if (manual) wlocUi.setState(runtimeState, 'notice', _('Refreshing...'));

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
            if (current.withinLimit()) return true;
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
            if (!withinLimit(current)) return Promise.resolve(false);
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
            if (!withinLimit(current)) return Promise.resolve(false);
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
            if (!withinLimit(current)) return Promise.resolve(false);
            var applied = false;
            var value = current.getValue();
            setMessage('notice', _('Applying Firewall rules and saving the file...'));

            return callApply(value).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Unable to apply Firewall rules.')));
                applied = true;
                updateRuntime(next);
                return callSave(value);
            }).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('The Firewall file could not be saved.')));
                current.markSaved(next.config === undefined ? value : next.config);
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
        refreshButton.addEventListener('click', function() { refreshRuntime(true); });

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, refreshButton ]);

        poll.add(refreshRuntime, RUNTIME_REFRESH_INTERVAL);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshRuntime);
        }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit the nftables source. Apply changes temporarily or apply and save them permanently.')),
            E('div', { 'class': 'cbi-section' }, [ editor.root, message ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
