'use strict';
'require view';
'require rpc';

var callRead = rpc.declare({ object: 'luci.wloc', method: 'firewall_read', expect: { '': {} } });
var callValidate = rpc.declare({ object: 'luci.wloc', method: 'firewall_validate', params: [ 'config' ], expect: { '': {} } });
var callSave = rpc.declare({ object: 'luci.wloc', method: 'firewall_save', params: [ 'config' ], expect: { '': {} } });
var callApply = rpc.declare({ object: 'luci.wloc', method: 'firewall_apply', expect: { '': {} } });

function addStylesheet() {
	if (document.querySelector('link[data-wloc-nft-style]')) return;
	var link = document.createElement('link');
	link.rel = 'stylesheet';
	link.dataset.wlocNftStyle = '1';
	link.href = L.resource('wloc/nftables.css');
	document.head.appendChild(link);
}

function setState(node, state, text) {
	node.dataset.state = state || '';
	node.textContent = text || '';
}

function formatNftables(source) {
	var text = String(source || '').replace(/\r\n?/g, '\n');
	var lines = [], line = '', indent = 0, quoted = false, escaped = false, comment = false;
	function flush() {
		var value = line.trim();
		if (value) lines.push('\t'.repeat(indent) + value);
		line = '';
	}
	function space() { if (line && !/\s$/.test(line)) line += ' '; }
	for (var i = 0; i < text.length; i++) {
		var c = text.charAt(i);
		if (comment) {
			if (c === '\n') { flush(); comment = false; } else line += c;
			continue;
		}
		if (quoted) {
			line += c;
			if (escaped) escaped = false;
			else if (c === '\\') escaped = true;
			else if (c === '"') quoted = false;
			continue;
		}
		if (c === '#') { space(); line += c; comment = true; }
		else if (c === '"') { line += c; quoted = true; }
		else if (c === '{') { space(); line += '{'; flush(); indent++; }
		else if (c === '}') { flush(); indent = Math.max(0, indent - 1); line = '}'; }
		else if (c === ';') { line = line.trimEnd() + ';'; flush(); }
		else if (c === '\n') flush();
		else if (/\s/.test(c)) space();
		else line += c;
	}
	flush();
	return lines.join('\n') + (lines.length ? '\n' : '');
}

return view.extend({
	render: function() {
		document.title = 'OpenWrt | WLOC Firewall';
		addStylesheet();

		var editor = E('textarea', {
			'class': 'wloc-nft-textarea', 'wrap': 'off', 'spellcheck': 'false',
			'autocapitalize': 'off', 'autocomplete': 'off', 'aria-label': _('nftables configuration')
		});
		var gutter = E('div', { 'class': 'wloc-nft-gutter', 'aria-hidden': 'true' });
		var preview = E('pre', { 'class': 'wloc-nft-output', 'tabindex': '0' });
		var active = E('pre', { 'class': 'wloc-nft-output', 'tabindex': '0' });
		var path = E('span', { 'class': 'wloc-nft-path' }, '/etc/wloc/firewall.nft');
		var bytes = E('span', { 'class': 'wloc-nft-stat' }, '0 B');
		var dirty = E('span', { 'class': 'wloc-nft-stat' }, _('Not loaded'));
		var status = E('span', { 'class': 'wloc-nft-status', 'data-state': 'warn' }, _('Loading'));
		var feedback = E('p', { 'class': 'wloc-nft-feedback', 'aria-live': 'polite' });
		var editPanel = E('section', { 'id': 'wloc-nft-edit', 'class': 'wloc-nft-panel', 'role': 'tabpanel' });
		var previewPanel = E('section', { 'id': 'wloc-nft-preview', 'class': 'wloc-nft-panel', 'role': 'tabpanel', hidden: true });
		var activePanel = E('section', { 'id': 'wloc-nft-active', 'class': 'wloc-nft-panel', 'role': 'tabpanel', hidden: true });
		var formatButton = E('button', { 'class': 'wloc-nft-button', 'type': 'button' }, _('Format'));
		var checkButton = E('button', { 'class': 'wloc-nft-button', 'type': 'button' }, _('Check syntax'));
		var saveButton = E('button', { 'class': 'wloc-nft-button wloc-nft-primary', 'type': 'button' }, _('Save'));
		var applyButton = E('button', { 'class': 'wloc-nft-button wloc-nft-primary', 'type': 'button' }, _('Save & apply'));
		var refreshButton = E('button', { 'class': 'wloc-nft-button', 'type': 'button' }, _('Refresh'));
		var buttons = [ formatButton, checkButton, saveButton, applyButton, refreshButton ];
		var loaded = false;

		function renderGutter() {
			gutter.replaceChildren();
			editor.value.split('\n').forEach(function(unused, index) {
				gutter.appendChild(E('div', { 'class': 'wloc-nft-gutter-line' }, String(index + 1)));
			});
		}
		function updatePreview() {
			bytes.textContent = new Blob([ editor.value ]).size + ' B';
			preview.textContent = editor.value || _('# The custom nftables file is empty.');
		}
		function markChanged() {
			renderGutter(); updatePreview();
			dirty.textContent = loaded ? _('Unsaved changes') : _('Not loaded');
		}
		function setBusy(busy) { buttons.forEach(function(button) { button.disabled = busy; }); }
		function validate() {
			setBusy(true);
			setState(feedback, '', _('Checking with nft --check...'));
			return callValidate(editor.value).then(function(result) {
				if (!result || result.valid !== true)
					throw new Error([ result && result.error, result && result.detail ].filter(Boolean).join(': ') || _('Syntax check failed.'));
				setState(feedback, 'ok', _('The nftables syntax check passed.'));
				return true;
			}).catch(function(error) {
				setState(feedback, 'error', String(error)); return false;
			}).then(function(ok) { setBusy(false); return ok; });
		}
		function refreshActive() {
			setBusy(true);
			return callRead().then(function(result) {
				if (!result || result.ok !== true) throw new Error((result && result.error) || _('Unable to read nftables rules.'));
				active.textContent = result.active || _('# No custom nftables tables are active.');
				setState(status, result.active_found ? 'ok' : 'warn', _('%d/%d table(s) active').format(result.active_table_count || 0, result.table_count || 0));
			}).catch(function(error) {
				setState(feedback, 'error', String(error));
			}).then(function() { setBusy(false); });
		}
		function save(apply) {
			setBusy(true);
			setState(feedback, '', apply ? _('Saving and applying rules...') : _('Saving rules...'));
			return callSave(editor.value).then(function(result) {
				if (!result || result.ok !== true)
					throw new Error([ result && result.error, result && result.detail ].filter(Boolean).join(': ') || _('Unable to save nftables rules.'));
				loaded = true; dirty.textContent = _('Saved');
				if (!apply) { setState(feedback, 'ok', _('Rules saved but not applied.')); return null; }
				return callApply().then(function(applied) {
					if (!applied || applied.ok !== true)
						throw new Error([ applied && applied.error, applied && applied.detail ].filter(Boolean).join(': ') || _('Unable to apply nftables rules.'));
					active.textContent = applied.active || _('# No custom nftables tables are active.');
					setState(status, applied.active_found ? 'ok' : 'warn', _('%d/%d table(s) active').format(applied.active_table_count || 0, applied.table_count || 0));
					setState(feedback, 'ok', _('Rules saved and applied.'));
				});
			}).catch(function(error) {
				setState(feedback, 'error', String(error));
			}).then(function(result) { setBusy(false); return result; });
		}

		var panels = [ editPanel, previewPanel, activePanel ];
		var tabButtons = [ _('Edit'), _('Preview'), _('Active') ].map(function(label, index) {
			var button = E('button', {
				'class': 'wloc-nft-button', 'type': 'button', 'role': 'tab',
				'aria-controls': panels[index].id, 'aria-selected': index === 0 ? 'true' : 'false'
			}, label);
			button.addEventListener('click', function() {
				panels.forEach(function(panel, panelIndex) { panel.hidden = panelIndex !== index; });
				tabButtons.forEach(function(tab, tabIndex) {
					tab.classList.toggle('is-active', tabIndex === index);
					tab.setAttribute('aria-selected', tabIndex === index ? 'true' : 'false');
				});
				if (index === 1) { updatePreview(); validate(); }
				if (index === 2) refreshActive();
			});
			return button;
		});
		tabButtons[0].classList.add('is-active');

		editPanel.appendChild(E('div', { 'class': 'wloc-nft-toolbar' }, [
			formatButton, checkButton, E('span', { 'class': 'wloc-nft-spacer' }), saveButton, applyButton
		]));
		editPanel.appendChild(E('div', { 'class': 'wloc-nft-editor-wrap' }, [ gutter, editor ]));
		editPanel.appendChild(E('div', { 'class': 'wloc-nft-foot' }, [
			E('span', {}, _('Ctrl/Cmd+S save · Ctrl/Cmd+Enter save & apply')),
			E('span', {}, _('Custom top-level nftables tables'))
		]));
		previewPanel.appendChild(E('div', { 'class': 'wloc-nft-toolbar' }, _('Read-only preview; syntax is checked when this tab opens.')));
		previewPanel.appendChild(preview);
		activePanel.appendChild(E('div', { 'class': 'wloc-nft-toolbar' }, [
			E('span', {}, _('Custom tables from this file that are currently loaded.')),
			E('span', { 'class': 'wloc-nft-spacer' }), refreshButton
		]));
		activePanel.appendChild(active);

		formatButton.addEventListener('click', function() {
			validate().then(function(valid) {
				if (!valid) return;
				editor.value = formatNftables(editor.value); markChanged(); editor.focus();
				setState(feedback, 'ok', _('Rules formatted. Review before saving.'));
			});
		});
		checkButton.addEventListener('click', validate);
		refreshButton.addEventListener('click', refreshActive);
		saveButton.addEventListener('click', function() { save(false); });
		applyButton.addEventListener('click', function() { save(true); });
		editor.addEventListener('input', markChanged);
		editor.addEventListener('scroll', function() { gutter.scrollTop = editor.scrollTop; });
		editor.addEventListener('keydown', function(event) {
			if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') { event.preventDefault(); save(false); }
			else if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); save(true); }
			else if (event.key === 'Tab') {
				event.preventDefault();
				var start = editor.selectionStart, end = editor.selectionEnd;
				editor.value = editor.value.slice(0, start) + '\t' + editor.value.slice(end);
				editor.selectionStart = editor.selectionEnd = start + 1;
				editor.dispatchEvent(new Event('input'));
			}
		});

		var root = E('main', { 'class': 'wloc-nft-page' }, [
			E('div', { 'class': 'wloc-nft-heading' }, [
				E('h2', {}, _('Firewall settings')),
				E('p', {}, _('The complete “table inet wloc” ruleset is managed here. WLOC never generates, replaces or deletes this table; an empty file means no interception rules.')),
				E('p', {}, _('Dynamic IP set: the set name is fixed as “apple_wloc_v4” and must use “type ipv4_addr; flags timeout;”. The table family and name are detected automatically. WLOC refreshes it immediately on apply and then every 5 minutes.'))
			]),
			E('section', { 'class': 'wloc-nft-statusbar' }, [ status, path, bytes, dirty ]),
			E('div', { 'class': 'wloc-nft-tabs', 'role': 'tablist' }, tabButtons),
			E('div', { 'class': 'wloc-nft-workbench' }, panels), feedback
		]);

		callRead().then(function(result) {
			if (!result || result.ok !== true) throw new Error((result && result.error) || _('Unable to read nftables rules.'));
			path.textContent = result.path || '/etc/wloc/firewall.nft';
			editor.value = result.config || ''; active.textContent = result.active || '';
			loaded = true; dirty.textContent = _('Loaded');
			setState(status, result.active_found ? 'ok' : 'warn', _('%d/%d table(s) active').format(result.active_table_count || 0, result.table_count || 0));
			renderGutter(); updatePreview();
		}).catch(function(error) {
			setState(status, 'error', _('Read failed')); setState(feedback, 'error', String(error));
		});
		return root;
	}
});
