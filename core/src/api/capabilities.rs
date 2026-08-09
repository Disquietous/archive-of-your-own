// ---------------------------------------------------------------------------
// Platform capabilities — services only the platform layer can provide
// ---------------------------------------------------------------------------
//
// Opposite dependency direction from `events::CoreObserver`: an observer is
// informational (Rust tells Swift what happened, fire-and-forget), while a
// capability is a service request Rust blocks on and cannot proceed
// without. Kept as a separate trait for exactly that reason — merging the
// two would let a slow or absent observer implementation stall Rust code
// that has no informational content to deliver.
//
// Rule: never call a capability while holding a lock. Rust awaits the
// result, so unlike `emit`, this one genuinely can deadlock if called with
// the client or storage guard held.

use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum CapabilityError {
    #[error("{message}")]
    Failed { message: String },
    #[error("no platform capability implementation is registered")]
    Unavailable,
}

/// Implemented on the Swift side via a hidden WKWebView routed through the
/// given local SOCKS port — only WKWebView can run the JS Cloudflare uses to
/// clear its challenge. Returns every `archiveofourown.org` cookie
/// (`"name=value"` strings, matching the format `AO3Client::set_session_cookies`
/// already accepts) gathered after the challenge resolves.
#[uniffi::export(callback_interface)]
#[async_trait::async_trait]
pub trait PlatformCapabilities: Send + Sync {
    async fn earn_cloudflare_clearance(&self, socks_port: u16) -> Result<Vec<String>, CapabilityError>;
}

static CAPABILITIES: OnceLock<Mutex<Option<Arc<dyn PlatformCapabilities>>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Arc<dyn PlatformCapabilities>>> {
    CAPABILITIES.get_or_init(|| Mutex::new(None))
}

/// Register (or clear, with `None`) the single process-wide implementation.
pub fn set(capabilities: Option<Arc<dyn PlatformCapabilities>>) {
    *slot().lock().unwrap() = capabilities;
}

/// The registered implementation, if any. `None` means no platform layer
/// has registered one yet (or it was explicitly cleared) — callers should
/// treat that as "capability unavailable," not panic.
pub(crate) fn get() -> Option<Arc<dyn PlatformCapabilities>> {
    slot().lock().unwrap().clone()
}
