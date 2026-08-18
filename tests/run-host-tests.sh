#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cargo test --locked --all-targets
for script in $(find openwrt/files -type f \( -name '*.sh' -o -path '*/etc/init.d/*' -o -path '*/usr/libexec/rpcd/*' -o -path '*/etc/uci-defaults/*' \)); do
	sh -n "$script"
done
if command -v python3 >/dev/null 2>&1; then
	python3 -m json.tool openwrt/files/usr/share/rpcd/acl.d/luci-app-wloc.json >/dev/null
	python3 -m json.tool openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json >/dev/null
	python3 -m json.tool openwrt/files/usr/share/ucitrack/luci-app-wloc.json >/dev/null
elif command -v node >/dev/null 2>&1; then
	node -e "JSON.parse(require('fs').readFileSync(process.argv[1]))" openwrt/files/usr/share/rpcd/acl.d/luci-app-wloc.json
	node -e "JSON.parse(require('fs').readFileSync(process.argv[1]))" openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json
	node -e "JSON.parse(require('fs').readFileSync(process.argv[1]))" openwrt/files/usr/share/ucitrack/luci-app-wloc.json
else
	echo 'python3 or node is required for JSON validation' >&2; exit 1
fi
if command -v node >/dev/null 2>&1; then
	node --check openwrt/files/www/luci-static/resources/view/wloc/main.js
fi

grep -q '^TABLE=wloc$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^CLIENT_SET=target_clients_v4$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^CLIENT_MAC_SET=target_clients_mac$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^HOST_SET=apple_wloc_v4$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^DEFAULT_PRIORITY=-105$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^MIN_SAFE_PRIORITY=-199$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^HOST_TIMEOUT=15m$' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'redirect to :\$port comment "wloc owned redirect"' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'priority \$priority' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^analyze_prerouting_proxies()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^choose_wloc_priority()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'edge_target.*key(family_name, table_name' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^check_prerouting_order()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'nft -a list ruleset' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'order-conflict' openwrt/files/usr/libexec/wloc/rules.sh openwrt/files/usr/libexec/rpcd/luci.wloc
! grep -q 'hook output' openwrt/files/usr/libexec/wloc/rules.sh
! grep -q 'tproxy ip to\|meta mark set\|ip -4 rule add\|ip -4 route add' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'ether saddr @\$CLIENT_MAC_SET' openwrt/files/usr/libexec/wloc/rules.sh
! grep -q 'nft flush set inet "\$TABLE" "\$HOST_SET"' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'nft get element inet "\$TABLE" "\$HOST_SET"' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^rules_healthy()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^reconcile()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'rules_healthy || apply_rules "\$port"' openwrt/files/usr/libexec/wloc/rules.sh
grep -q '^table_healthy()' openwrt/files/usr/libexec/wloc/rules.sh
grep -q 'reconcile_rules_async(' src/main.rs
grep -q 'interception_rearmed' src/main.rs
grep -q 'Builder::new_current_thread()' src/main.rs
grep -q 'max_blocking_threads(2)' src/main.rs
grep -q 'Semaphore::new(16)' src/main.rs
grep -q 'GLOBAL_STREAM_LIMIT: usize = 2' src/proxy.rs
grep -q 'max_concurrent_streams(2)' src/proxy.rs
! grep -Eq '\b(cut|tr)\b' openwrt/files/usr/libexec/wloc/rules.sh
! grep -q 'path_failures=3' src/main.rs
! grep -q 'lease_armed.load(Ordering::Relaxed)' src/main.rs
grep -q 'json_add_boolean path_conflict' openwrt/files/usr/libexec/rpcd/luci.wloc
grep -q 'service_reason' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'status.path_conflict' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'runtime_log_enabled:0' openwrt/files/usr/libexec/rpcd/luci.wloc
! grep -q 'logread -e wlocd' openwrt/files/usr/libexec/rpcd/luci.wloc
grep -q 'Current-session in-memory log' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'scrollTop = logNode.scrollHeight' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'followRuntimeLog = runtimeLogAtBottom()' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'detected_priorities' openwrt/files/usr/libexec/rpcd/luci.wloc openwrt/files/www/luci-static/resources/view/wloc/main.js
defaults_script=openwrt/files/etc/uci-defaults/luci-app-wloc
grep -q 'get wloc.main.enabled >/dev/null' "$defaults_script"
grep -q 'listen_port=.*get wloc.main.listen_port' "$defaults_script"
grep -q "''|8443|58443).*listen_port='28443'" "$defaults_script"
grep -q "option listen_port '28443'" openwrt/files/etc/config/wloc
grep -q "config_get listen_port main listen_port 28443" openwrt/files/etc/init.d/wloc
grep -q '^listen_port_in_use()' openwrt/files/etc/init.d/wloc
grep -q 'local listen port .* is already in use' openwrt/files/etc/init.d/wloc
grep -q "option.default = '28443'" openwrt/files/www/luci-static/resources/view/wloc/main.js
eval "$(sed -n '/^listen_port_in_use()/,/^}/p' openwrt/files/etc/init.d/wloc)"
ss() { printf '%s\n' 'LISTEN 0 128 0.0.0.0:28443 0.0.0.0:*'; }
listen_port_in_use 28443 \
	|| { echo 'listen port collision checker missed an occupied IPv4 port' >&2; exit 1; }
! listen_port_in_use 28444 \
	|| { echo 'listen port collision checker rejected an available port' >&2; exit 1; }
grep -q 'get wloc.main.runtime_log >/dev/null' "$defaults_script"
grep -q '^PKG_NAME:=luci-app-wloc$' Makefile
grep -q '^PKG_VERSION:=0.1.1$' Makefile
grep -q '^PKG_RELEASE:=1$' Makefile
grep -q '^version = "0.1.1"$' Cargo.toml
! grep -q 'ca-bundle\|luci-mod-status' Makefile
! grep -q 'kmod-nft-tproxy' Makefile
grep -q '^/etc/config/wloc$' Makefile
grep -q '^/etc/config/wloc$' openwrt/files/lib/upgrade/keep.d/luci-app-wloc
grep -q '"config": "wloc"' openwrt/files/usr/share/ucitrack/luci-app-wloc.json
grep -q '"init": "wloc"' openwrt/files/usr/share/ucitrack/luci-app-wloc.json
grep -q 'old_mac=' "$defaults_script"
dns_fixture='Server:         127.0.0.1
Address:        127.0.0.1:53

Non-authoritative answer:
Name:   gs-loc.apple.com
Address: 140.205.31.96'
parsed_addresses="$(printf '%s\n' "$dns_fixture" \
	| sed -n '/^Name:[[:space:]]/,$ s/^Address[^:]*:[[:space:]]*\([0-9][0-9.]*\).*$/\1/p')"
[ "$parsed_addresses" = 140.205.31.96 ] \
	|| { echo 'BusyBox nslookup parser included a DNS server address' >&2; exit 1; }
nft_fixture='ip saddr @target_clients_v4 meta l4proto tcp counter packets 7 bytes 420 redirect to :28443 comment "wloc owned redirect"'
parsed_counter="$(printf '%s\n' "$nft_fixture" \
	| sed -n '/wloc owned redirect/ s/.*counter packets \([0-9][0-9]*\).*/\1/p')"
[ "$parsed_counter" = 7 ] \
	|| { echo 'nftables diagnostic counter parser failed' >&2; exit 1; }
rules_script=openwrt/files/usr/libexec/wloc/rules.sh
eval "$(sed '/^case /,$d' "$rules_script")"
valid_mac 'a6:88:db:2b:1f:bf' \
	|| { echo 'shell MAC validator rejected a valid unicast address' >&2; exit 1; }
valid_mac '02:11:22:33:44:55' \
	|| { echo 'shell MAC validator rejected a locally administered address' >&2; exit 1; }
! valid_mac 'a7:88:db:2b:1f:bf' \
	|| { echo 'shell MAC validator accepted a multicast address' >&2; exit 1; }
! valid_mac '00:00:00:00:00:00' \
	|| { echo 'shell MAC validator accepted the zero address' >&2; exit 1; }
healthy_table_fixture='table inet wloc {
	set target_clients_v4 {
		type ipv4_addr
	}
	set target_clients_mac {
		type ether_addr
	}
	set apple_wloc_v4 {
		type ipv4_addr
		elements = { 17.0.0.1 timeout 14m }
	}
	chain redirect_prerouting {
	}
}'
printf '%s\n' "$healthy_table_fixture" | table_healthy \
	|| { echo 'consolidated nftables health parser rejected a healthy table' >&2; exit 1; }
printf '%s\n' "$healthy_table_fixture" | sed '/elements =/d' | table_healthy \
	&& { echo 'consolidated nftables health parser accepted an empty host set' >&2; exit 1; }

order_state="$(mktemp)"
order_log="$(mktemp)"
order_fixture='table inet routed_proxy {
 chain ingress {
  type filter hook prerouting priority mangle - 1; policy accept;
  jump proxy_dispatch
 }
 chain proxy_dispatch {
  jump proxy_udp
 }
 chain proxy_udp {
  udp dport != 53 tproxy ip to :1041
 }
 chain nat_ingress {
  type nat hook prerouting priority dstnat - 1; policy accept;
  jump proxy_tcp
 }
 chain proxy_tcp {
  tcp dport 443 redirect to :1041
 }
}
table ip direct_proxy {
 chain ingress {
  type nat hook prerouting priority dstnat; policy accept;
  tcp dport 443 redirect to :2080
 }
}
table ip6 ignored_ipv6_proxy {
 chain ingress {
  type filter hook prerouting priority raw; policy accept;
  meta l4proto tcp tproxy to :2080
 }
}'
nft() { printf '%s\n' "$order_fixture"; }
[ "$(choose_wloc_priority)" = -152 ] \
	|| { echo 'dynamic priority chooser did not run before an indirect mangle - 1 proxy' >&2; exit 1; }
analysis="$(analyze_prerouting_proxies)"
[ "$(printf '%s\n' "$analysis" | awk -F'|' '{ values = values (values == "" ? "" : " ") $2 } END { print values }')" = '-151 -101 -100' ] \
	|| { echo 'proxy graph scanner did not report proxies in numeric priority order' >&2; exit 1; }
printf '%s\n' "$analysis" | grep -q 'PROXY|-151|inet|routed_proxy|ingress|mangle - 1|TPROXY|jump' \
	|| { echo 'proxy graph scanner missed an indirectly reached TPROXY verdict' >&2; exit 1; }
printf '%s\n' "$analysis" | grep -q 'PROXY|-101|inet|routed_proxy|nat_ingress|dstnat - 1|REDIRECT|jump' \
	|| { echo 'proxy graph scanner missed an indirectly reached REDIRECT verdict' >&2; exit 1; }
printf '%s\n' "$analysis" | grep -q 'PROXY|-100|ip|direct_proxy|ingress|dstnat|REDIRECT|direct' \
	|| { echo 'proxy graph scanner missed a direct IPv4 proxy verdict' >&2; exit 1; }
! printf '%s\n' "$analysis" | grep -q 'ignored_ipv6_proxy' \
	|| { echo 'proxy graph scanner compared an unrelated IPv6 hook domain' >&2; exit 1; }

order_fixture='table inet default_proxy {
 chain ingress {
  type nat hook prerouting priority dstnat; policy accept;
  tcp dport 443 redirect to :2080
 }
}'
[ "$(choose_wloc_priority)" = -105 ] \
	|| { echo 'dynamic priority chooser changed the safe default unnecessarily' >&2; exit 1; }

order_fixture='table inet unknown_proxy {
 chain ingress {
  type filter hook prerouting priority custom_proxy_priority; policy accept;
  tcp dport 443 tproxy to :2080
 }
}'
! choose_wloc_priority >/dev/null 2>&1 \
	|| { echo 'dynamic priority chooser accepted an unknown proxy priority' >&2; exit 1; }

order_fixture='table inet too_early_proxy {
 chain ingress {
  type filter hook prerouting priority -199; policy accept;
  tcp dport 443 tproxy to :2080
 }
}'
! choose_wloc_priority >/dev/null 2>&1 \
	|| { echo 'dynamic priority chooser crossed the conntrack safety boundary' >&2; exit 1; }

order_fixture='table inet wloc {
 chain redirect_prerouting {
  type nat hook prerouting priority -152; policy accept;
  tcp dport 443 redirect to :28443
 }
}
table inet routed_proxy {
 chain ingress {
  type filter hook prerouting priority mangle - 1; policy accept;
  jump proxy_dispatch
 }
 chain proxy_dispatch {
  udp dport 443 tproxy ip to :1041
 }
}
table ip direct_proxy {
 chain ingress {
  type nat hook prerouting priority dstnat; policy accept;
  tcp dport 443 redirect to :2080
 }
}'
ORDER_STATE="$order_state"
check_prerouting_order 2>"$order_log"
[ "$(cat "$order_state")" = 0 ] \
	|| { echo 'nftables order checker rejected a verified WLOC-first order' >&2; exit 1; }
grep -q 'ORDER: WLOC table=wloc chain=redirect_prerouting numeric=-152 verdict=REDIRECT stage=first' "$order_log" \
	|| { echo 'nftables order checker did not record WLOC priority' >&2; exit 1; }
grep -q 'ORDER: PROXY family=inet table=routed_proxy chain=ingress priority=mangle - 1 numeric=-151 verdict=TPROXY via=jump relation=after_wloc' "$order_log" \
	|| { echo 'nftables order checker did not record complete indirect proxy order' >&2; exit 1; }
grep -q 'ORDER: PROXY family=ip table=direct_proxy chain=ingress priority=dstnat numeric=-100 verdict=REDIRECT via=direct relation=after_wloc' "$order_log" \
	|| { echo 'nftables order checker did not record complete direct proxy order' >&2; exit 1; }
order_fixture="$(printf '%s\n' "$order_fixture" | sed 's/priority mangle - 1/priority -153/')"
! check_prerouting_order 2>"$order_log" \
	|| { echo 'nftables order checker accepted a newly earlier proxy chain' >&2; exit 1; }
[ "$(cat "$order_state")" = 1 ] \
	|| { echo 'nftables order checker did not persist its ordering conflict' >&2; exit 1; }
rm -f "$order_state" "$order_log"
grep -q "flush set inet \$TABLE \$CLIENT_SET" openwrt/files/usr/libexec/wloc/rules.sh
grep -q "flush set inet \$TABLE \$CLIENT_MAC_SET" openwrt/files/usr/libexec/wloc/rules.sh
! grep -q 'ip_lookup\|uclient-fetch' openwrt/files/usr/libexec/rpcd/luci.wloc Makefile
grep -q "form.GridSection, 'client'" openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q "form.Value, 'accuracy'" openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q 'config_get accuracy' openwrt/files/etc/init.d/wloc
grep -q 'preserved=accuracy,all_other_fields' src/proxy.rs
grep -q 'patch_response_following' src/proxy.rs
grep -q "form.Value, '_lookup_ip'" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "form.ListValue, 'proxy_type'" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "proxyTypeOption.value('http'" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "proxyTypeOption.value('socks5'" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'relativeTime(activity.last_location_at)' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q -- '--client-proxy' openwrt/files/etc/init.d/wloc
grep -q 'connect_outbound(outbound' src/proxy.rs
grep -q 'Look up and fill coordinates' openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q 'wloc-tabs' openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q 'wloc-hero\|wloc-scope' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "_('Last updated')" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "_('Failure reason')" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "_('Last result')" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'client_activity' openwrt/files/usr/libexec/rpcd/luci.wloc
grep -q 'client_id' openwrt/files/usr/libexec/rpcd/luci.wloc
grep -q 'last_error' openwrt/files/usr/libexec/rpcd/luci.wloc src/status.rs
grep -q '"admin/services/wloc"' openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json
grep -q '"title": "WLOC"' openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json
grep -q '"path": "wloc/main"' openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json
grep -q 'wloc-service-list' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "new form.Map('wloc', _('WLOC')" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "method: 'restart'" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "actionButton.call(this, _('Restart')" openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q "'runtime_log', _('Enable runtime log')" openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q 'JSON.stringify' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'getUIElement(sectionId)' openwrt/files/www/luci-static/resources/view/wloc/main.js
! grep -q 'callLogs' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'poll.add(refresh, 10)' openwrt/files/www/luci-static/resources/view/wloc/main.js
grep -q 'write_atomic' src/status.rs
grep -q 'update_detail_lines' src/proxy.rs
grep -q 'upstream_reused' src/proxy.rs
grep -q 'EXPECTED_APK=' scripts/build-openwrt-25.12.5.sh
grep -Fq 'bash "$PROJECT/tests/run-host-tests.sh"' scripts/build-openwrt-25.12.5.sh
grep -q 'x86_64-unknown-linux-musl' Makefile scripts/build-openwrt-25.12.5.sh
grep -q 'SDK_SHA256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c' scripts/build-openwrt-25.12.5.sh
grep -q 'matrix:' .github/workflows/openwrt-build.yml
grep -q '^name: WLOC / Host checks$' .github/workflows/ci.yml
grep -q '^name: WLOC / OpenWrt package build$' .github/workflows/openwrt-build.yml
grep -q '^name: WLOC / OpenWrt upstream maintenance$' .github/workflows/openwrt-upstream.yml
grep -q '^run-name: Host checks /' .github/workflows/ci.yml
grep -q '^run-name: OpenWrt packages /' .github/workflows/openwrt-build.yml
grep -q '^run-name: Upstream check /' .github/workflows/openwrt-upstream.yml
grep -q 'name: Build APK /' .github/workflows/openwrt-build.yml
grep -q 'name: Rust quality and host tests' .github/workflows/ci.yml
grep -q 'uses: actions/cache@v4' .github/workflows/openwrt-build.yml .github/workflows/ci.yml
grep -Fq '.build/openwrt-25.12.5-${{ matrix.target }}/downloads' .github/workflows/openwrt-build.yml
grep -Fq '${{ matrix.sdk_sha256 }}' .github/workflows/openwrt-build.yml
grep -q '~/.cargo/registry' .github/workflows/openwrt-build.yml .github/workflows/ci.yml
grep -q "github.ref == 'refs/heads/master'" .github/workflows/openwrt-build.yml
grep -Fq 'release_tag="v${version}-r${package_release}"' .github/workflows/openwrt-build.yml
grep -Fq -- '--target "$GITHUB_SHA"' .github/workflows/openwrt-build.yml
grep -q 'docs/images/wloc-dashboard.png' README.md
! grep -Eiq 'udp.*(500|4500)|(500|4500).*udp|ePDG|PassWall|OpenClash|sing-box|Xray' \
	openwrt/files/usr/libexec/wloc/rules.sh openwrt/files/etc/init.d/wloc
! grep -Riq 'WLOC_DUMP_DIR|forward\.dump|request_body.*eprintln|payload.*eprintln' src openwrt

echo 'host tests: PASS'
