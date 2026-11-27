//! The content queue's worker: a background task on the app's runtime
//! that fetches the full content of every queued work.
//!
//! Each source is its own lane. A lane downloads one work at a time, in
//! the queue's order, and waits the shared pause after it before its
//! next; the lanes of different sources run side by side. So a queue
//! holding works of four sources has four downloads in flight, and a
//! queue holding works of one source has one — never two requests to the
//! same site at once.
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
//! effect between works: every work in flight — each chapter and image
//! request it needs — runs to its end first, and the status reads
//! `Pausing` until they have. The pause lasts for the session; a launch
//! starts with the queue running.

use super::*;
use crate::storage::content_queue::{ChapterSpan, CONTENT_QUEUED};
use std::collections::{BTreeMap, HashSet};
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
/// Wakes the worker when a lane is free to take its source's next work.
static LANE_FREED: tokio::sync::Notify = tokio::sync::Notify::const_new();
/// The worker's last look found the network gate closed.
static BLOCKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Nothing is started before this time (epoch seconds): the gate was
/// closed, or a download lost its connection.
static HOLD_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// One source's lane.
#[derive(Debug, Clone, Default)]
struct Lane {
    /// Taken: a work is in flight, or the pause after one is being
    /// waited out. Nothing of this source starts meanwhile.
    busy: bool,
    /// The work in flight (0 = none) and when it started (epoch seconds).
    work_id: u64,
    started: u64,
    /// Works finished since the lane last ran out of works to fetch.
    completed: u32,
    /// The lane ran out of works to fetch: its next work starts a fresh
    /// count.
    drained: bool,
}

/// Every lane that has had a work, by source id. Process-wide, like the
/// pause, so the picture carries over a library replacement's fresh
/// worker.
static LANES: std::sync::Mutex<BTreeMap<String, Lane>> = std::sync::Mutex::new(BTreeMap::new());

fn lanes() -> std::sync::MutexGuard<'static, BTreeMap<String, Lane>> {
    LANES.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

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

/// One source's lane of the queue, for the monitor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UContentQueueLane {
    pub source_id: String,
    /// The display name of the source.
    pub source_name: String,
    /// What this lane is doing: `Working` / `Pausing` only while a work
    /// of this source is in flight.
    pub state: ContentQueueState,
    /// The work in flight, if any.
    pub current_work_id: Option<u64>,
    /// When the in-flight work started, epoch seconds.
    pub current_started_at: Option<u64>,
    /// Works of this source finished since its lane last ran out of
    /// works to fetch. With what is still queued, the "5 of 23" of a
    /// progress line; it starts again from 0 with the lane's next work
    /// after it ran out.
    pub completed: u32,
}

/// The worker's status, for the monitor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UContentQueueStatus {
    /// The queue as a whole: `Working` / `Pausing` while any work is in
    /// flight.
    pub state: ContentQueueState,
    /// The user's pause, whether or not the in-flight works have finished.
    pub paused: bool,
    /// One lane for every source the queue fetches from, in the
    /// registry's order — whether or not it has anything queued.
    pub lanes: Vec<UContentQueueLane>,
}

/// One queued work, for the monitor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UContentQueueItem {
    pub work_id: u64,
    pub title: String,
    /// The work's source — the lane it waits in. Empty when the source
    /// is not one the app knows.
    pub source_id: String,
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

/// A source's lane, taken for one work: for as long as this lives
/// nothing else of the source starts. Dropping it frees the lane however
/// the download ends — the worker being aborted included.
struct LaneClaim {
    source: String,
}

impl LaneClaim {
    fn begin(source: &str, work_id: u64) -> Self {
        {
            let mut lanes = lanes();
            let lane = lanes.entry(source.to_string()).or_default();
            if lane.drained {
                lane.completed = 0;
                lane.drained = false;
            }
            lane.busy = true;
            lane.work_id = work_id;
            lane.started = crate::timefmt::epoch_now();
        }
        // A fresh list of requests for this work.
        crate::steps::clear(source);
        queue_changed();
        LaneClaim { source: source.to_string() }
    }

    /// The work is no longer in flight — `finished`: its content is in
    /// the library. The lane stays taken until the claim drops, so the
    /// pause before the source's next work is waited out first.
    fn landed(&self, finished: bool) {
        if let Some(lane) = lanes().get_mut(&self.source) {
            lane.work_id = 0;
            if finished {
                lane.completed += 1;
            }
        }
        crate::steps::clear(&self.source);
        queue_changed();
    }
}

impl Drop for LaneClaim {
    fn drop(&mut self) {
        let was_in_flight = lanes().get_mut(&self.source).map(|lane| {
            lane.busy = false;
            std::mem::take(&mut lane.work_id) != 0
        }).unwrap_or(false);
        LANE_FREED.notify_one();
        if was_in_flight {
            crate::steps::clear(&self.source);
            queue_changed();
        }
    }
}

/// The sources whose lanes are taken.
fn busy_lanes() -> HashSet<String> {
    lanes().iter().filter(|(_, lane)| lane.busy).map(|(source, _)| source.clone()).collect()
}

/// Note which free lanes have nothing left to fetch: `waiting` is every
/// source with a work still queued for a fetch.
fn mark_drained(waiting: &HashSet<String>) {
    for (source, lane) in lanes().iter_mut() {
        if !lane.busy && !waiting.contains(source) {
            lane.drained = true;
        }
    }
}

/// The works to start now, out of the due ones in the queue's order
/// (each with its source): the first of every source whose lane is free.
fn first_per_free_lane(due: &[(u64, String)], busy: &HashSet<String>) -> Vec<(u64, String)> {
    let mut taken: HashSet<&str> = busy.iter().map(String::as_str).collect();
    due.iter()
        .filter(|(_, source)| taken.insert(source.as_str()))
        .cloned()
        .collect()
}

#[uniffi::export]
impl AO3App {
    /// What the content queue's worker is doing right now. Reads no
    /// storage.
    pub fn content_queue_status(&self) -> UContentQueueStatus {
        use std::sync::atomic::Ordering::Relaxed;
        let paused = PAUSED.load(Relaxed);
        let blocked = BLOCKED.load(Relaxed);
        let held = lanes().clone();
        let lanes: Vec<UContentQueueLane> = self.sources.all().iter()
            .filter(|source| !source.library_only())
            .map(|source| {
                let caps = source.capabilities();
                let lane = held.get(&caps.id).cloned().unwrap_or_default();
                let current = Some(lane.work_id).filter(|id| *id != 0);
                UContentQueueLane {
                    source_id: caps.id.clone(),
                    source_name: caps.name.clone(),
                    state: queue_state(paused, current.is_some(), blocked),
                    current_work_id: current,
                    current_started_at: current.map(|_| lane.started),
                    completed: lane.completed,
                }
            }).collect();
        let working = lanes.iter().any(|lane| lane.current_work_id.is_some());
        UContentQueueStatus { state: queue_state(paused, working, blocked), paused, lanes }
    }

    /// Everything queued, in the order the worker gets to it: due works,
    /// then held-back ones, then the ones it gave up on. Each lane takes
    /// its own source's works out of that order. A work in flight is
    /// still listed (it leaves the queue when it finishes).
    pub fn content_queue_items(&self) -> Result<Vec<UContentQueueItem>, AO3Error> {
        let s = self.storage.blocking_lock();
        let rows = s.content_queue_items(crate::timefmt::epoch_now()).map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|row| {
            let (source_id, source_name) = s.work_ref(row.work_id)
                .and_then(|external| self.sources.by_id(&external.source))
                .map(|source| { let caps = source.capabilities(); (caps.id.clone(), caps.name.clone()) })
                .unwrap_or_default();
            let title = s.get_work(row.work_id).ok().flatten().map(|w| w.title)
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| format!("Work {}", row.work_id));
            UContentQueueItem {
                work_id: row.work_id,
                title,
                source_id,
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

    /// The requests each work in flight needs, by source id, as far as
    /// they are known, under names a reader understands: the chapter
    /// list, each chapter, each page of a chapter, each image. A source
    /// with nothing in flight has no entry; a finished work's list is
    /// cleared. Reads no storage.
    pub fn content_queue_steps(&self) -> std::collections::HashMap<String, Vec<crate::steps::UContentQueueStep>> {
        crate::steps::snapshot_all()
    }

    /// Pause or resume the content queue. A pause lets every work in
    /// flight finish in full — each request it needs — and starts
    /// nothing after them; `content_queue_status` reads `Pausing` until
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

/// How one work's download ended.
enum Step {
    /// The work was downloaded (or its download failed): requests went out.
    Worked,
    /// The work was settled without a request: already whole in the
    /// library.
    Skipped,
    /// Nothing can be sent right now.
    Blocked,
}

/// Seconds to hold a work back after its `attempts`-th failure.
fn retry_delay_secs(attempts: u32) -> u64 {
    RETRY_BASE_SECS
        .saturating_mul(1u64 << attempts.saturating_sub(1).min(16))
        .min(RETRY_MAX_SECS)
}

fn set_blocked(blocked: bool) {
    if BLOCKED.swap(blocked, std::sync::atomic::Ordering::Relaxed) != blocked {
        queue_changed();
    }
}

/// Spawn the worker for one opened database. It holds only a `Weak` to
/// the storage between works, and the returned handle aborts it — the
/// owning `AO3App` does so when it drops — and every download it has in
/// flight with it.
pub(super) fn spawn_worker(
    handle: &tokio::runtime::Handle,
    storage: std::sync::Weak<Mutex<Storage>>,
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    registry: Arc<crate::source::SourceRegistry>,
) -> tokio::task::AbortHandle {
    handle.spawn(async move {
        use std::sync::atomic::Ordering::Relaxed;
        // Nothing is looked at, judged or sent before the app has handed
        // over its privacy settings.
        crate::client::privacy::wait_established().await;
        // The downloads in flight, one a lane. Owned here, so they are
        // aborted with this task.
        let mut downloads = tokio::task::JoinSet::new();
        loop {
            if storage.strong_count() == 0 { return }
            let mut wait = POLL;
            let now = crate::timefmt::epoch_now();
            let hold = HOLD_UNTIL.load(Relaxed);
            if PAUSED.load(Relaxed) {
                // A pause holds here, between works: a work that was
                // started always runs to its end.
            } else if hold > now {
                wait = Duration::from_secs(hold - now);
            } else {
                let Some(strong) = storage.upgrade() else { return };
                let blocked = start_due(&client, &strong, &registry, &mut downloads).await;
                drop(strong);
                if blocked {
                    HOLD_UNTIL.store(crate::timefmt::epoch_now() + POLL.as_secs(), Relaxed);
                }
                set_blocked(blocked);
            }
            // Look again when a work is queued, a lane comes free, the
            // pause is lifted, or the poll runs out.
            tokio::select! {
                _ = CONTENT_QUEUED.notified() => {}
                _ = LANE_FREED.notified() => {}
                _ = RESUMED.notified() => {}
                Some(_) = downloads.join_next(), if !downloads.is_empty() => {}
                _ = tokio::time::sleep(wait) => {}
            }
        }
    }).abort_handle()
}

/// One look at the queue: start the next due work of every source whose
/// lane is free. Returns whether the network gate was closed (nothing
/// was started).
async fn start_due(
    client: &Arc<tokio::sync::RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    registry: &Arc<crate::source::SourceRegistry>,
    downloads: &mut tokio::task::JoinSet<()>,
) -> bool {
    let now = crate::timefmt::epoch_now();
    let starts: Vec<(u64, String, ChapterSpan)> = {
        let s = storage.lock().await;
        let pending = match s.pending_content_items(now) {
            Ok(pending) => pending,
            Err(e) => {
                log_error!("content_queue", "reading the queue failed: {e}");
                return false;
            }
        };
        // Every source with a work still to fetch, due or held back.
        let mut waiting: HashSet<String> = HashSet::new();
        let mut due: Vec<(u64, String)> = Vec::new();
        // Works settled without a request, written in one go below.
        let mut gone: Vec<u64> = Vec::new();
        let mut unreachable: Vec<(u64, String)> = Vec::new();
        for (work_id, is_due) in pending {
            let source = s.work_ref(work_id).and_then(|external| registry.by_id(&external.source));
            let Some(source) = source.filter(|source| !source.library_only()) else {
                // A work that is gone, or whose source serves nothing to
                // fetch (an imported file), leaves the queue.
                if is_due {
                    gone.push(work_id);
                }
                continue;
            };
            let source_id = &source.capabilities().id;
            if !waiting.contains(source_id) {
                waiting.insert(source_id.clone());
            }
            if !is_due { continue }
            // A source the current privacy mode can't reach: hold the
            // work back; it costs the work no attempt.
            if let Err(e) = check_reachable(&source) {
                unreachable.push((work_id, format!("{e}")));
                continue;
            }
            due.push((work_id, source_id.clone()));
        }
        if !gone.is_empty() || !unreachable.is_empty() {
            log_db("settle_content_items",
                   s.settle_content_items(&gone, &unreachable, now + UNREACHABLE_RETRY_SECS));
            queue_changed();
        }
        mark_drained(&waiting);
        first_per_free_lane(&due, &busy_lanes()).into_iter()
            .map(|(work_id, source)| {
                let span = s.content_item_span(work_id).ok().flatten().unwrap_or(ChapterSpan::WHOLE);
                (work_id, source, span)
            }).collect()
    };
    if starts.is_empty() {
        return false;
    }
    // Ask the privacy policy before sending anything: a refused request
    // is reported to the user, and nobody asked for these.
    let is_tor = client.read().await.transport().is_tor();
    if crate::client::privacy::gate(is_tor).is_err() {
        return true;
    }
    for (work_id, source, span) in starts {
        // Taken here, not in the task: the next look must find the lane
        // busy even before the download has run its first step.
        let claim = LaneClaim::begin(&source, work_id);
        downloads.spawn(run_lane(client.clone(), storage.clone(), registry.clone(), claim, work_id, span));
    }
    false
}

/// One lane's turn: download the work, then wait out the pause before
/// the source's next work with the lane still taken.
async fn run_lane(
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    registry: Arc<crate::source::SourceRegistry>,
    claim: LaneClaim,
    work_id: u64,
    span: ChapterSpan,
) {
    let step = download_item(&client, &storage, &registry, &claim, work_id, span).await;
    flush_request_log_to(&storage);
    // The storage is not kept alive through the pause.
    drop(storage);
    match step {
        // The same pause that spaces the works of "Download all".
        Step::Worked => crate::client::pacing::request_gap().await,
        // Nothing sent, nothing to space the next work from.
        Step::Skipped => {}
        Step::Blocked => {
            HOLD_UNTIL.store(crate::timefmt::epoch_now() + POLL.as_secs(), std::sync::atomic::Ordering::Relaxed);
            set_blocked(true);
        }
    }
}

/// Download one queued work and settle its queue row.
async fn download_item(
    client: &Arc<tokio::sync::RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    registry: &Arc<crate::source::SourceRegistry>,
    claim: &LaneClaim,
    work_id: u64,
    span: ChapterSpan,
) -> Step {
    if span.is_whole() {
        log_info!("content_queue", "Fetching the content of work {work_id}");
    } else {
        log_info!("content_queue", "Fetching chapters {} to {} of work {work_id}",
                  span.first.max(1), if span.last == 0 { "the last".to_string() } else { span.last.to_string() });
    }
    // Unattended: a human check the user just dismissed is not raised
    // again for a download nobody is waiting on.
    let result = crate::client::clearance::unattended(crate::steps::recording(&claim.source, async {
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
    // The queue row is settled below before the monitor is told the work
    // is no longer in flight.
    let s = storage.lock().await;
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
            claim.landed(true);
            log_info!("content_queue", "Work {work_id}: {}{}",
                      if complete { "fully in the library" } else { "the chapters asked for are in the library" },
                      if requested { "" } else { " (nothing was missing)" });
            crate::events::emit(crate::events::CoreEvent::WorkContentSaved { work_id });
            if requested { Step::Worked } else { Step::Skipped }
        }
        // The connection went away mid-download: the work keeps its
        // place and costs no attempt.
        Err(AO3Error::NetworkDisabled) => {
            drop(s);
            claim.landed(false);
            Step::Blocked
        }
        Err(e) => {
            let attempts = s.content_item_attempts(work_id).ok().flatten().unwrap_or(0) + 1;
            let wait = retry_delay_secs(attempts);
            log_error!("content_queue",
                "Content fetch for work {work_id} failed (attempt {attempts} of {}), next try in {wait}s: {e}",
                crate::storage::content_queue::CONTENT_MAX_ATTEMPTS);
            log_db("defer_content_item",
                   s.defer_content_item(work_id, crate::timefmt::epoch_now() + wait, &format!("{e}"), true));
            drop(s);
            claim.landed(false);
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
    fn each_free_lane_takes_the_first_due_work_of_its_source() {
        let due = |items: &[(u64, &str)]| -> Vec<(u64, String)> {
            items.iter().map(|(id, source)| (*id, source.to_string())).collect()
        };
        let busy = |sources: &[&str]| -> HashSet<String> { sources.iter().map(|s| s.to_string()).collect() };
        let queue = due(&[(1, "ao3"), (2, "ao3"), (3, "scribblehub"), (4, "wattpad"), (5, "scribblehub")]);

        // Every source starts its first work; a source's later works wait.
        assert_eq!(first_per_free_lane(&queue, &busy(&[])),
                   due(&[(1, "ao3"), (3, "scribblehub"), (4, "wattpad")]));
        // A source with a work in flight starts nothing.
        assert_eq!(first_per_free_lane(&queue, &busy(&["ao3", "wattpad"])), due(&[(3, "scribblehub")]));
        // One source queued: one work at a time.
        let one = due(&[(1, "ao3"), (2, "ao3"), (6, "ao3")]);
        assert_eq!(first_per_free_lane(&one, &busy(&[])), due(&[(1, "ao3")]));
        assert_eq!(first_per_free_lane(&one, &busy(&["ao3"])), due(&[]));
    }

    #[test]
    fn a_lane_counts_its_finished_works_until_it_runs_out() {
        const SOURCE: &str = "lane-test-count";
        let lane = || lanes().get(SOURCE).cloned().unwrap_or_default();
        let waiting = |sources: &[&str]| -> HashSet<String> { sources.iter().map(|s| s.to_string()).collect() };

        let claim = LaneClaim::begin(SOURCE, 7);
        assert!(lane().busy && lane().work_id == 7);
        assert!(busy_lanes().contains(SOURCE));
        // Landed: no longer in flight, the lane still taken for the pause.
        claim.landed(true);
        assert!(lane().busy && lane().work_id == 0 && lane().completed == 1);
        // A taken lane is never marked as run out.
        mark_drained(&waiting(&[]));
        assert!(!lane().drained);
        drop(claim);
        assert!(!lane().busy && !busy_lanes().contains(SOURCE));

        // More of the source is queued: the count carries on, and a
        // failed work adds nothing to it.
        mark_drained(&waiting(&[SOURCE]));
        let claim = LaneClaim::begin(SOURCE, 8);
        claim.landed(false);
        drop(claim);
        let claim = LaneClaim::begin(SOURCE, 9);
        claim.landed(true);
        drop(claim);
        assert_eq!(lane().completed, 2);

        // Run out: the count stands until the lane's next work, which
        // starts a fresh one.
        mark_drained(&waiting(&[]));
        assert!(lane().drained && lane().completed == 2);
        let claim = LaneClaim::begin(SOURCE, 10);
        assert!(lane().completed == 0 && !lane().drained);
        // Dropped without landing (the worker was aborted): freed, not counted.
        drop(claim);
        assert!(!lane().busy && lane().work_id == 0 && lane().completed == 0);
        lanes().remove(SOURCE);
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
