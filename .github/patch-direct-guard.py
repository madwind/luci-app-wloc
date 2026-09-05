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

path = Path("src/wloc-rs/src/outbound.rs")
text = path.read_text()
old = "use crate::config::Outbound;\n\n"
new = "use crate::config::Outbound;\n\nconst DIRECT_GUARD_MARK: u32 = 0x20000000;\n\n"
if text.count(old) != 1:
    raise SystemExit("outbound guard constant marker mismatch")
text = text.replace(old, new, 1)
old = '''        Outbound::Direct => {
            let stream = TcpStream::connect(destination).await?;
            stream.set_nodelay(true)?;
            Ok(stream)
        }
'''
new = '''        Outbound::Direct => connect_marked(destination, DIRECT_GUARD_MARK).await,
'''
if text.count(old) != 1:
    raise SystemExit("direct TCP marker mismatch")
text = text.replace(old, new, 1)
old = '''    if let Outbound::Tproxy { mark, .. } = outbound {
        set_socket_mark(&socket, *mark)?;
    }
'''
new = '''    match outbound {
        Outbound::Direct => set_socket_mark(&socket, DIRECT_GUARD_MARK)?,
        Outbound::Tproxy { mark, .. } => set_socket_mark(&socket, *mark)?,
    }
'''
if text.count(old) != 1:
    raise SystemExit("direct UDP marker mismatch")
text = text.replace(old, new, 1)
path.write_text(text)
