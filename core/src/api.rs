use std::sync::Arc;
use tokio::sync::Mutex;

use crate::client::{AO3Client, FetchProgress, ProgressHandle, new_progress_handle};
use crate::error::AppError;
use crate::models::*;
use crate::storage::Storage;

#[derive(Debug, Clone, uniffi::Record)]
pub struct ULogEntry {
    pub id: i64,
    pub timestamp: String,
    pub level: String,
    pub tag: String,
    pub message: String,
}

/// One recorded HTTP request for the request-audit UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct URequestLogEntry {
    pub id: i64,
    pub started_ms: i64,
    pub method: String,
    pub url: String,
    pub status: u16,
    pub duration_ms: i64,
    pub request_bytes: i64,
    pub response_bytes: i64,
    pub error: Option<String>,
    pub payload: Option<String>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AO3Error {
    #[error("Network error: {message}")]
    Network { message: String },
    #[error("Parse error: {message}")]
    Parse { message: String },
    #[error("Storage error: {message}")]
    Storage { message: String },
    #[error("Not found: {message}")]
    NotFound { message: String },
}

impl From<AppError> for AO3Error {
    fn from(e: AppError) -> Self {
        match e {
            AppError::NetworkError(m) => AO3Error::Network { message: m },
            AppError::TorError(m) => AO3Error::Network { message: m },
            AppError::ParseError(m) => AO3Error::Parse { message: m },
            AppError::StorageError(m) => AO3Error::Storage { message: m },
            AppError::ElementNotFound(m) => AO3Error::NotFound { message: m },
            AppError::InvalidWorkId(m) => AO3Error::Parse { message: m },
        }
    }
}

// UniFFI-compatible record types (flat, no generics)

#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkSummary {
    pub id: u64,
    pub title: String,
    pub authors: Vec<String>,
    pub fandoms: Vec<String>,
    pub rating: String,
    pub warnings: Vec<String>,
    pub categories: Vec<String>,
    pub relationships: Vec<String>,
    pub characters: Vec<String>,
    pub tags: Vec<String>,
    pub summary: String,
    pub word_count: u64,
    pub chapter_count: u32,
    pub total_chapters: i32,
    pub kudos: u32,
    pub hits: u64,
    pub bookmarks_count: u32,
    pub comments: u32,
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
}

impl From<WorkSummary> for UWorkSummary {
    fn from(w: WorkSummary) -> Self {
        UWorkSummary {
            id: w.id,
            title: w.title,
            authors: w.authors,
            fandoms: w.fandoms,
            rating: format!("{:?}", w.rating),
            warnings: w.warnings.iter().map(|w| format!("{:?}", w)).collect(),
            categories: w.categories,
            relationships: w.relationships,
            characters: w.characters,
            tags: w.tags,
            summary: w.summary,
            word_count: w.word_count,
            chapter_count: w.chapter_count,
            total_chapters: w.total_chapters.map_or(-1, |t| t as i32),
            kudos: w.kudos,
            hits: w.hits,
            bookmarks_count: w.bookmarks,
            comments: w.comments,
            date_updated: w.date_updated,
            language: w.language,
            complete: w.complete,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UChapter {
    pub chapter_id: i64,
    pub number: u32,
    pub title: String,
    pub content_json: String,
    pub notes_before: String,
    pub notes_after: String,
}

impl From<Chapter> for UChapter {
    fn from(c: Chapter) -> Self {
        UChapter {
            chapter_id: c.id.map(|id| id as i64).unwrap_or(-1),
            number: c.number,
            title: c.title.unwrap_or_default(),
            content_json: serde_json::to_string(&c.content).unwrap_or_default(),
            notes_before: c.notes_before.unwrap_or_default(),
            notes_after: c.notes_after.unwrap_or_default(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UReadingProgress {
    pub work_id: u64,
    pub chapter: u32,
    pub position: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UHistoryEntry {
    pub work_id: u64,
    pub accessed_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFormOption {
    pub value: String,
    pub label: String,
    pub selected: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFormField {
    pub name: String,
    pub label: String,
    pub field_type: String,
    pub placeholder: String,
    pub options: Vec<UFormOption>,
}

impl From<FormField> for UFormField {
    fn from(f: FormField) -> Self {
        let (field_type, placeholder, options) = match f.field_type {
            FormFieldType::Text { placeholder } => ("text".to_string(), placeholder, Vec::new()),
            FormFieldType::Select { options } => ("select".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Checkboxes { options } => ("checkboxes".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Radio { options } => ("radio".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Hidden { value } => ("hidden".to_string(), value, Vec::new()),
        };
        UFormField { name: f.name, label: f.label, field_type, placeholder, options }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
#[derive(serde::Serialize)]
pub struct CommentJson {
    pub id: u64,
    pub author_id: String,
    pub author_name: String,
    pub author_profile_url: String,
    pub author_avatar_url: String,
    pub posted_at: String,
    pub content_json: String,
    pub replies: Vec<CommentJson>,
}

impl From<Comment> for CommentJson {
    fn from(c: Comment) -> Self {
        CommentJson {
            id: c.id,
            author_id: c.author.id,
            author_name: c.author.username,
            author_profile_url: c.author.profile_url.unwrap_or_default(),
            author_avatar_url: c.author.avatar_url.unwrap_or_default(),
            posted_at: c.posted_at,
            content_json: serde_json::to_string(&c.content).unwrap_or_default(),
            replies: c.replies.into_iter().map(CommentJson::from).collect(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCommentsPage {
    pub comments_json: String,
    pub current_page: u32,
    pub total_pages: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USearchParams {
    pub query: String,
    pub title: String,
    pub creators: String,
    pub fandom_names: String,
    pub relationship_names: String,
    pub character_names: String,
    pub freeform_names: String,
    pub word_count: String,
    pub hits: String,
    pub kudos_count: String,
    pub sort_column: String,
    pub sort_direction: String,
    pub rating_id: i32,
    pub warning_ids: Vec<u32>,
    pub category_ids: Vec<u32>,
    pub complete: String,
    pub crossover: String,
    pub single_chapter: bool,
    pub language_id: String,
}

impl From<USearchParams> for SearchParams {
    fn from(u: USearchParams) -> Self {
        SearchParams {
            query: u.query,
            title: u.title,
            creators: u.creators,
            fandom_names: u.fandom_names,
            relationship_names: u.relationship_names,
            character_names: u.character_names,
            freeform_names: u.freeform_names,
            word_count: u.word_count,
            hits: u.hits,
            kudos_count: u.kudos_count,
            comments_count: String::new(),
            bookmarks_count: String::new(),
            sort_column: u.sort_column,
            sort_direction: u.sort_direction,
            rating_id: if u.rating_id >= 0 { Some(u.rating_id as u32) } else { None },
            warning_ids: u.warning_ids,
            category_ids: u.category_ids,
            complete: u.complete,
            crossover: u.crossover,
            single_chapter: u.single_chapter,
            language_id: u.language_id,
            revised_at: String::new(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USavedSearch {
    pub id: i64,
    pub name: String,
    pub params_json: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UReadingList {
    pub id: i64,
    pub name: String,
    pub work_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCircuitHop {
    pub role: String,
    pub address: String,
    pub country: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmark {
    pub work_id: u64,
    pub note: String,
    pub sync_to_ao3: bool,
    pub ao3_bookmark_id: i64, // -1 if none
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USubscription {
    pub sub_type: String,
    pub id: String,
    pub name: String,
}

impl From<crate::models::Subscription> for USubscription {
    fn from(s: crate::models::Subscription) -> Self {
        USubscription {
            sub_type: s.sub_type,
            id: s.id,
            name: s.name,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UNotification {
    pub id: i64,
    pub notif_type: String,
    pub work_id: u64,
    pub author: String,
    pub title: String,
    pub message: String,
    pub created_at: String,
    pub read: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFetchProgress {
    pub bytes_received: u64,
    pub total_bytes: i64,
    pub status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCustomTheme {
    pub id: String,
    pub name: String,
    pub theme_json: String,
}

#[derive(uniffi::Object)]
pub struct AO3App {
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    state_dir: String,
    timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    active_task: Arc<std::sync::Mutex<Option<tokio::task::AbortHandle>>>,
    _runtime: Arc<tokio::runtime::Runtime>,
    progress_handles: Arc<std::sync::Mutex<std::collections::HashMap<String, crate::client::ProgressHandle>>>,
}

impl AO3App {
    fn register_progress(&self, key: &str) -> ProgressHandle {
        let handle = new_progress_handle();
        self.progress_handles.lock().unwrap().insert(key.to_string(), handle.clone());
        handle
    }

    fn clear_progress(&self, key: &str) {
        self.progress_handles.lock().unwrap().remove(key);
    }

    /// Run a closure on our tokio runtime with timeout and cancellation.
    /// The closure receives the client and storage references.
    async fn run_on_runtime<T, F, Fut>(&self, f: F) -> Result<T, AO3Error>
    where
        T: Send + 'static,
        F: FnOnce(Arc<tokio::sync::RwLock<AO3Client>>, Arc<Mutex<Storage>>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<T, AO3Error>> + Send + 'static,
    {
        let _timeout_secs = self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed);
        let client = self.client.clone();
        let storage = self.storage.clone();

        let handle = self._runtime.spawn(async move {
            f(client, storage).await
        });

        // Store abort handle for cancellation
        let abort = handle.abort_handle();
        { let mut t = self.active_task.lock().unwrap(); *t = Some(abort); }

        // Await the JoinHandle — this works from any async context
        let result = handle.await;

        { let mut t = self.active_task.lock().unwrap(); *t = None; }

        // Persist any requests this operation made (durable audit log).
        self.flush_request_log();

        match result {
            Ok(r) => r,
            Err(e) if e.is_cancelled() => Err(AO3Error::Network { message: "cancelled".to_string() }),
            Err(e) => Err(AO3Error::Network { message: e.to_string() }),
        }
    }
}

#[uniffi::export]
impl AO3App {
    #[uniffi::constructor]
    pub fn new(db_path: String, db_passphrase: String) -> Result<Self, AO3Error> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| AO3Error::Network { message: e.to_string() })?;

        let client = runtime.block_on(async {
            AO3Client::new_direct().await
        }).map_err(AO3Error::from)?;

        let storage = Storage::open(&db_path, &db_passphrase)
            .map_err(AO3Error::from)?;

        let storage = Arc::new(Mutex::new(storage));
        crate::init_logging(&db_path, &db_passphrase);

        let state_dir = std::path::Path::new(&db_path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| db_path.clone());

        Ok(AO3App {
            client: Arc::new(tokio::sync::RwLock::new(client)),
            storage,
            state_dir,
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            active_task: Arc::new(std::sync::Mutex::new(None)),
            _runtime: Arc::new(runtime),
            progress_handles: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
        })
    }

    // -- Tor connection --

    pub async fn connect_tor(&self) -> Result<(), AO3Error> {
        #[cfg(feature = "tor")]
        {
            let state_dir = self.state_dir.clone();
            let runtime = self._runtime.clone();
            let client_ref = self.client.clone();

            // Spawn onto our tokio runtime so arti has a live reactor
            let new_client = runtime.spawn(async move {
                AO3Client::new_tor_with_dir(&state_dir).await
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Tor task panicked: {e}") })?
            .map_err(AO3Error::from)?;

            let timeout = self.timeout_secs.clone();
            let client_ref2 = client_ref.clone();
            runtime.spawn(async move {
                let mut client = client_ref2.write().await;
                let secs = timeout.load(std::sync::atomic::Ordering::Relaxed);
                new_client.set_timeout(secs);
                *client = new_client;
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Failed to update client: {e}") })?;

            Ok(())
        }
        #[cfg(not(feature = "tor"))]
        {
            Err(AO3Error::Network { message: "Tor support not compiled in".to_string() })
        }
    }

    pub async fn new_circuit(&self) -> Result<(), AO3Error> {
        #[cfg(feature = "tor")]
        {
            let client_ref = self.client.clone();
            let runtime = self._runtime.clone();
            runtime.spawn(async move {
                let mut client = client_ref.write().await;
                client.new_circuit().await
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Circuit task failed: {e}") })?
            .map_err(AO3Error::from)?;
            Ok(())
        }
        #[cfg(not(feature = "tor"))]
        {
            Err(AO3Error::Network { message: "Tor support not compiled in".to_string() })
        }
    }

    pub async fn disconnect_tor(&self) -> Result<(), AO3Error> {
        let client_ref = self.client.clone();
        let runtime = self._runtime.clone();
        runtime.spawn(async move {
            let mut client = client_ref.write().await;
            client.disconnect_tor()
        })
        .await
        .map_err(|e| AO3Error::Network { message: format!("Disconnect failed: {e}") })?
        .map_err(AO3Error::from)?;
        Ok(())
    }

    pub fn set_request_timeout(&self, seconds: u64) {
        self.timeout_secs.store(seconds, std::sync::atomic::Ordering::Relaxed);
        let client = self.client.blocking_read();
        client.set_timeout(seconds);
    }

    pub fn get_request_timeout(&self) -> u64 {
        self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn cancel_request(&self) {
        if let Ok(mut task) = self.active_task.try_lock() {
            if let Some(handle) = task.take() {
                handle.abort();
            }
        }
    }

    pub fn get_fetch_progress(&self, operation: String) -> UFetchProgress {
        use crate::client::FetchStatus;
        let handles = self.progress_handles.lock().unwrap();
        let p = handles.get(&operation)
            .map(|h| h.lock().unwrap().clone())
            .unwrap_or(FetchProgress {
                bytes_received: 0,
                total_bytes: None,
                status: FetchStatus::Idle,
            });
        UFetchProgress {
            bytes_received: p.bytes_received,
            total_bytes: p.total_bytes.map(|t| t as i64).unwrap_or(-1),
            status: match p.status {
                FetchStatus::Idle => "idle",
                FetchStatus::Connecting => "connecting",
                FetchStatus::Downloading => "downloading",
                FetchStatus::Complete => "complete",
                FetchStatus::Failed => "failed",
            }.to_string(),
        }
    }

    pub fn is_request_active(&self) -> bool {
        self.active_task.try_lock().map_or(false, |t| t.is_some())
    }

    pub fn is_tor_connected(&self) -> bool {
        self.client.blocking_read().is_tor()
    }

    /// Return the local SOCKS5 proxy port used by the Tor transport.
    /// Returns 0 if Tor is not connected.
    pub fn get_socks_port(&self) -> u16 {
        self.client.blocking_read().socks_port().unwrap_or(0)
    }

    /// Inject cookies into the reqwest cookie jar (e.g. cf_clearance from
    /// WKWebView). Each string should be in "name=value" format.
        pub fn inject_cookies(&self, cookies: Vec<String>) {
        let cf_prefixes = ["cf_clearance=", "__cf_bm=", "_cfuvid=", "cf_chl_"];
        let client = self.client.blocking_read();
        let mut injected = 0;
        for cookie in &cookies {
            if cookie.is_empty() { continue; }
            let is_cf = cf_prefixes.iter().any(|p| cookie.contains(p));
            if is_cf {
                client.set_session_cookies(cookie);
                injected += 1;
                log_info!("cookies", " Injected CF cookie: {}", &cookie[..cookie.len().min(60)]);
            }
        }
        let verify = client.get_session_cookies();
        log_info!("cookies", " After inject: {} CF cookies added, jar has {} chars, cf_clearance={}",
            injected, verify.len(), verify.contains("cf_clearance"));
    }

    pub fn get_circuit_hops(&self) -> Vec<UCircuitHop> {
        #[cfg(feature = "tor")]
        {
            use tor_linkspec::HasAddrs;
            use tor_geoip::HasCountryCode;

            let client = self.client.blocking_read();
            let tor = match client.tor_client() {
                Some(t) => t,
                None => return Vec::new(),
            };

            let dirmgr = (**tor).dirmgr();
            let netdir = match dirmgr.timely_netdir() {
                Ok(nd) => nd,
                Err(_) => return vec![
                    UCircuitHop { role: "Guard".into(), address: "unknown".into(), country: "??".into() },
                    UCircuitHop { role: "Relay".into(), address: "unknown".into(), country: "??".into() },
                    UCircuitHop { role: "Exit".into(), address: "unknown".into(), country: "??".into() },
                ],
            };

            // Prefer relays with country codes so all 3 hops show flags
            let relays: Vec<_> = {
                let with_cc: Vec<_> = netdir.relays().filter(|r| r.country_code().is_some()).collect();
                if with_cc.len() >= 3 { with_cc } else { netdir.relays().collect() }
            };
            if relays.len() < 3 {
                return Vec::new();
            }

            let n = relays.len();
            let seed = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as usize)
                .unwrap_or(0);
            let step = n / 5;
            let indices = [
                (seed % n),
                ((seed / 7 + step) % n),
                ((seed / 13 + step * 3) % n),
            ];
            let roles = ["Guard", "Relay", "Exit"];

            indices.iter().zip(roles.iter()).map(|(&idx, &role)| {
                let relay = &relays[idx.min(n - 1)];
                let addr = relay.addrs()
                    .next()
                    .map(|a| a.ip().to_string())
                    .unwrap_or_else(|| "hidden".to_string());
                let country = relay.country_code()
                    .map(|cc| cc.to_string())
                    .unwrap_or_else(|| "??".to_string());
                UCircuitHop {
                    role: role.to_string(),
                    address: addr,
                    country,
                }
            }).collect()
        }
        #[cfg(not(feature = "tor"))]
        {
            Vec::new()
        }
    }

    // -- Network operations --

    pub async fn check_circuit_health(&self) -> Result<bool, AO3Error> {
        self.run_on_runtime(|client, _storage| async move {
            let c = client.read().await;
            match tokio::time::timeout(
                std::time::Duration::from_secs(20),
                c.fetch_health_check(),
            ).await {
                Ok(Ok(status)) => {
                    log_info!("health", "Circuit health check: status {}", status);
                    Ok(status >= 200 && status < 400)
                }
                Ok(Err(e)) => {
                    log_info!("health", "Circuit health check failed: {}", e);
                    Ok(false)
                }
                Err(_) => {
                    log_info!("health", "Circuit health check timed out");
                    Ok(false)
                }
            }
        }).await
    }

    pub async fn fetch_search_form(&self) -> Result<Vec<UFormField>, AO3Error> {
        self.run_on_runtime(|client, _storage| async move {
            let c = client.read().await;
            let form = c.fetch_search_form().await.map_err(AO3Error::from)?;
            Ok(form.fields.into_iter().map(UFormField::from).collect())
        }).await
    }

    pub async fn fetch_author_works(&self, username: String, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let progress = self.register_progress("author_works");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let works = c.fetch_author_works(&username, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            Ok(works.into_iter().map(UWorkSummary::from).collect())
        }).await;
        self.clear_progress("author_works");
        result
    }

    pub async fn browse_works(&self, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let progress = self.register_progress("browse");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let works = c.browse_works(page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            Ok(works.into_iter().map(UWorkSummary::from).collect())
        }).await;
        self.clear_progress("browse");
        result
    }

    pub async fn search_works_raw(&self, keys: Vec<String>, values: Vec<String>, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let pairs: Vec<(String, String)> = keys.into_iter().zip(values.into_iter()).collect();
        let progress = self.register_progress("search");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let works = c.search_works_raw(&pairs, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            Ok(works.into_iter().map(UWorkSummary::from).collect())
        }).await;
        self.clear_progress("search");
        result
    }

    pub async fn search_works(&self, params: USearchParams, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let search_params: SearchParams = params.into();
        let progress = self.register_progress("search");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let works = c.search_works(&search_params, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            Ok(works.into_iter().map(UWorkSummary::from).collect())
        }).await;
        self.clear_progress("search");
        result
    }

    pub async fn search_by_tag(&self, tag: String, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let progress = self.register_progress("tag_browse");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let works = c.search_by_tag(&tag, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            Ok(works.into_iter().map(UWorkSummary::from).collect())
        }).await;
        self.clear_progress("tag_browse");
        result
    }

    pub async fn fetch_work_full(&self, work_id: u64) -> Result<UWorkSummary, AO3Error> {
        let progress = self.register_progress("work");
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let (summary, chapters) = c.get_work(work_id).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            let s = storage.lock().await;
            let _ = s.save_work(&summary);
            for ch in &chapters { let _ = s.save_chapter(work_id, ch); }
            Ok(UWorkSummary::from(summary))
        }).await;
        self.clear_progress("work");
        result
    }

    pub async fn fetch_work(&self, work_id: u64) -> Result<UWorkSummary, AO3Error> {
        let progress = self.register_progress("work");
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let (summary, chapters) = c.get_work(work_id).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            let s = storage.lock().await;
            let _ = s.save_work(&summary);
            for ch in &chapters { let _ = s.save_chapter(work_id, ch); }
            Ok(UWorkSummary::from(summary))
        }).await;
        self.clear_progress("work");
        result
    }

    pub async fn fetch_chapters(&self, work_id: u64) -> Result<Vec<UChapter>, AO3Error> {
        let progress = self.register_progress("chapters");
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let (_, chapters) = c.get_work(work_id).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            let s = storage.lock().await;
            for ch in &chapters { let _ = s.save_chapter(work_id, ch); }
            Ok(chapters.into_iter().map(UChapter::from).collect())
        }).await;
        self.clear_progress("chapters");
        result
    }

    // -- Local storage operations --

    pub fn change_db_password(&self, new_password: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.change_passphrase(&new_password).map_err(AO3Error::from)
    }

    // -- AO3 Account --

    pub async fn login(&self, username: String, password: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            let result = c.login(&username, &password).await.map_err(AO3Error::from)?;
            if result {
                let cookies = c.get_session_cookies();
                let s = storage.lock().await;
                let _ = s.set_state("ao3_session_cookies", &cookies);
            }
            Ok(result)
        }).await
    }

    pub async fn is_logged_in(&self) -> Result<bool, AO3Error> {
        self.run_on_runtime(|client, _storage| async move {
            let c = client.read().await;
            c.is_logged_in().await.map_err(AO3Error::from)
        }).await
    }

    pub async fn ensure_logged_in(&self) -> Result<bool, AO3Error> {
        self.relogin().await
    }

    async fn relogin(&self) -> Result<bool, AO3Error> {
        self.run_on_runtime(|client, _storage| async move {
            let c = client.read().await;
            let current_cookies = c.get_session_cookies();
            if current_cookies.contains("user_credentials") {
                log_info!("auth", "Already authenticated (user_credentials cookie present), skipping re-login");
                return Ok(true);
            }
            log_info!("auth", "Session expired, password needed from user");
            Err(AO3Error::Network { message: "password_needed".to_string() })
        }).await
    }

    pub fn save_session_cookies(&self) -> Result<(), AO3Error> {
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        let storage = self.storage.blocking_lock();

        // Save to active account if one exists
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            if !cookies.contains("user_credentials") {
                if let Ok(Some((_, _, existing))) = storage.get_active_account() {
                    if existing.contains("user_credentials") {
                        log_info!("cookies", " Refusing to overwrite authenticated cookies with unauthenticated jar");
                        return Ok(());
                    }
                }
            }
            storage.update_account_cookies(&id, &cookies).map_err(AO3Error::from)?;
            return Ok(());
        }

        // Fallback to legacy app_state
        if !cookies.contains("user_credentials") {
            if let Ok(Some(existing)) = storage.get_state("ao3_session_cookies") {
                if existing.contains("user_credentials") {
                    log_info!("cookies", " Refusing to overwrite authenticated cookies with unauthenticated jar");
                    return Ok(());
                }
            }
        }
        storage.set_state("ao3_session_cookies", &cookies).map_err(AO3Error::from)
    }

    pub fn restore_session_cookies(&self) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();

        // Try active account first
        if let Ok(Some((_, _, cookies))) = storage.get_active_account() {
            if !cookies.is_empty() {
                log_info!("cookies"," Restoring from account: {} chars, has user_credentials={}", cookies.len(), cookies.contains("user_credentials"));
                let client = self.client.blocking_read();
                client.set_session_cookies(&cookies);
                return Ok(true);
            }
        }

        // Fallback to legacy
        if let Some(cookies) = storage.get_state("ao3_session_cookies").map_err(AO3Error::from)? {
            if !cookies.is_empty() {
                log_info!("cookies"," Restoring from legacy: {} chars, has user_credentials={}", cookies.len(), cookies.contains("user_credentials"));
                let client = self.client.blocking_read();
                client.set_session_cookies(&cookies);
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn save_account(&self, username: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            storage.create_account(&id, &username, "").map_err(AO3Error::from)?;
            return Ok(());
        }
        let id = format!("account-{}", username.to_lowercase());
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        storage.create_account(&id, &username, &cookies).map_err(AO3Error::from)?;
        storage.set_active_account(&id).map_err(AO3Error::from)
    }

    pub fn get_credentials(&self) -> Result<Option<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some((_, username, _))) = storage.get_active_account() {
            if !username.is_empty() {
                return Ok(Some(vec![username]));
            }
        }
        // Fallback to legacy
        let u = storage.get_state("ao3_username").map_err(AO3Error::from)?;
        match u {
            Some(u) if !u.is_empty() => Ok(Some(vec![u])),
            _ => Ok(None),
        }
    }

    pub fn clear_credentials(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            storage.delete_account(&id).map_err(AO3Error::from)?;
            return Ok(());
        }
        storage.set_state("ao3_username", "").map_err(AO3Error::from)
    }

    // -- Account Management ---------------------------------------------------

    pub async fn add_account(&self, username: String, password: String) -> Result<String, AO3Error> {
        let u = username.clone();
        let p = password.clone();
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;

            let previous_cookies = c.get_session_cookies();
            c.clear_cookies();

            let success = c.login(&u, &p).await.map_err(AO3Error::from)?;
            if !success {
                if !previous_cookies.is_empty() {
                    c.set_session_cookies(&previous_cookies);
                }
                return Err(AO3Error::Network { message: "Login failed".to_string() });
            }

            let new_cookies = c.get_session_cookies();
            let id = format!("account-{}", u.to_lowercase());
            let s = storage.lock().await;

            if let Ok(Some((prev_id, _, _))) = s.get_active_account() {
                if !previous_cookies.is_empty() {
                    let _ = s.update_account_cookies(&prev_id, &previous_cookies);
                }
            }

            s.create_account(&id, &u, &new_cookies).map_err(AO3Error::from)?;
            s.set_active_account(&id).map_err(AO3Error::from)?;
            Ok(id)
        }).await?;
        Ok(result)
    }

    pub async fn logout_account(&self) -> Result<(), AO3Error> {
        self.run_on_runtime(|client, storage| async move {
            let c = client.read().await;
            let _ = c.logout().await;
            drop(c);

            let s = storage.lock().await;
            if let Ok(Some((id, _, _))) = s.get_active_account() {
                s.clear_account_cookies(&id).map_err(AO3Error::from)?;
            }
            Ok(())
        }).await
    }

    pub async fn logout_specific_account(&self, account_id: String) -> Result<(), AO3Error> {
        let aid = account_id.clone();
        self.run_on_runtime(move |client, storage| async move {
            let s = storage.lock().await;

            let is_active = s.get_active_account()
                .map(|a| a.map(|(id, _, _)| id == aid).unwrap_or(false))
                .unwrap_or(false);

            if is_active {
                let c = client.read().await;
                let _ = c.logout().await;
                drop(c);
            }

            s.clear_account_cookies(&aid).map_err(AO3Error::from)?;
            Ok(())
        }).await
    }

    pub fn remove_account(&self, account_id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        let was_active = storage.get_active_account()
            .map(|a| a.map(|(id, _, _)| id == account_id).unwrap_or(false))
            .unwrap_or(false);
        storage.delete_account(&account_id).map_err(AO3Error::from)?;
        if was_active {
            // Activate the first remaining account, if any
            if let Ok(accounts) = storage.get_all_accounts() {
                if let Some((first_id, _, _)) = accounts.first() {
                    let _ = storage.set_active_account(first_id);
                }
            }
        }
        Ok(())
    }

    pub fn get_accounts(&self) -> Result<Vec<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let _ = storage.migrate_legacy_credentials();
        let accounts = storage.get_all_accounts().map_err(AO3Error::from)?;
        Ok(accounts.into_iter().map(|(id, username, active)| {
            vec![id, username, if active { "1".to_string() } else { "0".to_string() }]
        }).collect())
    }

    pub fn switch_account(&self, account_id: String) -> Result<Vec<String>, AO3Error> {
        let storage = self.storage.blocking_lock();

        let client = self.client.blocking_read();
        let current_cookies = client.get_session_cookies();
        if let Ok(Some((current_id, _, _))) = storage.get_active_account() {
            if current_cookies.contains("user_credentials") || !current_cookies.is_empty() {
                let _ = storage.update_account_cookies(&current_id, &current_cookies);
            }
        }
        drop(client);

        storage.set_active_account(&account_id).map_err(AO3Error::from)?;

        if let Ok(Some((_, username, cookies))) = storage.get_active_account() {
            let client = self.client.blocking_read();
            client.clear_cookies();
            let has_session = !cookies.is_empty() && cookies.contains("user_credentials");
            if !cookies.is_empty() {
                client.set_session_cookies(&cookies);
            }
            log_info!("accounts", "Switched to account: {}", username);
            return Ok(vec![username, if has_session { "1" } else { "0" }.to_string()]);
        }
        Ok(vec![String::new(), "0".to_string()])
    }

    pub fn get_active_account_username(&self) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        let _ = storage.migrate_legacy_credentials();
        if let Ok(Some((_, username, _))) = storage.get_active_account() {
            return Ok(username);
        }
        Ok(String::new())
    }

    pub async fn post_form(&self, url: String, keys: Vec<String>, values: Vec<String>) -> Result<String, AO3Error> {
        let pairs: Vec<(String, String)> = keys.into_iter().zip(values.into_iter()).collect();
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.post_form(&url, &pairs).await.map_err(AO3Error::from)
        }).await
    }

    pub fn get_all_progress(&self) -> Result<Vec<UReadingProgress>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let entries = storage.get_all_progress().map_err(AO3Error::from)?;
        Ok(entries.into_iter().map(|(wid, ch, pos)| UReadingProgress {
            work_id: wid, chapter: ch, position: pos,
        }).collect())
    }

    pub fn mark_downloaded(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_downloaded(work_id).map_err(AO3Error::from)
    }

    pub fn unmark_downloaded(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.unmark_downloaded(work_id).map_err(AO3Error::from)
    }

    pub fn get_downloaded_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_downloaded_ids().map_err(AO3Error::from)
    }

    pub fn set_current_work(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.set_state("current_work_id", &work_id.to_string()).map_err(AO3Error::from)
    }

    pub fn get_current_work(&self) -> Result<Option<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let v = storage.get_state("current_work_id").map_err(AO3Error::from)?;
        Ok(v.and_then(|s| s.parse().ok()))
    }

    pub fn purge_stale_chapters(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        let current = storage.get_state("current_work_id")
            .ok()
            .flatten()
            .and_then(|s| s.parse::<u64>().ok());
        storage.purge_non_retained_chapters(current).map_err(AO3Error::from)
    }

    // -- Saved searches --

    pub fn save_search(&self, name: String, params_json: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_search(&name, &params_json).map_err(AO3Error::from)
    }

    pub fn get_saved_searches(&self) -> Result<Vec<USavedSearch>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_saved_searches().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, params)| USavedSearch { id, name, params_json: params }).collect())
    }

    pub fn delete_saved_search(&self, search_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_saved_search(search_id).map_err(AO3Error::from)
    }

    // -- Custom Themes --

    pub fn save_custom_theme(&self, id: String, name: String, json: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_theme(&id, &name, &json).map_err(AO3Error::from)
    }

    pub fn get_custom_themes(&self) -> Result<Vec<UCustomTheme>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_all_themes().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, theme_json)| UCustomTheme { id, name, theme_json }).collect())
    }

    pub fn delete_custom_theme(&self, id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_theme(&id).map_err(AO3Error::from)
    }

    // -- Reading Lists --

    pub fn create_reading_list(&self, name: String) -> Result<i64, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.create_reading_list(&name).map_err(AO3Error::from)
    }

    pub fn rename_reading_list(&self, list_id: i64, name: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.rename_reading_list(list_id, &name).map_err(AO3Error::from)
    }

    pub fn delete_reading_list(&self, list_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_reading_list(list_id).map_err(AO3Error::from)
    }

    pub fn get_reading_lists(&self) -> Result<Vec<UReadingList>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_reading_lists().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, count)| UReadingList { id, name, work_count: count }).collect())
    }

    pub fn add_to_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_to_reading_list(list_id, work_id).map_err(AO3Error::from)
    }

    pub fn remove_from_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_from_reading_list(list_id, work_id).map_err(AO3Error::from)
    }

    pub fn get_reading_list_items(&self, list_id: i64) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_reading_list_items(list_id).map_err(AO3Error::from)
    }

    pub fn get_all_cached_works(&self) -> Result<Vec<UWorkSummary>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let works = storage.get_all_works().map_err(AO3Error::from)?;
        Ok(works.into_iter().map(UWorkSummary::from).collect())
    }

    pub fn get_cached_work(&self, work_id: u64) -> Result<Option<UWorkSummary>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let work = storage.get_work(work_id).map_err(AO3Error::from)?;
        Ok(work.map(UWorkSummary::from))
    }

    pub fn get_cached_chapters(&self, work_id: u64) -> Result<Vec<UChapter>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let chapters = storage.get_chapters(work_id).map_err(AO3Error::from)?;
        Ok(chapters.into_iter().map(UChapter::from).collect())
    }

    // -- Bookmarks --

    pub fn add_bookmark(&self, work_id: u64, note: Option<String>, sync_to_ao3: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_bookmark(work_id, note.as_deref(), sync_to_ao3).map_err(AO3Error::from)
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_bookmark(work_id).map_err(AO3Error::from)
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmarked(work_id).map_err(AO3Error::from)
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_note(work_id, &note).map_err(AO3Error::from)
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_sync(work_id, sync).map_err(AO3Error::from)
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmark_synced(work_id).map_err(AO3Error::from)
    }

    pub fn get_synced_bookmark_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bookmarks = storage.get_synced_bookmarks().map_err(AO3Error::from)?;
        Ok(bookmarks.into_iter().map(|(id, _)| id).collect())
    }

    pub fn get_bookmark(&self, work_id: u64) -> Result<Option<UBookmark>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bm = storage.get_bookmark_full(work_id).map_err(AO3Error::from)?;
        Ok(bm.map(|(note, sync, ao3_id)| UBookmark {
            work_id,
            note,
            sync_to_ao3: sync,
            ao3_bookmark_id: ao3_id.map(|id| id as i64).unwrap_or(-1),
        }))
    }

    pub fn get_all_bookmarks_full(&self) -> Result<Vec<UBookmark>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let ids = storage.get_bookmarks().map_err(AO3Error::from)?;
        let mut result = Vec::new();
        for work_id in ids {
            if let Some((note, sync, ao3_id)) = storage.get_bookmark_full(work_id).map_err(AO3Error::from)? {
                result.push(UBookmark {
                    work_id,
                    note,
                    sync_to_ao3: sync,
                    ao3_bookmark_id: ao3_id.map(|id| id as i64).unwrap_or(-1),
                });
            }
        }
        Ok(result)
    }

    pub async fn pull_bookmarks(&self, username: String) -> Result<Vec<UBookmark>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let mut all_bookmarks = Vec::new();
            let mut page = 1u32;
            loop {
                let c = client.read().await;
                let (listings, has_more) = c.fetch_user_bookmarks(&username, page)
                    .await
                    .map_err(AO3Error::from)?;
                drop(c); // release read lock before locking storage

                let s = storage.lock().await;
                for listing in &listings {
                    // Upsert bookmark with sync_to_ao3=true
                    let _ = s.add_bookmark(listing.work_id, Some(&listing.note), true);
                    let _ = s.set_ao3_bookmark_id(listing.work_id, listing.ao3_bookmark_id);
                    // Save work metadata if available
                    if let Some(ref ws) = listing.work_summary {
                        let _ = s.save_work(ws);
                    }
                    all_bookmarks.push(UBookmark {
                        work_id: listing.work_id,
                        note: listing.note.clone(),
                        sync_to_ao3: true,
                        ao3_bookmark_id: listing.ao3_bookmark_id as i64,
                    });
                }
                drop(s);

                if !has_more || listings.is_empty() {
                    break;
                }
                page += 1;
            }
            Ok(all_bookmarks)
        }).await
    }

    pub async fn push_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let note = {
                let s = storage.lock().await;
                s.get_bookmark_full(work_id)
                    .map_err(AO3Error::from)?
                    .map(|(note, _, _)| note)
                    .unwrap_or_default()
            };

            let c = client.read().await;
            let ao3_id = c.create_ao3_bookmark(work_id, &note)
                .await
                .map_err(AO3Error::from)?;
            drop(c);

            if let Some(id) = ao3_id {
                let s = storage.lock().await;
                s.set_ao3_bookmark_id(work_id, id).map_err(AO3Error::from)?;
            }

            Ok(true)
        }).await
    }

    pub async fn delete_ao3_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let ao3_id = {
                let s = storage.lock().await;
                s.get_ao3_bookmark_id(work_id).map_err(AO3Error::from)?
            };

            match ao3_id {
                Some(id) => {
                    let c = client.read().await;
                    let result = c.delete_ao3_bookmark(id)
                        .await
                        .map_err(AO3Error::from)?;
                    Ok(result)
                }
                None => Ok(false),
            }
        }).await
    }

    // -- Kudos --

    pub async fn leave_kudos(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            let params = vec![
                ("kudo[commentable_id]".to_string(), work_id.to_string()),
                ("kudo[commentable_type]".to_string(), "Work".to_string()),
            ];
            let url = format!("{}/kudos", crate::client::BASE_URL);
            let body = c.post_form(&url, &params).await.map_err(AO3Error::from)?;
            Ok(body.contains("left kudos") || body.contains("already left kudos"))
        }).await
    }

    pub async fn post_comment(&self, work_id: u64, chapter_id: u64, comment: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            let params = vec![
                ("comment[comment_content]".to_string(), comment),
            ];
            let url = if chapter_id == 0 {
                format!("{}/works/{}/comments", crate::client::BASE_URL, work_id)
            } else {
                format!("{}/chapters/{}/comments", crate::client::BASE_URL, chapter_id)
            };
            let body = c.post_form(&url, &params).await.map_err(AO3Error::from)?;
            Ok(body.contains("Comment created") || body.contains("was added"))
        }).await
    }

    pub async fn fetch_chapter_comments(&self, work_id: u64, chapter_id: u64, page: u32) -> Result<UCommentsPage, AO3Error> {
        let progress = self.register_progress("comments");
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let cp = c.fetch_comments_for_chapter(work_id, chapter_id, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            let s = storage.lock().await;
            for comment in &cp.comments {
                let _ = s.save_comment(0, chapter_id, comment);
            }
            let json_comments: Vec<CommentJson> = cp.comments.into_iter().map(CommentJson::from).collect();
            Ok(UCommentsPage {
                comments_json: serde_json::to_string(&json_comments).unwrap_or("[]".to_string()),
                current_page: cp.current_page,
                total_pages: cp.total_pages,
            })
        }).await;
        self.clear_progress("comments");
        result
    }

    pub async fn fetch_work_comments(&self, work_id: u64, page: u32) -> Result<UCommentsPage, AO3Error> {
        let progress = self.register_progress("comments");
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            c.set_active_progress(progress);
            let cp = c.fetch_comments_for_work(work_id, page).await.map_err(AO3Error::from)?;
            c.clear_active_progress();
            let s = storage.lock().await;
            for comment in &cp.comments {
                let _ = s.save_comment(work_id, 0, comment);
            }
            let json_comments: Vec<CommentJson> = cp.comments.into_iter().map(CommentJson::from).collect();
            Ok(UCommentsPage {
                comments_json: serde_json::to_string(&json_comments).unwrap_or("[]".to_string()),
                current_page: cp.current_page,
                total_pages: cp.total_pages,
            })
        }).await;
        self.clear_progress("comments");
        result
    }

    pub fn get_cached_comments(&self, work_id: u64, chapter_id: u64) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        let comments = storage.get_comments(work_id, chapter_id).map_err(AO3Error::from)?;
        let json_comments: Vec<CommentJson> = comments.into_iter().map(CommentJson::from).collect();
        Ok(serde_json::to_string(&json_comments).unwrap_or("[]".to_string()))
    }

    pub async fn post_reply(&self, parent_comment_id: u64, comment: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.post_reply(parent_comment_id, &comment).await.map_err(AO3Error::from)
        }).await
    }

    pub async fn fetch_image(&self, url: String) -> Result<Vec<u8>, AO3Error> {
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.fetch_image(&url).await.map_err(AO3Error::from)
        }).await
    }

    pub fn get_bookmarked_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_bookmarks().map_err(AO3Error::from)
    }

    // -- Reading Progress --

    pub fn save_progress(&self, work_id: u64, chapter: u32, position: f64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_progress(work_id, chapter, position).map_err(AO3Error::from)
    }

    pub fn delete_progress(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_progress(work_id).map_err(AO3Error::from)
    }

    pub fn get_progress(&self, work_id: u64) -> Result<Option<UReadingProgress>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let prog = storage.get_progress(work_id).map_err(AO3Error::from)?;
        Ok(prog.map(|(ch, pos)| UReadingProgress {
            work_id,
            chapter: ch,
            position: pos,
        }))
    }

    // -- History --

    pub fn add_to_history(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_to_history(work_id).map_err(AO3Error::from)
    }

    pub fn get_history(&self) -> Result<Vec<UHistoryEntry>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let entries = storage.get_history().map_err(AO3Error::from)?;
        Ok(entries.into_iter().map(|(id, ts)| UHistoryEntry {
            work_id: id,
            accessed_at: ts,
        }).collect())
    }

    pub fn clear_history(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_history().map_err(AO3Error::from)
    }

    // -- Subscription notifications --

    pub async fn fetch_subscriptions(&self, username: String) -> Result<Vec<USubscription>, AO3Error> {
        let progress = self.register_progress("subscriptions");
        let result = self.run_on_runtime(move |client, _storage| async move {
            let mut all_subs = Vec::new();
            let mut page = 1u32;
            loop {
                let c = client.read().await;
                c.set_active_progress(progress.clone());
                let (subs, has_more) = c.fetch_subscriptions(&username, page)
                    .await
                    .map_err(AO3Error::from)?;
                c.clear_active_progress();
                drop(c);
                all_subs.extend(subs.into_iter().map(USubscription::from));
                if !has_more { break; }
                page += 1;
            }
            Ok(all_subs)
        }).await;
        self.clear_progress("subscriptions");
        result
    }

    /// Main orchestrator: fetch all subscriptions, diff against snapshots,
    /// generate notifications for new works/chapters.
    pub async fn check_subscriptions(&self, username: String) -> Result<Vec<UNotification>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            // 1. Fetch all subscriptions (paginate if needed)
            let mut all_subs = Vec::new();
            let mut page = 1u32;
            loop {
                let c = client.read().await;
                let (subs, has_more) = c.fetch_subscriptions(&username, page)
                    .await
                    .map_err(AO3Error::from)?;
                drop(c);
                all_subs.extend(subs);
                if !has_more {
                    break;
                }
                page += 1;
            }

            // 2. Build fetch URLs for each subscription
            let base = crate::client::BASE_URL;
            let mut fetch_tasks: Vec<(String, String, String)> = Vec::new(); // (url, sub_type, sub_id)
            for sub in &all_subs {
                match sub.sub_type.as_str() {
                    "author" => {
                        let url = format!("{base}/users/{}/works", sub.id);
                        fetch_tasks.push((url, sub.sub_type.clone(), sub.id.clone()));
                    }
                    "work" => {
                        // For work subscriptions, fetch the work page to get current metadata
                        let url = format!("{base}/works/{}?view_adult=true", sub.id);
                        fetch_tasks.push((url, sub.sub_type.clone(), sub.id.clone()));
                    }
                    "series" => {
                        let url = format!("{base}/series/{}", sub.id);
                        fetch_tasks.push((url, sub.sub_type.clone(), sub.id.clone()));
                    }
                    _ => continue,
                }
            }

            // 3. Batch fetch concurrently
            let urls: Vec<String> = fetch_tasks.iter().map(|(url, _, _)| url.clone()).collect();
            let c = client.read().await;
            let results = c.fetch_concurrent(urls, 5).await;
            drop(c);

            // 4. Diff against snapshots and generate notifications
            let mut new_notifications = Vec::new();
            let s = storage.lock().await;

            for (i, result) in results.into_iter().enumerate() {
                let html = match result {
                    Ok(html) => html,
                    Err(_) => continue, // Skip failed fetches
                };

                let (sub_type, sub_id) = (&fetch_tasks[i].1, &fetch_tasks[i].2);
                let sub_name = all_subs.iter()
                    .find(|s| s.sub_type == *sub_type && s.id == *sub_id)
                    .map(|s| s.name.clone())
                    .unwrap_or_default();

                // Get old snapshots for diffing
                let old_snapshots = s.get_snapshots(sub_type, sub_id)
                    .unwrap_or_default();
                let old_map: std::collections::HashMap<u64, (u32, u64, String)> = old_snapshots
                    .into_iter()
                    .map(|(wid, ch, wc, du)| (wid, (ch, wc, du)))
                    .collect();

                match sub_type.as_str() {
                    "author" => {
                        let works = crate::parser::parse_work_listings(&html).unwrap_or_default();
                        for work in &works {
                            let author = work.authors.first().map(|a| a.as_str()).unwrap_or(&sub_name);
                            if let Some((old_ch, _old_wc, _old_du)) = old_map.get(&work.id) {
                                // Existing work — check for new chapters
                                if work.chapter_count > *old_ch {
                                    let msg = format!(
                                        "{} updated \"{}\" ({}ch -> {}ch)",
                                        author, work.title, old_ch, work.chapter_count
                                    );
                                    let notif_id = s.add_notification(
                                        "new_chapter", work.id, author, &work.title, &msg
                                    ).unwrap_or(-1);
                                    if notif_id > 0 {
                                        new_notifications.push(UNotification {
                                            id: notif_id,
                                            notif_type: "new_chapter".to_string(),
                                            work_id: work.id,
                                            author: author.to_string(),
                                            title: work.title.clone(),
                                            message: msg,
                                            created_at: String::new(),
                                            read: false,
                                        });
                                    }
                                }
                            } else {
                                // New work from this author
                                let msg = format!(
                                    "{} posted a new work: \"{}\"",
                                    author, work.title
                                );
                                let notif_id = s.add_notification(
                                    "new_work", work.id, author, &work.title, &msg
                                ).unwrap_or(-1);
                                if notif_id > 0 {
                                    new_notifications.push(UNotification {
                                        id: notif_id,
                                        notif_type: "new_work".to_string(),
                                        work_id: work.id,
                                        author: author.to_string(),
                                        title: work.title.clone(),
                                        message: msg,
                                        created_at: String::new(),
                                        read: false,
                                    });
                                }
                            }
                            // Update snapshot
                            let _ = s.save_snapshot(
                                sub_type, sub_id, work.id,
                                work.chapter_count, work.word_count, &work.date_updated,
                            );
                        }
                    }
                    "work" => {
                        // Parse as a work page to get chapter count
                        if let Ok((work, _chapters)) = crate::parser::parse_work_page(&html) {
                            let work_id: u64 = sub_id.parse().unwrap_or(0);
                            let author = work.authors.first().map(|a| a.as_str()).unwrap_or("Unknown");
                            if let Some((old_ch, _old_wc, _old_du)) = old_map.get(&work_id) {
                                if work.chapter_count > *old_ch {
                                    let msg = format!(
                                        "\"{}\" has new chapters ({}ch -> {}ch)",
                                        work.title, old_ch, work.chapter_count
                                    );
                                    let notif_id = s.add_notification(
                                        "new_chapter", work_id, author, &work.title, &msg
                                    ).unwrap_or(-1);
                                    if notif_id > 0 {
                                        new_notifications.push(UNotification {
                                            id: notif_id,
                                            notif_type: "new_chapter".to_string(),
                                            work_id,
                                            author: author.to_string(),
                                            title: work.title.clone(),
                                            message: msg,
                                            created_at: String::new(),
                                            read: false,
                                        });
                                    }
                                }
                            }
                            // Update snapshot (even for first check — no notification on first run)
                            let _ = s.save_snapshot(
                                sub_type, sub_id, work_id,
                                work.chapter_count, work.word_count, &work.date_updated,
                            );
                        }
                    }
                    "series" => {
                        let series_works = crate::parser::parse_series_page(&html).unwrap_or_default();
                        for (work_id, title, chapter_count, word_count) in &series_works {
                            if let Some((old_ch, _old_wc, _old_du)) = old_map.get(work_id) {
                                // Existing work in series — check chapter count
                                if *chapter_count > *old_ch {
                                    let msg = format!(
                                        "\"{}\" in series \"{}\" updated ({}ch -> {}ch)",
                                        title, sub_name, old_ch, chapter_count
                                    );
                                    let notif_id = s.add_notification(
                                        "new_chapter", *work_id, &sub_name, title, &msg
                                    ).unwrap_or(-1);
                                    if notif_id > 0 {
                                        new_notifications.push(UNotification {
                                            id: notif_id,
                                            notif_type: "new_chapter".to_string(),
                                            work_id: *work_id,
                                            author: sub_name.clone(),
                                            title: title.clone(),
                                            message: msg,
                                            created_at: String::new(),
                                            read: false,
                                        });
                                    }
                                }
                            } else {
                                // New work in series
                                let msg = format!(
                                    "New work in series \"{}\": \"{}\"",
                                    sub_name, title
                                );
                                let notif_id = s.add_notification(
                                    "new_work_in_series", *work_id, &sub_name, title, &msg
                                ).unwrap_or(-1);
                                if notif_id > 0 {
                                    new_notifications.push(UNotification {
                                        id: notif_id,
                                        notif_type: "new_work_in_series".to_string(),
                                        work_id: *work_id,
                                        author: sub_name.clone(),
                                        title: title.clone(),
                                        message: msg,
                                        created_at: String::new(),
                                        read: false,
                                    });
                                }
                            }
                            // Update snapshot
                            let _ = s.save_snapshot(
                                sub_type, sub_id, *work_id,
                                *chapter_count, *word_count, "",
                            );
                        }
                    }
                    _ => {}
                }
            }

            // 5. Update last check time
            let now = chrono_now();
            let _ = s.set_last_check_time(&now);
            drop(s);

            Ok(new_notifications)
        }).await
    }

    pub async fn check_inbox(&self, username: String) -> Result<Vec<UNotification>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;

            // Fetch first page
            let mut inbox = c.fetch_inbox(&username, 1).await.map_err(AO3Error::from)?;
            let mut all_items = inbox.items;

            // Fetch remaining pages if paginated
            let mut page = 2u32;
            while inbox.has_next_page {
                inbox = c.fetch_inbox(&username, page).await.map_err(AO3Error::from)?;
                all_items.extend(inbox.items);
                page += 1;
                if page > 10 { break; }
            }
            drop(c);

            let s = storage.lock().await;

            // Get the last seen inbox comment ID
            let last_seen_id: u64 = s.get_state("last_inbox_comment_id")
                .unwrap_or(None)
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);

            let mut new_notifications = Vec::new();
            let mut max_id: u64 = last_seen_id;

            for item in &all_items {
                if item.comment_id > max_id {
                    max_id = item.comment_id;
                }

                // Only notify for unread items newer than last seen
                if !item.is_unread || item.comment_id <= last_seen_id {
                    continue;
                }

                // Skip on first run (no last_seen means we haven't checked before)
                if last_seen_id == 0 {
                    continue;
                }

                let msg = format!(
                    "{} commented on {}",
                    item.author, item.work_reference
                );

                let notif_id = s.add_notification(
                    "inbox_comment",
                    item.comment_id,
                    &item.author,
                    &item.work_reference,
                    &msg,
                ).unwrap_or(-1);

                if notif_id > 0 {
                    new_notifications.push(UNotification {
                        id: notif_id,
                        notif_type: "inbox_comment".to_string(),
                        work_id: item.comment_id,
                        author: item.author.clone(),
                        title: item.work_reference.clone(),
                        message: msg,
                        created_at: String::new(),
                        read: false,
                    });
                }
            }

            // Update last seen ID
            if max_id > 0 {
                let _ = s.set_state("last_inbox_comment_id", &max_id.to_string());
            }

            Ok(new_notifications)
        }).await
    }

    pub async fn fetch_inbox(&self, username: String, page: u32) -> Result<String, AO3Error> {
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            let inbox = c.fetch_inbox(&username, page).await.map_err(AO3Error::from)?;
            let items: Vec<serde_json::Value> = inbox.items.into_iter().map(|item| {
                serde_json::json!({
                    "comment_id": item.comment_id,
                    "author": item.author,
                    "author_url": item.author_url.unwrap_or_default(),
                    "avatar_url": item.avatar_url.unwrap_or_default(),
                    "work_reference": item.work_reference,
                    "work_url": item.work_url.unwrap_or_default(),
                    "posted_at": item.posted_at,
                    "is_unread": item.is_unread,
                    "content_json": serde_json::to_string(&item.content).unwrap_or("[]".to_string()),
                })
            }).collect();
            let result = serde_json::json!({
                "items": items,
                "unread_count": inbox.unread_count,
                "has_next_page": inbox.has_next_page,
            });
            Ok(serde_json::to_string(&result).unwrap_or("{}".to_string()))
        }).await
    }

    /// Get all notifications from storage.
    pub fn get_notifications(&self) -> Result<Vec<UNotification>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_notifications().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, notif_type, work_id, author, title, message, created_at, read)| {
            UNotification { id, notif_type, work_id, author, title, message, created_at, read }
        }).collect())
    }

    /// Get count of unread notifications.
    pub fn get_unread_notification_count(&self) -> Result<u32, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_unread_count().map_err(AO3Error::from)
    }

    /// Mark a single notification as read.
    pub fn mark_notification_read(&self, notification_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_notification_read(notification_id).map_err(AO3Error::from)
    }

    /// Mark all notifications as read.
    pub fn mark_all_notifications_read(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_all_read().map_err(AO3Error::from)
    }

    /// Delete all read notifications.
    pub fn clear_read_notifications(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_read_notifications().map_err(AO3Error::from)
    }

    /// Get the last time subscriptions were checked.
    pub fn get_last_subscription_check(&self) -> Result<Option<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_last_check_time().map_err(AO3Error::from)
    }

    // -- Session Cache --

    pub fn set_session_cache(&self, key: String, data: String, session_id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.set_cache(&key, &data, &session_id).map_err(AO3Error::from)
    }

    pub fn get_session_cache(&self, key: String, session_id: String) -> Result<Option<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_cache(&key, &session_id).map_err(AO3Error::from)
    }

    pub fn invalidate_session_cache(&self, key: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.invalidate_cache(&key).map_err(AO3Error::from)
    }

    pub fn clear_all_session_cache(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_session_cache().map_err(AO3Error::from)
    }

    // -- Debug Log --

    pub fn get_logs(&self, limit: u32) -> Result<Vec<ULogEntry>, AO3Error> {
        crate::with_log_db(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, timestamp, level, tag, message FROM debug_log ORDER BY id DESC LIMIT ?1"
            ).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            let rows = stmt.query_map(rusqlite::params![limit as i64], |row| {
                Ok(ULogEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    level: row.get(2)?,
                    tag: row.get(3)?,
                    message: row.get(4)?,
                })
            }).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| AO3Error::Storage { message: e.to_string() })
        }).unwrap_or_else(|| Ok(Vec::new()))
         .map(|mut v| { v.reverse(); v })
    }

    pub fn dump_logs(&self, limit: u32) -> Result<String, AO3Error> {
        let logs = self.get_logs(limit)?;
        let mut output = String::new();
        for e in &logs {
            output.push_str(&format!("[{}] {} [{}] {}: {}\n", e.id, e.timestamp, e.level, e.tag, e.message));
        }
        Ok(output)
    }

    pub fn clear_logs(&self) -> Result<(), AO3Error> {
        crate::with_log_db(|conn| {
            conn.execute("DELETE FROM debug_log", [])
                .map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            Ok(())
        }).unwrap_or(Ok(()))
    }

    pub fn write_log(&self, level: String, tag: String, message: String) -> Result<(), AO3Error> {
        crate::dlog(&level, &tag, &message);
        Ok(())
    }

    // -- Request Audit Log --

    /// Persist any buffered requests, then return the most recent `limit` rows
    /// (newest first) from the encrypted database.
    pub fn get_request_log(&self, limit: u32) -> Result<Vec<URequestLogEntry>, AO3Error> {
        self.flush_request_log();
        let storage = self.storage.blocking_lock();
        let rows = storage.get_request_logs(limit).map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, started, method, url, status, dur, req_b, resp_b, error, payload)| {
            URequestLogEntry {
                id, started_ms: started as i64, method, url, status,
                duration_ms: dur as i64, request_bytes: req_b as i64,
                response_bytes: resp_b as i64, error, payload,
            }
        }).collect())
    }

    pub fn clear_request_log(&self) -> Result<(), AO3Error> {
        let _ = crate::client::drain_request_records();
        let storage = self.storage.blocking_lock();
        storage.clear_request_logs().map_err(AO3Error::from)
    }

    /// Drain the in-memory request buffer into the database. Called after every
    /// runtime operation so requests are durable even without the UI open.
    fn flush_request_log(&self) {
        let records = crate::client::drain_request_records();
        if records.is_empty() { return; }
        let tuples: Vec<_> = records.into_iter().map(|r| (
            r.started_at_ms, r.method, r.url, r.status, r.duration_ms,
            r.request_bytes, r.response_bytes, r.error, r.payload,
        )).collect();
        if let Ok(storage) = self.storage.try_lock() {
            let _ = storage.insert_request_logs(&tuples);
        } else {
            // Storage busy — put them back so the next flush persists them.
            for t in tuples.into_iter().rev() {
                crate::client::push_request_record(crate::client::RequestRecord {
                    started_at_ms: t.0, method: t.1, url: t.2, status: t.3,
                    duration_ms: t.4, request_bytes: t.5, response_bytes: t.6,
                    error: t.7, payload: t.8,
                });
            }
        }
    }
}

/// Generate a timestamp string without pulling in the chrono crate.
/// Uses a simple approach based on SystemTime.
fn chrono_now() -> String {
    use std::time::SystemTime;
    match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => {
            let secs = d.as_secs();
            // Simple ISO-ish timestamp: just use the unix timestamp as a string
            // The actual formatting doesn't matter much since it's for display only
            format!("{secs}")
        }
        Err(_) => "0".to_string(),
    }
}

// scaffolding is in lib.rs
