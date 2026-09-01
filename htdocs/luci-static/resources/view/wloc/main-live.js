'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require uci';
'require wloc.ui as wlocUi';
'require wloc.overview as wlocOverview';

var callStatus = rpc.declare({ object: 'luci.wloc', method: 'status', expect: {} });
var callRouting = rpc.declare({ object: 'luci.wloc.routing', method: 'read', expect: {} });
var callStart = rpc.declare({ object: 'luci.wloc.service', method: 'start', expect: {} });
var callStop = rpc.declare({ object: 'luci.wloc.service', method: 'stop', expect: {} });
var callRestart = rpc.declare({ object: 'luci.wloc.service', method: 'restart', expect: {} });
var callRegenerate = rpc.declare({ object: 'luci.wloc', method: 'regenerate_ca', expect: {} });

var LOG_TAG = 'wlocd';
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_RECONNECT_MS = 2000;
var ACTION_TIMEOUT = 20000;

function truthy(value) {
    return value === true || value === 1 || value === '1' || value === 'true';
}

function numberOrNull(value) {
    var number = Number(value);
    return isFinite(number) && number >= 0 ? number : null;
}

function tableRow(label, value) {
    return E('tr', { 'class': 'tr' }, [
        E('th', { 'class': 'th cbi-section-table-cell' }, label),
        E('td', { 'class': 'td cbi-section-table-cell' }, value)
    ]);
}

function formatUptime(startedAt) {
    var started = numberOrNull(startedAt);
    if (started === null || started <= 0)
        return '—';

    var seconds = Math.max(0, Math.floor(Date.now() / 1000 - started));
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor(seconds % 86400 / 3600);
    var minutes = Math.floor(seconds % 3600 / 60);

    if (days > 0)
        return _('%sd %sh %sm').format(days, hours, minutes);
    if (hours > 0)
        return _('%sh %sm').format(hours, minutes);
    if (minutes > 0)
        return _('%sm').format(minutes);
    return _('%ss').format(seconds);
}

function actionText(action) {
    if (action === 'start')
        return _('Start');
    if (action === 'stop')
        return _('Stop');
    if (action === 'restart')
        return _('Restart');
    return _('Service action');
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

function removeEmbeddedCaSection(node) {
    if (!node || !node.querySelectorAll)
        return;

    Array.prototype.forEach.call(node.querySelectorAll('.cbi-section-title'), function(title) {
        if (String(title.textContent || '').trim() !== _('Root CA'))
            return;
        var section = title.closest ? title.closest('.cbi-section') : title.parentNode;
        if (section && section.parentNode)
            section.parentNode.removeChild(section);
    });
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), {}),
            uci.load('system').catch(function() { return {}; }),
            wlocOverview.load(),
            L.resolveDefault(callRouting(), {})
        ]);
    },

    render: function(data) {
        document.title = _('WLOC | Overview');

        var initial = data && data[0] || {};
        var initialRouting = data && data[3] || {};
        var service = E('span', { 'aria-live': 'polite' });
        var uptime = E('span');
        var firewall = E('span', { 'aria-live': 'polite' });
        var routing = E('span', { 'aria-live': 'polite' });
        var caFingerprint = E('span', { 'aria-live': 'polite' });
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var serviceButtons = [];
        var regenerateButton = null;
        var pageVisible = true;
        var statusRequest = null;
        var actionInProgress = false;
        var actionDeadline = 0;
        var lastStatus = null;
        var overviewController = wlocOverview.create(data && data[2] || {}, initial, refreshStatus);

        function setMessage(state, value) {
            if (!value) {
                message.className = 'cbi-section-descr';
                message.textContent = '';
                return;
            }
            wlocUi.setState(message, state, value);
        }

        function updateActionButtons() {
            var runningKnown = lastStatus && lastStatus.running !== undefined;
            var running = runningKnown && truthy(lastStatus.running);
            var enabled = lastStatus && truthy(lastStatus.enabled);

            serviceButtons.forEach(function(button) {
                button.node.disabled = actionInProgress || !runningKnown ||
                    (button.name === 'start' && (running || !enabled)) ||
                    (button.name === 'stop' && !running);
            });

            if (regenerateButton)
                regenerateButton.disabled = actionInProgress || !enabled;
        }

        function applyStatus(result, routingResult) {
            result = result || {};
            routingResult = routingResult || {};
            lastStatus = result;

            var runningKnown = result.running !== undefined;
            var running = runningKnown && truthy(result.running);
            var firewallKnown = result.firewall_active !== undefined;
            var firewallActive = firewallKnown && truthy(result.firewall_active);
            var routingKnown = routingResult.ok === true && routingResult.route_active !== undefined;
            var routingActive = routingKnown && truthy(routingResult.route_active);
            var reason = String(result.service_reason || '');

            wlocUi.setState(service, running ? 'ok' : runningKnown ? 'warn' : 'notice',
                runningKnown ? (running ? _('Running') : _('Stopped')) : _('Unavailable'));
            wlocUi.setText(uptime, running ? formatUptime(result.session_started_at) : '—');
            wlocUi.setState(firewall, firewallActive ? 'ok' : firewallKnown ? 'warn' : 'notice',
                firewallKnown ? (firewallActive ? _('Active') : _('Inactive')) : _('Unavailable'));
            wlocUi.setText(caFingerprint, result.fingerprint || _('Not generated'));

            if (!routingKnown) {
                wlocUi.setState(routing, 'notice', _('Unavailable'));
            } else if (routingActive) {
                wlocUi.setState(routing, 'ok', _('Active · IPv4'));
            } else {
                wlocUi.setState(routing, 'warn', _('Inactive'));
            }

            if (!actionInProgress)
                setMessage(reason ? 'error' : 'notice', reason);

            overviewController.updateStatus(result);
            updateActionButtons();
            return result;
        }

        function showStatusUnavailable(error) {
            if (!lastStatus) {
                wlocUi.setState(service, 'notice', _('Unavailable'));
                wlocUi.setText(uptime, '—');
                wlocUi.setState(firewall, 'notice', _('Unavailable'));
                wlocUi.setState(routing, 'notice', _('Unavailable'));
                wlocUi.setText(caFingerprint, _('Unavailable'));
            }
            if (error && !actionInProgress)
                console.warn(error);
            updateActionButtons();
        }

        function readRuntimeStatus() {
            return Promise.all([
                callStatus(),
                L.resolveDefault(callRouting(), {})
            ]);
        }

        function refreshStatus() {
            if (!pageVisible || statusRequest)
                return statusRequest || Promise.resolve();

            statusRequest = readRuntimeStatus().then(function(results) {
                return applyStatus(results[0], results[1]);
            }).catch(function(error) {
                showStatusUnavailable(error);
                return null;
            }).then(function(result) {
                statusRequest = null;
                return result;
            });
            return statusRequest;
        }

        function waitForLifecycle(action) {
            return readRuntimeStatus().then(function(results) {
                var result = results[0] || {};
                applyStatus(result, results[1]);
                var running = truthy(result.running);
                var complete = action === 'stop' ? !running : running;

                if (complete)
                    return result;
                if (Date.now() >= actionDeadline)
                    throw new Error(_('WLOC did not reach the requested state within 20 seconds.'));

                setMessage('notice', action === 'stop' ? _('Stopping WLOC...') : _('Starting WLOC...'));
                return new Promise(function(resolve) {
                    window.setTimeout(resolve, 750);
                }).then(function() {
                    return waitForLifecycle(action);
                });
            });
        }

        function serviceAction(action) {
            var request = action === 'start' ? callStart : action === 'stop' ? callStop : callRestart;
            actionInProgress = true;
            actionDeadline = Date.now() + ACTION_TIMEOUT;
            setMessage('notice', _('%s requested...').format(actionText(action)));
            updateActionButtons();

            return request().then(function(result) {
                if (result && result.ok === false)
                    throw new Error(result.error || _('Service action failed.'));
                return waitForLifecycle(action);
            }).then(function(result) {
                setMessage('ok', action === 'start' ? _('WLOC started.') : action === 'stop' ? _('WLOC stopped.') : _('WLOC restarted.'));
                return result;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Service action failed.')));
                return false;
            }).then(function(result) {
                actionInProgress = false;
                updateActionButtons();
                return result;
            });
        }

        function regenerateCa() {
            actionInProgress = true;
            setMessage('notice', _('Regenerating Root CA...'));
            updateActionButtons();

            return callRegenerate().then(function(result) {
                if (result && result.ok === false)
                    throw new Error(String(result.detail || result.error || result.error_code || _('Unable to regenerate the Root CA.')));
                return refreshStatus();
            }).then(function() {
                setMessage('ok', _('Root CA regenerated. Reinstall and trust it on the iPhone.'));
                return true;
            }).catch(function(error) {
                setMessage('error', wlocUi.errorMessage(error, _('Unable to regenerate the Root CA.')));
                return false;
            }).then(function(result) {
                actionInProgress = false;
                updateActionButtons();
                return result;
            });
        }

        function confirmRegenerateCa() {
            return new Promise(function(resolve, reject) {
                ui.showModal(_('Regenerate Root CA'), [
                    E('p', { 'class': 'alert-message warning' },
                        _('Regenerating the Root CA permanently replaces the current CA. Devices that trust the existing CA will stop trusting WLOC until the new CA is installed and trusted.')),
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
                                Promise.resolve().then(regenerateCa).then(resolve, reject);
                            }
                        }, _('Regenerate CA'))
                    ])
                ]);
            });
        }

        function serviceButton(name, title, className) {
            var button = E('button', {
                'class': 'btn cbi-button ' + className,
                'type': 'button'
            }, title);
            serviceButtons.push({ name: name, node: button });
            button.addEventListener('click', ui.createHandlerFn(button, function() {
                return serviceAction(name);
            }));
            return button;
        }

        applyStatus(initial, initialRouting);
        poll.add(refreshStatus, L.env.pollinterval);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshStatus);
        }, { once: true });

        return overviewController.render().then(function(overviewForm) {
            removeEmbeddedCaSection(overviewForm);

            regenerateButton = E('button', {
                'class': 'btn cbi-button cbi-button-negative',
                'type': 'button'
            }, _('Regenerate CA'));
            regenerateButton.addEventListener('click', ui.createHandlerFn(regenerateButton, confirmRegenerateCa));

            var root = E('div', { 'class': 'cbi-map' }, [
                E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Overview')),
                E('div', { 'class': 'cbi-map-descr' }, _('WLOC process, runtime integration, AP locations, Root CA and live log.')),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', { 'class': 'cbi-section-title' }, _('Runtime')),
                    E('table', { 'class': 'table cbi-section-table' }, [
                        E('tbody', {}, [
                            tableRow(_('WLOC'), service),
                            tableRow(_('Uptime'), uptime),
                            tableRow(_('Firewall'), firewall),
                            tableRow(_('Routing'), routing),
                            tableRow(_('Root CA SHA-256'), caFingerprint)
                        ])
                    ]),
                    E('div', { 'class': 'cbi-page-actions' }, [
                        serviceButton('start', _('Start'), 'cbi-button-positive'),
                        serviceButton('restart', _('Restart'), 'cbi-button-positive'),
                        E('a', { 'class': 'btn cbi-button cbi-button-action', href: '/wloc-ca.mobileconfig' }, _('Download CA')),
                        serviceButton('stop', _('Stop'), 'cbi-button-negative'),
                        regenerateButton
                    ]),
                    message
                ]),
                overviewForm,
                runtimeLogSection()
            ]);

            updateActionButtons();
            return root;
        });
    }
});
