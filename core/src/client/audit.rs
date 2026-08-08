// ---------------------------------------------------------------------------
// Request audit log (dev-console style)
// ---------------------------------------------------------------------------

/// One recorded HTTP request/response. Populated in the client's fetch/post
/// paths and drained to the encrypted database by the app layer.
#[derive(Debug, Clone)]
pub struct RequestRecord {
    pub started_at_ms: u64,
    pub method: String,
    pub url: String,
    pub status: u16,
    pub duration_ms: u64,
    pub request_bytes: u64,
    pub response_bytes: u64,
    pub error: Option<String>,
    /// Redacted request payload (POST form params; credentials removed).
    pub payload: Option<String>,
}

static REQUEST_LOG: std::sync::OnceLock<std::sync::Mutex<std::collections::VecDeque<RequestRecord>>> =
    std::sync::OnceLock::new();

fn request_log_buffer() -> &'static std::sync::Mutex<std::collections::VecDeque<RequestRecord>> {
    REQUEST_LOG.get_or_init(|| std::sync::Mutex::new(std::collections::VecDeque::new()))
}

/// Append a record to the in-memory buffer (bounded — the DB is the durable store).
pub fn push_request_record(record: RequestRecord) {
    if let Ok(mut buf) = request_log_buffer().lock() {
        buf.push_back(record);
        while buf.len() > 2000 {
            buf.pop_front();
        }
    }
}

/// Drain all buffered records (the app layer persists them to the database).
pub fn drain_request_records() -> Vec<RequestRecord> {
    request_log_buffer().lock().map(|mut b| b.drain(..).collect()).unwrap_or_default()
}

/// Audit context for one logical request: captures identity and timing at
/// construction, records the terminal outcome (transparent retries collapse
/// into the final row). Every fetch/POST path logs through this.
pub(super) struct AuditCtx {
    started_at_ms: u64,
    start: std::time::Instant,
    method: String,
    url: String,
    request_bytes: u64,
    payload: Option<String>,
}

impl AuditCtx {
    /// `payload` is the redacted POST body; None for GETs. Request size is
    /// approximated as URL + payload + a typical header block.
    pub(super) fn new(method: &str, url: &str, payload: Option<String>) -> Self {
        AuditCtx {
            started_at_ms: now_ms(),
            start: std::time::Instant::now(),
            method: method.to_string(),
            url: url.to_string(),
            request_bytes: (url.len() + payload.as_deref().map_or(0, str::len) + 380) as u64,
            payload,
        }
    }

    pub(super) fn record(&self, status: u16, response_bytes: u64, error: Option<String>) {
        push_request_record(RequestRecord {
            started_at_ms: self.started_at_ms,
            method: self.method.clone(),
            url: self.url.clone(),
            status,
            duration_ms: self.start.elapsed().as_millis() as u64,
            request_bytes: self.request_bytes,
            response_bytes,
            error,
            payload: self.payload.clone(),
        });
    }
}

/// A request currently in flight, for the request-log UI's live view.
#[derive(Debug, Clone)]
pub struct ActiveRequest {
    pub id: u64,
    pub started_at_ms: u64,
    pub method: String,
    pub url: String,
}

static ACTIVE_REQUESTS: std::sync::OnceLock<std::sync::Mutex<Vec<ActiveRequest>>> =
    std::sync::OnceLock::new();
static NEXT_ACTIVE_REQUEST_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn active_requests() -> &'static std::sync::Mutex<Vec<ActiveRequest>> {
    ACTIVE_REQUESTS.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

/// RAII registration of an in-flight request: registers on creation and
/// unregisters on drop — including early returns, retries that give up,
/// and task aborts — so the live view can never leak a phantom entry.
pub struct ActiveRequestGuard {
    id: u64,
}

impl ActiveRequestGuard {
    pub fn new(method: &str, url: &str) -> Self {
        let id = NEXT_ACTIVE_REQUEST_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if let Ok(mut list) = active_requests().lock() {
            list.push(ActiveRequest {
                id,
                started_at_ms: now_ms(),
                method: method.to_string(),
                url: url.to_string(),
            });
        }
        Self { id }
    }
}

impl Drop for ActiveRequestGuard {
    fn drop(&mut self) {
        if let Ok(mut list) = active_requests().lock() {
            list.retain(|r| r.id != self.id);
        }
    }
}

pub fn active_requests_snapshot() -> Vec<ActiveRequest> {
    active_requests().lock().map(|l| l.clone()).unwrap_or_default()
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Redact credentials/tokens from POST form params before logging.
pub fn redact_payload(params: &[(&str, &str)]) -> String {
    params.iter().map(|(k, v)| {
        let key = k.to_lowercase();
        let redacted = key.contains("password")
            || key.contains("authenticity_token")
            || key.contains("token")
            || key.contains("secret");
        format!("{}={}", k, if redacted { "‹redacted›" } else { v })
    }).collect::<Vec<_>>().join("&")
}
