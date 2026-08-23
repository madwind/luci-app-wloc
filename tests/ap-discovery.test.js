'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(__dirname, '..', 'openwrt', 'files', 'www',
	'luci-static', 'resources', 'view', 'wloc', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8').replace(
	'return view.extend({',
	'testExports.callWirelessAccessPoints = callWirelessAccessPoints;\n' +
	'testExports.constants = { attempts: AP_DISCOVERY_ATTEMPTS, retryMs: AP_DISCOVERY_RETRY_MS };\n' +
	'return view.extend({'
);

function loadDiscovery(responders) {
	const testExports = {};
	const delays = [];
	const rpc = {
		declare: function(specification) {
			return responders[specification.object + '.' + specification.method]
				|| function() { return Promise.resolve({}); };
		}
	};
	const execute = new Function('view', 'form', 'uci', 'rpc', 'ui', 'poll', 'dom',
		'window', 'testExports', source);
	execute({ extend: function() { return {}; } }, {}, {}, rpc, {}, {}, {}, {
		setTimeout: function(callback, milliseconds) {
			delays.push(milliseconds);
			callback();
		}
	}, testExports);
	return { api: testExports, delays: delays };
}

async function testRetriesAnEmptyResultAfterRestart() {
	let calls = 0;
	const harness = loadDiscovery({
		'luci.wloc.access_points': function() {
			calls++;
			return Promise.resolve(calls < 3 ? { access_points: [] } : {
				access_points: [ {
					ssid: 'Recovered AP',
					bssid: '02:11:22:33:44:55',
					interface: 'phy0-ap0'
				} ]
			});
		},
		'iwinfo.devices': function() { return Promise.resolve({ devices: [] }); }
	});
	const result = await harness.api.callWirelessAccessPoints(harness.api.constants.attempts);
	assert.strictEqual(calls, 3);
	assert.deepStrictEqual(harness.delays, [
		harness.api.constants.retryMs,
		harness.api.constants.retryMs
	]);
	assert.strictEqual(result.access_points[0].bssid, '02:11:22:33:44:55');
}

async function testAcceptsVirtualApModeFromIwinfo() {
	const harness = loadDiscovery({
		'luci.wloc.access_points': function() { return Promise.resolve({ access_points: [] }); },
		'iwinfo.devices': function() { return Promise.resolve({ devices: [ 'phy0-ap1' ] }); },
		'iwinfo.info': function() {
			return Promise.resolve({
				mode: 'Master (VLAN)',
				ssid: 'Guest AP',
				bssid: '02:AA:BB:CC:DD:EE'
			});
		}
	});
	const result = await harness.api.callWirelessAccessPoints(1);
	assert.strictEqual(result.access_points.length, 1);
	assert.strictEqual(result.access_points[0].ssid, 'Guest AP');
}

Promise.resolve()
	.then(testRetriesAnEmptyResultAfterRestart)
	.then(testAcceptsVirtualApModeFromIwinfo)
	.then(function() { process.stdout.write('AP discovery tests: PASS\n'); })
	.catch(function(error) {
		process.stderr.write(error.stack + '\n');
		process.exit(1);
	});
