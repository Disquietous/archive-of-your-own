//! Site clearances: a site's human check (Cloudflare's checkbox), passed
//! by the user in a web view the platform shows, and carried afterwards
//! as the cookies it set plus the User-Agent string that passed it — the
//! clearance cookie is bound to both, so every later request to that site
//! must present the same pair.
//!
//! Three pieces live here: the per-source User-Agent the transport sends
//! (`user_agent`), the note the transport leaves when a request is
//! challenged so the recovery engine knows which site and page to show
//! (`note_challenge` / `take_challenge`), and the persisted form every
//! clearance is restored from after a relaunch or a fresh transport
//! (`load` / `apply` / `save`).
//!
//! A clearance expires, and the site then challenges again: every
//! operation is asked afresh, so the check is simply shown again. What
//! is kept per source (`generation`, `earning_lock`, `dismissals`) makes
//! several operations challenged at once share one sheet.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::events::OpId;
use crate::storage::Storage;

use super::Transport;

/// What the platform hands back after the user passes a site's check.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct SiteClearance {
    /// Every cookie the site set during the check, as `name=value`.
    pub cookies: Vec<String>,
    /// The web view's User-Agent — the one the clearance is bound to.
    pub user_agent: String,
}

/// One saved clearance: the site origin its cookies belong to and the
/// clearance itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedClearance {
    pub origin: String,
    #[serde(flatten)]
    pub clearance: SiteClearance,
}

/// app_state key: a JSON map of source id → `SavedClearance`.
pub const STATE_KEY: &str = "site_clearances";

static USER_AGENTS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);
/// The User-Agent a source's requests must carry, once a clearance has
/// been earned for it. `None` → the shared app User-Agent.
pub fn user_agent(source: &str) -> Option<String> {
    USER_AGENTS.lock().unwrap().as_ref()?.get(source).cloned()
}

pub fn set_user_agent(source: &str, ua: &str) {
    USER_AGENTS.lock().unwrap().get_or_insert_with(HashMap::new).insert(source.to_string(), ua.to_string());
}

/// A challenged request, as the transport noted it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Challenge {
    pub source: String,
    /// The page the platform shows the user to pass the check on.
    pub url: String,
    /// The source's clearance generation when the request was sent
    /// (`generation`): a later generation means a clearance was earned
    /// after this request left, so it is retried instead of asked again.
    pub generation: u64,
}

static CHALLENGES: Mutex<Option<HashMap<OpId, Challenge>>> = Mutex::new(None);

/// Per source: how many clearances have been earned this launch, how many
/// checks the user dismissed (and when the last one was), and the lock
/// that keeps the check to one sheet at a time.
#[derive(Default)]
struct SourceState {
    generation: u64,
    dismissals: u64,
    dismissed_at: Option<std::time::Instant>,
    earning: std::sync::Arc<tokio::sync::Mutex<()>>,
}

static SOURCES: Mutex<Option<HashMap<String, SourceState>>> = Mutex::new(None);

fn with_source<T>(source: &str, f: impl FnOnce(&mut SourceState) -> T) -> T {
    let mut guard = SOURCES.lock().unwrap();
    f(guard.get_or_insert_with(HashMap::new).entry(source.to_string()).or_default())
}

/// How many clearances `source` has earned this launch.
pub fn generation(source: &str) -> u64 { with_source(source, |s| s.generation) }

/// A clearance was just earned for `source`.
pub fn mark_earned(source: &str) { with_source(source, |s| s.generation += 1) }

/// How many checks for `source` the user has dismissed this launch.
pub fn dismissals(source: &str) -> u64 { with_source(source, |s| s.dismissals) }

/// The user dismissed the check for `source`.
pub fn mark_dismissed(source: &str) {
    with_source(source, |s| { s.dismissals += 1; s.dismissed_at = Some(std::time::Instant::now()); })
}

/// Whether the user dismissed a check for `source` within `window`.
pub fn dismissed_within(source: &str, window: std::time::Duration) -> bool {
    with_source(source, |s| s.dismissed_at.is_some_and(|at| at.elapsed() < window))
}

/// The lock held while the check for `source` is on screen: every other
/// challenged operation waits on it instead of raising a second sheet.
pub fn earning_lock(source: &str) -> std::sync::Arc<tokio::sync::Mutex<()>> {
    with_source(source, |s| s.earning.clone())
}

tokio::task_local! {
    static UNATTENDED: ();
}

/// Run `fut` as work nobody is waiting on (the content queue): a check the
/// user just dismissed is not raised again on its behalf.
pub async fn unattended<F: std::future::Future>(fut: F) -> F::Output {
    UNATTENDED.scope((), fut).await
}

pub fn is_unattended() -> bool { UNATTENDED.try_with(|_| ()).is_ok() }

/// Whether a response is a site's human check rather than its answer.
/// Cloudflare marks every challenge it serves with `cf-mitigated:
/// challenge`, whatever the status; a bare 403 is treated the same way
/// (an edge that challenges without the header).
pub fn is_challenge(status: u16, cf_mitigated: Option<&str>) -> bool {
    cf_mitigated.is_some_and(|v| v.trim().eq_ignore_ascii_case("challenge")) || status == 403
}

/// The page the user passes the check on for a challenged request. A GET
/// is shown as asked; a POST's endpoint is no page, so the site's front
/// page stands in (the clearance covers the whole site).
pub fn challenge_page(url: &str, is_get: bool) -> String {
    if is_get { return url.to_string(); }
    origin_of(url).map(|origin| format!("{origin}/")).unwrap_or_else(|| url.to_string())
}

/// The transport leaves this when a request under operation `id` came back
/// challenged: which source, the page to show the user, and the source's
/// clearance generation when the request was sent.
pub fn note_challenge(id: OpId, source: &str, url: &str, generation: u64) {
    CHALLENGES.lock().unwrap().get_or_insert_with(HashMap::new)
        .insert(id, Challenge { source: source.to_string(), url: url.to_string(), generation });
}

/// The recovery engine takes the note when it decides to earn clearance.
pub fn take_challenge(id: OpId) -> Option<Challenge> {
    CHALLENGES.lock().unwrap().as_mut()?.remove(&id)
}

static CLEARED: Mutex<Option<std::collections::HashSet<OpId>>> = Mutex::new(None);

/// Record that operation `id` earned a clearance; true the first time only.
/// A retry that is challenged again after a passed check means the
/// clearance was not accepted — the check is not shown a second time for
/// the same operation. A later operation is asked afresh.
pub fn mark_cleared(id: OpId) -> bool {
    CLEARED.lock().unwrap().get_or_insert_with(Default::default).insert(id)
}

/// Operation `id` is over: drop what was kept for it.
pub fn forget_operation(id: OpId) {
    if let Some(notes) = CHALLENGES.lock().unwrap().as_mut() { notes.remove(&id); }
    if let Some(cleared) = CLEARED.lock().unwrap().as_mut() { cleared.remove(&id); }
}

/// `scheme://host` of a page URL — the origin its cookies are stored for.
pub fn origin_of(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    Some(format!("{}://{}", parsed.scheme(), host))
}

/// Put a clearance to work on the live transport: its cookies into the jar
/// for the site, its User-Agent on the source's requests.
pub fn apply(transport: &Transport, source: &str, saved: &SavedClearance) {
    set_user_agent(source, &saved.clearance.user_agent);
    let joined = saved.clearance.cookies.iter()
        .filter(|c| !c.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join("; ");
    if !joined.is_empty() {
        transport.set_cookies(&saved.origin, &joined);
    }
}

/// Every saved clearance, by source id.
pub fn load(storage: &Storage) -> HashMap<String, SavedClearance> {
    storage.get_state(STATE_KEY).ok().flatten()
        .and_then(|json| serde_json::from_str(&json).ok())
        .unwrap_or_default()
}

/// Record (or replace) a source's clearance.
pub fn save(storage: &Storage, source: &str, saved: &SavedClearance) {
    let mut all = load(storage);
    all.insert(source.to_string(), saved.clone());
    if let Ok(json) = serde_json::to_string(&all) {
        if let Err(e) = storage.set_state(STATE_KEY, &json) {
            log_error!("clearance", "could not persist site clearance for {source}: {e}");
        }
    }
}

/// Re-apply every saved clearance — after a relaunch, or whenever the
/// transport is rebuilt with an empty jar.
pub fn restore_all(storage_snapshot: &HashMap<String, SavedClearance>, transport: &Transport) {
    for (source, saved) in storage_snapshot {
        apply(transport, source, saved);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_strips_path_and_query() {
        assert_eq!(origin_of("https://www.scribblehub.com/series/1/x/?toc=2").as_deref(),
                   Some("https://www.scribblehub.com"));
        assert_eq!(origin_of("not a url"), None);
    }

    #[test]
    fn cleared_once_per_operation() {
        assert!(mark_cleared(9002));
        assert!(!mark_cleared(9002));
    }

    #[test]
    fn challenge_notes_are_taken_once() {
        note_challenge(9001, "scribblehub", "https://www.scribblehub.com/series/1/x/", 3);
        assert_eq!(take_challenge(9001), Some(Challenge {
            source: "scribblehub".into(), url: "https://www.scribblehub.com/series/1/x/".into(), generation: 3,
        }));
        assert_eq!(take_challenge(9001), None);
    }

    #[test]
    fn a_finished_operation_can_be_asked_again() {
        assert!(mark_cleared(9003));
        forget_operation(9003);
        assert!(mark_cleared(9003));
        forget_operation(9003);
    }

    #[test]
    fn challenges_are_told_by_header_or_403() {
        assert!(is_challenge(403, None));
        assert!(is_challenge(503, Some("challenge")));
        assert!(is_challenge(200, Some(" Challenge ")));
        assert!(!is_challenge(503, None));
        assert!(!is_challenge(404, Some("block")));
    }

    #[test]
    fn a_post_is_cleared_on_the_front_page() {
        let ajax = "https://www.scribblehub.com/wp-admin/admin-ajax.php";
        assert_eq!(challenge_page(ajax, false), "https://www.scribblehub.com/");
        assert_eq!(challenge_page("https://www.scribblehub.com/read/1/?gb=2", true), "https://www.scribblehub.com/read/1/?gb=2");
    }

    #[test]
    fn earned_and_dismissed_are_counted_per_source() {
        let before = generation("counting-test");
        mark_earned("counting-test");
        assert_eq!(generation("counting-test"), before + 1);
        assert!(!dismissed_within("counting-test", std::time::Duration::from_secs(60)));
        mark_dismissed("counting-test");
        assert_eq!(dismissals("counting-test"), 1);
        assert!(dismissed_within("counting-test", std::time::Duration::from_secs(60)));
        assert_eq!(generation("other-counting-test"), 0);
    }

    #[tokio::test]
    async fn unattended_is_scoped() {
        assert!(!is_unattended());
        assert!(unattended(async { is_unattended() }).await);
    }

    #[test]
    fn saved_form_round_trips() {
        let saved = SavedClearance {
            origin: "https://www.scribblehub.com".into(),
            clearance: SiteClearance { cookies: vec!["cf_clearance=abc".into()], user_agent: "UA/1".into() },
        };
        let json = serde_json::to_string(&saved).unwrap();
        assert!(json.contains("\"user_agent\":\"UA/1\""), "{json}");
        assert_eq!(serde_json::from_str::<SavedClearance>(&json).unwrap(), saved);
    }

    #[tokio::test]
    async fn apply_sets_cookies_and_user_agent() {
        let transport = Transport::new_direct().await.unwrap();
        let saved = SavedClearance {
            origin: "https://clearance.example".into(),
            clearance: SiteClearance { cookies: vec!["cf_clearance=abc".into(), "__cf_bm=d".into()], user_agent: "UA/2".into() },
        };
        apply(&transport, "clearance-test", &saved);
        assert_eq!(user_agent("clearance-test").as_deref(), Some("UA/2"));
        let header = transport.cookies_for("https://clearance.example");
        assert!(header.contains("cf_clearance=abc") && header.contains("__cf_bm=d"), "{header}");
    }
}
