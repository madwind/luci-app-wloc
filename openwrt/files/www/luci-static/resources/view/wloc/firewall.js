'use strict';
'require view';
'require rpc';

var callRead = rpc.declare({ object: 'luci.wloc', method: 'firewall_read', expect: { '': {} } });
var callValidate = rpc.declare({ object: 'luci.wloc', method: 'firewall_validate', params: [ 'config' ], expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc', method: 'firewall_save', params: [ 'config' ], expect: { '': {} } });
var callApply = rpc.declare({ object: 'luci.wloc', method: 'firewall_apply', expect: { '': {} } });

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
		if (value) lines.push('\t'.repeat(indent) + value);
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

function setBusy(buttons, busy) {
	buttons.forEach(function(button) { button.disabled = busy; });
}

function tableRow(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('th', { 'class': 'th cbi-section-table-cell' }, label),
		E('td', { 'class': 'td cbi-section-table-cell' }, value)
	]);
}

return view.extend({
	render: function() {
		document.title = 'OpenWrt | Firewall';

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
		var bytes = E('span', {}, '0 B');
		var dirty = E('span', {}, _('Not loaded'));
		var activeStatus = E('span', {}, _('Loading'));
		var feedback = E('div', { 'class': 'alert-message', 'aria-live': 'polite', hidden: true });
		var formatButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Format'));
		var checkButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Check syntax'));
		var saveButton = E('button', { 'class': 'btn cbi-button cbi-button-save', 'type': 'button' }, _('Save'));
		var applyButton = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Save & apply'));
		var refreshButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('Refresh'));
		var buttons = [ formatButton, checkButton, saveButton, applyButton, refreshButton ];
		var loaded = false;

		function updateBytes() {
			bytes.textContent = new Blob([ editor.value ]).size + ' B';
		}

		function markChanged() {
			updateBytes();
			dirty.textContent = loaded ? _('Unsaved changes') : _('Not loaded');
		}

		function validate() {
			setBusy(buttons, true);
			setState(feedback, '', _('Checking the editor contents with nft --check...'));
			return callValidate(editor.value).then(function(result) {
				if (!result || result.valid !== true)
					throw new Error([ result && result.error, result && result.detail ].filter(Boolean).join(': ') || _('Syntax check failed.'));
				setState(feedback, 'ok', _('The nftables syntax check passed.'));
				return true;
			}).catch(function(error) {
				setState(feedback, 'error', String(error));
				return false;
			}).then(function(ok) { setBusy(buttons, false); return ok; });
		}

		function formatEditor() {
			return validate().then(function(valid) {
				if (!valid) return false;
				editor.value = formatNftables(editor.value);
				markChanged();
				setState(feedback, 'ok', _('Rules formatted. Review the changes before saving.'));
				editor.focus();
				return true;
			});
		}

		function refreshActive() {
			setBusy(buttons, true);
			return callRead().then(function(result) {
				if (!result || result.ok !== true) throw new Error((result && result.error) || _('Unable to read nftables rules.'));
				active.value = result.active || _('# No custom nftables tables are active.\n');
				updateActiveState(activeStatus, result);
				return result;
			}).catch(function(error) {
				setState(feedback, 'error', String(error));
				return null;
			}).then(function(result) { setBusy(buttons, false); return result; });
		}

		function save(apply) {
			setBusy(buttons, true);
			setState(feedback, '', apply ? _('Saving and applying rules...') : _('Saving rules...'));
			return callSave(editor.value).then(function(result) {
				if (!result || result.ok !== true)
					throw new Error([ result && result.error, result && result.detail ].filter(Boolean).join(': ') || _('Unable to save nftables rules.'));
				loaded = true;
				dirty.textContent = _('Saved');
				if (!apply) {
					setState(feedback, 'ok', _('Rules saved but not applied.'));
					return null;
				}
				return callApply().then(function(applied) {
					if (!applied || applied.ok !== true)
						throw new Error([ applied && applied.error, applied && applied.detail ].filter(Boolean).join(': ') || _('Unable to apply nftables rules.'));
					active.value = applied.active || _('# No custom nftables tables are active.\n');
					updateActiveState(activeStatus, applied);
					setState(feedback, 'ok', _('Rules saved and applied.'));
					return applied;
				});
			}).catch(function(error) {
				setState(feedback, 'error', String(error));
				return null;
			}).then(function(result) { setBusy(buttons, false); return result; });
		}

		formatButton.addEventListener('click', formatEditor);
		checkButton.addEventListener('click', validate);
		refreshButton.addEventListener('click', refreshActive);
		saveButton.addEventListener('click', function() { save(false); });
		applyButton.addEventListener('click', function() { save(true); });
		editor.addEventListener('input', markChanged);
		editor.addEventListener('keydown', function(event) {
			if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
				event.preventDefault(); save(false);
			} else if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
				event.preventDefault(); save(true);
			} else if (event.key === 'Tab') {
				event.preventDefault();
				var start = editor.selectionStart, end = editor.selectionEnd;
				editor.value = editor.value.slice(0, start) + '\t' + editor.value.slice(end);
				editor.selectionStart = editor.selectionEnd = start + 1;
				editor.dispatchEvent(new Event('input'));
			}
		});

		var statusTable = E('table', { 'class': 'table cbi-section-table' }, [
			E('tbody', {}, [
				tableRow(_('File'), path),
				tableRow(_('Size'), bytes),
				tableRow(_('Active state'), activeStatus),
				tableRow(_('Editor state'), dirty)
			])
		]);

		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
			E('div', { 'class': 'cbi-map-descr' }, _('Edit the complete WLOC nftables ruleset. An empty file means that no interception rules are loaded.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', { 'class': 'cbi-section-title' }, _('Firewall file')),
				statusTable,
				E('div', { 'class': 'cbi-section-descr' }, _('The dynamic IP set name is apple_wloc_v4 and it must use type ipv4_addr with the timeout flag. WLOC refreshes it immediately when rules are applied and every five minutes afterward.')),
				E('label', { 'class': 'cbi-section-descr', 'for': 'wloc-firewall-editor' }, _('nftables ruleset')),
				editor,
				E('div', { 'class': 'cbi-section-descr' }, _('Save & apply validates and loads the configured nftables tables.')),
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
			if (!result || result.ok !== true) throw new Error((result && result.error) || _('Unable to read nftables rules.'));
			path.textContent = result.path || '/etc/wloc/firewall.nft';
			editor.value = result.config || '';
			active.value = result.active || '';
			loaded = true;
			dirty.textContent = _('Loaded');
			updateActiveState(activeStatus, result);
			updateBytes();
		}).catch(function(error) {
			setState(feedback, 'error', String(error));
		});

		return root;
	}
});
