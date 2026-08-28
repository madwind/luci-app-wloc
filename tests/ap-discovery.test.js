'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(__dirname, '..', 'htdocs',
    'luci-static', 'resources', 'view', 'wloc', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8').replace(
    'return view.extend({',
    'testExports.interceptionState = interceptionState;\n' +
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
                    active: true,
                    up: true,
                    iface: 'phy0-ap0',
                    ifname: 'phy0-ap0',
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
    assert.strictEqual(result.access_points[0].iface, 'phy0-ap0');
}

async function testInterfaceAndSsidRemainSeparate() {
    const harness = loadDiscovery({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    active: true,
                    iface: 'phy0-ap0'
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.deepStrictEqual(
        [result.access_points[0].ssid, result.access_points[0].section],
        ['WLOC-US', 'wloc_us_5g']
    );
    assert.strictEqual(result.access_points[0].iface, 'phy0-ap0');
}

async function testOfflineConfiguredApRemainsAvailable() {
    const harness = loadDiscovery({
        'luci.wloc.configured_access_points': function () {
            return Promise.resolve({
                access_points: [{
                    section: 'wloc_us_5g',
                    ssid: 'WLOC-US',
                    active: false,
                    up: false,
                    disabled: true,
                    iface: 'phy0-ap0'
                }]
            });
        }
    });
    const result = await harness.api.callWirelessAccessPoints(1);
    assert.strictEqual(result.access_points.length, 1);
    assert.strictEqual(result.access_points[0].ssid, 'WLOC-US');
    assert.strictEqual(result.access_points[0].disabled, true);
    assert.strictEqual(result.access_points[0].iface, 'phy0-ap0');
}

assert.ok(source.includes("form.ListValue, 'iface', _('Interface')"));
assert.ok(source.indexOf("form.ListValue, 'iface', _('Interface')") <
    source.indexOf("form.DummyValue, '_wifi_state', _('AP status')"));
assert.ok(source.indexOf("form.DummyValue, '_wifi_state', _('AP status')") <
    source.indexOf("form.DummyValue, '_ssid', _('SSID')"));
assert.ok(source.includes('ifaceOption.modalonly = null;'));
assert.ok(!source.includes('wifiSections.sectiontitle'));
assert.ok(source.includes("form.DummyValue, '_intercepted_domains', _('Intercepted domains')"));
assert.ok(source.includes('gs-loc.apple.com'));
assert.ok(source.includes('gs-loc-cn.apple.com'));
assert.ok(source.includes("Apple WLOC endpoints intercepted by this service."));
assert.ok(!source.includes('form.DynamicList'));
assert.ok(!source.includes('DOMAIN_PATTERN'));
assert.ok(!source.includes('validDomainList'));
assert.ok(!source.includes('validDomainInput'));
assert.ok(!source.includes('Add a test domain here when needed.'));
assert.ok(source.includes("form.DummyValue, '_service_status', _('Interception status')"));
assert.ok(source.includes("Restart service"));
assert.ok(source.includes('display: flex'));
const statusHarness = loadDiscovery({});
assert.strictEqual(statusHarness.api.interceptionState({ enabled: 0 }).label, 'Disabled');
assert.strictEqual(statusHarness.api.interceptionState({
    enabled: 1, running: 1, armed: 1, firewall_active: 1, configured_aps: 2
}).label, 'Active');
assert.strictEqual(statusHarness.api.interceptionState({
    enabled: 1, running: 1, armed: 0
}).label, 'Recovering');
assert.strictEqual(statusHarness.api.interceptionState({
    enabled: 1, running: 0
}).label, 'Error');
assert.strictEqual(statusHarness.api.interceptionState({
    enabled: 1, running: 1, armed: 1, firewall_active: 1, path_conflict: 1
}).label, 'Traffic conflict');
assert.ok(!source.includes("'gid'"));
assert.ok(source.includes('return callRestart().then(function()'));
assert.ok(!source.includes("_('Service restarted.')"));
assert.ok(!source.includes('WLOC prerouting priority:'));
assert.ok(!source.includes('Found proxy priorities:'));
assert.ok(!source.includes("form.Button, '_refresh_access_points'"));
assert.ok(!source.includes("_('AP discovery')"));
assert.ok(source.includes("uci.set('wloc', sectionId, 'iface', value)"));
assert.ok(source.includes("uci.unset('wloc', sectionId, 'ssid')"));
assert.ok(source.includes("source && (source.iface || source.ifname)"));
assert.ok(source.includes('wifi.ifname'));
assert.ok(source.includes('Interfaces without a fixed ifname are not shown.'));
assert.ok(source.includes("Configured interface \"%s\" was not found."));
assert.ok(source.includes("Interface \"%s\" is used by multiple APs and cannot be selected by WLOC."));
assert.ok(!source.includes("form.DummyValue, '_radio'"));
assert.ok(!source.includes("form.DummyValue, '_network'"));
assert.ok(!source.includes("form.DummyValue, '_device'"));
assert.ok(!source.includes("form.DummyValue, '_live_bssid'"));
assert.ok(!source.includes("uci.set('wloc', sectionId, 'wireless_section', value)"));

Promise.resolve()
    .then(testRetriesAnEmptyInventoryAfterRestart)
    .then(testInterfaceAndSsidRemainSeparate)
    .then(testOfflineConfiguredApRemainsAvailable)
    .then(function () {
        process.stdout.write('AP discovery tests: PASS\n');
    })
    .catch(function (error) {
        process.stderr.write(error.stack + '\n');
        process.exit(1);
    });
