'use strict';
'require view';
'require rpc';

var callRead = rpc.declare({ object: 'luci.wloc', method: 'firewall_read', expect: { '': {} } });
var callValidate = rpc.declare({ object: 'luci.wloc', method: 'firewall_validate', params: [ 'config' ], expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc', method: 'firewall_save', params: [ 'expected_applied_hash' ], expect: { '': {} } });
var callApply = rpc.declare({ object: 'luci.wloc', method: 'firewall_apply', params: [ 'config' ], expect: { '': {} } });

function firewallError(result, fallback) {
    var messages = {
        firewall_busy: 'Another firewall operation is already in progress. Please retry.',
        stale_applied_revision: 'The applied firewall configuration changed. Refresh the page before saving.',
        no_applied_snapshot: 'No successfully applied firewall rules are available to save.',
        snapshot_stage_failed: 'The runtime snapshot could not be staged.',
        nft_check_failed: 'The nftables syntax check failed.',
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

function setState(element, state, value) {
    element.classList.remove('success', 'warning', 'error', 'notice');
    element.hidden = !value;
    element.textContent = value || '';
    if (value)
        element.classList.add(state === 'ok' ? 'success' : state === 'warn' ? 'warning' : state === 'error' ? 'error' : 'notice');
}

function updateActiveState(status, result) {
    status.textContent = _('%d/%d table(s) active').format(result.active_table_count || 0, result.table_count || 0);
}

function formatNftables(source) {
    var text = String(source || '').replace(/\r\n?/g, '\n');
    var lines = [], line = '', indent = 0, quoted = false, escaped = false, comment = false;

    function flush() {
        var value = line.trim();
        if (value) lines.push('    '.repeat(indent) + value);
        line = '';
    }

    function space() {
        if (line && !/\s$/.test(line)) line += ' ';
    }

    for (var i = 0; i < text.length; i++) {
        var character = text.charAt(i);
        if (comment) {
            if (character === '\n') { flush(); comment = false; }
            else line += character;
            continue;
        }
        if (quoted) {
            line += character;
            if (escaped) escaped = false;
            else if (character === '\\') escaped = true;
            else if (character === '"') quoted = false;
            continue;
        }
        if (character === '#') { space(); line += character; comment = true; }
        else if (character === '"') { line += character; quoted = true; }
        else if (character === '{') { space(); line += '{'; flush(); indent++; }
        else if (character === '}') { flush(); indent = Math.max(0, indent - 1); line = '}'; }
        else if (character === ';') { line = line.trimEnd() + ';'; flush(); }
        else if (character === '\n') flush();
        else if (/\s/.test(character)) space();
        else {
            line += character;
            if (character === ',' && line.length >= 96) flush();
        }
    }
    flush();
    return lines.join('\n') + (lines.length ? '\n' : '');
}

function contentHash(value) {
    var hash = 2166136261;
    value = String(value || '');
    for (var i = 0; i < value.length; i++)
        hash = Math.imul(hash ^ value.charCodeAt(i), 16777619);
    return ('00000000' + (hash >>> 0).toString(16)).slice(-8);
}

function initialEditorContent(result) {
    var persistent = String(result && result.config || '');
    var applied = String(result && result.applied || '');
    return result && result.applied_present === true &&
        contentHash(applied) !== contentHash(persistent) ? applied : persistent;
}

function initialEditorState(result) {
    var persistent = String(result && result.config || '');
    var applied = String(result && result.applied || '');
    var appliedPresent = result && result.applied_present === true;
    var persistentPresent = result && result.persistent_present === true;
    var appliedRevision = String(result && result.applied_hash || '');
    var savedRevision = String(result && result.saved_hash || '');
    var editor = initialEditorContent(result);
    var matchesApplied = appliedPresent && contentHash(editor) === contentHash(applied);
    var matchesSaved = matchesApplied && persistentPresent &&
        appliedRevision && savedRevision && appliedRevision === savedRevision;
    return { content: editor, saveEnabled: matchesApplied && !!appliedRevision && !matchesSaved };
}

function setBusy(buttons, busy) {
    buttons.forEach(function(button) {
        button.wlocBusy = busy;
        button.disabled = busy || !!button.wlocStateDisabled;
    });
}

function tableRow(label, value) {
    return E('tr', { 'class': 'tr' }, [
        E('th', { 'class': 'th cbi-section-table-cell' }, label),
        E('td', { 'class': 'td cbi-section-table-cell' }, value)
    ]);
}

return view.extend({
    render: function() {
        document.title = 'OpenWrt | ' + _('Firewall');

        var editor = E('textarea', {
            'id': 'wloc-firewall-editor',
            'class': 'cbi-input-text',
            'style': 'display: block; width: 100%; min-height: 32em; box-sizing: border-box;',
            'wrap': 'off', 'rows': '32', 'spellcheck': 'false',
            'autocapitalize': 'off', 'autocomplete': 'off',
            'aria-label': _('nftables configuration')
        });
        var active = E('textarea', {
            'class': 'cbi-input-text',
            'style': 'display: block; width: 100%; min-height: 18em; box-sizing: border-box;',
            'wrap': 'off', 'rows': '18', 'readonly': true,
            'aria-label': _('active nftables configuration')
        });
        var path = E('span', {}, '/etc/wloc/firewall.nft');
        var bytes = E('span', {}, '%s %s'.format(0, _('B')));
        var dirty = E('span', {}, _('Not loaded'));
        var runtimeState = E('span', {}, _('Loading'));
        var persistentState = E('span', {}, _('Loading'));
        var activeStatus = E('span', {}, _('Loading'));
        var feedback = E('div', { 'class': 'alert-message', 'aria-live': 'polite', hidden: true });
        var formatButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Format'));
        var checkButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Check syntax'));
        var saveButton = E('button', { 'class': 'btn cbi-button cbi-button-save', 'type': 'button' }, _('Save'));
        var applyButton = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Apply'));
        var refreshButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Refresh'));
        var buttons = [ formatButton, checkButton, saveButton, applyButton, refreshButton ];
        var loaded = false;
        var appliedPresent = false;
        var persistentPresent = false;
        var appliedContentHash = '';
        var appliedRevision = '';
        var savedHash = '';
        var runtimeReady = false;
        var recovering = false;
        var runtimeWarning = '';

        saveButton.wlocStateDisabled = true;
        saveButton.disabled = true;

        function updateBytes() {
            bytes.textContent = '%s %s'.format(new Blob([ editor.value ]).size, _('B'));
        }

        function markChanged() {
            updateBytes();
            updateStates();
        }

        function updateStates() {
            var editorHash = contentHash(editor.value);
            var matchesApplied = loaded && appliedPresent && editorHash === appliedContentHash;
            var appliedMatchesSaved = loaded && appliedPresent && persistentPresent &&
                !!appliedRevision && !!savedHash && appliedRevision === savedHash;
            var matchesSaved = matchesApplied && appliedMatchesSaved;
            if (!loaded) {
                dirty.textContent = _('Not loaded');
                runtimeState.textContent = _('Loading');
                persistentState.textContent = _('Loading');
            } else {
                dirty.textContent = matchesApplied
                    ? (matchesSaved ? _('Matches saved rules') : _('Matches applied rules; not saved'))
                    : _('Modified; apply before saving');
                runtimeState.textContent = recovering ? _('Recovering') :
                    runtimeReady || appliedPresent ? _('Applied') : _('Not applied');
                persistentState.textContent = appliedMatchesSaved ? _('Saved') : _('Not saved');
            }
            saveButton.wlocStateDisabled = !matchesApplied || !appliedRevision || matchesSaved;
            if (!saveButton.wlocBusy)
                saveButton.disabled = saveButton.wlocStateDisabled;
        }

        function validate() {
            setBusy(buttons, true);
            setState(feedback, '', _('Checking the editor contents with nft --check...'));
            return callValidate(editor.value).then(function(result) {
                if (!result || result.valid !== true)
                    throw new Error(firewallError(result, _('Syntax check failed.')));
                setState(feedback, 'ok', _('The nftables syntax check passed.'));
                return true;
            }).catch(function(error) {
                setState(feedback, 'error', String(error));
                return false;
            }).then(function(ok) { setBusy(buttons, false); return ok; });
        }

        function formatEditor() {
            if (!loaded)
                return false;
            editor.value = formatNftables(editor.value);
            markChanged();
            setState(feedback, 'ok', _('Rules formatted. Review the changes, then check and apply them.'));
            editor.focus();
            return true;
        }

        function refreshActive() {
            setBusy(buttons, true);
            return callRead().then(function(result) {
                if (!result || result.ok !== true) throw new Error(firewallError(result, _('Unable to read nftables rules.')));
                active.value = result.active || _('# No custom nftables tables are active.') + '\n';
                persistentPresent = result.persistent_present === true;
                savedHash = persistentPresent ? String(result.saved_hash || '') : '';
                appliedPresent = result.applied_present === true;
                appliedContentHash = appliedPresent ? contentHash(result.applied || '') : '';
                appliedRevision = appliedPresent ? String(result.applied_hash || '') : '';
                runtimeReady = result.runtime_ready === true;
                recovering = result.recovering === true;
                runtimeWarning = String(result.warning || '');
                updateActiveState(activeStatus, result);
                updateStates();
                if (runtimeWarning)
                    setState(feedback, 'warn', _(runtimeWarning));
                return result;
            }).catch(function(error) {
                setState(feedback, 'error', String(error));
                return null;
            }).then(function(result) { setBusy(buttons, false); updateStates(); return result; });
        }

        function apply() {
            setBusy(buttons, true);
            setState(feedback, '', _('Checking and temporarily applying the editor contents...'));
            return callApply(editor.value).then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(firewallError(result, _('Unable to apply nftables rules.')));
                appliedPresent = true;
                persistentPresent = result.persistent_present === true;
                savedHash = persistentPresent ? String(result.saved_hash || '') : '';
                appliedContentHash = contentHash(result.applied !== undefined ? result.applied : editor.value);
                appliedRevision = String(result.applied_hash || '');
                runtimeReady = result.runtime_ready === true;
                recovering = result.recovering === true;
                runtimeWarning = String(result.warning || '');
                active.value = result.active || _('# No custom nftables tables are active.') + '\n';
                updateActiveState(activeStatus, result);
                updateStates();
                setState(feedback, recovering ? 'warn' : 'ok', recovering
                    ? _('Firewall rules were temporarily applied. Runtime dynamic sets are recovering automatically.')
                    : _('Rules were temporarily applied. Confirm that network, LuCI and SSH still work, then click Save.'));
                return result;
            }).catch(function(error) {
                setState(feedback, 'error', String(error));
                return null;
            }).then(function(result) { setBusy(buttons, false); updateStates(); return result; });
        }

        function save() {
            var matchesApplied = loaded && appliedPresent && contentHash(editor.value) === appliedContentHash;
            if (!matchesApplied || !appliedRevision) {
                setState(feedback, 'warn', _('The current editor contents have not been applied and cannot be saved.'));
                updateStates();
                return Promise.resolve(null);
            }
            setBusy(buttons, true);
            setState(feedback, '', _('Saving the currently applied rules...'));
            return callSave(appliedRevision).then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(firewallError(result, _('Unable to save nftables rules.')));
                persistentPresent = true;
                appliedRevision = String(result.applied_hash || appliedRevision);
                savedHash = String(result.saved_hash || '');
                updateStates();
                setState(feedback, 'ok', _('The currently applied rules were saved and will load on the next boot.'));
                return result;
            }).catch(function(error) {
                setState(feedback, 'error', String(error));
                return null;
            }).then(function(result) { setBusy(buttons, false); updateStates(); return result; });
        }

        formatButton.addEventListener('click', formatEditor);
        checkButton.addEventListener('click', validate);
        refreshButton.addEventListener('click', refreshActive);
        saveButton.addEventListener('click', save);
        applyButton.addEventListener('click', apply);
        editor.addEventListener('input', markChanged);
        editor.addEventListener('keydown', function(event) {
            if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
                event.preventDefault(); save();
            } else if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
                event.preventDefault(); apply();
            } else if (event.key === 'Tab') {
                event.preventDefault();
                var start = editor.selectionStart, end = editor.selectionEnd;
                editor.value = editor.value.slice(0, start) + '    ' + editor.value.slice(end);
                editor.selectionStart = editor.selectionEnd = start + 4;
                editor.dispatchEvent(new Event('input'));
            }
        });

        var statusTable = E('table', { 'class': 'table cbi-section-table' }, [
            E('tbody', {}, [
                tableRow(_('File'), path),
                tableRow(_('Size'), bytes),
                tableRow(_('Active state'), activeStatus),
                tableRow(_('Editor state'), dirty),
                tableRow(_('Runtime state'), runtimeState),
                tableRow(_('Persistent state'), persistentState)
            ])
        ]);

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' }, _('Enter any valid nftables ruleset. WLOC does not require a particular table, chain, priority, or redirect rule. An empty file means that no custom rules are loaded.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Firewall file')),
                statusTable,
                E('div', { 'class': 'alert-message warning' }, _('This is a full nftables editor. An invalid or logically unsafe ruleset can interrupt network access, LuCI, or SSH. Apply is temporary; rebooting without Save restores the last saved rules.')),
                E('div', { 'class': 'cbi-section-descr' }, _('WLOC only maintains optional dynamic sets when you declare them: apple_wloc_v4 (type ipv4_addr, flags timeout) receives resolved Apple addresses, and target_ingress_interfaces (type ifname, flags timeout) receives configured AP interfaces. Other rules and sets are left unchanged.')),
                E('label', { 'class': 'cbi-section-descr', 'for': 'wloc-firewall-editor' }, _('nftables ruleset')),
                editor,
                E('div', { 'class': 'cbi-section-descr' }, _('Check syntax only validates the editor. Apply temporarily loads it without changing the persistent file. Save is enabled only after the current editor contents have been applied. No WLOC rule layout is enforced.')),
                E('div', { 'class': 'cbi-page-actions' }, [ formatButton, checkButton, saveButton, applyButton, refreshButton ]),
                feedback
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Active nftables rules')),
                E('div', { 'class': 'cbi-section-descr' }, _('The configured tables currently loaded in the kernel.')),
                active
            ])
        ]);

        callRead().then(function(result) {
            if (!result || result.ok !== true) throw new Error(firewallError(result, _('Unable to read nftables rules.')));
            path.textContent = result.path || '/etc/wloc/firewall.nft';
            editor.value = initialEditorContent(result);
            active.value = result.active || '';
            persistentPresent = result.persistent_present === true;
            appliedPresent = result.applied_present === true;
            savedHash = persistentPresent ? String(result.saved_hash || '') : '';
            appliedContentHash = appliedPresent ? contentHash(result.applied || '') : '';
            appliedRevision = appliedPresent ? String(result.applied_hash || '') : '';
            runtimeReady = result.runtime_ready === true;
            recovering = result.recovering === true;
            runtimeWarning = String(result.warning || '');
            loaded = true;
            updateActiveState(activeStatus, result);
            updateBytes();
            updateStates();
            if (runtimeWarning)
                setState(feedback, 'warn', _(runtimeWarning));
        }).catch(function(error) {
            setState(feedback, 'error', String(error));
        });

        return root;
    }
});
