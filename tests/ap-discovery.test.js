'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(__dirname, '..', 'htdocs',
    'luci-static', 'resources', 'view', 'wloc', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8').replace(
    'return view.extend({',
    'testExports.validDomainList = validDomainList;\n' +
    'testExports.validDomainInput = validDomainInput;\n' +
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
const domainHarness = loadDiscovery({});
assert.strictEqual(domainHarness.api.validDomainList('baidu.com'), true);
assert.strictEqual(domainHarness.api.validDomainInput(''), true);
assert.strictEqual(domainHarness.api.validDomainInput('baidu.com'), true);
assert.strictEqual(domainHarness.api.validDomainInput('baidu..com'), false);
assert.strictEqual(domainHarness.api.validDomainList([
    'gs-loc.apple.com', 'gs-loc-cn.apple.com', 'baidu.com'
]), true);
assert.strictEqual(domainHarness.api.validDomainList(['baidu.com', 'baidu..com']), false);
assert.strictEqual(domainHarness.api.validDomainList([]), false);
assert.ok(!source.includes("'gid'"));
assert.ok(source.includes('domainOption.optional = true;'));
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
