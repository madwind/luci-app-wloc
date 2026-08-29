'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(__dirname, '..', 'htdocs',
    'luci-static', 'resources', 'view', 'wloc', 'firewall.js');
const source = fs.readFileSync(sourcePath, 'utf8').replace(
    'return view.extend({',
    'testExports.initialEditorContent = initialEditorContent;\n' +
    'testExports.initialEditorState = initialEditorState;\n' +
    'return view.extend({'
);

function loadFirewallView() {
    const testExports = {};
    const rpc = {
        declare: function () {
            return function () { return Promise.resolve({}); };
        }
    };
    const execute = new Function('view', 'rpc', 'testExports', source);
    execute({ extend: function () { return {}; } }, rpc, testExports);
    return testExports;
}

const api = loadFirewallView();
const persistent = 'table inet saved {\n}\n';
const applied = 'table inet applied {\n}\n';

assert.ok(source.includes('table bridge wloc'));
assert.ok(source.includes('table inet wloc'));
assert.ok(source.includes('Only table bridge wloc and table inet wloc definitions are supported.'));
assert.ok(!source.includes('custom nftables tables'));

// A browser reload after Apply must restore the unsaved applied revision so
// that the next Save targets the same snapshot the user actually confirmed.
let state = api.initialEditorState({
    config: persistent,
    applied: applied,
    applied_hash: 'applied-revision',
    saved_hash: 'saved-revision',
    persistent_present: true,
    applied_present: true
});
assert.strictEqual(state.content, applied);
assert.strictEqual(state.saveEnabled, true);

// Once the applied revision matches the persistent revision, Save is no
// longer needed and must remain disabled.
state = api.initialEditorState({
    config: persistent,
    applied: persistent,
    applied_hash: 'same-revision',
    saved_hash: 'same-revision',
    persistent_present: true,
    applied_present: true
});
assert.strictEqual(state.content, persistent);
assert.strictEqual(state.saveEnabled, false);

state = api.initialEditorState({
    config: persistent,
    persistent_present: true,
    applied_present: false
});
assert.strictEqual(state.content, persistent);
assert.strictEqual(state.saveEnabled, false);

process.stdout.write('Firewall UI tests: PASS\n');
