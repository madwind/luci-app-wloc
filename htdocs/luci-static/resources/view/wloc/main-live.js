'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require uci';
'require wloc.ui as wlocUi';
'require wloc.overview as wlocOverview';

var callStatus = rpc.declare({ object: 'luci.wloc', method: 'status', expect: {} });
var callRestart = rpc.declare({ object: 'luci.wloc', method: 'restart', expect: {} });

var LOG_TAG = 'wlocd';
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_RECONNECT_MS = 2000;

function truthy(value) {
    return value === true || value === 1 || value === '1' || value === 'true';
}

function valueRow(label, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

function logDateFormatter() {
    var timezone = uci.get('system', '@system[0]', 'zonename');
    timezone = timezone ? String(timezone).replace(/ /g, '_') : undefined;

    try {
        return new Intl.DateTimeFormat('en-US', {
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', second: '2-digit',
            hourCycle: 'h23', timeZone: timezone
        });
    } catch (error) {
        return null;
    }
}

function formatLogTimestamp(date, formatter) {
    if (formatter && typeof formatter.formatToParts === 'function') {
        try {
            var values = {};
            formatter.formatToParts(date).forEach(function(part) {
                if (part.type !== 'literal')
                    values[part.type] = part.value;
            });
            if (values.year && values.month && values.day && values.hour && values.minute && values.second)
                return '%s-%s-%s %s:%s:%s'.format(values.year, values.month, values.day, values.hour, values.minute, values.second);
        } catch (error) {
            // Fall through to UTC below.
        }
    }
    return date.toISOString().slice(0, 19).replace('T', ' ');
}

function formatLogEntry(entry, formatter) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    var date = new Date(entry && entry.time);
    var timestamp = !isNaN(date.getTime()) ? formatLogTimestamp(date, formatter) : '';
    return timestamp ? '[' + timestamp + '] ' + message : message;
}

function runtimeLogSection() {
    var formatter = logDateFormatter();
    var logState = E('span', { 'aria-live': 'polite' }, _('Connecting'));
    var logFilter = E('input', {
        'class': 'cbi-input-text', 'type': 'search', 'placeholder': _('Filter'),
        'autocomplete': 'off', 'spellcheck': 'false', 'aria-label': _('Filter runtime log')
    });
    var logOutput = E('textarea', {
        'id': 'wloc-runtime-log', 'class': 'cbi-input-text',
        'style': 'display: block; width: 100%; min-height: 22em; box-sizing: border-box;',
        'rows': 20, 'wrap': 'off', 'spellcheck': 'false', 'readonly': true,
        'role': 'log', 'aria-label': _('WLOC runtime log')
    });
    var paused = false;
    var pageVisible = true;
    var followLogs = true;
    var logLines = [];
    var streamController = null;
    var reconnectTimer = null;

    function filteredLogLines() {
        var filter = logFilter.value.trim().toLowerCase();
        return filter ? logLines.filter(function(line) { return line.toLowerCase().indexOf(filter) !== -1; }) : logLines;
    }

    function renderLogs() {
        var oldScrollTop = logOutput.scrollTop;
        var wasAtBottom = followLogs;
        logOutput.value = filteredLogLines().join('\n');
        logOutput.scrollTop = wasAtBottom ? logOutput.scrollHeight : oldScrollTop;
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
            if (!line || line.charAt(0) === ':') return;
            if (line.indexOf('event:') === 0) eventName = line.slice(6).trim();
            else if (line.indexOf('data:') === 0) data.push(line.slice(5).trimStart());
        });
        if (eventName !== 'message' || !data.length) return;
        try { appendLogEntry(JSON.parse(data.join('\n'))); } catch (error) { console.warn(error); }
    }

    function pump(reader, decoder, controller, state) {
        return reader.read().then(function(chunk) {
            if (chunk.done) throw new Error('log subscription ended');
            state.buffer += decoder.decode(chunk.value, { stream: true }).replace(/\r\n/g, '\n');
            var boundary;
            while ((boundary = state.buffer.indexOf('\n\n')) >= 0) {
                consumeSseFrame(state.buffer.slice(0, boundary));
                state.buffer = state.buffer.slice(boundary + 2);
            }
            if (!controller.signal.aborted) return pump(reader, decoder, controller, state);
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
        if (streamController) streamController.abort();
        streamController = null;
    }

    function scheduleReconnect() {
        if (paused || !pageVisible || reconnectTimer !== null) return;
        wlocUi.setState(logState, 'notice', _('Reconnecting'));
        reconnectTimer = window.setTimeout(function() {
            reconnectTimer = null;
            startLogStream();
        }, LOG_RECONNECT_MS);
    }

    function startLogStream() {
        if (paused || !pageVisible || streamController) return Promise.resolve();
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
            headers: { 'Accept': 'text/event-stream', 'Authorization': 'Bearer ' + rpc.getSessionID() },
            credentials: 'same-origin', cache: 'no-store', signal: controller.signal
        }).then(function(response) {
            if (!response.ok || !response.body) throw new Error('log subscription HTTP ' + response.status);
            wlocUi.setState(logState, 'ok', _('Live'));
            return pump(response.body.getReader(), new TextDecoder(), controller, { buffer: '' });
        }).catch(function(error) {
            if (!controller.signal.aborted) console.warn(error);
        }).then(function() {
            if (streamController === controller) streamController = null;
            if (!controller.signal.aborted) scheduleReconnect();
        });
    }

    logOutput.addEventListener('scroll', function() {
        followLogs = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight <= 4;
    });
    logFilter.addEventListener('input', renderLogs);

    var pauseButton = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Pause'));
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
        E('div', { 'class': 'cbi-section-descr', 'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .5rem;' }, [
            logState,
            E('div', { 'style': 'display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; margin-left: auto;' }, [
                E('label', { 'style': 'display: inline-flex; align-items: center; gap: .5rem;' }, [ _('Filter'), logFilter ]),
                pauseButton
            ])
        ]),
        logOutput
    ]);
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), {}),
            uci.load('system').catch(function() { return {}; }),
            wlocOverview.load()
        ]);
    },

    render: function(data) {
        document.title = _('WLOC | Overview');

        var initial = data && data[0] || {};
        var version = E('span');
        var service = E('span', { 'aria-live': 'polite' });
        var interception = E('span', { 'aria-live': 'polite' });
        var firewall = E('span', { 'aria-live': 'polite' });
        var accessPoints = E('span');
        var detail = E('span');
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var pageVisible = true;
        var statusRequest = null;
        var overviewController = wlocOverview.create(data && data[2] || {}, initial, refreshStatus);

        function applyStatus(result) {
            result = result || {};
            var enabled = truthy(result.enabled);
            var running = truthy(result.running);
            var armed = truthy(result.armed);
            var firewallActive = truthy(result.firewall_active);
            var pathConflict = truthy(result.path_conflict);
            var reason = result.service_reason || result.last_error || '';

            wlocUi.setText(version, result.version || _('Unknown'));
            wlocUi.setState(service, running ? 'ok' : enabled ? 'warn' : 'notice', running ? _('Running') : enabled ? _('Stopped') : _('Disabled'));

            if (!enabled) wlocUi.setState(interception, 'notice', _('Disabled'));
            else if (pathConflict) wlocUi.setState(interception, 'error', _('Traffic conflict'));
            else if (!running) wlocUi.setState(interception, 'error', _('Error'));
            else if (!armed) wlocUi.setState(interception, 'warn', _('Recovering'));
            else if (!firewallActive) wlocUi.setState(interception, 'error', _('Error'));
            else wlocUi.setState(interception, 'ok', _('Active'));

            wlocUi.setState(firewall, firewallActive ? 'ok' : 'warn', firewallActive ? _('Active') : _('Inactive'));
            wlocUi.setText(accessPoints, String(Number(result.configured_aps) || 0));
            wlocUi.setText(detail, reason || '—');
            overviewController.updateStatus(result);
            return result;
        }

        function refreshStatus() {
            if (!pageVisible || statusRequest) return statusRequest || Promise.resolve();
            statusRequest = callStatus().then(applyStatus).catch(function(error) {
                wlocUi.setState(service, 'error', _('Unavailable'));
                wlocUi.setState(interception, 'error', _('Unavailable'));
                wlocUi.setState(firewall, 'error', _('Unavailable'));
                wlocUi.setText(detail, error && error.message ? error.message : _('Unable to read service status.'));
                return false;
            }).then(function(result) {
                statusRequest = null;
                return result;
            });
            return statusRequest;
        }

        var restart = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Restart service'));
        restart.addEventListener('click', ui.createHandlerFn(restart, function() {
            restart.disabled = true;
            wlocUi.setState(message, 'notice', _('Restarting WLOC...'));
            return callRestart().then(function(result) {
                if (result && result.ok === false) throw new Error(result.error || _('Restart failed.'));
                return refreshStatus();
            }).then(function() {
                wlocUi.setState(message, 'ok', _('WLOC restarted.'));
                return true;
            }).catch(function(error) {
                wlocUi.setState(message, 'error', wlocUi.errorMessage(error, _('Restart failed.')));
                return false;
            }).then(function(result) {
                restart.disabled = false;
                return result;
            });
        }));

        applyStatus(initial);
        poll.add(refreshStatus, 2);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshStatus);
        }, { once: true });

        return overviewController.render().then(function(overviewForm) {
            return E('div', { 'class': 'cbi-map' }, [
                E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Overview')),
                E('div', { 'class': 'cbi-map-descr' }, _('Service state, AP locations, Root CA and live WLOC runtime log.')),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', { 'class': 'cbi-section-title' }, _('Service')),
                    valueRow(_('Version'), version),
                    valueRow(_('Service status'), service),
                    valueRow(_('Interception status'), interception),
                    valueRow(_('Firewall'), firewall),
                    valueRow(_('Configured APs'), accessPoints),
                    valueRow(_('Detail'), detail),
                    valueRow(_('Actions'), restart),
                    message
                ]),
                overviewForm,
                runtimeLogSection()
            ]);
        });
    }
});
