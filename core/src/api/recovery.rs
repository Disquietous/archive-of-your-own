// ---------------------------------------------------------------------------
// Recovery engine — the only place remediation policy exists
// ---------------------------------------------------------------------------
//
// A free function, not a method on `AO3App`: the operations that need
// retry/rotation run inside a `run_on_runtime`-spawned closure, which only
// captures `client`/`storage` clones (never `self` — see that function's
// doc), so `with_recovery` takes the same two Arcs directly.
//
// Loop structure (the crux, because of the lock topology constraint —
// `AO3Client::new_circuit` needs `client.write()`, and every request holds
// `client.read()` for its duration, so rotation can never happen while an
// attempt's read guard is still held):
//
// 1. Emit `OperationStarted`. Run `op`, which takes and drops its own read
//    guard internally.
// 2. On success, emit `OperationFinished` and return.
// 3. Classify the failure via the policy table below. No policy (or the cap
//    reached, or an `AtMostOnce` op hitting a kind that must not retry) —
//    emit and return the error.
// 4. Otherwise emit `RecoveryStarted`, perform the remedy with no read
//    guard held, and loop back to 1.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{Mutex, RwLock};

use crate::client::{AO3Client, FailureKind};
use crate::events::{self, CoreEvent, OpId, OpKind, OpOutcome, OperationStatus, RecoveryStep, Remedy};
use crate::storage::Storage;

use super::capabilities;
use super::error::{classify, AO3Error};

/// Whether re-running `op` after a remedy could double-apply its effect.
/// `Idempotent` operations (a GET, or a POST AO3 itself de-dupes — kudos
/// answers "already left kudos") are safe to retry outright. `AtMostOnce`
/// operations (comment, reply — anything that creates a new record with no
/// natural dedup) are retried only for failure kinds where the request
/// provably never reached the origin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetrySafety {
    Idempotent,
    AtMostOnce,
}

struct Policy {
    remedy: Remedy,
    cap: u32,
    /// Whether an `AtMostOnce` operation retries after this remedy. An
    /// `Idempotent` operation always retries (up to `cap`) regardless.
    retry_at_most_once: bool,
}

/// The policy table, consulted once per failed attempt (`attempt` counts
/// the attempts that have failed so far, starting at 1). Most kinds use one
/// remedy throughout; the rate-limit schedule escalates from node rotation
/// to a full reconnect mid-cycle. `ResponseTimeout` isn't here — it has no
/// circuit-level remedy at all (see `run_loop`), so it doesn't fit the
/// `Policy` shape.
fn policy_for(failure: FailureKind, attempt: u32) -> Option<Policy> {
    match failure {
        // Provably never reached AO3 — safe to retry for any operation.
        FailureKind::EdgeTlsFailure =>
            Some(Policy { remedy: Remedy::RotateAndReclear, cap: 3, retry_at_most_once: true }),
        // 429's budget is scoped to the exit IP. Escalation ladder: three
        // retries each from a new set of nodes (isolated client on the
        // same bootstrap), then one full reconnect (fresh TorClient — the
        // privacy hub's New-Circuit treatment) and the node cycle starts
        // over. Still limited after the second cycle → surface the rate
        // limit honestly instead of hammering AO3 forever.
        FailureKind::RateLimited { .. } => {
            let remedy = if attempt == 4 { Remedy::Reconnect } else { Remedy::Rotate };
            Some(Policy { remedy, cap: 8, retry_at_most_once: true })
        }
        FailureKind::Challenged =>
            Some(Policy { remedy: Remedy::RotateAndReclear, cap: 3, retry_at_most_once: true }),
        // 502/503/504. The transport layer already punched through any
        // cached edge error with its one-shot no-cache (shift+refresh)
        // retry, so a 503 that reaches here is real: rebuild the Tor
        // connection outright (full reconnect, not just new nodes) and try
        // once more. Never retries an AtMostOnce op — a 503 can't prove
        // the write didn't land.
        FailureKind::OriginUnavailable =>
            Some(Policy { remedy: Remedy::Reconnect, cap: 2, retry_at_most_once: false }),
        // Ambiguous: could be a dead circuit, or a slow one that will still
        // land the write.
        FailureKind::ConnectFailure =>
            Some(Policy { remedy: Remedy::Rotate, cap: 3, retry_at_most_once: false }),
        FailureKind::ResponseTimeout => None,
        // Not transient — surface as-is. `SessionExpired` is already
        // handled by `run_on_runtime`'s existing purge-and-surface path.
        FailureKind::SessionExpired | FailureKind::Http { .. } | FailureKind::Malformed => None,
    }
}

const DEFAULT_CAP: u32 = 3;

/// Everything a full reconnect needs from the app — `connect_tor`'s
/// dependencies, registered by `AO3App`'s constructors so the engine can
/// rebuild the transport without holding an app reference (ops only ever
/// capture `client`/`storage` clones — see the module doc).
pub(crate) struct ReconnectContext {
    pub state_dir: String,
    pub tor_connected: Arc<std::sync::atomic::AtomicBool>,
    pub socks_port: Arc<std::sync::atomic::AtomicU32>,
    pub timeout_secs: Arc<std::sync::atomic::AtomicU64>,
    pub route_timeouts: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>,
}

static RECONNECT_CTX: std::sync::Mutex<Option<Arc<ReconnectContext>>> = std::sync::Mutex::new(None);

pub(crate) fn set_reconnect_context(ctx: ReconnectContext) {
    *RECONNECT_CTX.lock().unwrap() = Some(Arc::new(ctx));
}

#[cfg(feature = "tor")]
fn reconnect_context() -> Option<Arc<ReconnectContext>> {
    RECONNECT_CTX.lock().unwrap().clone()
}

/// Wrap a retryable unit of work with the recovery engine. `op` may run more
/// than once — it must not close over anything that isn't safe to run
/// again (each call gets a fresh `client` clone).
pub(crate) async fn with_recovery<T, F, Fut>(
    client: Arc<RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    kind: OpKind,
    safety: RetrySafety,
    op: F,
) -> Result<T, AO3Error>
where
    F: Fn(Arc<RwLock<AO3Client>>) -> Fut,
    Fut: std::future::Future<Output = Result<T, AO3Error>>,
{
    with_recovery_as(client, storage, events::next_op_id(), kind, safety, op).await
}

/// `with_recovery` under a caller-supplied operation id — the request-
/// tracking standard's engine entry point.
///
/// The standard: a UI that wants to surface an operation's progress asks
/// the core for an id up front (`AO3App::new_operation_id`), passes it to
/// a tracking-aware API method, and that id then stamps everything the
/// operation produces — every in-flight request registers with it
/// (`ActiveRequestGuard` captures the ambient id, so `get_active_requests`
/// rows carry it), every retry the engine runs after a failure happens
/// inside the same scope and keeps the same id, and every `CoreEvent`
/// (started / progress / recovery / finished) names it. The UI filters all
/// of those streams by the id it already holds; no guessing by kind, URL,
/// or timing.
pub(crate) async fn with_recovery_as<T, F, Fut>(
    client: Arc<RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    id: OpId,
    kind: OpKind,
    safety: RetrySafety,
    op: F,
) -> Result<T, AO3Error>
where
    F: Fn(Arc<RwLock<AO3Client>>) -> Fut,
    Fut: std::future::Future<Output = Result<T, AO3Error>>,
{
    events::scoped(id, run_loop(client, storage, id, kind, safety, op)).await
}

async fn run_loop<T, F, Fut>(
    client: Arc<RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    id: OpId,
    kind: OpKind,
    safety: RetrySafety,
    op: F,
) -> Result<T, AO3Error>
where
    F: Fn(Arc<RwLock<AO3Client>>) -> Fut,
    Fut: std::future::Future<Output = Result<T, AO3Error>>,
{
    let started_at_ms = crate::client::now_ms();
    let mut attempt: u32 = 1;

    loop {
        events::emit(CoreEvent::OperationStarted { id, kind: kind.clone() });
        events::track_operation(OperationStatus {
            id, kind: kind.clone(), attempt, max_attempts: DEFAULT_CAP, remedy: None, started_at_ms,
        });

        let err = match op(client.clone()).await {
            Ok(value) => {
                events::emit(CoreEvent::OperationFinished { id, outcome: OpOutcome::Succeeded });
                events::untrack_operation(id);
                return Ok(value);
            }
            Err(e) => e,
        };

        let Some(failure) = classify(&err) else {
            finish_failed(id, None);
            return Err(err);
        };

        // No circuit-level remedy exists for this one — headers already
        // arrived, so the only question is whether re-running `op` is safe.
        if failure == FailureKind::ResponseTimeout {
            if safety == RetrySafety::Idempotent && attempt < 2 {
                events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::Retrying });
                attempt += 1;
                continue;
            }
            finish_failed(id, Some(failure));
            return Err(err);
        }

        let Some(policy) = policy_for(failure, attempt) else {
            finish_failed(id, Some(failure));
            return Err(err);
        };

        let will_retry = attempt < policy.cap
            && (safety == RetrySafety::Idempotent || policy.retry_at_most_once);
        if !will_retry {
            finish_failed(id, Some(failure));
            return Err(err);
        }

        events::emit(CoreEvent::RecoveryStarted {
            id, failure, remedy: policy.remedy, attempt, max_attempts: policy.cap,
        });
        events::track_operation(OperationStatus {
            id, kind: kind.clone(), attempt, max_attempts: policy.cap, remedy: Some(policy.remedy), started_at_ms,
        });

        perform_remedy(&client, &storage, policy.remedy, failure, id).await;

        attempt += 1;
    }
}

fn finish_failed(id: OpId, kind: Option<FailureKind>) {
    events::emit(CoreEvent::OperationFinished { id, outcome: OpOutcome::Failed { kind } });
    events::untrack_operation(id);
}

async fn perform_remedy(
    client: &Arc<RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    remedy: Remedy,
    failure: FailureKind,
    id: OpId,
) {
    match remedy {
        Remedy::Rotate => {
            // 429's budget is scoped to the exit IP; with no circuit to
            // rotate (not on Tor), honor the origin's Retry-After instead.
            if let FailureKind::RateLimited { retry_after_secs } = failure {
                if !client.read().await.is_tor() {
                    let secs = retry_after_secs.unwrap_or(5).min(60);
                    events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::BackingOff { seconds: secs } });
                    tokio::time::sleep(Duration::from_secs(secs as u64)).await;
                    return;
                }
            }
            events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::RotatingCircuit });
            rotate(client).await;
        }
        Remedy::RotateAndReclear => {
            events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::RotatingCircuit });
            rotate(client).await;
            events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::EarningClearance });
            earn_clearance(client, storage).await;
        }
        Remedy::Backoff => {
            let secs = 2u32;
            events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::BackingOff { seconds: secs } });
            tokio::time::sleep(Duration::from_secs(secs as u64)).await;
        }
        Remedy::Reconnect => {
            // Off Tor there is no circuit to rebuild — a plain backoff
            // covers a genuine outage on a direct connection.
            if !client.read().await.is_tor() {
                let secs = 2u32;
                events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::BackingOff { seconds: secs } });
                tokio::time::sleep(Duration::from_secs(secs as u64)).await;
                return;
            }
            events::emit(CoreEvent::RecoveryStep { id, step: RecoveryStep::Reconnecting });
            full_reconnect(client).await;
            // The fresh client starts with an empty cookie jar — put the
            // persisted session back so the retry stays signed in.
            restore_persisted_cookies(client, storage).await;
        }
        // Not driven by the engine today — `run_on_runtime` already purges
        // dead session cookies on `AO3Error::SessionExpired` independently
        // of this loop (`SessionExpired` never reaches `policy_for`).
        Remedy::Purge => {}
    }
}

/// The privacy hub's "New circuit" treatment: replace the whole TorClient
/// with a freshly bootstrapped one (new guards and all), not just an
/// isolated sub-client on the old bootstrap. Mirrors `AO3App::connect_tor`,
/// driven by the context the app constructor registers. Falls back to
/// plain rotation when the context is missing or the bootstrap fails, so
/// the retry never runs on the very circuit that just failed.
async fn full_reconnect(client: &Arc<RwLock<AO3Client>>) {
    #[cfg(feature = "tor")]
    {
        let Some(ctx) = reconnect_context() else {
            log_info!("recovery", "no reconnect context registered — falling back to circuit rotation");
            rotate(client).await;
            return;
        };
        match AO3Client::new_tor_with_dir(&ctx.state_dir).await {
            Ok(mut new_client) => {
                new_client.share_route_timeouts(ctx.route_timeouts.clone());
                new_client.set_timeout(ctx.timeout_secs.load(std::sync::atomic::Ordering::Relaxed));
                let mut c = client.write().await;
                // Stop the outgoing client's SOCKS accept loop before the
                // swap — same leak-avoidance as connect_tor.
                c.stop_socks_proxy();
                *c = new_client;
                ctx.tor_connected.store(c.is_tor(), std::sync::atomic::Ordering::Relaxed);
                ctx.socks_port.store(c.socks_port().unwrap_or(0) as u32, std::sync::atomic::Ordering::Relaxed);
            }
            Err(e) => {
                log_error!("recovery", "full reconnect failed: {e} — falling back to circuit rotation");
                rotate(client).await;
            }
        }
    }
    #[cfg(not(feature = "tor"))]
    { let _ = client; }
}

async fn rotate(client: &Arc<RwLock<AO3Client>>) {
    #[cfg(feature = "tor")]
    {
        let mut c = client.write().await;
        if c.is_tor() {
            if let Err(e) = c.new_circuit().await {
                log_error!("recovery", "circuit rotation failed: {e}");
            }
        }
    }
    #[cfg(not(feature = "tor"))]
    { let _ = client; }
}

async fn earn_clearance(client: &Arc<RwLock<AO3Client>>, storage: &Arc<Mutex<Storage>>) {
    let socks_port = client.read().await.socks_port().unwrap_or(0);
    if socks_port == 0 {
        return; // Not on Tor — no clearance to earn.
    }
    let Some(capability) = capabilities::get() else {
        log_info!("recovery", "no PlatformCapabilities registered — skipping clearance");
        return;
    };
    match capability.earn_cloudflare_clearance(socks_port).await {
        Ok(cookies) => {
            // Mirrors `resolveCloudflare()`'s existing ordering: auth
            // cookies first, Cloudflare's cookies layered on top.
            restore_persisted_cookies(client, storage).await;
            let c = client.read().await;
            for cookie in &cookies {
                if !cookie.is_empty() {
                    c.set_session_cookies(cookie);
                }
            }
        }
        Err(e) => { log_error!("recovery", "clearance capability failed: {e}"); }
    }
}

/// Mirrors `AO3App::restore_session_cookies`'s lookup, through the async
/// mutex — that method is a `blocking_lock()` export reachable only from
/// Swift's thread (see the lock discipline invariant in `api/mod.rs`) and
/// must never be called from inside the runtime, which is exactly where
/// this runs.
async fn restore_persisted_cookies(client: &Arc<RwLock<AO3Client>>, storage: &Arc<Mutex<Storage>>) {
    let s = storage.lock().await;
    let cookies = match s.get_active_account() {
        Ok(Some((_, _, cookies))) if !cookies.is_empty() => Some(cookies),
        _ => s.get_state("ao3_session_cookies").ok().flatten().filter(|c| !c.is_empty()),
    };
    drop(s);
    if let Some(cookies) = cookies {
        client.read().await.set_session_cookies(&cookies);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    async fn test_app() -> (Arc<RwLock<AO3Client>>, Arc<Mutex<Storage>>) {
        let client = AO3Client::new_direct().await.unwrap();
        let storage = Storage::open_in_memory("test-passphrase").unwrap();
        (Arc::new(RwLock::new(client)), Arc::new(Mutex::new(storage)))
    }

    fn http_err(kind: FailureKind) -> AO3Error {
        AO3Error::Http { kind, message: "test".to_string() }
    }

    #[tokio::test]
    async fn edge_tls_failure_retries_up_to_cap_for_idempotent() {
        let (client, storage) = test_app().await;
        let calls = Arc::new(AtomicU32::new(0));
        let calls2 = calls.clone();
        let result = with_recovery(client, storage, OpKind::Kudos, RetrySafety::Idempotent, move |_c| {
            let calls = calls2.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>(http_err(FailureKind::EdgeTlsFailure))
            }
        }).await;

        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 3, "must attempt exactly the cap (3), not more or fewer");
    }

    #[tokio::test]
    async fn at_most_once_never_retries_an_ambiguous_connect_failure() {
        let (client, storage) = test_app().await;
        let calls = Arc::new(AtomicU32::new(0));
        let calls2 = calls.clone();
        let result = with_recovery(client, storage, OpKind::Comment, RetrySafety::AtMostOnce, move |_c| {
            let calls = calls2.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>(http_err(FailureKind::ConnectFailure))
            }
        }).await;

        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1, "AtMostOnce must never retry a failure that might have landed");
    }

    #[tokio::test]
    async fn at_most_once_does_retry_edge_tls_failure() {
        // 525 is provably pre-origin for every operation, so it's the one
        // kind that's safe to retry even for AtMostOnce ops.
        let (client, storage) = test_app().await;
        let calls = Arc::new(AtomicU32::new(0));
        let calls2 = calls.clone();
        let result = with_recovery(client, storage, OpKind::Comment, RetrySafety::AtMostOnce, move |_c| {
            let calls = calls2.clone();
            async move {
                let n = calls.fetch_add(1, Ordering::SeqCst);
                if n < 2 { Err(http_err(FailureKind::EdgeTlsFailure)) } else { Ok(()) }
            }
        }).await;

        assert!(result.is_ok());
        assert_eq!(calls.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn origin_unavailable_never_retries_for_at_most_once() {
        let (client, storage) = test_app().await;
        let calls = Arc::new(AtomicU32::new(0));
        let calls2 = calls.clone();
        let result = with_recovery(client, storage, OpKind::Reply, RetrySafety::AtMostOnce, move |_c| {
            let calls = calls2.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>(http_err(FailureKind::OriginUnavailable))
            }
        }).await;

        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn unclassified_error_surfaces_immediately_with_one_call() {
        let (client, storage) = test_app().await;
        let calls = Arc::new(AtomicU32::new(0));
        let calls2 = calls.clone();
        let result = with_recovery(client, storage, OpKind::Login, RetrySafety::Idempotent, move |_c| {
            let calls = calls2.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>(AO3Error::Parse { message: "bad markup".to_string() })
            }
        }).await;

        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn success_on_first_attempt_never_touches_recovery() {
        let (client, storage) = test_app().await;
        let result = with_recovery(client, storage, OpKind::Image, RetrySafety::Idempotent, |_c| async { Ok::<_, AO3Error>(42) }).await;
        assert_eq!(result.unwrap(), 42);
    }
}
