use crate::error::AppError;

pub(crate) mod audit;
mod circuit;
pub mod clearance;
mod failure;
mod helpers;
pub mod privacy;
pub mod routes;
#[cfg(feature = "tor")]
mod socks;
pub mod transport;
mod vpn;

pub use audit::{ActiveRequest, ActiveRequestGuard, RequestRecord, active_requests_snapshot,
                drain_request_records, now_ms, push_request_record, redact_payload};
pub use circuit::{CircuitHopInfo, StreamInfo, current_circuit_hops, current_stream};
pub use clearance::SiteClearance;
pub use failure::FailureKind;
pub use helpers::sniff_image_kind;
pub use privacy::{NetworkRefusal, PrivacyMode, VpnFingerprint, VpnStatus};
pub use transport::{PostOutcome, SiteHooks, Transport};

#[cfg(feature = "tor")]
pub use socks::{kill_socks_streams, live_socks_streams};
/// Without Tor there is no SOCKS proxy, so never any streams.
#[cfg(not(feature = "tor"))]
pub fn kill_socks_streams() {}
#[cfg(not(feature = "tor"))]
pub fn live_socks_streams() -> usize { 0 }

/// Base URLs of every site the transport may hold cookies for; the jar is
/// per-site, so carrying cookies across a circuit rotation asks per site.
pub(crate) const KNOWN_SITES: &[&str] = &["https://archiveofourown.org"];

/// Largest page body the client will buffer. The biggest real AO3 pages
/// (a long work with view_full_work) run a few MB; past this the body is
/// not a page the parsers could use, and buffering it unbounded is the
/// only way a hostile or broken response could exhaust memory.
pub const MAX_PAGE_BYTES: u64 = 24 * 1024 * 1024;
/// Largest image body the client will buffer.
pub const MAX_IMAGE_BYTES: u64 = 8 * 1024 * 1024;

/// Arti's on-disk state (guards, consensus, everything) under the app's
/// state directory.
pub fn tor_state_dir(state_dir: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(state_dir).join("tor")
}

/// Delete all of arti's on-disk state. Only safe with no Tor client alive.
pub fn wipe_tor_state(state_dir: &str) -> Result<(), AppError> {
    let dir = tor_state_dir(state_dir);
    match std::fs::remove_dir_all(&dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(AppError::TorError(format!("Cannot delete Tor state {}: {e}", dir.display()))),
    }
}

/// Cloudflare's cookies (`cf_clearance`, `__cf_bm`, `_cfuvid`, ...): bound
/// to the exit that earned them, unrelated to the AO3 session.
pub(crate) fn is_cloudflare_cookie(name: &str) -> bool {
    name.starts_with("cf_") || name.starts_with("__cf") || name == "_cfuvid"
}

/// A jar string without its Cloudflare cookies.
pub fn strip_cloudflare_cookies(cookies: &str) -> String {
    cookies.split("; ")
        .filter(|c| !c.is_empty() && !is_cloudflare_cookie(c.split('=').next().unwrap_or("")))
        .collect::<Vec<_>>()
        .join("; ")
}


/// Compatibility shim over the privacy mode (`privacy.rs`): "Tor required"
/// is the Tor mode, "not required" the Open one. Kept for the bridge until
/// Swift speaks in modes.
pub fn set_tor_required(required: bool) {
    privacy::set_privacy_mode(if required { PrivacyMode::Tor } else { PrivacyMode::Open });
}

pub fn tor_required() -> bool {
    privacy::privacy_mode() == PrivacyMode::Tor
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// The transport knows no source: every site's pages, forms and rules
    /// live in its adapter under `crate::source` (Area 5.4). A reference
    /// from here back into a source would undo that.
    #[test]
    fn transport_names_no_source() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/client");
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let text = std::fs::read_to_string(&path).unwrap();
            for (n, line) in text.lines().enumerate() {
                let code = line.split("//").next().unwrap_or("");
                // Spelled in two parts so this file passes its own check.
                let needle = ["crate::", "source"].concat();
                assert!(!code.contains(&needle),
                        "{}:{}: the transport must not reach into a source", path.display(), n + 1);
            }
        }
    }

    #[test]
    fn test_strip_cloudflare_cookies() {
        assert_eq!(
            strip_cloudflare_cookies("_otwarchive_session=a; cf_clearance=b; remember_user_token=c; __cf_bm=d; _cfuvid=e"),
            "_otwarchive_session=a; remember_user_token=c");
        assert_eq!(strip_cloudflare_cookies(""), "");
    }
}
