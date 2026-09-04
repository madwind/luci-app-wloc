'use strict';
'require view';
'require form';
'require uci';

return view.extend({
    load: function() {
        return uci.load('wloc');
    },

    render: function() {
        document.title = _('WLOC | Settings');

        var map = new form.Map('wloc', _('Settings'),
            _('Persistent WLOC service configuration. AP locations and the Root CA are managed from Overview.'));

        var settings = map.section(form.NamedSection, 'main', 'wloc', _('Service settings'));
        settings.anonymous = true;

        var option = settings.option(form.Flag, 'enabled', _('Enable service'));
        option.default = '0';
        option.rmempty = false;

        option = settings.option(form.Value, 'listen_port', _('Local listen port'));
        option.datatype = 'port';
        option.default = '61520';
        option.rmempty = false;
        option.description = _('Normally this should not be changed. If your custom nftables rules redirect traffic to WLOC, use the same port. WLOC does not inspect or enforce redirect rules; a mismatched rule simply will not send traffic to the listener.');

        var domainsOption = settings.option(form.DummyValue, '_intercepted_domains', _('Intercepted domains'));
        domainsOption.rmempty = true;
        domainsOption.cfgvalue = function() { return 'gs-loc.apple.com\ngs-loc-cn.apple.com'; };
        domainsOption.renderWidget = function() {
            return E('div', { 'class': 'wloc-fixed-domains' }, [
                E('code', {}, 'gs-loc.apple.com'),
                E('br'),
                E('code', {}, 'gs-loc-cn.apple.com')
            ]);
        };
        domainsOption.description = _('Apple WLOC endpoints intercepted by this service.');

        option = settings.option(form.Flag, 'debug_log', _('Debug request logging'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('Log every observed TLS request with client address, SNI hostname, and whether WLOC will intercept or pass it through. Normal WLOC events continue to report upstream status, patched coordinates, and failures.');

        option = settings.option(form.Flag, 'debug', _('Debug: fixed JSON response'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('When enabled, requests to the fixed Apple WLOC endpoints return {"wloc":"ok"} without contacting the upstream server.');

        return map.render();
    }
});
