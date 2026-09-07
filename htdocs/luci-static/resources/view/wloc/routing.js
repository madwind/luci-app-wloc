'use strict';
'require view';
'require rpc';
'require ui';
'require wloc.ui as wlocUi';
'require wloc.editor as wlocEditor';

var callRead = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'read',
    expect: { '': {} },
    reject: true
});

var callRuntime = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'runtime',
    expect: { '': {} },
    reject: true
});

var callValidate = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'validate',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callSave = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'save',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callInstall = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'install',
    expect: { '': {} },
    reject: true
});

var callUninstall = rpc.declare({
    object: 'luci.wloc.routing',
    method: 'uninstall',
    expect: { '': {} },
    reject: true
});

var callDefault = rpc.declare({
    object: 'luci.wloc.defaults',
    method: 'routing',
    expect: { '': {} },
    reject: true
});

function routingMessage(result, fallback) {
    return [ result && result.error, result && result.detail ]
        .filter(Boolean).join(': ') || fallback;
}

function validationDetail(result) {
    return routingMessage(result, _('Routing command was rejected.'));
}

function formatRouting(source) {
    var input = String(source || '').replace(/\r\n?/g, '\n').split('\n');
    var output = [];
    var blank = false;

    input.forEach(function(line) {
        var value = line.trim();
        if (!value) {
            if (output.length && !blank) {
                output.push('');
                blank = true;
            }
            return;
        }
        output.push(value);
        blank = false;
    });

    while (output.length && output[output.length - 1] === '')
        output.pop();

    return output.join('\n') + (output.length ? '\n' : '');
}

return view.extend({
    load: function() {
        return L.resolveDefault(callRead(), { ok: false, error: _('Unable to read the Routing file.') });
    },

    render: function(result) {
        document.title = 'OpenWrt | ' + _('Routing');

        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Not loaded'));
        var runtimeRequest = null;
        var pageVisible = true;
        var uninstallButton;
        var editor;
        var activeEditor = wlocEditor.create({
            id: 'wloc-routing-active',
            label: _('Active kernel commands'),
            minHeight: '18em',
            rows: 18,
            readonly: true
        });

        activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));

        function setMessage(state, value) {
            wlocUi.setState(message, state, value);
        }

        function requireOk(next, fallback) {
            if (!next || next.ok !== true)
                throw new Error(routingMessage(next, fallback));
            return next;
        }

        function invalidateRuntime() {
            activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));
            wlocUi.setState(runtimeState, 'notice', _('Not loaded'));
        }

        function updateRuntime(next) {
            var installed = next && next.installed === true;
            var active = next && next.route_active === true;
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No active policy routing commands are installed.\n'));
            wlocUi.setState(runtimeState, installed && active ? 'ok' : installed || active ? 'warn' : 'notice',
                installed ? (active ? _('Installed') : _('Installed, but inactive')) : (active ? _('Active, but not installed') : _('Not installed')));
            if (uninstallButton)
                uninstallButton.disabled = !installed && !active;
        }

        function refreshRuntime() {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            wlocUi.setState(runtimeState, 'notice', _('Refreshing...'));

            runtimeRequest = callRuntime().then(function(next) {
                return requireOk(next, _('Unable to read runtime Routing rules.'));
            }).then(function(next) {
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

        function reloadRouting(current) {
            setMessage('notice', _('Reloading the saved Routing file...'));

            return callRead().then(function(next) {
                return requireOk(next, _('Unable to read the Routing file.'));
            }).then(function(next) {
                current.markSaved(next.config || '');
                setMessage('ok', _('Saved Routing file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to read the Routing file.')));
                return false;
            });
        }

        function loadDefaultRouting(current) {
            setMessage('notice', _('Loading default Routing template...'));

            return callDefault().then(function(next) {
                return requireOk(next, _('Unable to read the default Routing template.'));
            }).then(function(next) {
                current.setValue(formatRouting(next.config || ''));
                current.focus();
                setMessage('notice', _('Default Routing template loaded in the editor. Review before saving.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to read the default Routing template.')));
                return false;
            });
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;

            current.focus();
            setMessage('error', _('The Routing file is larger than 32 KiB.'));
            return false;
        }

        function formatRoutingEditor(current) {
            current.setValue(formatRouting(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before saving.'));
            return Promise.resolve(true);
        }

        function checkRouting(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Checking Routing commands...'));
            return callValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(validationDetail(next));
                setMessage('ok', _('Routing syntax check passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Routing syntax check failed.')));
                return false;
            });
        }

        function saveRouting(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var value = current.getValue();
            setMessage('notice', _('Saving Routing file...'));

            return callSave(value).then(function(next) {
                return requireOk(next, _('The Routing file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage('ok', _('Routing file saved.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('The Routing file could not be saved.')));
                return false;
            });
        }

        function installRouting() {
            if (editor.isDirty()) {
                editor.focus();
                setMessage('error', _('Save the Routing file before installing it.'));
                return Promise.resolve(false);
            }
            setMessage('notice', _('Installing Routing commands...'));
            return callInstall().then(function(next) {
                return requireOk(next, _('Routing commands could not be installed.'));
            }).then(function() {
                invalidateRuntime();
                setMessage('ok', _('Routing installed.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Routing commands could not be installed.')));
                return false;
            });
        }

        function uninstallRouting() {
            setMessage('notice', _('Uninstalling Routing commands...'));
            return callUninstall().then(function(next) {
                return requireOk(next, _('Routing commands could not be uninstalled.'));
            }).then(function() {
                invalidateRuntime();
                setMessage('ok', _('Routing uninstalled.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Routing commands could not be uninstalled.')));
                return false;
            });
        }

        editor = wlocEditor.create({
            id: 'wloc-routing-editor',
            label: _('Policy routing commands'),
            minHeight: '16em',
            rows: 16,
            format: formatRoutingEditor,
            check: checkRouting,
            loadDefault: loadDefaultRouting,
            reload: reloadRouting,
            save: saveRouting
        });

        if (result && result.ok === true) {
            editor.markSaved(result.config || '');
        } else {
            setMessage('error', wlocUi.errorMessage(result, _('Unable to read the Routing file.')));
        }

        var refreshButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Refresh'));
        refreshButton.addEventListener('click', function() {
            refreshRuntime();
        });

        var installButton = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Install'));
        uninstallButton = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button' }, _('Uninstall'));
        installButton.addEventListener('click', ui.createHandlerFn(installButton, installRouting));
        uninstallButton.addEventListener('click', ui.createHandlerFn(uninstallButton, uninstallRouting));

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, E('span', {}, [ installButton, ' ', uninstallButton, ' ', refreshButton ]) ]);

        window.addEventListener('pagehide', function() {
            pageVisible = false;
        }, { once: true });

        refreshRuntime();

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Routing')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Edit and save policy routing independently. Install loads the saved commands into the system and enables them at boot; Uninstall removes them and disables startup. WLOC does not need to be running.')),
            E('div', { 'class': 'cbi-section' }, [
                editor.root,
                message
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
