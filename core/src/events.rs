//! Centralized connection-recovery event bus.
//!
//! `emit` is lock-free and callable from anywhere, including mid-request
//! while a client read guard is held. `deliver` (inside `dispatch_loop`)
//! runs on its own task and owns no locks, so Swift can never be on the
//! stack while a lock is held — reentrancy is impossible by construction,
//! not by discipline.
//!
//! The stream is an optimization; callers that need the authoritative
//! picture of what's happening right now should use
//! `client::active_requests_snapshot` / `AO3App::active_operations`, not
//! replay events from here.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::mpsc;

use crate::client::FailureKind;

/// Identifies one logical operation across its whole lifecycle, including
/// every recovery attempt.
pub type OpId = u64;

static NEXT_OP_ID: AtomicU64 = AtomicU64::new(1);

/// Allocate a fresh `OpId`. Called once per logical operation, at the point
/// `OperationStarted` is emitted.
pub fn next_op_id() -> OpId {
    NEXT_OP_ID.fetch_add(1, Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Event payload types
// ---------------------------------------------------------------------------

/// What kind of operation this is, for UI copy. `Fetch`'s `label` mirrors the
/// operation keys screens already key their loading state on (e.g. "browse",
/// "inbox", "collections_browse") — a screen that already reads a key it
/// registered keeps working with no additional wiring.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OpKind {
    Fetch { label: String },
    Image,
    Kudos,
    Comment,
    Reply,
    Login,
    Logout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OpPhase {
    Connecting,
    Downloading,
    Complete,
    Failed,
}

/// What the recovery engine is doing about a classified failure — mirrors
/// the policy table's "Remedy" column at the granularity the UI needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Remedy {
    /// New set of nodes: an isolated sub-client on the existing bootstrap.
    Rotate,
    RotateAndReclear,
    Backoff,
    Purge,
    /// Full new circuit: replace the whole TorClient with a freshly
    /// bootstrapped one — the privacy hub's "New circuit" treatment.
    Reconnect,
}

/// A sub-step within one recovery attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecoveryStep {
    RotatingCircuit,
    EarningClearance,
    BackingOff { seconds: u32 },
    Retrying,
    /// Rebuilding the Tor connection from scratch (full reconnect).
    Reconnecting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OpOutcome {
    Succeeded,
    Failed { kind: Option<FailureKind> },
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected { via_tor: bool, socks_port: u16 },
}

/// Scope of cached data a screen should treat as stale. Deliberately coarse
/// — today only emitted for the session-purge path.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum InvalidationScope {
    Session,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum CoreEvent {
    OperationStarted { id: OpId, kind: OpKind },
    OperationProgress { id: OpId, phase: OpPhase, bytes: u64, total: Option<u64> },
    OperationTick { id: OpId, elapsed_ms: u64, attempt: u32, max_attempts: u32 },
    RecoveryStarted { id: OpId, failure: FailureKind, remedy: Remedy, attempt: u32, max_attempts: u32 },
    RecoveryStep { id: OpId, step: RecoveryStep },
    OperationFinished { id: OpId, outcome: OpOutcome },
    ConnectionChanged { state: ConnectionState },
    DataInvalidated { scope: InvalidationScope },
}

// ---------------------------------------------------------------------------
// Ambient operation context
// ---------------------------------------------------------------------------
//
// `with_recovery` (api::recovery) allocates one `OpId` per logical
// operation and scopes it here for the lifetime of the whole retry loop —
// every low-level fetch/post call made during any attempt picks up the same
// id automatically, with no parameter threading through the call chain
// between the recovery engine and `fetch_with_progress_inner` four layers
// down.

tokio::task_local! {
    static CURRENT_OP: OpId;
}

/// Run `fut` with `id` as the ambient operation for everything it calls,
/// directly or transitively.
pub async fn scoped<F: std::future::Future>(id: OpId, fut: F) -> F::Output {
    CURRENT_OP.scope(id, fut).await
}

/// The ambient operation's id, if this code is running inside a `scoped`
/// future. `None` for anything invoked outside `with_recovery` (tests, or a
/// call site that hasn't been migrated onto the engine yet).
pub fn current_op() -> Option<OpId> {
    CURRENT_OP.try_with(|id| *id).ok()
}

// ---------------------------------------------------------------------------
// Authoritative snapshot — the truth a late-mounting view asks for
// ---------------------------------------------------------------------------
//
// The event stream is an optimization; this registry is the source of
// truth. `with_recovery` keeps it current at every lifecycle point
// (attempt start, remedy chosen, terminal outcome) so a view that mounts
// mid-recovery can ask "what's happening right now" instead of having
// missed the events that would have told it.

/// A live logical operation, as `AO3App::active_operations()` reports it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OperationStatus {
    pub id: OpId,
    pub kind: OpKind,
    pub attempt: u32,
    pub max_attempts: u32,
    /// `Some` only while a remedy (rotate/backoff/etc.) is actively being
    /// applied between attempts; `None` while a request is in flight.
    pub remedy: Option<Remedy>,
    pub started_at_ms: u64,
}

static OPERATIONS: OnceLock<Mutex<HashMap<OpId, OperationStatus>>> = OnceLock::new();

fn operations() -> &'static Mutex<HashMap<OpId, OperationStatus>> {
    OPERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Insert or overwrite the tracked status for one operation.
pub(crate) fn track_operation(status: OperationStatus) {
    operations().lock().unwrap().insert(status.id, status);
}

/// Stop tracking an operation — called once it reaches a terminal outcome.
/// Never called mid-recovery, so a terminal status can't vanish out from
/// under a reader that hasn't asked yet; it simply won't appear in the next
/// snapshot once this runs.
pub(crate) fn untrack_operation(id: OpId) {
    operations().lock().unwrap().remove(&id);
}

/// Every operation currently in flight or being recovered.
pub fn operations_snapshot() -> Vec<OperationStatus> {
    operations().lock().unwrap().values().cloned().collect()
}

// ---------------------------------------------------------------------------
// Observer registration
// ---------------------------------------------------------------------------

/// Implemented on the Swift side. Invoked only from the dispatcher task,
/// never from inside a lock or mid-request. Implementations must hop off
/// this thread quickly (e.g. to `@MainActor`) rather than doing UI work
/// inline, since the dispatcher delivers every event sequentially.
#[uniffi::export(callback_interface)]
pub trait CoreObserver: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}

static OBSERVER: OnceLock<Mutex<Option<Arc<dyn CoreObserver>>>> = OnceLock::new();

fn observer_slot() -> &'static Mutex<Option<Arc<dyn CoreObserver>>> {
    OBSERVER.get_or_init(|| Mutex::new(None))
}

/// Register (or clear, with `None`) the single process-wide observer.
pub fn set_observer(observer: Option<Arc<dyn CoreObserver>>) {
    *observer_slot().lock().unwrap() = observer;
}

// ---------------------------------------------------------------------------
// Emit / deliver split
// ---------------------------------------------------------------------------

struct Bus {
    /// Behind a mutex (not a `OnceLock`) so `init()` can be called more than
    /// once — every `#[tokio::test]` owns a throwaway runtime, so tests
    /// re-init a fresh channel/dispatcher pair per run. Replacing the
    /// sender drops the old dispatcher's only sender clone, so it observes
    /// `rx.recv() -> None` and exits on its own; nothing leaks.
    tx: Mutex<mpsc::UnboundedSender<CoreEvent>>,
    /// Latest-wins coalescing: one pending progress/tick event per `OpId`,
    /// flushed on `FLUSH_INTERVAL`. A stale byte count is worthless, so
    /// collapsing a burst of updates into the last one loses nothing a
    /// viewer cares about.
    progress: Mutex<HashMap<OpId, CoreEvent>>,
    ticks: Mutex<HashMap<OpId, CoreEvent>>,
}

const FLUSH_INTERVAL: std::time::Duration = std::time::Duration::from_millis(120);

static BUS: OnceLock<Bus> = OnceLock::new();

fn bus() -> &'static Bus {
    BUS.get_or_init(|| {
        // A throwaway channel with no reader, so `emit()` is always safe to
        // call before `init()` runs — those events are simply never
        // delivered, same as if no observer were registered.
        let (tx, _rx) = mpsc::unbounded_channel();
        Bus {
            tx: Mutex::new(tx),
            progress: Mutex::new(HashMap::new()),
            ticks: Mutex::new(HashMap::new()),
        }
    })
}

/// Spawn the dispatcher task onto `handle`. Call once, from a context that
/// already owns a runtime (the app's constructor) — never via the ambient
/// `tokio::spawn`, which would panic if the very first `emit()` happened to
/// come from a synchronous FFI call on Swift's thread.
pub fn init(handle: &tokio::runtime::Handle) {
    let (tx, rx) = mpsc::unbounded_channel();
    *bus().tx.lock().unwrap() = tx;
    handle.spawn(dispatch_loop(rx));
}

/// Non-blocking, infallible, safe under any lock: never awaits, never
/// blocks on a mutex held by anything else. `OperationProgress` and
/// `OperationTick` are coalesced per `OpId`; every other variant is queued
/// on an unbounded channel so a lifecycle event can never be dropped or
/// made to wait behind a full queue.
pub fn emit(event: CoreEvent) {
    let b = bus();
    match &event {
        CoreEvent::OperationProgress { id, .. } => {
            b.progress.lock().unwrap().insert(*id, event);
        }
        CoreEvent::OperationTick { id, .. } => {
            b.ticks.lock().unwrap().insert(*id, event);
        }
        _ => {
            // An unbounded send only fails if the receiver was dropped,
            // which only happens if the dispatcher task itself panicked;
            // there's nothing useful to do with that here.
            let _ = b.tx.lock().unwrap().send(event);
        }
    }
}

async fn dispatch_loop(mut rx: mpsc::UnboundedReceiver<CoreEvent>) {
    let mut flush = tokio::time::interval(FLUSH_INTERVAL);
    flush.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            maybe_event = rx.recv() => {
                match maybe_event {
                    Some(event) => deliver(event),
                    None => break,
                }
            }
            _ = flush.tick() => flush_coalesced(),
        }
    }
}

fn flush_coalesced() {
    let b = bus();
    let progress: Vec<CoreEvent> = {
        let mut m = b.progress.lock().unwrap();
        m.drain().map(|(_, v)| v).collect()
    };
    for event in progress {
        deliver(event);
    }
    let ticks: Vec<CoreEvent> = {
        let mut m = b.ticks.lock().unwrap();
        m.drain().map(|(_, v)| v).collect()
    };
    for event in ticks {
        deliver(event);
    }
}

fn deliver(event: CoreEvent) {
    let observer = observer_slot().lock().unwrap().clone();
    if let Some(observer) = observer {
        observer.on_event(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    struct RecordingObserver {
        events: Arc<Mutex<Vec<CoreEvent>>>,
    }

    impl CoreObserver for RecordingObserver {
        fn on_event(&self, event: CoreEvent) {
            self.events.lock().unwrap().push(event);
        }
    }

    fn label(event: &CoreEvent) -> String {
        match event {
            CoreEvent::OperationStarted { id, .. } => format!("started:{id}"),
            CoreEvent::OperationFinished { id, .. } => format!("finished:{id}"),
            CoreEvent::ConnectionChanged { .. } => "connection_changed".to_string(),
            other => format!("{other:?}"),
        }
    }

    /// `BUS` and `OBSERVER` are process-global, but `cargo test` runs test
    /// functions concurrently on separate threads within the same process —
    /// without this, two tests' events would interleave into whichever
    /// observer happened to be registered at the time. Held for the whole
    /// body so each test's install → run → observe → teardown is atomic
    /// with respect to every other test in this module.
    static TEST_SERIAL: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

    /// Each test in this module installs its own observer and (re-)inits
    /// the dispatcher on the current-thread test runtime — `init()` is
    /// safe to call repeatedly, so this works even though every
    /// `#[tokio::test]` tears its runtime down when the test ends.
    async fn with_observer<F, Fut>(f: F) -> Vec<CoreEvent>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        let _serial = TEST_SERIAL.get_or_init(|| tokio::sync::Mutex::new(())).lock().await;
        let events = Arc::new(Mutex::new(Vec::new()));
        set_observer(Some(Arc::new(RecordingObserver { events: events.clone() })));
        init(&tokio::runtime::Handle::current());
        f().await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        set_observer(None);
        let out = events.lock().unwrap().clone();
        out
    }

    #[tokio::test]
    async fn lifecycle_ordering_is_preserved() {
        let events = with_observer(|| async {
            for i in 1..=5u64 {
                emit(CoreEvent::OperationStarted { id: i, kind: OpKind::Kudos });
            }
        }).await;

        let ids: Vec<String> = events.iter().map(label).collect();
        assert_eq!(ids, vec!["started:1", "started:2", "started:3", "started:4", "started:5"]);
    }

    #[tokio::test]
    async fn progress_coalesces_under_load() {
        let op = next_op_id();
        let events = with_observer(|| async move {
            for bytes in 0..200u64 {
                emit(CoreEvent::OperationProgress {
                    id: op, phase: OpPhase::Downloading, bytes, total: Some(200),
                });
            }
        }).await;

        let progress: Vec<_> = events.iter().filter(|e| matches!(e, CoreEvent::OperationProgress { .. })).collect();
        assert_eq!(progress.len(), 1, "200 rapid updates must coalesce to one flush");
        match progress[0] {
            CoreEvent::OperationProgress { bytes, .. } => assert_eq!(*bytes, 199, "coalescing must keep the latest value"),
            _ => unreachable!(),
        }
    }

    #[tokio::test]
    async fn emit_never_blocks_on_an_unrelated_lock() {
        // Shares the same serialization as every other test here — without
        // it, this emit lands on whatever observer another concurrently
        // running test happens to have installed on the process-global bus.
        let _serial = TEST_SERIAL.get_or_init(|| tokio::sync::Mutex::new(())).lock().await;
        let unrelated = Mutex::new(0);
        let _guard = unrelated.lock().unwrap();
        // If emit() ever tried to acquire a lock contended by the caller's
        // own state, this would hang forever; the timeout turns that into a
        // failed assertion instead of a stuck test suite.
        let result = tokio::time::timeout(Duration::from_millis(200), async {
            emit(CoreEvent::ConnectionChanged { state: ConnectionState::Disconnected });
        }).await;
        assert!(result.is_ok(), "emit() blocked while an unrelated lock was held");
    }
}
