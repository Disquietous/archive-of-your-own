use std::sync::Arc;
use std::time::Duration;

use crate::error::AppError;

mod audit;
mod auth;
mod circuit;
pub mod clearance;
mod failure;
mod helpers;
mod ops;
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

use audit::AuditCtx;
use helpers::scan_attr_near;
#[cfg(feature = "tor")]
pub use socks::{kill_socks_streams, live_socks_streams};
/// Without Tor there is no SOCKS proxy, so never any streams.
#[cfg(not(feature = "tor"))]
pub fn kill_socks_streams() {}
#[cfg(not(feature = "tor"))]
pub fn live_socks_streams() -> usize { 0 }

pub const BASE_URL: &str = "https://archiveofourown.org";

/// Base URLs of every site the transport may hold cookies for; the jar is
/// per-site, so carrying cookies across a circuit rotation asks per site.
pub(crate) const KNOWN_SITES: &[&str] = &[BASE_URL];

/// Largest page body the client will buffer. The biggest real AO3 pages
/// (a long work with view_full_work) run a few MB; past this the body is
/// not a page the parsers could use, and buffering it unbounded is the
/// only way a hostile or broken response could exhaust memory.
pub const MAX_PAGE_BYTES: u64 = 24 * 1024 * 1024;
/// Largest image body the client will buffer.
pub const MAX_IMAGE_BYTES: u64 = 8 * 1024 * 1024;

/// Cookies that prove an AO3 login: `remember_user_token` (what AO3 sets
/// now) and the older `user_credentials`. `_otwarchive_session` is issued to
/// anonymous visitors too, so it never proves a login on its own.
const LOGIN_COOKIE_NAMES: [&str; 2] = ["remember_user_token", "user_credentials"];

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
fn is_cloudflare_cookie(name: &str) -> bool {
    name.starts_with("cf_") || name.starts_with("__cf") || name == "_cfuvid"
}

/// A jar string without its Cloudflare cookies.
pub fn strip_cloudflare_cookies(cookies: &str) -> String {
    cookies.split("; ")
        .filter(|c| !c.is_empty() && !is_cloudflare_cookie(c.split('=').next().unwrap_or("")))
        .collect::<Vec<_>>()
        .join("; ")
}

/// Whether a cookie string (a jar's `name=value; ...` header, or a single
/// Set-Cookie value) carries an AO3 login. The one test of logged-in state.
pub fn is_ao3_login_cookie(name: &str) -> bool {
    LOGIN_COOKIE_NAMES.contains(&name)
}

pub fn has_login_cookie(cookies: &str) -> bool {
    cookies.split(';').any(|part| {
        let (name, value) = part.trim().split_once('=').unwrap_or((part.trim(), ""));
        LOGIN_COOKIE_NAMES.contains(&name) && !value.is_empty()
    })
}

// ---------------------------------------------------------------------------
// AO3Client
// ---------------------------------------------------------------------------

/// The AO3 site client: AO3's pages, forms and rules, on top of the private
/// transport (`transport.rs`), which owns the connection, the privacy gate,
/// cookies, rate limit and timeouts. The mock archive answers here, above
/// the transport, so a request the mock serves never reaches it.
pub struct AO3Client {
    transport: Transport,
    /// Posting credentials harvested opportunistically from pages fetched
    /// for content — so kudos/comments POST directly, with no preparatory
    /// GET. The CSRF token is session-scoped (any page's token validates
    /// until the login session changes); the pseud id is per-account.
    csrf_token: Arc<std::sync::Mutex<Option<String>>>,
    pseud_id: Arc<std::sync::Mutex<Option<String>>>,
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

impl SiteHooks for AO3Client {
    fn source(&self) -> &'static str {
        crate::models::SOURCE_AO3
    }

    fn user_agent(&self) -> Option<String> {
        clearance::user_agent(crate::models::SOURCE_AO3)
    }

    /// AO3 answers a request made with a dead session by redirecting to
    /// the login page.
    fn session_expired(&self, request_url: &str, final_url: &str) -> bool {
        final_url.contains("/users/login") && !request_url.contains("/users/login")
    }

    fn on_page(&self, body: String) -> String {
        self.harvest_credentials(&body);
        // Site-wide announcement banners (`#admin-banner`) carry a
        // `div.userstuff` body that content selectors mistake for page
        // content (observed: chapters "loading" as the banner text).
        // Strip here so every parser sees banner-free HTML.
        crate::parser::strip_admin_banner(body)
    }
}

impl AO3Client {
    // -- Constructors -------------------------------------------------------

    /// A client on a direct connection (sends only when the privacy policy
    /// allows: VPN verified, or Open).
    pub async fn new_direct() -> Result<Self, AppError> {
        Ok(Self::with_transport(Transport::new_direct().await?))
    }

    /// A client on the app's own Tor connection (see `Transport::new_tor_with_dir`).
    #[cfg(feature = "tor")]
    pub async fn new_tor_with_dir(state_dir: &str) -> Result<Self, AppError> {
        Ok(Self::with_transport(Transport::new_tor_with_dir(state_dir).await?))
    }

    pub fn with_transport(transport: Transport) -> Self {
        Self {
            transport,
            csrf_token: Arc::new(std::sync::Mutex::new(None)),
            pseud_id: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    // -- Transport (delegated) ----------------------------------------------

    pub fn transport(&self) -> &Transport {
        &self.transport
    }

    pub fn transport_mut(&mut self) -> &mut Transport {
        &mut self.transport
    }

    pub fn is_tor(&self) -> bool {
        self.transport.is_tor()
    }

    #[cfg(feature = "tor")]
    pub fn tor_client(&self) -> Option<&Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>> {
        self.transport.tor_client()
    }

    /// The local SOCKS5 proxy port while Tor is the connection.
    pub fn socks_port(&self) -> Option<u16> {
        self.transport.socks_port()
    }

    /// See `Transport::stop_socks_proxy`.
    pub fn stop_socks_proxy(&mut self) {
        self.transport.stop_socks_proxy();
    }

    /// Switch from Tor to a direct connection, keeping cookies.
    pub fn disconnect_tor(&mut self) -> Result<(), AppError> {
        self.transport.go_direct()
    }

    /// A new circuit on an isolated Tor client (see `Transport::new_circuit`).
    #[cfg(feature = "tor")]
    pub async fn new_circuit(&mut self) -> Result<(), AppError> {
        self.transport.new_circuit().await
    }

    pub fn set_timeout(&self, secs: u64) {
        self.transport.set_timeout(secs);
    }

    pub fn timeout_for_url(&self, url: &str) -> u64 {
        self.transport.timeout_for_url(url)
    }

    pub(super) fn request_timeout(&self) -> Duration {
        self.transport.request_timeout()
    }

    pub fn share_route_timeouts(&mut self, map: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>) {
        self.transport.share_route_timeouts(map);
    }

    // -- Fetching -----------------------------------------------------------

    pub async fn fetch_ajax_with_progress(&self, url: &str, timeout_secs: u64) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, true).await
    }

    pub async fn fetch_with_progress(&self, url: &str, timeout_secs: u64) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, false).await
    }

    async fn fetch_with_progress_inner(&self, url: &str, timeout_secs: u64, ajax: bool) -> Result<String, AppError> {
        if crate::mock_site::enabled() {
            let method = if ajax { "GET (ajax)" } else { "GET" };
            let _active = ActiveRequestGuard::new(method, url, timeout_secs);
            let audit = AuditCtx::new(self.source(), method, url, None);
            let progress = |phase, bytes, total| {
                if let Some(id) = crate::events::current_op() {
                    crate::events::emit(crate::events::CoreEvent::OperationProgress { id, phase, bytes, total });
                }
            };
            progress(crate::events::OpPhase::Connecting, 0, None);
            let reply = crate::mock_site::respond_get(url, ajax, &self.get_session_cookies());
            let len = reply.body.len() as u64;
            if reply.status >= 400 {
                progress(crate::events::OpPhase::Failed, 0, None);
                let detail = format!("HTTP {} for {url} (mock)", reply.status);
                audit.record(reply.status, len, Some(detail.clone()));
                return Err(AppError::Http { kind: FailureKind::from_status(reply.status, None), detail });
            }
            progress(crate::events::OpPhase::Complete, len, Some(len));
            audit.record(reply.status, len, None);
            return Ok(self.on_page(reply.body));
        }
        self.transport.get_page(url, timeout_secs, ajax, self).await
    }

    async fn fetch(&self, url: &str) -> Result<String, AppError> {
        self.fetch_with_progress(url, self.timeout_for_url(url)).await
    }

    async fn fetch_ajax(&self, url: &str) -> Result<String, AppError> {
        self.fetch_ajax_with_progress(url, self.timeout_for_url(url)).await
    }

    pub async fn fetch_health_check(&self) -> Result<u16, AppError> {
        if crate::mock_site::enabled() {
            return Ok(200);
        }
        self.transport.head_status(BASE_URL).await
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

    // -- Cookies (AO3's jar) -------------------------------------------------

    /// AO3's cookies as a string for persistence.
    pub fn get_session_cookies(&self) -> String {
        self.transport.cookies_for(BASE_URL)
    }

    /// Restore AO3 cookies from a saved string.
    pub fn set_session_cookies(&self, cookies: &str) {
        self.transport.set_cookies(BASE_URL, cookies);
    }

    pub fn clear_cookies(&self) {
        self.transport.expire_cookies(BASE_URL, |_| true);
    }

    /// Expire the Cloudflare cookies, keeping everything else.
    pub fn clear_cloudflare_cookies(&self) {
        self.transport.expire_cookies(BASE_URL, is_cloudflare_cookie);
    }

    /// Expire ONLY the AO3 auth cookies (the login cookies plus
    /// `_otwarchive_session`) — used when AO3 rejects the session. Leaves
    /// every other cookie (notably Cloudflare's cf_clearance) intact, since
    /// those are expensive to re-earn over Tor.
    pub fn clear_auth_cookies(&self) {
        let names: Vec<&str> = LOGIN_COOKIE_NAMES.iter().copied().chain(["_otwarchive_session"]).collect();
        self.transport.expire_named_cookies(BASE_URL, &names);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use super::helpers::{comment_post_succeeded, scan_attr_near, urlencoded};

    #[test]
    fn test_strip_cloudflare_cookies() {
        assert_eq!(
            strip_cloudflare_cookies("_otwarchive_session=a; cf_clearance=b; remember_user_token=c; __cf_bm=d; _cfuvid=e"),
            "_otwarchive_session=a; remember_user_token=c");
        assert_eq!(strip_cloudflare_cookies(""), "");
    }

    #[test]
    fn test_has_login_cookie() {
        assert!(has_login_cookie("_otwarchive_session=abc; remember_user_token=xyz"));
        assert!(has_login_cookie("user_credentials=1; cf_clearance=q"));
        assert!(has_login_cookie("remember_user_token=xyz; path=/; secure; HttpOnly"));
        assert!(!has_login_cookie("_otwarchive_session=abc; cf_clearance=q"));
        assert!(!has_login_cookie("remember_user_token=; Max-Age=0"));
        assert!(!has_login_cookie("x_remember_user_token=xyz"));
        assert!(!has_login_cookie(""));
    }

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
        client.set_timeout(30);
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/users/someone/works?page=3"), 15);
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/users/someone/pseuds/p/works?page=1"), 15);
        // No override -> global default.
        assert_eq!(client.timeout_for_url("https://archiveofourown.org/works/123"), 30);
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
