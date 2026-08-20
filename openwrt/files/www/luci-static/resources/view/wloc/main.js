'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';
'require dom';

var callStatus = rpc.declare({ object: 'luci.wloc', method: 'status', expect: {} });
var callRestart = rpc.declare({ object: 'luci.wloc', method: 'restart', expect: {} });
var callRegenerate = rpc.declare({ object: 'luci.wloc', method: 'regenerate_ca', expect: {} });
var callAccessPoints = rpc.declare({ object: 'luci.wloc', method: 'access_points', expect: {} });
var callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: {} });

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

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wloc'),
			uci.load('wireless').catch(function() { return {}; }),
			callLeases().catch(function() { return {}; }),
			callAccessPoints().catch(function() { return {}; }),
			callStatus().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var leases = data[2].dhcp_leases || data[2].leases || [];
		var accessPoints = data[3].access_points || [];
		var initialStatus = data[4] || {};
		var initialLogs = initialStatus.runtime_log || '';
		var lookupResultNodes = {};
		var lastUpdatedNodes = {};
		var lastResultNodes = {};

		function rememberNode(nodes, sectionId, node) {
			if (!nodes[sectionId])
				nodes[sectionId] = [];
			nodes[sectionId].push(node);
		}

		function updateNodes(nodes, sectionId, update) {
			(nodes[sectionId] || []).forEach(update);
		}

		var map = new form.Map('wloc', _('WLOC'),
			_('Version %s · Assign an independent Apple WLOC location to each authorized device.').format(initialStatus.version || _('unknown')));

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
			return E('div', { 'class': 'wloc-status-control' }, [
				statusNode,
				actionButton.call(this, _('Restart'), 'cbi-button-action', function() {
					return notifyAction(callRestart(), function(status) {
						var priority = status.prerouting_priority;
						var found = status.detected_priorities || _('none');
						if (priority && truthy(status.running) && !status.service_reason)
							return _('Service restarted. WLOC prerouting priority: %s. Found proxy priorities: %s.').format(priority, found);
						if (priority)
							return _('Restart incomplete. WLOC prerouting priority: %s. Found proxy priorities: %s. Reason: %s').format(priority, found, status.service_reason || _('interception is not ready'));
						return _('Restart failed: %s').format(status.service_reason || _('no safe prerouting priority was found'));
					});
				})
			]);
		};
		option = settings.option(form.Value, 'listen_port', _('Local listen port'));
		option.datatype = 'port';
		option.default = '61520';
		option.description = _('Startup stops safely if the selected port is already occupied.');
		option.rmempty = false;
		option.description = _('Normally this should not be changed. Only enabled devices connecting to Apple WLOC over TCP 443 are intercepted.');
		option = settings.option(form.Flag, 'runtime_log', _('Enable runtime log'));
		option.default = '0';
		option.rmempty = false;
		option.description = _('Keeps detailed request and coordinate events in RAM until the service restarts. Leave disabled to avoid continuous log allocation and updates.');
		var caOption = settings.option(form.DummyValue, '_ca_certificate', _('iPhone root certificate'));
		caOption.rmempty = true;
		caOption.cfgvalue = function() { return 'certificate'; };
		caOption.renderWidget = function() {
			return E('div', { 'class': 'wloc-ca-control' }, [
				E('p', {}, _('After installing the profile, explicitly enable full trust in iOS Certificate Trust Settings.')),
				E('div', { 'class': 'wloc-actions' }, [
					E('a', { 'class': 'cbi-button cbi-button-action', 'href': profileUrl }, _('Download CA profile')),
					actionButton.call(this, _('Regenerate CA'), 'cbi-button-negative', function() {
						return notifyAction(callRegenerate(), _('The Root CA was regenerated. Reinstall and trust it on the iPhone.'));
					})
				]),
				fingerprintNode
			]);
		};

		var wifiSections = map.section(form.TypedSection, 'wifi', _('WiFi / AP'),
			_('Add a WiFi / AP first, then add device conditions below it. Parent order is the primary priority; device order is secondary.'));
		wifiSections.anonymous = true;
		wifiSections.addremove = true;
		wifiSections.addbtntitle = _('Add WiFi / AP');
		wifiSections.sectiontitle = function(sectionId) {
			return uci.get('wloc', sectionId, 'name') || _('Unnamed WiFi / AP');
		};

		option = wifiSections.option(form.Flag, 'enabled', _('Enabled'));
		option.default = '1';
		option.rmempty = false;

		option = wifiSections.option(form.Value, 'name', _('Name'));
		option.placeholder = _('Living room WiFi');
		option.rmempty = false;
		option.description = _('A management name for this WiFi / AP group.');

		function wifiSourceSummary(sectionId) {
			var network = uci.get('wloc', sectionId, 'network') || 'ssid';
			if (network === 'ssid')
				return '%s - %s'.format(_('WiFi name'), uci.get('wloc', sectionId, 'ssid') || _('SSID not set'));
			if (network === 'bssid') {
				var bssid = String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase();
				var ssid = uci.get('wloc', sectionId, 'ssid');
				return ssid ? '%s - %s'.format(ssid, bssid) : bssid;
			}
			return _('Any WiFi / AP');
		}

		var wifiNetworkOption = wifiSections.option(form.ListValue, 'network', _('WiFi / AP source'));
		wifiNetworkOption.value('any', _('Any WiFi / AP'));
		wifiNetworkOption.value('ssid', _('Specified WiFi name (SSID)'));
		wifiNetworkOption.value('bssid', _('Specified AP (BSSID)'));
		wifiNetworkOption.default = 'ssid';
		wifiNetworkOption.rmempty = false;
		wifiNetworkOption.description = _('This parent selects the wireless source. Add device conditions below it.');

		var wifiSsidOption = wifiSections.option(form.ListValue, 'ssid', _('WiFi name (SSID)'));
		wifiSsidOption.depends('network', 'ssid');
		wifiSsidOption.rmempty = false;
		wifiSsidOption.retain = true;
		wifiSsidOption.description = _('All APs broadcasting this name belong to the same WiFi / AP group.');
		function addSsidChoice(ssid, label) {
			ssid = String(ssid || '');
			if (!ssid || knownSsids.indexOf(ssid) >= 0)
				return;
			knownSsids.push(ssid);
			wifiSsidOption.value(ssid, label || ssid);
		}
		var knownSsids = [];
		accessPoints.forEach(function(ap) {
			var ssid = String(ap.ssid || '');
			if (!ssid || knownSsids.indexOf(ssid) >= 0)
				return;
			knownSsids.push(ssid);
			var count = accessPoints.filter(function(candidate) {
				return String(candidate.ssid || '') === ssid;
			}).length;
			addSsidChoice(ssid, '%s - %d AP%s'.format(ssid, count, count === 1 ? '' : 's'));
		});
		uci.sections('wireless', 'wifi-iface').forEach(function(wifi) {
			var mode = String(wifi.mode || 'ap');
			var ssid = String(wifi.ssid || '');
			if ([ 'ap', 'ap-wds' ].indexOf(mode) < 0 || !ssid || knownSsids.indexOf(ssid) >= 0)
				return;
			addSsidChoice(ssid, '%s - %s'.format(ssid,
				String(wifi.disabled || '0') === '1' ? _('disabled') : _('not currently active')));
		});
		uci.sections('wloc', 'wifi').forEach(function(wifi) {
			var ssid = String(wifi.ssid || '');
			if ((wifi.network || 'ssid') === 'ssid' && ssid && knownSsids.indexOf(ssid) < 0) {
				addSsidChoice(ssid, '%s - %s'.format(ssid, _('not currently active')));
			}
		});
		wifiSsidOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'ssid') || '');
		};
		wifiSsidOption.validate = function(sectionId, value) {
			value = String(value || '');
			return value && value.length <= 32 && !/[\x00-\x1f\x7f]/.test(value)
				? true : _('Enter a valid WiFi name (1-32 characters).');
		};

		var wifiBssidOption = wifiSections.option(form.ListValue, 'bssid', _('Access point (BSSID)'));
		wifiBssidOption.depends('network', 'bssid');
		wifiBssidOption.rmempty = false;
		wifiBssidOption.description = _('Select one AP by BSSID. A BSSID identifies one radio, even when several radios use the same WiFi name.');
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
		uci.sections('wloc', 'wifi').forEach(function(wifi) {
			var bssid = String(wifi.bssid || '').toUpperCase();
			if (bssid && knownBssids.indexOf(bssid) < 0)
				addBssidChoice(bssid, '%s - %s - %s'.format(wifi.ssid || _('Unavailable AP'), bssid, _('not currently active')));
		});
		uci.sections('wireless', 'wifi-iface').forEach(function(wifi) {
			var mode = String(wifi.mode || 'ap');
			var bssid = String(wifi.bssid || wifi.macaddr || '').toUpperCase();
			if ([ 'ap', 'ap-wds' ].indexOf(mode) >= 0 && bssid)
				addBssidChoice(bssid, '%s - %s - %s'.format(wifi.ssid || _('Configured AP'), bssid, _('configured in wireless')));
		});
		wifiBssidOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase();
		};
		wifiBssidOption.write = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			uci.set('wloc', sectionId, 'bssid', value);
			var ap = accessPoints.find(function(candidate) {
				return String(candidate.bssid || '').toLowerCase() === value;
			});
			if (ap && ap.ssid)
				uci.set('wloc', sectionId, 'ssid', ap.ssid);
			else
				uci.unset('wloc', sectionId, 'ssid');
		};
		wifiBssidOption.validate = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(value))
				return _('Select a valid access point BSSID.');
			return (parseInt(value.slice(0, 2), 16) & 1) === 0 && value !== '00:00:00:00:00:00'
				? true : _('The BSSID must be an individual unicast address.');
		};

		var devicesValue = wifiSections.option(form.SectionValue, '_devices', form.GridSection,
			'device', _('Device conditions'), _('Add one or more device conditions under this WiFi / AP.'));
		var devices = devicesValue.subsection;
		function setDeviceParent(sectionId) {
			devices.parent_section_id = sectionId;
			devicesValue.parent_section_id = sectionId;
		}
		var devicesLoad = devicesValue.load;
		devicesValue.load = function(sectionId) {
			setDeviceParent(sectionId);
			return devicesLoad.apply(this, arguments);
		};
		var devicesParse = devicesValue.parse;
		devicesValue.parse = function(sectionId) {
			setDeviceParent(sectionId);
			return devicesParse.apply(this, arguments);
		};
		var devicesRenderWidget = devicesValue.renderWidget;
		devicesValue.renderWidget = function(sectionId) {
			setDeviceParent(sectionId);
			return devicesRenderWidget.apply(this, arguments);
		};
		devices.filter = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'wifi') || '') === String(this.parent_section_id || '');
		};
		devices.anonymous = true;
		devices.addremove = true;
		devices.sortable = true;
		devices.nodescriptions = true;
		devices.addbtntitle = _('Add device');
		devices.sectiontitle = function(sectionId) {
			return uci.get('wloc', sectionId, 'name') || _('Unnamed device condition');
		};
		devices.handleAdd = function(event, name) {
			var parentId = this.parent_section_id;
			if (!parentId)
				return;
			var configName = this.uciconfig || this.map.config;
			var sectionId = this.map.data.add(configName, this.sectiontype, name);
			this.map.data.set(configName, sectionId, 'wifi', parentId);
			var mapNode = this.getPreviousModalMap ? this.getPreviousModalMap() : null;
			var previousMap = mapNode ? dom.findClassInstance(mapNode) : this.map;
			previousMap.addedSection = sectionId;
			return this.renderMoreOptionsModal(sectionId);
		};
		var wifiHandleRemove = wifiSections.handleRemove;
		wifiSections.handleRemove = function(sectionId) {
			var configName = this.uciconfig || this.map.config;
			uci.sections(configName, 'device').forEach(function(device) {
				if (String(device.wifi || '') === String(sectionId))
					this.map.data.remove(configName, device['.name']);
			}, this);
			return wifiHandleRemove.apply(this, arguments);
		};

		option = devices.option(form.Flag, 'enabled', _('Enabled'));
		option.default = '1';
		option.rmempty = false;

		option = devices.option(form.Value, 'name', _('Name'));
		option.placeholder = _('iPhone at living room AP');
		option.rmempty = false;

		function modalGroup(optionName, title, description, tone) {
			var group = devices.option(form.DummyValue, optionName, null);
			group.modalonly = true;
			group.rmempty = true;
			group.cfgvalue = function() { return ''; };
			group.renderWidget = function() {
				return E('div', { 'class': 'wloc-modal-group wloc-modal-group-' + tone }, [
					E('strong', { 'class': 'wloc-modal-group-title' }, title),
					E('span', { 'class': 'wloc-modal-group-description' }, description)
				]);
			};
			return group;
		}

		var parentSummary = devices.option(form.DummyValue, '_wifi_parent', _('WiFi / AP'));
		parentSummary.modalonly = true;
		parentSummary.textvalue = function(sectionId) {
			var parentId = uci.get('wloc', sectionId, 'wifi');
			var parentName = parentId ? uci.get('wloc', parentId, 'name') : '';
			return parentName ? '%s - %s'.format(parentName, wifiSourceSummary(parentId)) : _('WiFi / AP not set');
		};

		modalGroup('_device_group', _('Device'),
			_('Choose which client this device condition applies to.'), 'device');

		var deviceSummary = devices.option(form.DummyValue, '_device_summary', _('Device'));
		deviceSummary.textvalue = function(sectionId) {
			return uci.get('wloc', sectionId, 'device') === 'all'
				? _('All devices') : String(uci.get('wloc', sectionId, 'mac') || _('MAC not set')).toUpperCase();
		};

		var deviceOption = devices.option(form.ListValue, 'device', _('Device match'));
		deviceOption.modalonly = true;
		deviceOption.value('mac', _('Specified MAC'));
		deviceOption.value('all', _('All devices'));
		deviceOption.default = 'mac';
		deviceOption.rmempty = false;

		var macOption = devices.option(form.Value, 'mac', _('Device MAC'));
		macOption.modalonly = true;
		macOption.depends('device', 'mac');
		macOption.rmempty = false;
		macOption.placeholder = 'aa:bb:cc:dd:ee:ff';
		macOption.description = _('Select a current DHCP device or enter its MAC address. Private Wi-Fi addresses are distinct devices.');
		leases.forEach(function(lease) {
			var mac = (lease.macaddr || lease.mac || '').toUpperCase();
			var ip = lease.ipaddr || lease.ip || '';
			if (mac)
				macOption.value(mac, '%s - %s%s'.format(lease.hostname || _('Unnamed device'), mac, ip ? ' - ' + ip : ''));
		});
		macOption.renderWidget = function(sectionId, optionIndex, cfgvalue) {
			var widget = form.Value.prototype.renderWidget.apply(this, arguments);
			var select = widget && widget.nodeName === 'SELECT' ? widget
				: (widget && widget.querySelector ? widget.querySelector('select') : null);
			if (!select)
				return widget;

			var macPattern = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i;
			var expandOptions = function() {
				Array.prototype.forEach.call(select.options, function(option) {
					var fullLabel = option.getAttribute('data-wloc-full-label');
					if (!fullLabel) {
						fullLabel = option.textContent;
						option.setAttribute('data-wloc-full-label', fullLabel);
					}
					if (macPattern.test(option.value))
						option.textContent = fullLabel;
				});
			};
			var compactSelected = function() {
				var selected = select.options[select.selectedIndex];
				if (selected && macPattern.test(selected.value))
					selected.textContent = selected.value.toUpperCase();
			};

			select.addEventListener('mousedown', expandOptions);
			select.addEventListener('keydown', function(event) {
				if ([ 'ArrowDown', 'ArrowUp', 'Home', 'End', ' ', 'Enter' ].indexOf(event.key) >= 0)
					expandOptions();
			});
			select.addEventListener('change', compactSelected);
			select.addEventListener('blur', compactSelected);
			expandOptions();
			compactSelected();
			return widget;
		};
		macOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'mac') || '').toUpperCase();
		};
		macOption.validate = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(value))
				return _('Enter a valid MAC address.');
			if ((parseInt(value.slice(0, 2), 16) & 1) !== 0 || value === '00:00:00:00:00:00')
				return _('The MAC address must be an individual unicast address.');
			return true;
		};

		var sourceSummary = devices.option(form.DummyValue, '_source_summary', _('Network source'));
		sourceSummary.modalonly = true;
		sourceSummary.textvalue = function(sectionId) {
			var network = uci.get('wloc', sectionId, 'network');
			if (network === 'ssid')
				return '%s · %s'.format(_('WiFi name'), uci.get('wloc', sectionId, 'ssid') || _('SSID not set'));
			if (network !== 'bssid')
				return _('Any source');
			var bssid = String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase();
			var ssid = uci.get('wloc', sectionId, 'ssid');
			return ssid ? '%s · %s'.format(ssid, bssid) : bssid;
		};

		var networkOption = devices.option(form.ListValue, 'network', _('Network source match'));
		networkOption.modalonly = true;
		networkOption.value('any', _('Any WiFi / AP source'));
		networkOption.value('ssid', _('Specified WiFi name (SSID)'));
		networkOption.value('bssid', _('Specified AP (BSSID)'));
		networkOption.default = 'any';
		networkOption.rmempty = false;

		var ssidOption = devices.option(form.Value, 'ssid', _('WiFi name (SSID)'));
		ssidOption.modalonly = true;
		ssidOption.depends('network', 'ssid');
		ssidOption.rmempty = false;
		ssidOption.retain = true;
		ssidOption.description = _('Matches every AP broadcasting this WiFi name. Choose a BSSID below to pin the rule to one radio.');
		ssidOption.placeholder = _('Select or enter an SSID');
		var knownSsids = [];
		accessPoints.forEach(function(ap) {
			var ssid = String(ap.ssid || '');
			if (!ssid || knownSsids.indexOf(ssid) >= 0)
				return;
			knownSsids.push(ssid);
			var count = accessPoints.filter(function(candidate) {
				return String(candidate.ssid || '') === ssid;
			}).length;
			ssidOption.value(ssid, '%s · %d AP%s'.format(ssid, count, count === 1 ? '' : 's'));
		});
		uci.sections('wloc', 'device').forEach(function(device) {
			var ssid = String(device.ssid || '');
			if (device.network === 'ssid' && ssid && knownSsids.indexOf(ssid) < 0) {
				knownSsids.push(ssid);
				ssidOption.value(ssid, '%s · %s'.format(ssid, _('not currently active')));
			}
		});
		ssidOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'ssid') || '');
		};
		ssidOption.validate = function(sectionId, value) {
			value = String(value || '');
			return value && value.length <= 32 && !/[\x00-\x1f\x7f]/.test(value)
				? true : _('Enter a valid WiFi name (1-32 characters).');
		};

		var bssidOption = devices.option(form.Value, 'bssid', _('Access point'));
		bssidOption.modalonly = true;
		bssidOption.depends('network', 'bssid');
		bssidOption.rmempty = false;
		bssidOption.description = _('Choose one AP by BSSID. BSSID is unique per radio; same-name access points remain separate.');
		accessPoints.forEach(function(ap) {
			var bssid = String(ap.bssid || '').toUpperCase();
			if (bssid)
				bssidOption.value(bssid, '%s · %s · %s'.format(ap.ssid || _('Hidden SSID'), bssid, ap.interface || _('unknown interface')));
		});
		uci.sections('wloc', 'device').forEach(function(device) {
			var bssid = String(device.bssid || '').toUpperCase();
			if (bssid && !accessPoints.some(function(ap) { return String(ap.bssid || '').toUpperCase() === bssid; }))
				bssidOption.value(bssid, '%s · %s · %s'.format(device.ssid || _('Unavailable AP'), bssid, _('not currently active')));
		});
		bssidOption.cfgvalue = function(sectionId) {
			return String(uci.get('wloc', sectionId, 'bssid') || '').toUpperCase();
		};
		bssidOption.write = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			uci.set('wloc', sectionId, 'bssid', value);
			var ap = accessPoints.find(function(candidate) {
				return String(candidate.bssid || '').toLowerCase() === value;
			});
			if (ap && ap.ssid)
				uci.set('wloc', sectionId, 'ssid', ap.ssid);
			else
				uci.unset('wloc', sectionId, 'ssid');
		};
		bssidOption.validate = function(sectionId, value) {
			value = String(value || '').toLowerCase();
			if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(value))
				return _('Select a valid access point BSSID.');
			return (parseInt(value.slice(0, 2), 16) & 1) === 0 && value !== '00:00:00:00:00:00'
				? true : _('The BSSID must be an individual unicast address.');
		};
		sourceSummary.hidden = true;
		networkOption.deps = [];
		networkOption.depends('_wloc_parent_only', '1');
		ssidOption.deps = [];
		ssidOption.depends('_wloc_parent_only', '1');
		bssidOption.deps = [];
		bssidOption.depends('_wloc_parent_only', '1');

		modalGroup('_location_group', _('Location and outbound'),
			_('Set the virtual location and the optional proxy for this device condition.'), 'location');

		var locationSummary = devices.option(form.DummyValue, '_location_summary', _('Location'));
		locationSummary.textvalue = function(sectionId) {
			return '%s, %s'.format(uci.get('wloc', sectionId, 'latitude') || '—', uci.get('wloc', sectionId, 'longitude') || '—');
		};

		var latitudeOption = devices.option(form.Value, 'latitude', _('Latitude'));
		latitudeOption.modalonly = true;
		latitudeOption.rmempty = false;
		latitudeOption.description = _('Fixed virtual baseline. Each later response adds only the movement since the previous real location; the baseline itself never changes.');
		latitudeOption.validate = coordinateValidator(-90, 90);

		var longitudeOption = devices.option(form.Value, 'longitude', _('Longitude'));
		longitudeOption.modalonly = true;
		longitudeOption.rmempty = false;
		longitudeOption.validate = coordinateValidator(-180, 180);

		var proxyTypeOption = devices.option(form.ListValue, 'proxy_type', _('Outbound'));
		proxyTypeOption.modalonly = true;
		proxyTypeOption.value('direct', _('Direct'));
		proxyTypeOption.value('http', _('HTTP proxy'));
		proxyTypeOption.value('socks5', _('SOCKS5 proxy'));
		proxyTypeOption.default = 'direct';
		proxyTypeOption.rmempty = false;

		var proxyHostOption = devices.option(form.Value, 'proxy_host', _('Proxy host'));
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

		var proxyPortOption = devices.option(form.Value, 'proxy_port', _('Proxy port'));
		proxyPortOption.modalonly = true;
		proxyPortOption.rmempty = false;
		proxyPortOption.datatype = 'port';
		proxyPortOption.placeholder = '1080';
		proxyPortOption.depends('proxy_type', 'http');
		proxyPortOption.depends('proxy_type', 'socks5');
		proxyPortOption.description = _('HTTP CONNECT and SOCKS5 proxies without authentication are supported.');

		var lastUpdatedOption = devices.option(form.DummyValue, '_last_updated', _('Last updated'));
		lastUpdatedOption.rmempty = true;
		lastUpdatedOption.textvalue = function(sectionId) {
			var activity = clientActivity(sectionId, initialStatus);
			return activity && Number(activity.last_location_at)
				? relativeTime(activity.last_location_at) : _('Never');
		};
		lastUpdatedOption.renderWidget = function(sectionId) {
			var node = E('span', {}, lastUpdatedOption.textvalue(sectionId));
			rememberNode(lastUpdatedNodes, sectionId, node);
			var activity = clientActivity(sectionId, initialStatus);
			updateRelativeTime(node, activity && activity.last_location_at);
			return node;
		};

		var lastResultOption = devices.option(form.DummyValue, '_last_result', _('Last result'));
		lastResultOption.rmempty = true;
		function renderClientResult(node, activity) {
			var hasActivity = !!activity;
			var success = hasActivity && truthy(activity.success);
			var error = hasActivity && !success ? String(activity.last_error || '') : '';
			node.className = hasActivity ? (success ? 'is-ok' : 'is-idle') : '';
			node.replaceChildren(E('span', {}, hasActivity ? (success ? _('Success') : _('Failed')) : _('Never')));
			if (error)
				node.appendChild(E('span', { 'class': 'wloc-result-error' }, error));
			if (error)
				node.title = error;
			else
				node.removeAttribute('title');
		}
		lastResultOption.textvalue = function(sectionId) {
			var activity = clientActivity(sectionId, initialStatus);
			return activity ? (truthy(activity.success) ? _('Success') : _('Failed')) : _('Never');
		};
		lastResultOption.renderWidget = function(sectionId) {
			var activity = clientActivity(sectionId, initialStatus);
			var node = E('span', {});
			renderClientResult(node, activity);
			rememberNode(lastResultNodes, sectionId, node);
			return node;
		};

		var ipOption = devices.option(form.Value, 'ip', _('IP address'));
		ipOption.modalonly = true;
		ipOption.rmempty = true;
		ipOption.placeholder = '8.8.8.8';
		ipOption.description = _('The browser sends this address directly to ipinfo.io. It is saved with this device condition; lookup results stay on this page.');

		var lookupButton = devices.option(form.Button, '_lookup_action', _('IP location'));
		lookupButton.modalonly = true;
		lookupButton.rmempty = true;
		lookupButton.inputtitle = _('Fill from IP location');
		lookupButton.inputstyle = 'action';
		lookupButton.onclick = function(first, second) {
			var event = first && first.currentTarget ? first : (second && second.currentTarget ? second : null);
			var sectionId = typeof first === 'string' ? first : (typeof second === 'string' ? second : null);
			var modal = event && event.currentTarget ? event.currentTarget.closest('.modal') : null;
			var inputNode = modal ? modal.querySelector('input[id$=".ip"], [id$=".ip"] input, input[placeholder="8.8.8.8"]') : null;
			var ip = String(inputNode ? inputNode.value : (sectionId ? ipOption.formvalue(sectionId) : '') || '').trim();
			var resultNode = lookupResultNodes[sectionId] || (modal ? modal.querySelector('.wloc-inline-result') : null);
			if (!ip) {
				if (resultNode)
					resultNode.textContent = _('Enter an IPv4 or IPv6 address first.');
				return Promise.resolve();
			}
			if (resultNode)
				resultNode.replaceChildren(E('em', {}, _('Looking up with ipinfo.io…')));
			return lookupIpInfo(ip).then(function(result) {
				var latitudeWidget = latitudeOption.getUIElement(sectionId);
				var longitudeWidget = longitudeOption.getUIElement(sectionId);
				var latitudeInput = modal ? modal.querySelector('input[id$=".latitude"], [id$=".latitude"] input') : null;
				var longitudeInput = modal ? modal.querySelector('input[id$=".longitude"], [id$=".longitude"] input') : null;
				if (latitudeWidget)
					latitudeWidget.setValue(result.latitude);
				else if (latitudeInput) {
					latitudeInput.value = result.latitude;
					latitudeInput.dispatchEvent(new Event('input', { bubbles: true }));
					latitudeInput.dispatchEvent(new Event('change', { bubbles: true }));
				}
				if (longitudeWidget)
					longitudeWidget.setValue(result.longitude);
				else if (longitudeInput) {
					longitudeInput.value = result.longitude;
					longitudeInput.dispatchEvent(new Event('input', { bubbles: true }));
					longitudeInput.dispatchEvent(new Event('change', { bubbles: true }));
				}
				if (!latitudeWidget && !latitudeInput || !longitudeWidget && !longitudeInput)
					throw new Error(_('The coordinate fields are unavailable'));
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

		var lookupResultOption = devices.option(form.DummyValue, '_lookup_result', _('Lookup result'));
		lookupResultOption.modalonly = true;
		lookupResultOption.rmempty = true;
		lookupResultOption.renderWidget = function(sectionId) {
			var node = E('div', { 'class': 'wloc-inline-result' }, _('No lookup performed.'));
			lookupResultNodes[sectionId] = node;
			return node;
		};
		// WiFi/AP matching belongs to the parent section. Do not expose or parse
		// the legacy network fields that used to live on flat device rules.
		devices.children = devices.children.filter(function(child) {
			return [ '_source_summary', 'network', 'ssid', 'bssid' ].indexOf(child.option) < 0;
		});

		var statusNode = E('div', { 'class': 'wloc-status' });
		var fingerprintNode = E('div', { 'class': 'wloc-fingerprint' });
		var logNode = E('pre', { 'class': 'wloc-log', 'tabindex': '0' }, initialLogs || _('No events in this session yet.'));
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

		function serviceReason(status, running, healthy) {
			if (status.service_reason)
				return status.service_reason;
			if (!running && truthy(status.enabled))
				return _('The service is not running. Check the system log for the startup error.');
			if (running && !healthy)
				return status.last_error || _('Interception is unavailable. Check the runtime log.');
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
			statusNode.replaceChildren(E('span', { 'class': healthy ? 'is-ok' : 'is-idle' }, state));
			if (reason)
				statusNode.appendChild(E('span', { 'class': 'wloc-status-reason' }, reason));
			fingerprintNode.replaceChildren(
				E('span', {}, _('Root CA SHA-256')),
				E('code', {}, status.fingerprint || _('Generated on first start'))
			);
		}

		function clientActivity(sectionId, status) {
			return (status.client_activity || []).find(function(activity) {
				return String(activity.client_id || '') === sectionId;
			});
		}

		function renderClientActivity(status) {
			initialStatus = status;
			uci.sections('wloc', 'device').forEach(function(device) {
				var sectionId = device['.name'];
				var activity = clientActivity(sectionId, status);
				updateNodes(lastUpdatedNodes, sectionId, function(node) {
					updateRelativeTime(node, activity && activity.last_location_at);
				});
				updateNodes(lastResultNodes, sectionId, function(node) {
					renderClientResult(node, activity);
				});
			});
		}

		function renderRuntimeLog(status, logs) {
			var enabled = truthy(status.runtime_log_enabled);
			logNode.classList.toggle('is-disabled', !enabled);
			logNode.textContent = enabled ? (logs || _('No events in this session yet.'))
				: _('Runtime logging is disabled. Enable it in Service settings and Save & Apply to begin a new in-memory log.');
			scrollRuntimeLogToBottom();
		}

		function refresh() {
			return callStatus().then(function(status) {
				status = status || {};
				renderStatus(status);
				renderClientActivity(status);
				renderRuntimeLog(status, status.runtime_log || '');
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
			renderClientActivity(initialStatus);
			scrollRuntimeLogToBottom();
			poll.add(refresh, 5);
			refresh();
			return E('div', { 'class': 'wloc-console' }, [
				E('style', {}, '.wloc-console #cbi-wloc-wifi>.cbi-section-node{margin:1rem 0;padding:1rem;border:1px solid var(--wloc-border);background:var(--wloc-surface);border-radius:.25rem}.wloc-console #cbi-wloc-wifi>.cbi-section-node>.cbi-section-remove{margin-bottom:.5rem}.wloc-console #cbi-wloc-wifi>.cbi-section-node .cbi-section{margin-top:.8rem;padding-top:.7rem;border-top:1px solid var(--wloc-border)}'),
				E('style', {}, '.wloc-console .cbi-section-table-row[draggable="true"]{transition:box-shadow .14s ease,transform .14s ease}.wloc-console .cbi-section-table-row[draggable="true"]:hover{box-shadow:inset 3px 0 0 var(--wloc-accent)}.wloc-console .cbi-section-table-row.drag-over{box-shadow:inset 0 2px 0 var(--wloc-accent)}@media(prefers-reduced-motion:reduce){.wloc-console .cbi-section-table-row[draggable="true"]{transition:none}}'),
				E('style', {}, '.wloc-status-reason{display:block;margin-top:.3rem;color:var(--wloc-warn);overflow-wrap:anywhere}.wloc-status-reason:before{content:"Reason: ";font-weight:600}.wloc-result-error{display:block;margin-top:.2rem;max-width:16rem;overflow-wrap:anywhere;font-size:.85em;font-weight:400}'),
				E('style', {}, '.wloc-status-control{display:flex;align-items:flex-start;gap:.8rem;flex-wrap:wrap}.wloc-status-control>.cbi-button{margin:0}'),
				E('style', {}, '.cbi-modal{--wloc-muted:rgba(127,127,127,.85);--wloc-surface:rgba(127,127,127,.08);--wloc-border:rgba(127,127,127,.35)}.cbi-modal .cbi-value[data-name="_device_group"],.cbi-modal .cbi-value[data-name="_location_group"]{display:block;margin:1.15rem 0 .35rem}.wloc-modal-group{display:flex;align-items:baseline;gap:.75rem;width:100%;padding:.7rem .85rem;border:1px solid var(--wloc-border);border-left:3px solid;background:var(--wloc-surface)}.wloc-modal-group-device{border-left-color:#8b5cf6}.wloc-modal-group-location{border-left-color:#16803c}.wloc-modal-group-title{font-size:1rem;letter-spacing:.01em}.wloc-modal-group-description{color:var(--wloc-muted);font-size:.85em}@media(prefers-color-scheme:dark){.cbi-modal{--wloc-muted:rgba(255,255,255,.68);--wloc-surface:rgba(255,255,255,.055);--wloc-border:rgba(255,255,255,.18)}.wloc-modal-group-device{border-left-color:#a78bfa}.wloc-modal-group-location{border-left-color:#4ade80}}@media(max-width:560px){.wloc-modal-group{display:grid;gap:.2rem}}'),
				E('style', {}, '.wloc-console{--wloc-accent:#0e7490;--wloc-safe:#16803c;--wloc-warn:#b45309;--wloc-surface:rgba(127,127,127,.08);--wloc-border:rgba(127,127,127,.35);--wloc-log-bg:#f1f5f9;--wloc-log-fg:#172033;color:inherit}.wloc-grid{display:grid;grid-template-columns:1fr 1fr;gap:1rem}.wloc-card{border:1px solid var(--wloc-border);padding:1rem;background:var(--wloc-surface);margin:1rem 0}.wloc-status,.wloc-fingerprint,.wloc-inline-result{display:grid;gap:.4rem}.wloc-inline-result{min-height:2.8rem;padding:.7rem;background:var(--wloc-surface);border:1px solid var(--wloc-border)}.is-ok{color:var(--wloc-safe)}.is-idle{color:var(--wloc-warn)}.wloc-service-list{display:grid;margin:.5rem 0 0}.wloc-service-list div{display:grid;grid-template-columns:minmax(9rem,.45fr) 1fr;gap:1rem;padding:.65rem 0;border-bottom:1px solid var(--wloc-border)}.wloc-service-list div:last-child{border-bottom:0}.wloc-service-list dt{font-weight:600}.wloc-service-list dd{margin:0;overflow-wrap:anywhere}.wloc-fingerprint{margin:1rem 0}.wloc-fingerprint code{overflow-wrap:anywhere;padding:.6rem;background:var(--wloc-log-bg);color:var(--wloc-log-fg);border:1px solid var(--wloc-border)}.wloc-actions{display:flex;gap:.6rem;flex-wrap:wrap;align-items:center;margin-top:.8rem}.wloc-actions>.cbi-button{margin:0}.wloc-log{min-height:14rem;max-height:28rem;overflow:auto;background:var(--wloc-log-bg);color:var(--wloc-log-fg);border:1px solid var(--wloc-border);padding:.8rem;font:12px/1.55 ui-monospace,SFMono-Regular,Consolas,monospace}.wloc-log.is-disabled{min-height:0;white-space:normal;font-family:inherit;font-size:inherit}.wloc-danger{border-top:3px solid var(--wloc-warn)}@media(prefers-color-scheme:dark){.wloc-console{--wloc-accent:#38bdf8;--wloc-safe:#4ade80;--wloc-warn:#fbbf24;--wloc-surface:rgba(255,255,255,.055);--wloc-border:rgba(255,255,255,.18);--wloc-log-bg:#0f172a;--wloc-log-fg:#dbeafe}}@media(max-width:800px){.wloc-grid{grid-template-columns:1fr}.wloc-service-list div{grid-template-columns:1fr}}'),
				formNode,
				E('section', { 'class': 'wloc-card' }, [
					E('h3', {}, _('Current-session in-memory log')),
					E('p', {}, _('Shows received requests, upstream responses and coordinates before and after patching. It is stored only in /var/run and is cleared on every service start.')),
					logNode
				])
			]);
		}.bind(this));
	}
});
