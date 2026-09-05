'use strict';
'require baseclass';
'require form';
'require uci';
'require rpc';
'require dom';

var callConfiguredAccessPoints = rpc.declare({ object: 'luci.wloc', method: 'configured_access_points', expect: {} });

function truthy(value) {
    return value === true || value === 1 || value === '1' || value === 'true';
}

function validIfname(value) {
    return /^[A-Za-z0-9_.-]{1,15}$/.test(String(value || ''));
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
        method: 'GET',
        cache: 'no-store',
        headers: { accept: 'application/json' }
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
            city: result.city || '',
            region: result.region || '',
            timezone: result.timezone || ''
        };
    });
}

function modalUIElement(option, sectionId) {
    var node = document.getElementById(option.cbid(sectionId));
    var element = node ? dom.findClassInstance(node) : null;
    return element && typeof element.getValue === 'function' ? element : null;
}

function callWirelessAccessPoints() {
    return callConfiguredAccessPoints().catch(function() { return {}; }).then(function(result) {
        return { access_points: Array.isArray(result && result.access_points) ? result.access_points : [] };
    });
}

return baseclass.extend({
    load: function() {
        return Promise.all([
            uci.load('wloc'),
            uci.load('wireless').catch(function() { return {}; }),
            callWirelessAccessPoints()
        ]).then(function(data) {
            return data[2] || { access_points: [] };
        });
    },

    create: function(data, initialStatus) {
        var accessPoints = data && data.access_points || [];
        var currentStatus = initialStatus || {};
        var lookupResultNodes = {};
        var lastUpdatedNodes = {};
        var lastResultNodes = {};
        var configuredWireless = [];
        var configuredWirelessKeys = {};

        function addConfiguredWireless(source) {
            var ssid = String(source && source.ssid || '');
            var section = String(source && source.section || '');
            var iface = String(source && (source.iface || source.ifname) || '');
            if (!section || !validIfname(iface) || configuredWirelessKeys[section])
                return;
            configuredWirelessKeys[section] = true;
            configuredWireless.push({
                ssid: ssid,
                section: section,
                iface: iface,
                disabled: truthy(source && source.disabled),
                active: truthy(source && source.active),
                missing: truthy(source && source.missing)
            });
        }

        accessPoints.forEach(addConfiguredWireless);
        uci.sections('wireless', 'wifi-iface').forEach(function(wifi) {
            var mode = String(wifi.mode || 'ap');
            if ([ 'ap', 'ap-wds' ].indexOf(mode) < 0 || configuredWirelessKeys[wifi['.name']])
                return;
            addConfiguredWireless({
                section: wifi['.name'],
                ssid: wifi.ssid,
                ifname: wifi.ifname,
                disabled: wifi.disabled,
                active: false
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

        function apActivity(sectionId, status) {
            return ((status || {}).ap_activity || []).find(function(activity) {
                return String(activity.ap_id || '') === sectionId;
            });
        }

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

        function updateStatus(status) {
            currentStatus = status || {};
            uci.sections('wloc', 'wifi').forEach(function(wifi) {
                var sectionId = wifi['.name'];
                var activity = apActivity(sectionId, currentStatus);
                updateNodes(lastUpdatedNodes, sectionId, function(node) {
                    updateRelativeTime(node, activity && activity.last_location_at);
                });
                updateNodes(lastResultNodes, sectionId, function(node) {
                    renderApResult(node, activity);
                });
            });
        }

        var map = new form.Map('wloc');
        var wifiSections = map.section(form.GridSection, 'wifi', _('AP location'),
            _('Select an exact fixed interface and assign one virtual location to clients connected through that AP.'));
        wifiSections.anonymous = true;
        wifiSections.addremove = true;
        wifiSections.sortable = true;
        wifiSections.nodescriptions = true;
        wifiSections.addbtntitle = _('Add AP');

        var ifaceOption = wifiSections.option(form.ListValue, 'iface', _('Interface'));
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
            if (ap.disabled)
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
        scheduleEnabledOption.description = _('Persistently disable the selected interface during this window. Outside the window WLOC enables it, applies the saved radio country code, commits wireless UCI, and reloads WiFi.');

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

        var scheduleEndOption = wifiSections.option(form.Value, 'schedule_end', _('Enable at'));
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

        var countryOption = wifiSections.option(form.Value, 'country', _('Country code'));
        countryOption.modalonly = true;
        countryOption.rmempty = true;
        countryOption.placeholder = 'US';
        countryOption.description = _('Two-letter regulatory country code applied to this AP radio when the schedule enables it. IP location lookup fills this automatically; APs sharing one radio also share one country setting.');
        countryOption.validate = function(sectionId, value) {
            value = String(value || '').trim();
            return !value || /^[A-Za-z]{2}$/.test(value)
                ? true : _('Enter a two-letter country code such as US or GB.');
        };
        countryOption.write = function(sectionId, value) {
            value = String(value || '').trim().toUpperCase();
            if (value)
                uci.set('wloc', sectionId, 'country', value);
            else
                uci.unset('wloc', sectionId, 'country');
        };

        var outboundOption = wifiSections.option(form.ListValue, 'outbound', _('Outbound'));
        outboundOption.modalonly = true;
        outboundOption.value('direct', _('Direct'));
        outboundOption.value('tproxy', _('TPROXY port'));
        outboundOption.default = 'direct';
        outboundOption.rmempty = false;

        function tproxyPortSuggestion(sectionId) {
            var sections = uci.sections('wloc', 'wifi');
            var index = Math.max(0, sections.findIndex(function(section) {
                return section['.name'] === sectionId;
            }));
            return String(12345 + index);
        }

        var tproxyPortOption = wifiSections.option(form.Value, 'tproxy_port', _('TPROXY port'));
        tproxyPortOption.modalonly = true;
        tproxyPortOption.rmempty = false;
        tproxyPortOption.datatype = 'port';
        tproxyPortOption.depends('outbound', 'tproxy');
        tproxyPortOption.cfgvalue = function(sectionId) {
            return String(uci.get('wloc', sectionId, 'tproxy_port') || tproxyPortSuggestion(sectionId));
        };
        tproxyPortOption.description = _('Destination TPROXY listener port. The suggested value starts at 12345 and increments per rule.');

        var lastUpdatedOption = wifiSections.option(form.DummyValue, '_last_updated', _('Last updated'));
        lastUpdatedOption.modalonly = false;
        lastUpdatedOption.rmempty = true;
        lastUpdatedOption.cfgvalue = lastUpdatedOption.textvalue = function(sectionId) {
            var activity = apActivity(sectionId, currentStatus);
            var node = E('span', {});
            rememberNode(lastUpdatedNodes, sectionId, node);
            updateRelativeTime(node, activity && activity.last_location_at);
            return node;
        };

        var lastResultOption = wifiSections.option(form.DummyValue, '_last_result', _('Last result'));
        lastResultOption.modalonly = false;
        lastResultOption.rmempty = true;
        lastResultOption.cfgvalue = lastResultOption.textvalue = function(sectionId) {
            var node = E('span', {});
            renderApResult(node, apActivity(sectionId, currentStatus));
            rememberNode(lastResultNodes, sectionId, node);
            return node;
        };

        var ipOption = wifiSections.option(form.Value, 'ip', _('IP address'));
        ipOption.modalonly = true;
        ipOption.rmempty = true;
        ipOption.placeholder = '8.8.8.8';
        ipOption.description = _('Use ipinfo.io in this browser to fill the AP coordinates and regulatory country code.');

        var lookupButton = wifiSections.option(form.Button, '_lookup_action', _('IP location'));
        lookupButton.modalonly = true;
        lookupButton.rmempty = true;
        lookupButton.inputtitle = _('Fill from IP location');
        lookupButton.inputstyle = 'action';
        lookupButton.onclick = function(ev, sectionId) {
            var ipElement = modalUIElement(ipOption, sectionId);
            var ip = String(ipElement ? ipElement.getValue() : '').trim();
            var resultNode = lookupResultNodes[sectionId];
            if (!ip) {
                if (resultNode)
                    resultNode.textContent = _('Enter an IPv4 or IPv6 address first.');
                return Promise.resolve();
            }
            if (resultNode)
                resultNode.replaceChildren(E('em', {}, _('Looking up with ipinfo.io…')));
            return lookupIpInfo(ip).then(function(result) {
                var latitudeElement = modalUIElement(latitudeOption, sectionId);
                var longitudeElement = modalUIElement(longitudeOption, sectionId);
                var countryElement = modalUIElement(countryOption, sectionId);
                if (!latitudeElement || !longitudeElement || !countryElement)
                    throw new Error(_('Location fields are unavailable.'));
                latitudeElement.setValue(result.latitude);
                longitudeElement.setValue(result.longitude);
                countryElement.setValue(String(result.country || '').toUpperCase());
                latitudeElement.triggerValidation();
                longitudeElement.triggerValidation();
                countryElement.triggerValidation();
                if (resultNode) {
                    var location = [ result.city, result.region ].filter(Boolean).join(' · ');
                    resultNode.replaceChildren(
                        E('div', {}, [ E('strong', {}, _('Coordinates:')), ' ', '%s, %s'.format(result.latitude, result.longitude) ]),
                        E('div', {}, [ E('strong', {}, _('Country:')), ' ', result.country || _('Unknown') ]),
                        E('div', {}, [ E('strong', {}, _('Location:')), ' ', location || _('Unknown') ]),
                        E('div', {}, [ E('strong', {}, _('Timezone:')), ' ', result.timezone || _('Unknown') ])
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

        updateStatus(currentStatus);

        return {
            updateStatus: updateStatus,
            render: function() {
                return map.render().then(function(node) {
                    updateStatus(currentStatus);
                    return node;
                });
            }
        };
    }
});