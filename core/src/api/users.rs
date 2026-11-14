//! People by row id (design/users-model-plan.md): the one identity the
//! UI holds for an author or commenter. Profile and listing fetches go to
//! the user's own source; AO3 flows that are username-keyed by nature
//! (follows, subscriptions, block, mute) stay in `social`/`follows`.

use super::*;
use crate::storage::UserRecord;
use super::sources::UResolvedLink;

/// The DTO for a stored user, with the signed-in account's subscription
/// state joined in (AO3 only; it lives in the subscriptions table).
pub(super) fn user_dto(s: &Storage, u: &UserRecord) -> UUser {
    let subscribed = u.source == crate::models::SOURCE_AO3
        && s.subscription_account()
            .map(|a| s.has_subscription(a.id, "author", &u.username).unwrap_or(false))
            .unwrap_or(false);
    UUser::from_record(u, subscribed)
}

#[uniffi::export]
impl AO3App {
    /// A user by row id, from the library. No network.
    pub fn get_user(&self, user_id: u64) -> Option<UUser> {
        let s = self.storage.blocking_lock();
        s.get_user(user_id as i64).map(|u| user_dto(&s, &u))
    }

    /// The users row for an AO3 username (created when never seen) — how
    /// an AO3-keyed surface (a follow, a subscription, a pasted link)
    /// reaches the id-keyed user screens.
    pub fn user_id_for_ao3_username(&self, username: String) -> Result<Option<u64>, AO3Error> {
        let (account, _) = split_author_byline(&username);
        let s = self.storage.blocking_lock();
        Ok(s.ensure_ao3_user_row(&account).map_err(AO3Error::from)?.map(|id| id as u64))
    }

    /// Which source, if any, recognises a profile link, and the user key
    /// it names. No network, no row created.
    pub fn resolve_user_link(&self, link: String) -> Option<UResolvedLink> {
        self.sources.resolve_user(&link).map(|(source, external)| UResolvedLink {
            source: source.id().to_string(),
            external_id: external.external_id,
            url: external.url,
        })
    }

    /// The users row for a source key (created when never seen), named
    /// `username` until a profile fetch supplies the real name. How a
    /// pasted profile link becomes a user to follow.
    pub fn ensure_user(&self, source: String, source_id: String, url: String, username: String) -> Result<u64, AO3Error> {
        let name = if username.trim().is_empty() { source_id.clone() } else { username };
        let s = self.storage.blocking_lock();
        let sighting = crate::models::AO3User {
            source, id: source_id, username: name,
            profile_url: Some(url).filter(|u| !u.is_empty()), avatar_url: None,
        };
        s.record_user(&sighting).map(|id| id as u64).map_err(AO3Error::from)
    }

    /// Users at `source` whose names match `query`, as that source's own
    /// search ranks them. Nothing is stored; picking a hit goes through
    /// `ensure_user`. A source without user search answers an empty list.
    pub async fn search_users(&self, source: String, query: String) -> Result<Vec<UUserHit>, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime(move |client, storage| async move {
            let Some(src) = registry.by_id(&source) else {
                return Err(AO3Error::NotFound { message: format!("no source {source}") });
            };
            if !src.capabilities().user_search { return Ok(Vec::new()) }
            check_reachable(&src)?;
            let hits = with_recovery(client, storage, OpKind::Fetch { label: "user_search".to_string() }, RetrySafety::Idempotent,
                move |_client| {
                    let (src, query) = (src.clone(), query.clone());
                    async move { src.search_users(&query).await.map_err(AO3Error::from) }
                }).await?;
            Ok(hits.into_iter().map(|u| UUserHit {
                source: u.source, source_id: u.id, username: u.username,
                profile_url: u.profile_url.unwrap_or_default(), avatar_url: u.avatar_url.unwrap_or_default(),
            }).collect())
        }).await
    }

    /// The users row for an AO3 username the library already knows; None
    /// when never seen. Never creates a row (safe inside a render pass).
    pub fn lookup_ao3_user_id(&self, username: String) -> Option<u64> {
        let (account, _) = split_author_byline(&username);
        let s = self.storage.blocking_lock();
        s.ao3_user_row_id(&account).map(|id| id as u64)
    }

    /// Works in the library by this user, newest update first.
    pub fn get_works_by_user(&self, user_id: u64) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_works_by_user(user_id as i64).map_err(AO3Error::from)?.into_iter().map(UWorkSummary::from).collect())
    }

    /// Fetch a user's profile from their source and cache it. For an AO3
    /// user the page also mirrors live subscription state into the
    /// signed-in account's subscriptions (never follows).
    pub async fn fetch_user(&self, user_id: u64) -> Result<UUser, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime(move |client, storage| async move {
            let record = { storage.lock().await.get_user(user_id as i64) }
                .ok_or_else(|| AO3Error::NotFound { message: format!("no user with id {user_id}") })?;
            if record.source == crate::models::SOURCE_AO3 {
                let username = record.username.clone();
                let page = with_recovery(client, storage.clone(), OpKind::Fetch { label: "user_profile".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let username = username.clone();
                        async move { client.read().await.fetch_user_profile_full(&username).await.map_err(AO3Error::from) }
                    }).await?;
                let s = storage.lock().await;
                log_db("upsert_user_profile", s.upsert_user_profile(&page.profile));
                // Subscription data only — never follows.
                if let (true, Some(account)) = (page.viewer_signed_in, s.subscription_account()) {
                    if page.subscribed {
                        log_db("add_subscription", s.add_subscription(account.id, "author", &page.profile.username,
                            &page.profile.username, page.subscription_ao3_id.as_deref()));
                    } else {
                        log_db("remove_subscription", s.remove_subscription(account.id, "author", &page.profile.username));
                    }
                }
                let fresh = s.get_user(user_id as i64)
                    .ok_or_else(|| AO3Error::NotFound { message: format!("user {user_id} vanished") })?;
                return Ok(user_dto(&s, &fresh));
            }
            let Some(source) = registry.by_id(&record.source) else {
                return Err(AO3Error::NotFound { message: format!("no source {} for user {user_id}", record.source) });
            };
            check_reachable(&source)?;
            let external = record.external_ref();
            let profile = with_recovery(client, storage.clone(), OpKind::Fetch { label: "user_profile".to_string() }, RetrySafety::Idempotent,
                move |_client| {
                    let (source, external) = (source.clone(), external.clone());
                    async move { source.fetch_author(&external).await.map_err(AO3Error::from) }
                }).await?;
            let s = storage.lock().await;
            log_db("upsert_user_profile", s.upsert_user_profile(&profile));
            let fresh = s.get_user(user_id as i64)
                .ok_or_else(|| AO3Error::NotFound { message: format!("user {user_id} vanished") })?;
            Ok(user_dto(&s, &fresh))
        }).await
    }

    /// One page of a user's works at their source. AO3 users go through
    /// the AO3 listing path (`fetch_author_works`); another source's
    /// adapter lists, and the works land with their figures and authors.
    pub async fn fetch_user_works(&self, user_id: u64, page: u32, op_id: Option<u64>) -> Result<UPagedWorks, AO3Error> {
        let record = { self.storage.lock().await.get_user(user_id as i64) }
            .ok_or_else(|| AO3Error::NotFound { message: format!("no user with id {user_id}") })?;
        if record.source == crate::models::SOURCE_AO3 {
            return self.fetch_author_works(record.username.clone(), None, page, op_id).await;
        }
        let registry = self.sources.clone();
        self.run_on_runtime_for(op_id, move |client, storage| async move {
            let Some(source) = registry.by_id(&record.source) else {
                return Err(AO3Error::NotFound { message: format!("no source {} for user {user_id}", record.source) });
            };
            check_reachable(&source)?;
            let external = record.external_ref();
            let needs_details = source.listings_need_details();
            let listing = super::with_recovery_as(
                client.clone(), storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "author_works".to_string() }, RetrySafety::Idempotent,
                move |_client| {
                    let (source, external) = (source.clone(), external.clone());
                    async move { source.fetch_author_works(&external, page).await.map_err(AO3Error::from) }
                }).await?;
            let mut page = { let s = storage.lock().await; save_listing_page(&s, &listing)? };
            if needs_details {
                fetch_listed_details(client, storage, registry, &mut page, op_id).await?;
            }
            Ok(page)
        }).await
    }
}

/// Follow a saved listing page with each work's own details, for a source
/// whose listings leave something out (`Source::listings_need_details`).
/// One work after another, the shared request pacer's wait before each.
/// A work whose page fails is logged and keeps what the listing gave —
/// one missing story must not stop the author's whole list — but a
/// refused network or a dead session ends the run: every later fetch
/// would fail the same way.
async fn fetch_listed_details(
    client: Arc<tokio::sync::RwLock<AO3Client>>,
    storage: Arc<Mutex<Storage>>,
    registry: Arc<crate::source::SourceRegistry>,
    page: &mut UPagedWorks,
    op_id: Option<u64>,
) -> Result<(), AO3Error> {
    for listed in page.works.iter_mut() {
        crate::client::pacing::request_gap().await;
        match super::works::fetch_and_save_work(client.clone(), storage.clone(), registry.clone(), listed.id, op_id).await {
            Ok(detailed) => *listed = detailed,
            Err(e @ (AO3Error::NetworkDisabled | AO3Error::SessionExpired)) => return Err(e),
            Err(e) => {
                log_error!("listing", "details for work {} failed, keeping the listing's: {e:?}", listed.id);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AO3User, SourceUserProfile};

    #[test]
    fn dto_maps_ao3_properties_to_globals() {
        let s = Storage::open_in_memory("k").unwrap();
        s.record_user(&AO3User::ao3("ambirch", "ambirch", None, None)).unwrap();
        let id = s.upsert_user_profile(&SourceUserProfile {
            source: "ao3".into(), source_id: "ambirch".into(), username: "ambirch".into(),
            properties: vec![
                ("bio".into(), r#"[{"Paragraph":{"text":[{"Text":{"value":"Find me"}}]}}]"#.into()),
                ("works".into(), "17".into()), ("joined".into(), "2022-04-27".into()),
                ("pseuds".into(), r#"["ambirch","AshWrecksEverything"]"#.into()),
            ],
        }).unwrap();
        let u = user_dto(&s, &s.get_user(id).unwrap());
        assert_eq!(u.id, id as u64);
        assert!(u.info_json.as_deref().unwrap().contains("Find me"));
        assert_eq!(u.works, Some(17));
        assert_eq!(u.joined.as_deref(), Some("2022-04-27"));
        assert_eq!(u.pseuds, vec!["ambirch", "AshWrecksEverything"]);
        assert!(u.profile_fetched_at.is_some());
        assert!(u.profile_url.as_deref().unwrap().contains("/users/ambirch"));
    }
}
