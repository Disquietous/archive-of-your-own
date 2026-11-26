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
//!
//! The queue can be paused (`set_content_queue_paused`). A pause takes
//! effect between works: the work in flight — every chapter and image
//! request it needs — runs to its end first, and the status reads
//! `Pausing` until it has. The pause lasts for the session; a launch
//! starts with the queue running.

use super::*;
use crate::storage::content_queue::{ChapterSpan, CONTENT_QUEUED};
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

/// The user's pause. Process-wide, so it carries over a library
/// replacement's fresh worker.
static PAUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Wakes a paused worker when the pause is lifted.
static RESUMED: tokio::sync::Notify = tokio::sync::Notify::const_new();
/// The work in flight (0 = none) and when it started (epoch seconds).
static CURRENT_WORK: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static CURRENT_STARTED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
/// The worker's last pass found the network gate closed.
static BLOCKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// What the content queue's worker is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ContentQueueState {
    /// Running, with nothing due right now.
    Idle,
    /// Downloading a work.
    Working,
    /// Paused by the user, with a work still in flight: it is finished
    /// in full, then nothing further starts.
    Pausing,
    /// Paused by the user; nothing is in flight and nothing starts.
    Paused,
    /// Nothing can be sent in the current privacy mode; the worker waits.
    Blocked,
}

/// The worker's status, for the monitor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UContentQueueStatus {
    pub state: ContentQueueState,
    /// The user's pause, whether or not the in-flight work has finished.
    pub paused: bool,
    /// The work in flight, if any.
    pub current_work_id: Option<u64>,
    /// When the in-flight work started, epoch seconds.
    pub current_started_at: Option<u64>,
}

/// One queued work, for the monitor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UContentQueueItem {
    pub work_id: u64,
    pub title: String,
    /// The display name of the work's source.
    pub source_name: String,
    /// The chapters asked for, by number: `first_chapter` 0 = from the
    /// first, `last_chapter` 0 = to the last; both 0 = the whole work.
    pub first_chapter: u32,
    pub last_chapter: u32,
    /// UTC "YYYY-MM-DD HH:MM:SS".
    pub queued_at: String,
    /// Failed downloads so far, out of `max_attempts`; at the maximum the
    /// work is left alone until it changes again.
    pub attempts: u32,
    pub max_attempts: u32,
    /// Epoch seconds the work is held back until; 0 = not held.
    pub retry_at: u64,
    /// Why it was last held back or failed; empty when it never was.
    pub last_error: String,
}

fn queue_state(paused: bool, working: bool, blocked: bool) -> ContentQueueState {
    match (paused, working) {
        (true, true) => ContentQueueState::Pausing,
        (true, false) => ContentQueueState::Paused,
        (false, true) => ContentQueueState::Working,
        (false, false) if blocked => ContentQueueState::Blocked,
        (false, false) => ContentQueueState::Idle,
    }
}

fn queue_changed() {
    crate::events::emit(crate::events::CoreEvent::ContentQueueChanged);
}

/// Marks a work in flight for as long as it lives, so the mark clears
/// however the download ends — the worker being aborted included.
struct InFlight;

impl InFlight {
    fn begin(work_id: u64) -> Self {
        CURRENT_STARTED.store(crate::timefmt::epoch_now(), std::sync::atomic::Ordering::Relaxed);
        CURRENT_WORK.store(work_id, std::sync::atomic::Ordering::Relaxed);
        // A fresh list of requests for this work.
        crate::steps::clear();
        queue_changed();
        InFlight
    }
}

impl Drop for InFlight {
    fn drop(&mut self) {
        CURRENT_WORK.store(0, std::sync::atomic::Ordering::Relaxed);
        crate::steps::clear();
        queue_changed();
    }
}

#[uniffi::export]
impl AO3App {
    /// What the content queue's worker is doing right now. Reads no
    /// storage.
    pub fn content_queue_status(&self) -> UContentQueueStatus {
        use std::sync::atomic::Ordering::Relaxed;
        let paused = PAUSED.load(Relaxed);
        let current = Some(CURRENT_WORK.load(Relaxed)).filter(|id| *id != 0);
        UContentQueueStatus {
            state: queue_state(paused, current.is_some(), BLOCKED.load(Relaxed)),
            paused,
            current_work_id: current,
            current_started_at: current.map(|_| CURRENT_STARTED.load(Relaxed)),
        }
    }

    /// Everything queued, in the order the worker gets to it: due works,
    /// then held-back ones, then the ones it gave up on. The work in
    /// flight is still listed (it leaves the queue when it finishes).
    pub fn content_queue_items(&self) -> Result<Vec<UContentQueueItem>, AO3Error> {
        let s = self.storage.blocking_lock();
        let rows = s.content_queue_items(crate::timefmt::epoch_now()).map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|row| {
            let source_name = s.work_ref(row.work_id)
                .and_then(|external| self.sources.by_id(&external.source))
                .map(|source| source.capabilities().name.clone())
                .unwrap_or_default();
            let title = s.get_work(row.work_id).ok().flatten().map(|w| w.title)
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| format!("Work {}", row.work_id));
            UContentQueueItem {
                work_id: row.work_id,
                title,
                source_name,
                first_chapter: if row.span.is_whole() { 0 } else { row.span.first },
                last_chapter: row.span.last,
                queued_at: row.queued_at,
                attempts: row.attempts,
                max_attempts: crate::storage::content_queue::CONTENT_MAX_ATTEMPTS,
                retry_at: row.retry_at,
                last_error: row.last_error,
            }
        }).collect())
    }

    /// Queue a work's content for the background download: the whole
    /// work when neither bound is given, else the chapters numbered
    /// `first_chapter` (None = from the first) to `last_chapter` (None =
    /// to the last), both included, in either order. A work already queued keeps its one
    /// entry, widened to cover both requests. A chapter whose text the
    /// library holds is not fetched again either way.
    pub fn queue_work_content(&self, work_id: u64, first_chapter: Option<u32>, last_chapter: Option<u32>) -> Result<(), AO3Error> {
        let mut span = ChapterSpan { first: first_chapter.unwrap_or(0), last: last_chapter.unwrap_or(0) };
        // Bounds given the wrong way round name the same chapters.
        if span.last != 0 && span.first > span.last {
            span = ChapterSpan { first: span.last, last: span.first };
        }
        let s = self.storage.blocking_lock();
        if s.get_work(work_id).map_err(AO3Error::from)?.is_none() {
            return Err(AO3Error::NotFound { message: format!("no work with id {work_id}") });
        }
        s.queue_content_span(work_id, span).map_err(AO3Error::from)
    }

    /// The requests the work in flight needs, as far as they are known,
    /// under names a reader understands: the chapter list, each chapter,
    /// each page of a chapter, each image. Empty when nothing is in
    /// flight; a finished work's list is cleared. Reads no storage.
    pub fn content_queue_steps(&self) -> Vec<crate::steps::UContentQueueStep> {
        crate::steps::snapshot()
    }

    /// Pause or resume the content queue. A pause lets the work in
    /// flight finish in full — every request it needs — and starts
    /// nothing after it; `content_queue_status` reads `Pausing` until
    /// then. Queued works keep their place. Lasts for the session.
    pub fn set_content_queue_paused(&self, paused: bool) {
        if PAUSED.swap(paused, std::sync::atomic::Ordering::Relaxed) == paused {
            return;
        }
        log_info!("content_queue", "{}", if paused { "Paused by the user" } else { "Resumed by the user" });
        if !paused {
            RESUMED.notify_one();
        }
        queue_changed();
    }
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
            // A pause holds here, between works: the pass below always
            // runs a work it started to its end.
            if PAUSED.load(std::sync::atomic::Ordering::Relaxed) {
                if storage.strong_count() == 0 { return }
                let _ = tokio::time::timeout(POLL, RESUMED.notified()).await;
                continue;
            }
            let Some(strong) = storage.upgrade() else { return };
            let step = run_next(&client, &strong, &registry).await;
            flush_request_log_to(&strong);
            drop(strong);
            let blocked = matches!(step, Step::Blocked);
            if BLOCKED.swap(blocked, std::sync::atomic::Ordering::Relaxed) != blocked {
                queue_changed();
            }
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
    let (work_id, span) = {
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
            queue_changed();
            return Step::Skipped;
        };
        // A source the current privacy mode can't reach: hold the work
        // back so the works behind it are not kept waiting.
        if let Err(e) = check_reachable(&source) {
            log_db("defer_content_item",
                   s.defer_content_item(work_id, now + UNREACHABLE_RETRY_SECS, &format!("{e}"), false));
            queue_changed();
            return Step::Skipped;
        }
        (work_id, s.content_item_span(work_id).ok().flatten().unwrap_or(ChapterSpan::WHOLE))
    };
    // Ask the privacy policy before sending anything: a refused request
    // is reported to the user, and nobody asked for this one.
    let is_tor = client.read().await.transport().is_tor();
    if crate::client::privacy::gate(is_tor).is_err() {
        return Step::Blocked;
    }

    if span.is_whole() {
        log_info!("content_queue", "Fetching the content of work {work_id}");
    } else {
        log_info!("content_queue", "Fetching chapters {} to {} of work {work_id}",
                  span.first.max(1), if span.last == 0 { "the last".to_string() } else { span.last.to_string() });
    }
    let in_flight = InFlight::begin(work_id);
    // Unattended: a human check the user just dismissed is not raised
    // again for a download nobody is waiting on.
    let result = crate::client::clearance::unattended(crate::steps::recording(async {
        let mut result = super::works::download_work(client.clone(), storage.clone(), registry.clone(), work_id, span).await;
        if let Ok(requested) = &mut result {
            // The chapters are in: their embedded images complete the work.
            // A skipped or failed image never fails the download.
            let cap = IMAGE_CAP_BYTES.load(std::sync::atomic::Ordering::Relaxed);
            match super::works::prefetch_work_images(client.clone(), storage.clone(), work_id, cap, span).await {
                Ok(fetched) => *requested |= fetched > 0,
                Err(e) => { log_error!("content_queue", "Image prefetch for work {work_id} failed: {e}"); }
            }
        }
        result
    })).await;
    let s = storage.lock().await;
    // The queue row is settled below before the monitor is told the work
    // is no longer in flight.
    let _in_flight = in_flight;
    match result {
        Ok(requested) => {
            // A range leaves the work downloaded only when nothing else
            // of it is missing.
            let complete = span.is_whole() || super::works::work_content_complete(&s, work_id);
            if complete {
                log_db("mark_downloaded", s.mark_downloaded(work_id));
            }
            log_db("finish_content_item", s.finish_content_item(work_id));
            drop(s);
            log_info!("content_queue", "Work {work_id}: {}{}",
                      if complete { "fully in the library" } else { "the chapters asked for are in the library" },
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
    fn a_pause_waits_for_the_work_in_flight() {
        assert_eq!(queue_state(true, true, false), ContentQueueState::Pausing);
        assert_eq!(queue_state(true, false, false), ContentQueueState::Paused);
        assert_eq!(queue_state(true, false, true), ContentQueueState::Paused);
        assert_eq!(queue_state(false, true, true), ContentQueueState::Working);
        assert_eq!(queue_state(false, false, true), ContentQueueState::Blocked);
        assert_eq!(queue_state(false, false, false), ContentQueueState::Idle);
    }

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
