pub mod ca;
pub mod client_hello;
pub mod config;
pub mod http1;
pub mod network_source;
pub mod proxy;
pub mod status;
pub mod wloc;

pub const APPROVED_HOSTS: [&str; 2] = ["gs-loc.apple.com", "gs-loc-cn.apple.com"];

pub fn approved_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    APPROVED_HOSTS.contains(&host.as_str())
}
