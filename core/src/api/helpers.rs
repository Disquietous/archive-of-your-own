use super::*;

/// A failed persistence call must never fail the user's operation, but it
/// must not vanish either — record it in the debug log.
pub(super) fn log_db<T, E: std::fmt::Display>(what: &str, result: Result<T, E>) {
    if let Err(e) = result {
        log_error!("db", "{what} failed: {e}");
    }
}

/// Seed the client's posting credentials (CSRF token, comment pseud id)
/// from persisted state — fills gaps only, freshly harvested values win.
/// Lets kudos/comment POSTs go out with no preparatory fetch even on a
/// fresh launch.
pub(super) fn seed_posting_credentials(c: &crate::client::AO3Client, s: &crate::storage::Storage) {
    let token = s.get_state("csrf_token").ok().flatten();
    let pseud = s.get_state("comment_pseud_id").ok().flatten();
    c.seed_credentials(token, pseud);
}

/// Persist the freshest harvested posting credentials for the next launch.
/// A fetched work page's kudos list names the signed-in user → they left
/// kudos at some point (website, another device, pre-tracking). Record it
/// so the heart shows full. The list truncates past ~150 names, so absence
/// never clears anything.
pub(super) fn record_kudos_if_listed(s: &crate::storage::Storage, work_id: u64, kudos_names: &[String]) {
    let Ok(Some(account)) = s.get_active_account() else { return };
    let username = account.username;
    if !username.is_empty() && kudos_names.iter().any(|n| n.eq_ignore_ascii_case(&username)) {
        log_db("mark_kudos_given", s.mark_kudos_given(work_id));
    }
}

/// The source and external identity of a work row, for dispatch. Errors
/// for an unknown row or a source the registry lacks. Refuses, with the
/// reason, a source the current privacy mode cannot reach (a site that
/// blocks Tor while the app is in Tor mode).
pub(super) fn source_for_work(s: &Storage, registry: &crate::source::SourceRegistry, work_id: u64)
    -> Result<(Arc<dyn crate::source::Source>, ExternalRef), AO3Error>
{
    let Some(external) = s.work_ref(work_id) else {
        return Err(AO3Error::NotFound { message: format!("no work with id {work_id}") });
    };
    let Some(source) = registry.by_id(&external.source) else {
        return Err(AO3Error::NotFound { message: format!("work {work_id} is from an unknown source {}", external.source) });
    };
    check_reachable(&source)?;
    Ok((source, external))
}

/// Tor mode cannot reach a source that blocks Tor exits: say so instead
/// of trying (nothing would be sent anyway; the gate refuses direct sends
/// in Tor mode).
pub(super) fn check_reachable(source: &Arc<dyn crate::source::Source>) -> Result<(), AO3Error> {
    let caps = source.capabilities();
    if crate::client::privacy::privacy_mode() == crate::client::PrivacyMode::Tor && !caps.reach.tor {
        return Err(AO3Error::Network {
            message: format!("{} blocks Tor. Switch to My VPN in Settings › Privacy to read it.", caps.name),
        });
    }
    Ok(())
}

/// Save one page of a source listing (every work, its authors and its
/// figures) in one transaction and shape it for the bridge.
pub(super) fn save_listing_page(s: &Storage, listing: &crate::source::ListingPage) -> Result<UPagedWorks, AO3Error> {
    let tx = s.begin_tx().map_err(AO3Error::from)?;
    let mut works = Vec::with_capacity(listing.works.len());
    for listed in &listing.works {
        match s.save_work(&listed.summary) {
            Ok(id) => {
                if !listed.authors.is_empty() {
                    match s.record_users(&listed.authors) {
                        Ok(ids) => { log_db("link_work_authors", s.link_work_authors(id, &ids)); }
                        Err(e) => { log_error!("db", "record_users failed: {e}"); }
                    }
                }
                save_source_stats(s, id, &listed.summary.source, &listed.stats);
                works.push(UWorkSummary::from(WorkSummary { id, ..listed.summary.clone() }));
            }
            Err(e) => { log_error!("db", "save_work failed: {e}"); }
        }
    }
    log_db("commit listing save", tx.commit());
    Ok(UPagedWorks { works, has_next_page: listing.has_next, total_pages: listing.total_pages, total_works: listing.total_works })
}

/// Persist a source's stats on a work: register each field on first
/// sight, then replace the work's values (absent = NULL, never zero).
pub(super) fn save_source_stats(s: &Storage, work_row: u64, source: &str, stats: &[crate::source::SourceStat]) {
    if stats.is_empty() && s.fields_for_source(source).is_empty() { return }
    let mut rows = Vec::with_capacity(stats.len());
    for stat in stats {
        let value_type = if stat.num.is_some() { "num" } else { "text" };
        match s.ensure_field(source, &stat.key, &stat.label, value_type, stat.order) {
            Ok(field_id) => rows.push(crate::storage::WorkStat {
                field_id, num_value: stat.num, text_value: stat.text.clone(),
            }),
            Err(e) => { log_error!("db", "ensure_field {}:{} failed: {e}", source, stat.key); }
        }
    }
    log_db("set_work_stats", s.set_work_stats(work_row, &rows));
}

/// The AO3 identity of a work row — what a fetch or a site URL needs.
/// Errors for an unknown row, or one from another source (there are none
/// yet; the AO3 client cannot fetch them).
pub(super) fn ao3_work_number(s: &Storage, work_id: u64) -> Result<u64, AO3Error> {
    let Some(external) = s.work_ref(work_id) else {
        return Err(AO3Error::NotFound { message: format!("no work with id {work_id}") });
    };
    if external.source != SOURCE_AO3 {
        return Err(AO3Error::NotFound { message: format!("work {work_id} is not an AO3 work") });
    }
    external.external_id.parse().map_err(|_| AO3Error::NotFound {
        message: format!("work {work_id} has no AO3 number"),
    })
}

/// The AO3 identity of a series row (see `ao3_work_number`).
pub(super) fn ao3_series_number(s: &Storage, series_id: u64) -> Result<u64, AO3Error> {
    let Some(series) = s.get_series(series_id).map_err(AO3Error::from)? else {
        return Err(AO3Error::NotFound { message: format!("no series with id {series_id}") });
    };
    if series.source != SOURCE_AO3 {
        return Err(AO3Error::NotFound { message: format!("series {series_id} is not an AO3 series") });
    }
    series.external_id.parse().map_err(|_| AO3Error::NotFound {
        message: format!("series {series_id} has no AO3 number"),
    })
}

/// The AO3 identifier a follow target is fetched by: username for
/// authors, the AO3 number for works and series. None for a fandom (never
/// fetched) or a target from another source.
pub(super) fn ao3_follow_id(s: &Storage, target: FollowTarget) -> Option<String> {
    match target {
        FollowTarget::Author(id) => s.get_user(id)
            .filter(|u| u.source == SOURCE_AO3)
            .map(|u| u.username),
        FollowTarget::Work(id) => s.work_ref(id)
            .filter(|r| r.source == SOURCE_AO3)
            .map(|r| r.external_id),
        FollowTarget::Series(id) => s.get_series(id).ok().flatten()
            .filter(|r| r.source == SOURCE_AO3)
            .map(|r| r.external_id),
        FollowTarget::Fandom(_) => None,
    }
}

pub(super) fn persist_posting_credentials(c: &crate::client::AO3Client, s: &crate::storage::Storage) {
    if let Some(token) = c.cached_csrf_token() {
        log_db("set_state", s.set_state("csrf_token", &token));
    }
    if let Some(pseud) = c.cached_pseud_id() {
        log_db("set_state", s.set_state("comment_pseud_id", &pseud));
    }
}

/// How old a follow's own `last_checked_at` may be before it joins the
/// next check round.
pub(super) const CHECK_INTERVAL_SECS: u64 = 3600;

/// Consecutive 404s after which a follow is excluded from What's New
/// checks, until the user sets the pref. 0 = never exclude.
pub(super) const DEFAULT_NOT_FOUND_LIMIT: u32 = 5;

/// The user's not-found limit (pref `whats_new_not_found_limit`).
pub(super) fn not_found_limit(s: &Storage) -> u32 {
    s.get_state("pref:whats_new_not_found_limit").ok().flatten()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(DEFAULT_NOT_FOUND_LIMIT)
}

/// Is this follow's own check stale? A missing follow, NULL, or
/// unparseable stamp all count as never-checked.
pub(super) fn follow_check_due(s: &Storage, target: FollowTarget) -> bool {
    follow_older_than(s, target, CHECK_INTERVAL_SECS)
}

/// Was this follow last checked more than `max_age_secs` ago (or never)?
pub(super) fn follow_older_than(s: &Storage, target: FollowTarget, max_age_secs: u64) -> bool {
    match s.get_follow_last_checked(target) {
        Ok(Some(at)) if !at.is_empty() => {
            let then = crate::timefmt::datetime_to_epoch(&at).unwrap_or(0);
            crate::timefmt::epoch_now().saturating_sub(then) > max_age_secs
        }
        _ => true,
    }
}
/// How often an age-based full-listing census runs per subscription.
pub(super) const CENSUS_INTERVAL_SECS: u64 = 7 * 24 * 3600;
/// Hard page cap per census — safety valve against pagination anomalies.
pub(super) const CENSUS_MAX_PAGES: u32 = 200;
/// Minimum gap before EVERY request the check makes — page-1 checks,
/// census pages, and each recovery-engine retry of either. The check is
/// the one scheduled back-to-back walk against AO3, so it paces itself
/// well above the client's global 500ms limiter.
pub(super) const SUBSCRIPTION_CHECK_DELAY: std::time::Duration = std::time::Duration::from_secs(5);

/// In-progress census bookkeeping, persisted in the follow row so a
/// cancelled or crashed check resumes where it left off. `seen_ids` are
/// work row ids (every listed work is saved before it is recorded).
#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct CensusState {
    pub(super) next_page: u32,
    pub(super) total_pages: u32,
    pub(super) seen_ids: Vec<u64>,
    pub(super) started_at: String,
    pub(super) reason: String,
    /// Baseline-building pass: cache and associate everything, flag nothing —
    /// on the first full listing walk, "unknown" means "unseen by us", not
    /// "new on AO3".
    pub(super) seed: bool,
}

/// The What's-New qualification rules applied to one page of parsed blurbs,
/// BEFORE they are saved. Returns (external ids of works to flag, how many
/// were never in the cache); the caller maps flagged external ids to row
/// ids once the page is saved (`flagged_row_ids`).
pub(super) fn diff_and_flag_works(
    s: &Storage,
    parsed_works: &[WorkSummary],
    sub_type: &str,
    sub_name: &str,
    seed: bool,
) -> (Vec<String>, usize) {
    // Per-work diff against the local cache, BEFORE overwriting it.
    // date_updated is day-granular, so a chapter posted later the
    // same day is invisible to date comparison — chapter and word
    // counts (already in the parsed blurbs) catch it.
    let mut updated_ids: Vec<String> = Vec::new();
    let mut unseen = 0usize;
    for w in parsed_works {
        let cached = s.resolve_work(&w.source, &w.external_id)
            .and_then(|id| s.get_work(id).ok().flatten());
        match cached {
            Some(old) => {
                if seed {
                    continue;
                }
                // Log every metric that differs so the What's New
                // decision is auditable after the fact.
                let date_changed = old.date_updated != w.date_updated;
                let chapters_changed = old.chapter_count != w.chapter_count;
                let words_changed = old.word_count != w.word_count;
                let mut reasons: Vec<String> = Vec::new();
                if date_changed {
                    reasons.push(format!(
                        "date_updated '{}' → '{}' (rule: a changed update date means content was posted since we cached it)",
                        old.date_updated, w.date_updated));
                }
                if chapters_changed {
                    reasons.push(format!(
                        "chapter_count {} → {} (rule: AO3 dates are day-granular, so a same-day chapter shows up here, not in the date)",
                        old.chapter_count, w.chapter_count));
                }
                if words_changed {
                    reasons.push(format!(
                        "word_count {:?} → {:?} (rule: edits that add/remove text without a new chapter still count as an update)",
                        old.word_count, w.word_count));
                }
                // A date change alone is NOT sufficient: AO3 has
                // been seen shifting update dates without any
                // content change (timezone drift on the site's
                // side). It must be corroborated by at least one
                // content metric; chapter/word changes remain
                // sufficient on their own.
                if chapters_changed || words_changed {
                    log_info!("whats_new",
                        "Flagged work {} '{}' from {} subscription '{}': {}",
                        w.external_id, w.title, sub_type, sub_name, reasons.join("; "));
                    updated_ids.push(w.external_id.clone());
                } else if date_changed {
                    log_info!("whats_new",
                        "Suppressed work {} '{}' from {} subscription '{}': {} — no chapter/word change corroborates it (rule: an uncorroborated date change is site-side date drift, not an update; the fresh date is cached so it won't re-trigger)",
                        w.external_id, w.title, sub_type, sub_name, reasons.join("; "));
                }
            }
            None => {
                // never seen — new work (a stub row counts as never seen:
                // nothing was ever fetched for it)
                unseen += 1;
                if seed {
                    continue;
                }
                log_info!("whats_new",
                    "Flagged work {} '{}' from {} subscription '{}': not in the local works cache (rule: a work we've never cached from any source is new to us)",
                    w.external_id, w.title, sub_type, sub_name);
                updated_ids.push(w.external_id.clone());
            }
        }
    }
    (updated_ids, unseen)
}

/// Save every parsed work and return their row ids, in order.
pub(super) fn save_works(s: &Storage, works: &[WorkSummary]) -> Vec<u64> {
    works.iter().filter_map(|w| match s.save_work(w) {
        Ok(id) => Some(id),
        Err(e) => { log_error!("db", "save_work failed: {e}"); None }
    }).collect()
}

/// The row ids of flagged works, after the page was saved.
pub(super) fn flagged_row_ids(s: &Storage, flagged: &[String]) -> Vec<u64> {
    flagged.iter().filter_map(|ext| s.resolve_work(SOURCE_AO3, ext)).collect()
}

/// Census complete: `seen_ids` is everything AO3 still lists. Reconcile the
/// gone-from-AO3 flags, adopt the authoritative total, stamp the census
/// time, and clear the in-progress state.
pub(super) fn finalize_census(s: &Storage, target: FollowTarget, sub_name: &str, state: &CensusState) {
    let sub_type = target.kind();
    let known = s.get_subscription_member_ids(target).unwrap_or_default();
    let seen: std::collections::HashSet<u64> = state.seen_ids.iter().copied().collect();
    let gone: Vec<u64> = known.into_iter().filter(|id| !seen.contains(id)).collect();
    if !gone.is_empty() {
        log_db("set_works_gone", s.set_works_gone(&gone, true));
        log_info!("whats_new",
            "Census: {} work(s) from {} subscription '{}' no longer listed on AO3 — flagged gone, cached copies retained: {:?}",
            gone.len(), sub_type, sub_name, gone);
    }
    // A reappearance (undeleted, un-anonymized, unrestricted) clears the flag.
    log_db("set_works_gone", s.set_works_gone(&state.seen_ids, false));
    log_db("set_follow_total_works", s.set_follow_total_works(target, seen.len() as u32));
    log_db("set_follow_last_census", s.set_follow_last_census(target, &now_utc()));
    log_db("set_follow_census_state", s.set_follow_census_state(target, None));
    log_info!("whats_new",
        "Census complete for {} subscription '{}' ({}): {} works listed{}",
        sub_type, sub_name, state.reason, seen.len(),
        if state.seed { " — baseline established" } else { "" });
}

/// Append this subscription's census-continuation marker to the check queue
/// (at the tail, so other subscriptions get their turn first). Returns the
/// new queue length.
pub(super) fn requeue_census_marker(s: &Storage, target: FollowTarget, name: &str) -> u32 {
    let queue_json = s.get_check_queue().ok().flatten().unwrap_or_else(|| "[]".to_string());
    let mut queue: Vec<serde_json::Value> = serde_json::from_str(&queue_json).unwrap_or_default();
    queue.push(serde_json::json!({
        "kind": target.kind(),
        "target_id": s.follow_bridge_id(target),
        "name": name,
        "census": true,
    }));
    log_db("set_check_queue", s.set_check_queue(&serde_json::to_string(&queue).unwrap_or_default()));
    queue.len() as u32
}

/// Image cache key: one row per image URL, whoever asked for it — a
/// chapter, a comment avatar, the inbox. Site-relative URLs resolve
/// against AO3 first so both spellings of one image share the row.
pub(super) fn image_url_key(url: &str) -> String {
    if url.starts_with('/') {
        format!("img:{}{url}", crate::client::BASE_URL)
    } else {
        format!("img:{url}")
    }
}

/// Every image URL in a ContentBlock tree, depth-first (blockquotes, lists).
pub(super) fn collect_image_srcs(blocks: &[crate::models::ContentBlock], out: &mut Vec<String>) {
    use crate::models::ContentBlock;
    for block in blocks {
        match block {
            ContentBlock::Image { src, .. }
                if !out.contains(src) => {
                    out.push(src.clone());
                }
            ContentBlock::Blockquote { blocks } => collect_image_srcs(blocks, out),
            ContentBlock::List { items, .. } => {
                for item in items {
                    collect_image_srcs(item, out);
                }
            }
            _ => {}
        }
    }
}

/// Now, in the database's single timestamp encoding
/// (UTC "YYYY-MM-DD HH:MM:SS" — see crate::timefmt).
pub(super) fn now_utc() -> String {
    crate::timefmt::now_utc_datetime()
}


/// Cache everything a bookmark listing showed, target first so the
/// bookmarks target-exists trigger passes: the work (or series) blurb,
/// then the AO3 bookmark record attributed to whoever made it. Mystery
/// blurbs (unrevealed challenge works) carry only a synthetic display
/// stub — no real data to cache — and are skipped. Returns the target's
/// row id (once saved) and the bookmark record's row id, or None for
/// each that was not cached (mystery, unattributed, or no blurb).
pub(super) fn cache_bookmark_listing(s: &Storage, l: &BookmarkListing) -> (Option<BookmarkTarget>, Option<i64>) {
    if l.mystery {
        return (None, None);
    }
    let target = match l.kind {
        BookmarkKind::Work => {
            let Some(w) = l.work_summary.as_ref() else { return (None, None) };
            match s.save_work(w) {
                Ok(id) => BookmarkTarget::Work(id),
                Err(e) => { log_error!("db", "save_work failed: {e}"); return (None, None); }
            }
        }
        BookmarkKind::Series => {
            let Some(sr) = l.series_summary.as_ref() else { return (None, None) };
            match s.save_series(sr) {
                Ok(id) => BookmarkTarget::Series(id),
                Err(e) => { log_error!("db", "save_series failed: {e}"); return (None, None); }
            }
        }
    };
    let id = match s.cache_fetched_bookmark_for(&l.bookmarker, target, l.ao3_bookmark_id,
                                                &l.note, &l.tags.join(", "), l.rec) {
        Ok(id) => id,
        Err(e) => {
            crate::log_error!("db", "cache_fetched_bookmark failed: {e}");
            None
        }
    };
    (Some(target), id)
}

/// A remote listing as a search hit (cached or not). `target` is the
/// saved target's row id; a hit that was not cached has target id 0.
pub(super) fn hit_from_listing(l: BookmarkListing, target: Option<BookmarkTarget>, id: Option<i64>) -> BookmarkHit {
    BookmarkHit {
        id: id.unwrap_or(0),
        target: target.unwrap_or_else(|| l.kind.with_id(0)),
        bookmarker: l.bookmarker,
        note: l.note,
        tags: l.tags,
        rec: l.rec,
        date_bookmarked: l.date_bookmarked,
        mystery: l.mystery,
        mystery_collection_name: l.mystery_collection_name,
        mystery_collection_title: l.mystery_collection_title,
        work: l.work_summary,
        series: l.series_summary,
    }
}

// scaffolding is in lib.rs

#[cfg(test)]
mod byline_tests {
    use crate::models::split_author_byline;

    #[test]
    fn test_split_author_byline() {
        assert_eq!(split_author_byline("tealvneu"), ("tealvneu".to_string(), None));
        assert_eq!(split_author_byline("saltedriceball (tealvneu)"),
                   ("tealvneu".to_string(), Some("saltedriceball".to_string())));
        assert_eq!(split_author_byline("saltedriceball(tealvneu)"),
                   ("tealvneu".to_string(), Some("saltedriceball".to_string())));
        assert_eq!(split_author_byline("  plain_name  "), ("plain_name".to_string(), None));
        // Same pseud as username still splits to the clean account name.
        assert_eq!(split_author_byline("astolat (astolat)"),
                   ("astolat".to_string(), Some("astolat".to_string())));
    }
}
