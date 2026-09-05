from pathlib import Path


changed_masks = 0
for base in (Path("root"), Path("src")):
    for path in base.rglob("*"):
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if "0xc0010000" not in text:
            continue
        count = text.count("0xc0010000")
        path.write_text(text.replace("0xc0010000", "0xe0010000"))
        changed_masks += count
if changed_masks == 0:
    raise SystemExit("WLOC reserved mark mask was not found")

# Keep Direct sockets completely unmarked. Namespace only WLOC's own TPROXY sockets so
# NftFlow's generic mark 0x1 can never equal a WLOC outbound dispatch mark.
path = Path("src/wloc-rs/src/outbound.rs")
text = path.read_text()
old = "use crate::config::Outbound;\n\n"
new = "use crate::config::Outbound;\n\nconst OUTBOUND_NAMESPACE_MARK: u32 = 0x20000000;\n\n"
if text.count(old) != 1:
    raise SystemExit("outbound namespace constant marker mismatch")
text = text.replace(old, new, 1)
old = "        Outbound::Tproxy { mark, .. } => connect_marked(destination, *mark).await,\n"
new = "        Outbound::Tproxy { mark, .. } => {\n            connect_marked(destination, OUTBOUND_NAMESPACE_MARK | *mark).await\n        }\n"
if text.count(old) != 1:
    raise SystemExit("TPROXY TCP namespace marker mismatch")
text = text.replace(old, new, 1)
old = '''    if let Outbound::Tproxy { mark, .. } = outbound {
        set_socket_mark(&socket, *mark)?;
    }
'''
new = '''    if let Outbound::Tproxy { mark, .. } = outbound {
        set_socket_mark(&socket, OUTBOUND_NAMESPACE_MARK | *mark)?;
    }
'''
if text.count(old) != 1:
    raise SystemExit("TPROXY UDP namespace marker mismatch")
text = text.replace(old, new, 1)
path.write_text(text)

# Render the namespaced mark only for WLOC-generated outbound traffic. AP dispatch keeps
# using the configured low mark because that mark identifies the AP's configured port.
path = Path("root/usr/libexec/wloc/firewall.uc")
text = path.read_text()
old = "const HANDLED_MARK = 0x00010000;\n"
new = "const HANDLED_MARK = 0x00010000;\nconst OUTBOUND_NAMESPACE_MARK = 0x20000000;\n"
if text.count(old) != 1:
    raise SystemExit("firewall namespace constant marker mismatch")
text = text.replace(old, new, 1)
old = '        push(outbound_dispatch, `meta mark ${hex32(outbound.mark)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc outbound ${outbound.mark}"`);\n'
new = '        push(outbound_dispatch, `meta mark ${hex32(OUTBOUND_NAMESPACE_MARK | outbound.mark)} meta l4proto { tcp, udp } ct mark set ct mark | ${hex32(HANDLED_MARK)} meta mark set ${hex32(handled)} counter tproxy to :${outbound.port} accept comment "wloc outbound ${outbound.mark}"`);\n'
if text.count(old) != 1:
    raise SystemExit("firewall outbound namespace marker mismatch")
text = text.replace(old, new, 1)
path.write_text(text)

# Policy routing must use the same namespaced mark. Keep state files in configured-mark
# form and remove both namespaced and pre-r67 legacy rules during cleanup/upgrades.
path = Path("root/usr/libexec/wloc/rules.uc")
text = path.read_text()
old = "const RESERVED_MARK_MASK = 0xe0010000;\nconst OUTBOUND_POLICY_MASK = 0xfffeffff;\n"
new = "const RESERVED_MARK_MASK = 0xe0010000;\nconst OUTBOUND_NAMESPACE_MARK = 0x20000000;\nconst OUTBOUND_POLICY_MASK = 0xfffeffff;\n"
if text.count(old) != 1:
    raise SystemExit("rules namespace constant marker mismatch")
text = text.replace(old, new, 1)
old = "function rule_present(family, mark, table) { return policy_rule_present(family, mark, OUTBOUND_POLICY_MASK, table); }\n"
new = "function rule_present(family, mark, table) { return policy_rule_present(family, OUTBOUND_NAMESPACE_MARK | mark, OUTBOUND_POLICY_MASK, table); }\n"
if text.count(old) != 1:
    raise SystemExit("rules presence namespace marker mismatch")
text = text.replace(old, new, 1)
old = '''function read_outbound_state() {
'''
new = '''function delete_outbound_policy_rule(family, mark, table) {
    let namespaced = delete_policy_rule(family, OUTBOUND_NAMESPACE_MARK | mark, table);
    let legacy = delete_policy_rule(family, mark, table);
    return namespaced && legacy;
}
function read_outbound_state() {
'''
if text.count(old) != 1:
    raise SystemExit("rules cleanup helper marker mismatch")
text = text.replace(old, new, 1)
text = text.replace("delete_policy_rule('4', item.mark, item.table)", "delete_outbound_policy_rule('4', item.mark, item.table)")
text = text.replace("delete_policy_rule('6', item.mark, item.table)", "delete_outbound_policy_rule('6', item.mark, item.table)")
old = "        if (!quiet(`ip -4 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {\n"
new = "        if (!quiet(`ip -4 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${OUTBOUND_NAMESPACE_MARK | outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {\n"
if text.count(old) != 1:
    raise SystemExit("IPv4 outbound install namespace marker mismatch")
text = text.replace(old, new, 1)
old = "        if (ipv6 && !quiet(`ip -6 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {\n"
new = "        if (ipv6 && !quiet(`ip -6 rule add priority ${OUTBOUND_RULE_PRIORITY} fwmark ${OUTBOUND_NAMESPACE_MARK | outbound.mark}/${hex32(OUTBOUND_POLICY_MASK)} lookup ${table}`)) {\n"
if text.count(old) != 1:
    raise SystemExit("IPv6 outbound install namespace marker mismatch")
text = text.replace(old, new, 1)
# Rollback paths operate on configured marks, so route them through the dual cleanup helper too.
text = text.replace("delete_policy_rule('4', item.mark, table)", "delete_outbound_policy_rule('4', item.mark, table)")
text = text.replace("delete_policy_rule('6', item.mark, table)", "delete_outbound_policy_rule('6', item.mark, table)")
text = text.replace("delete_policy_rule('4', outbound.mark, table)", "delete_outbound_policy_rule('4', outbound.mark, table)")
path.write_text(text)
