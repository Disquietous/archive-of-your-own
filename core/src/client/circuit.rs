//! Tracking of the Tor circuit path that actually carries AO3 traffic.
//!
//! Every AO3 request flows through our embedded SOCKS bridge
//! ([`super::socks`]), which opens an arti `DataStream` per connection.
//! That stream is the one place the real circuit exists, so the bridge
//! captures its path (via `tor-proto`'s `stream-ctrl` API) right after a
//! successful connect and stores it here. The slot mirrors the
//! `REQUEST_LOG` pattern in [`super::audit`]: a process-global `OnceLock`
//! holding a small mutex-guarded value, cheap to read from the UI thread.
//!
//! The slot is cleared on `disconnect_tor` and circuit rotation so a stale
//! path is never displayed, and it stays empty until the first stream has
//! actually run — the UI shows a generic "no circuit used yet" diagram for
//! that state rather than invented identities.

/// One hop of the Tor circuit most recently used for AO3 traffic.
///
/// All fields describe the real relay arti connected through — nothing here
/// is ever fabricated. `country` is an ISO 3166-1 alpha-2 code resolved from
/// the relay's IP via arti's embedded GeoIP database, or empty when the
/// address has no GeoIP entry (the UI then shows the IP without a country
/// chip).
#[derive(Debug, Clone)]
pub struct CircuitHopInfo {
    /// "Guard", "Relay", or "Exit" — derived from the hop's position.
    pub role: String,
    /// The relay's IP address (no port), or empty for a virtual hop.
    pub address: String,
    /// ISO country code for the address, or empty if unknown.
    pub country: String,
}

/// Process-global slot holding the most recently captured circuit path.
static CURRENT_CIRCUIT: std::sync::OnceLock<std::sync::Mutex<Vec<CircuitHopInfo>>> =
    std::sync::OnceLock::new();

fn slot() -> &'static std::sync::Mutex<Vec<CircuitHopInfo>> {
    CURRENT_CIRCUIT.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

/// Record the path of the circuit that just carried (or is about to carry)
/// a stream. Called by the SOCKS bridge after every successful Tor connect.
pub fn set_current_circuit_hops(hops: Vec<CircuitHopInfo>) {
    if let Ok(mut slot) = slot().lock() {
        *slot = hops;
    }
}

/// Forget the captured path. Called on disconnect and circuit rotation so
/// a superseded path never lingers in the UI.
pub fn clear_current_circuit_hops() {
    if let Ok(mut slot) = slot().lock() {
        slot.clear();
    }
}

/// The most recently captured circuit path; empty until the first stream
/// has run on the current Tor client.
pub fn current_circuit_hops() -> Vec<CircuitHopInfo> {
    slot().lock().map(|s| s.clone()).unwrap_or_default()
}
