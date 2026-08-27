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

function loadInventory(responses) {
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
    return { api: testExports, delays: delays };
}

async function testRetriesAnEmptyInventoryAfterRestart() {
    let calls = 0;
    const harness = loadInventory({
        'luci.wloc.configured_access_points': function () {
            calls++;
            return Promise.resolve(calls < 3 ? { access_points: [] } : {
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    network: 'wloc_us',
                    bridge: 'br-wloc-us',
                    active: true,
                    disabled: false,
                    interface: 'phy0-ap0',
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
    assert.strictEqual(result.access_points[0].section, 'wloc_us_5g');
    assert.strictEqual(result.access_points[0].bridge, 'br-wloc-us');
}

async function testBssidChangesWithoutChangingStableIdentity() {
    const harness = loadInventory({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    network: 'wloc_us',
                    bridge: 'br-wloc-us',
                    active: true,
                    bssid: '02:AA:BB:CC:DD:EE'
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.deepStrictEqual(
        [result.access_points[0].section, result.access_points[0].bridge],
        ['wloc_us_5g', 'br-wloc-us']
    );
    assert.strictEqual(result.access_points[0].bssid, '02:AA:BB:CC:DD:EE');
}

async function testDisabledConfiguredApRemainsAvailable() {
    const harness = loadInventory({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    network: 'wloc_us',
                    bridge: 'br-wloc-us',
                    active: false,
                    disabled: true,
                    bssid: ''
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.strictEqual(result.access_points.length, 1);
    assert.strictEqual(result.access_points[0].section, 'wloc_us_5g');
    assert.strictEqual(result.access_points[0].disabled, true);
    assert.strictEqual(result.access_points[0].bssid, '');
}

assert.ok(source.includes("uci.set('wloc', sectionId, 'wireless_section', value)"));
assert.ok(source.includes("uci.set('wloc', sectionId, 'bridge', ap.bridge)"));
assert.ok(source.includes("uci.unset('wloc', sectionId, 'bssid')"));

Promise.resolve()
    .then(testRetriesAnEmptyInventoryAfterRestart)
    .then(testBssidChangesWithoutChangingStableIdentity)
    .then(testDisabledConfiguredApRemainsAvailable)
    .then(function () {
        process.stdout.write('Wireless section discovery tests: PASS\n');
    })
    .catch(function (error) {
        process.stderr.write(error.stack + '\n');
        process.exit(1);
    });
