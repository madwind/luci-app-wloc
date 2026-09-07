'use strict';
'require view';
'require rpc';
'require uci';
'require wloc.ui as wlocUi';
'require wloc.editor as wlocEditor';
'require wloc.nftformat as wlocNftFormat';

var callRead = rpc.declare({ object: 'luci.wloc.firewall', method: 'read', expect: { '': {} } });
var callRuntime = rpc.declare({ object: 'luci.wloc.firewall', method: 'runtime', expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc.firewall', method: 'save', params: [ 'config' ], expect: { '': {} } });
var callInstall = rpc.declare({ object: 'luci.wloc.firewall', method: 'install', expect: { '': {} }, reject: true });
var callUninstall = rpc.declare({ object: 'luci.wloc.firewall', method: 'uninstall', expect: { '': {} }, reject: true });
var callDefault = rpc.declare({ object: 'luci.wloc.defaults', method: 'firewall', expect: { '': {} } });

function firewallError(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callRead(), { ok: false, error: _('Unable to read nftables rules.') }),
            L.resolveDefault(uci.load('wloc'), null)
        ]);
    },

    render: function(data) {
        document.title = 'OpenWrt | ' + _('Firewall');

        var result = data && data[0] || {};
        var port = String(uci.get('wloc', 'main', 'listen_port') || '61520');
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Not loaded'));
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

        activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function invalidateRuntime() {
            activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));
            wlocUi.setState(runtimeState, 'notice', _('Not loaded'));
        }

        function updateRuntime(next) {
            var active = next && next.firewall_active === true;
            activeEditor.markSaved(next && next.active ? next.active : _('# No WLOC nftables tables are active.\n'));
            wlocUi.setState(runtimeState, active ? 'ok' : 'notice', active ? _('Installed') : _('Not installed'));
            if (editor)
                editor.setInstalled(active);
        }

        function refreshRuntime() {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();
            wlocUi.setState(runtimeState, 'notice', _('Refreshing...'));

            runtimeRequest = callRuntime().then(function(next) {
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
                current.setValue(wlocNftFormat.format(next.config || ''));
                current.focus();
                setMessage('notice', _('Default Firewall template loaded in the editor. Review before saving.'));
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
            setMessage('ok', _('Formatted in the editor. Review before saving.'));
            return Promise.resolve(true);
        }

        function saveFirewall(current) {
            if (!withinLimit(current)) return Promise.resolve(false);

            var value = current.getValue();
            setMessage('notice', _('Saving Firewall file...'));

            return callSave(value).then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('The Firewall file could not be saved.')));
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage('ok', _('Firewall file saved.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('The Firewall file could not be saved.')));
                return false;
            });
        }

        function installFirewall(current) {
            if (current.isDirty()) {
                current.focus();
                setMessage('error', _('Save the Firewall file before installing it.'));
                return Promise.resolve(false);
            }
            setMessage('notice', _('Installing Firewall rules...'));
            return callInstall().then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Firewall rules could not be installed.')));
                invalidateRuntime();
                setMessage('ok', _('Firewall installed.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Firewall rules could not be installed.')));
                return false;
            });
        }

        function uninstallFirewall() {
            setMessage('notice', _('Uninstalling Firewall rules...'));
            return callUninstall().then(function(next) {
                if (!next || next.ok !== true)
                    throw new Error(firewallError(next, _('Firewall rules could not be uninstalled.')));
                invalidateRuntime();
                setMessage('ok', _('Firewall uninstalled.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Firewall rules could not be uninstalled.')));
                return false;
            });
        }

        function toggleFirewall(current, installed) {
            return installed ? uninstallFirewall() : installFirewall(current);
        }

        editor = wlocEditor.create({
            id: 'wloc-firewall-editor',
            label: _('nftables ruleset'),
            minHeight: '32em',
            rows: 32,
            format: formatFirewall,
            loadDefault: loadDefaultFirewall,
            reload: reloadFirewall,
            save: saveFirewall,
            installToggle: toggleFirewall
        });

        if (result && result.ok === true) {
            editor.markSaved(result.config || '');
        } else {
            setMessage('error', wlocUi.errorMessage(result, _('Unable to read the Firewall file.')));
        }

        var refreshButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Refresh'));
        refreshButton.addEventListener('click', function() { refreshRuntime(); });

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, refreshButton ]);

        window.addEventListener('pagehide', function() {
            pageVisible = false;
        }, { once: true });

        refreshRuntime();

        var variablesHelp = E('div', { 'class': 'cbi-section-descr' }, [
            E('div', {}, _('Template variables are rendered automatically when the firewall is installed or refreshed:')),
            E('div', {}, [ E('code', {}, '%port%'), ' = ', E('code', {}, port), ' — ', _('WLOC local transparent-proxy listener port.') ]),
            E('div', {}, [ E('code', {}, '%ap_interfaces%'), ' — ', _('Enabled WLOC AP interfaces inserted into the bridge ingress set.') ]),
            E('div', {}, [ E('code', {}, '%location_ipv4%'), ' / ', E('code', {}, '%location_ipv6%'), ' — ', _('Runtime Apple location target addresses.') ]),
            E('div', {}, [ E('code', {}, '%ap_tproxy_mark_rules%'), ' — ', _('Per-AP profile mark rules inserted into ap_tproxy_marks.') ]),
            E('div', {}, [ E('code', {}, '%ap_tproxy_dispatch_rules%'), ' — ', _('Per-AP TPROXY dispatch rules inserted into ap_tproxy_dispatch.') ]),
            E('div', {}, [ E('code', {}, '%outbound_tproxy_rules%'), ' — ', _('Dispatch rules for WLOC-originated marked sockets inserted into outbound_prerouting.') ]),
            E('div', {}, _('Keep the template jumps from mark_prerouting to ap_tproxy_marks and from transparent_prerouting to ap_tproxy_dispatch so the generated rules are reachable.'))
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit and save the WLOC nftables template. Use the editor toggle to install or uninstall it manually. WLOC automatically installs saved rules when the service starts and removes them when it stops or exits unexpectedly.')),
            E('div', { 'class': 'cbi-section' }, [ variablesHelp, editor.root, message ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
