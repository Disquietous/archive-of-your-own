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
static CHALLENGES: Mutex<Option<HashMap<OpId, (String, String)>>> = Mutex::new(None);

/// The User-Agent a source's requests must carry, once a clearance has
/// been earned for it. `None` → the shared app User-Agent.
pub fn user_agent(source: &str) -> Option<String> {
    USER_AGENTS.lock().unwrap().as_ref()?.get(source).cloned()
}

pub fn set_user_agent(source: &str, ua: &str) {
    USER_AGENTS.lock().unwrap().get_or_insert_with(HashMap::new).insert(source.to_string(), ua.to_string());
}

/// The transport leaves this when a request under operation `id` came back
/// challenged (HTTP 403): which source, and the page that was asked for —
/// the page the platform shows the user to pass the check on.
pub fn note_challenge(id: OpId, source: &str, url: &str) {
    CHALLENGES.lock().unwrap().get_or_insert_with(HashMap::new)
        .insert(id, (source.to_string(), url.to_string()));
}

/// The recovery engine takes the note when it decides to earn clearance.
pub fn take_challenge(id: OpId) -> Option<(String, String)> {
    CHALLENGES.lock().unwrap().as_mut()?.remove(&id)
}

static CLEARED: Mutex<Option<std::collections::HashSet<OpId>>> = Mutex::new(None);

/// Record that operation `id` earned a clearance; true the first time only.
/// A retry that is challenged again after a passed check means the
/// clearance was not accepted — the check is not shown a second time.
pub fn mark_cleared(id: OpId) -> bool {
    CLEARED.lock().unwrap().get_or_insert_with(Default::default).insert(id)
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
        note_challenge(9001, "scribblehub", "https://www.scribblehub.com/series/1/x/");
        assert_eq!(take_challenge(9001), Some(("scribblehub".into(), "https://www.scribblehub.com/series/1/x/".into())));
        assert_eq!(take_challenge(9001), None);
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
