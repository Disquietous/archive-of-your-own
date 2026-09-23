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

// ---------------------------------------------------------------------------
// Per-stream identity and timing
// ---------------------------------------------------------------------------

/// One Tor stream as the SOCKS bridge observed it: which circuit it rode
/// (so failures can be attributed to an exit) and the TLS-level timing —
/// how long the Tor connect took, and when the first bytes went out to and
/// came back from the exit, relative to the connect completing. Every
/// field is measured; nothing is inferred.
#[derive(Debug, Clone, Default)]
pub struct StreamInfo {
    /// Process-unique id of the stream, for matching timing updates.
    pub id: u64,
    /// arti's circuit id as it displays it ("Circ 3.3").
    pub circuit: String,
    /// First 8 hex chars of the exit relay's RSA fingerprint, or "?".
    pub exit: String,
    /// First 8 hex chars of the guard relay's RSA fingerprint, or "?".
    pub guard: String,
    /// "host:port" the stream was opened to.
    pub target: String,
    /// Time for `TorClient::connect` to return.
    pub connect_ms: u64,
    /// Offset after connect of the first byte the client sent (TLS
    /// ClientHello), None if nothing was ever sent.
    pub first_tx_ms: Option<u64>,
    /// Offset after connect of the first byte back from the exit, None if
    /// the exit never answered.
    pub first_rx_ms: Option<u64>,
}

impl StreamInfo {
    /// One-line form stored with each request-log row.
    pub fn summary(&self) -> String {
        format!(
            "circ={} exit={} guard={} connect={}ms first_tx={} first_rx={}",
            self.circuit, self.exit, self.guard, self.connect_ms,
            offset(self.first_tx_ms), offset(self.first_rx_ms)
        )
    }
}

fn offset(ms: Option<u64>) -> String {
    ms.map_or_else(|| "never".to_string(), |ms| format!("+{ms}ms"))
}

static CURRENT_STREAM: std::sync::OnceLock<std::sync::Mutex<Option<StreamInfo>>> =
    std::sync::OnceLock::new();
static NEXT_STREAM_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn stream_slot() -> &'static std::sync::Mutex<Option<StreamInfo>> {
    CURRENT_STREAM.get_or_init(|| std::sync::Mutex::new(None))
}

/// Allocate an id for a stream the bridge is about to open.
pub fn next_stream_id() -> u64 {
    NEXT_STREAM_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// Publish the stream that just connected as the current one. Requests are
/// serialized by the rate limiter, so "most recently opened" is the stream
/// carrying the request being audited.
pub fn set_current_stream(info: StreamInfo) {
    if let Ok(mut slot) = stream_slot().lock() {
        *slot = Some(info);
    }
}

/// Record the first-byte-out offset for `id`, if it is still current.
pub fn note_stream_first_tx(id: u64, ms: u64) {
    if let Ok(mut slot) = stream_slot().lock() {
        if let Some(s) = slot.as_mut().filter(|s| s.id == id) {
            s.first_tx_ms.get_or_insert(ms);
        }
    }
}

/// Record the first-byte-in offset for `id`, if it is still current.
pub fn note_stream_first_rx(id: u64, ms: u64) {
    if let Ok(mut slot) = stream_slot().lock() {
        if let Some(s) = slot.as_mut().filter(|s| s.id == id) {
            s.first_rx_ms.get_or_insert(ms);
        }
    }
}

/// Forget the current stream. Called on disconnect and circuit rotation
/// alongside `clear_current_circuit_hops`.
pub fn clear_current_stream() {
    if let Ok(mut slot) = stream_slot().lock() {
        *slot = None;
    }
}

/// The most recently opened stream, None until one has run on the current
/// Tor client (or off Tor).
pub fn current_stream() -> Option<StreamInfo> {
    stream_slot().lock().ok().and_then(|s| s.clone())
}
