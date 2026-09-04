#!/usr/bin/env ucode

'use strict';

import { open } from 'fs';

const DEFAULT_FIREWALL = '/usr/share/wloc/defaults/firewall.nft';
const DEFAULT_ROUTING = '/usr/share/wloc/defaults/routing.conf';

function read_file(path) {
    let file = open(path, 'r');
    if (!file) return null;
    let value = file.read('all') || '';
    file.close();
    return value;
}

function emit_default(path, label) {
    let config = read_file(path);
    if (config == null)
        return { ok: false, error: `Default ${label} template is unavailable.` };

    return { ok: true, path: path, config: config };
}

const methods = {
    firewall: { args: {}, call: function() { return emit_default(DEFAULT_FIREWALL, 'Firewall'); } },
    routing: { args: {}, call: function() { return emit_default(DEFAULT_ROUTING, 'Routing'); } }
};

return { 'luci.wloc.defaults': methods };
