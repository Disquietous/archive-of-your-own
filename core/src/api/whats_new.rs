use super::*;

#[uniffi::export]
impl AO3App {
    // -- Sequential subscription check queue --

    /// Build (or resume) the What's-New check queue. `extra_authors` are
    /// device-local follows — they join the queue as author checks,
    /// deduplicated against real author subscriptions. The combined queue
    /// is sorted alphabetically by display name so the user can predict
    /// where a given check lands in the request order.
    pub fn start_subscription_check(&self, extra_authors: Vec<String>) -> Result<u32, AO3Error> {
        self.census_cycle_used.store(false, std::sync::atomic::Ordering::Relaxed);
        let s = self.storage.blocking_lock();
        // Resume if a queue already exists
        if let Some(json) = s.get_check_queue().map_err(AO3Error::from)? {
            let arr: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap_or_default();
            if !arr.is_empty() {
                return Ok(arr.len() as u32);
            }
        }
        // Fresh queue: persisted subscriptions plus followed authors.
        let subs = s.get_subscriptions().map_err(AO3Error::from)?;
        let mut entries: Vec<(String, String, String)> = subs.into_iter()
            .map(|(t, id, name, _)| (t, id, name))
            .collect();
        for follow in &extra_authors {
            let display = follow.trim();
            let (user, _) = split_author_byline(display);
            if user.is_empty() {
                continue;
            }
            let duplicate = entries.iter().any(|(t, id, _)|
                t == "author" && id.eq_ignore_ascii_case(&user));
            if !duplicate {
                entries.push(("author".to_string(), user, display.to_string()));
            }
        }
        entries.sort_by(|a, b| a.2.to_lowercase().cmp(&b.2.to_lowercase()));
        let arr: Vec<serde_json::Value> = entries.iter().map(|(t, id, name)| {
            serde_json::json!({"sub_type": t, "sub_id": id, "name": name})
        }).collect();
        let json = serde_json::to_string(&arr).unwrap_or_else(|_| "[]".to_string());
        s.set_check_queue(&json).map_err(AO3Error::from)?;
        Ok(arr.len() as u32)
    }

    pub fn reset_subscription_check(&self) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.clear_check_queue().map_err(AO3Error::from)
    }

    // -- What's New work list --

    pub fn get_new_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_new_work_ids().map_err(AO3Error::from)
    }

    /// Works a census confirmed are no longer listed on AO3 (cached copies
    /// are retained; this is display metadata).
    pub fn get_gone_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_gone_work_ids().map_err(AO3Error::from)
    }

    /// Stamp that the user opened a chapter of this work right now —
    /// drives the Currently Reading sort (latest first).
    pub fn mark_work_read(&self, work_id: u64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.mark_work_read(work_id).map_err(AO3Error::from)
    }

    pub fn get_work_last_read_times(&self) -> Result<Vec<ULastRead>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_work_last_read_times()
            .map_err(AO3Error::from)?
            .into_iter()
            .map(|(id, at)| ULastRead { work_id: id, last_read_dt: at })
            .collect())
    }

    /// Record that the user opened this work's detail view (first view
    /// wins). The What's New badge counts only never-viewed works.
    pub fn mark_work_detail_viewed(&self, work_id: u64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.mark_work_detail_viewed(work_id, &now_utc()).map_err(AO3Error::from)
    }

    pub fn get_detail_viewed_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_detail_viewed_work_ids().map_err(AO3Error::from)
    }

    /// Stamp "a full works crawl for this author/series completed now".
    pub fn set_works_crawled_now(&self, sub_type: String, sub_id: String) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.set_works_crawled_at(&sub_type, &sub_id, &now_utc()).map_err(AO3Error::from)
    }

    /// UTC "YYYY-MM-DD HH:MM:SS" of the last completed works crawl, or None.
    pub fn get_works_crawled_at(&self, sub_type: String, sub_id: String) -> Result<Option<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_works_crawled_at(&sub_type, &sub_id).map_err(AO3Error::from)
    }

    pub fn remove_new_work(&self, work_id: u64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.remove_new_work_id(work_id).map_err(AO3Error::from)
    }

    pub fn clear_new_works(&self) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.clear_new_work_ids().map_err(AO3Error::from)
    }

    pub async fn check_next_subscription(&self) -> Result<Option<USubscriptionCheckResult>, AO3Error> {
        let census_cycle_used = self.census_cycle_used.clone();
        self.run_on_runtime(move |client, storage| async move {
            let s = storage.lock().await;
            // Pop the first item from the queue
            let queue_json = s.get_check_queue().map_err(AO3Error::from)?
                .unwrap_or_else(|| "[]".to_string());
            let mut queue: Vec<serde_json::Value> = serde_json::from_str(&queue_json)
                .unwrap_or_default();
            if queue.is_empty() {
                return Ok(None);
            }
            let item = queue.remove(0);
            let sub_type = item["sub_type"].as_str().unwrap_or("").to_string();
            let sub_id = item["sub_id"].as_str().unwrap_or("").to_string();
            let sub_name = item["name"].as_str().unwrap_or("").to_string();
            let is_census = item["census"].as_bool().unwrap_or(false);

            // Persist updated queue before the fetch (so a crash mid-fetch
            // skips this item rather than retrying it forever).
            let mut remaining = queue.len() as u32;
            let updated_json = serde_json::to_string(&queue).unwrap_or_else(|_| "[]".to_string());
            log_db("set_check_queue", s.set_check_queue(&updated_json));

            // Census continuations read their page cursor from the persisted
            // state, not the queue marker — cancel/crash resumes cleanly.
            let census_state: Option<CensusState> = if is_census {
                s.get_snapshot_census_meta(&sub_type, &sub_id)
                    .ok()
                    .and_then(|(_, _, state)| state)
                    .and_then(|json| serde_json::from_str(&json).ok())
            } else {
                None
            };
            drop(s);

            if is_census && census_state.is_none() {
                // Orphaned marker — its state was cleared elsewhere.
                return Ok(Some(USubscriptionCheckResult {
                    sub_type, sub_id, name: sub_name, changed: false, remaining, error: None,
                }));
            }

            // Build URL
            let base = crate::client::BASE_URL;
            let census_page = census_state.as_ref().map(|c| c.next_page);
            let url = match (sub_type.as_str(), census_page) {
                ("author", None) => format!("{base}/users/{sub_id}/works"),
                ("author", Some(p)) => format!("{base}/users/{sub_id}/works?page={p}"),
                ("series", None) => format!("{base}/series/{sub_id}"),
                ("series", Some(p)) => format!("{base}/series/{sub_id}?page={p}"),
                ("work", _) => format!("{base}/works/{sub_id}?view_adult=true"),
                _ => return Ok(Some(USubscriptionCheckResult {
                    sub_type, sub_id, name: sub_name, changed: false, remaining,
                    error: Some(format!("Unknown subscription type")),
                })),
            };

            // Fetch (rate-limited via enforce_rate_limit inside fetch_with_progress)
            let c = client.read().await;
            let html = match c.fetch_with_progress(&url, 30, None).await {
                Ok(h) => h,
                Err(e) => {
                    let msg = format!("{e}");
                    log_error!("sub_check", "Failed to fetch {sub_type} '{sub_name}' ({url}): {msg}");
                    drop(c);

                    let retryable = msg.to_lowercase().contains("timeout")
                        || msg.contains("HTTP 403") || msg.contains("HTTP 429");
                    if retryable {
                        let s = storage.lock().await;
                        if let Ok(Some(json)) = s.get_check_queue() {
                            if let Ok(mut q) = serde_json::from_str::<Vec<serde_json::Value>>(&json) {
                                // Re-insert the item wholesale so census
                                // markers survive the retry.
                                q.insert(0, item);
                                log_db("set_check_queue", s.set_check_queue(&serde_json::to_string(&q).unwrap_or_default()));
                            }
                        }
                    }
                    return Ok(Some(USubscriptionCheckResult {
                        sub_type, sub_id, name: sub_name, changed: false,
                        remaining: if retryable { remaining + 1 } else { remaining },
                        error: Some(msg),
                    }));
                }
            };
            drop(c);

            // Parse works and extract the newest date
            let (newest_date, parsed_works) = match sub_type.as_str() {
                "author" | "series" => {
                    // Both author pages and series pages use li.work.blurb.
                    // A parse error (schema canary) must abort the check:
                    // treating it as "0 works" would make the census flag
                    // every known work as gone. An interrupted census
                    // resumes on this subscription's next regular check.
                    let works = match crate::parser::parse_work_listings(&html) {
                        Ok(w) => w,
                        Err(e) => {
                            log_error!("sub_check", "Parse failed for {sub_type} '{sub_name}' ({url}): {e}");
                            return Ok(Some(USubscriptionCheckResult {
                                sub_type, sub_id, name: sub_name, changed: false,
                                remaining, error: Some(format!("{e}")),
                            }));
                        }
                    };
                    let date = works.iter()
                        .map(|w| w.date_updated.as_str())
                        .max()
                        .unwrap_or("")
                        .to_string();
                    (date, works)
                }
                "work" => {
                    if let Ok((w, _)) = crate::parser::parse_work_page(&html) {
                        let date = w.date_updated.clone();
                        (date, vec![w])
                    } else {
                        (String::new(), vec![])
                    }
                }
                _ => (String::new(), vec![]),
            };

            let s = storage.lock().await;

            // ---- Census continuation: one deeper listing page per call ----
            if let Some(mut state) = census_state {
                let (flagged, _) = diff_and_flag_works(&s, &parsed_works, &sub_type, &sub_name, state.seed);
                // One transaction per census page: works + associations +
                // flags land together or not at all.
                let tx = s.begin_tx().map_err(AO3Error::from)?;
                for w in &parsed_works {
                    log_db("save_work", s.save_work(w));
                }
                let page_ids: Vec<u64> = parsed_works.iter().map(|w| w.id).collect();
                if !page_ids.is_empty() {
                    log_db("add_subscription_works", s.add_subscription_works(&sub_type, &sub_id, &page_ids));
                }
                for id in page_ids {
                    if !state.seen_ids.contains(&id) {
                        state.seen_ids.push(id);
                    }
                }
                let changed = !flagged.is_empty();
                if changed {
                    log_db("add_new_work_ids", s.add_new_work_ids(&flagged));
                }
                log_db("commit census page", tx.commit());

                let done = !crate::parser::has_next_page(&html)
                    || state.next_page >= CENSUS_MAX_PAGES
                    || parsed_works.is_empty();
                if done && state.next_page >= CENSUS_MAX_PAGES && crate::parser::has_next_page(&html) {
                    log_error!("whats_new",
                        "Census for {sub_type} '{sub_name}' hit the {CENSUS_MAX_PAGES}-page cap with pages left — listing walk truncated");
                }
                if done {
                    finalize_census(&s, &sub_type, &sub_id, &sub_name, &state);
                } else {
                    state.next_page += 1;
                    log_db("set_snapshot_census_state", s.set_snapshot_census_state(&sub_type,
                        &sub_id, serde_json::to_string(&state).ok().as_deref()));
                    remaining = requeue_census_marker(&s, &sub_type, &sub_id, &sub_name);
                }
                if remaining == 0 {
                    log_db("set_last_check_time", s.set_last_check_time(&now_utc()));
                }
                return Ok(Some(USubscriptionCheckResult {
                    sub_type, sub_id, name: sub_name, changed, remaining, error: None,
                }));
            }

            // ---- Level 0: page 1 (or the single work) ----
            // The snapshot's job here: distinguish a first run (seed
            // silently) from a repeat check. An empty date also counts as
            // first run — census bookkeeping may create the row early.
            let first_run = s.get_subscription_snapshot(&sub_type, &sub_id)
                .unwrap_or(None)
                .map(|d| d.is_empty())
                .unwrap_or(true);

            let (updated_ids, unseen) = if first_run {
                log_info!("whats_new",
                    "First check for {} subscription '{}' — seeded {} works silently (rule: no baseline yet, nothing can qualify)",
                    sub_type, sub_name, parsed_works.len());
                (Vec::new(), 0)
            } else {
                diff_and_flag_works(&s, &parsed_works, &sub_type, &sub_name, false)
            };
            let changed = !updated_ids.is_empty();

            // Cache works and mark new/updated ones for the What's New feed —
            // one transaction, so a crash can't leave a half-saved page.
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            for w in &parsed_works {
                log_db("save_work", s.save_work(w));
            }
            // Merge (not replace): the check only sees page 1, and a full
            // "Refresh Works" crawl may have cached the author's complete list.
            let all_ids: Vec<u64> = parsed_works.iter().map(|w| w.id).collect();
            if !all_ids.is_empty() {
                log_db("add_subscription_works", s.add_subscription_works(&sub_type, &sub_id, &all_ids));
            }
            if changed {
                log_db("add_new_work_ids", s.add_new_work_ids(&updated_ids));
            }

            // Save snapshot (always, even on first run)
            if !newest_date.is_empty() {
                log_db("save_subscription_snapshot", s.save_subscription_snapshot(&sub_type, &sub_id, &newest_date));
            }
            log_db("commit check page", tx.commit());

            // ---- Census escalation (listings only) ----
            // Page 1 sorted by update date is blind to backdated posts and
            // removals; the listing's total works count is not. When the
            // count doesn't reconcile with what page 1 shows, walk the whole
            // listing. A periodic census also runs to catch the one case the
            // count can't see (an addition paired with a removal between
            // checks) and to reconcile the gone-from-AO3 flags.
            if sub_type == "author" || sub_type == "series" {
                let header_total = crate::parser::parse_listing_works_total(&html);
                let (prev_total, last_census_at, existing_state) =
                    s.get_snapshot_census_meta(&sub_type, &sub_id).unwrap_or((None, None, None));

                let mut census_reason: Option<String> = None;
                if existing_state.is_some() {
                    census_reason = Some("resuming interrupted census".to_string());
                } else if !first_run {
                    if let (Some(t), Some(p)) = (header_total, prev_total) {
                        let delta = t as i64 - p as i64;
                        if delta < 0 {
                            census_reason = Some(format!(
                                "listing count fell {p} → {t} (rule: something was removed; confirm what)"));
                        } else if delta > unseen as i64 {
                            census_reason = Some(format!(
                                "listing count rose {p} → {t} but page 1 shows only {unseen} unknown work(s) (rule: a new work missing from the top of the date sort is a backdated post)"));
                        } else if delta == 0 && unseen > 0 {
                            census_reason = Some(format!(
                                "unknown work on page 1 with unchanged count {t} (rule: an addition paired with a removal keeps the count flat)"));
                        }
                    }
                }
                // Age-based census — capped at one per check cycle so
                // baselines build gradually instead of all at once.
                let seed = last_census_at.is_none();
                if census_reason.is_none() {
                    let due = match &last_census_at {
                        None => true,
                        Some(at) => {
                            let then = crate::timefmt::datetime_to_epoch(at).unwrap_or(0);
                            let now = crate::timefmt::epoch_now();
                            now.saturating_sub(then) > CENSUS_INTERVAL_SECS
                        }
                    };
                    if due && !census_cycle_used.swap(true, std::sync::atomic::Ordering::Relaxed) {
                        census_reason = Some(if seed {
                            "baseline census (first full listing pass)".to_string()
                        } else {
                            "periodic census".to_string()
                        });
                    }
                }

                if let Some(reason) = census_reason {
                    let resumed = existing_state
                        .and_then(|json| serde_json::from_str::<CensusState>(&json).ok());
                    let fresh = resumed.is_none();
                    let mut state = resumed.unwrap_or_else(|| CensusState {
                        next_page: 2,
                        total_pages: crate::parser::total_pages(&html),
                        seen_ids: Vec::new(),
                        started_at: now_utc(),
                        reason: reason.clone(),
                        seed,
                    });
                    for id in &all_ids {
                        if !state.seen_ids.contains(id) {
                            state.seen_ids.push(*id);
                        }
                    }
                    log_info!("whats_new",
                        "Census for {} subscription '{}': {} (from page {}, ~{} pages)",
                        sub_type, sub_name, reason, state.next_page, state.total_pages);
                    if fresh && !crate::parser::has_next_page(&html) {
                        // Single-page listing: page 1 was the whole census.
                        finalize_census(&s, &sub_type, &sub_id, &sub_name, &state);
                    } else {
                        log_db("set_snapshot_census_state", s.set_snapshot_census_state(&sub_type,
                            &sub_id, serde_json::to_string(&state).ok().as_deref()));
                        remaining = requeue_census_marker(&s, &sub_type, &sub_id, &sub_name);
                    }
                } else if let Some(t) = header_total {
                    // Counts reconcile — adopt the fresh total as the next
                    // check's baseline.
                    log_db("set_snapshot_total_works", s.set_snapshot_total_works(&sub_type, &sub_id, t));
                }
            }

            // If queue is now empty, mark the check as complete
            if remaining == 0 {
                log_db("set_last_check_time", s.set_last_check_time(&now_utc()));
            }

            Ok(Some(USubscriptionCheckResult {
                sub_type, sub_id, name: sub_name, changed, remaining,
                error: None,
            }))
        }).await
    }

    pub async fn check_inbox(&self, username: String) -> Result<Vec<UNotification>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;

            // The inbox is sorted newest-first, and every sync stores messages
            // until it reaches ones it already has — so the moment a fetched
            // page contains ANY locally-known message, everything older is
            // guaranteed to be stored already. Stop paginating there.
            // Storage is locked per page, never across a fetch — holding it
            // for the whole loop stalls every sync getter for up to 10 Tor
            // round-trips.
            let mut all_items = Vec::new();
            let mut page = 1u32;
            loop {
                let inbox = c.fetch_inbox(&username, page).await.map_err(AO3Error::from)?;
                let reached_known = {
                    let s = storage.lock().await;
                    inbox.items.iter()
                        .any(|m| s.has_inbox_message(m.comment_id).unwrap_or(false))
                };
                let has_next = inbox.has_next_page;
                all_items.extend(inbox.items);
                if !has_next || reached_known || page >= 10 {
                    if page >= 10 && has_next && !reached_known {
                        log_error!("inbox", "Inbox sync stopped at the 10-page cap with more pages unread — older messages were not stored");
                    }
                    break;
                }
                page += 1;
            }
            drop(c);
            let s = storage.lock().await;

            // Persist all fetched messages
            log_db("save_inbox_messages", s.save_inbox_messages(&all_items));

            // Get the last seen inbox comment ID
            let last_seen_id: u64 = s.get_state("last_inbox_comment_id")
                .unwrap_or(None)
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);

            let mut new_notifications = Vec::new();
            let mut max_id: u64 = last_seen_id;

            for item in &all_items {
                if item.comment_id > max_id {
                    max_id = item.comment_id;
                }

                // Only notify for unread items newer than last seen
                if !item.is_unread || item.comment_id <= last_seen_id {
                    continue;
                }

                // Skip on first run (no last_seen means we haven't checked before)
                if last_seen_id == 0 {
                    continue;
                }

                let msg = format!(
                    "{} commented on {}",
                    item.author, item.work_reference
                );

                let notif_id = s.add_notification(
                    "inbox_comment",
                    item.comment_id,
                    &item.author,
                    &item.work_reference,
                    &msg,
                ).unwrap_or(-1);

                if notif_id > 0 {
                    new_notifications.push(UNotification {
                        id: notif_id,
                        notif_type: "inbox_comment".to_string(),
                        work_id: item.comment_id,
                        author: item.author.clone(),
                        title: item.work_reference.clone(),
                        message: msg,
                        created_at: String::new(),
                        read: false,
                    });
                }
            }

            // Update last seen ID
            if max_id > 0 {
                log_db("set_state", s.set_state("last_inbox_comment_id", &max_id.to_string()));
            }

            Ok(new_notifications)
        }).await
    }

    pub async fn fetch_inbox(&self, username: String, page: u32) -> Result<String, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            let inbox = c.fetch_inbox(&username, page).await.map_err(AO3Error::from)?;
            drop(c);

            // Persist fetched messages
            {
                let s = storage.lock().await;
                log_db("save_inbox_messages", s.save_inbox_messages(&inbox.items));
            }

            let items: Vec<serde_json::Value> = inbox.items.into_iter().map(|item| {
                serde_json::json!({
                    "comment_id": item.comment_id,
                    "author": item.author,
                    "author_url": item.author_url.unwrap_or_default(),
                    "avatar_url": item.avatar_url.unwrap_or_default(),
                    "work_reference": item.work_reference,
                    "work_url": item.work_url.unwrap_or_default(),
                    "posted_at": item.posted_at,
                    "is_unread": item.is_unread,
                    "content_json": serde_json::to_string(&item.content).unwrap_or("[]".to_string()),
                })
            }).collect();
            let result = serde_json::json!({
                "items": items,
                "unread_count": inbox.unread_count,
                "has_next_page": inbox.has_next_page,
            });
            Ok(serde_json::to_string(&result).unwrap_or("{}".to_string()))
        }).await
    }

    /// Read cached inbox messages from the database (no network).
    pub fn get_cached_inbox(&self, page: u32) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        let per_page: u32 = 25;
        let rows = storage.get_inbox_messages(page, per_page).map_err(AO3Error::from)?;
        let (total, unread) = storage.get_inbox_message_count().map_err(AO3Error::from)?;
        let has_next = (page * per_page) < total;
        let items: Vec<serde_json::Value> = rows.into_iter().map(|(comment_id, author, author_url, avatar_url, work_reference, work_url, posted_at, is_unread, content_json)| {
            serde_json::json!({
                "comment_id": comment_id,
                "author": author,
                "author_url": author_url,
                "avatar_url": avatar_url,
                "work_reference": work_reference,
                "work_url": work_url,
                "posted_at": posted_at,
                "is_unread": is_unread,
                "content_json": content_json,
            })
        }).collect();
        let result = serde_json::json!({
            "items": items,
            "unread_count": unread,
            "has_next_page": has_next,
        });
        Ok(serde_json::to_string(&result).unwrap_or("{}".to_string()))
    }

    /// Get all notifications from storage.
    pub fn get_notifications(&self) -> Result<Vec<UNotification>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_notifications().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, notif_type, work_id, author, title, message, created_at, read)| {
            UNotification { id, notif_type, work_id, author, title, message, created_at, read }
        }).collect())
    }

    /// Get count of unread notifications.
    pub fn get_unread_notification_count(&self) -> Result<u32, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_unread_count().map_err(AO3Error::from)
    }

    /// Mark a single notification as read.
    pub fn mark_notification_read(&self, notification_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_notification_read(notification_id).map_err(AO3Error::from)
    }

    /// Mark all notifications as read.
    pub fn mark_all_notifications_read(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_all_read().map_err(AO3Error::from)
    }

    /// Delete all read notifications.
    pub fn clear_read_notifications(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_read_notifications().map_err(AO3Error::from)
    }

    /// Get the last time subscriptions were checked.
    pub fn get_last_subscription_check(&self) -> Result<Option<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_last_check_time().map_err(AO3Error::from)
    }
}
