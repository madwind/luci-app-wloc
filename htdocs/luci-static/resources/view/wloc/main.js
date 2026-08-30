'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({ object: 'luci.wloc', method: 'status', expect: {} });
var callLogs = rpc.declare({ object: 'luci.wloc', method: 'logs', expect: {} });
var callRestart = rpc.declare({ object: 'luci.wloc', method: 'restart', expect: {} });
var callRegenerate = rpc.declare({ object: 'luci.wloc', method: 'regenerate_ca', expect: {} });
var callConfiguredAccessPoints = rpc.declare({ object: 'luci.wloc', method: 'configured_access_points', expect: {} });

function truthy(value) {
    return value === true || value === 1 || value === '1' || value === 'true';
}

function validIfname(value) {
    return /^[A-Za-z0-9_.-]{1,15}$/.test(String(value || ''));
}

function interceptionState(status) {
    status = status || {};
    if (!truthy(status.enabled))
        return { label: 'Disabled', tone: 'neutral', detail: 'none' };
    if (truthy(status.path_conflict))
        return {
            label: 'Traffic conflict',
            tone: 'error',
            detail: 'Transparent-proxy traffic is not reaching the WLOC listener.'
        };
    if (!truthy(status.running))
        return {
            label: 'Error',
            tone: 'error',
            detail: status.service_reason || status.last_error ||
                'The service is not running. Check the system log for the startup error.'
        };
    if (!truthy(status.armed))
        return {
            label: 'Recovering',
            tone: 'warning',
            detail: 'Retrying interception rules…',
            reason: status.service_reason || status.last_error || ''
        };
    if (!truthy(status.firewall_active))
        return {
            label: 'Error',
            tone: 'error',
            detail: status.service_reason || 'Firewall rules are not active.'
        };
    return {
        label: 'Active',
        tone: 'success',
        detail: 'active',
        configured_aps: Number(status.configured_aps) || 0
    };
}

function actionButton(label, className, handler) {
    return E('button', {
        'class': 'cbi-button ' + className,
        'type': 'button',
        'click': ui.createHandlerFn(this, handler)
    }, label);
}

function coordinateValidator(minimum, maximum) {
    return function(sectionId, value) {
        var number = Number(value);
        return value !== '' && isFinite(number) && number >= minimum && number <= maximum
            ? true : _('Enter a number from %s to %s.').format(minimum, maximum);
    };
}

function relativeTime(timestamp) {
    var seconds = Math.max(0, Math.floor(Date.now() / 1000 - Number(timestamp)));
    if (seconds < 60)
        return _('Just now');
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return minutes === 1 ? _('1 min ago') : _('%d min ago').format(minutes);
    var hours = Math.floor(minutes / 60);
    if (hours < 24)
        return hours === 1 ? _('1 hr ago') : _('%d hr ago').format(hours);
    var days = Math.floor(hours / 24);
    return days === 1 ? _('1 day ago') : _('%d days ago').format(days);
}

function updateRelativeTime(node, timestamp) {
    if (!node)
        return;
    if (!Number(timestamp)) {
        node.textContent = _('Never');
        node.removeAttribute('title');
        return;
    }
    var date = new Date(Number(timestamp) * 1000);
    node.textContent = relativeTime(timestamp);
    node.title = date.toLocaleString();
}

function lookupIpInfo(ip) {
    return fetch('https://ipinfo.io/' + encodeURIComponent(ip) + '/json', {
        'method': 'GET',
        'cache': 'no-store',
        'headers': { 'accept': 'application/json' }
    }).then(function(response) {
        if (!response.ok)
            throw new Error(_('ipinfo.io returned HTTP %s').format(response.status));
        return response.json();
    }).then(function(result) {
        var coordinates = String(result.loc || '').split(',');
        if (coordinates.length !== 2 || !isFinite(Number(coordinates[0])) || !isFinite(Number(coordinates[1])))
            throw new Error(_('ipinfo.io returned no valid coordinates'));
        return {
            latitude: coordinates[0],
            longitude: coordinates[1],
            country: result.country || '',
            location: [ result.city, result.region, result.timezone ].filter(Boolean).join(' · ')
        };
    });
}

function callWirelessAccessPoints() {
    return callConfiguredAccessPoints().catch(function() { return {}; }).then(function(result) {
        return { access_points: Array.isArray(result && result.access_points) ? result.access_points : [] };
    });
}

return view.extend({
    load: function() {
        return Promise.all([
            uci.load('wloc'),
            uci.load('wireless').catch(function() { return {}; }),
            // The configured inventory remains available while hostapd is restarting;
            // runtime fields are only metadata on those stable entries.
            callWirelessAccessPoints(),
            callStatus().catch(function() { return {}; }),
            callLogs().catch(function() { return {}; })
        ]);
    },

    render: function(data) {
        var accessPoints = data[2].access_points || [];
        var initialStatus = data[3] || {};
        var initialLogs = (data[4] || {}).logs || '';
        var lastLogRevision = initialLogs
            ? String(initialStatus.session_started_at || 0) + ':' + String(initialStatus.runtime_log_revision || 0)
            : '';
        var lookupResultNodes = {};
        var lastUpdatedNodes = {};
        var lastResultNodes = {};
        var configuredWireless = [];
        var configuredWirelessKeys = {};

        function addConfiguredWireless(source) {
            var ssid = String(source && source.ssid || '');
            var section = String(source && source.section || '');
            var iface = String(source && (source.iface || source.ifname) || '');
            var key = section;
            if (!section || !validIfname(iface) || configuredWirelessKeys[key])
                return;
            configuredWirelessKeys[key] = true;
            configuredWireless.push({
                ssid: ssid,
                section: section,
                iface: iface,
                disabled: truthy(source && source.disabled),
                active: truthy(source && (source.active || source.up)),
                missing: truthy(source && source.missing)
            });
        }

        accessPoints.forEach(addConfiguredWireless);
        // Keep a local fallback visible if rpcd is temporarily unavailable. The
        // fixed interface remains the only value that can be saved.
        uci.sections('wireless', 'wifi-iface').forEach(function(wifi) {
            var mode = String(wifi.mode || 'ap');
            if ([ 'ap', 'ap-wds' ].indexOf(mode) < 0 || configuredWirelessKeys[wifi['.name']])
                return;
            addConfiguredWireless({
                section: wifi['.name'],
                ssid: wifi.ssid,
                ifname: wifi.ifname,
                disabled: wifi.disabled,
                active: false,
            });
        });

        function rememberNode(nodes, sectionId, node) {
            if (!nodes[sectionId])
                nodes[sectionId] = [];
            nodes[sectionId].push(node);
        }

        function updateNodes(nodes, sectionId, update) {
            (nodes[sectionId] || []).forEach(update);
        }

        var map = new form.Map('wloc', _('WLOC'),
            _('Version %s · Bind each Apple WLOC location to one fixed interface.').format(initialStatus.version || _('unknown')));

        var profileUrl = '/wloc-ca.mobileconfig';
        var settings = map.section(form.NamedSection, 'main', 'wloc', _('Service settings'));
        settings.anonymous = true;
        var option = settings.option(form.Flag, 'enabled', _('Enable location interception'));
        option.default = '0';
        option.rmempty = false;
        var serviceStatusOption = settings.option(form.DummyValue, '_service_status', _('Interception status'));
        serviceStatusOption.rmempty = true;
        serviceStatusOption.cfgvalue = function() { return 'status'; };
        serviceStatusOption.renderWidget = function() {
            return E('div', {
                'class': 'wloc-status-row',
                'style': 'display: flex; align-items: flex-start; gap: 1em; flex-wrap: wrap;'
            }, [
                statusNode,
                actionButton.call(this, _('Restart service'), 'cbi-button', function() {
                    return callRestart().then(function() {
                        return refresh();
                    }).catch(function(error) {
                        ui.addNotification(null, E('p', {}, _('Action failed: %s').format(error.message || error)), 'error');
                    });
                })
            ]);
        };
        option = settings.option(form.Value, 'listen_port', _('Local listen port'));
        option.datatype = 'port';
        option.default = '61520';
        option.rmempty = false;
        option.description = _('Normally this should not be changed. If your custom nftables rules redirect traffic to WLOC, use the same port. WLOC does not inspect or enforce redirect rules; a mismatched rule simply will not send traffic to the listener.');
        var domainsOption = settings.option(form.DummyValue, '_intercepted_domains', _('Intercepted domains'));
        domainsOption.rmempty = true;
        domainsOption.cfgvalue = function() { return 'gs-loc.apple.com\ngs-loc-cn.apple.com'; };
        domainsOption.renderWidget = function() {
            return E('div', { 'class': 'wloc-fixed-domains' }, [
                E('code', {}, 'gs-loc.apple.com'),
                E('br'),
                E('code', {}, 'gs-loc-cn.apple.com')
            ]);
        };
        domainsOption.description = _('Apple WLOC endpoints intercepted by this service.');
        option = settings.option(form.Flag, 'debug', _('Debug: fixed JSON response'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('When enabled, requests to the fixed Apple WLOC endpoints return {"wloc":"ok"} without contacting the upstream server.');
        option = settings.option(form.Flag, 'runtime_log', _('Enable runtime log'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('Keeps detailed request and coordinate events in RAM until the service restarts. Leave disabled to avoid continuous log allocation and updates.');
        var caOption = settings.option(form.DummyValue, '_ca_certificate', _('iPhone root certificate'));
        caOption.rmempty = true;
        caOption.cfgvalue = function() { return 'certificate'; };
        caOption.renderWidget = function() {
            return E('div', {}, [
                E('div', { 'class': 'cbi-section-descr' }, _('After installing the profile, explicitly enable full trust in iOS Certificate Trust Settings.')),
                E('div', { 'class': 'cbi-page-actions' }, [
                    E('a', { 'class': 'cbi-button cbi-button-action', 'href': profileUrl }, _('Download CA profile')),
                    actionButton.call(this, _('Regenerate CA'), 'cbi-button-negative', function() {
                        return notifyAction(callRegenerate(), _('The Root CA was regenerated. Reinstall and trust it on the iPhone.'));
                    })
                ]),
                fingerprintNode
            ]);
        };

    var wifiSections = map.section(form.GridSection, 'wifi', _('AP location'),
        _('Select an exact fixed interface and assign one virtual location to clients connected through that AP.'));
    wifiSections.anonymous = true;
    wifiSections.addremove = true;
    wifiSections.sortable = true;
    wifiSections.nodescriptions = true;
    wifiSections.addbtntitle = _('Add AP');

    var ifaceOption = wifiSections.option(form.ListValue, 'iface', _('Interface'));
    // Keep the interface selector in both the table and the Add/Edit modal.
    ifaceOption.modalonly = null;
    ifaceOption.rmempty = false;
    ifaceOption.description = _('Select the exact fixed interface name from a wifi-iface. Interfaces without a fixed ifname are not shown.');
    if (!accessPoints.length && configuredWireless.length)
        ifaceOption.description = _('Live AP status is not ready; configured interfaces remain selectable.');
    if (!configuredWireless.length)
        ifaceOption.description = _('No configured AP was found in wireless. Add a wifi-iface with a fixed ifname before creating a WLOC rule.');
    var knownIfaces = [];
    var ifaceCounts = {};
    configuredWireless.forEach(function(ap) {
        ifaceCounts[ap.iface] = (ifaceCounts[ap.iface] || 0) + 1;
    });
    function addIfaceChoice(ap) {
        var iface = String(ap && ap.iface || '');
        if (!iface || knownIfaces.indexOf(iface) >= 0)
            return;
        knownIfaces.push(iface);
        var label = iface;
        if (ap.missing)
            label += ' (' + _('not found') + ')';
        else if (ifaceCounts[iface] > 1)
            label += ' — ' + _('duplicate; cannot be selected');
        else if (!ap.active)
            label += ' (' + _('offline') + ')';
        ifaceOption.value(iface, label);
    }
    configuredWireless.forEach(addIfaceChoice);
    uci.sections('wloc', 'wifi').forEach(function(wifi) {
        var iface = String(wifi.iface || '');
        if (iface && knownIfaces.indexOf(iface) < 0)
            addIfaceChoice({ iface: iface, active: false, missing: true });
    });
    ifaceOption.cfgvalue = function(sectionId) {
        return String(uci.get('wloc', sectionId, 'iface') || '');
    };
    ifaceOption.write = function(sectionId, value) {
        value = String(value || '');
        uci.set('wloc', sectionId, 'iface', value);
        uci.unset('wloc', sectionId, 'ssid');
        uci.unset('wloc', sectionId, 'migration_pending');
    };
    ifaceOption.validate = function(sectionId, value) {
        value = String(value || '');
        var matches = configuredWireless.filter(function(candidate) { return candidate.iface === value; });
        if (!matches.length || matches.some(function(candidate) { return candidate.missing; }))
            return _('Configured interface "%s" was not found.').format(value);
        if (matches.length > 1)
            return _('Interface "%s" is used by multiple APs and cannot be selected by WLOC.').format(value);
        return true;
    };

    function accessPointForRule(sectionId) {
        var iface = String(uci.get('wloc', sectionId, 'iface') || '');
        return configuredWireless.find(function(candidate) { return candidate.iface === iface; });
    }

    var wifiStateOption = wifiSections.option(form.DummyValue, '_wifi_state', _('AP status'));
    wifiStateOption.modalonly = false;
    wifiStateOption.cfgvalue = wifiStateOption.textvalue = function(sectionId) {
        var iface = String(uci.get('wloc', sectionId, 'iface') || '');
        var ap = accessPointForRule(sectionId);
        if (!ap)
            return iface ? _('Configured interface "%s" was not found.').format(iface) : _('Unavailable');
        if (ifaceCounts[iface] > 1)
            return _('Ambiguous');
        if (ap.active && !ap.disabled)
            return _('On');
        if (ap && ap.disabled)
            return _('Off');
        return _('Offline');
    };

    var ssidOption = wifiSections.option(form.DummyValue, '_ssid', _('SSID'));
    ssidOption.modalonly = false;
    ssidOption.cfgvalue = ssidOption.textvalue = function(sectionId) {
        var ap = accessPointForRule(sectionId);
        return ap && ap.ssid ? ap.ssid : _('Unavailable');
    };

    var enabledOption = wifiSections.option(form.Flag, 'enabled', _('Enabled'));
    enabledOption.modalonly = true;
    enabledOption.default = '1';
    enabledOption.rmempty = false;

        var scheduleEnabledOption = wifiSections.option(form.Flag, 'schedule_enabled', _('Scheduled disable'));
        scheduleEnabledOption.modalonly = true;
        scheduleEnabledOption.default = '0';
        scheduleEnabledOption.rmempty = false;
    scheduleEnabledOption.description = _('Actually disable the selected interface during this window with a temporary disabled=1 override and WiFi reload. Nothing is committed, and a missing interface never falls back to another AP or the whole wireless configuration.');

        function scheduleTimeValidator(sectionId, value) {
            return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(String(value || ''))
                ? true : _('Enter a time in HH:MM format.');
        }

        var scheduleStartOption = wifiSections.option(form.Value, 'schedule_start', _('Disable from'));
        scheduleStartOption.modalonly = true;
        scheduleStartOption.depends('schedule_enabled', '1');
        scheduleStartOption.default = '22:00';
        scheduleStartOption.rmempty = false;
        scheduleStartOption.placeholder = '22:00';
        scheduleStartOption.validate = scheduleTimeValidator;

        var scheduleEndOption = wifiSections.option(form.Value, 'schedule_end', _('Restore at'));
        scheduleEndOption.modalonly = true;
        scheduleEndOption.depends('schedule_enabled', '1');
        scheduleEndOption.default = '06:00';
        scheduleEndOption.rmempty = false;
        scheduleEndOption.placeholder = '06:00';
        scheduleEndOption.description = _('If the end is earlier than the start, the window crosses midnight. Equal times mean all day.');
        scheduleEndOption.validate = scheduleTimeValidator;

        var latitudeOption = wifiSections.option(form.Value, 'latitude', _('Latitude'));
        latitudeOption.modalonly = true;
        latitudeOption.rmempty = false;
        latitudeOption.description = _('Fixed virtual baseline for every device connected through this AP.');
        latitudeOption.validate = coordinateValidator(-90, 90);

        var longitudeOption = wifiSections.option(form.Value, 'longitude', _('Longitude'));
        longitudeOption.modalonly = true;
        longitudeOption.rmempty = false;
        longitudeOption.validate = coordinateValidator(-180, 180);

        var proxyTypeOption = wifiSections.option(form.ListValue, 'proxy_type', _('Outbound'));
        proxyTypeOption.modalonly = true;
        proxyTypeOption.value('direct', _('Direct'));
        proxyTypeOption.value('http', _('HTTP proxy'));
        proxyTypeOption.value('socks5', _('SOCKS5 proxy'));
        proxyTypeOption.default = 'direct';
        proxyTypeOption.rmempty = false;

        var proxyHostOption = wifiSections.option(form.Value, 'proxy_host', _('Proxy host'));
        proxyHostOption.modalonly = true;
        proxyHostOption.rmempty = false;
        proxyHostOption.placeholder = '192.0.2.10';
        proxyHostOption.description = _('Hostname or IP address of the outbound proxy. DNS for the Apple destination is resolved by the proxy.');
        proxyHostOption.depends('proxy_type', 'http');
        proxyHostOption.depends('proxy_type', 'socks5');
        proxyHostOption.validate = function(sectionId, value) {
            return value && value.length <= 253 && !/[\s\x00-\x1f\x7f]/.test(value)
                ? true : _('Enter a valid proxy hostname or IP address.');
        };

        var proxyPortOption = wifiSections.option(form.Value, 'proxy_port', _('Proxy port'));
        proxyPortOption.modalonly = true;
        proxyPortOption.rmempty = false;
        proxyPortOption.datatype = 'port';
        proxyPortOption.placeholder = '1080';
        proxyPortOption.depends('proxy_type', 'http');
        proxyPortOption.depends('proxy_type', 'socks5');
        proxyPortOption.description = _('HTTP CONNECT and SOCKS5 proxies without authentication are supported.');

        var lastUpdatedOption = wifiSections.option(form.DummyValue, '_last_updated', _('Last updated'));
        lastUpdatedOption.modalonly = false;
        lastUpdatedOption.rmempty = true;
        lastUpdatedOption.cfgvalue = lastUpdatedOption.textvalue = function(sectionId) {
            var activity = apActivity(sectionId, initialStatus);
            var node = E('span', {});
            rememberNode(lastUpdatedNodes, sectionId, node);
            updateRelativeTime(node, activity && activity.last_location_at);
            return node;
        };

        function renderApResult(node, activity) {
            var hasActivity = !!activity;
            var success = hasActivity && truthy(activity.success);
            var error = hasActivity && !success ? String(activity.last_error || '') : '';
            node.className = hasActivity ? (success ? 'success' : 'warning') : '';
            node.textContent = hasActivity
                ? (success ? _('Success') : (error ? _('Failed: %s').format(error) : _('Failed')))
                : _('Never');
            node.title = error;
        }

        var lastResultOption = wifiSections.option(form.DummyValue, '_last_result', _('Last result'));
        lastResultOption.modalonly = false;
        lastResultOption.rmempty = true;
        lastResultOption.cfgvalue = lastResultOption.textvalue = function(sectionId) {
            var node = E('span', {});
            renderApResult(node, apActivity(sectionId, initialStatus));
            rememberNode(lastResultNodes, sectionId, node);
            return node;
        };

        var ipOption = wifiSections.option(form.Value, 'ip', _('IP address'));
        ipOption.modalonly = true;
        ipOption.rmempty = true;
        ipOption.placeholder = '8.8.8.8';
        ipOption.description = _('Use ipinfo.io in this browser to fill the AP location coordinates.');

        var lookupButton = wifiSections.option(form.Button, '_lookup_action', _('IP location'));
        lookupButton.modalonly = true;
        lookupButton.rmempty = true;
        lookupButton.inputtitle = _('Fill from IP location');
        lookupButton.inputstyle = 'action';
        lookupButton.onclick = function(ev, sectionId) {
            var ip = String(ipOption.formvalue(sectionId) || '').trim();
            var resultNode = lookupResultNodes[sectionId];
            if (!ip) {
                if (resultNode)
                    resultNode.textContent = _('Enter an IPv4 or IPv6 address first.');
                return Promise.resolve();
            }
            if (resultNode)
                resultNode.replaceChildren(E('em', {}, _('Looking up with ipinfo.io…')));
            return lookupIpInfo(ip).then(function(result) {
                latitudeOption.getUIElement(sectionId).setValue(result.latitude);
                longitudeOption.getUIElement(sectionId).setValue(result.longitude);
                if (resultNode) {
                    resultNode.replaceChildren(
                        E('strong', {}, '%s, %s'.format(result.latitude, result.longitude)),
                        E('span', {}, _('Country: %s').format(result.country || _('Unknown'))),
                        E('span', {}, result.location || _('Location details unavailable'))
                    );
                }
            }).catch(function(error) {
                if (resultNode)
                    resultNode.textContent = _('Lookup failed: %s').format(error.message || error);
            });
        };

        var lookupResultOption = wifiSections.option(form.DummyValue, '_lookup_result', _('Lookup result'));
        lookupResultOption.modalonly = true;
        lookupResultOption.rmempty = true;
        lookupResultOption.renderWidget = function(sectionId) {
            var node = E('div', { 'class': 'cbi-section-descr' }, _('No lookup performed.'));
            lookupResultNodes[sectionId] = node;
            return node;
        };

        var statusNode = E('div', {
            'class': 'cbi-section-descr wloc-status-copy',
            'style': 'display: flex; flex: 1 1 auto; flex-direction: column; gap: 0.25em; margin: 0;'
        });
        var fingerprintNode = E('div', { 'class': 'cbi-section-descr' });
        var logNode = E('textarea', {
            'class': 'cbi-input-text',
            'style': 'display: block; width: 100%; min-height: 18em; box-sizing: border-box;',
            'wrap': 'off',
            'rows': '18',
            'readonly': true,
            'aria-label': _('Current-session in-memory log')
        }, initialLogs || _('No events in this session yet.'));
        var followRuntimeLog = true;

        function runtimeLogAtBottom() {
            return logNode.scrollHeight - logNode.scrollTop - logNode.clientHeight <= 8;
        }

        logNode.addEventListener('scroll', function() {
            followRuntimeLog = runtimeLogAtBottom();
        });

        function scrollRuntimeLogToBottom() {
            if (!logNode || !followRuntimeLog)
                return;
            logNode.scrollTop = logNode.scrollHeight;
            if (typeof requestAnimationFrame === 'function')
                requestAnimationFrame(function() { logNode.scrollTop = logNode.scrollHeight; });
        }

        function translateReason(reason) {
            if (!reason)
                return reason;
            var sep = reason.indexOf(': ');
            var key = sep >= 0 ? reason.slice(0, sep) : reason;
            var rest = sep >= 0 ? reason.slice(sep) : '';
            var translated = _(key);
            return translated !== key ? translated + rest : reason;
        }

        function renderStatus(status) {
            var state = interceptionState(status);
            var label = state.label === 'Disabled'
                ? _('Disabled') : '● ' + _(state.label);
            var detail = state.detail === 'active'
                ? _('%d APs · listener ready · interception armed').format(state.configured_aps)
                : _(state.detail);
            var badge = E('span', { 'class': 'wloc-status-badge ' + state.tone }, label);
            statusNode.replaceChildren(badge);
            if (detail && state.detail !== 'none')
                statusNode.appendChild(E('div', { 'class': 'wloc-status-detail ' + state.tone }, detail));
            if (state.reason)
                statusNode.appendChild(E('div', { 'class': 'wloc-status-reason' }, translateReason(state.reason)));
            fingerprintNode.replaceChildren(
                E('strong', {}, _('Root CA SHA-256: ')),
                E('span', {}, status.fingerprint || _('Generated on first start'))
            );
        }

        function apActivity(sectionId, status) {
            return (status.ap_activity || []).find(function(activity) {
                return String(activity.ap_id || '') === sectionId;
            });
        }

        function renderApActivity(status) {
            initialStatus = status;
            uci.sections('wloc', 'wifi').forEach(function(wifi) {
                var sectionId = wifi['.name'];
                var activity = apActivity(sectionId, status);
                updateNodes(lastUpdatedNodes, sectionId, function(node) {
                    updateRelativeTime(node, activity && activity.last_location_at);
                });
                updateNodes(lastResultNodes, sectionId, function(node) {
                    renderApResult(node, activity);
                });
            });
        }

        function renderRuntimeLog(status, logs) {
            var enabled = truthy(status.runtime_log_enabled);
            logNode.value = enabled ? (logs || _('No events in this session yet.'))
                : _('Runtime logging is disabled. Enable it in Service settings and Save & Apply to begin a new in-memory log.');
            scrollRuntimeLogToBottom();
        }

        function refreshRuntimeLog(status, force) {
            if (!truthy(status.runtime_log_enabled)) {
                lastLogRevision = '';
                renderRuntimeLog(status, '');
                return Promise.resolve();
            }
            var revision = String(status.session_started_at || 0) + ':' + String(status.runtime_log_revision || 0);
            if ((!force && document.visibilityState === 'hidden') || (!force && revision === lastLogRevision))
                return Promise.resolve();
            return callLogs().then(function(result) {
                lastLogRevision = revision;
                renderRuntimeLog(status, (result || {}).logs || '');
            });
        }

        function refresh() {
            return callStatus().then(function(status) {
                status = status || {};
                renderStatus(status);
                renderApActivity(status);
                return refreshRuntimeLog(status, false);
            }).catch(function() {
                // Keep the last known state visible when a single poll request fails.
            });
        }

        function notifyAction(promise, message) {
            return promise.then(function(result) {
                if (result && result.ok === false) {
                    var detail = result.detail || result.error || result.error_code || _('The action was not completed.');
                    throw new Error(String(detail));
                }
                var notification = typeof message === 'function' ? message(result || {}) : message;
                ui.addNotification(null, E('p', {}, notification), 'info');
                return refresh();
            }).catch(function(error) {
                ui.addNotification(null, E('p', {}, _('Action failed: %s').format(error.message || error)), 'error');
            });
        }

        renderStatus(initialStatus);
        renderRuntimeLog(initialStatus, initialLogs);
        document.addEventListener('visibilitychange', function() {
            if (document.visibilityState !== 'hidden')
                refresh();
        });
        window.addEventListener('focus', refresh);

        return map.render().then(function(formNode) {
            renderApActivity(initialStatus);
            scrollRuntimeLogToBottom();
            poll.add(refresh, 10);
            return E('div', {}, [
                formNode,
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', { 'class': 'cbi-section-title' }, _('Current-session in-memory log')),
                    E('div', { 'class': 'cbi-section-descr' }, _('Shows received requests, upstream responses and coordinates before and after patching. It is stored only in /var/run and is cleared on every service start.')),
                    logNode
                ])
            ]);
        }.bind(this));
    }
});
