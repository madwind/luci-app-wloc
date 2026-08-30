'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require view.wloc.main as wlocMain';
'require wloc.ui as wlocUi';

var LOG_TAG = 'wlocd';
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_RECONNECT_MS = 2000;

function logDateFormatter() {
    var timezone = uci.get('system', '@system[0]', 'zonename');
    timezone = timezone ? String(timezone).replace(/ /g, '_') : undefined;

    try {
        return new Intl.DateTimeFormat(undefined, {
            dateStyle: 'medium',
            timeStyle: 'long',
            timeZone: timezone
        });
    } catch (error) {
        return null;
    }
}

function formatLogEntry(entry, formatter) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    var date = new Date(entry && entry.time);
    var timestamp = '';

    if (!isNaN(date.getTime())) {
        try {
            timestamp = formatter ? formatter.format(date) : date.toLocaleString();
        } catch (error) {
            timestamp = date.toLocaleString();
        }
    }

    return timestamp ? '[' + timestamp + '] ' + message : message;
}

function runtimeLogSection() {
    var formatter = logDateFormatter();
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
    var paused = false;
    var pageVisible = true;
    var followLogs = true;
    var logLines = [];
    var streamController = null;
    var reconnectTimer = null;

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

    function appendLogEntry(entry) {
        var message = entry && entry.msg != null ? String(entry.msg) : '';

        if (message.toLowerCase().indexOf(LOG_TAG) === -1)
            return;

        logLines.push(formatLogEntry(entry, formatter));
        logLines = wlocUi.boundedLines(logLines, LOG_LINES, LOG_MAX_BYTES);
        renderLogs();
    }

    function consumeSseFrame(frame) {
        var eventName = 'message';
        var data = [];

        frame.split('\n').forEach(function(line) {
            if (!line || line.charAt(0) === ':')
                return;
            if (line.indexOf('event:') === 0)
                eventName = line.slice(6).trim();
            else if (line.indexOf('data:') === 0)
                data.push(line.slice(5).trimStart());
        });

        if (eventName !== 'message' || !data.length)
            return;

        try {
            appendLogEntry(JSON.parse(data.join('\n')));
        } catch (error) {
            console.warn(error);
        }
    }

    function pumpLogStream(reader, decoder, controller, state) {
        return reader.read().then(function(chunk) {
            if (chunk.done)
                throw new Error('log subscription ended');

            state.buffer += decoder.decode(chunk.value, { stream: true }).replace(/\r\n/g, '\n');

            var boundary;
            while ((boundary = state.buffer.indexOf('\n\n')) >= 0) {
                consumeSseFrame(state.buffer.slice(0, boundary));
                state.buffer = state.buffer.slice(boundary + 2);
            }

            if (!controller.signal.aborted)
                return pumpLogStream(reader, decoder, controller, state);
        });
    }

    function clearReconnect() {
        if (reconnectTimer !== null) {
            window.clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
    }

    function stopLogStream() {
        clearReconnect();

        if (streamController)
            streamController.abort();

        streamController = null;
    }

    function scheduleReconnect() {
        if (paused || !pageVisible || reconnectTimer !== null)
            return;

        wlocUi.setState(logState, 'notice', _('Reconnecting'));
        reconnectTimer = window.setTimeout(function() {
            reconnectTimer = null;
            startLogStream();
        }, LOG_RECONNECT_MS);
    }

    function startLogStream() {
        if (paused || !pageVisible || streamController)
            return Promise.resolve();

        if (typeof fetch !== 'function' || typeof TextDecoder !== 'function' || typeof AbortController !== 'function') {
            wlocUi.setState(logState, 'warn', _('Unavailable'));
            return Promise.resolve();
        }

        clearReconnect();
        wlocUi.setState(logState, 'notice', _('Connecting'));

        var controller = new AbortController();
        streamController = controller;

        return fetch('/ubus/subscribe/log', {
            method: 'GET',
            headers: {
                'Accept': 'text/event-stream',
                'Authorization': 'Bearer ' + rpc.getSessionID()
            },
            credentials: 'same-origin',
            cache: 'no-store',
            signal: controller.signal
        }).then(function(response) {
            if (!response.ok || !response.body)
                throw new Error('log subscription HTTP ' + response.status);

            wlocUi.setState(logState, 'ok', _('Live'));

            return pumpLogStream(
                response.body.getReader(),
                new TextDecoder(),
                controller,
                { buffer: '' }
            );
        }).catch(function(error) {
            if (!controller.signal.aborted)
                console.warn(error);
        }).then(function() {
            if (streamController === controller)
                streamController = null;

            if (!controller.signal.aborted)
                scheduleReconnect();
        });
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

        if (paused) {
            stopLogStream();
            wlocUi.setState(logState, 'notice', _('Paused'));
            return Promise.resolve();
        }

        return startLogStream();
    }));

    window.addEventListener('pagehide', function() {
        pageVisible = false;
        stopLogStream();
    }, { once: true });

    startLogStream();

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
        return Promise.all([
            wlocMain.load.call(this),
            uci.load('system').catch(function() { return {}; })
        ]);
    },

    render: function(data) {
        var mainData = data && data[0] ? data[0] : data;

        return Promise.resolve(wlocMain.render.call(this, mainData)).then(function(root) {
            root.appendChild(runtimeLogSection());
            return root;
        });
    }
});
