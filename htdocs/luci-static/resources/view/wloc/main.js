'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require wloc.ui as wlocUi';

var callServiceSync = rpc.declare({ object: 'luci.wloc.service', method: 'sync', expect: { '': {} }, reject: true });
var callStart = rpc.declare({ object: 'luci.wloc.service', method: 'start', expect: { '': {} }, reject: true });
var callStop = rpc.declare({ object: 'luci.wloc.service', method: 'stop', expect: { '': {} }, reject: true });

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
        option.description = _('Log observed TLS requests and DNS-over-HTTPS forwarding, including client and destination addresses, DNS names and types, selected outbound route, DoH endpoint, DNS response code, returned A/AAAA/CNAME answers, and failures.');

        option = settings.option(form.Flag, 'debug', _('Debug: fixed JSON response'));
        option.default = '0';
        option.rmempty = false;
        option.description = _('When enabled, requests to the fixed Apple WLOC endpoints return {"wloc":"ok"} without contacting the upstream server.');

        return map.render();
    },

    handleSaveApply: function(event, mode) {
        if (this._wlocAppliedHandler)
            document.removeEventListener('uci-applied', this._wlocAppliedHandler);

        var appliedHandler = function() {
            document.removeEventListener('uci-applied', appliedHandler);

            if (this._wlocAppliedHandler === appliedHandler)
                this._wlocAppliedHandler = null;

            return callServiceSync().then(function(result) {
                return wlocUi.requireOk(result, _('WLOC boot state synchronization failed.'));
            }).then(function(result) {
                return result.enabled ? callStart() : callStop();
            }).then(function(result) {
                return wlocUi.requireOk(result, _('WLOC service state reconciliation failed.'));
            }).then(function() {
                return true;
            }).catch(function(error) {
                wlocUi.notifyFatal(error, _('WLOC service state reconciliation failed.'));
                return false;
            });
        }.bind(this);

        this._wlocAppliedHandler = appliedHandler;
        document.addEventListener('uci-applied', appliedHandler);
        return this.super('handleSaveApply', [ event, mode ]);
    }
});
