use super::*;

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    // -- Sequential What's New check queue (follows only) --

    /// Build (or extend) the What's New check queue from the follows.
    /// Leftover queue items (an interrupted round, census continuations)
    /// keep their place at the front; everything else joins behind them
    /// sorted alphabetically by display name so the user can predict the
    /// request order. With `only_stale`, a follow joins only when its own
    /// `last_checked_at` is missing or older than CHECK_INTERVAL_SECS —
    /// per-row freshness, so a resumed round re-checks exactly the rows
    /// that need it and nothing that was already checked recently.
    /// `older_than_secs` narrows the round further: only follows last
    /// checked longer ago than that (or never) join — the overdue warning's
    /// "check just these". None leaves `only_stale` in charge.
    pub fn start_whats_new_check(&self, only_stale: bool, older_than_secs: Option<u64>) -> Result<u32, AO3Error> {
        self.census_cycle_used.store(false, std::sync::atomic::Ordering::Relaxed);
        let s = self.storage.blocking_lock();
        // Only the selected sources are asked: their leftover items keep
        // their place, a left-out source's are parked until it is back.
        let skipped = skipped_check_sources(&s, &self.sources);
        let mut queue = park_unselected_checks(&s, &skipped).map_err(AO3Error::from)?;

        for row in s.get_check_targets().map_err(AO3Error::from)? {
            // A source without update checks is never asked (Area 9), nor
            // is one the user left out of the check.
            if !check_selected(&s, &self.sources, &skipped, row.target) {
                continue;
            }
            let kind = row.target.kind();
            let id = row.bridge_id;
            let queued = queue.iter().any(|q|
                q["kind"].as_str() == Some(kind)
                    && q["target_id"].as_str().is_some_and(|t| t.eq_ignore_ascii_case(&id)));
            let wanted = match older_than_secs {
                Some(age) => follow_older_than(&s, row.target, age),
                None => !only_stale || follow_check_due(&s, row.target),
            };
            if queued || !wanted {
                continue;
            }
            queue.push(serde_json::json!({"kind": kind, "target_id": id, "name": row.name}));
        }
        let json = serde_json::to_string(&queue).unwrap_or_else(|_| "[]".to_string());
        s.set_check_queue(&json).map_err(AO3Error::from)?;
        Ok(queue.len() as u32)
    }

    /// The sources a What's New check can ask, each with whether the user
    /// has it selected and how many follows it would cover. A source
    /// without update checks is not listed.
    pub fn whats_new_check_sources(&self) -> Result<Vec<UCheckSource>, AO3Error> {
        let s = self.storage.blocking_lock();
        let skipped = skipped_check_sources(&s, &self.sources);
        let mut follows: std::collections::HashMap<String, u32> = Default::default();
        for row in s.get_check_targets().map_err(AO3Error::from)? {
            if let Some(caps) = follow_source_caps(&s, &self.sources, row.target) {
                *follows.entry(caps.id).or_default() += 1;
            }
        }
        Ok(self.sources.capabilities().into_iter().filter(|caps| caps.update_checks).map(|caps| UCheckSource {
            selected: !skipped.contains(&caps.id),
            follows: follows.get(&caps.id).copied().unwrap_or(0),
            id: caps.id,
            name: caps.name,
        }).collect())
    }

    /// Choose the sources the What's New check asks — one of them up to
    /// all. Every round, the due test and the overdue warning leave the
    /// others out until they are selected again; their queued items are
    /// parked, not lost. Refused when it would select no source.
    pub fn set_whats_new_check_sources(&self, selected: Vec<String>) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let checking: Vec<String> = self.sources.capabilities().into_iter()
            .filter(|caps| caps.update_checks).map(|caps| caps.id).collect();
        let skipped: Vec<String> = checking.iter().filter(|id| !selected.contains(id)).cloned().collect();
        if skipped.len() >= checking.len() {
            return Err(AO3Error::NotFound { message: "Select at least one source to check".to_string() });
        }
        set_skipped_check_sources(&s, &skipped).map_err(AO3Error::from)?;
        park_unselected_checks(&s, &skipped.into_iter().collect()).map_err(AO3Error::from)?;
        Ok(())
    }

    /// Would a check round have anything to do? True when leftover queue
    /// items exist or any follow's own `last_checked_at` is missing or
    /// stale — among the selected sources only.
    /// This replaces gating on the global queue-drain time, which
    /// only describes when a round finished — after an interrupted round it
    /// overstates the freshness of every row checked before the break.
    pub fn is_whats_new_check_due(&self) -> Result<bool, AO3Error> {
        let s = self.storage.blocking_lock();
        let skipped = skipped_check_sources(&s, &self.sources);
        if !park_unselected_checks(&s, &skipped).map_err(AO3Error::from)?.is_empty() {
            return Ok(true);
        }
        Ok(s.get_check_targets().map_err(AO3Error::from)?
            .iter()
            .any(|row| check_selected(&s, &self.sources, &skipped, row.target) && follow_check_due(&s, row.target)))
    }

    /// How many checked follows were last checked longer ago than
    /// `max_age_secs`, or never — the overdue warning's numbers. Per-row,
    /// like `is_whats_new_check_due`: a round counts as full once every row
    /// has its own recent stamp, however many interrupted runs it took.
    /// Follows of a source left out of the check are not counted.
    pub fn whats_new_overdue(&self, max_age_secs: u64) -> Result<UWhatsNewOverdue, AO3Error> {
        let s = self.storage.blocking_lock();
        let skipped = skipped_check_sources(&s, &self.sources);
        let targets: Vec<_> = s.get_check_targets().map_err(AO3Error::from)?
            .into_iter().filter(|row| check_selected(&s, &self.sources, &skipped, row.target)).collect();
        let mut overdue = 0u32;
        let mut never_checked = 0u32;
        for row in &targets {
            if !follow_older_than(&s, row.target, max_age_secs) {
                continue;
            }
            overdue += 1;
            if !matches!(s.get_follow_last_checked(row.target), Ok(Some(at)) if !at.is_empty()) {
                never_checked += 1;
            }
        }
        Ok(UWhatsNewOverdue { overdue, never_checked, total: targets.len() as u32 })
    }

    /// The persisted check queue as it stands — front item first. Read by
    /// the monitor window between items; empty when no round is pending.
    pub fn get_whats_new_check_queue(&self) -> Result<Vec<UCheckQueueItem>, AO3Error> {
        let s = self.storage.blocking_lock();
        let queue: Vec<serde_json::Value> = s.get_check_queue().map_err(AO3Error::from)?
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default();
        Ok(queue.iter().map(|q| {
            let kind = q["kind"].as_str().unwrap_or("").to_string();
            let target_id = q["target_id"].as_str().unwrap_or("").to_string();
            let census = q["census"].as_bool().unwrap_or(false);
            // The page cursor lives in the persisted census state, not the
            // queue marker (see check_next_follow).
            let (page, total_pages) = if census {
                s.follow_target(&kind, &target_id)
                    .and_then(|t| s.get_follow_census_meta(t).ok())
                    .and_then(|(_, _, state)| state)
                    .and_then(|json| serde_json::from_str::<CensusState>(&json).ok())
                    .map(|c| (c.next_page, c.total_pages))
                    .unwrap_or((0, 0))
            } else {
                (0, 0)
            };
            UCheckQueueItem {
                kind,
                target_id,
                name: q["name"].as_str().unwrap_or("").to_string(),
                census,
                page,
                total_pages,
            }
        }).collect())
    }

    pub fn reset_whats_new_check(&self) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.clear_check_queue().map_err(AO3Error::from)
    }

    // -- What's New work list --

    pub fn get_new_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_new_work_ids().map_err(AO3Error::from)
    }

    /// What's New entries not yet selected since they were added.
    pub fn get_unseen_new_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_unseen_new_work_ids().map_err(AO3Error::from)
    }

    /// The user selected this What's New entry — clears its "New" badge.
    pub fn mark_new_work_seen(&self, work_id: u64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.mark_new_work_seen(work_id, &now_utc()).map_err(AO3Error::from)
    }

    /// Works a census confirmed are no longer listed on AO3 (cached copies
    /// are retained; this is display metadata).
    pub fn get_gone_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_gone_work_ids().map_err(AO3Error::from)
    }

    /// Works the user flagged as finished reading (manual only).
    pub fn get_finished_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_finished_work_ids().map_err(AO3Error::from)
    }

    /// Set or clear the user's finished-reading flag on a batch of works.
    pub fn set_works_finished(&self, work_ids: Vec<u64>, finished: bool) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.set_works_finished(&work_ids, finished).map_err(AO3Error::from)
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

    /// A full works crawl (Refresh Works) for this author/series finished;
    /// `work_ids` is every work it listed. Stamps the crawl. When the target
    /// is followed, the crawl was a complete What's New census as well, so
    /// it is recorded as one — gone-from-AO3 flags reconciled, total and
    /// census time adopted — and the follow is marked checked with a fresh
    /// baseline. (Each page was already compared and new or
    /// updated works flagged as it arrived; see `run_listing_fetch`.)
    /// `target_id`: the author's username or the series row id; `work_ids`
    /// are row ids.
    pub fn complete_works_crawl(&self, kind: String, target_id: String, work_ids: Vec<u64>) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let now = now_utc();
        let Some(target) = s.ensure_follow_target(&kind, &target_id).map_err(AO3Error::from)? else {
            return Err(AO3Error::NotFound { message: format!("{kind} '{target_id}' is not in the library") });
        };
        s.set_works_crawled_at(target, &now).map_err(AO3Error::from)?;
        if !s.is_followed(target).map_err(AO3Error::from)? {
            return Ok(());
        }
        let state = CensusState {
            next_page: 0,
            total_pages: 0,
            seen_ids: work_ids.clone(),
            started_at: now.clone(),
            reason: "full works crawl (Refresh Works)".to_string(),
            seed: s.get_follow_census_meta(target).map(|(_, last, _)| last.is_none()).unwrap_or(true),
        };
        finalize_census(&s, target, &target_id, &state);
        // The newest update date the crawl saw — what a check's page 1
        // would have recorded.
        let newest = work_ids.iter()
            .filter_map(|id| s.get_work(*id).ok().flatten())
            .map(|w| w.date_updated)
            .max()
            .unwrap_or_default();
        if !newest.is_empty() {
            log_db("set_follow_baseline", s.set_follow_baseline(target, &newest));
        }
        log_db("set_follow_last_checked", s.set_follow_last_checked(target, &now));
        Ok(())
    }

    /// UTC "YYYY-MM-DD HH:MM:SS" of the last completed works crawl, or None.
    /// `target_id`: the author's username or the series row id.
    pub fn get_works_crawled_at(&self, kind: String, target_id: String) -> Result<Option<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        let Some(target) = s.follow_target(&kind, &target_id) else { return Ok(None) };
        s.get_works_crawled_at(target).map_err(AO3Error::from)
    }

    pub fn remove_new_work(&self, work_id: u64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.remove_new_work_id(work_id).map_err(AO3Error::from)
    }

    pub fn clear_new_works(&self) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.clear_new_work_ids().map_err(AO3Error::from)
    }

    pub async fn check_next_follow(&self) -> Result<Option<UFollowCheckResult>, AO3Error> {
        let census_cycle_used = self.census_cycle_used.clone();
        let registry = self.sources.clone();
        self.run_on_runtime(move |client, storage| async move {
            // The follow this call popped. Its `last_checked_at` is stamped
            // after the check whatever the outcome — success, 404, other
            // failure — so a target that keeps failing doesn't hold the
            // overdue warning up forever.
            let mut checked: Option<FollowTarget> = None;
            let result: Result<Option<UFollowCheckResult>, AO3Error> = async {
                let s = storage.lock().await;
                // Pop the first item from the queue
                let queue_json = s.get_check_queue().map_err(AO3Error::from)?
                    .unwrap_or_else(|| "[]".to_string());
                let mut queue: Vec<serde_json::Value> = serde_json::from_str(&queue_json)
                    .unwrap_or_default();
                if queue.is_empty() {
                    return Ok(None);
                }
                // Items whose follow was removed since they were queued are
                // dropped — an unfollowed target is never fetched. (Queue
                // items name targets the way the bridge does.)
                fn followed_target(s: &Storage, item: &serde_json::Value) -> Option<FollowTarget> {
                    s.follow_target(item["kind"].as_str().unwrap_or(""), item["target_id"].as_str().unwrap_or(""))
                        .filter(|t| s.is_followed(*t).unwrap_or(false))
                }
                let mut item = queue.remove(0);
                let mut target = followed_target(&s, &item);
                while target.is_none() {
                    if queue.is_empty() {
                        log_db("set_check_queue", s.set_check_queue("[]"));
                        return Ok(None);
                    }
                    item = queue.remove(0);
                    target = followed_target(&s, &item);
                }
                let target = target.expect("loop exits with a followed target");
                let sub_type = target.kind().to_string();
                // The bridge id for the result and for the queue marker.
                let sub_id = s.follow_bridge_id(target);
                let sub_name = item["name"].as_str().unwrap_or("").to_string();
                let is_census = item["census"].as_bool().unwrap_or(false);
                checked = Some(target);
                // What the target's own source is asked for (Area 9): the
                // check dispatches by the row's source, never by kind alone.
                let update = update_target(&s, target)
                    .and_then(|t| registry.by_id(&t.external().source).map(|source| (source, t)));
                let refusal = match &update {
                    None => Some("No source can check this follow".to_string()),
                    Some((source, _)) if !source.capabilities().update_checks =>
                        Some(format!("{} has no update checks", source.capabilities().name)),
                    // A source the current privacy mode can't reach is
                    // reported for this follow; the round goes on.
                    Some((source, _)) => check_reachable(source).err().map(|e| format!("{e}")),
                };
                let (source, update) = match (update, refusal) {
                    (Some(found), None) => found,
                    (_, error) => {
                        let json = serde_json::to_string(&queue).unwrap_or_else(|_| "[]".to_string());
                        log_db("set_check_queue", s.set_check_queue(&json));
                        return Ok(Some(UFollowCheckResult {
                            kind: sub_type, target_id: sub_id, name: sub_name, changed: false,
                            remaining: queue.len() as u32, error,
                        }));
                    }
                };

                // Persist updated queue before the fetch (so a crash mid-fetch
                // skips this item rather than retrying it forever).
                let mut remaining = queue.len() as u32;
                let updated_json = serde_json::to_string(&queue).unwrap_or_else(|_| "[]".to_string());
                log_db("set_check_queue", s.set_check_queue(&updated_json));

                // Census continuations read their page cursor from the persisted
                // state, not the queue marker — cancel/crash resumes cleanly.
                let census_state: Option<CensusState> = if is_census {
                    s.get_follow_census_meta(target)
                        .ok()
                        .and_then(|(_, _, state)| state)
                        .and_then(|json| serde_json::from_str(&json).ok())
                } else {
                    None
                };
                drop(s);

                if is_census && census_state.is_none() {
                    // Orphaned marker — its state was cleared elsewhere.
                    return Ok(Some(UFollowCheckResult {
                        kind: sub_type, target_id: sub_id, name: sub_name, changed: false, remaining, error: None,
                    }));
                }

                // The target's page at its source, for the log.
                let url = update.external().url.clone();
                let page = census_state.as_ref().map(|c| c.next_page).unwrap_or(1);

                // Fetch through the recovery engine (Idempotent — a plain GET):
                // a transient failure already gets rotated-and-retried in Rust
                // before ever reaching this match. What's left after that is
                // classified (never string-matched) to decide whether it's
                // still worth requeuing for the next census cycle.
                let fetch_result: Result<crate::source::UpdatePage, AO3Error> = with_recovery(
                    client.clone(), storage.clone(), OpKind::Fetch { label: "subscription_check".to_string() }, RetrySafety::Idempotent,
                    move |_client| {
                        let (source, update) = (source.clone(), update.clone());
                        async move {
                            // Inside the attempt closure so retries pace too —
                            // not just the first request for each item.
                            tokio::time::sleep(SUBSCRIPTION_CHECK_DELAY).await;
                            source.fetch_updates(&update, page).await.map_err(AO3Error::from)
                        }
                    }).await;
                let fetched = match fetch_result {
                    Ok(f) => {
                        // A successful fetch ends any not-found streak.
                        let s = storage.lock().await;
                        log_db("reset_follow_status", s.reset_follow_status(target));
                        f
                    }
                    Err(e) => {
                        let msg = format!("{e}");
                        log_error!("sub_check", "Failed to fetch {sub_type} '{sub_name}' ({url}): {msg}");
                        // A page that arrived but didn't parse was still
                        // found: it ends a not-found streak like any fetch.
                        if matches!(e, AO3Error::Parse { .. }) {
                            let s = storage.lock().await;
                            log_db("reset_follow_status", s.reset_follow_status(target));
                        }

                        // A 404 counts toward the not-found limit; reaching it
                        // excludes the follow from every future check.
                        if matches!(classify(&e), Some(crate::client::FailureKind::Http { code: 404 })) {
                            let s = storage.lock().await;
                            let limit = not_found_limit(&s);
                            match s.record_follow_not_found(target, limit) {
                                Ok(-1) => { log_info!("whats_new",
                                    "{sub_type} '{sub_name}' not found on {limit} consecutive checks — excluded from What's New checks"); }
                                Ok(n) => { log_info!("whats_new",
                                    "{sub_type} '{sub_name}' not found ({n} consecutive, limit {limit})"); }
                                Err(e) => log_db("record_follow_not_found", Err::<(), _>(e)),
                            }
                        }

                        let retryable = matches!(classify(&e), Some(
                            crate::client::FailureKind::ConnectFailure
                            | crate::client::FailureKind::EdgeTlsFailure
                            | crate::client::FailureKind::RateLimited { .. }
                            | crate::client::FailureKind::Challenged
                            | crate::client::FailureKind::OriginUnavailable
                            | crate::client::FailureKind::ResponseTimeout
                        ));
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
                        return Ok(Some(UFollowCheckResult {
                            kind: sub_type, target_id: sub_id, name: sub_name, changed: false,
                            remaining: if retryable { remaining + 1 } else { remaining },
                            error: Some(msg),
                        }));
                    }
                };

                // The works the page lists and the newest update date among
                // them (a listing that failed to parse never gets here: the
                // adapter reports it as an error, so it can't read as "0
                // works" and make the census flag every known work gone).
                let parsed_works: Vec<WorkSummary> = fetched.works.iter().map(|l| l.summary.clone()).collect();
                let newest_date = parsed_works.iter()
                    .map(|w| w.date_updated.as_str())
                    .max()
                    .unwrap_or("")
                    .to_string();
                // A listing may carry each work's figures and its authors
                // as users; they land beside the saved works.
                let detailed = fetched.detailed;
                let save_listed_extras = |s: &Storage| {
                    for lw in &fetched.works {
                        if lw.authors.is_empty() && lw.stats.is_empty() { continue }
                        let Some(id) = s.resolve_work(&lw.summary.source, &lw.summary.external_id) else { continue };
                        if !lw.authors.is_empty() {
                            if let Ok(ids) = s.record_users(&lw.authors) {
                                log_db("link_work_authors", s.link_work_authors(id, &ids));
                            }
                        }
                        if detailed {
                            save_source_stats(s, id, &lw.summary.source, &lw.stats);
                        } else {
                            merge_listed_stats(s, id, &lw.summary.source, &lw.stats);
                        }
                    }
                };
                // A followed work's check read the work's own page, which
                // owns its values and replaces them; an author's or series'
                // listing only adds to what the library holds.
                let save_page = |s: &Storage| if detailed {
                    save_works(s, &parsed_works)
                } else {
                    save_listed_works(s, &parsed_works)
                };

                let s = storage.lock().await;

                // ---- Census continuation: one deeper listing page per call ----
                if let Some(mut state) = census_state {
                    let (flagged, _) = diff_and_flag_works(&s, &parsed_works, &sub_type, &sub_name, state.seed);
                    // One transaction per census page: works + associations +
                    // flags land together or not at all.
                    let tx = s.begin_tx().map_err(AO3Error::from)?;
                    let page_ids = save_page(&s);
                    save_listed_extras(&s);
                    for id in page_ids {
                        if !state.seen_ids.contains(&id) {
                            state.seen_ids.push(id);
                        }
                    }
                    let changed = !flagged.is_empty();
                    if changed {
                        log_db("add_new_work_ids", s.add_new_work_ids(&flagged_row_ids(&s, &flagged)));
                    }
                    log_db("commit census page", tx.commit());

                    let done = !fetched.has_next
                        || state.next_page >= CENSUS_MAX_PAGES
                        || parsed_works.is_empty();
                    if done && state.next_page >= CENSUS_MAX_PAGES && fetched.has_next {
                        log_error!("whats_new",
                            "Census for {sub_type} '{sub_name}' hit the {CENSUS_MAX_PAGES}-page cap with pages left — listing walk truncated");
                    }
                    if done {
                        finalize_census(&s, target, &sub_name, &state);
                    } else {
                        state.next_page += 1;
                        log_db("set_follow_census_state", s.set_follow_census_state(target,
                            serde_json::to_string(&state).ok().as_deref()));
                        remaining = requeue_census_marker(&s, target, &sub_name);
                    }
                    if remaining == 0 {
                        log_db("set_last_check_time", s.set_last_check_time(&now_utc()));
                    }
                    return Ok(Some(UFollowCheckResult {
                        kind: sub_type, target_id: sub_id, name: sub_name, changed, remaining, error: None,
                    }));
                }

                // ---- Level 0: page 1 (or the single work) ----
                // The snapshot's job here: distinguish a first run (seed
                // silently) from a repeat check. An empty date also counts as
                // first run — census bookkeeping may create the row early.
                let first_run = s.get_follow_baseline(target)
                    .unwrap_or(None)
                    .is_none();

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
                // Membership (author byline / series part) rides on the saved
                // works themselves — nothing to record per subscription.
                let all_ids = save_page(&s);
                save_listed_extras(&s);
                if changed {
                    log_db("add_new_work_ids", s.add_new_work_ids(&flagged_row_ids(&s, &updated_ids)));
                }

                // Save snapshot (always, even on first run)
                if !newest_date.is_empty() {
                    log_db("set_follow_baseline", s.set_follow_baseline(target, &newest_date));
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
                    let header_total = fetched.total_works;
                    let (prev_total, last_census_at, existing_state) =
                        s.get_follow_census_meta(target).unwrap_or((None, None, None));

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
                            total_pages: fetched.total_pages,
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
                        if fresh && !fetched.has_next {
                            // Single-page listing: page 1 was the whole census.
                            finalize_census(&s, target, &sub_name, &state);
                        } else {
                            log_db("set_follow_census_state", s.set_follow_census_state(target,
                                serde_json::to_string(&state).ok().as_deref()));
                            remaining = requeue_census_marker(&s, target, &sub_name);
                        }
                    } else if let Some(t) = header_total {
                        // Counts reconcile — adopt the fresh total as the next
                        // check's baseline.
                        log_db("set_follow_total_works", s.set_follow_total_works(target, t));
                    }
                }

                // If queue is now empty, mark the check as complete
                if remaining == 0 {
                    log_db("set_last_check_time", s.set_last_check_time(&now_utc()));
                }

                Ok(Some(UFollowCheckResult {
                    kind: sub_type, target_id: sub_id, name: sub_name, changed, remaining,
                    error: None,
                }))
            }.await;
            if let Some(target) = checked {
                let s = storage.lock().await;
                log_db("set_follow_last_checked", s.set_follow_last_checked(target, &now_utc()));
            }
            result
        }).await
    }

    pub async fn check_inbox(&self, username: String) -> Result<Vec<UNotification>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
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
                let username_for_fetch = username.clone();
                let inbox = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "inbox".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let username = username_for_fetch.clone();
                        async move { client.read().await.fetch_inbox(&username, page).await.map_err(AO3Error::from) }
                    }).await?;
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
            let inbox = with_recovery(client, storage.clone(), OpKind::Fetch { label: "inbox".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let username = username.clone();
                    async move { client.read().await.fetch_inbox(&username, page).await.map_err(AO3Error::from) }
                }).await?;

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

    /// When the last What's New round drained its queue.
    pub fn get_last_whats_new_check(&self) -> Result<Option<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_last_check_time().map_err(AO3Error::from)
    }
}
