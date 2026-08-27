#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="$ROOT/root"
HTDOCS="$ROOT/htdocs"

RULES="$ROOTFS/usr/libexec/wloc/rules.sh"
AP_TEST="$ROOT/tests/ap-discovery.test.js"

fail() {
	echo "host tests: FAIL: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 \
		|| fail "required command not found: $1"
}

for command in sh find python3 node sed awk sort; do
	need "$command"
done

[ -d "$ROOTFS" ] || fail "root directory not found"
[ -d "$HTDOCS" ] || fail "htdocs directory not found"
[ -f "$RULES" ] || fail "rules.sh not found"
[ -f "$AP_TEST" ] || fail "AP discovery test not found"


echo '==> Shell syntax'

while IFS= read -r -d '' script; do
	sh -n "$script" || fail "shell syntax error: $script"
done < <(
	find "$ROOTFS" -type f \
		\( \
			-name '*.sh' \
			-o -path '*/etc/init.d/*' \
			-o -path '*/etc/uci-defaults/*' \
			-o -path '*/usr/libexec/rpcd/*' \
		\) \
		-print0
)


echo '==> JSON syntax'

while IFS= read -r -d '' json; do
	python3 -m json.tool "$json" >/dev/null \
		|| fail "invalid JSON: $json"
done < <(
	find "$ROOTFS" -type f -name '*.json' -print0
)


echo '==> JavaScript syntax'

while IFS= read -r -d '' js; do
	node --check "$js" >/dev/null \
		|| fail "JavaScript syntax error: $js"
done < <(
	find "$HTDOCS" -type f -name '*.js' -print0
)


echo '==> JavaScript behavior'

node "$AP_TEST"


echo '==> WLOC shell behavior'

# Load function definitions from rules.sh without executing its command dispatcher.
eval "$(sed '/^case /,$d' "$RULES")"


echo '  -> port validation'

valid_port 1 \
	|| fail 'valid_port rejected port 1'

valid_port 61520 \
	|| fail 'valid_port rejected port 61520'

valid_port 65535 \
	|| fail 'valid_port rejected port 65535'

if valid_port 0; then
	fail 'valid_port accepted port 0'
fi

if valid_port 65536; then
	fail 'valid_port accepted port 65536'
fi

if valid_port abc; then
	fail 'valid_port accepted a non-numeric port'
fi


echo '  -> MAC validation'

valid_mac 'a6:88:db:2b:1f:bf' \
	|| fail 'valid_mac rejected a valid unicast MAC'

valid_mac '02:11:22:33:44:55' \
	|| fail 'valid_mac rejected a locally administered MAC'

if valid_mac 'a7:88:db:2b:1f:bf'; then
	fail 'valid_mac accepted a multicast MAC'
fi

if valid_mac '00:00:00:00:00:00'; then
	fail 'valid_mac accepted the zero MAC'
fi

if valid_mac 'not-a-mac'; then
	fail 'valid_mac accepted an invalid MAC'
fi


echo '  -> nftables table health'

empty_host_set_fixture='table inet wloc {
    set target_ap_interfaces {
        type ifname
        flags timeout
    }

    set apple_wloc_v4 {
        type ipv4_addr
        flags timeout
    }

    chain redirect_prerouting {
        type nat hook prerouting priority -105; policy accept;
        iifname @target_ap_interfaces ip daddr @apple_wloc_v4 tcp dport 443 redirect to :61520 comment "wloc owned AP redirect"
    }
}'

printf '%s\n' "$empty_host_set_fixture" \
    | table_healthy 61520 \
    || fail 'table_healthy rejected a valid table with an empty host set'

if printf '%s\n' "$healthy_table_fixture" \
	| table_healthy 61521; then
	fail 'table_healthy accepted the wrong redirect port'
fi

if printf '%s\n' "$healthy_table_fixture" \
	| sed '/flags timeout/d' \
	| table_healthy 61520; then
	fail 'table_healthy accepted sets without timeout'
fi

if printf '%s\n' "$healthy_table_fixture" \
	| sed '/wloc owned AP redirect/d' \
	| table_healthy 61520; then
	fail 'table_healthy accepted a missing redirect rule'
fi


echo '  -> nftables proxy priority'

order_fixture='table inet routed_proxy {
	chain ingress {
		type filter hook prerouting priority mangle - 1; policy accept;
		jump proxy_dispatch
	}

	chain proxy_dispatch {
		tcp dport 443 tproxy ip to :1041
	}
}'

nft() {
	printf '%s\n' "$order_fixture"
}

priority="$(choose_wloc_priority)"

[ "$priority" = '-152' ] \
	|| fail "expected priority -152, got $priority"


echo '  -> default nftables priority'

order_fixture='table inet unrelated {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}'

priority="$(choose_wloc_priority)"

[ "$priority" = '-105' ] \
	|| fail "expected default priority -105, got $priority"


echo '  -> unknown nftables priority'

order_fixture='table inet unknown_proxy {
	chain ingress {
		type filter hook prerouting priority custom_proxy_priority; policy accept;
		tcp dport 443 tproxy ip to :2080
	}
}'

if choose_wloc_priority >/dev/null 2>&1; then
	fail 'choose_wloc_priority accepted an unknown priority'
fi


echo '  -> conntrack safety boundary'

order_fixture='table inet too_early_proxy {
	chain ingress {
		type filter hook prerouting priority -199; policy accept;
		tcp dport 443 tproxy ip to :2080
	}
}'

if choose_wloc_priority >/dev/null 2>&1; then
	fail 'choose_wloc_priority crossed the conntrack safety boundary'
fi


echo 'host tests: PASS'