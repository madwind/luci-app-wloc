'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require uci';
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
var LOG_HISTORY_LINES = 1000;
var LOG_CATCHUP_LINES = 128;
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_FALLBACK_POLL_INTERVAL = 2;
var LOG_STREAM_RETRY_MS = 30000;
var LOG_SEEN_KEYS = 5000;

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

function logEntryId(entry) {
    if (!entry || entry.id == null || !isFinite(Number(entry.id)))
        return null;

    return Number(entry.id) >>> 0;
}

function logEntryKey(entry) {
    return [
        entry && entry.id != null ? String(entry.id) : '',
        entry && entry.time != null ? String(entry.time) : '',
        entry && entry.source != null ? String(entry.source) : '',
        entry && entry.msg != null ? String(entry.msg) : ''
    ].join('\u001f');
}

function isNewerLogId(candidate, current) {
    if (candidate == null)
        return false;
    if (current == null)
        return true;
    if (candidate === current)
        return false;

    return ((candidate - current) >>> 0) < 0x80000000;
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
    var logRequest = null;
    var paused = false;
    var pageVisible = true;
    var followLogs = true;
    var logLines = [];
    var seenLogKeys = Object.create(null);
    var seenLogOrder = [];
    var lastLogId = null;
    var streamController = null;
    var streamStarting = false;
    var streamActive = false;
    var streamUnsupported = false;
    var nextStreamRetryAt = 0;
    var fallbackPolling = false;

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

    function rememberLogKey(key) {
        if (seenLogKeys[key])
            return false;

        seenLogKeys[key] = true;
        seenLogOrder.push(key);
        while (seenLogOrder.length > LOG_SEEN_KEYS)
            delete seenLogKeys[seenLogOrder.shift()];
        return true;
    }

    function appendLogEntries(entries, resetCursor) {
        var changed = false;

        if (!Array.isArray(entries))
            throw new Error(_('Runtime log returned an invalid line list.'));

        if (resetCursor)
            lastLogId = null;

        entries.forEach(function(entry) {
            var id = logEntryId(entry);
            var message = entry && entry.msg != null ? String(entry.msg) : '';

            if (isNewerLogId(id, lastLogId))
                lastLogId = id;

            if (message.toLowerCase().indexOf(LOG_TAG) === -1)
                return;

            if (!rememberLogKey(logEntryKey(entry)))
                return;

            logLines.push(formatLogEntry(entry, formatter));
            changed = true;
        });

        if (changed) {
            logLines = wlocUi.boundedLines(logLines, LOG_LINES, LOG_MAX_BYTES);
            renderLogs();
        }

        return entries;
    }

    function findLogId(entries, id) {
        if (id == null)
            return -1;

        for (var index = 0; index < entries.length; index++) {
            if (logEntryId(entries[index]) === id)
                return index;
        }

        return -1;
    }

    function readSince(anchorId, lines) {
        return callLogRead(lines, false, true).then(function(entries) {
            if (!Array.isArray(entries))
                throw new Error(_('Runtime log returned an invalid line list.'));

            if (anchorId == null)
                return appendLogEntries(entries, false);

            var anchorIndex = findLogId(entries, anchorId);
            if (anchorIndex >= 0)
                return appendLogEntries(entries.slice(anchorIndex + 1), false);

            if (lines < LOG_HISTORY_LINES)
                return readSince(anchorId, LOG_HISTORY_LINES);

            return appendLogEntries(entries, true);
        });
    }

    function requestIncremental(anchorId) {
        if (paused || !pageVisible || logRequest)
            return logRequest || Promise.resolve();

        logRequest = readSince(anchorId, LOG_CATCHUP_LINES).catch(function(error) {
            if (pageVisible)
                console.warn(error);
            return null;
        }).then(function(result) {
            logRequest = null;
            return result;
        });

        return logRequest;
    }

    function stopFallbackPolling() {
        if (!fallbackPolling)
            return;

        poll.remove(fallbackPoll);
        fallbackPolling = false;
    }

    function fallbackPoll() {
        if (paused || !pageVisible)
            return Promise.resolve();

        var anchorId = lastLogId;
        return requestIncremental(anchorId).then(function() {
            if (!streamUnsupported && !streamStarting && !streamActive && Date.now() >= nextStreamRetryAt)
                startLogStream(lastLogId);
        });
    }

    function startFallbackPolling() {
        if (fallbackPolling || paused || !pageVisible)
            return;

        fallbackPolling = true;
        wlocUi.setState(logState, 'notice', _('Live'));
        poll.add(fallbackPoll, LOG_FALLBACK_POLL_INTERVAL);
        fallbackPoll();
    }

    function stopLogStream() {
        if (streamController)
            streamController.abort();

        streamController = null;
        streamStarting = false;
        streamActive = false;
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
            appendLogEntries([ JSON.parse(data.join('\n')) ], false);
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
                var frame = state.buffer.slice(0, boundary);
                state.buffer = state.buffer.slice(boundary + 2);
                consumeSseFrame(frame);
            }

            if (controller.signal.aborted)
                return null;

            return pumpLogStream(reader, decoder, controller, state);
        });
    }

    function startLogStream(anchorId) {
        if (paused || !pageVisible || streamUnsupported || streamStarting || streamActive)
            return Promise.resolve(false);

        if (typeof fetch !== 'function' || typeof TextDecoder !== 'function' || typeof AbortController !== 'function') {
            streamUnsupported = true;
            startFallbackPolling();
            return Promise.resolve(false);
        }

        var controller = new AbortController();
        streamController = controller;
        streamStarting = true;

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
            if (!response.ok || !response.body) {
                if ([ 404, 405, 501 ].indexOf(response.status) >= 0)
                    streamUnsupported = true;
                throw new Error('log subscription HTTP ' + response.status);
            }

            streamStarting = false;
            streamActive = true;
            nextStreamRetryAt = 0;
            stopFallbackPolling();
            wlocUi.setState(logState, 'ok', _('Live'));

            requestIncremental(anchorId);

            return pumpLogStream(
                response.body.getReader(),
                new TextDecoder(),
                controller,
                { buffer: '' }
            );
        }).catch(function(error) {
            if (streamController === controller)
                streamController = null;
            streamStarting = false;
            streamActive = false;

            if (controller.signal.aborted)
                return false;

            console.warn(error);
            nextStreamRetryAt = Date.now() + LOG_STREAM_RETRY_MS;
            startFallbackPolling();
            return false;
        });
    }

    function bootstrapLogs() {
        return callLogRead(LOG_HISTORY_LINES, false, true).then(function(entries) {
            appendLogEntries(entries, true);
            return startLogStream(lastLogId);
        }).catch(function(error) {
            console.warn(error);
            startFallbackPolling();
            if (!fallbackPolling)
                wlocUi.setState(logState, 'warn', _('Unavailable'));
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
            stopFallbackPolling();
            wlocUi.setState(logState, 'notice', _('Paused'));
            return Promise.resolve();
        }

        wlocUi.setState(logState, 'ok', _('Connecting'));
        return startLogStream(lastLogId).then(function(started) {
            if (!started && !streamActive)
                startFallbackPolling();
        });
    }));

    window.addEventListener('pagehide', function() {
        pageVisible = false;
        stopLogStream();
        stopFallbackPolling();
    }, { once: true });

    bootstrapLogs();

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
            var oldLog = root.querySelector('textarea[aria-label="' + _('Current-session in-memory log') + '"]');
            var oldSection = oldLog && oldLog.closest ? oldLog.closest('.cbi-section') : null;
            var legacyRuntimeToggle = root.querySelector('[id$=".runtime_log"]');
            var legacyRuntimeRow = legacyRuntimeToggle && legacyRuntimeToggle.closest
                ? legacyRuntimeToggle.closest('.cbi-value') : null;

            if (oldSection)
                oldSection.remove();
            if (legacyRuntimeRow)
                legacyRuntimeRow.remove();

            root.appendChild(runtimeLogSection());
            return root;
        });
    }
});
