//! Lock discipline invariant: `client.blocking_read()` and
//! `storage.blocking_lock()` are safe ONLY on a thread that is not running
//! on `_runtime` — that's exactly the synchronous `#[uniffi::export]`
//! methods in this module, which UniFFI calls directly on the thread Swift
//! invoked them from. Every `blocking_*` call site in `core/src/api/` is one
//! of these plain `fn` exports; none are reachable from `run_on_runtime` or
//! any other code running on `_runtime`, so this holds today.
//!
//! Never mix `blocking_*` and async (`.lock().await` / `.read().await`)
//! acquisition of the same mutex within a single call path, and never call a
//! `blocking_*` method — directly or transitively — from inside a
//! `run_on_runtime` closure or any other future spawned on `_runtime`: both
//! panic or deadlock, since tokio's blocking acquisition methods assume they
//! are not themselves running inside the runtime they belong to.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::client::AO3Client;
use crate::error::AppError;
use crate::models::*;
use crate::storage::Storage;

mod account;
mod capabilities;
mod connection;
mod error;
mod helpers;
mod library;
mod listing;
mod logs;
mod prefs;
mod records;
mod recovery;
mod social;
mod whats_new;
mod works;

pub use self::capabilities::{CapabilityError, PlatformCapabilities};
pub use self::error::*;
pub use self::records::*;
pub(crate) use self::recovery::with_recovery;
pub use self::recovery::RetrySafety;
pub use crate::events::OpKind;
use self::helpers::*;

#[derive(uniffi::Object)]
pub struct AO3App {
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    state_dir: String,
    timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    /// Every in-flight operation, keyed by a process-unique id. A single
    /// Option slot here made overlapping operations uncancelable (only the
    /// latest was tracked) and `is_request_active` inaccurate.
    active_tasks: Arc<std::sync::Mutex<std::collections::HashMap<u64, tokio::task::AbortHandle>>>,
    next_task_id: Arc<std::sync::atomic::AtomicU64>,
    /// Lock-free mirrors of connection facts the UI polls constantly.
    /// `blocking_read()` on the client RwLock can stall the main thread:
    /// tokio's RwLock is write-preferring, so a queued writer
    /// (connect/rotate/disconnect) blocks new readers until in-flight
    /// fetches release their read guards — up to a full Tor round-trip.
    tor_connected: Arc<std::sync::atomic::AtomicBool>,
    socks_port: Arc<std::sync::atomic::AtomicU32>,
    /// Per-route timeout overrides, loaded from storage at open and shared
    /// into every client (current and future) — see
    /// `client::routes::ROUTES` for the catalog.
    route_timeouts: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>,
    _runtime: Arc<tokio::runtime::Runtime>,
    /// One age-based works census per check cycle: keeps a fresh install (or
    /// a long-idle app) from crawling every subscription's full listing in a
    /// single cycle. Evidence-based censuses (count mismatches) ignore this.
    census_cycle_used: Arc<std::sync::atomic::AtomicBool>,
}

impl AO3App {
    /// Shared block/mute toggle: flips the state AO3-side (kind is
    /// "blocked" or "muted") and mirrors the result onto the user's row.
    async fn toggle_user_moderation(&self, target: String, me: String, kind: &'static str)
        -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (target, _) = split_author_byline(&target);
            let (current, record_id) = {
                let s = storage.lock().await;
                s.get_user_profile(&target).ok().flatten()
                    .map(|p| if kind == "blocked" { (p.blocked, p.block_ao3_id) }
                             else { (p.muted, p.mute_ao3_id) })
                    .unwrap_or((false, None))
            };
            let want = !current;

            let (target_for_fetch, me_for_fetch) = (target.clone(), me.clone());
            let (state, new_record) = with_recovery(client, storage.clone(), OpKind::Fetch { label: "moderation".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let (target, me) = (target_for_fetch.clone(), me_for_fetch.clone());
                    let record_id = record_id.clone();
                    async move {
                        client.read().await.set_user_moderation(&me, &target, kind, want, record_id.as_deref())
                            .await.map_err(AO3Error::from)
                    }
                }).await?;

            let s = storage.lock().await;
            if kind == "blocked" {
                log_db("set_user_block_state", s.set_user_block_state(&target, state, new_record.as_deref()));
            } else {
                log_db("set_user_mute_state", s.set_user_mute_state(&target, state, new_record.as_deref()));
            }
            Ok(state)
        }).await
    }

    /// Shared harness for every one-page listing fetch (browse, search, tag,
    /// author, series): runs `fetch` through the recovery engine (`key`
    /// doubles as its `OpKind::Fetch` label — the same key these screens
    /// already read their loading state by), caches every returned work
    /// (save_work also harvests tags for autocomplete). `fetch` returns
    /// (works, has_next_page, total_pages, total_works) and may run more
    /// than once — see `with_recovery`.
    async fn run_listing_fetch<F, Fut>(&self, key: &str, fetch: F) -> Result<UPagedWorks, AO3Error>
    where
        F: Fn(Arc<tokio::sync::RwLock<AO3Client>>) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<(Vec<WorkSummary>, bool, u32, Option<u32>), AO3Error>> + Send + 'static,
    {
        let kind = OpKind::Fetch { label: key.to_string() };
        self.run_on_runtime(move |client, storage| async move {
            let (works, has_next, total, found) =
                with_recovery(client, storage.clone(), kind, RetrySafety::Idempotent, fetch).await?;
            let s = storage.lock().await;
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            for w in &works { log_db("save_work", s.save_work(w)); }
            log_db("commit listing save", tx.commit());
            Ok(UPagedWorks {
                works: works.into_iter().map(UWorkSummary::from).collect(),
                has_next_page: has_next,
                total_pages: total,
                total_works: found,
            })
        }).await
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
        let task_id = self.next_task_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        { self.active_tasks.lock().unwrap().insert(task_id, abort); }

        // Await the JoinHandle — this works from any async context
        let result = handle.await;

        { self.active_tasks.lock().unwrap().remove(&task_id); }

        // Persist any requests this operation made (durable audit log).
        self.flush_request_log();

        let outcome = match result {
            Ok(r) => r,
            Err(e) if e.is_cancelled() => Err(AO3Error::Cancelled),
            Err(e) => Err(AO3Error::Network { message: e.to_string() }),
        };

        // AO3 rejected the session — the cached token is dead. Purge it so
        // the UI can prompt for a manual sign-in. Purge failures are logged
        // and swallowed; they must not mask the SessionExpired error.
        if matches!(outcome, Err(AO3Error::SessionExpired)) {
            self.purge_expired_session().await;
        }

        outcome
    }

    /// Clear the dead auth cookies from the live jar and every persisted
    /// copy (active account row + legacy app_state key). Never sends a
    /// network request — expiry is only ever detected from a normal
    /// request's rejection.
    async fn purge_expired_session(&self) {
        self.client.read().await.clear_auth_cookies();
        let s = self.storage.lock().await;
        if let Ok(Some((id, _, _))) = s.get_active_account() {
            log_db("clear_account_cookies", s.clear_account_cookies(&id));
        }
        log_db("set_state", s.set_state("ao3_session_cookies", ""));
        log_info!("auth", "Session expired — cleared cached token; user must sign in again");
    }

    fn flush_request_log(&self) {
        let records = crate::client::drain_request_records();
        if records.is_empty() { return; }
        let tuples: Vec<_> = records.into_iter().map(|r| (
            r.started_at_ms, r.method, r.url, r.status, r.duration_ms,
            r.request_bytes, r.response_bytes, r.error, r.payload,
        )).collect();
        if let Ok(storage) = self.storage.try_lock() {
            log_db("insert_request_logs", storage.insert_request_logs(&tuples));
        } else {
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
