'use strict';
'require baseclass';
'require ui';
'require wloc.ui as wlocUi';

function editorByteLength(value) {
    return wlocUi.byteLength(value);
}

function createEditor(options) {
    options = options || {};

    var id = options.id || 'wloc-editor';
    var label = options.label || _('Text editor');
    var minHeight = options.minHeight || '24em';
    var rows = options.rows || 24;
    var savedValue = String(options.value === undefined || options.value === null ? '' : options.value);
    var installed = false;
    var installToggleButton = null;
    var textarea = E('textarea', {
        'id': id,
        'class': 'cbi-input-text',
        'style': 'display: block; width: 100%; min-height: ' + minHeight + '; box-sizing: border-box;',
        'rows': rows,
        'wrap': 'off',
        'spellcheck': 'false',
        'autocapitalize': 'off',
        'autocomplete': 'off',
        'readonly': options.readonly ? true : null,
        'aria-label': label
    });
    var byteCount = E('span', {}, wlocUi.formatBytes(editorByteLength(savedValue)));
    var state = E('span', { 'aria-live': 'polite' }, options.readonly ? _('Read-only') : _('Saved file'));
    var cursorPosition = E('span', { 'aria-live': 'polite' }, _('Ln 1, Col 1'));
    var leftActions = E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: .5rem;' });
    var rightActions = E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: .5rem; margin-left: auto;' });
    var toolbar = E('div', {
        'class': 'cbi-page-actions',
        'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .75rem;'
    }, [ leftActions, rightActions ]);
    var hasActions = !options.readonly && [
        options.format,
        options.loadDefault,
        options.reload,
        options.save,
        options.installToggle
    ].some(function(handler) {
        return typeof handler === 'function';
    });
    var rootChildren = [
        E('label', { 'class': 'cbi-section-descr', 'for': id }, label),
        textarea,
        E('div', { 'class': 'cbi-section-descr' }, [
            _('Size'), ': ', byteCount, ' · ', state, ' · ', cursorPosition
        ])
    ];
    var api;

    if (hasActions)
        rootChildren.push(toolbar);

    var root = E('div', { 'class': 'wloc-editor' }, rootChildren);
    textarea.value = savedValue;

    function isDirty() {
        return textarea.value !== savedValue;
    }

    function updateCursorPosition() {
        var position = typeof textarea.selectionStart === 'number' ? textarea.selectionStart : 0;
        var before = textarea.value.slice(0, Math.max(0, position));
        var lastBreak = before.lastIndexOf('\n');
        var line = before.split('\n').length;
        var column = position - lastBreak;

        wlocUi.setText(cursorPosition, _('Ln %d, Col %d').format(line, column));
    }

    function updateState() {
        wlocUi.setText(byteCount, wlocUi.formatBytes(editorByteLength(textarea.value)));
        wlocUi.setText(state, options.readonly ? _('Read-only') : isDirty() ? _('Unsaved edits') : _('Saved file'));
        updateCursorPosition();
    }

    function handleInput() {
        updateState();
        if (options.onInput)
            options.onInput(api);
    }

    function confirmAction(title, message, handler) {
        return new Promise(function(resolve, reject) {
            ui.showModal(title, [
                E('p', { 'class': 'alert-message warning' }, message),
                E('div', { 'class': 'right' }, [
                    E('button', {
                        'class': 'btn',
                        'type': 'button',
                        'click': function() {
                            ui.hideModal();
                            resolve(false);
                        }
                    }, _('Cancel')),
                    ' ',
                    E('button', {
                        'class': 'btn cbi-button cbi-button-negative',
                        'type': 'button',
                        'click': function() {
                            ui.hideModal();
                            Promise.resolve().then(handler).then(resolve, reject);
                        }
                    }, title)
                ])
            ]);
        });
    }

    function addInjectedAction(container, title, className, handler, confirmMessage) {
        if (typeof handler !== 'function')
            return null;

        var button = E('button', {
            'class': 'btn cbi-button ' + className,
            'type': 'button'
        }, title);
        var actionHandler = function() {
            if (confirmMessage)
                return confirmAction(title, confirmMessage, function() { return handler(api); });
            return Promise.resolve(handler(api));
        };

        button.addEventListener('click', ui.createHandlerFn(button, actionHandler));
        container.appendChild(button);
        return button;
    }

    function setValue(value) {
        textarea.value = String(value === undefined || value === null ? '' : value);
        updateState();
    }

    function markSaved(value) {
        if (value !== undefined)
            textarea.value = String(value === null ? '' : value);
        savedValue = textarea.value;
        updateState();
    }

    function setInstalled(value) {
        installed = value === true;
        if (!installToggleButton)
            return;
        installToggleButton.className = 'btn cbi-button ' + (installed ? 'cbi-button-negative' : 'cbi-button-apply');
        wlocUi.setText(installToggleButton, installed ? _('Uninstall') : _('Install'));
    }

    function focus() {
        textarea.focus();
    }

    api = {
        focus: focus,
        getValue: function() { return textarea.value; },
        isDirty: isDirty,
        markSaved: markSaved,
        root: root,
        setInstalled: setInstalled,
        setValue: setValue
    };

    addInjectedAction(leftActions, options.formatLabel || _('Format'), 'cbi-button-action', options.format, null);
    addInjectedAction(leftActions, _('Reload saved file'), 'cbi-button-negative', options.reload,
        _('Reload the saved file? This will replace the current editor contents. Any unsaved changes will be lost.'));
    addInjectedAction(leftActions, _('Load default'), 'cbi-button-negative', options.loadDefault,
        _('Load the default template? This will replace the current editor contents. Any unsaved changes will be lost.'));
    addInjectedAction(rightActions, options.saveLabel || _('Save'), 'cbi-button-save', options.save, null);

    if (typeof options.installToggle === 'function') {
        installToggleButton = E('button', { 'class': 'btn cbi-button', 'type': 'button' });
        installToggleButton.addEventListener('click', ui.createHandlerFn(installToggleButton, function() {
            return Promise.resolve(options.installToggle(api, installed));
        }));
        rightActions.appendChild(installToggleButton);
        setInstalled(installed);
    }

    textarea.addEventListener('input', handleInput);
    textarea.addEventListener('keyup', updateCursorPosition);
    textarea.addEventListener('click', updateCursorPosition);
    textarea.addEventListener('select', updateCursorPosition);
    updateState();

    return api;
}

return baseclass.extend({
    create: createEditor
});
