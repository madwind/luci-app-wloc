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
var callAccessPoints = rpc.declare({ object: 'luci.wloc', method: 'access_points', expect: {} });
var callConfiguredAccessPoints = rpc.declare({ object: 'luci.wloc', method: 'configured_access_points', expect: {} });
var callIwinfoDevices = rpc.declare({ object: 'iwinfo', method: 'devices', expect: {} });
var callIwinfoInfo = rpc.declare({ object: 'iwinfo', method: 'info', params: [ 'device' ], expect: {} });
var AP_DISCOVERY_ATTEMPTS = 6;
var AP_DISCOVERY_RETRY_MS = 1500;

function truthy(value) {
	return value === true || value === 1 || value === '1' || value === 'true';
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

function wait(milliseconds) {
	return new Promise(function(resolve) {
		window.setTimeout(resolve, milliseconds);
	});
}

function callWirelessAccessPointsOnce() {
	return Promise.all([
		callAccessPoints().catch(function() { return {}; }),
		callIwinfoDevices().then(function(result) {
			var devices = Array.isArray(result.devices) ? result.devices : [];
			return Promise.all(devices.map(function(device) {
				return callIwinfoInfo(device).then(function(info) {
					var mode = String(info.mode || '').toLowerCase();
					if (mode && [ 'master', 'master (vlan)', 'ap', 'wds' ].indexOf(mode) < 0)
						return null;
					return {
						ssid: info.ssid || '',
						bssid: info.bssid || '',
						// iwinfo identifies the radio, not a specific virtual AP.
						// Do not use it as the exact BSSID-to-wifi-iface mapping.
						interface: ''
					};
				}).catch(function() { return null; });
			}));
		}).catch(function() { return []; })
	]).then(function(results) {
		var accessPoints = [];
		var seenBssids = {};

		function addAccessPoint(ap) {
			var bssid = String(ap && ap.bssid || '').toUpperCase();
			if (!/^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/.test(bssid) || seenBssids[bssid])
				return;
			seenBssids[bssid] = true;
			accessPoints.push({
				ssid: String(ap.ssid || ''),
				bssid: bssid,
				interface: String(ap.interface || ap.ifname || '')
			});
		}

		// hostapd reports the real AP interface (including VAPs such as
		// wlan0-1). Prefer it over iwinfo, which only reports a radio.
		(results[0].access_points || []).forEach(addAccessPoint);
		(results[1] || []).forEach(addAccessPoint);
		return { access_points: accessPoints };
	});
}

function callWirelessAccessPoints(attempts) {
	attempts = Math.max(1, Number(attempts) || 1);
	return callWirelessAccessPointsOnce().then(function(result) {
		if ((result.access_points || []).length || attempts <= 1)
			return result;
		return wait(AP_DISCOVERY_RETRY_MS).then(function() {
			return callWirelessAccessPoints(attempts - 1);
		});
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wloc'),
			uci.load('wireless').catch(function() { return {}; }),
			// rpcd may become reachable before hostapd and the wireless interfaces
			// after a router restart. Do not freeze that transient empty result into
			// the BSSID choices for the lifetime of this page.
			callWirelessAccessPoints(AP_DISCOVERY_ATTEMPTS),
			callConfiguredAccessPoints().catch(function() { return {}; }),
			callStatus().catch(function() { return {}; }),
			callLogs().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var accessPoints = data[2].access_points || [];
		var configuredAccessPoints = (data[3] || {}).access_points || [];
		var initialStatus = data[4] || {};
		var initialLogs = (data[5] || {}).logs || '';
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
			var bssid = String(source && source.bssid || '').toUpperCase();
			var section = String(source && (source.section || source.wireless_section) || '');
			var interfaceName = String(source && (source.interface || source.ifname) || '');
			var key = section || (bssid ? 'bssid:' + bssid : 'ssid:' + ssid + '|interface:' + interfaceName);
			if ((!ssid && !bssid) || configuredWirelessKeys[key])
				return;
			configuredWirelessKeys[key] = true;
			configuredWireless.push({
				ssid: ssid,
				bssid: bssid,
				section: section,
				interface: interfaceName,
				disabled: truthy(source && source.disabled)
			});
		}

		uci.sections('wireless', 'wifi-iface').forEach(function(wifi) {
			var mode = String(wifi.mode || 'ap');
			if ([ 'ap', 'ap-wds' ].indexOf(mode) < 0)
				return;
			addConfiguredWireless({
				section: wifi['.name'],
				ssid: wifi.ssid,
				bssid: wifi.bssid || wifi.macaddr,
				interface: wifi.ifname,
				disabled: wifi.disabled
			});
		});
		configuredAccessPoints.forEach(addConfiguredWireless);

		function rememberNode(nodes, sectionId, node) {
			if (!nodes[sectionId])
				nodes[sectionId] = [];
			nodes[sectionId].push(node);
		}

		function updateNodes(nodes, sectionId, update) {
			(nodes[sectionId] || []).forEach(update);
		}

		var map = new form.Map('wloc', _('WLOC'),
			_('Version %s · Assign one Apple WLOC location to each selected AP.').format(initialStatus.version || _('unknown')));

		var profileUrl = '/wloc-ca.mobileconfig';
		var settings = map.section(form.NamedSection, 'main', 'wloc', _('Service settings'));
		settings.anonymous = true;
		var option = settings.option(form.Flag, 'enabled', _('Enable location interception'));
		option.default = '0';
		option.rmempty = false;
		var serviceStatusOption = settings.option(form.DummyValue, '_service_status', _('Status'));
		serviceStatusOption.rmempty = true;
		serviceStatusOption.cfgvalue = function() { return 'status'; };
		serviceStatusOption.renderWidget = function() {
			return E('div', {}, [
				statusNode,
				actionButton.call(this, _('Restart'), 'cbi-button-action', function() {
					return notifyAction(callRestart(), function(status) {
						var priority = status.prerouting_priority;
						var found = status.detected_priorities || _('none');
						if (priority && truthy(status.running) && !status.service_reason)
							return _('Service restarted. WLOC prerouting priority: %s. Found proxy priorities: %s.').format(priority, found);
						if (priority)
							return _('Restart incomplete. WLOC prerouting priority: %s. Found proxy priorities: %s. Reason: %s').format(priority, found, status.service_reason || _('interception is not ready'));
						return _('Restart failed: %s').format(status.service_reason || _('interception is not ready'));
					});
				})
			]);
		};
		option = settings.option(form.Value, 'listen_port', _('Local listen port'));
		option.datatype = 'port';
		option.default = '61520';
		option.rmempty = false;
		option.description = _('Normally this should not be changed. If changed, the WLOC redirect rule in the nftables editor must use the same port. Startup stops safely if the selected port is occupied or the redirect port does not match.');
		option = settings.option(form.Flag, 'runtime_log', _('Enable runtime log'));
		option.default = '0';
		option.rmempty = false;
		option.description = _('Keeps detailed request and coordinate events in RAM until the service restarts. Leave disabled to avoid continuous log allocation and updates.');
		var refreshAccessPointsOption = settings.option(form.Button, '_refresh_access_points', _('AP discovery'));
		refreshAccessPointsOption.inputtitle = _('Refresh AP list');
		refreshAccessPointsOption.inputstyle = 'apply';
		refreshAccessPointsOption.description = _('Retry AP discovery after WiFi or the router has restarted. The page reloads only after at least one BSSID is found.');
		refreshAccessPointsOption.onclick = function() {
			return callWirelessAccessPoints(AP_DISCOVERY_ATTEMPTS).then(function(result) {
				if (!(result.access_points || []).length) {
					ui.addNotification(null, E('p', {}, _('No active AP BSSID was found. WiFi may still be starting; try again shortly.')), 'warning');
					return;
				}
				window.location.reload();
			});
		};
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
			_('Select an AP and assign one virtual location to all devices connected through it.'));
		wifiSections.anonymous = true;
		wifiSections.addremove = true;
		wifiSections.sortable = true;
		wifiSections.nodescriptions = true;
		wifiSections.addbtntitle = _('Add AP');
		wifiSections.sectiontitle = function(sectionId) {
			return uci.get('wloc', sectionId, 'ssid') ||
				String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase() || _('Unnamed AP');
		};

		option = wifiSections.option(form.Flag, 'enabled', _('Enabled'));
		option.default = '1';
		option.rmempty = false;

		var wifiBssidOption = wifiSections.option(form.ListValue, 'bssid', _('Access point (BSSID)'));
		wifiBssidOption.modalonly = true;
		wifiBssidOption.rmempty = false;
		wifiBssidOption.description = _('Select one AP by BSSID. Its location and scheduled disable apply to this AP only.');
		if (!accessPoints.length && configuredWireless.length)
			wifiBssidOption.description = _('Live AP data is not ready; choices are loaded from the saved wireless configuration.');
		if (!accessPoints.length && !configuredWireless.length)
			wifiBssidOption.description = _('No AP is currently visible. Existing saved BSSID values remain selectable, but a new BSSID needs the wireless interface to be available.');
		var knownBssids = [];
		function addBssidChoice(bssid, label) {
			bssid = String(bssid || '').toUpperCase();
			if (!bssid || knownBssids.indexOf(bssid) >= 0)
				return;
			knownBssids.push(bssid);
			wifiBssidOption.value(bssid, label);
		}
		accessPoints.forEach(function(ap) {
			var bssid = String(ap.bssid || '').toUpperCase();
			if (bssid)
				addBssidChoice(bssid, '%s - %s - %s'.format(ap.ssid || _('Hidden SSID'), bssid, ap.interface || _('unknown interface')));
		});
		configuredWireless.forEach(function(wifi) {
			var bssid = String(wifi.bssid || '').toUpperCase();
			if (bssid)
				addBssidChoice(bssid, '%s - %s - %s'.format(wifi.ssid || _('Configured AP'), bssid, _('configured in wireless')));
		});
		uci.sections('wloc', 'wifi').forEach(function(wifi) {
			var bssid = String(wifi.bssid || '').toUpperCase();
			if (bssid)
				addBssidChoice(bssid, '%s - %s - %s'.format(wifi.ssid || _('Unavailable AP'), bssid, _('not currently active')));
		});
		wifiBssidOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase();
		};
		wifiBssidOption.write = function(sectionId, value) {
			var previousBssid = String(uci.get('wloc', sectionId, 'bssid') || '').toLowerCase();
			value = String(value || '').toLowerCase();
			uci.set('wloc', sectionId, 'network', 'bssid');
			uci.set('wloc', sectionId, 'bssid', value);
			var matches = accessPoints.concat(configuredWireless).filter(function(candidate) {
				return String(candidate.bssid || '').toLowerCase() === value;
			});
			var ap = matches.find(function(candidate) { return candidate.section; }) || matches[0];
			if (ap && ap.ssid)
				uci.set('wloc', sectionId, 'ssid', ap.ssid);
			else if (previousBssid !== value)
				uci.unset('wloc', sectionId, 'ssid');
			if (ap && ap.section)
				uci.set('wloc', sectionId, 'wireless_section', ap.section);
			else if (previousBssid !== value)
				uci.unset('wloc', sectionId, 'wireless_section');
			if (ap && ap.interface)
				uci.set('wloc', sectionId, 'wireless_ifname', ap.interface);
			else if (previousBssid !== value)
				uci.unset('wloc', sectionId, 'wireless_ifname');
		};
		wifiBssidOption.validate = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(value))
				return _('Select a valid access point BSSID.');
			return (parseInt(value.slice(0, 2), 16) & 1) === 0 && value !== '00:00:00:00:00:00'
				? true : _('The BSSID must be an individual unicast address.');
		};

		var wifiStateOption = wifiSections.option(form.DummyValue, '_wifi_state', _('AP status'));
		wifiStateOption.modalonly = false;
		wifiStateOption.cfgvalue = wifiStateOption.textvalue = function(sectionId) {
			var bssid = String(uci.get('wloc', sectionId, 'bssid') || '').toLowerCase();
			var active = accessPoints.some(function(ap) {
				return String(ap.bssid || '').toLowerCase() === bssid;
			});
			if (active)
				return _('On');
			var configured = configuredWireless.some(function(ap) {
				return String(ap.bssid || '').toLowerCase() === bssid;
			});
			return configured ? _('Off') : _('Unavailable');
		};

		var scheduleEnabledOption = wifiSections.option(form.Flag, 'schedule_enabled', _('Scheduled disable'));
		scheduleEnabledOption.modalonly = true;
		scheduleEnabledOption.default = '0';
		scheduleEnabledOption.rmempty = false;
		scheduleEnabledOption.description = _('Actually disable the matching OpenWrt AP during this window by applying a temporary wireless disabled=1 override and reloading WiFi. Nothing is committed; the original value is restored afterward. BSSID mode requires an exact AP interface or wifi-iface mapping and never falls back to the whole radio.');

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
		lookupButton.onclick = function(sectionId) {
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

		var statusNode = E('div', { 'class': 'cbi-section-descr' });
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

		function serviceReason(status, running, healthy) {
			if (status.service_reason)
				return translateReason(status.service_reason);
			if (!running && truthy(status.enabled))
				return _('The service is not running. Check the system log for the startup error.');
			if (running && !healthy)
				return translateReason(status.last_error) || _('Interception is unavailable. Check the runtime log.');
			return '';
		}

		function renderStatus(status) {
			var armed = truthy(status.armed);
			var conflict = truthy(status.path_conflict);
			var running = truthy(status.running);
			var healthy = running && armed && truthy(status.rules_present) && !conflict;
			var state = running ? (healthy ? _('Running') : _('Running, interception unavailable'))
				: (truthy(status.enabled) ? _('Stopped') : _('Disabled'));
			var reason = serviceReason(status, running, healthy);
			statusNode.replaceChildren(E('span', { 'class': healthy ? 'success' : 'warning' }, state));
			if (reason)
				statusNode.appendChild(E('div', { 'class': 'alert-message warning' }, _('Reason: %s').format(reason)));
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
			refresh();
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
