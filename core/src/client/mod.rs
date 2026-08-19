use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, USER_AGENT};
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep};

use crate::error::AppError;

mod audit;
mod auth;
mod circuit;
mod failure;
mod helpers;
mod ops;
pub mod routes;
#[cfg(feature = "tor")]
mod socks;

pub use audit::{ActiveRequest, ActiveRequestGuard, RequestRecord, active_requests_snapshot,
                drain_request_records, now_ms, push_request_record, redact_payload};
pub use circuit::{CircuitHopInfo, current_circuit_hops};
pub use failure::FailureKind;
pub use helpers::sniff_image_kind;

use audit::AuditCtx;
use helpers::scan_attr_near;
#[cfg(feature = "tor")]
use socks::run_socks_proxy;

pub const BASE_URL: &str = "https://archiveofourown.org";

const APP_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0";
const RATE_LIMIT_DELAY: Duration = Duration::from_millis(500);

// ---------------------------------------------------------------------------
// Transport abstraction
// ---------------------------------------------------------------------------

enum Transport {
    Direct(reqwest::Client),
    #[cfg(feature = "tor")]
    Tor {
        client: reqwest::Client,
        // Keep the TorClient alive so the background tasks continue running.
        // The SOCKS proxy task also holds a clone.
        _tor: Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>,
    },
}

// ---------------------------------------------------------------------------
// AO3Client
// ---------------------------------------------------------------------------

/// HTTP client for fetching AO3 pages, with optional Tor transport.
pub struct AO3Client {
    transport: Transport,
    cookie_jar: Arc<reqwest::cookie::Jar>,
    last_request: Arc<Mutex<Option<Instant>>>,
    timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    /// Per-route timeout overrides (route key → seconds), consulted by URL
    /// classification on every GET; routes without an entry use
    /// `timeout_secs`. Shared with the owning AO3App so edits apply to the
    /// live client and survive client replacement on (re)connect.
    route_timeouts: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>,
    socks_port: Option<u16>,
    /// Posting credentials harvested opportunistically from pages fetched
    /// for content — so kudos/comments POST directly, with no preparatory
    /// GET. The CSRF token is session-scoped (any page's token validates
    /// until the login session changes); the pseud id is per-account.
    csrf_token: Arc<std::sync::Mutex<Option<String>>>,
    pseud_id: Arc<std::sync::Mutex<Option<String>>>,
    /// Accept-loop task of the local SOCKS proxy. Aborted on circuit
    /// rotation/disconnect so each rotation doesn't orphan a listener port
    /// and a background task.
    socks_proxy_task: Option<tokio::task::AbortHandle>,
}

impl AO3Client {
    /// The underlying reqwest client of the active transport.
    fn http(&self) -> &reqwest::Client {
        match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        }
    }

    /// The configured per-request timeout.
    fn request_timeout(&self) -> Duration {
        Duration::from_secs(self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed))
    }

    /// The timeout for a concrete URL: its route's override when one is
    /// set, the global timeout otherwise (including unclassified URLs).
    pub fn timeout_for_url(&self, url: &str) -> u64 {
        let default = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        let key = routes::route_for_url(url);
        let (override_secs, map_len) = self.route_timeouts.lock()
            .map(|m| (key.and_then(|k| m.get(k).copied()), m.len()))
            .unwrap_or((None, 0));
        log_debug!("timeouts", " {} -> route={} override={} default={}s ({} overrides in map)",
                   url, key.unwrap_or("(unclassified)"),
                   override_secs.map_or("none".to_string(), |s| format!("{s}s")),
                   default, map_len);
        override_secs.unwrap_or(default)
    }

    /// Adopt the app-owned override map (replacing this client's own) so a
    /// freshly built client sees existing overrides and later edits without
    /// re-plumbing. Call at every client-creation site.
    pub fn share_route_timeouts(&mut self, map: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>) {
        self.route_timeouts = map;
    }

    pub fn is_tor(&self) -> bool {
        #[cfg(feature = "tor")]
        { matches!(self.transport, Transport::Tor { .. }) }
        #[cfg(not(feature = "tor"))]
        { false }
    }

    #[cfg(feature = "tor")]
    pub fn tor_client(&self) -> Option<&Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>> {
        match &self.transport {
            Transport::Tor { _tor, .. } => Some(_tor),
            _ => None,
        }
    }

    /// Return the local SOCKS5 proxy port, if Tor transport is active.
    pub fn socks_port(&self) -> Option<u16> {
        self.socks_port
    }

    /// Abort this client's SOCKS accept-loop task, if any. Must be called
    /// before the client is replaced or dropped — an `AbortHandle` dropped
    /// without `.abort()` leaves the listener port and accept loop running.
    pub(crate) fn stop_socks_proxy(&mut self) {
        if let Some(old) = self.socks_proxy_task.take() {
            old.abort();
        }
    }

    // -- Constructors -------------------------------------------------------

    /// Create a client using direct HTTP (for development/testing).
    pub async fn new_direct() -> Result<Self, AppError> {
        let (client, jar) = build_reqwest_client(None)?;
        Ok(Self {
            transport: Transport::Direct(client),
            cookie_jar: jar,
            last_request: Arc::new(Mutex::new(None)),
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            route_timeouts: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            socks_port: None,
            csrf_token: Arc::new(std::sync::Mutex::new(None)),
            pseud_id: Arc::new(std::sync::Mutex::new(None)),
            socks_proxy_task: None,
        })
    }

    /// Create a client that routes all traffic through Tor.
    ///
    /// `state_dir` must be a writable directory inside the app's sandbox
    /// (e.g. Application Support). Tor caches consensus data here so
    /// subsequent launches are faster.
    ///
    /// Bootstrap has a 90-second timeout. First launch downloads ~3 MB of
    /// network consensus and typically takes 15-40 seconds.
    #[cfg(feature = "tor")]
    pub async fn new_tor_with_dir(state_dir: &str) -> Result<Self, AppError> {
        use arti_client::TorClient;
        use arti_client::config::TorClientConfigBuilder;

        let tor_dir = std::path::PathBuf::from(state_dir).join("tor");
        let cache_dir = tor_dir.join("cache");
        let data_dir = tor_dir.join("data");
        for dir in [&tor_dir, &cache_dir, &data_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|e| AppError::TorError(format!("Cannot create dir {}: {e}", dir.display())))?;
        }

        let config = TorClientConfigBuilder::from_directories(&data_dir, &cache_dir)
            .build()
            .map_err(|e| AppError::TorError(format!("Tor config: {e}")))?;

        let tor = tokio::time::timeout(
            std::time::Duration::from_secs(90),
            TorClient::create_bootstrapped(config),
        )
        .await
        .map_err(|_| AppError::TorError(
            "Tor bootstrap timed out after 90 seconds. Check your network connection.".to_string()
        ))?
        .map_err(|e| AppError::TorError(format!("Tor bootstrap failed: {e}")))?;

        let tor = Arc::new(tor);

        // Bind a local TCP listener on an ephemeral port to act as a SOCKS5
        // proxy. For every inbound connection we perform a minimal SOCKS5
        // handshake, extract the target address, open a Tor stream, and then
        // bidirectionally copy bytes between the local socket and the Tor
        // DataStream.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| AppError::NetworkError(format!("Failed to bind SOCKS listener: {e}")))?;
        let local_addr = listener
            .local_addr()
            .map_err(|e| AppError::NetworkError(format!("Failed to get local address: {e}")))?;

        let tor_for_proxy = Arc::clone(&tor);
        let proxy_task = tokio::spawn(async move {
            run_socks_proxy(listener, tor_for_proxy).await;
        });

        // A fresh bootstrap means any previously captured path is stale.
        circuit::clear_current_circuit_hops();

        let port = local_addr.port();
        let proxy_url = format!("socks5h://127.0.0.1:{}", port);
        let (client, jar) = build_reqwest_client(Some(&proxy_url))?;

        Ok(Self {
            transport: Transport::Tor {
                client,
                _tor: tor,
            },
            cookie_jar: jar,
            last_request: Arc::new(Mutex::new(None)),
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            route_timeouts: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            socks_port: Some(port),
            csrf_token: Arc::new(std::sync::Mutex::new(None)),
            pseud_id: Arc::new(std::sync::Mutex::new(None)),
            socks_proxy_task: Some(proxy_task.abort_handle()),
        })
    }

    // -- Internal -----------------------------------------------------------

    pub async fn fetch_ajax_with_progress(&self, url: &str, timeout_secs: u64) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, true).await
    }

    pub async fn fetch_with_progress(&self, url: &str, timeout_secs: u64) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, false).await
    }

    async fn fetch_with_progress_inner(&self, url: &str, timeout_secs: u64, ajax: bool) -> Result<String, AppError> {
        let _active = ActiveRequestGuard::new(if ajax { "GET (ajax)" } else { "GET" }, url, timeout_secs);
        let header_timeout = std::time::Duration::from_secs(timeout_secs);
        let body_timeout = std::time::Duration::from_secs(timeout_secs);
        let fetch_start = std::time::Instant::now();
        let audit = AuditCtx::new(if ajax { "GET (ajax)" } else { "GET" }, url, None);
        log_debug!("http", " {} header_timeout={}s body_timeout={}s", url, header_timeout.as_secs(), body_timeout.as_secs());
        // Set after a first 429 or 503: the retry goes out with
        // shift+refresh (no-cache) headers to punch through a cached
        // error response at the edge.
        let mut hard_reload = false;
        // Reports against the ambient operation set by `with_recovery`
        // (`events::scoped`) — a no-op outside that scope, e.g. in tests.
        // This is what lets code down here report status without a
        // progress handle threaded through every call in between.
        macro_rules! progress {
            ($phase:expr, $recv:expr, $total:expr) => {
                if let Some(id) = crate::events::current_op() {
                    crate::events::emit(crate::events::CoreEvent::OperationProgress {
                        id, phase: $phase, bytes: $recv, total: $total,
                    });
                }
            };
        }
        loop {
            self.enforce_rate_limit().await;
            progress!(crate::events::OpPhase::Connecting, 0, None);

            // Check cookies before sending
            let cookies = self.get_session_cookies();
            let has_auth = cookies.contains("user_credentials");
            log_debug!("http"," cookies: has_auth={} len={} for {}", has_auth, cookies.len(), url);

            let client = self.http();

            // Phase 1: Connect + TLS + headers (short timeout — dead connections fail fast)
            let send_start = std::time::Instant::now();
            let mut req = client.get(url);
            if ajax {
                req = req.header("X-Requested-With", "XMLHttpRequest")
                    .header("Accept", "text/html, */*; q=0.01");
            }
            if hard_reload {
                // Browser shift+refresh headers: force every cache between
                // us and the Rails origin to revalidate instead of replaying
                // a stored response.
                req = req.header("Cache-Control", "no-cache")
                    .header("Pragma", "no-cache");
            }
            let response = match tokio::time::timeout(header_timeout, req.send()).await {
                Err(_) => {
                    log_debug!("http"," TIMEOUT send phase after {:?} total={:?} {}", send_start.elapsed(), fetch_start.elapsed(), url);
                    progress!(crate::events::OpPhase::Failed, 0, None);
                    audit.record(0, 0, Some("timeout".to_string()));
                    return Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() });
                }
                Ok(Err(e)) => {
                    log_debug!("http"," ERROR send phase after {:?}: {e} {}", send_start.elapsed(), url);
                    progress!(crate::events::OpPhase::Failed, 0, None);
                    audit.record(0, 0, Some(format!("{e}")));
                    return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") });
                }
                Ok(Ok(r)) => {
                    log_debug!("http"," HEADERS in {:?} status={} {}", send_start.elapsed(), r.status(), url);
                    r
                }
            };

            // Detect stale session — AO3 redirects to login page
            let final_url = response.url().to_string();
            if final_url.contains("/users/login") && !url.contains("/users/login") {
                progress!(crate::events::OpPhase::Failed, 0, None);
                audit.record(response.status().as_u16(), 0, Some("session_expired".to_string()));
                return Err(AppError::SessionExpired);
            }

            let status = response.status();
            let code = status.as_u16();

            // Retry on transient HTTP errors before reading body
            // 429/503: first, retry ONCE with hard-reload headers: edge
            // caches can serve a stored 429/503 for the URL, in which case
            // every client gets it regardless of exit IP (new circuits
            // don't help) while a browser shift+refresh punches through to
            // origin and gets a 200 — observed on bookmark fetches that
            // 503'd in-app while Tor Browser loaded the same page every
            // time. Only when the no-cache retry also fails is the error
            // real — then fail fast so upper layers can back off (503) or
            // rotate for a fresh rate budget / surface an honest countdown
            // (429).
            if (code == 429 || code == 503) && !hard_reload {
                hard_reload = true;
                log_info!("http", " {} for {} — retrying with no-cache (shift+refresh)", code, url);
                progress!(crate::events::OpPhase::Connecting, 0, None);
                continue;
            }
            if code == 429 {
                let retry_after = response.headers().get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.trim().parse::<u32>().ok());
                let detail = match retry_after {
                    Some(secs) => format!("HTTP 429 retry_after={secs}"),
                    None => "HTTP 429".to_string(),
                };
                log_info!("http", " 429 rate-limited ({}) for {}",
                          retry_after.map_or("no retry-after".to_string(), |s| format!("{s}s")), url);
                progress!(crate::events::OpPhase::Failed, 0, None);
                audit.record(code, 0, Some(detail.clone()));
                return Err(AppError::Http {
                    kind: FailureKind::from_status(code, retry_after),
                    detail,
                });
            }
            // Retry policy (rotation on 525/429/403, full reconnect on
            // 502/503/504) lives entirely in the recovery engine now —
            // beyond the one-shot no-cache retry above, this path returns
            // the classified failure on the first non-success status.
            if !status.is_success() {
                progress!(crate::events::OpPhase::Failed, 0, None);
                let detail = format!("HTTP {status} for {url}");
                audit.record(code, 0, Some(detail.clone()));
                return Err(AppError::Http { kind: FailureKind::from_status(code, None), detail });
            }

            // Phase 2: Read body in chunks with idle timeout per chunk
            let total_bytes = response.content_length();
            progress!(crate::events::OpPhase::Downloading, 0, total_bytes);

            let mut bytes_received: u64 = 0;
            let mut body_bytes = Vec::new();
            let mut response = response;

            loop {
                match tokio::time::timeout(body_timeout, response.chunk()).await {
                    Err(_) => {
                        progress!(crate::events::OpPhase::Failed, bytes_received, total_bytes);
                        audit.record(code, bytes_received, Some("timeout".to_string()));
                        // Headers already arrived — the request definitely
                        // reached the origin, unlike a header-phase timeout.
                        return Err(AppError::Http { kind: FailureKind::ResponseTimeout, detail: "timeout".to_string() });
                    }
                    Ok(Err(e)) => {
                        progress!(crate::events::OpPhase::Failed, bytes_received, total_bytes);
                        let detail = format!("Failed to read body: {e}");
                        audit.record(code, bytes_received, Some(detail.clone()));
                        return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail });
                    }
                    Ok(Ok(None)) => break,
                    Ok(Ok(Some(chunk))) => {
                        bytes_received += chunk.len() as u64;
                        body_bytes.extend_from_slice(&chunk);
                        progress!(crate::events::OpPhase::Downloading, bytes_received, total_bytes);
                    }
                }
            }

            progress!(crate::events::OpPhase::Complete, bytes_received, total_bytes);
            log_debug!("http"," DONE {} bytes in {:?} {}", bytes_received, fetch_start.elapsed(), url);
            audit.record(code, bytes_received, None);

            let body = String::from_utf8(body_bytes)
                .map_err(|e| AppError::Http { kind: FailureKind::Malformed, detail: format!("Invalid UTF-8: {e}") })?;

            self.harvest_credentials(&body);
            // Site-wide announcement banners (`#admin-banner`) carry a
            // `div.userstuff` body that content selectors mistake for page
            // content (observed: chapters "loading" as the banner text).
            // Strip here so every parser sees banner-free HTML.
            return Ok(crate::parser::strip_admin_banner(body));
        }
    }

    // -- Posting credentials (harvested from content fetches) ---------------

    /// Cheap string scans — no DOM parse — run on every fetched page so the
    /// posting credentials stay fresh as a side effect of normal browsing.
    fn harvest_credentials(&self, html: &str) {
        if let Some(token) = scan_attr_near(html, "name=\"csrf-token\"", "content=\"") {
            *self.csrf_token.lock().unwrap() = Some(token);
        }
        if let Some(pseud) = scan_attr_near(html, "name=\"comment[pseud_id]\"", "value=\"") {
            *self.pseud_id.lock().unwrap() = Some(pseud);
        }
    }

    pub fn cached_csrf_token(&self) -> Option<String> {
        self.csrf_token.lock().unwrap().clone()
    }

    pub fn cached_pseud_id(&self) -> Option<String> {
        self.pseud_id.lock().unwrap().clone()
    }

    /// Restore credentials persisted from a previous session (only fills
    /// gaps — freshly harvested values win).
    pub fn seed_credentials(&self, csrf_token: Option<String>, pseud_id: Option<String>) {
        if let Some(t) = csrf_token {
            let mut cached = self.csrf_token.lock().unwrap();
            if cached.is_none() { *cached = Some(t); }
        }
        if let Some(p) = pseud_id {
            let mut cached = self.pseud_id.lock().unwrap();
            if cached.is_none() { *cached = Some(p); }
        }
    }

    pub async fn fetch_health_check(&self) -> Result<u16, AppError> {
        self.enforce_rate_limit().await;
        let client = self.http();
        let response = client.head(BASE_URL)
            .send()
            .await
            .map_err(|e| AppError::NetworkError(format!("{e}")))?;
        Ok(response.status().as_u16())
    }

    async fn fetch(&self, url: &str) -> Result<String, AppError> {
        self.fetch_with_progress(url, self.timeout_for_url(url)).await
    }

    async fn fetch_ajax(&self, url: &str) -> Result<String, AppError> {
        self.fetch_ajax_with_progress(url, self.timeout_for_url(url)).await
    }

    /// Switch back from Tor to a direct HTTP client, preserving cookies.
    pub fn disconnect_tor(&mut self) -> Result<(), AppError> {
        use reqwest::header::{ACCEPT, ACCEPT_LANGUAGE, ACCEPT_ENCODING};
        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static(APP_USER_AGENT));
        headers.insert(ACCEPT, HeaderValue::from_static("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"));
        headers.insert(ACCEPT_LANGUAGE, HeaderValue::from_static("en-US,en;q=0.5"));
        headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("gzip, deflate, br, zstd"));
        headers.insert("Sec-GPC", HeaderValue::from_static("1"));
        headers.insert("Connection", HeaderValue::from_static("keep-alive"));
        headers.insert("Upgrade-Insecure-Requests", HeaderValue::from_static("1"));
        headers.insert("Sec-Fetch-Dest", HeaderValue::from_static("document"));
        headers.insert("Sec-Fetch-Mode", HeaderValue::from_static("navigate"));
        headers.insert("Sec-Fetch-Site", HeaderValue::from_static("none"));
        headers.insert("Priority", HeaderValue::from_static("u=0, i"));

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .cookie_provider(self.cookie_jar.clone())
            .connect_timeout(std::time::Duration::from_secs(10))
            .pool_idle_timeout(std::time::Duration::from_secs(0))
            .pool_max_idle_per_host(0)
            .tcp_nodelay(true)
            .tcp_keepalive(std::time::Duration::from_secs(15))
            .build()
            .map_err(|e| AppError::NetworkError(format!("Failed to build HTTP client: {e}")))?;

        self.transport = Transport::Direct(client);
        self.socks_port = None;
        self.stop_socks_proxy();
        // The captured circuit path belongs to the transport we just tore
        // down — never show it for a direct connection.
        circuit::clear_current_circuit_hops();
        Ok(())
    }

    /// Get session cookies as a string for persistence.
    pub fn get_session_cookies(&self) -> String {
        use reqwest::cookie::CookieStore;
        let url = BASE_URL.parse::<url::Url>().unwrap();
        self.cookie_jar.cookies(&url)
            .map(|h| h.to_str().unwrap_or("").to_string())
            .unwrap_or_default()
    }

    pub fn clear_cookies(&self) {
        use reqwest::cookie::CookieStore;
        let url = BASE_URL.parse::<url::Url>().unwrap();
        // Set each existing cookie to expire by setting empty values
        if let Some(header) = self.cookie_jar.cookies(&url) {
            let cookie_str = header.to_str().unwrap_or("");
            for part in cookie_str.split("; ") {
                if let Some(name) = part.split('=').next() {
                    if !name.is_empty() {
                        self.cookie_jar.add_cookie_str(&format!("{}=; Max-Age=0", name), &url);
                    }
                }
            }
        }
    }

    /// Expire ONLY the AO3 auth cookies (`user_credentials`,
    /// `_otwarchive_session`) — used when AO3 rejects the session. Leaves
    /// every other cookie (notably Cloudflare's cf_clearance) intact, since
    /// those are expensive to re-earn over Tor.
    pub fn clear_auth_cookies(&self) {
        let url = BASE_URL.parse::<url::Url>().unwrap();
        for name in ["user_credentials", "_otwarchive_session"] {
            self.cookie_jar.add_cookie_str(&format!("{name}=; Max-Age=0"), &url);
        }
    }

    /// Restore session cookies from a saved string.
    pub fn set_session_cookies(&self, cookies: &str) {
        let url = BASE_URL.parse::<url::Url>().unwrap();
        for cookie_str in cookies.split("; ") {
            if !cookie_str.is_empty() {
                self.cookie_jar.add_cookie_str(cookie_str, &url);
            }
        }
    }

    /// Get a new circuit by rebuilding the SOCKS proxy with an isolated TorClient.
    /// Much faster than full re-bootstrap — reuses existing consensus and guards.
    #[cfg(feature = "tor")]
    pub async fn new_circuit(&mut self) -> Result<(), AppError> {
        let tor = match &self.transport {
            Transport::Tor { _tor, .. } => Arc::clone(_tor),
            _ => return Err(AppError::TorError("Not connected via Tor".to_string())),
        };

        let isolated = tor.isolated_client();
        let isolated = Arc::new(isolated);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| AppError::NetworkError(format!("Failed to bind SOCKS listener: {e}")))?;
        let local_addr = listener
            .local_addr()
            .map_err(|e| AppError::NetworkError(format!("Failed to get local address: {e}")))?;

        let tor_for_proxy = Arc::clone(&isolated);
        let proxy_task = tokio::spawn(async move {
            run_socks_proxy(listener, tor_for_proxy).await;
        });

        let proxy_url = format!("socks5h://127.0.0.1:{}", local_addr.port());
        let (client, new_jar) = build_reqwest_client(Some(&proxy_url))?;

        // Transfer cookies from old jar to new jar
        let old_cookies = self.get_session_cookies();
        if !old_cookies.is_empty() {
            let url = BASE_URL.parse::<url::Url>().unwrap();
            for cookie_str in old_cookies.split("; ") {
                if !cookie_str.is_empty() {
                    new_jar.add_cookie_str(cookie_str, &url);
                }
            }
        }

        let timeout = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        // Stop the previous proxy's accept loop before swapping it out —
        // otherwise every rotation orphans a listener port and a task.
        self.stop_socks_proxy();
        self.transport = Transport::Tor { client, _tor: isolated };
        self.cookie_jar = new_jar;
        self.socks_port = Some(local_addr.port());
        self.socks_proxy_task = Some(proxy_task.abort_handle());
        self.timeout_secs.store(timeout, std::sync::atomic::Ordering::Relaxed);

        // The old circuit's path no longer applies; the slot refills when the
        // first stream runs on the new isolated client.
        circuit::clear_current_circuit_hops();

        Ok(())
    }

    pub fn set_timeout(&self, secs: u64) {
        self.timeout_secs.store(secs, std::sync::atomic::Ordering::Relaxed);
    }

    /// Enforce a minimum delay of [`RATE_LIMIT_DELAY`] between requests to be
    /// respectful of AO3's servers.
    async fn enforce_rate_limit(&self) {
        let mut last = self.last_request.lock().await;
        if let Some(prev) = *last {
            let elapsed = prev.elapsed();
            if elapsed < RATE_LIMIT_DELAY {
                sleep(RATE_LIMIT_DELAY - elapsed).await;
            }
        }
        *last = Some(Instant::now());
    }
}

/// Build a `reqwest::Client` with our standard headers and an optional SOCKS
/// proxy.
fn build_reqwest_client(proxy_url: Option<&str>) -> Result<(reqwest::Client, Arc<reqwest::cookie::Jar>), AppError> {
    use reqwest::header::{ACCEPT, ACCEPT_LANGUAGE, ACCEPT_ENCODING};
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(APP_USER_AGENT));
    headers.insert(ACCEPT, HeaderValue::from_static("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"));
    headers.insert(ACCEPT_LANGUAGE, HeaderValue::from_static("en-US,en;q=0.5"));
    headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("gzip, deflate, br, zstd"));
    headers.insert("Sec-GPC", HeaderValue::from_static("1"));
    headers.insert("Connection", HeaderValue::from_static("keep-alive"));
    headers.insert("Upgrade-Insecure-Requests", HeaderValue::from_static("1"));
    headers.insert("Sec-Fetch-Dest", HeaderValue::from_static("document"));
    headers.insert("Sec-Fetch-Mode", HeaderValue::from_static("navigate"));
    headers.insert("Sec-Fetch-Site", HeaderValue::from_static("none"));
    headers.insert("Priority", HeaderValue::from_static("u=0, i"));

    let jar = Arc::new(reqwest::cookie::Jar::default());
    let mut builder = reqwest::Client::builder()
        .default_headers(headers)
        .cookie_provider(jar.clone())
        .connect_timeout(Duration::from_secs(10))
        .pool_idle_timeout(Duration::from_secs(0))
        .pool_max_idle_per_host(0)
        .tcp_nodelay(true)
        .tcp_keepalive(Duration::from_secs(15));

    if let Some(url) = proxy_url {
        let proxy = reqwest::Proxy::all(url)
            .map_err(|e| AppError::NetworkError(format!("Invalid proxy URL: {e}")))?;
        builder = builder.proxy(proxy);
    }

    let client = builder
        .build()
        .map_err(|e| AppError::NetworkError(format!("Failed to build HTTP client: {e}")))?;
    Ok((client, jar))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use super::helpers::{comment_post_succeeded, scan_attr_near, urlencoded};

    #[test]
    fn test_comment_post_succeeded() {
        // AO3 echoes the comment HTML-escaped.
        let content = "This doesn't read like a \"draft\" — loved it";
        let body = r#"<blockquote class="userstuff"><p>This doesn&#39;t read like a &quot;draft&quot; — loved it</p></blockquote>"#;
        assert!(comment_post_succeeded(body, content));

        // Multi-line comments come back split into paragraphs.
        let content = "First line of praise\nSecond, much longer line with more detail";
        let body = "<p>First line of praise</p>\n<p>Second, much longer line with more detail</p>";
        assert!(comment_post_succeeded(body, content));

        // Plain comments still match verbatim.
        assert!(comment_post_succeeded("<p>lovely chapter</p>", "lovely chapter"));

        // A rejection page without the comment stays a failure.
        let body = "<div class=\"error\">Sorry, you can't post comments</div>";
        assert!(!comment_post_succeeded(body, "This doesn't appear anywhere"));
    }

    #[test]
    fn test_scan_attr_near_attribute_order() {
        // Rails may emit `content` before `name` — the scan must find the
        // value regardless of attribute order within the tag.
        let name_first = r#"<head><meta name="csrf-token" content="tok123"></head>"#;
        let content_first = r#"<head><meta content="tok123" name="csrf-token"></head>"#;
        assert_eq!(scan_attr_near(name_first, "name=\"csrf-token\"", "content=\""),
                   Some("tok123".to_string()));
        assert_eq!(scan_attr_near(content_first, "name=\"csrf-token\"", "content=\""),
                   Some("tok123".to_string()));
        // Absent attribute → None, not a panic.
        assert_eq!(scan_attr_near("<meta name=\"csrf-token\">", "name=\"csrf-token\"", "content=\""),
                   None);
    }

    #[test]
    fn test_urlencoded() {
        assert_eq!(urlencoded("Harry Potter"), "Harry+Potter");
        assert_eq!(
            urlencoded("Alternate Universe - Modern Setting"),
            "Alternate+Universe+-+Modern+Setting"
        );
    }

    #[tokio::test]
    async fn test_route_timeout_override_applies_to_author_works() {
        let mut client = AO3Client::new_direct().await.unwrap();
        let map = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
        map.lock().unwrap().insert("author_works".to_string(), 15u64);
        client.share_route_timeouts(map);
        client.timeout_secs.store(30, std::sync::atomic::Ordering::Relaxed);
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/users/someone/works?page=3"), 15);
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/users/someone/pseuds/p/works?page=1"), 15);
        // No override -> global default.
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/works/123"), 30);
    }

    #[test]
    fn test_build_reqwest_client_direct() {
        let client = build_reqwest_client(None);
        assert!(client.is_ok());
    }

    #[tokio::test]
    async fn test_rate_limiting() {
        let client = AO3Client::new_direct().await.unwrap();

        // Record first timestamp
        client.enforce_rate_limit().await;
        let start = Instant::now();

        // Second call should wait ~RATE_LIMIT_DELAY (with a little slack)
        client.enforce_rate_limit().await;
        let elapsed = start.elapsed();

        assert!(
            elapsed >= RATE_LIMIT_DELAY - Duration::from_millis(100),
            "Rate limiting should enforce ~{:?} delay, got {:?}",
            RATE_LIMIT_DELAY,
            elapsed
        );
    }

    #[test]
    fn test_search_url() {
        let encoded = urlencoded("Sherlock Holmes & Related Fandoms");
        let url = format!("{BASE_URL}/tags/{encoded}/works?page=1");
        assert!(url.starts_with("https://archiveofourown.org/tags/"));
        assert!(url.ends_with("works?page=1"));
    }

    #[test]
    fn test_work_url() {
        let url = format!("{BASE_URL}/works/12345?view_adult=true");
        assert_eq!(
            url,
            "https://archiveofourown.org/works/12345?view_adult=true"
        );
    }

    #[test]
    fn test_chapter_url() {
        let url = format!("{BASE_URL}/works/12345/chapters/67890?view_adult=true");
        assert_eq!(
            url,
            "https://archiveofourown.org/works/12345/chapters/67890?view_adult=true"
        );
    }
}
