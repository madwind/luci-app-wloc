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
            _('Persistent WLOC service and GeoIP configuration. AP locations and the Root CA are managed from Overview.'));

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

        option = settings.option(form.Flag, 'debug', _('Debug: fixed JSON response'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('When enabled, requests to the fixed Apple WLOC endpoints return {"wloc":"ok"} without contacting the upstream server.');

        var geoipSettings = map.section(form.NamedSection, 'main', 'wloc', _('GeoIP'));
        geoipSettings.anonymous = true;

        option = geoipSettings.option(form.Value, 'geoip_file', _('GeoIP file'));
        option.default = '/usr/share/xray/geoip.dat';
        option.rmempty = false;
        option.description = _('GeoIP database used to expand %geoip:<tag>% macros in the Firewall editor. The version is read from the adjacent .version file.');
        option.validate = function(sectionId, value) {
            value = String(value || '');
            return value.charAt(0) === '/' && !/[\x00\r\n]/.test(value)
                ? true : _('Enter an absolute file path.');
        };

        option = geoipSettings.option(form.Value, 'geoip_url', _('GeoIP source'));
        option.default = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat';
        option.rmempty = false;
        option.description = _('HTTPS source used by the Updates page when checking or downloading GeoIP.');
        option.validate = function(sectionId, value) {
            return /^https:\/\/\S+$/.test(String(value || ''))
                ? true : _('Enter an HTTPS URL.');
        };

        return map.render();
    }
});
