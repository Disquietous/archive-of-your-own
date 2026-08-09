use std::collections::HashSet;

use super::*;

// ---------------------------------------------------------------------------
// Work-list filter/sort compute — the shared engine behind every section's
// sort menu and filter popover. Lives here (not in the UIs) so both
// platforms apply identical rules; the UI layers only supply the section's
// id list and the user's choices.
// ---------------------------------------------------------------------------

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    /// Filter and sort a section's work list. `work_ids` is the section's
    /// membership in natural order; metadata comes from the works cache, so
    /// ids without a cached row drop out. Returns ids in display order.
    pub fn filter_and_sort_works(&self, work_ids: Vec<u64>, query: UWorkListQuery)
        -> Result<Vec<u64>, AO3Error> {
        let works = {
            let s = self.storage.blocking_lock();
            s.get_works_by_ids(&work_ids)?
        };
        Ok(filter_and_sort(works, &query))
    }

    /// The distinct tags and fandoms across a work list AFTER the section
    /// filters (completion/rating/explicit) but BEFORE the list filter —
    /// the filter dialog's suggestion pools. Case-insensitively sorted.
    pub fn work_filter_options(&self, work_ids: Vec<u64>, query: UWorkListQuery)
        -> Result<UWorkFilterOptions, AO3Error> {
        let works = {
            let s = self.storage.blocking_lock();
            s.get_works_by_ids(&work_ids)?
        };
        let mut tags = HashSet::new();
        let mut fandoms = HashSet::new();
        for w in works.iter().filter(|w| passes_section_filters(w, &query)) {
            tags.extend(w.tags.iter().cloned());
            fandoms.extend(work_fandoms(w));
        }
        Ok(UWorkFilterOptions {
            tags: case_insensitive_sorted(tags),
            fandoms: case_insensitive_sorted(fandoms),
        })
    }

    /// Cache a listing (browse/search/tag results) as ids only — the works
    /// themselves already live in the works cache via save_work. Replaces
    /// the UI layers' JSON-encoded work blobs.
    pub fn set_cached_work_list(&self, key: String, session_id: String, work_ids: Vec<u64>)
        -> Result<(), AO3Error> {
        let json = serde_json::to_string(&work_ids).unwrap_or_else(|_| "[]".to_string());
        let s = self.storage.blocking_lock();
        s.set_cache(&format!("worklist:{key}"), &json, &session_id).map_err(AO3Error::from)
    }

    /// A cached listing, hydrated from the works cache. None when the key
    /// is absent, from another session, or hydrates to nothing.
    pub fn get_cached_work_list(&self, key: String, session_id: String)
        -> Result<Option<Vec<UWorkSummary>>, AO3Error> {
        let s = self.storage.blocking_lock();
        let Some(json) = s.get_cache(&format!("worklist:{key}"), &session_id)
            .map_err(AO3Error::from)? else {
            return Ok(None);
        };
        let ids: Vec<u64> = serde_json::from_str(&json).unwrap_or_default();
        let works = s.get_works_by_ids(&ids)?;
        if works.is_empty() {
            return Ok(None);
        }
        Ok(Some(works.into_iter().map(UWorkSummary::from).collect()))
    }
}

pub(super) fn filter_and_sort(mut works: Vec<WorkSummary>, q: &UWorkListQuery) -> Vec<u64> {
    works.retain(|w| passes_section_filters(w, q) && passes_list_filter(w, q));
    match q.sort.as_str() {
        "updated" => works.sort_by(|a, b| b.date_updated.cmp(&a.date_updated)),
        "kudos" => works.sort_by(|a, b| b.kudos.cmp(&a.kudos)),
        "words" => works.sort_by(|a, b| b.word_count.cmp(&a.word_count)),
        "title" => works.sort_by_key(|w| w.title.to_lowercase()),
        _ => {} // "natural": keep the caller's order
    }
    works.into_iter().map(|w| w.id).collect()
}

/// The same encoding UWorkSummary uses for ratings.
fn rating_str(w: &WorkSummary) -> String {
    format!("{:?}", w.rating)
}

fn passes_section_filters(w: &WorkSummary, q: &UWorkListQuery) -> bool {
    let rating = rating_str(w);
    let explicit_ok = !q.hide_explicit || rating != "Explicit";
    let completion_ok = match q.completion.as_str() {
        "complete" => w.complete,
        "inProgress" => !w.complete,
        _ => true,
    };
    let rating_ok = q.rating.as_deref().is_none_or(|r| rating == r);
    explicit_ok && completion_ok && rating_ok
}

/// A work with no fandom tags files under this placeholder — the same name
/// the UI renders for it — so the fandom filter can still target it.
const UNKNOWN_FANDOM: &str = "Unknown Fandom";

fn work_fandoms(w: &WorkSummary) -> Vec<String> {
    if w.fandoms.is_empty() {
        vec![UNKNOWN_FANDOM.to_string()]
    } else {
        w.fandoms.clone()
    }
}

fn passes_list_filter(w: &WorkSummary, q: &UWorkListQuery) -> bool {
    let needle = q.text.trim().to_lowercase();
    let text_ok = needle.is_empty()
        || w.title.to_lowercase().contains(&needle)
        || w.authors.iter().any(|a| a.to_lowercase().contains(&needle))
        || w.summary.to_lowercase().contains(&needle);
    // Tag/fandom selections are OR within their group: a work matches if it
    // carries ANY selected tag / ANY selected fandom.
    let tags_ok = q.tags.is_empty() || w.tags.iter().any(|t| q.tags.contains(t));
    let fandoms_ok = q.fandoms.is_empty()
        || work_fandoms(w).iter().any(|f| q.fandoms.contains(f));
    let kudos_ok = matches_count(w.kudos as i64, &q.kudos_expr);
    let words_ok = matches_count(w.word_count as i64, &q.words_expr);
    text_ok && tags_ok && fandoms_ok && kudos_ok && words_ok
}

/// ">" / "<" prefixed comparisons; a plain number means "at least".
/// Unparseable input filters nothing.
fn matches_count(value: i64, expression: &str) -> bool {
    let trimmed = expression.trim();
    if trimmed.is_empty() {
        return true;
    }
    if let Some(rest) = trimmed.strip_prefix('>') {
        return rest.trim().parse::<i64>().map_or(true, |n| value > n);
    }
    if let Some(rest) = trimmed.strip_prefix('<') {
        return rest.trim().parse::<i64>().map_or(true, |n| value < n);
    }
    trimmed.parse::<i64>().map_or(true, |n| value >= n)
}

fn case_insensitive_sorted(set: HashSet<String>) -> Vec<String> {
    let mut v: Vec<String> = set.into_iter().collect();
    v.sort_by_key(|s| s.to_lowercase());
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Rating;

    fn work(id: u64, title: &str, kudos: u32, words: u64, updated: &str,
            complete: bool, rating: Rating, tags: &[&str], fandoms: &[&str]) -> WorkSummary {
        WorkSummary {
            id,
            title: title.to_string(),
            authors: vec!["author_a".to_string()],
            fandoms: fandoms.iter().map(|s| s.to_string()).collect(),
            rating,
            warnings: vec![],
            categories: vec![],
            relationships: vec![],
            characters: vec![],
            tags: tags.iter().map(|s| s.to_string()).collect(),
            summary: "a quiet summary".to_string(),
            word_count: words,
            chapter_count: 1,
            total_chapters: Some(1),
            kudos,
            hits: 0,
            bookmarks: 0,
            comments: 0,
            date_published: "2024-01-01".to_string(),
            date_updated: updated.to_string(),
            language: "en".to_string(),
            complete,
            series: vec![],
            fetched_at: String::new(),
        }
    }

    fn query() -> UWorkListQuery {
        UWorkListQuery {
            sort: "natural".to_string(),
            completion: "all".to_string(),
            rating: None,
            hide_explicit: false,
            text: String::new(),
            kudos_expr: String::new(),
            words_expr: String::new(),
            tags: vec![],
            fandoms: vec![],
        }
    }

    #[test]
    fn natural_sort_keeps_order_and_sorts_apply() {
        let works = vec![
            work(1, "Beta", 5, 100, "2024-02-01", true, Rating::General, &[], &[]),
            work(2, "alpha", 9, 50, "2024-03-01", true, Rating::General, &[], &[]),
            work(3, "Gamma", 7, 200, "2024-01-01", true, Rating::General, &[], &[]),
        ];
        let mut q = query();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1, 2, 3]);
        q.sort = "kudos".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![2, 3, 1]);
        q.sort = "words".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![3, 1, 2]);
        q.sort = "updated".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![2, 1, 3]);
        q.sort = "title".to_string();
        assert_eq!(filter_and_sort(works, &q), vec![2, 1, 3]);
    }

    #[test]
    fn section_filters() {
        let works = vec![
            work(1, "Done", 0, 0, "", true, Rating::General, &[], &[]),
            work(2, "WIP", 0, 0, "", false, Rating::Explicit, &[], &[]),
        ];
        let mut q = query();
        q.completion = "complete".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1]);
        q.completion = "inProgress".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![2]);
        q = query();
        q.hide_explicit = true;
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1]);
        q = query();
        q.rating = Some("Explicit".to_string());
        assert_eq!(filter_and_sort(works, &q), vec![2]);
    }

    #[test]
    fn list_filter_text_tags_and_counts() {
        let works = vec![
            work(1, "The Lighthouse", 250, 90_000, "", true, Rating::General,
                 &["Slow Burn"], &["Fandom A"]),
            work(2, "Harbor Nights", 40, 5_000, "", true, Rating::General,
                 &["Fluff"], &["Fandom B"]),
        ];
        let mut q = query();
        q.text = "lighthouse".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1]);
        q = query();
        q.tags = vec!["Fluff".to_string()];
        assert_eq!(filter_and_sort(works.clone(), &q), vec![2]);
        q = query();
        q.fandoms = vec!["Fandom A".to_string()];
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1]);
        q = query();
        q.kudos_expr = ">100".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1]);
        q = query();
        q.words_expr = "<10000".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![2]);
        // Plain number = at least; unparseable filters nothing.
        q = query();
        q.kudos_expr = "40".to_string();
        assert_eq!(filter_and_sort(works.clone(), &q), vec![1, 2]);
        q.kudos_expr = "banana".to_string();
        assert_eq!(filter_and_sort(works, &q), vec![1, 2]);
    }

    #[test]
    fn fandomless_work_files_under_placeholder() {
        let works = vec![work(1, "Orphan", 0, 0, "", true, Rating::General, &[], &[])];
        let mut q = query();
        q.fandoms = vec![UNKNOWN_FANDOM.to_string()];
        assert_eq!(filter_and_sort(works, &q), vec![1]);
    }
}
