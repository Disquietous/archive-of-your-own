//! The content queue's worker: a background task on the app's runtime
//! that fetches the full content of every queued work, one work at a
//! time.
//!
//! A work is queued by the save that adds or changes it
//! (`Storage::save_work`), so whatever saved it — a What's New check, a
//! listing, a search — carries on without waiting. Each queued work gets
//! the download a user's "Download for offline" runs (`works::download_work`):
//! the same fetch plan, the same recovery engine, the same shared pacer
//! between requests and between works, then the work's embedded images
//! (`works::prefetch_work_images`). A finished work is marked downloaded
//! and announced with `CoreEvent::WorkContentSaved`.
//!
//! The worker never sends into a closed network gate: while the privacy
//! policy would refuse a request it waits, and the queue keeps.

use super::*;
use crate::storage::content_queue::CONTENT_QUEUED;
use std::time::Duration;

/// How long the worker waits before looking again when the queue is
/// empty (a queued work wakes it sooner) or the network gate is closed.
const POLL: Duration = Duration::from_secs(60);
/// A work whose source the current privacy mode can't reach is looked at
/// again after this long; it costs the work no attempt.
const UNREACHABLE_RETRY_SECS: u64 = 15 * 60;
/// Wait after a work's first failed download; doubles with each further
/// failure up to `RETRY_MAX_SECS`.
const RETRY_BASE_SECS: u64 = 5 * 60;
const RETRY_MAX_SECS: u64 = 60 * 60;

/// The per-image size cap the worker prefetches under, in bytes; 0 = no
/// limit. It is a device setting the UI owns, handed over with
/// `set_image_prefetch_cap`; until then, the setting's default of 2 MB.
static IMAGE_CAP_BYTES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(2 * 1_048_576);

/// Tell the core the per-image size cap for images it fetches on its
/// own (the content queue's prefetch): `max_bytes`, 0 = no limit. The
/// UI calls this at launch and whenever the setting changes.
#[uniffi::export]
pub fn set_image_prefetch_cap(max_bytes: u64) {
    IMAGE_CAP_BYTES.store(max_bytes, std::sync::atomic::Ordering::Relaxed);
}

/// What one pass over the queue did.
enum Step {
    /// A work was downloaded (or its download failed): requests went out.
    Worked,
    /// A queued work was settled without a request: dropped, held back,
    /// or already whole in the library.
    Skipped,
    /// Nothing is due.
    Idle,
    /// Nothing can be sent right now.
    Blocked,
}

/// Seconds to hold a work back after its `attempts`-th failure.
fn retry_delay_secs(attempts: u32) -> u64 {
    RETRY_BASE_SECS
        .saturating_mul(1u64 << attempts.saturating_sub(1).min(16))
        .min(RETRY_MAX_SECS)
}

/// Spawn the worker for one opened database. It holds only a `Weak` to
/// the storage between works, and the returned handle aborts it — the
/// owning `AO3App` does so when it drops.
pub(super) fn spawn_worker(
    handle: &tokio::runtime::Handle,
    storage: std::sync::Weak<Mutex<Storage>>,
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    registry: Arc<crate::source::SourceRegistry>,
) -> tokio::task::AbortHandle {
    handle.spawn(async move {
        // Nothing is looked at, judged or sent before the app has handed
        // over its privacy settings.
        crate::client::privacy::wait_established().await;
        loop {
            let Some(strong) = storage.upgrade() else { return };
            let step = run_next(&client, &strong, &registry).await;
            flush_request_log_to(&strong);
            drop(strong);
            match step {
                // The same pause that spaces the works of "Download all".
                Step::Worked => crate::client::pacing::request_gap().await,
                Step::Skipped => {}
                Step::Idle => {
                    let _ = tokio::time::timeout(POLL, CONTENT_QUEUED.notified()).await;
                }
                Step::Blocked => tokio::time::sleep(POLL).await,
            }
        }
    }).abort_handle()
}

/// Take the next due work and download it.
async fn run_next(
    client: &Arc<tokio::sync::RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    registry: &Arc<crate::source::SourceRegistry>,
) -> Step {
    let now = crate::timefmt::epoch_now();
    let work_id = {
        let s = storage.lock().await;
        let work_id = match s.next_content_item(now) {
            Ok(Some(id)) => id,
            Ok(None) => return Step::Idle,
            Err(e) => {
                log_error!("content_queue", "reading the queue failed: {e}");
                return Step::Idle;
            }
        };
        // A work that is gone, or whose source serves nothing to fetch
        // (an imported file), leaves the queue.
        let source = s.work_ref(work_id).and_then(|external| registry.by_id(&external.source));
        let Some(source) = source.filter(|source| !source.library_only()) else {
            log_db("finish_content_item", s.finish_content_item(work_id));
            return Step::Skipped;
        };
        // A source the current privacy mode can't reach: hold the work
        // back so the works behind it are not kept waiting.
        if let Err(e) = check_reachable(&source) {
            log_db("defer_content_item",
                   s.defer_content_item(work_id, now + UNREACHABLE_RETRY_SECS, &format!("{e}"), false));
            return Step::Skipped;
        }
        work_id
    };
    // Ask the privacy policy before sending anything: a refused request
    // is reported to the user, and nobody asked for this one.
    let is_tor = client.read().await.transport().is_tor();
    if crate::client::privacy::gate(is_tor).is_err() {
        return Step::Blocked;
    }

    log_info!("content_queue", "Fetching the content of work {work_id}");
    // Unattended: a human check the user just dismissed is not raised
    // again for a download nobody is waiting on.
    let result = crate::client::clearance::unattended(async {
        let mut result = super::works::download_work(client.clone(), storage.clone(), registry.clone(), work_id).await;
        if let Ok(requested) = &mut result {
            // The chapters are in: their embedded images complete the work.
            // A skipped or failed image never fails the download.
            let cap = IMAGE_CAP_BYTES.load(std::sync::atomic::Ordering::Relaxed);
            match super::works::prefetch_work_images(client.clone(), storage.clone(), work_id, cap).await {
                Ok(fetched) => *requested |= fetched > 0,
                Err(e) => { log_error!("content_queue", "Image prefetch for work {work_id} failed: {e}"); }
            }
        }
        result
    }).await;
    let s = storage.lock().await;
    match result {
        Ok(requested) => {
            log_db("mark_downloaded", s.mark_downloaded(work_id));
            log_db("finish_content_item", s.finish_content_item(work_id));
            drop(s);
            log_info!("content_queue", "Work {work_id} is fully in the library{}",
                      if requested { "" } else { " (nothing was missing)" });
            crate::events::emit(crate::events::CoreEvent::WorkContentSaved { work_id });
            // Nothing sent, nothing to space the next work from.
            if requested { Step::Worked } else { Step::Skipped }
        }
        // The connection went away mid-download: the work keeps its
        // place and costs no attempt.
        Err(AO3Error::NetworkDisabled) => Step::Blocked,
        Err(e) => {
            let attempts = s.content_item_attempts(work_id).ok().flatten().unwrap_or(0) + 1;
            let wait = retry_delay_secs(attempts);
            log_error!("content_queue",
                "Content fetch for work {work_id} failed (attempt {attempts} of {}), next try in {wait}s: {e}",
                crate::storage::content_queue::CONTENT_MAX_ATTEMPTS);
            log_db("defer_content_item",
                   s.defer_content_item(work_id, crate::timefmt::epoch_now() + wait, &format!("{e}"), true));
            Step::Worked
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_delay_doubles_to_the_cap() {
        assert_eq!(retry_delay_secs(1), 5 * 60);
        assert_eq!(retry_delay_secs(2), 10 * 60);
        assert_eq!(retry_delay_secs(3), 20 * 60);
        assert_eq!(retry_delay_secs(4), 40 * 60);
        assert_eq!(retry_delay_secs(5), 60 * 60);
        assert_eq!(retry_delay_secs(40), 60 * 60);
    }
}
