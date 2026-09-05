from pathlib import Path

path = Path('root/usr/libexec/wloc/firewall.uc')
text = path.read_text()
old = '''    let recovering = false, warning = '';
    if (daemon_ready()) {
        let port = listen_port();
        let reconciled = port ? rules('reconcile', [ port ]) : { ok: false, error: 'the WLOC listen port is empty' };
        if (!reconciled.ok) {
            let cleaned = rules('cleanup', []);
            recovering = true;
            warning = cleaned.ok
                ? 'Runtime rule refresh failed; WLOC will retry automatically.'
                : 'Runtime rule refresh failed and fail-open cleanup also failed; WLOC will retry automatically.';
        }
    } else {
        let cleaned = rules('cleanup', []);
        recovering = true;
        warning = cleaned.ok
            ? 'Runtime dynamic sets are waiting for the WLOC listener; WLOC will retry automatically.'
            : 'WLOC listener is not ready and fail-open cleanup failed; WLOC will retry automatically.';
    }
'''
new = '''    let recovering = false, warning = '';
    if (!daemon_ready()) {
        let cleaned = rules('cleanup', []);
        warning = cleaned.ok
            ? 'WLOC is not running; interception remains disabled.'
            : 'WLOC is not running and fail-open cleanup failed.';
    }
'''
if text.count(old) != 1:
    raise SystemExit('firewall apply reconcile block marker failed')
path.write_text(text.replace(old, new, 1))
