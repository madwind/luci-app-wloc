'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require view.wloc.main as wlocMain';
'require wloc.ui as wlocUi';

var callLogRead = rpc.declare({
    object: 'log',
    method: 'read',
    params: [ 'lines', 'stream', 'oneshot' ],
    expect: { log: [] },
    reject: true
});

var LOG_TAG = 'wlocd';
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_POLL_INTERVAL = 1;

function validateLogResponse(entries) {
    if (!Array.isArray(entries))
        throw new Error(_('Runtime log returned an invalid line list.'));

    return entries.filter(function(entry) {
        var message = entry && entry.msg != null ? String(entry.msg) : '';
        return message.toLowerCase().indexOf(LOG_TAG) !== -1;
    }).map(function(entry) {
        return String(entry.msg || '');
    });
}

function runtimeLogSection() {
    var logState = E('span', { 'aria-live': 'polite' }, _('Connecting'));
    var logFilter = E('input', {
        'class': 'cbi-input-text',
        'type': 'search',
        'placeholder': _('Filter'),
        'autocomplete': 'off',
        'spellcheck': 'false',
        'aria-label': _('Filter runtime log')
    });
    var logOutput = E('textarea', {
        'id': 'wloc-runtime-log',
        'class': 'cbi-input-text',
        'style': 'display: block; width: 100%; min-height: 22em; box-sizing: border-box;',
        'rows': 20,
        'wrap': 'off',
        'spellcheck': 'false',
        'readonly': true,
        'role': 'log',
        'aria-label': _('WLOC runtime log')
    });
    var logRequest = null;
    var paused = false;
    var pageVisible = true;
    var followLogs = true;
    var logLines = [];

    function filteredLogLines() {
        var filter = logFilter.value.trim().toLowerCase();
        if (!filter)
            return logLines;

        return logLines.filter(function(line) {
            return line.toLowerCase().indexOf(filter) !== -1;
        });
    }

    function renderLogs() {
        var oldScrollTop = logOutput.scrollTop;
        var wasAtBottom = followLogs;

        logOutput.value = filteredLogLines().join('\n');
        if (wasAtBottom)
            logOutput.scrollTop = logOutput.scrollHeight;
        else
            logOutput.scrollTop = oldScrollTop;
    }

    function applyLogResponse(entries) {
        logLines = wlocUi.boundedLines(validateLogResponse(entries), LOG_LINES, LOG_MAX_BYTES);
        renderLogs();
        wlocUi.setState(logState, paused ? 'notice' : 'ok', paused ? _('Paused') : _('Live'));
        return entries;
    }

    function requestLogs() {
        if (paused || !pageVisible || logRequest)
            return logRequest || Promise.resolve();

        logRequest = callLogRead(LOG_LINES, false, true).then(function(entries) {
            return applyLogResponse(entries);
        }).catch(function(error) {
            if (pageVisible) {
                wlocUi.setState(logState, 'warn', _('Unavailable'));
                console.warn(error);
            }
            return null;
        }).then(function(result) {
            logRequest = null;
            return result;
        });

        return logRequest;
    }

    logOutput.addEventListener('scroll', function() {
        followLogs = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight <= 4;
    });
    logFilter.addEventListener('input', renderLogs);

    var pauseButton = E('button', {
        'class': 'btn cbi-button cbi-button-action',
        'type': 'button'
    }, _('Pause'));
    pauseButton.addEventListener('click', ui.createHandlerFn(pauseButton, function() {
        paused = !paused;
        pauseButton.textContent = paused ? _('Resume') : _('Pause');
        wlocUi.setState(logState, paused ? 'notice' : 'ok', paused ? _('Paused') : _('Live'));
        return paused ? Promise.resolve() : requestLogs();
    }));

    poll.add(requestLogs, LOG_POLL_INTERVAL);
    window.addEventListener('pagehide', function() {
        pageVisible = false;
        poll.remove(requestLogs);
    }, { once: true });

    requestLogs();

    return E('div', { 'class': 'cbi-section' }, [
        E('h3', { 'class': 'cbi-section-title' }, _('Runtime log')),
        E('div', {
            'class': 'cbi-section-descr',
            'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .5rem;'
        }, [
            logState,
            E('div', {
                'style': 'display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; margin-left: auto;'
            }, [
                E('label', {
                    'style': 'display: inline-flex; align-items: center; gap: .5rem;'
                }, [ _('Filter'), logFilter ]),
                pauseButton
            ])
        ]),
        logOutput
    ]);
}

return view.extend({
    load: function() {
        return wlocMain.load.call(this);
    },

    render: function(data) {
        return Promise.resolve(wlocMain.render.call(this, data)).then(function(root) {
            var oldLog = root.querySelector('textarea[aria-label="' + _('Current-session in-memory log') + '"]');
            var oldSection = oldLog && oldLog.closest ? oldLog.closest('.cbi-section') : null;

            if (oldSection)
                oldSection.remove();

            root.appendChild(runtimeLogSection());
            return root;
        });
    }
});
