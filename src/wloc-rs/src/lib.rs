macro_rules! eprintln {
    ($($arg:tt)*) => {{
        crate::logging::write(format_args!($($arg)*));
    }};
}

pub mod ca;
pub mod client_hello;
pub mod config;
pub mod http1;
pub mod logging;
pub mod network_source;
pub mod proxy;
pub mod status;
pub mod wloc;

pub const DEFAULT_DOMAINS: [&str; 2] = ["gs-loc.apple.com", "gs-loc-cn.apple.com"];

pub fn approved_host(host: &str, domains: &[String]) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    domains.iter().any(|domain| domain == &host)
}
