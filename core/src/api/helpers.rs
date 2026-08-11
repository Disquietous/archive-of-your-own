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
    let Ok(Some((_, username, _))) = s.get_active_account() else { return };
    if !username.is_empty() && kudos_names.iter().any(|n| n.eq_ignore_ascii_case(&username)) {
        log_db("mark_kudos_given", s.mark_kudos_given(work_id));
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

/// How old a subscription's own `last_checked_at` may be before it joins
/// the next check round (mirrored by the Swift auto-check gate's cadence).
pub(super) const CHECK_INTERVAL_SECS: u64 = 3600;

/// Everything a check round covers: persisted subscriptions plus
/// device-local followed authors, deduplicated.
pub(super) fn check_entries(s: &Storage, extra_authors: &[String])
    -> Result<Vec<(String, String, String)>, AO3Error> {
    let subs = s.get_subscriptions().map_err(AO3Error::from)?;
    let mut entries: Vec<(String, String, String)> = subs.into_iter()
        .map(|(t, id, name, _)| (t, id, name))
        .collect();
    for follow in extra_authors {
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
    Ok(entries)
}

/// Is this subscription's own check stale? Missing row, NULL, or
/// unparseable all count as never-checked.
pub(super) fn snapshot_check_due(s: &Storage, sub_type: &str, sub_id: &str) -> bool {
    match s.get_snapshot_last_checked(sub_type, sub_id) {
        Ok(Some(at)) if !at.is_empty() => {
            let then = crate::timefmt::datetime_to_epoch(&at).unwrap_or(0);
            crate::timefmt::epoch_now().saturating_sub(then) > CHECK_INTERVAL_SECS
        }
        _ => true,
    }
}
/// How often an age-based full-listing census runs per subscription.
pub(super) const CENSUS_INTERVAL_SECS: u64 = 7 * 24 * 3600;
/// Hard page cap per census — safety valve against pagination anomalies.
pub(super) const CENSUS_MAX_PAGES: u32 = 200;

/// In-progress census bookkeeping, persisted in the snapshot row so a
/// cancelled or crashed check resumes where it left off.
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

/// The What's-New qualification rules applied to one page of parsed blurbs.
/// Returns (work ids to flag, how many were never in the cache).
pub(super) fn diff_and_flag_works(
    s: &Storage,
    parsed_works: &[WorkSummary],
    sub_type: &str,
    sub_name: &str,
    seed: bool,
) -> (Vec<u64>, usize) {
    // Per-work diff against the local cache, BEFORE overwriting it.
    // date_updated is day-granular, so a chapter posted later the
    // same day is invisible to date comparison — chapter and word
    // counts (already in the parsed blurbs) catch it.
    let mut updated_ids: Vec<u64> = Vec::new();
    let mut unseen = 0usize;
    for w in parsed_works {
        match s.get_work(w.id) {
            Ok(Some(old)) => {
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
                        "word_count {} → {} (rule: edits that add/remove text without a new chapter still count as an update)",
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
                        w.id, w.title, sub_type, sub_name, reasons.join("; "));
                    updated_ids.push(w.id);
                } else if date_changed {
                    log_info!("whats_new",
                        "Suppressed work {} '{}' from {} subscription '{}': {} — no chapter/word change corroborates it (rule: an uncorroborated date change is site-side date drift, not an update; the fresh date is cached so it won't re-trigger)",
                        w.id, w.title, sub_type, sub_name, reasons.join("; "));
                }
            }
            Ok(None) => {
                // never seen — new work
                unseen += 1;
                if seed {
                    continue;
                }
                log_info!("whats_new",
                    "Flagged work {} '{}' from {} subscription '{}': not in the local works cache (rule: a work we've never cached from any source is new to us)",
                    w.id, w.title, sub_type, sub_name);
                updated_ids.push(w.id);
            }
            Err(_) => {}
        }
    }
    (updated_ids, unseen)
}

/// Census complete: `seen_ids` is everything AO3 still lists. Reconcile the
/// gone-from-AO3 flags, adopt the authoritative total, stamp the census
/// time, and clear the in-progress state.
pub(super) fn finalize_census(s: &Storage, sub_type: &str, sub_id: &str, sub_name: &str, state: &CensusState) {
    let known = s.get_subscription_work_ids(sub_type, sub_id).unwrap_or_default();
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
    log_db("set_snapshot_total_works", s.set_snapshot_total_works(sub_type, sub_id, seen.len() as u32));
    log_db("set_snapshot_last_census", s.set_snapshot_last_census(sub_type, sub_id, &now_utc()));
    log_db("set_snapshot_census_state", s.set_snapshot_census_state(sub_type, sub_id, None));
    log_info!("whats_new",
        "Census complete for {} subscription '{}' ({}): {} works listed{}",
        sub_type, sub_name, state.reason, seen.len(),
        if state.seed { " — baseline established" } else { "" });
}

/// Append this subscription's census-continuation marker to the check queue
/// (at the tail, so other subscriptions get their turn first). Returns the
/// new queue length.
pub(super) fn requeue_census_marker(s: &Storage, sub_type: &str, sub_id: &str, name: &str) -> u32 {
    let queue_json = s.get_check_queue().ok().flatten().unwrap_or_else(|| "[]".to_string());
    let mut queue: Vec<serde_json::Value> = serde_json::from_str(&queue_json).unwrap_or_default();
    queue.push(serde_json::json!({
        "sub_type": sub_type,
        "sub_id": sub_id,
        "name": name,
        "census": true,
    }));
    log_db("set_check_queue", s.set_check_queue(&serde_json::to_string(&queue).unwrap_or_default()));
    queue.len() as u32
}

/// Chapter-image cache key — the full URL keeps it unique, the prefix
/// groups the rows apart from avatars.
pub(super) fn chapter_image_key(url: &str) -> String {
    format!("chimg:{url}")
}

/// Every image URL in a ContentBlock tree, depth-first (blockquotes, lists).
pub(super) fn collect_image_srcs(blocks: &[crate::models::ContentBlock], out: &mut Vec<String>) {
    use crate::models::ContentBlock;
    for block in blocks {
        match block {
            ContentBlock::Image { src, .. } => {
                if !out.contains(src) {
                    out.push(src.clone());
                }
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

/// AO3 bylines render as "Pseud (Username)" (also without the space) when
/// the pseud differs from the account name. Returns (username, pseud) —
/// plain names pass through as (name, None). Real usernames never contain
/// spaces or parens, so URLs must always use the split-out account name.
pub(super) fn split_author_byline(author: &str) -> (String, Option<String>) {
    let t = author.trim();
    if let Some(open) = t.rfind('(') {
        if t.ends_with(')') {
            let user = t[open + 1..t.len() - 1].trim();
            let pseud = t[..open].trim();
            if !user.is_empty() {
                return (user.to_string(),
                        Some(pseud.to_string()).filter(|p| !p.is_empty()));
            }
        }
    }
    (t.to_string(), None)
}

// scaffolding is in lib.rs

#[cfg(test)]
mod byline_tests {
    use super::split_author_byline;

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
