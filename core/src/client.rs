use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, USER_AGENT};
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep};

use crate::error::AppError;
use crate::models::*;
use crate::parser;

pub const BASE_URL: &str = "https://archiveofourown.org";

const APP_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0";
const RATE_LIMIT_DELAY: Duration = Duration::from_millis(500);

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

/// Find `marker` in `html`, then extract the quoted value of `attr_prefix`
/// (e.g. `value="`) within the same tag. Attribute order-independent, no DOM.
fn scan_attr_near(html: &str, marker: &str, attr_prefix: &str) -> Option<String> {
    let idx = html.find(marker)?;
    let tag_start = html[..idx].rfind('<')?;
    let tag_end = idx + html[idx..].find('>')?;
    let tag = &html[tag_start..tag_end];
    let value_start = tag.find(attr_prefix)? + attr_prefix.len();
    let rest = &tag[value_start..];
    let value_end = rest.find('"')?;
    let value = &rest[..value_end];
    if value.is_empty() { None } else { Some(value.to_string()) }
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

/// Progress state for a fetch operation.
#[derive(Debug, Clone)]
pub struct FetchProgress {
    pub bytes_received: u64,
    pub total_bytes: Option<u64>,
    pub status: FetchStatus,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FetchStatus {
    Idle,
    Connecting,
    Downloading,
    Complete,
    Failed,
}

pub type ProgressHandle = Arc<std::sync::Mutex<FetchProgress>>;

pub fn new_progress_handle() -> ProgressHandle {
    Arc::new(std::sync::Mutex::new(FetchProgress {
        bytes_received: 0,
        total_bytes: None,
        status: FetchStatus::Idle,
    }))
}

/// HTTP client for fetching AO3 pages, with optional Tor transport.
pub struct AO3Client {
    transport: Transport,
    cookie_jar: Arc<reqwest::cookie::Jar>,
    last_request: Arc<Mutex<Option<Instant>>>,
    timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    active_progress: Arc<std::sync::Mutex<Option<ProgressHandle>>>,
    socks_port: Option<u16>,
    /// Posting credentials harvested opportunistically from pages fetched
    /// for content — so kudos/comments POST directly, with no preparatory
    /// GET. The CSRF token is session-scoped (any page's token validates
    /// until the login session changes); the pseud id is per-account.
    csrf_token: Arc<std::sync::Mutex<Option<String>>>,
    pseud_id: Arc<std::sync::Mutex<Option<String>>>,
}

impl AO3Client {
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

    // -- Constructors -------------------------------------------------------

    /// Create a client using direct HTTP (for development/testing).
    pub async fn new_direct() -> Result<Self, AppError> {
        let (client, jar) = build_reqwest_client(None)?;
        Ok(Self {
            transport: Transport::Direct(client),
            cookie_jar: jar,
            last_request: Arc::new(Mutex::new(None)),
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            active_progress: Arc::new(std::sync::Mutex::new(None)),
            socks_port: None,
            csrf_token: Arc::new(std::sync::Mutex::new(None)),
            pseud_id: Arc::new(std::sync::Mutex::new(None)),
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
        use arti_client::{TorClient, TorClientConfig};

        let tor_dir = std::path::PathBuf::from(state_dir).join("tor");
        let cache_dir = tor_dir.join("cache");
        let data_dir = tor_dir.join("data");
        for dir in [&tor_dir, &cache_dir, &data_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|e| AppError::TorError(format!("Cannot create dir {}: {e}", dir.display())))?;
        }

        // Set arti's env vars so default config resolves to our sandbox paths
        std::env::set_var("ARTI_CACHE", &cache_dir);
        std::env::set_var("ARTI_LOCAL_DATA", &data_dir);

        let config = TorClientConfig::default();

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
        tokio::spawn(async move {
            run_socks_proxy(listener, tor_for_proxy).await;
        });

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
            active_progress: Arc::new(std::sync::Mutex::new(None)),
            socks_port: Some(port),
            csrf_token: Arc::new(std::sync::Mutex::new(None)),
            pseud_id: Arc::new(std::sync::Mutex::new(None)),
        })
    }

    // -- Public API ---------------------------------------------------------

    /// Fetch the search form structure from /works/search?edit_search=true
    pub async fn fetch_search_form(&self) -> Result<SearchForm, AppError> {
        let url = format!("{BASE_URL}/works/search?edit_search=true");
        let html = self.fetch(&url).await?;
        parser::parse_search_form(&html)
    }

    /// Browse latest works (returns one page from /works).
    pub async fn browse_works(&self, page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let url = format!("{BASE_URL}/works?page={page}");
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Search works with raw query string parameters.
    pub async fn search_works_raw(&self, query_pairs: &[(String, String)], page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let mut parts: Vec<String> = vec![format!("page={page}"), "commit=Search".to_string()];
        for (key, value) in query_pairs {
            if !value.is_empty() {
                let encoded_key = key.replace('[', "%5B").replace(']', "%5D");
                parts.push(format!("{}={}", encoded_key, urlencoded(value)));
            }
        }
        let url = format!("{BASE_URL}/works/search?{}", parts.join("&"));
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Search works using AO3's search engine (/works/search).
    /// Mirrors the full search form at archiveofourown.org/works/search.
    pub async fn search_works(&self, params: &SearchParams, page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let mut parts: Vec<String> = Vec::new();
        parts.push(format!("page={page}"));
        parts.push("commit=Search".to_string());

        if !params.query.is_empty() {
            parts.push(format!("work_search%5Bquery%5D={}", urlencoded(&params.query)));
        }
        if !params.title.is_empty() {
            parts.push(format!("work_search%5Btitle%5D={}", urlencoded(&params.title)));
        }
        if !params.creators.is_empty() {
            parts.push(format!("work_search%5Bcreators%5D={}", urlencoded(&params.creators)));
        }
        if !params.fandom_names.is_empty() {
            parts.push(format!("work_search%5Bfandom_names%5D={}", urlencoded(&params.fandom_names)));
        }
        if !params.relationship_names.is_empty() {
            parts.push(format!("work_search%5Brelationship_names%5D={}", urlencoded(&params.relationship_names)));
        }
        if !params.character_names.is_empty() {
            parts.push(format!("work_search%5Bcharacter_names%5D={}", urlencoded(&params.character_names)));
        }
        if !params.freeform_names.is_empty() {
            parts.push(format!("work_search%5Bfreeform_names%5D={}", urlencoded(&params.freeform_names)));
        }
        if !params.word_count.is_empty() {
            parts.push(format!("work_search%5Bword_count%5D={}", urlencoded(&params.word_count)));
        }
        if !params.hits.is_empty() {
            parts.push(format!("work_search%5Bhits%5D={}", urlencoded(&params.hits)));
        }
        if !params.kudos_count.is_empty() {
            parts.push(format!("work_search%5Bkudos_count%5D={}", urlencoded(&params.kudos_count)));
        }
        if !params.sort_column.is_empty() {
            parts.push(format!("work_search%5Bsort_column%5D={}", urlencoded(&params.sort_column)));
        }
        if !params.sort_direction.is_empty() {
            parts.push(format!("work_search%5Bsort_direction%5D={}", urlencoded(&params.sort_direction)));
        }
        if let Some(rating_id) = params.rating_id {
            parts.push(format!("work_search%5Brating_ids%5D={rating_id}"));
        }
        for wid in &params.warning_ids {
            parts.push(format!("work_search%5Barchive_warning_ids%5D%5B%5D={wid}"));
        }
        for cid in &params.category_ids {
            parts.push(format!("work_search%5Bcategory_ids%5D%5B%5D={cid}"));
        }
        if !params.complete.is_empty() {
            parts.push(format!("work_search%5Bcomplete%5D={}", urlencoded(&params.complete)));
        }
        if !params.crossover.is_empty() {
            parts.push(format!("work_search%5Bcrossover%5D={}", urlencoded(&params.crossover)));
        }
        if params.single_chapter {
            parts.push("work_search%5Bsingle_chapter%5D=1".to_string());
        }
        if !params.language_id.is_empty() {
            parts.push(format!("work_search%5Blanguage_id%5D={}", urlencoded(&params.language_id)));
        }

        let url = format!("{BASE_URL}/works/search?{}", parts.join("&"));
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Browse works by tag (returns one page from /tags/{tag}/works).
    pub async fn search_by_tag(&self, tag: &str, page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let encoded_tag = ao3_tag_encode(tag);
        let url = format!("{BASE_URL}/tags/{encoded_tag}/works?page={page}");
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Fetch a single work's metadata and all its chapters.
    pub async fn get_work(&self, work_id: u64) -> Result<(WorkSummary, Vec<Chapter>), AppError> {
        let url = format!("{BASE_URL}/works/{work_id}?view_full_work=true&view_adult=true");
        let html = self.fetch(&url).await?;
        let (mut summary, chapters) = parser::parse_work_page(&html)?;
        summary.id = work_id;
        Ok((summary, chapters))
    }

    /// Fetch a specific chapter by its AO3 chapter ID.
    pub async fn get_chapter(
        &self,
        work_id: u64,
        chapter_id: u64,
    ) -> Result<Chapter, AppError> {
        let url = format!(
            "{BASE_URL}/works/{work_id}/chapters/{chapter_id}?view_adult=true"
        );
        let html = self.fetch(&url).await?;
        let (_summary, chapters) = parser::parse_work_page(&html)?;

        // The page for a single chapter should still parse into one chapter.
        // If the parser returns multiple (e.g. the page included surrounding
        // chapters), look for the matching ID or fall back to the first.
        chapters
            .into_iter()
            .find(|ch| ch.id == Some(chapter_id))
            .ok_or_else(|| {
                AppError::ElementNotFound(format!(
                    "Chapter {chapter_id} not found in work {work_id}"
                ))
            })
    }

    // -- Inbox operations -----------------------------------------------------

    pub async fn fetch_inbox(&self, username: &str, page: u32) -> Result<InboxPage, AppError> {
        let url = format!("{BASE_URL}/users/{username}/inbox?page={page}");
        let html = self.fetch(&url).await?;
        Ok(parser::parse_inbox(&html))
    }

    // -- Comment operations ---------------------------------------------------

    pub async fn fetch_comments_for_chapter(&self, work_id: u64, chapter_id: u64, page: u32) -> Result<CommentsPage, AppError> {
        if page <= 1 {
            let url = format!("{BASE_URL}/works/{work_id}/chapters/{chapter_id}?show_comments=true&view_adult=true");
            let html = self.fetch(&url).await?;
            Ok(parser::parse_comments(&html))
        } else {
            let url = format!("{BASE_URL}/comments/show_comments?chapter_id={chapter_id}&page={page}");
            let html = self.fetch_ajax(&url).await?;
            Ok(parser::parse_comments(&html))
        }
    }

    pub async fn fetch_comments_for_work(&self, work_id: u64, page: u32) -> Result<CommentsPage, AppError> {
        if page <= 1 {
            let url = format!("{BASE_URL}/works/{work_id}?show_comments=true&view_adult=true");
            let html = self.fetch(&url).await?;
            Ok(parser::parse_comments(&html))
        } else {
            let url = format!("{BASE_URL}/comments/show_comments?work_id={work_id}&page={page}");
            let html = self.fetch_ajax(&url).await?;
            Ok(parser::parse_comments(&html))
        }
    }

    pub async fn fetch_image(&self, url: &str) -> Result<Vec<u8>, AppError> {
        let _active = ActiveRequestGuard::new("GET (image)", url);
        self.enforce_rate_limit().await;
        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };
        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );

        // Resolve the full URL for relative paths
        let full_url = if url.starts_with('/') {
            format!("{BASE_URL}{url}")
        } else {
            url.to_string()
        };

        log_debug!("image", "Fetching {}", full_url);
        let response = tokio::time::timeout(timeout, client.get(&full_url).send())
            .await
            .map_err(|_| AppError::NetworkError("timeout".to_string()))?
            .map_err(|e| {
                log_debug!("image", "Error fetching {}: {}", full_url, e);
                AppError::NetworkError(format!("{e}"))
            })?;

        let status = response.status();
        if !status.is_success() {
            log_debug!("image", "HTTP {} for {}", status, full_url);
            return Err(AppError::NetworkError(format!("HTTP {status}")));
        }

        let bytes = tokio::time::timeout(timeout, response.bytes())
            .await
            .map_err(|_| AppError::NetworkError("timeout".to_string()))?
            .map_err(|e| AppError::NetworkError(format!("{e}")))?;
        log_debug!("image", "Downloaded {} bytes from {}", bytes.len(), full_url);
        Ok(bytes.to_vec())
    }

    pub async fn post_reply(&self, parent_comment_id: u64, comment: &str) -> Result<bool, AppError> {
        let endpoint = format!("{BASE_URL}/comments/{parent_comment_id}/comments");
        // Credential-refresh page on failure: the parent comment's thread.
        let form_page = format!("{BASE_URL}/comments/{parent_comment_id}");
        self.post_comment_direct(&endpoint, "comments", &form_page, comment).await
    }

    // -- Bookmark operations -------------------------------------------------

    /// Fetch a page of user bookmarks.
    /// Returns (bookmarks, has_more_pages).
    pub async fn fetch_user_bookmarks(
        &self,
        username: &str,
        page: u32,
    ) -> Result<(Vec<crate::models::BookmarkListing>, bool), AppError> {
        let url = format!("{BASE_URL}/users/{username}/bookmarks?page={page}");
        let html = self.fetch(&url).await?;
        let bookmarks = parser::parse_bookmark_listings(&html)?;
        let has_more = parser::has_next_page(&html);
        Ok((bookmarks, has_more))
    }

    /// Create a bookmark on AO3, mirroring the site's form exactly
    /// (bookmark.html reference): pseud_id, bookmarker_notes, tag_string,
    /// collection_names, private, rec. Posts from cached credentials with
    /// no preparatory GET; refreshes them ONCE (work-page fetch) on a miss
    /// or rejection. Returns the ao3_bookmark_id on success.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_ao3_bookmark(
        &self,
        work_id: u64,
        note: &str,
        tag_string: &str,
        collection_names: &str,
        private: bool,
        rec: bool,
    ) -> Result<Option<u64>, AppError> {
        let endpoint = format!("{BASE_URL}/works/{work_id}/bookmarks");
        let form_page = format!("{BASE_URL}/works/{work_id}?view_adult=true");
        let mut refreshed = false;
        loop {
            let (token, pseud) = (self.cached_csrf_token(), self.cached_pseud_id());
            let (Some(token), Some(pseud)) = (token, pseud) else {
                if refreshed {
                    return Err(AppError::ParseError(
                        "no posting credentials — are you signed in?".to_string()));
                }
                self.fetch(&form_page).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let params = vec![
                ("authenticity_token".to_string(), token),
                ("bookmark[pseud_id]".to_string(), pseud),
                ("bookmark[bookmarker_notes]".to_string(), note.to_string()),
                ("bookmark[tag_string]".to_string(), tag_string.to_string()),
                ("bookmark[collection_names]".to_string(), collection_names.to_string()),
                ("bookmark[private]".to_string(), if private { "1" } else { "0" }.to_string()),
                ("bookmark[rec]".to_string(), if rec { "1" } else { "0" }.to_string()),
                ("commit".to_string(), "Create".to_string()),
            ];
            let body = self.post_form_raw(&endpoint, params).await?;
            // Success redirects to the bookmark's page — the id is in the markup.
            if let Some(id) = extract_bookmark_id_from_response(&body) {
                return Ok(Some(id));
            }
            if !refreshed {
                refreshed = true;
                self.fetch(&form_page).await?;
                continue;
            }
            log_info!("bookmark", "Rejected POST to {endpoint}: {}",
                      body.chars().take(300).collect::<String>());
            return Ok(None);
        }
    }

    /// Delete a bookmark from AO3.
    /// Returns true if the delete appeared successful.
    pub async fn delete_ao3_bookmark(
        &self,
        ao3_bookmark_id: u64,
    ) -> Result<bool, AppError> {
        let url = format!("{BASE_URL}/bookmarks/{ao3_bookmark_id}");
        let params = vec![
            ("_method".to_string(), "delete".to_string()),
        ];
        let body = self.post_form(&url, &params).await?;
        // AO3 typically redirects or shows a page without the bookmark
        Ok(!body.contains("Error") && !body.contains("Sorry, you don't have permission"))
    }

    // -- Subscription operations -----------------------------------------------

    /// Fetch a page of user subscriptions.
    /// Returns (subscriptions, has_more_pages).
    pub async fn fetch_subscriptions(
        &self,
        username: &str,
        page: u32,
    ) -> Result<(Vec<crate::models::Subscription>, bool), AppError> {
        let url = format!("{BASE_URL}/users/{username}/subscriptions?page={page}");
        let html = self.fetch(&url).await?;
        let subs = parser::parse_subscriptions_page(&html)?;
        let has_more = parser::has_next_page(&html);
        Ok((subs, has_more))
    }

    /// Fetch one page of an author's works.
    /// Returns (works, has_next_page, total_pages).
    pub async fn fetch_author_works(
        &self,
        username: &str,
        page: u32,
    ) -> Result<(Vec<WorkSummary>, bool, u32), AppError> {
        let url = format!("{BASE_URL}/users/{username}/works?page={page}");
        log_info!("http"," Starting: {url}");
        let start = std::time::Instant::now();
        match self.fetch(&url).await {
            Ok(html) => {
                log_info!("http"," Success in {:?}: {} bytes from {url}", start.elapsed(), html.len());
                let works = parser::parse_work_listings(&html)?;
                let has_next = parser::has_next_page(&html);
                let total = parser::total_pages(&html);
                Ok((works, has_next, total))
            }
            Err(e) => {
                log_info!("http"," Failed in {:?}: {e} for {url}", start.elapsed());
                Err(e)
            }
        }
    }

    /// Fetch one page of a series' works as full blurbs (series pages use the
    /// same li.work.blurb markup as author pages).
    /// Returns (works, has_next_page, total_pages).
    pub async fn fetch_series_works_page(
        &self,
        series_id: u64,
        page: u32,
    ) -> Result<(Vec<WorkSummary>, bool, u32), AppError> {
        let url = format!("{BASE_URL}/series/{series_id}?page={page}");
        let html = self.fetch(&url).await?;
        let works = parser::parse_work_listings(&html)?;
        let has_next = parser::has_next_page(&html);
        let total = parser::total_pages(&html);
        Ok((works, has_next, total))
    }

    /// Fetch works in a series.
    /// Returns Vec of (work_id, title, chapter_count, word_count, date).
    pub async fn fetch_series_works(
        &self,
        series_id: u64,
    ) -> Result<Vec<(u64, String, u32, u64, String)>, AppError> {
        let url = format!("{BASE_URL}/series/{series_id}");
        let html = self.fetch(&url).await?;
        parser::parse_series_page(&html)
    }

    /// Fetch multiple URLs concurrently in batches.
    ///
    /// Processes URLs in chunks of `concurrency` size, sleeping 1 second between
    /// batches to respect AO3 rate limits. Returns results in the same order as
    /// the input URLs. Individual rate limiting is skipped within a batch.
    pub async fn fetch_concurrent(
        &self,
        urls: Vec<String>,
        concurrency: usize,
    ) -> Vec<Result<String, AppError>> {
        let concurrency = concurrency.max(1);
        let timeout_secs = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        let timeout = std::time::Duration::from_secs(timeout_secs);

        let mut all_results: Vec<Result<String, AppError>> = Vec::with_capacity(urls.len());

        for (chunk_idx, chunk) in urls.chunks(concurrency).enumerate() {
            if chunk_idx > 0 {
                // Sleep between batches to respect rate limits
                sleep(Duration::from_secs(1)).await;
            }

            let client = match &self.transport {
                Transport::Direct(c) => c.clone(),
                #[cfg(feature = "tor")]
                Transport::Tor { client, .. } => client.clone(),
            };

            let mut handles = Vec::with_capacity(chunk.len());
            for url in chunk {
                let client = client.clone();
                let url = url.clone();
                let handle = tokio::spawn(async move {
                    let mut retries = 0u32;
                    loop {
                        let result = tokio::time::timeout(timeout, async {
                            let response = client.get(&url).send().await
                                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
                            let status = response.status();
                            let body = response.text().await
                                .map_err(|e| AppError::NetworkError(format!("Failed to read body: {e}")))?;
                            Ok::<(reqwest::StatusCode, String), AppError>((status, body))
                        }).await;

                        let (status, body) = match result {
                            Err(_) => return Err(AppError::NetworkError("timeout".to_string())),
                            Ok(Err(e)) => return Err(e),
                            Ok(Ok(pair)) => pair,
                        };

                        let code = status.as_u16();
                        if (code == 525 || code == 503 || code == 429) && retries < 5 {
                            retries += 1;
                            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                            continue;
                        }
                        if !status.is_success() {
                            return Err(AppError::NetworkError(format!("HTTP {status} for {url}")));
                        }
                        return Ok(body);
                    }
                });
                handles.push(handle);
            }

            // Await all handles in this chunk
            for handle in handles {
                let result = match handle.await {
                    Ok(r) => r,
                    Err(e) => Err(AppError::NetworkError(format!("Task failed: {e}"))),
                };
                all_results.push(result);
            }
        }

        all_results
    }

    // -- Internal -----------------------------------------------------------

    /// Fetch raw HTML from a URL with idle-based timeout and progress reporting.
    /// Times out if no data arrives for `timeout_secs` seconds (not total elapsed).
    async fn fetch_with_timeout(&self, url: &str, timeout_secs: u64) -> Result<String, AppError> {
        self.fetch_with_progress(url, timeout_secs, None).await
    }

    pub async fn fetch_ajax_with_progress(&self, url: &str, timeout_secs: u64, progress: Option<ProgressHandle>) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, progress, true).await
    }

    pub async fn fetch_with_progress(&self, url: &str, timeout_secs: u64, progress: Option<ProgressHandle>) -> Result<String, AppError> {
        self.fetch_with_progress_inner(url, timeout_secs, progress, false).await
    }

    async fn fetch_with_progress_inner(&self, url: &str, timeout_secs: u64, progress: Option<ProgressHandle>, ajax: bool) -> Result<String, AppError> {
        let _active = ActiveRequestGuard::new(if ajax { "GET (ajax)" } else { "GET" }, url);
        let mut retries = 0;
        let header_timeout = std::time::Duration::from_secs(timeout_secs);
        let body_timeout = std::time::Duration::from_secs(timeout_secs);
        let fetch_start = std::time::Instant::now();
        let record_started_ms = now_ms();
        // Approximate request size: request line + a typical header block.
        let request_bytes = (url.len() + 380) as u64;
        // Log every terminal outcome of this logical request (one row per call,
        // transparent retries collapse into the final outcome).
        macro_rules! audit {
            ($status:expr, $resp:expr, $err:expr) => {
                push_request_record(RequestRecord {
                    started_at_ms: record_started_ms,
                    method: if ajax { "GET (ajax)".into() } else { "GET".into() },
                    url: url.to_string(),
                    status: $status,
                    duration_ms: fetch_start.elapsed().as_millis() as u64,
                    request_bytes,
                    response_bytes: $resp,
                    error: $err,
                    payload: None,
                });
            };
        }
        log_debug!("http", " {} header_timeout={}s body_timeout={}s", url, header_timeout.as_secs(), body_timeout.as_secs());
        macro_rules! progress {
            ($status:expr, $recv:expr, $total:expr) => {
                if let Some(ref p) = progress {
                    let mut lock = p.lock().unwrap();
                    lock.status = $status;
                    lock.bytes_received = $recv;
                    lock.total_bytes = $total;
                }
            };
        }
        loop {
            self.enforce_rate_limit().await;
            progress!(FetchStatus::Connecting, 0, None);

            // Check cookies before sending
            let cookies = self.get_session_cookies();
            let has_auth = cookies.contains("user_credentials");
            log_debug!("http"," cookies: has_auth={} len={} for {}", has_auth, cookies.len(), url);

            let client = match &self.transport {
                Transport::Direct(c) => c,
                #[cfg(feature = "tor")]
                Transport::Tor { client, .. } => client,
            };

            // Phase 1: Connect + TLS + headers (short timeout — dead connections fail fast)
            let send_start = std::time::Instant::now();
            let mut req = client.get(url);
            if ajax {
                req = req.header("X-Requested-With", "XMLHttpRequest")
                    .header("Accept", "text/html, */*; q=0.01");
            }
            let response = match tokio::time::timeout(header_timeout, req.send()).await {
                Err(_) => {
                    log_debug!("http"," TIMEOUT send phase after {:?} total={:?} {}", send_start.elapsed(), fetch_start.elapsed(), url);
                    progress!(FetchStatus::Failed, 0, None);
                    audit!(0, 0, Some("timeout".to_string()));
                    return Err(AppError::NetworkError("timeout".to_string()));
                }
                Ok(Err(e)) => {
                    log_debug!("http"," ERROR send phase after {:?}: {e} {}", send_start.elapsed(), url);
                    progress!(FetchStatus::Failed, 0, None);
                    audit!(0, 0, Some(format!("{e}")));
                    return Err(AppError::NetworkError(format!("{e}")));
                }
                Ok(Ok(r)) => {
                    log_debug!("http"," HEADERS in {:?} status={} {}", send_start.elapsed(), r.status(), url);
                    r
                }
            };

            // Detect stale session — AO3 redirects to login page
            let final_url = response.url().to_string();
            if final_url.contains("/users/login") && !url.contains("/users/login") {
                progress!(FetchStatus::Failed, 0, None);
                audit!(response.status().as_u16(), 0, Some("session_expired".to_string()));
                return Err(AppError::NetworkError("session_expired".to_string()));
            }

            let status = response.status();
            let code = status.as_u16();

            // Retry on transient HTTP errors before reading body
            // 429: rate-limited. The budget is per exit IP and Retry-After
            // says how long it's burned — re-poking inside that window is
            // useless (and can extend the penalty). Fail fast with the
            // header value so upper layers can rotate the circuit (fresh IP
            // = fresh budget) or surface an honest countdown.
            if code == 429 {
                let retry_after = response.headers().get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.trim().parse::<u64>().ok());
                let detail = match retry_after {
                    Some(secs) => format!("HTTP 429 retry_after={secs}"),
                    None => "HTTP 429".to_string(),
                };
                log_info!("http", " 429 rate-limited ({}) for {}",
                          retry_after.map_or("no retry-after".to_string(), |s| format!("{s}s")), url);
                progress!(FetchStatus::Failed, 0, None);
                audit!(code, 0, Some(detail.clone()));
                return Err(AppError::NetworkError(detail));
            }
            if (code == 525 || code == 503) && retries < 5 {
                retries += 1;
                progress!(FetchStatus::Connecting, 0, None);
                let delay = std::cmp::min(retries as u64 * 2, 10);
                log_debug!("http"," {} retry {}/5, waiting {}s for {}", code, retries, delay, url);
                tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
                continue;
            }
            if !status.is_success() {
                progress!(FetchStatus::Failed, 0, None);
                audit!(code, 0, Some(format!("HTTP {status}")));
                return Err(AppError::NetworkError(format!("HTTP {status} for {url}")));
            }

            // Phase 2: Read body in chunks with idle timeout per chunk
            let total_bytes = response.content_length();
            progress!(FetchStatus::Downloading, 0, total_bytes);

            let mut bytes_received: u64 = 0;
            let mut body_bytes = Vec::new();
            let mut response = response;

            loop {
                match tokio::time::timeout(body_timeout, response.chunk()).await {
                    Err(_) => {
                        progress!(FetchStatus::Failed, bytes_received, total_bytes);
                        audit!(code, bytes_received, Some("timeout".to_string()));
                        return Err(AppError::NetworkError("timeout".to_string()));
                    }
                    Ok(Err(e)) => {
                        progress!(FetchStatus::Failed, bytes_received, total_bytes);
                        audit!(code, bytes_received, Some(format!("Failed to read body: {e}")));
                        return Err(AppError::NetworkError(format!("Failed to read body: {e}")));
                    }
                    Ok(Ok(None)) => break,
                    Ok(Ok(Some(chunk))) => {
                        bytes_received += chunk.len() as u64;
                        body_bytes.extend_from_slice(&chunk);
                        progress!(FetchStatus::Downloading, bytes_received, total_bytes);
                    }
                }
            }

            progress!(FetchStatus::Complete, bytes_received, total_bytes);
            log_debug!("http"," DONE {} bytes in {:?} {}", bytes_received, fetch_start.elapsed(), url);
            audit!(code, bytes_received, None);

            let body = String::from_utf8(body_bytes)
                .map_err(|e| AppError::NetworkError(format!("Invalid UTF-8: {e}")))?;

            self.harvest_credentials(&body);
            return Ok(body);
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
        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };
        let response = client.head(BASE_URL)
            .send()
            .await
            .map_err(|e| AppError::NetworkError(format!("{e}")))?;
        Ok(response.status().as_u16())
    }

    async fn fetch(&self, url: &str) -> Result<String, AppError> {
        let timeout = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        let progress = self.active_progress.lock().unwrap().clone();
        self.fetch_with_progress(url, timeout, progress).await
    }

    async fn fetch_ajax(&self, url: &str) -> Result<String, AppError> {
        let timeout = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        let progress = self.active_progress.lock().unwrap().clone();
        self.fetch_ajax_with_progress(url, timeout, progress).await
    }

    pub fn set_active_progress(&self, handle: ProgressHandle) {
        *self.active_progress.lock().unwrap() = Some(handle);
    }

    pub fn clear_active_progress(&self) {
        *self.active_progress.lock().unwrap() = None;
    }

    /// Log in to AO3 with username and password.
    /// Returns true on success, false on failure.
    pub async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        // Step 1: GET login page to get authenticity_token and session cookie
        let login_html = self.fetch(&format!("{BASE_URL}/users/login")).await?;

        // Get the token from the MAIN login form (#new_user), not the small header form
        let token = {
            let doc = scraper::Html::parse_document(&login_html);
            let form_sel = scraper::Selector::parse("form#new_user input[name='authenticity_token']").unwrap();
            doc.select(&form_sel)
                .next()
                .and_then(|el| el.value().attr("value"))
                .map(|s| s.to_string())
                .ok_or_else(|| AppError::ParseError("No authenticity_token found".to_string()))
        }?;

        // Step 2: POST login form
        self.enforce_rate_limit().await;

        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };

        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );

        let params = [
            ("authenticity_token", token.as_str()),
            ("user[login]", username),
            ("user[password]", password),
            ("user[remember_me]", "1"),
            ("commit", "Log In"),
        ];

        let login_url = format!("{BASE_URL}/users/login");
        let _active = ActiveRequestGuard::new("POST", &login_url);
        let audit_started = now_ms();
        let audit_start = std::time::Instant::now();
        let audit_payload = redact_payload(&params);
        let audit_req_bytes = (login_url.len() + audit_payload.len() + 380) as u64;

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(&login_url)
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;

            let status = resp.status().as_u16();

            // Check for user_credentials cookie in response headers
            let has_cred_cookie = resp.headers().get_all("set-cookie")
                .iter()
                .any(|v| v.to_str().unwrap_or("").contains("user_credentials"));

            let final_url = resp.url().to_string();
            let body = resp.text().await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;

            Ok::<(bool, String, String, u16, usize), AppError>((has_cred_cookie, final_url, body, status, 0))
        }).await;

        macro_rules! audit_login {
            ($status:expr, $resp:expr, $err:expr) => {
                push_request_record(RequestRecord {
                    started_at_ms: audit_started, method: "POST".into(), url: login_url.clone(),
                    status: $status, duration_ms: audit_start.elapsed().as_millis() as u64,
                    request_bytes: audit_req_bytes, response_bytes: $resp, error: $err,
                    payload: Some(audit_payload.clone()),
                });
            };
        }

        let (has_cred_cookie, final_url, body, status, _) = match result {
            Err(_) => { audit_login!(0, 0, Some("timeout".to_string())); return Err(AppError::NetworkError("timeout".to_string())); }
            Ok(Err(e)) => { audit_login!(0, 0, Some(format!("{e}"))); return Err(e); }
            Ok(Ok(v)) => v,
        };
        audit_login!(status, body.len() as u64, None);
        let _body = body;

        let logged_in = has_cred_cookie || !final_url.contains("/users/login");

        Ok(logged_in)
    }

    /// POST a form to AO3, scraping the CSRF token from the POST URL itself.
    /// Only valid when GET on that URL renders a page (bookmarks, deletes) —
    /// for endpoints with no GET route use post_form_from with a token page.
    pub async fn post_form(&self, url: &str, params: &[(String, String)]) -> Result<String, AppError> {
        self.post_form_from(url, url, params).await
    }

    /// POST a form to AO3 with the CSRF token scraped from `token_page` —
    /// the page that hosts the form. Falls back to the csrf-token meta tag
    /// (present on every AO3 page; session-scoped, so any page's token is
    /// valid), and refuses to POST with an empty token — that's a guaranteed
    /// Rails 500.
    pub async fn post_form_from(&self, url: &str, token_page: &str, params: &[(String, String)]) -> Result<String, AppError> {
        let page = self.fetch(token_page).await?;
        let token = {
            let doc = scraper::Html::parse_document(&page);
            doc.select(&scraper::Selector::parse("input[name='authenticity_token']").unwrap())
                .next()
                .and_then(|el| el.value().attr("value").map(str::to_string))
                .or_else(|| {
                    doc.select(&scraper::Selector::parse("meta[name='csrf-token']").unwrap())
                        .next()
                        .and_then(|el| el.value().attr("content").map(str::to_string))
                })
                .unwrap_or_default()
        };
        if token.is_empty() {
            return Err(AppError::ParseError(format!("no CSRF token found on {token_page}")));
        }

        let mut form_params: Vec<(String, String)> = vec![
            ("authenticity_token".to_string(), token),
        ];
        form_params.extend_from_slice(params);
        self.post_form_raw(url, form_params).await
    }

    /// POST a comment from cached credentials — no preparatory GET. The form
    /// fields mirror AO3's comment form exactly: authenticity_token,
    /// comment[pseud_id], controller_name, comment[comment_content], commit.
    /// If credentials are missing or the archive rejects them, `form_page`
    /// is fetched ONCE (which re-harvests both) and the POST retried.
    pub async fn post_comment_direct(&self, endpoint: &str, controller_name: &str,
                                     form_page: &str, content: &str) -> Result<bool, AppError> {
        let mut refreshed = false;
        loop {
            let (token, pseud) = (self.cached_csrf_token(), self.cached_pseud_id());
            let (Some(token), Some(pseud)) = (token, pseud) else {
                if refreshed {
                    return Err(AppError::ParseError(format!(
                        "no posting credentials found on {form_page} — are you signed in?")));
                }
                self.fetch(form_page).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let params = vec![
                ("authenticity_token".to_string(), token),
                ("comment[pseud_id]".to_string(), pseud),
                ("controller_name".to_string(), controller_name.to_string()),
                ("comment[comment_content]".to_string(), content.to_string()),
                ("commit".to_string(), "Comment".to_string()),
            ];
            let body = self.post_form_raw(endpoint, params).await?;
            if body.contains("Comment created") || body.contains("was added") || body.contains(content) {
                return Ok(true);
            }
            if !refreshed {
                // Stale token (session changed since it was harvested) —
                // refresh once and retry.
                refreshed = true;
                self.fetch(form_page).await?;
                continue;
            }
            log_info!("comment", "Rejected POST to {endpoint}: {}",
                      body.chars().take(300).collect::<String>());
            return Ok(false);
        }
    }

    /// POST pre-assembled form params (token already included).
    async fn post_form_raw(&self, url: &str, form_params: Vec<(String, String)>) -> Result<String, AppError> {
        self.enforce_rate_limit().await;

        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };

        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );

        let _active = ActiveRequestGuard::new("POST", url);
        let audit_started = now_ms();
        let audit_start = std::time::Instant::now();
        let audit_payload = redact_payload(
            &form_params.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect::<Vec<_>>());
        let audit_req_bytes = (url.len() + audit_payload.len() + 380) as u64;

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(url)
                .form(&form_params)
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            let status = resp.status().as_u16();
            let body = resp.text().await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            Ok::<(u16, String), AppError>((status, body))
        }).await;

        macro_rules! audit_post {
            ($status:expr, $resp:expr, $err:expr) => {
                push_request_record(RequestRecord {
                    started_at_ms: audit_started, method: "POST".into(), url: url.to_string(),
                    status: $status, duration_ms: audit_start.elapsed().as_millis() as u64,
                    request_bytes: audit_req_bytes, response_bytes: $resp, error: $err,
                    payload: Some(audit_payload.clone()),
                });
            };
        }

        match result {
            Err(_) => { audit_post!(0, 0, Some("timeout".to_string())); Err(AppError::NetworkError("timeout".to_string())) }
            Ok(Err(e)) => { audit_post!(0, 0, Some(format!("{e}"))); Err(e) }
            Ok(Ok((status, body))) => { audit_post!(status, body.len() as u64, None); Ok(body) }
        }
    }

    /// Leave kudos on a work using the cached CSRF token — no preparatory
    /// GET. On a cache miss or a stale-token rejection, the work page is
    /// fetched ONCE (re-harvesting the token) and the POST retried.
    pub async fn leave_kudos(&self, work_id: u64) -> Result<bool, AppError> {
        let work_url = format!("{BASE_URL}/works/{work_id}?view_adult=true");
        let mut refreshed = false;
        loop {
            let Some(token) = self.cached_csrf_token() else {
                if refreshed {
                    return Err(AppError::ParseError("no CSRF token available — are you signed in?".to_string()));
                }
                self.fetch(&work_url).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let (status, body) = self.post_kudos_raw(work_id, &token, &work_url).await?;
            let already = body.contains("already left kudos");
            if status < 300 || already {
                return Ok(true);
            }
            if !refreshed {
                refreshed = true;
                self.fetch(&work_url).await?;
                continue;
            }
            log_info!("kudos", "Rejected (HTTP {status}): {}", body.chars().take(300).collect::<String>());
            return Ok(false);
        }
    }

    async fn post_kudos_raw(&self, work_id: u64, token: &str, work_url: &str) -> Result<(u16, String), AppError> {
        let _active = ActiveRequestGuard::new("POST", &format!("{BASE_URL}/kudos"));
        self.enforce_rate_limit().await;

        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };
        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );

        let id_string = work_id.to_string();
        let params = [
            ("authenticity_token", token),
            ("kudo[commentable_id]", id_string.as_str()),
            ("kudo[commentable_type]", "Work"),
        ];
        let kudos_url = format!("{BASE_URL}/kudos");
        let audit_started = now_ms();
        let audit_start = std::time::Instant::now();
        let audit_payload = redact_payload(&params);
        let audit_req_bytes = (kudos_url.len() + audit_payload.len() + 380) as u64;

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(&kudos_url)
                // Match the site's own AJAX submission: JSON responses, and a
                // 422 (not a redirect chain) for "already left kudos".
                .header("X-Requested-With", "XMLHttpRequest")
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .header("Referer", work_url)
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            let status = resp.status().as_u16();
            let body = resp.text().await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            Ok::<(u16, String), AppError>((status, body))
        }).await;

        macro_rules! audit_kudos {
            ($status:expr, $resp:expr, $err:expr) => {
                push_request_record(RequestRecord {
                    started_at_ms: audit_started, method: "POST".into(), url: kudos_url.clone(),
                    status: $status, duration_ms: audit_start.elapsed().as_millis() as u64,
                    request_bytes: audit_req_bytes, response_bytes: $resp, error: $err,
                    payload: Some(audit_payload.clone()),
                });
            };
        }

        match result {
            Err(_) => {
                audit_kudos!(0, 0, Some("timeout".to_string()));
                Err(AppError::NetworkError("timeout".to_string()))
            }
            Ok(Err(e)) => {
                audit_kudos!(0, 0, Some(format!("{e}")));
                Err(e)
            }
            Ok(Ok((status, body))) => {
                let accepted = status < 300 || body.contains("already left kudos");
                audit_kudos!(status, body.len() as u64,
                             if accepted { None } else { Some(format!("HTTP {status}")) });
                Ok((status, body))
            }
        }
    }

    /// A user's profile page as an AO3User record (avatar URL included when
    /// the page has one). One request.
    pub async fn fetch_user_profile(&self, username: &str) -> Result<crate::models::AO3User, AppError> {
        let html = self.fetch(&format!("{BASE_URL}/users/{}/profile", urlencoded(username))).await?;
        Ok(crate::models::AO3User {
            id: username.to_string(),
            username: username.to_string(),
            profile_url: Some(format!("{BASE_URL}/users/{username}")),
            avatar_url: parser::extract_user_icon_url(&html),
        })
    }

    /// A user's profile icon: profile page → icon URL → image. Returns the
    /// bytes plus the resolved icon URL so callers can record it.
    /// Two requests; callers cache the result so this runs once per user.
    pub async fn fetch_user_icon(&self, username: &str) -> Result<(Vec<u8>, String), AppError> {
        let profile = self.fetch_user_profile(username).await?;
        let Some(url) = profile.avatar_url else {
            return Err(AppError::ElementNotFound(format!("profile icon for {username}")));
        };
        let bytes = self.fetch_image(&url).await?;
        Ok((bytes, url))
    }

    /// AO3's JSON autocomplete for canonical tag names — fired ONLY on an
    /// explicit user action, never on keystrokes (local cache handles those).
    /// tag_type: fandom | character | relationship | freeform | creator.
    pub async fn autocomplete(&self, tag_type: &str, term: &str) -> Result<Vec<String>, AppError> {
        let endpoint = match tag_type {
            "creator" => "pseud",
            other => other,
        };
        let url = format!("{BASE_URL}/autocomplete/{}?term={}", endpoint, urlencoded(term));
        let body = self.fetch_ajax(&url).await?;
        let parsed: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| AppError::ParseError(format!("autocomplete JSON: {e}")))?;
        let mut names = Vec::new();
        if let Some(items) = parsed.as_array() {
            for item in items {
                if let Some(name) = item.get("name").and_then(|v| v.as_str()) {
                    names.push(name.to_string());
                }
            }
        }
        Ok(names)
    }

    /// Check if the current session is logged in.
    pub async fn is_logged_in(&self) -> Result<bool, AppError> {
        self.enforce_rate_limit().await;
        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };
        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );
        let result = tokio::time::timeout(timeout, async {
            let resp = client.get(&format!("{BASE_URL}/users/login"))
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            // If logged in, AO3 redirects away from /users/login
            Ok::<bool, AppError>(!resp.url().to_string().contains("/users/login"))
        }).await;
        match result {
            Err(_) => Err(AppError::NetworkError("timeout".to_string())),
            Ok(r) => r,
        }
    }

    /// Log out of AO3 by sending a DELETE request to the session endpoint.
    pub async fn logout(&self) -> Result<(), AppError> {
        let html = self.fetch(&format!("{BASE_URL}/")).await?;
        let token = {
            let doc = scraper::Html::parse_document(&html);
            let sel = scraper::Selector::parse("a[href='/users/logout']").unwrap();
            if doc.select(&sel).next().is_none() {
                return Ok(());
            }
            let meta_sel = scraper::Selector::parse("meta[name='csrf-token']").unwrap();
            doc.select(&meta_sel)
                .next()
                .and_then(|el| el.value().attr("content"))
                .map(|s| s.to_string())
                .unwrap_or_default()
        };

        if token.is_empty() {
            self.clear_cookies();
            return Ok(());
        }

        self.enforce_rate_limit().await;

        let client = match &self.transport {
            Transport::Direct(c) => c,
            #[cfg(feature = "tor")]
            Transport::Tor { client, .. } => client,
        };

        let timeout = std::time::Duration::from_secs(
            self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
        );

        let params = [
            ("authenticity_token", token.as_str()),
            ("_method", "delete"),
        ];

        let result = tokio::time::timeout(timeout, async {
            client.post(&format!("{BASE_URL}/users/logout"))
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            Ok::<(), AppError>(())
        }).await;

        match result {
            Err(_) => {},
            Ok(Err(_)) => {},
            Ok(Ok(())) => {},
        }

        self.clear_cookies();
        Ok(())
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
        tokio::spawn(async move {
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
        self.transport = Transport::Tor { client, _tor: isolated };
        self.cookie_jar = new_jar;
        self.socks_port = Some(local_addr.port());
        self.timeout_secs.store(timeout, std::sync::atomic::Ordering::Relaxed);

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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

/// Minimal percent-encoding for AO3 tag URLs. AO3 uses *. (dot)* as a tag
/// separator in URLs, so we only encode what's strictly necessary for a valid
/// URL path segment.
fn urlencoded(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// Try to extract a bookmark ID from AO3's response HTML.
/// Looks for patterns like id="bookmark_12345" or /bookmarks/12345.
fn extract_bookmark_id_from_response(html: &str) -> Option<u64> {
    // Try id="bookmark_NNNNN"
    if let Some(pos) = html.find("id=\"bookmark_") {
        let after = &html[pos + 13..]; // skip `id="bookmark_`
        let end = after.find('"').unwrap_or(after.len());
        if let Ok(id) = after[..end].parse::<u64>() {
            return Some(id);
        }
    }
    // Try /bookmarks/NNNNN in the URL or body
    for part in html.split("/bookmarks/") {
        if part.is_empty() {
            continue;
        }
        let num_str: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(id) = num_str.parse::<u64>() {
            return Some(id);
        }
    }
    None
}

fn ao3_tag_encode(tag: &str) -> String {
    tag.replace('/', "*s*")
       .replace('&', "*a*")
       .replace('.', "*d*")
       .replace(' ', "%20")
}

// ---------------------------------------------------------------------------
// Embedded SOCKS5 proxy (Tor transport)
// ---------------------------------------------------------------------------

/// Run a minimal SOCKS5 proxy that bridges local TCP connections through the
/// Tor network. Only SOCKS5 CONNECT (command 0x01) with domain-name addresses
/// (address type 0x03), IPv4 (0x01), and IPv6 (0x04) is supported — this is
/// exactly what `reqwest` sends when configured with `socks5h://`.
#[cfg(feature = "tor")]
async fn run_socks_proxy(
    listener: tokio::net::TcpListener,
    tor: Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>,
) {
    loop {
        let (stream, _addr) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => continue,
        };
        let tor = Arc::clone(&tor);
        tokio::spawn(async move {
            if let Err(_e) = handle_socks_connection(stream, &tor).await {
                // Connection-level errors are silently dropped; the caller
                // (reqwest) will surface a network error.
            }
        });
    }
}

/// Handle one inbound SOCKS5 connection.
///
/// Protocol reference: RFC 1928
#[cfg(feature = "tor")]
async fn handle_socks_connection(
    mut stream: tokio::net::TcpStream,
    tor: &arti_client::TorClient<tor_rtcompat::PreferredRuntime>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use arti_client::IntoTorAddr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    stream.set_nodelay(true)?;

    // --- Greeting -----------------------------------------------------------
    // Client sends: VER | NMETHODS | METHODS...
    let mut buf = [0u8; 2];
    stream.read_exact(&mut buf).await?;
    let ver = buf[0];
    let nmethods = buf[1] as usize;
    if ver != 0x05 {
        return Err("unsupported SOCKS version".into());
    }
    let mut methods = vec![0u8; nmethods];
    stream.read_exact(&mut methods).await?;

    // We only support "no authentication" (0x00).
    stream.write_all(&[0x05, 0x00]).await?;

    // --- Request ------------------------------------------------------------
    // Client sends: VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).await?;
    let cmd = header[1];
    let atyp = header[3];

    if cmd != 0x01 {
        // Only CONNECT is supported.
        let reply = [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
        stream.write_all(&reply).await?;
        return Err("unsupported SOCKS command".into());
    }

    let (host, port) = match atyp {
        // IPv4
        0x01 => {
            let mut addr = [0u8; 4];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let ip = std::net::Ipv4Addr::from(addr);
            (ip.to_string(), port)
        }
        // Domain name
        0x03 => {
            let mut len_buf = [0u8; 1];
            stream.read_exact(&mut len_buf).await?;
            let len = len_buf[0] as usize;
            let mut domain = vec![0u8; len];
            stream.read_exact(&mut domain).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            (String::from_utf8(domain)?, port)
        }
        // IPv6
        0x04 => {
            let mut addr = [0u8; 16];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let ip = std::net::Ipv6Addr::from(addr);
            (ip.to_string(), port)
        }
        _ => {
            let reply = [0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err("unsupported address type".into());
        }
    };

    // --- Connect via Tor ----------------------------------------------------
    let tor_addr = (host.as_str(), port)
        .into_tor_addr()
        .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> {
            format!("invalid Tor address: {e}").into()
        })?;

    log_debug!("socks"," Connecting to {host}:{port} via Tor");
    let socks_start = std::time::Instant::now();
    let tor_stream = match tokio::time::timeout(
        std::time::Duration::from_secs(15),
        tor.connect(tor_addr),
    ).await {
        Ok(Ok(s)) => {
            log_debug!("socks"," Connected to {host}:{port} in {:?}", socks_start.elapsed());
            s
        }
        Ok(Err(e)) => {
            log_debug!("socks"," Failed to connect to {host}:{port} in {:?}: {e}", socks_start.elapsed());
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err(format!("Tor connect failed: {e}").into());
        }
        Err(_) => {
            log_debug!("socks"," Timed out connecting to {host}:{port} after 15s");
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err("Tor stream timed out after 15s".into());
        }
    };

    // --- Success reply ------------------------------------------------------
    // VER | REP(0x00=success) | RSV | ATYP(IPv4) | BND.ADDR(0.0.0.0) | BND.PORT(0)
    let reply = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
    stream.write_all(&reply).await?;

    // --- Bidirectional copy -------------------------------------------------
    let (mut local_read, mut local_write) = stream.into_split();
    let (mut tor_read, mut tor_write) = tokio::io::split(tor_stream);

    let client_to_tor = tokio::io::copy(&mut local_read, &mut tor_write);
    let tor_to_client = tokio::io::copy(&mut tor_read, &mut local_write);

    // When either direction finishes (or errors), we're done.
    tokio::select! {
        _ = client_to_tor => {}
        _ = tor_to_client => {}
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_urlencoded() {
        assert_eq!(urlencoded("Harry Potter"), "Harry+Potter");
        assert_eq!(
            urlencoded("Alternate Universe - Modern Setting"),
            "Alternate+Universe+-+Modern+Setting"
        );
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
