'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(__dirname, '..', 'htdocs',
    'luci-static', 'resources', 'view', 'wloc', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8').replace(
    'return view.extend({',
    'testExports.callWirelessAccessPoints = callWirelessAccessPoints;\n' +
    'testExports.constants = { attempts: AP_DISCOVERY_ATTEMPTS, retryMs: AP_DISCOVERY_RETRY_MS };\n' +
    'return view.extend({'
);

function loadDiscovery(responses) {
    const testExports = {};
    const delays = [];
    const rpc = {
        declare: function (specification) {
            return responses[specification.object + '.' + specification.method]
                || function () { return Promise.resolve({}); };
        }
    };
    const execute = new Function('view', 'form', 'uci', 'rpc', 'ui', 'poll', 'dom',
        'window', 'testExports', source);
    execute({ extend: function () { return {}; } }, {}, {}, rpc, {}, {}, {}, {
        setTimeout: function (callback, milliseconds) {
            delays.push(milliseconds);
            callback();
        }
    }, testExports);
    return {api: testExports, delays: delays};
}

async function testRetriesAnEmptyInventoryAfterRestart() {
    let calls = 0;
    const harness = loadDiscovery({
        'luci.wloc.configured_access_points': function () {
            calls++;
            return Promise.resolve(calls < 3 ? { access_points: [] } : {
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    network: 'wloc_us',
                    device: 'br-lan',
                    active: true,
                    up: true,
                    unique: true,
                    ifname: 'phy0-ap0',
                    bssid: '02:11:22:33:44:55'
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(harness.api.constants.attempts);
    assert.strictEqual(calls, 3);
    assert.deepStrictEqual(harness.delays, [
        harness.api.constants.retryMs,
        harness.api.constants.retryMs
    ]);
    assert.strictEqual(result.access_points[0].ssid, 'WLOC-US');
    assert.strictEqual(result.access_points[0].device, 'br-lan');
}

async function testBssidAndRuntimeInterfaceAreMetadata() {
    const harness = loadDiscovery({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    network: 'wloc_us',
                    device: 'br-lan',
                    active: true,
                    ifname: 'phy0-ap0',
                    bssid: '02:AA:BB:CC:DD:EE',
                    unique: true
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.deepStrictEqual(
        [result.access_points[0].ssid, result.access_points[0].section],
        ['WLOC-US', 'wloc_us_5g']
    );
    assert.strictEqual(result.access_points[0].bssid, '02:AA:BB:CC:DD:EE');
    assert.strictEqual(result.access_points[0].ifname, 'phy0-ap0');
}

async function testOfflineConfiguredApRemainsAvailable() {
    const harness = loadDiscovery({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    network: 'wloc_us',
                    device: 'br-lan',
                    active: false,
                    up: false,
                    disabled: true,
                    bssid: '',
                    unique: true
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.strictEqual(result.access_points.length, 1);
    assert.strictEqual(result.access_points[0].ssid, 'WLOC-US');
    assert.strictEqual(result.access_points[0].disabled, true);
    assert.strictEqual(result.access_points[0].bssid, '');
}

assert.ok(source.includes("form.ListValue, 'ssid', _('Access Point / SSID')"));
assert.ok(source.includes("uci.set('wloc', sectionId, 'ssid', value)"));
assert.ok(source.includes("uci.unset('wloc', sectionId, 'bridge')"));
assert.ok(source.includes("uci.unset('wloc', sectionId, 'wireless_section')"));
assert.ok(source.includes("Configured SSID \"%s\" was not found."));
assert.ok(source.includes("SSID \"%s\" is used by multiple APs and cannot be selected by WLOC."));
assert.ok(!source.includes("uci.set('wloc', sectionId, 'wireless_section', value)"));

Promise.resolve()
    .then(testRetriesAnEmptyInventoryAfterRestart)
    .then(testBssidAndRuntimeInterfaceAreMetadata)
    .then(testOfflineConfiguredApRemainsAvailable)
    .then(function () {
        process.stdout.write('AP discovery tests: PASS\n');
    })
    .catch(function (error) {
        process.stderr.write(error.stack + '\n');
        process.exit(1);
    });
