use std::sync::Arc;

use rusqlite::{params, OptionalExtension};

use crate::error::AppError;
use crate::models::{split_author_byline, WorkSummary};

use super::consts::*;
use super::works_cache::WorkEntity;
use super::{map_sql, Storage};

/// (sub_type, sub_id, name, ao3_id)
pub type SubscriptionRow = (String, String, String, Option<String>);
/// (total_works, last_census_at, census_state)
pub type FollowCensusMeta = (Option<u32>, Option<String>, Option<String>);

/// One follow as stored.
#[derive(Debug, Clone, PartialEq)]
pub struct FollowRow {
    pub kind: String,
    pub target_id: String,
    pub name: String,
    pub added_at: String,
    pub last_checked_at: Option<String>,
    /// What's New not-found counter: 0 = fetched fine, n > 0 = n
    /// consecutive 404s, -1 = excluded from checks.
    pub status: i32,
}

impl Storage {
    // -------------------------------------------------------------------
    // Follows (library-level; the What's New check's only input)
    // -------------------------------------------------------------------

    /// Follows of `kind` (all kinds when None), in the order they were added.
    pub fn get_follows(&self, kind: Option<&str>) -> Result<Vec<FollowRow>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT kind, target_id, name, added_at, last_checked_at, status FROM follows
             WHERE ?1 IS NULL OR kind = ?1 ORDER BY rowid"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![kind], |r| Ok(FollowRow {
            kind: r.get(0)?,
            target_id: r.get(1)?,
            name: r.get(2)?,
            added_at: r.get(3)?,
            last_checked_at: r.get(4)?,
            status: r.get(5)?,
        })).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn is_followed(&self, kind: &str, target_id: &str) -> Result<bool, AppError> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM follows WHERE kind = ?1 AND target_id = ?2",
            params![kind, target_id], |r| r.get(0),
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    /// True when the follow was created (false: it already existed).
    pub fn add_follow(&self, kind: &str, target_id: &str, name: &str) -> Result<bool, AppError> {
        let n = self.conn.execute(
            "INSERT OR IGNORE INTO follows (kind, target_id, name) VALUES (?1, ?2, ?3)",
            params![kind, target_id, name],
        ).map_err(map_sql)?;
        Ok(n > 0)
    }

    /// True when a follow was removed. Its check state goes with it.
    pub fn remove_follow(&self, kind: &str, target_id: &str) -> Result<bool, AppError> {
        let n = self.conn.execute(
            "DELETE FROM follows WHERE kind = ?1 AND target_id = ?2",
            params![kind, target_id],
        ).map_err(map_sql)?;
        Ok(n > 0)
    }

    /// Everything a What's New round covers: (kind, target_id, name) for
    /// every checkable follow, sorted by display name so the request order
    /// is predictable.
    pub fn get_check_targets(&self) -> Result<Vec<(String, String, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT kind, target_id, name FROM follows
             WHERE kind IN ('author', 'work', 'series') AND status >= 0
             ORDER BY name COLLATE NOCASE"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Subscriptions (the signed-in account's AO3 subscriptions only)
    // -------------------------------------------------------------------

    /// The account subscription data belongs to: the active account's
    /// username. None when no account is active — no subscription data is
    /// readable or writable then.
    pub fn subscription_account(&self) -> Option<String> {
        self.get_active_account().ok().flatten()
            .map(|(_, username, _)| username)
            .filter(|u| !u.is_empty())
    }

    /// Drop every subscription row. Runs on every account transition
    /// (activate another account, sign out, remove the active account).
    pub fn clear_subscriptions(&self) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM subscriptions", []).map_err(map_sql)?;
        Ok(())
    }

    /// Replace `account`'s subscription list.
    pub fn save_subscriptions(&self, account: &str,
                              subs: &[(String, String, String, Option<String>)]) -> Result<(), AppError> {
        let mut seen = std::collections::HashSet::new();
        for (sub_type, sub_id, name, _) in subs {
            if !seen.insert((sub_type.as_str(), sub_id.to_lowercase())) {
                crate::dlog("WARN", "storage",
                    &format!("Duplicate subscription: type={sub_type} id={sub_id} name={name}"));
            }
        }
        let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
        tx.execute("DELETE FROM subscriptions WHERE account = ?1", params![account]).map_err(map_sql)?;
        let mut stmt = tx.prepare(SQL_UPSERT_SUBSCRIPTION).map_err(map_sql)?;
        for (sub_type, sub_id, name, ao3_id) in subs {
            stmt.execute(params![account, sub_type, sub_id, name, ao3_id]).map_err(map_sql)?;
        }
        drop(stmt);
        tx.commit().map_err(map_sql)
    }

    pub fn add_subscription(&self, account: &str, sub_type: &str, sub_id: &str, name: &str,
                            ao3_id: Option<&str>) -> Result<(), AppError> {
        self.conn.execute(
            SQL_UPSERT_SUBSCRIPTION,
            params![account, sub_type, sub_id, name, ao3_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_subscription(&self, account: &str, sub_type: &str, sub_id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM subscriptions WHERE account = ?1 AND sub_type = ?2 AND sub_id = ?3",
            params![account, sub_type, sub_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_subscriptions(&self, account: &str) -> Result<Vec<SubscriptionRow>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT sub_type, sub_id, name, ao3_id FROM subscriptions WHERE account = ?1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![account], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?,
                row.get::<_, String>(2)?, row.get::<_, Option<String>>(3)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// `account`'s subscriptions with no matching follow.
    pub fn get_unfollowed_subscriptions(&self, account: &str)
        -> Result<Vec<SubscriptionRow>, AppError>
    {
        let mut stmt = self.conn.prepare(
            "SELECT s.sub_type, s.sub_id, s.name, s.ao3_id FROM subscriptions s
             WHERE s.account = ?1 AND NOT EXISTS (
                 SELECT 1 FROM follows f
                 WHERE f.kind = s.sub_type AND f.target_id = s.sub_id)
             ORDER BY s.name COLLATE NOCASE"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![account], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?,
                row.get::<_, String>(2)?, row.get::<_, Option<String>>(3)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// AO3's subscription record id for one of `account`'s subscriptions.
    pub fn get_subscription_ao3_id(&self, account: &str, sub_type: &str, sub_id: &str)
        -> Result<Option<String>, AppError>
    {
        let mut stmt = self.conn.prepare(
            "SELECT ao3_id FROM subscriptions WHERE account = ?1 AND sub_type = ?2 AND sub_id = ?3"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![account, sub_type, sub_id],
                                      |row| row.get::<_, Option<String>>(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(id)) => Ok(id),
            _ => Ok(None),
        }
    }

    pub fn has_subscription(&self, account: &str, sub_type: &str, sub_id: &str) -> Result<bool, AppError> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM subscriptions WHERE account = ?1 AND sub_type = ?2 AND sub_id = ?3",
            params![account, sub_type, sub_id], |row| row.get(0)
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    // -------------------------------------------------------------------
    // Follow check state (on the follow row). Writes are UPDATE-only: the
    // check never creates a follow, and a target unfollowed mid-check
    // simply absorbs nothing.
    // -------------------------------------------------------------------

    /// The newest update date the last check saw. Ok(None) = no follow row
    /// or never checked (the next check seeds silently).
    pub fn get_follow_baseline(&self, kind: &str, target_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT date_updated FROM follows WHERE kind = ?1 AND target_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![kind, target_id], |row| {
            row.get::<_, Option<String>>(0)
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(d)) => Ok(d.filter(|d| !d.is_empty())),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    pub fn set_follow_baseline(&self, kind: &str, target_id: &str, date_updated: &str) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "date_updated", &date_updated)
    }

    /// Census metadata for one follow: (total_works, last_census_at,
    /// census_state). All None when the follow doesn't exist.
    pub fn get_follow_census_meta(&self, kind: &str, target_id: &str)
        -> Result<FollowCensusMeta, AppError>
    {
        let mut stmt = self.conn.prepare(
            "SELECT total_works, last_census_at, census_state
             FROM follows WHERE kind = ?1 AND target_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![kind, target_id], |row| {
            Ok((
                row.get::<_, Option<u32>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(t)) => Ok(t),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok((None, None, None)),
        }
    }

    pub fn set_follow_total_works(&self, kind: &str, target_id: &str, total: u32) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "total_works", &total)
    }

    /// Persist (or clear, with None) the in-progress census JSON.
    pub fn set_follow_census_state(&self, kind: &str, target_id: &str, state: Option<&str>) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "census_state", &state)
    }

    pub fn set_follow_last_census(&self, kind: &str, target_id: &str, at: &str) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "last_census_at", &at)
    }

    /// Stamp "this follow's own check completed now" — per-row, so an
    /// interrupted round can't misrepresent when each target was actually
    /// checked (the global queue-drain time only describes the round).
    pub fn set_follow_last_checked(&self, kind: &str, target_id: &str, at: &str) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "last_checked_at", &at)
    }

    pub fn get_follow_last_checked(&self, kind: &str, target_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT last_checked_at FROM follows WHERE kind = ?1 AND target_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![kind, target_id], |row| {
            row.get::<_, Option<String>>(0)
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(v),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    /// Count one more consecutive 404 for this follow. Reaching `limit`
    /// (0 = no limit) sets the status to -1, which drops the follow from
    /// every future check. Returns the new status.
    pub fn record_follow_not_found(&self, kind: &str, target_id: &str, limit: u32) -> Result<i32, AppError> {
        self.conn.execute(
            "UPDATE follows SET status = CASE WHEN ?3 > 0 AND status + 1 >= ?3 THEN -1 ELSE status + 1 END
             WHERE kind = ?1 AND target_id = ?2 AND status >= 0",
            params![kind, target_id, limit],
        ).map_err(map_sql)?;
        self.get_follow_status(kind, target_id)
    }

    /// A successful fetch — the not-found streak is over.
    pub fn reset_follow_status(&self, kind: &str, target_id: &str) -> Result<(), AppError> {
        self.update_follow_column(kind, target_id, "status", &0)
    }

    pub fn get_follow_status(&self, kind: &str, target_id: &str) -> Result<i32, AppError> {
        self.conn.query_row(
            "SELECT status FROM follows WHERE kind = ?1 AND target_id = ?2",
            params![kind, target_id], |r| r.get(0),
        ).optional().map_err(map_sql).map(|v| v.unwrap_or(0))
    }

    fn update_follow_column(&self, kind: &str, target_id: &str, column: &str,
                            value: &dyn rusqlite::ToSql) -> Result<(), AppError> {
        self.conn.execute(
            &format!("UPDATE follows SET {column} = ?3 WHERE kind = ?1 AND target_id = ?2"),
            params![kind, target_id, value],
        ).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Works crawls (Refresh Works stamp per author/series)
    // -------------------------------------------------------------------

    pub fn set_works_crawled_at(&self, kind: &str, target_id: &str, at: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO crawl_stamps (kind, target_id, crawled_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(kind, target_id) DO UPDATE SET crawled_at = ?3",
            params![kind, target_id, at],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_works_crawled_at(&self, kind: &str, target_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT crawled_at FROM crawl_stamps WHERE kind = ?1 AND target_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![kind, target_id], |row| row.get::<_, String>(0))
            .map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(Some(v)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Subscription works (derived from the works table)
    // -------------------------------------------------------------------

    /// Every cached work that belongs to an author or series subscription,
    /// answered from the works table (author bylines / series memberships)
    /// — the set the census reconciles against.
    pub fn get_subscription_member_ids(&self, sub_type: &str, sub_id: &str) -> Result<Vec<u64>, AppError> {
        Ok(self.subscription_member_entities(sub_type, sub_id)?
            .into_iter()
            .map(|e| e.summary.id)
            .collect())
    }

    fn subscription_member_entities(&self, sub_type: &str, sub_id: &str)
        -> Result<Vec<Arc<WorkEntity>>, AppError>
    {
        match sub_type {
            SUB_TYPE_AUTHOR => {
                let account = self.users_cache
                    .resolve(sub_id)
                    .map(|e| e.username.clone())
                    .unwrap_or_else(|| split_author_byline(sub_id).0);
                Ok(self.works_cache.all().into_iter()
                    .filter(|e| e.summary.authors.iter()
                        .any(|a| split_author_byline(a).0.eq_ignore_ascii_case(&account)))
                    .collect())
            }
            SUB_TYPE_SERIES => {
                let Ok(series_id) = sub_id.parse::<u64>() else { return Ok(Vec::new()) };
                Ok(self.works_cache.all().into_iter()
                    .filter(|e| e.summary.series.iter().any(|m| m.series_id == series_id))
                    .collect())
            }
            _ => Ok(Vec::new()),
        }
    }

    /// Mark (or clear) works as no longer listed on AO3. The cached rows are
    /// never deleted — this flag is the only record of the disappearance.
    pub fn set_works_gone(&self, work_ids: &[u64], gone: bool) -> Result<(), AppError> {
        self.with_savepoint(Savepoint::WorksGone, || {
            self.works_cache.set_gone(&self.conn, work_ids, gone)
        })
    }

    /// Set (or clear) the user's finished-reading flag. Purely manual —
    /// nothing in the core ever derives it from progress.
    pub fn set_works_finished(&self, work_ids: &[u64], finished: bool) -> Result<(), AppError> {
        self.with_savepoint(Savepoint::WorksFinished, || {
            self.works_cache.set_finished(&self.conn, work_ids, finished)
        })
    }

    /// Works the user has flagged as finished. Answered from the works cache.
    pub fn get_finished_work_ids(&self) -> Result<Vec<u64>, AppError> {
        Ok(self.works_cache
            .all()
            .into_iter()
            .filter(|e| e.finished)
            .map(|e| e.summary.id)
            .collect())
    }

    /// Answered from the works cache.
    pub fn get_gone_work_ids(&self) -> Result<Vec<u64>, AppError> {
        Ok(self.works_cache
            .all()
            .into_iter()
            .filter(|e| e.gone_from_ao3)
            .map(|e| e.summary.id)
            .collect())
    }

    /// Works of a subscription. Author/series come from the works table
    /// (see `get_subscription_member_ids`); series works sort by part,
    /// everything else newest-first like the live listing.
    pub fn get_subscription_works(&self, sub_type: &str, sub_id: &str) -> Result<Vec<WorkSummary>, AppError> {
        let mut works: Vec<WorkSummary> = self.subscription_member_entities(sub_type, sub_id)?
            .iter()
            .map(|e| self.works_cache.hydrate(e, &self.tag_cache))
            .collect();
        match (sub_type, sub_id.parse::<u64>()) {
            (SUB_TYPE_SERIES, Ok(series_id)) => works.sort_by_key(|w| w.series.iter()
                .find(|m| m.series_id == series_id).map(|m| m.part).unwrap_or(0)),
            _ => works.sort_by(|a, b| b.date_updated.cmp(&a.date_updated)),
        }
        Ok(works)
    }

    // -------------------------------------------------------------------
    // Subscription check queue
    // -------------------------------------------------------------------

    pub fn set_check_queue(&self, json: &str) -> Result<(), AppError> {
        self.set_state(STATE_SUB_CHECK_QUEUE, json)
    }

    pub fn get_check_queue(&self) -> Result<Option<String>, AppError> {
        self.get_state(STATE_SUB_CHECK_QUEUE)
    }

    pub fn clear_check_queue(&self) -> Result<(), AppError> {
        self.set_state(STATE_SUB_CHECK_QUEUE, "[]")
    }

    // -------------------------------------------------------------------
    // Subscription new works (What's New feed)
    // -------------------------------------------------------------------

    pub fn add_new_work_ids(&self, ids: &[u64]) -> Result<(), AppError> {
        self.with_savepoint(Savepoint::NewWorkIds, || {
            // A work already in the feed that updates again is new again:
            // reset its seen stamp and bump it to the top of the list.
            let mut stmt = self.conn.prepare_cached(
                "INSERT INTO subscription_new_works (work_id) VALUES (?1)
                 ON CONFLICT(work_id) DO UPDATE SET seen_at = '', added_at = datetime('now')"
            ).map_err(map_sql)?;
            for id in ids {
                stmt.execute(params![*id as i64]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    pub fn get_new_work_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT work_id FROM subscription_new_works ORDER BY added_at DESC"
        ).map_err(map_sql)?;
        let ids = stmt.query_map([], |row| {
            let id: i64 = row.get(0)?;
            Ok(id as u64)
        }).map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();
        Ok(ids)
    }

    /// What's New entries the user has not selected since they were added
    /// (feeds the row "New" badge and the sidebar/dock count).
    pub fn get_unseen_new_work_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT work_id FROM subscription_new_works WHERE seen_at = '' ORDER BY added_at DESC"
        ).map_err(map_sql)?;
        let ids = stmt.query_map([], |row| {
            let id: i64 = row.get(0)?;
            Ok(id as u64)
        }).map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();
        Ok(ids)
    }

    /// Stamp a What's New entry as selected. No-op for works not in the feed.
    pub fn mark_new_work_seen(&self, work_id: u64, at: &str) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE subscription_new_works SET seen_at = ?2 WHERE work_id = ?1 AND seen_at = ''",
            params![work_id as i64, at],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_new_work_id(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM subscription_new_works WHERE work_id = ?1",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn clear_new_work_ids(&self) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM subscription_new_works", []).map_err(map_sql)?;
        Ok(())
    }

    /// Get the last time subscriptions were checked, using the app_state table.
    pub fn get_last_check_time(&self) -> Result<Option<String>, AppError> {
        self.get_state(STATE_LAST_SUB_CHECK)
    }

    /// Set the last subscription check time.
    pub fn set_last_check_time(&self, time: &str) -> Result<(), AppError> {
        self.set_state(STATE_LAST_SUB_CHECK, time)
    }
}
