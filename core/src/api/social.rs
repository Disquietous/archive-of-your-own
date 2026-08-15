use super::*;

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    // -- Kudos --

    pub async fn leave_kudos(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
            }
            // AO3 answers a duplicate kudos with "already left kudos"
            // rather than erroring, so a full retry after rotation can
            // never double-apply — safe to retry for every failure kind.
            let accepted = with_recovery(client.clone(), storage.clone(), OpKind::Kudos, RetrySafety::Idempotent,
                move |client| {
                    let work_id = work_id;
                    async move {
                        client.read().await.leave_kudos(work_id).await.map_err(AO3Error::from)
                    }
                }).await?;
            let c = client.read().await;
            let s = storage.lock().await;
            persist_posting_credentials(&c, &s);
            if accepted {
                // Kudos are permanent on AO3 — record it so the UI stays
                // truthful across launches.
                log_db("mark_kudos_given", s.mark_kudos_given(work_id));
            }
            Ok(accepted)
        }).await
    }

    /// Works this device has successfully left kudos on.
    pub fn get_kudos_given(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_kudos_given().map_err(AO3Error::from)
    }

    pub async fn post_comment(&self, work_id: u64, chapter_id: u64, comment: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
            }
            let base = crate::client::BASE_URL;
            let (endpoint, controller, form_page) = if chapter_id == 0 {
                (format!("{base}/works/{work_id}/comments"), "works",
                 format!("{base}/works/{work_id}?show_comments=true&view_adult=true"))
            } else {
                (format!("{base}/chapters/{chapter_id}/comments"), "chapters",
                 format!("{base}/works/{work_id}/chapters/{chapter_id}?show_comments=true&view_adult=true"))
            };
            // A comment creates a new record with no natural dedup, so this
            // only retries failures that are provably pre-origin (525) —
            // never on an ambiguous timeout, which could have already posted.
            let posted = with_recovery(client.clone(), storage.clone(), OpKind::Comment, RetrySafety::AtMostOnce,
                move |client| {
                    let (endpoint, controller, form_page, comment) =
                        (endpoint.clone(), controller, form_page.clone(), comment.clone());
                    async move {
                        client.read().await.post_comment_direct(&endpoint, controller, &form_page, &comment)
                            .await.map_err(AO3Error::from)
                    }
                }).await?;
            let c = client.read().await;
            let s = storage.lock().await;
            persist_posting_credentials(&c, &s);
            Ok(posted)
        }).await
    }

    pub async fn fetch_chapter_comments(&self, work_id: u64, chapter_id: u64, page: u32) -> Result<UCommentsPage, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let cp = with_recovery(client, storage.clone(), OpKind::Fetch { label: "comments".to_string() }, RetrySafety::Idempotent,
                move |client| async move {
                    client.read().await.fetch_comments_for_chapter(work_id, chapter_id, page).await.map_err(AO3Error::from)
                }).await?;
            let s = storage.lock().await;
            for comment in &cp.comments {
                log_db("save_comment", s.save_comment(0, chapter_id, comment));
            }
            let json_comments: Vec<CommentJson> = cp.comments.into_iter().map(CommentJson::from).collect();
            Ok(UCommentsPage {
                comments_json: serde_json::to_string(&json_comments).unwrap_or("[]".to_string()),
                current_page: cp.current_page,
                total_pages: cp.total_pages,
            })
        }).await
    }

    pub async fn fetch_work_comments(&self, work_id: u64, page: u32) -> Result<UCommentsPage, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let cp = with_recovery(client, storage.clone(), OpKind::Fetch { label: "comments".to_string() }, RetrySafety::Idempotent,
                move |client| async move {
                    client.read().await.fetch_comments_for_work(work_id, page).await.map_err(AO3Error::from)
                }).await?;
            let s = storage.lock().await;
            for comment in &cp.comments {
                log_db("save_comment", s.save_comment(work_id, 0, comment));
            }
            let json_comments: Vec<CommentJson> = cp.comments.into_iter().map(CommentJson::from).collect();
            Ok(UCommentsPage {
                comments_json: serde_json::to_string(&json_comments).unwrap_or("[]".to_string()),
                current_page: cp.current_page,
                total_pages: cp.total_pages,
            })
        }).await
    }

    pub fn get_cached_comments(&self, work_id: u64, chapter_id: u64) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        let comments = storage.get_comments(work_id, chapter_id).map_err(AO3Error::from)?;
        let json_comments: Vec<CommentJson> = comments.into_iter().map(CommentJson::from).collect();
        Ok(serde_json::to_string(&json_comments).unwrap_or("[]".to_string()))
    }

    pub async fn post_reply(&self, parent_comment_id: u64, comment: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
            }
            // Same reasoning as post_comment: AtMostOnce, only 525 retries.
            let posted = with_recovery(client.clone(), storage.clone(), OpKind::Reply, RetrySafety::AtMostOnce,
                move |client| {
                    let comment = comment.clone();
                    async move {
                        client.read().await.post_reply(parent_comment_id, &comment).await.map_err(AO3Error::from)
                    }
                }).await?;
            let c = client.read().await;
            let s = storage.lock().await;
            persist_posting_credentials(&c, &s);
            Ok(posted)
        }).await
    }

    // -- Subscription notifications --

    pub async fn fetch_subscriptions(&self, username: String) -> Result<Vec<USubscription>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let mut all_subs = Vec::new();
            let mut seen = std::collections::HashSet::new();
            let mut page = 1u32;
            loop {
                let username_for_fetch = username.clone();
                let (subs, has_more) = with_recovery(
                    client.clone(), storage.clone(), OpKind::Fetch { label: "subscriptions".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let username = username_for_fetch.clone();
                        async move {
                            client.read().await.fetch_subscriptions(&username, page).await.map_err(AO3Error::from)
                        }
                    }).await?;
                for s in subs {
                    let u = USubscription::from(s);
                    if seen.insert((u.sub_type.clone(), u.id.clone())) {
                        all_subs.push(u);
                    }
                }
                if !has_more { break; }
                page += 1;
            }

            // Backfill ao3_users for subscribed authors we've never recorded:
            // one profile-page request each, once ever. A fetch failure just
            // leaves the user unrecorded for the next refresh to retry.
            let unknown: Vec<String> = {
                let s = storage.lock().await;
                all_subs.iter()
                    .filter(|u| u.sub_type == "author")
                    .filter(|u| !s.has_ao3_user_with_username(&u.id).unwrap_or(true))
                    .map(|u| u.id.clone())
                    .collect()
            };
            for author in unknown {
                let author_for_fetch = author.clone();
                let profile = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "user_profile".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let author = author_for_fetch.clone();
                        async move { client.read().await.fetch_user_profile(&author).await.map_err(AO3Error::from) }
                    }).await;
                let profile = match profile {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                let s = storage.lock().await;
                log_db("upsert_ao3_user", s.upsert_ao3_user(&profile));
            }

            Ok(all_subs)
        }).await
    }

    /// Toggle the AO3 subscription for a work and mirror the result into
    /// the local subscriptions table. Prefers the direct one-POST paths
    /// (cached CSRF token; stored record id for unsubscribe) and falls back
    /// to the intent-aware page-fetch path when those can't run or fail.
    /// Returns the new state: true = now subscribed.
    pub async fn toggle_work_subscription(&self, work_id: u64, username: Option<String>)
        -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let id = work_id.to_string();
            let (locally_subscribed, stored_ao3_id) = {
                let s = storage.lock().await;
                (s.has_subscription("work", &id).unwrap_or(false),
                 s.get_subscription_ao3_id("work", &id).unwrap_or(None))
            };
            let want = !locally_subscribed;

            let c = client.read().await;
            let mut outcome: Option<(bool, Option<String>)> = None;
            if let Some(user) = username.as_deref().filter(|u| !u.is_empty()) {
                if want {
                    if let Ok(Some(new_id)) = c.subscribe_work_direct(user, work_id).await {
                        outcome = Some((true, Some(new_id)));
                    }
                } else if let Some(ref ao3_id) = stored_ao3_id {
                    if let Ok(true) = c.unsubscribe_work_direct(user, ao3_id).await {
                        outcome = Some((false, None));
                    }
                }
            }
            drop(c);
            // Ambiguous or impossible direct path: the page-fetch path reads
            // live state and only submits when it differs from `want`. This
            // is the one branch above that propagates a hard error, so it's
            // the one worth routing through the recovery engine.
            let (subscribed, ao3_id) = match outcome {
                Some(o) => o,
                None => with_recovery(client, storage.clone(), OpKind::Fetch { label: "work_subscribe".to_string() }, RetrySafety::Idempotent,
                    move |client| async move {
                        client.read().await.set_work_subscription(work_id, want).await.map_err(AO3Error::from)
                    }).await?,
            };

            let s = storage.lock().await;
            if subscribed {
                let name = s.get_work(work_id).ok().flatten()
                    .map(|w| w.title)
                    .unwrap_or_else(|| format!("Work {work_id}"));
                log_db("add_subscription", s.add_subscription("work", &id, &name, ao3_id.as_deref()));
            } else {
                log_db("remove_subscription", s.remove_subscription("work", &id));
            }
            Ok(subscribed)
        }).await
    }

    // -- User profiles (subscribe / block / mute) --

    /// The locally cached profile for a user — instant, DB-only. None when
    /// no profile fetch has ever been recorded for them.
    pub fn get_cached_user_profile(&self, username: String) -> Result<Option<UUserProfile>, AO3Error> {
        let (username, _) = split_author_byline(&username);
        let s = self.storage.blocking_lock();
        Ok(s.get_user_profile(&username).map_err(AO3Error::from)?.map(UUserProfile::from))
    }

    /// Fetch a user's profile from AO3, cache it, and mirror the live
    /// subscription state into the local subscriptions table (only when
    /// the session was signed in — a logged-out page carries no signal).
    pub async fn fetch_user_profile(&self, username: String) -> Result<UUserProfile, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (username, _) = split_author_byline(&username);
            let profile = with_recovery(client, storage.clone(), OpKind::Fetch { label: "user_profile".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let username = username.clone();
                    async move {
                        client.read().await.fetch_user_profile_full(&username).await.map_err(AO3Error::from)
                    }
                }).await?;
            let s = storage.lock().await;
            log_db("upsert_user_profile", s.upsert_user_profile(&profile));
            if profile.viewer_signed_in {
                if profile.subscribed {
                    log_db("add_subscription", s.add_subscription("author", &profile.username,
                        &profile.username, profile.subscription_ao3_id.as_deref()));
                } else {
                    log_db("remove_subscription", s.remove_subscription("author", &profile.username));
                }
            }
            Ok(UUserProfile::from(profile))
        }).await
    }

    /// One page of a user's public bookmarks (/users/{name}/bookmarks).
    /// Everything the listing showed is cached like collection bookmark
    /// listings: the works, and the bookmark rows scoped to whoever made
    /// them (only the active user's own land in the Bookmarks view).
    /// Series/external bookmarks are skipped by the parser.
    pub async fn fetch_user_bookmarks_page(&self, username: String, page: u32) -> Result<UPagedWorks, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (username, _) = split_author_byline(&username);
            let fetch_user = username.clone();
            let (listings, has_next, total, found) = with_recovery(
                client, storage.clone(),
                OpKind::Fetch { label: "user_bookmarks".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let username = fetch_user.clone();
                    async move {
                        client.read().await.fetch_user_bookmarks(&username, page).await.map_err(AO3Error::from)
                    }
                }).await?;
            let s = storage.lock().await;
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            let mut works = Vec::new();
            for l in listings {
                let Some(w) = l.work_summary else { continue };
                log_db("save_work", s.save_work(&w));
                log_db("cache_fetched_bookmark",
                       s.cache_fetched_bookmark(&l.bookmarker, l.work_id, l.ao3_bookmark_id, &l.note));
                works.push(w);
            }
            log_db("commit listing save", tx.commit());
            Ok(UPagedWorks {
                works: works.into_iter().map(UWorkSummary::from).collect(),
                has_next_page: has_next,
                total_pages: total,
                total_works: found,
            })
        }).await
    }

    /// One page of a user's collections (/users/{name}/collections). Every
    /// fetched blurb lands in the collections cache exactly like the public
    /// index pages, tags included.
    pub async fn fetch_user_collections(&self, username: String, page: u32) -> Result<UCollectionsPage, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (username, _) = split_author_byline(&username);
            let fetch_user = username.clone();
            let (collections, has_next, total) = with_recovery(
                client, storage.clone(),
                OpKind::Fetch { label: "user_collections".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let username = fetch_user.clone();
                    async move {
                        client.read().await.fetch_user_collections(&username, page).await.map_err(AO3Error::from)
                    }
                }).await?;
            log_debug!("collections",
                "fetch_user_collections '{username}' page {page}: parsed {} blurb(s) (has_next={has_next}, total_pages={total}) — saving",
                collections.len());
            {
                let s = storage.lock().await;
                log_db("save_collections", s.save_collections(&collections));
            }
            Ok(UCollectionsPage {
                collections: collections.into_iter().map(UCollection::from).collect(),
                has_next_page: has_next,
                total_pages: total,
            })
        }).await
    }

    /// Toggle the AO3 subscription for a user and mirror the result into
    /// the local subscriptions table (sub_type "author", so it shows under
    /// Subscriptions → Following immediately). Prefers the direct one-POST
    /// paths and falls back to the intent-aware profile-page path.
    /// Returns the new state: true = now subscribed.
    pub async fn toggle_user_subscription(&self, target: String, username: Option<String>)
        -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (target, _) = split_author_byline(&target);
            let (locally_subscribed, stored_ao3_id, numeric_id) = {
                let s = storage.lock().await;
                (s.has_subscription("author", &target).unwrap_or(false),
                 s.get_subscription_ao3_id("author", &target).unwrap_or(None),
                 s.get_user_profile(&target).ok().flatten().and_then(|p| p.numeric_id))
            };
            let want = !locally_subscribed;

            let c = client.read().await;
            let mut outcome: Option<(bool, Option<String>)> = None;
            if let Some(user) = username.as_deref().filter(|u| !u.is_empty()) {
                if want {
                    if let Some(ref nid) = numeric_id {
                        if let Ok(Some(new_id)) = c.subscribe_user_direct(user, nid).await {
                            outcome = Some((true, Some(new_id)));
                        }
                    }
                } else if let Some(ref ao3_id) = stored_ao3_id {
                    // The unsubscribe endpoint is type-agnostic — same
                    // record-id POST works for user subscriptions.
                    if let Ok(true) = c.unsubscribe_work_direct(user, ao3_id).await {
                        outcome = Some((false, None));
                    }
                }
            }
            drop(c);
            let (subscribed, ao3_id) = match outcome {
                Some(o) => o,
                None => {
                    let target_for_fetch = target.clone();
                    with_recovery(client, storage.clone(), OpKind::Fetch { label: "user_subscribe".to_string() }, RetrySafety::Idempotent,
                        move |client| {
                            let target = target_for_fetch.clone();
                            async move { client.read().await.set_user_subscription(&target, want).await.map_err(AO3Error::from) }
                        }).await?
                }
            };

            let s = storage.lock().await;
            if subscribed {
                log_db("add_subscription", s.add_subscription("author", &target, &target, ao3_id.as_deref()));
            } else {
                log_db("remove_subscription", s.remove_subscription("author", &target));
            }
            Ok(subscribed)
        }).await
    }

    /// Toggle blocking a user on AO3 and mirror the result locally.
    /// Returns the new state: true = now blocked.
    pub async fn toggle_user_block(&self, target: String, username: String)
        -> Result<bool, AO3Error> {
        self.toggle_user_moderation(target, username, "blocked").await
    }

    /// Toggle muting a user on AO3 and mirror the result locally.
    /// Returns the new state: true = now muted.
    pub async fn toggle_user_mute(&self, target: String, username: String)
        -> Result<bool, AO3Error> {
        self.toggle_user_moderation(target, username, "muted").await
    }

    // -- Subscription persistence (user-triggered refresh) --

    pub fn persist_subscriptions(&self, subscriptions: Vec<USubscription>) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let tuples: Vec<(String, String, String, Option<String>)> = subscriptions
            .into_iter()
            .map(|u| (u.sub_type, u.id, u.name, u.ao3_id))
            .collect();
        s.save_subscriptions(&tuples).map_err(AO3Error::from)
    }

    pub fn get_persisted_subscriptions(&self) -> Result<Vec<USubscription>, AO3Error> {
        let s = self.storage.blocking_lock();
        let rows = s.get_subscriptions().map_err(AO3Error::from)?;
        Ok(rows.into_iter()
            .map(|(t, id, name, ao3_id)| USubscription { sub_type: t, id, name, ao3_id })
            .collect())
    }

    pub fn save_subscription_works(&self, sub_type: String, sub_id: String, work_ids: Vec<u64>) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.save_subscription_works(&sub_type, &sub_id, &work_ids).map_err(AO3Error::from)
    }

    pub fn get_subscription_works(&self, sub_type: String, sub_id: String) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        let works = s.get_subscription_works(&sub_type, &sub_id).map_err(AO3Error::from)?;
        Ok(works.into_iter().map(UWorkSummary::from).collect())
    }

    pub fn get_works_by_author(&self, username: String) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        let works = s.get_works_by_author(&username).map_err(AO3Error::from)?;
        Ok(works.into_iter().map(UWorkSummary::from).collect())
    }

    /// Fetch a comment thread from AO3 (or cache) for display in the reading pane.
    /// Checks the local DB first; if the comment isn't cached, paginates
    /// through the work's comment pages until found.
    pub async fn fetch_comment_thread(&self, work_url: String, comment_id: u64) -> Result<String, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let work_id: u64 = work_url.split('/')
                .find(|s| s.chars().all(|c| c.is_ascii_digit()) && !s.is_empty())
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);

            if work_id == 0 {
                return Err(AO3Error::Network { message: "Invalid work URL".to_string() });
            }

            fn find_root_thread(comments: &[Comment], target_id: u64) -> Option<Comment> {
                fn contains(comment: &Comment, id: u64) -> bool {
                    if comment.id == id { return true; }
                    comment.replies.iter().any(|r| contains(r, id))
                }
                for comment in comments {
                    if contains(comment, target_id) {
                        return Some(comment.clone());
                    }
                }
                None
            }

            fn comment_to_json(comment: &Comment) -> serde_json::Value {
                serde_json::json!({
                    "id": comment.id,
                    "author": comment.author.username,
                    "author_url": comment.author.profile_url.as_deref().unwrap_or(""),
                    "avatar_url": comment.author.avatar_url.as_deref().unwrap_or(""),
                    "posted_at": comment.posted_at,
                    "content_json": serde_json::to_string(&comment.content).unwrap_or("[]".to_string()),
                    "replies": comment.replies.iter().map(comment_to_json).collect::<Vec<_>>(),
                })
            }

            // 1. Check DB cache first
            {
                let s = storage.lock().await;
                if let Ok(Some(root)) = s.get_comment_thread(comment_id) {
                    let result = serde_json::json!({
                        "thread": comment_to_json(&root),
                        "target_comment_id": comment_id,
                    });
                    return Ok(serde_json::to_string(&result).unwrap_or("{}".to_string()));
                }
            }

            // 2. Not cached — paginate through comment pages until found
            let mut page = 1u32;
            let mut total_pages = 1u32;
            let mut found_thread: Option<Comment> = None;

            while page <= total_pages {
                let comments_page = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "comments".to_string() }, RetrySafety::Idempotent,
                    move |client| async move {
                        client.read().await.fetch_comments_for_work(work_id, page).await.map_err(AO3Error::from)
                    }).await?;

                total_pages = comments_page.total_pages.max(1);

                // Persist all comments from this page
                {
                    let s = storage.lock().await;
                    for comment in &comments_page.comments {
                        log_db("save_comment", s.save_comment(work_id, 0, comment));
                    }
                }

                // Check if the target is on this page
                if let Some(root) = find_root_thread(&comments_page.comments, comment_id) {
                    found_thread = Some(root);
                    break;
                }

                page += 1;
            }

            // 3. If we paginated through everything and found nothing in the
            //    parsed trees, the comment might have been persisted during
            //    pagination as a child — check the DB one more time.
            if found_thread.is_none() {
                let s = storage.lock().await;
                if let Ok(Some(root)) = s.get_comment_thread(comment_id) {
                    found_thread = Some(root);
                }
            }

            let result = serde_json::json!({
                "thread": found_thread.as_ref().map(comment_to_json),
                "target_comment_id": comment_id,
            });
            Ok(serde_json::to_string(&result).unwrap_or("{}".to_string()))
        }).await
    }

    /// An author's avatar: served from the DB cache when present. On a miss,
    /// a known avatar URL — the caller's hint (inbox/comment data carries
    /// one) or one recorded in ao3_users — means a single image request;
    /// only a never-seen user costs the profile-page fetch as well. The
    /// bytes are cached forever either way.
    pub async fn fetch_author_avatar(&self, username: String, url_hint: Option<String>) -> Result<Vec<u8>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let key = format!("avatar:{username}");
            let known_url = {
                let s = storage.lock().await;
                if let Some(data) = s.get_cached_image(&key).map_err(AO3Error::from)? {
                    return Ok(data);
                }
                url_hint.filter(|u| !u.is_empty())
                    .or_else(|| s.get_known_avatar_url(&username).unwrap_or(None))
            };
            let (bytes, fetched_icon_url) = if let Some(url) = known_url {
                let bytes = with_recovery(client.clone(), storage.clone(), OpKind::Image, RetrySafety::Idempotent,
                    move |client| {
                        let url = url.clone();
                        async move { client.read().await.fetch_image(&url).await.map_err(AO3Error::from) }
                    }).await?;
                (bytes, None)
            } else {
                let username_for_fetch = username.clone();
                let (bytes, icon_url) = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "user_profile".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let username = username_for_fetch.clone();
                        async move { client.read().await.fetch_user_icon(&username).await.map_err(AO3Error::from) }
                    }).await?;
                (bytes, Some(icon_url))
            };
            let s = storage.lock().await;
            // A profile-page fetch is the authoritative source for this
            // user's avatar URL — record it so future lookups skip the
            // profile request.
            if let Some(icon_url) = fetched_icon_url {
                log_db("upsert_ao3_user", s.upsert_ao3_user(&AO3User {
                    id: username.clone(),
                    username: username.clone(),
                    profile_url: Some(format!("{}/users/{}", crate::client::BASE_URL, username)),
                    avatar_url: Some(icon_url),
                }));
            }
            log_db("save_cached_image", s.save_cached_image(&key, &bytes));
            Ok(bytes)
        }).await
    }
}
