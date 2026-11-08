use super::*;

// ---------------------------------------------------------------------------
// Follows — the What's New check's only input — and the bell menu that
// couples them to AO3 subscriptions. A follow never sends an AO3 request on
// its own; a subscription change always comes through
// `apply_follow_change`, which keeps the invariant that nothing the app
// subscribes to exists without a follow.
//
// Over the bridge a follow target is named by `kind` plus: the work or
// series row id (as text), the author's username, or the fandom's tag
// name. The core resolves that to a row; a work or series must already
// have a row (a stub, if nothing else — see `resolve_ao3_work`).
// ---------------------------------------------------------------------------

/// Kinds a follow can have. Fandoms are followed but never checked.
const FOLLOW_KINDS: [&str; 4] = ["author", "work", "series", "fandom"];
/// Kinds AO3 can subscribe to.
const SUBSCRIBABLE_KINDS: [&str; 3] = ["author", "work", "series"];

/// The stored key for a target: an author byline ("Pseud (user)") keys on
/// the account username; everything else is the trimmed id/name.
pub(super) fn canonical_target(kind: &str, target: &str) -> String {
    let t = target.trim();
    if kind == "author" && t.parse::<i64>().is_err() {
        split_author_byline(t).0
    } else {
        t.to_string()
    }
}

/// The source a follow target belongs to, for the list's labels.
fn follow_source(s: &Storage, target: FollowTarget) -> String {
    match target {
        FollowTarget::Author(id) => s.get_user(id).map(|u| u.source).unwrap_or_default(),
        FollowTarget::Work(id) => s.work_ref(id).map(|r| r.source).unwrap_or_default(),
        FollowTarget::Series(id) => s.get_series(id).ok().flatten().map(|r| r.source).unwrap_or_default(),
        FollowTarget::Fandom(_) => String::new(),
    }
}

fn invalid(message: &str) -> AO3Error {
    AO3Error::Storage { message: message.to_string() }
}

fn unknown_target(kind: &str, target: &str) -> AO3Error {
    AO3Error::NotFound { message: format!("{kind} '{target}' is not in the library") }
}

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    /// Follows of `kind` (every kind when None), in the order they were added.
    pub fn get_follows(&self, kind: Option<String>) -> Result<Vec<UFollow>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_follows(kind.as_deref()).map_err(AO3Error::from)?
            .into_iter().map(|row| {
                let source = follow_source(&s, row.target);
                UFollow { source, ..UFollow::from(row) }
            }).collect())
    }

    /// Followed / subscribed state for one target's bell.
    pub fn follow_state(&self, kind: String, target_id: String) -> Result<UFollowState, AO3Error> {
        let bridge_id = canonical_target(&kind, &target_id);
        let s = self.storage.blocking_lock();
        let Some(target) = s.follow_target(&kind, &bridge_id) else {
            return Ok(UFollowState { followed: false, subscribed: false });
        };
        let followed = s.is_followed(target).map_err(AO3Error::from)?;
        let subscribed = match (s.subscription_account(), ao3_follow_id(&s, target)) {
            (Some(account), Some(sub_id)) => s.has_subscription(account.id, &kind, &sub_id).map_err(AO3Error::from)?,
            _ => false,
        };
        Ok(UFollowState { followed, subscribed })
    }

    /// Follow a target locally — never an AO3 request. Returns true when the
    /// follow was created (false: already followed).
    pub fn add_follow(&self, kind: String, target_id: String, name: String) -> Result<bool, AO3Error> {
        if !FOLLOW_KINDS.contains(&kind.as_str()) {
            return Err(invalid(&format!("Unknown follow kind: {kind}")));
        }
        let bridge_id = canonical_target(&kind, &target_id);
        if bridge_id.is_empty() {
            return Ok(false);
        }
        let name = if name.trim().is_empty() { bridge_id.clone() } else { name.trim().to_string() };
        let s = self.storage.blocking_lock();
        let Some(target) = s.ensure_follow_target(&kind, &bridge_id).map_err(AO3Error::from)? else {
            return Err(unknown_target(&kind, &bridge_id));
        };
        s.add_follow(target, &name).map_err(AO3Error::from)
    }

    /// Unfollow a target locally. Refused while the signed-in account is
    /// subscribed to it — that unfollow must go through
    /// `apply_follow_change`, which unsubscribes too. Returns true when a
    /// follow was removed.
    pub fn remove_follow(&self, kind: String, target_id: String) -> Result<bool, AO3Error> {
        let bridge_id = canonical_target(&kind, &target_id);
        let s = self.storage.blocking_lock();
        let Some(target) = s.follow_target(&kind, &bridge_id) else { return Ok(false) };
        if let (Some(account), Some(sub_id)) = (s.subscription_account(), ao3_follow_id(&s, target)) {
            if s.has_subscription(account.id, &kind, &sub_id).map_err(AO3Error::from)? {
                return Err(invalid("Subscribed on AO3 — unfollowing must also unsubscribe"));
            }
        }
        s.remove_follow(target).map_err(AO3Error::from)
    }

    /// Perform a confirmed bell-menu change: bring the target to exactly
    /// (`want_followed`, `want_subscribed`). The AO3 request (if the
    /// subscription changes) goes first; local follow/subscription rows are
    /// written only after it succeeds, so a failed request changes nothing.
    /// `want_subscribed` without `want_followed` is refused.
    pub async fn apply_follow_change(&self, kind: String, target_id: String, name: String,
                                     want_followed: bool, want_subscribed: bool)
        -> Result<UFollowChange, AO3Error>
    {
        if want_subscribed && !want_followed {
            return Err(invalid("A subscribed item must also be followed"));
        }
        if !FOLLOW_KINDS.contains(&kind.as_str()) {
            return Err(invalid(&format!("Unknown follow kind: {kind}")));
        }
        self.run_on_runtime(move |client, storage| async move {
            let bridge_id = canonical_target(&kind, &target_id);
            if bridge_id.is_empty() {
                return Err(invalid("Nothing to follow"));
            }
            let name = if name.trim().is_empty() { bridge_id.clone() } else { name.trim().to_string() };
            let (target, account, followed, subscribed, sub_id) = {
                let s = storage.lock().await;
                let Some(target) = s.ensure_follow_target(&kind, &bridge_id).map_err(AO3Error::from)? else {
                    return Err(unknown_target(&kind, &bridge_id));
                };
                let account = s.subscription_account();
                let followed = s.is_followed(target).map_err(AO3Error::from)?;
                let sub_id = ao3_follow_id(&s, target);
                let subscribed = match (&account, &sub_id) {
                    (Some(a), Some(id)) => s.has_subscription(a.id, &kind, id).map_err(AO3Error::from)?,
                    _ => false,
                };
                (target, account, followed, subscribed, sub_id)
            };

            let mut now_subscribed = subscribed;
            let mut ao3_id = None;
            if want_subscribed != subscribed {
                if !SUBSCRIBABLE_KINDS.contains(&kind.as_str()) {
                    return Err(invalid("AO3 has no subscriptions for this kind"));
                }
                let Some(account) = account.clone() else {
                    return Err(AO3Error::Network { message: "Sign in to AO3 to change subscriptions".to_string() });
                };
                let Some(sub_id) = sub_id.clone() else {
                    return Err(invalid("AO3 has no subscriptions for this kind"));
                };
                let (state, id) = set_subscription_remote(
                    client, storage.clone(), account, kind.clone(), sub_id, want_subscribed).await?;
                now_subscribed = state;
                ao3_id = id;
            }
            let subscription_changed = now_subscribed != subscribed;

            let s = storage.lock().await;
            // The account may have changed while the request was in flight;
            // its subscription data was cleared then, so record nothing.
            let still_current = account.is_some()
                && s.subscription_account().map(|a| a.id) == account.as_ref().map(|a| a.id);
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            if subscription_changed && still_current {
                let a = account.as_ref().map(|a| a.id).unwrap_or_default();
                let id = sub_id.clone().unwrap_or_default();
                if now_subscribed {
                    s.add_subscription(a, &kind, &id, &name, ao3_id.as_deref()).map_err(AO3Error::from)?;
                } else {
                    s.remove_subscription(a, &kind, &id).map_err(AO3Error::from)?;
                }
            }
            if now_subscribed != want_subscribed {
                // AO3 didn't land on the requested state — mirror what it
                // has, but leave follows alone.
                tx.commit().map_err(AO3Error::from)?;
                return Err(AO3Error::Network {
                    message: "AO3 didn't apply the subscription change".to_string(),
                });
            }
            let follow_added = want_followed && !followed
                && s.add_follow(target, &name).map_err(AO3Error::from)?;
            let follow_removed = !want_followed && followed
                && s.remove_follow(target).map_err(AO3Error::from)?;
            tx.commit().map_err(AO3Error::from)?;
            log_info!("follows",
                "{kind} '{name}': followed={want_followed} subscribed={now_subscribed} \
                 (subscription changed: {subscription_changed}, follow added: {follow_added}, removed: {follow_removed})");
            Ok(UFollowChange {
                followed: want_followed,
                subscribed: now_subscribed,
                subscription_changed,
                follow_added,
                follow_removed,
            })
        }).await
    }

    /// The signed-in account's subscriptions that have no follow — what the
    /// post-refresh "Follow All" prompt offers. Empty when signed out.
    pub fn get_unfollowed_subscriptions(&self) -> Result<Vec<USubscription>, AO3Error> {
        let s = self.storage.blocking_lock();
        let Some(account) = s.subscription_account() else { return Ok(Vec::new()) };
        Ok(s.get_unfollowed_subscriptions(account.id).map_err(AO3Error::from)?
            .into_iter()
            .map(super::social::usubscription)
            .collect())
    }

    /// Follow every given subscription's target in one transaction — the
    /// user accepted "Follow All". No AO3 request. A subscribed work or
    /// series the library never cached gets a stub row so the follow has
    /// a target. Returns how many follows were created.
    pub fn follow_subscriptions(&self, subscriptions: Vec<USubscription>) -> Result<u32, AO3Error> {
        let s = self.storage.blocking_lock();
        let tx = s.begin_tx().map_err(AO3Error::from)?;
        let mut created = 0u32;
        for sub in &subscriptions {
            if !SUBSCRIBABLE_KINDS.contains(&sub.sub_type.as_str()) {
                continue;
            }
            let ao3_id = canonical_target(&sub.sub_type, &sub.id);
            if ao3_id.is_empty() {
                continue;
            }
            let name = if sub.name.trim().is_empty() { ao3_id.clone() } else { sub.name.clone() };
            let target = match sub.sub_type.as_str() {
                "work" => {
                    let Ok(n) = ao3_id.parse::<u64>() else { continue };
                    let external = ExternalRef::ao3(ao3_id.clone(), crate::parser::ao3_work_url(n));
                    FollowTarget::Work(s.ensure_work_stub(&external, &name).map_err(AO3Error::from)?)
                }
                "series" => {
                    let Ok(n) = ao3_id.parse::<u64>() else { continue };
                    let external = ExternalRef::ao3(ao3_id.clone(), crate::parser::ao3_series_url(n));
                    FollowTarget::Series(s.ensure_series(&external, &name).map_err(AO3Error::from)?)
                }
                _ => match s.ensure_follow_target("author", &ao3_id).map_err(AO3Error::from)? {
                    Some(t) => t,
                    None => continue,
                },
            };
            if s.add_follow(target, &name).map_err(AO3Error::from)? {
                created += 1;
            }
        }
        tx.commit().map_err(AO3Error::from)?;
        Ok(created)
    }
}

/// Set the signed-in account's AO3 subscription for a target to exactly
/// `want`. `target` is AO3's identifier (username, or work/series number
/// as text). Prefers the direct one-POST paths (cached CSRF token; stored
/// record id for unsubscribe) and falls back to the intent-aware page path,
/// which reads live state and only submits when it differs — a harmless
/// no-op when AO3 already has the desired state. Returns the resulting state
/// and AO3's record id when subscribed.
async fn set_subscription_remote(
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    account: crate::storage::AccountRow,
    kind: String,
    target: String,
    want: bool,
) -> Result<(bool, Option<String>), AO3Error> {
    let numeric = target.parse::<u64>().ok();
    if kind != "author" && numeric.is_none() {
        return Err(invalid(&format!("Not a {kind} id: {target}")));
    }
    let username = account.username.clone();
    let (stored_ao3_id, profile_id) = {
        let s = storage.lock().await;
        (s.get_subscription_ao3_id(account.id, &kind, &target).unwrap_or(None),
         if kind == "author" {
             s.get_ao3_user_record(&target).and_then(|u| u.field(crate::user_fields::UserField::NumericId).map(str::to_string))
         } else {
             None
         })
    };

    let c = client.read().await;
    let mut outcome: Option<(bool, Option<String>)> = None;
    if want {
        let direct = match (kind.as_str(), numeric) {
            ("author", _) => match &profile_id {
                Some(nid) => c.subscribe_user_direct(&username, nid).await,
                None => Ok(None),
            },
            ("work", Some(id)) => c.subscribe_work_direct(&username, id).await,
            ("series", Some(id)) => c.subscribe_series_direct(&username, id).await,
            _ => Ok(None),
        };
        if let Ok(Some(new_id)) = direct {
            outcome = Some((true, Some(new_id)));
        }
    } else if let Some(ref ao3_id) = stored_ao3_id {
        // The unsubscribe endpoint is type-agnostic.
        if let Ok(true) = c.unsubscribe_work_direct(&username, ao3_id).await {
            outcome = Some((false, None));
        }
    }
    drop(c);
    if let Some(o) = outcome {
        return Ok(o);
    }
    with_recovery(client, storage, OpKind::Fetch { label: format!("{kind}_subscribe") }, RetrySafety::Idempotent,
        move |client| {
            let (kind, target) = (kind.clone(), target.clone());
            async move {
                let c = client.read().await;
                match (kind.as_str(), numeric) {
                    ("work", Some(id)) => c.set_work_subscription(id, want).await,
                    ("series", Some(id)) => c.set_series_subscription(id, want).await,
                    _ => c.set_user_subscription(&target, want).await,
                }.map_err(AO3Error::from)
            }
        }).await
}
