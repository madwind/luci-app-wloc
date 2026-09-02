use std::fmt;
use std::io::{self, Write};

pub fn write(args: fmt::Arguments<'_>) {
    let now = time::OffsetDateTime::now_utc();
    let rendered = args.to_string();
    let message = rendered.strip_prefix("wlocd: ").unwrap_or(&rendered);
    let mut stderr = io::stderr().lock();
    let _ = writeln!(
        stderr,
        "{:04}/{:02}/{:02} {:02}:{:02}:{:02}.{:06} {}",
        now.year(),
        now.month() as u8,
        now.day(),
        now.hour(),
        now.minute(),
        now.second(),
        now.microsecond(),
        message
    );
}
