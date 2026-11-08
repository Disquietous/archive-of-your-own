//! The private transport: how a request reaches the internet, with no
//! knowledge of which site it is for.
//!
//! Owns the connection (direct, or the app's own Tor client behind a local
//! SOCKS proxy), the privacy gate every request passes (`privacy.rs`), the
//! cookie jar, the per-host rate limit, global and per-route timeouts, and
//! the request audit log. Site-specific behaviour (AO3's session-expiry
//! redirect, credential harvesting, banner stripping) reaches in through
//! `SiteHooks`, which the site client implements. Multi-source plan Area 5.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, USER_AGENT};
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep};

use crate::error::AppError;

use super::audit::{ActiveRequestGuard, AuditCtx, redact_payload};
use super::{FailureKind, MAX_IMAGE_BYTES, MAX_PAGE_BYTES, NetworkRefusal, circuit, privacy, routes};
#[cfg(feature = "tor")]
use super::socks::{self, run_socks_proxy};

pub(super) const APP_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0";
/// Minimum spacing between requests to the same host.
pub(super) const RATE_LIMIT_DELAY: Duration = Duration::from_millis(500);

/// What a site client tells the transport about its pages. Every method has
/// a do-nothing default so a site with no such behaviour declares nothing.
pub trait SiteHooks: Sync {
    /// Source id stamped on every request-log row ("ao3").
    fn source(&self) -> &'static str;
    /// A GET that landed somewhere meaning "your session is gone".
    fn session_expired(&self, _request_url: &str, _final_url: &str) -> bool { false }
    /// Runs on every fetched page body before it is returned: harvest
    /// tokens, strip site chrome the parsers would trip over.
    fn on_page(&self, body: String) -> String { body }
    /// The User-Agent this site's requests must carry instead of the
    /// shared one — a clearance earned in a web view is bound to the web
    /// view's (`client::clearance`).
    fn user_agent(&self) -> Option<String> { None }
}

/// A challenged (403) response under a tracked operation: leave the note
/// the recovery engine needs to earn clearance for this site and page.
fn note_challenge(code: u16, hooks: &dyn SiteHooks, url: &str) {
    if code == 403 {
        if let Some(id) = crate::events::current_op() {
            super::clearance::note_challenge(id, hooks.source(), url);
        }
    }
}

/// The connection behind the transport.
enum Kind {
    Direct(reqwest::Client),
    #[cfg(feature = "tor")]
    Tor {
        client: reqwest::Client,
        // Keep the TorClient alive so the background tasks continue running.
        // The SOCKS proxy task also holds a clone.
        _tor: Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>,
    },
}

/// A completed form POST, with what a login flow needs to judge it.
pub struct PostOutcome {
    pub status: u16,
    pub final_url: String,
    pub set_cookies: Vec<String>,
    pub body: String,
}

pub struct Transport {
    kind: Kind,
    cookie_jar: Arc<reqwest::cookie::Jar>,
    /// Last send per host, for the rate limit.
    last_request: Arc<Mutex<HashMap<String, Instant>>>,
    timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    /// Per-route timeout overrides (route key → seconds), consulted by URL
    /// classification on every GET; routes without an entry use
    /// `timeout_secs`. Shared with the owning app so edits apply to the
    /// live transport and survive replacement on (re)connect.
    route_timeouts: Arc<std::sync::Mutex<HashMap<String, u64>>>,
    socks_port: Option<u16>,
    /// Accept-loop task of the local SOCKS proxy. Aborted on circuit
    /// rotation/disconnect so each rotation doesn't orphan a listener port
    /// and a background task.
    socks_proxy_task: Option<tokio::task::AbortHandle>,
}

impl Transport {
    // -- Constructors -------------------------------------------------------

    /// A direct connection. Sends only when the privacy policy allows it
    /// (VPN verified, or Open).
    pub async fn new_direct() -> Result<Self, AppError> {
        let (client, jar) = build_reqwest_client(None)?;
        Ok(Self::assemble(Kind::Direct(client), jar, None, None))
    }

    /// The app's own Tor client, bootstrapped under `state_dir` (a writable
    /// directory inside the sandbox; consensus is cached there so later
    /// launches are faster). Bootstrap has a 90-second timeout; a first
    /// launch downloads ~3 MB and typically takes 15–40 seconds.
    #[cfg(feature = "tor")]
    pub async fn new_tor_with_dir(state_dir: &str) -> Result<Self, AppError> {
        use arti_client::TorClient;
        use arti_client::config::TorClientConfigBuilder;

        let tor_dir = super::tor_state_dir(state_dir);
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
            Duration::from_secs(90),
            TorClient::create_bootstrapped(config),
        )
        .await
        .map_err(|_| AppError::TorError(
            "Tor bootstrap timed out after 90 seconds. Check your network connection.".to_string()
        ))?
        .map_err(|e| AppError::TorError(format!("Tor bootstrap failed: {}", socks::error_chain(&e))))?;

        let (client, jar, port, task) = Self::proxy_for(Arc::clone(&tor)).await?;

        // A fresh bootstrap means any previously captured path is stale.
        circuit::clear_current_circuit_hops();
        circuit::clear_current_stream();

        Ok(Self::assemble(Kind::Tor { client, _tor: tor }, jar, Some(port), Some(task)))
    }

    fn assemble(kind: Kind, jar: Arc<reqwest::cookie::Jar>, socks_port: Option<u16>,
                socks_proxy_task: Option<tokio::task::AbortHandle>) -> Self {
        Self {
            kind,
            cookie_jar: jar,
            last_request: Arc::new(Mutex::new(HashMap::new())),
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            route_timeouts: Arc::new(std::sync::Mutex::new(HashMap::new())),
            socks_port,
            socks_proxy_task,
        }
    }

    /// Bind a local SOCKS5 proxy in front of a Tor client and build a
    /// reqwest client that uses it. Every inbound connection gets a minimal
    /// SOCKS5 handshake, a Tor stream to the target, and bidirectional copy.
    #[cfg(feature = "tor")]
    async fn proxy_for(
        tor: Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>,
    ) -> Result<(reqwest::Client, Arc<reqwest::cookie::Jar>, u16, tokio::task::AbortHandle), AppError> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| AppError::NetworkError(format!("Failed to bind SOCKS listener: {e}")))?;
        let local_addr = listener
            .local_addr()
            .map_err(|e| AppError::NetworkError(format!("Failed to get local address: {e}")))?;
        let proxy_task = tokio::spawn(async move {
            run_socks_proxy(listener, tor).await;
        });
        let proxy_url = format!("socks5h://127.0.0.1:{}", local_addr.port());
        let (client, jar) = build_reqwest_client(Some(&proxy_url))?;
        Ok((client, jar, local_addr.port(), proxy_task.abort_handle()))
    }

    // -- Connection state ---------------------------------------------------

    /// The reqwest client of the active connection — the single choke
    /// point every request passes, and so where the privacy policy is
    /// enforced.
    fn http(&self) -> Result<&reqwest::Client, AppError> {
        if let Err(reason) = privacy::gate(self.is_tor()) {
            match &reason {
                NetworkRefusal::TorNotConnected => {
                    log_info!("network", "Refused request: Tor is required and not connected");
                }
                NetworkRefusal::VpnNotVerified { status } => {
                    log_info!("network", "Refused request: VPN not verified ({status:?})");
                }
                NetworkRefusal::MockUnserved => {}
            }
            crate::events::emit(crate::events::CoreEvent::NetworkRefused {
                id: crate::events::current_op(),
                reason,
            });
            return Err(AppError::NetworkDisabled);
        }
        Ok(match &self.kind {
            Kind::Direct(c) => c,
            #[cfg(feature = "tor")]
            Kind::Tor { client, .. } => client,
        })
    }

    pub fn is_tor(&self) -> bool {
        #[cfg(feature = "tor")]
        { matches!(self.kind, Kind::Tor { .. }) }
        #[cfg(not(feature = "tor"))]
        { false }
    }

    #[cfg(feature = "tor")]
    pub fn tor_client(&self) -> Option<&Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>> {
        match &self.kind {
            Kind::Tor { _tor, .. } => Some(_tor),
            _ => None,
        }
    }

    /// The local SOCKS5 proxy port while Tor is the connection.
    pub fn socks_port(&self) -> Option<u16> {
        self.socks_port
    }

    /// Abort the SOCKS accept loop, if any. Must run before the transport
    /// is replaced or dropped — an `AbortHandle` dropped without `.abort()`
    /// leaves the listener port and accept loop running.
    pub fn stop_socks_proxy(&mut self) {
        if let Some(old) = self.socks_proxy_task.take() {
            old.abort();
        }
    }

    /// Switch from Tor to a direct connection, keeping the cookies.
    pub fn go_direct(&mut self) -> Result<(), AppError> {
        let client = client_builder(None)?
            .cookie_provider(self.cookie_jar.clone())
            .build()
            .map_err(|e| AppError::NetworkError(format!("Failed to build HTTP client: {e}")))?;
        self.kind = Kind::Direct(client);
        self.socks_port = None;
        self.stop_socks_proxy();
        // The captured circuit path belongs to the connection just torn
        // down — never show it for a direct one.
        circuit::clear_current_circuit_hops();
        circuit::clear_current_stream();
        Ok(())
    }

    /// A new circuit: rebuild the SOCKS proxy on an isolated Tor client.
    /// Much faster than a full re-bootstrap — reuses consensus and guards.
    #[cfg(feature = "tor")]
    pub async fn new_circuit(&mut self) -> Result<(), AppError> {
        let tor = match &self.kind {
            Kind::Tor { _tor, .. } => Arc::clone(_tor),
            _ => return Err(AppError::TorError("Not connected via Tor".to_string())),
        };
        let isolated = tor.isolated_client();
        let (client, new_jar, port, task) = Self::proxy_for(Arc::clone(&isolated)).await?;

        // Carry every cookie across to the new jar.
        copy_jar(&self.cookie_jar, &new_jar);

        // Stop the previous proxy's accept loop before swapping it out —
        // otherwise every rotation orphans a listener port and a task.
        self.stop_socks_proxy();
        self.kind = Kind::Tor { client, _tor: isolated };
        self.cookie_jar = new_jar;
        self.socks_port = Some(port);
        self.socks_proxy_task = Some(task);

        // The old circuit's path no longer applies; the slot refills when the
        // first stream runs on the new isolated client.
        circuit::clear_current_circuit_hops();
        circuit::clear_current_stream();
        Ok(())
    }

    // -- Timeouts and rate limit --------------------------------------------

    pub fn set_timeout(&self, secs: u64) {
        self.timeout_secs.store(secs, std::sync::atomic::Ordering::Relaxed);
    }

    /// The configured per-request timeout.
    pub fn request_timeout(&self) -> Duration {
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

    /// Adopt the app-owned override map (replacing this transport's own) so
    /// a freshly built transport sees existing overrides and later edits
    /// without re-plumbing. Call at every creation site.
    pub fn share_route_timeouts(&mut self, map: Arc<std::sync::Mutex<HashMap<String, u64>>>) {
        self.route_timeouts = map;
    }

    /// Hold back until [`RATE_LIMIT_DELAY`] has passed since the last send
    /// to this URL's host.
    pub async fn enforce_rate_limit(&self, url: &str) {
        let host = host_of(url);
        let mut last = self.last_request.lock().await;
        if let Some(prev) = last.get(&host) {
            let elapsed = prev.elapsed();
            if elapsed < RATE_LIMIT_DELAY {
                sleep(RATE_LIMIT_DELAY - elapsed).await;
            }
        }
        last.insert(host, Instant::now());
    }

    // -- Cookies ------------------------------------------------------------

    /// The jar's cookies for a site, as a `name=value; ...` header string.
    pub fn cookies_for(&self, base_url: &str) -> String {
        use reqwest::cookie::CookieStore;
        let Ok(url) = base_url.parse::<url::Url>() else { return String::new() };
        self.cookie_jar.cookies(&url)
            .map(|h| h.to_str().unwrap_or("").to_string())
            .unwrap_or_default()
    }

    /// Add cookies for a site from a `name=value; ...` string.
    pub fn set_cookies(&self, base_url: &str, cookies: &str) {
        let Ok(url) = base_url.parse::<url::Url>() else { return };
        for cookie_str in cookies.split("; ") {
            if !cookie_str.is_empty() {
                self.cookie_jar.add_cookie_str(cookie_str, &url);
            }
        }
    }

    /// Expire the site's cookies whose names match.
    pub fn expire_cookies(&self, base_url: &str, matches: impl Fn(&str) -> bool) {
        use reqwest::cookie::CookieStore;
        let Ok(url) = base_url.parse::<url::Url>() else { return };
        let Some(header) = self.cookie_jar.cookies(&url) else { return };
        for part in header.to_str().unwrap_or("").split("; ") {
            let name = part.split('=').next().unwrap_or("");
            if !name.is_empty() && matches(name) {
                self.cookie_jar.add_cookie_str(&format!("{name}=; Max-Age=0"), &url);
            }
        }
    }

    /// Expire the named cookies for a site whether or not the jar lists them.
    pub fn expire_named_cookies(&self, base_url: &str, names: &[&str]) {
        let Ok(url) = base_url.parse::<url::Url>() else { return };
        for name in names {
            self.cookie_jar.add_cookie_str(&format!("{name}=; Max-Age=0"), &url);
        }
    }

    // -- Requests -----------------------------------------------------------

    /// GET a page: rate limit, gate, two-phase timeouts (headers, then each
    /// body chunk), one no-cache retry on 429/503, 429 retry-after
    /// classification, size cap, progress reporting against the ambient
    /// operation, and an audit row. `hooks` adds the site's own rules.
    pub async fn get_page(&self, url: &str, timeout_secs: u64, ajax: bool,
                          hooks: &dyn SiteHooks) -> Result<String, AppError> {
        let method = if ajax { "GET (ajax)" } else { "GET" };
        let _active = ActiveRequestGuard::new(method, url, timeout_secs);
        let header_timeout = Duration::from_secs(timeout_secs);
        let body_timeout = Duration::from_secs(timeout_secs);
        let fetch_start = std::time::Instant::now();
        let audit = AuditCtx::new(hooks.source(), method, url, None);
        log_debug!("http", " {} header_timeout={}s body_timeout={}s", url, header_timeout.as_secs(), body_timeout.as_secs());
        // Set after a first 429 or 503: the retry goes out with
        // shift+refresh (no-cache) headers to punch through a cached
        // error response at the edge.
        let mut hard_reload = false;
        // Reports against the ambient operation set by `with_recovery`
        // (`events::scoped`) — a no-op outside that scope, e.g. in tests.
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
            self.enforce_rate_limit(url).await;
            progress!(crate::events::OpPhase::Connecting, 0, None);

            let client = self.http()?;

            // Phase 1: Connect + TLS + headers (short timeout — dead connections fail fast)
            let send_start = std::time::Instant::now();
            let mut req = client.get(url);
            if let Some(ua) = hooks.user_agent() {
                req = req.header(USER_AGENT, ua);
            }
            if ajax {
                req = req.header("X-Requested-With", "XMLHttpRequest")
                    .header("Accept", "text/html, */*; q=0.01");
            }
            if hard_reload {
                // Browser shift+refresh headers: force every cache between
                // us and the origin to revalidate instead of replaying a
                // stored response.
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

            let final_url = response.url().to_string();
            if hooks.session_expired(url, &final_url) {
                progress!(crate::events::OpPhase::Failed, 0, None);
                audit.record(response.status().as_u16(), 0, Some("session_expired".to_string()));
                return Err(AppError::SessionExpired);
            }

            let status = response.status();
            let code = status.as_u16();

            // 429/503: first, retry ONCE with hard-reload headers: edge
            // caches can serve a stored 429/503 for the URL, in which case
            // every client gets it regardless of exit IP (new circuits
            // don't help) while a browser shift+refresh punches through to
            // origin and gets a 200. Only when the no-cache retry also
            // fails is the error real — then fail fast so upper layers can
            // back off (503) or rotate / surface an honest countdown (429).
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
            // 502/503/504) lives entirely in the recovery engine — beyond
            // the one-shot no-cache retry above, this path returns the
            // classified failure on the first non-success status.
            if !status.is_success() {
                progress!(crate::events::OpPhase::Failed, 0, None);
                let detail = format!("HTTP {status} for {url}");
                audit.record(code, 0, Some(detail.clone()));
                note_challenge(code, hooks, url);
                return Err(AppError::Http { kind: FailureKind::from_status(code, None), detail });
            }

            // Phase 2: Read body in chunks with idle timeout per chunk
            let total_bytes = response.content_length();
            progress!(crate::events::OpPhase::Downloading, 0, total_bytes);
            if total_bytes.is_some_and(|n| n > MAX_PAGE_BYTES) {
                progress!(crate::events::OpPhase::Failed, 0, total_bytes);
                let detail = format!("response too large: {} bytes declared (cap {MAX_PAGE_BYTES})", total_bytes.unwrap_or(0));
                audit.record(code, 0, Some(detail.clone()));
                return Err(AppError::Http { kind: FailureKind::Malformed, detail });
            }

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
                        if bytes_received > MAX_PAGE_BYTES {
                            progress!(crate::events::OpPhase::Failed, bytes_received, total_bytes);
                            let detail = format!("response too large: over {MAX_PAGE_BYTES} bytes");
                            audit.record(code, bytes_received, Some(detail.clone()));
                            return Err(AppError::Http { kind: FailureKind::Malformed, detail });
                        }
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
            return Ok(hooks.on_page(body));
        }
    }

    /// POST a form and return everything a caller might judge it by. One
    /// deadline covers the whole round trip, so a timeout here cannot prove
    /// whether the origin saw the request and is treated as connect-class.
    /// `ok` decides whether the audit row counts the response as a success
    /// (a site may accept a 422 that means "already done").
    pub async fn post_form(&self, url: &str, form: &[(String, String)], headers: &[(&str, &str)],
                           ok: &(dyn Fn(u16, &str) -> bool + Sync), hooks: &dyn SiteHooks) -> Result<PostOutcome, AppError> {
        self.enforce_rate_limit(url).await;
        let client = self.http()?;
        let timeout = self.request_timeout();
        let _active = ActiveRequestGuard::new("POST", url, timeout.as_secs());
        let audit = AuditCtx::new(hooks.source(), "POST", url, Some(redact_payload(
            &form.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect::<Vec<_>>())));

        let result = tokio::time::timeout(timeout, async {
            let mut req = client.post(url).form(form);
            if let Some(ua) = hooks.user_agent() {
                req = req.header(USER_AGENT, ua);
            }
            for (name, value) in headers {
                req = req.header(*name, *value);
            }
            let resp = req
                .send()
                .await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            let status = resp.status().as_u16();
            let set_cookies = resp.headers().get_all("set-cookie")
                .iter()
                .filter_map(|v| v.to_str().ok().map(str::to_string))
                .collect();
            let final_url = resp.url().to_string();
            let body = resp.text().await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            Ok::<PostOutcome, AppError>(PostOutcome { status, final_url, set_cookies, body })
        }).await;

        match result {
            Err(_) => {
                audit.record(0, 0, Some("timeout".to_string()));
                Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() })
            }
            Ok(Err(e)) => { audit.record(0, 0, Some(format!("{e}"))); Err(e) }
            Ok(Ok(out)) => {
                let error = if ok(out.status, &out.body) { None } else { Some(format!("HTTP {} for {url}", out.status)) };
                audit.record(out.status, out.body.len() as u64, error);
                note_challenge(out.status, hooks, url);
                Ok(out)
            }
        }
    }

    /// GET raw bytes (images) with image-appropriate headers and the image
    /// size cap. Logs the content headers so decode failures are diagnosable.
    pub async fn get_bytes(&self, url: &str, hooks: &dyn SiteHooks) -> Result<Vec<u8>, AppError> {
        let _active = ActiveRequestGuard::new("GET (image)", url, self.request_timeout().as_secs());
        let audit = AuditCtx::new(hooks.source(), "GET (image)", url, None);
        self.enforce_rate_limit(url).await;
        let client = self.http()?;
        let timeout = self.request_timeout();

        log_info!("image", "Fetching {}", url);
        // Image-appropriate headers (override the client's document-navigation
        // defaults): a CDN seeing Accept: text/html on an image URL may serve
        // its HTML viewer/block page instead of the bytes.
        let request = client.get(url)
            .header("Accept", "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5")
            .header("Sec-Fetch-Dest", "image")
            .header("Sec-Fetch-Mode", "no-cors")
            .header("Sec-Fetch-Site", "cross-site");
        let response = match tokio::time::timeout(timeout, request.send()).await {
            Err(_) => {
                log_error!("image", "Timeout connecting to {}", url);
                audit.record(0, 0, Some("timeout".to_string()));
                return Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() });
            }
            Ok(Err(e)) => {
                log_error!("image", "Error fetching {}: {}", url, e);
                audit.record(0, 0, Some(format!("{e}")));
                return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") });
            }
            Ok(Ok(r)) => r,
        };

        let status = response.status();
        let content_type = response.headers().get("content-type")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        let content_encoding = response.headers().get("content-encoding")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        let content_length = response.headers().get("content-length")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        log_info!("image", "HTTP {} type={} encoding={} length={} for {}",
                  status.as_u16(), content_type, content_encoding, content_length, url);

        if !status.is_success() {
            let detail = format!("HTTP {status}");
            audit.record(status.as_u16(), 0, Some(detail.clone()));
            return Err(AppError::Http { kind: FailureKind::from_status(status.as_u16(), None), detail });
        }
        if response.content_length().is_some_and(|n| n > MAX_IMAGE_BYTES) {
            let detail = format!("image too large: {} bytes declared (cap {})", response.content_length().unwrap_or(0), MAX_IMAGE_BYTES);
            audit.record(status.as_u16(), 0, Some(detail.clone()));
            return Err(AppError::Http { kind: FailureKind::Malformed, detail });
        }

        let bytes = match tokio::time::timeout(timeout, response.bytes()).await {
            Err(_) => {
                log_error!("image", "Timeout reading body of {}", url);
                audit.record(status.as_u16(), 0, Some("body timeout".to_string()));
                // Headers already arrived — the request reached the origin.
                return Err(AppError::Http { kind: FailureKind::ResponseTimeout, detail: "timeout".to_string() });
            }
            Ok(Err(e)) => {
                log_error!("image", "Failed reading body of {}: {}", url, e);
                let detail = format!("{e}");
                audit.record(status.as_u16(), 0, Some(detail.clone()));
                return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail });
            }
            Ok(Ok(b)) => b,
        };
        if bytes.len() as u64 > MAX_IMAGE_BYTES {
            let detail = format!("image too large: {} bytes (cap {})", bytes.len(), MAX_IMAGE_BYTES);
            audit.record(status.as_u16(), bytes.len() as u64, Some(detail.clone()));
            return Err(AppError::Http { kind: FailureKind::Malformed, detail });
        }

        let kind = super::sniff_image_kind(&bytes);
        log_info!("image", "Downloaded {} bytes ({}) from {}", bytes.len(), kind, url);
        if kind == "not-an-image" {
            // The body isn't any known image format — log what the host
            // actually sent so decode failures are diagnosable.
            let snippet: String = String::from_utf8_lossy(&bytes[..bytes.len().min(300)])
                .chars().filter(|c| !c.is_control()).collect();
            log_error!("image", "Body of {} is not a recognized image (type={} encoding={}): {}",
                       url, content_type, content_encoding, snippet);
        }
        audit.record(status.as_u16(), bytes.len() as u64, None);
        Ok(bytes.to_vec())
    }

    /// HEAD a site's base URL and return the status: the cheapest "is this
    /// connection alive" probe.
    pub async fn head_status(&self, url: &str) -> Result<u16, AppError> {
        self.enforce_rate_limit(url).await;
        let client = self.http()?;
        let response = client.head(url)
            .send()
            .await
            .map_err(|e| AppError::NetworkError(format!("{e}")))?;
        Ok(response.status().as_u16())
    }
}

/// The host part of a URL, for the per-host rate limit. Unparseable
/// URLs share one bucket.
fn host_of(url: &str) -> String {
    url.parse::<url::Url>().ok()
        .and_then(|u| u.host_str().map(str::to_lowercase))
        .unwrap_or_default()
}

/// Copy every cookie the old jar holds for the sites it has seen into the
/// new one. reqwest's jar is per-site, so each site is asked by URL.
fn copy_jar(from: &Arc<reqwest::cookie::Jar>, to: &Arc<reqwest::cookie::Jar>) {
    use reqwest::cookie::CookieStore;
    for base in super::KNOWN_SITES {
        let Ok(url) = base.parse::<url::Url>() else { continue };
        let Some(header) = from.cookies(&url) else { continue };
        for cookie_str in header.to_str().unwrap_or("").split("; ") {
            if !cookie_str.is_empty() {
                to.add_cookie_str(cookie_str, &url);
            }
        }
    }
}

/// Build a `reqwest::Client` with our standard headers and an optional SOCKS
/// proxy.
pub(super) fn build_reqwest_client(proxy_url: Option<&str>) -> Result<(reqwest::Client, Arc<reqwest::cookie::Jar>), AppError> {
    let jar = Arc::new(reqwest::cookie::Jar::default());
    let builder = client_builder(proxy_url)?.cookie_provider(jar.clone());
    let client = builder
        .build()
        .map_err(|e| AppError::NetworkError(format!("Failed to build HTTP client: {e}")))?;
    Ok((client, jar))
}

/// The browser-like client configuration every connection shares —
/// headers, timeouts, proxy — without a cookie store.
fn client_builder(proxy_url: Option<&str>) -> Result<reqwest::ClientBuilder, AppError> {
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

    let mut builder = reqwest::Client::builder()
        .default_headers(headers)
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
    Ok(builder)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_reqwest_client_direct() {
        assert!(build_reqwest_client(None).is_ok());
    }

    #[test]
    fn host_of_lowercases_and_tolerates_junk() {
        assert_eq!(host_of("https://ArchiveOfOurOwn.org/works/1"), "archiveofourown.org");
        assert_eq!(host_of("not a url"), "");
    }

    #[tokio::test]
    async fn rate_limit_is_per_host() {
        let t = Transport::new_direct().await.unwrap();
        t.enforce_rate_limit("https://a.example/x").await;
        let start = Instant::now();
        // A different host is not held back by the first.
        t.enforce_rate_limit("https://b.example/x").await;
        assert!(start.elapsed() < RATE_LIMIT_DELAY / 2);
        // The same host is.
        t.enforce_rate_limit("https://a.example/y").await;
        assert!(start.elapsed() >= RATE_LIMIT_DELAY - Duration::from_millis(100));
    }

    #[tokio::test]
    async fn cookies_are_per_site() {
        let t = Transport::new_direct().await.unwrap();
        t.set_cookies("https://a.example", "k=1; j=2");
        let mut names: Vec<&str> = Vec::new();
        let header = t.cookies_for("https://a.example");
        names.extend(header.split("; "));
        names.sort();
        assert_eq!(names, vec!["j=2", "k=1"]);
        assert_eq!(t.cookies_for("https://b.example"), "");
        t.expire_cookies("https://a.example", |n| n == "k");
        assert_eq!(t.cookies_for("https://a.example"), "j=2");
        t.expire_named_cookies("https://a.example", &["j"]);
        assert_eq!(t.cookies_for("https://a.example"), "");
    }
}
