use rusqlite::params;

use crate::error::AppError;
use crate::models::WorkSummary;

use super::{map_sql, Storage};

impl Storage {
    // -------------------------------------------------------------------
    // Followed items (device-local fandom/author follows)
    // -------------------------------------------------------------------

    /// The user's follows of `kind` ("fandom" or "author"), in the order
    /// they were added — matching the list order the UI always showed.
    pub fn get_followed(&self, kind: &str) -> Result<Vec<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT name FROM followed_items WHERE kind = ?1 ORDER BY rowid"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![kind], |row| row.get::<_, String>(0))
            .map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn add_followed(&self, kind: &str, name: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR IGNORE INTO followed_items (kind, name) VALUES (?1, ?2)",
            params![kind, name],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_followed(&self, kind: &str, name: &str) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM followed_items WHERE kind = ?1 AND name = ?2",
            params![kind, name],
        ).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Subscriptions (persisted list)
    // -------------------------------------------------------------------

    pub fn save_subscriptions(&self, subs: &[(String, String, String, Option<String>)]) -> Result<(), AppError> {
        let mut seen = std::collections::HashSet::new();
        for (sub_type, sub_id, name, _) in subs {
            if !seen.insert((sub_type.as_str(), sub_id.as_str())) {
                crate::dlog("WARN", "storage",
                    &format!("Duplicate subscription: type={sub_type} id={sub_id} name={name}"));
            }
        }
        let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
        tx.execute("DELETE FROM subscriptions", []).map_err(map_sql)?;
        let mut stmt = tx.prepare(
            "INSERT OR REPLACE INTO subscriptions (sub_type, sub_id, name, ao3_id) VALUES (?1, ?2, ?3, ?4)"
        ).map_err(map_sql)?;
        for (sub_type, sub_id, name, ao3_id) in subs {
            stmt.execute(params![sub_type, sub_id, name, ao3_id]).map_err(map_sql)?;
        }
        drop(stmt);
        tx.commit().map_err(map_sql)
    }

    pub fn add_subscription(&self, sub_type: &str, sub_id: &str, name: &str,
                            ao3_id: Option<&str>) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO subscriptions (sub_type, sub_id, name, ao3_id) VALUES (?1, ?2, ?3, ?4)",
            params![sub_type, sub_id, name, ao3_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_subscription(&self, sub_type: &str, sub_id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM subscriptions WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_subscriptions(&self) -> Result<Vec<(String, String, String, Option<String>)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT sub_type, sub_id, name, ao3_id FROM subscriptions"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?,
                row.get::<_, String>(2)?, row.get::<_, Option<String>>(3)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// AO3's subscription record id for a local subscription, when known.
    pub fn get_subscription_ao3_id(&self, sub_type: &str, sub_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT ao3_id FROM subscriptions WHERE sub_type = ?1 AND sub_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![sub_type, sub_id],
                                      |row| row.get::<_, Option<String>>(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(id)) => Ok(id),
            _ => Ok(None),
        }
    }

    pub fn has_subscription(&self, sub_type: &str, sub_id: &str) -> Result<bool, AppError> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM subscriptions WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id], |row| row.get(0)
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    // -------------------------------------------------------------------
    // Subscription snapshots (one date per subscription)
    // -------------------------------------------------------------------

    pub fn save_subscription_snapshot(
        &self,
        sub_type: &str,
        sub_id: &str,
        date_updated: &str,
    ) -> Result<(), AppError> {
        // Upsert, NOT INSERT OR REPLACE: replace would null out the census
        // columns (total_works, last_census_at, census_state) on every check.
        self.conn
            .execute(
                "INSERT INTO subscription_snapshots (sub_type, sub_id, date_updated)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(sub_type, sub_id) DO UPDATE SET date_updated = ?3",
                params![sub_type, sub_id, date_updated],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Census metadata for one subscription: (total_works, last_census_at,
    /// census_state). All None when the row doesn't exist yet.
    pub fn get_snapshot_census_meta(
        &self,
        sub_type: &str,
        sub_id: &str,
    ) -> Result<(Option<u32>, Option<String>, Option<String>), AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT total_works, last_census_at, census_state
             FROM subscription_snapshots WHERE sub_type = ?1 AND sub_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![sub_type, sub_id], |row| {
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

    pub fn set_snapshot_total_works(
        &self,
        sub_type: &str,
        sub_id: &str,
        total: u32,
    ) -> Result<(), AppError> {
        self.ensure_snapshot_row(sub_type, sub_id)?;
        self.conn.execute(
            "UPDATE subscription_snapshots SET total_works = ?3
             WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id, total],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Persist (or clear, with None) the in-progress census JSON.
    pub fn set_snapshot_census_state(
        &self,
        sub_type: &str,
        sub_id: &str,
        state: Option<&str>,
    ) -> Result<(), AppError> {
        self.ensure_snapshot_row(sub_type, sub_id)?;
        self.conn.execute(
            "UPDATE subscription_snapshots SET census_state = ?3
             WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id, state],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn set_snapshot_last_census(
        &self,
        sub_type: &str,
        sub_id: &str,
        at: &str,
    ) -> Result<(), AppError> {
        self.ensure_snapshot_row(sub_type, sub_id)?;
        self.conn.execute(
            "UPDATE subscription_snapshots SET last_census_at = ?3
             WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id, at],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn set_works_crawled_at(&self, sub_type: &str, sub_id: &str, at: &str) -> Result<(), AppError> {
        self.ensure_snapshot_row(sub_type, sub_id)?;
        self.conn.execute(
            "UPDATE subscription_snapshots SET works_crawled_at = ?3
             WHERE sub_type = ?1 AND sub_id = ?2",
            params![sub_type, sub_id, at],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_works_crawled_at(&self, sub_type: &str, sub_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT works_crawled_at FROM subscription_snapshots
             WHERE sub_type = ?1 AND sub_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![sub_type, sub_id], |row| {
            row.get::<_, Option<String>>(0)
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(v),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    fn ensure_snapshot_row(&self, sub_type: &str, sub_id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR IGNORE INTO subscription_snapshots (sub_type, sub_id, date_updated)
             VALUES (?1, ?2, '')",
            params![sub_type, sub_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_subscription_snapshot(
        &self,
        sub_type: &str,
        sub_id: &str,
    ) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT date_updated FROM subscription_snapshots WHERE sub_type = ?1 AND sub_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![sub_type, sub_id], |row| {
            row.get::<_, String>(0)
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(d)) => Ok(Some(d)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Subscription works cache
    // -------------------------------------------------------------------

    pub fn save_subscription_works(&self, sub_type: &str, sub_id: &str, work_ids: &[u64]) -> Result<(), AppError> {
        self.with_savepoint("sub_works", || {
            self.conn.execute(
                "DELETE FROM subscription_works WHERE sub_type = ?1 AND sub_id = ?2",
                params![sub_type, sub_id],
            ).map_err(map_sql)?;
            let mut stmt = self.conn.prepare_cached(
                "INSERT INTO subscription_works (sub_type, sub_id, work_id) VALUES (?1, ?2, ?3)"
            ).map_err(map_sql)?;
            for id in work_ids {
                stmt.execute(params![sub_type, sub_id, *id as i64]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    /// Add works to a subscription's cached set without dropping existing
    /// Just the associated work ids — the cheap set-membership view the
    /// census reconciles against.
    pub fn get_subscription_work_ids(&self, sub_type: &str, sub_id: &str) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT work_id FROM subscription_works WHERE sub_type = ?1 AND sub_id = ?2"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![sub_type, sub_id], |row| row.get::<_, u64>(0))
            .map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Mark (or clear) works as no longer listed on AO3. The cached rows are
    /// never deleted — this flag is the only record of the disappearance.
    pub fn set_works_gone(&self, work_ids: &[u64], gone: bool) -> Result<(), AppError> {
        self.with_savepoint("works_gone", || {
            let mut stmt = self.conn.prepare_cached(
                "UPDATE works SET gone_from_ao3 = ?2 WHERE id = ?1"
            ).map_err(map_sql)?;
            for id in work_ids {
                stmt.execute(params![id, gone as i64]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    pub fn get_gone_work_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id FROM works WHERE gone_from_ao3 = 1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| row.get::<_, u64>(0)).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// associations (unlike save_subscription_works, which replaces the set).
    pub fn add_subscription_works(&self, sub_type: &str, sub_id: &str, work_ids: &[u64]) -> Result<(), AppError> {
        self.with_savepoint("add_sub_works", || {
            let mut stmt = self.conn.prepare_cached(
                "INSERT OR IGNORE INTO subscription_works (sub_type, sub_id, work_id) VALUES (?1, ?2, ?3)"
            ).map_err(map_sql)?;
            for id in work_ids {
                stmt.execute(params![sub_type, sub_id, *id as i64]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    pub fn get_subscription_works(&self, sub_type: &str, sub_id: &str) -> Result<Vec<WorkSummary>, AppError> {
        // Series works keep their crawl (reading) order; author works sort
        // newest-first like the live listing.
        let order = if sub_type == "series" { "sw.rowid ASC" } else { "w.date_updated DESC" };
        let mut stmt = self.conn.prepare(&format!(
            "SELECT w.id, w.title, w.authors_json, w.fandoms_json, w.rating,
                    w.warnings_json, w.categories_json, w.relationships_json,
                    w.characters_json, w.tags_json, w.summary, w.word_count,
                    w.chapter_count, w.total_chapters, w.kudos, w.hits,
                    w.bookmarks, w.comments, w.date_published, w.date_updated, w.language, w.complete,
                    w.series_json, w.fetched_at
             FROM subscription_works sw
             JOIN works w ON w.id = sw.work_id
             WHERE sw.sub_type = ?1 AND sw.sub_id = ?2
             ORDER BY {order}"
        )).map_err(map_sql)?;
        let rows = stmt.query_map(params![sub_type, sub_id], |row| {
            Ok(Self::work_from_row(row))
        }).map_err(map_sql)?;
        let mut works = Vec::new();
        for r in rows {
            if let Ok(Ok(w)) = r { works.push(w); }
        }
        Ok(works)
    }

    // -------------------------------------------------------------------
    // Subscription check queue
    // -------------------------------------------------------------------

    pub fn set_check_queue(&self, json: &str) -> Result<(), AppError> {
        self.set_state("subscription_check_queue", json)
    }

    pub fn get_check_queue(&self) -> Result<Option<String>, AppError> {
        self.get_state("subscription_check_queue")
    }

    pub fn clear_check_queue(&self) -> Result<(), AppError> {
        self.set_state("subscription_check_queue", "[]")
    }

    // -------------------------------------------------------------------
    // Subscription new works (What's New feed)
    // -------------------------------------------------------------------

    pub fn add_new_work_ids(&self, ids: &[u64]) -> Result<(), AppError> {
        self.with_savepoint("new_work_ids", || {
            let mut stmt = self.conn.prepare_cached(
                "INSERT OR IGNORE INTO subscription_new_works (work_id) VALUES (?1)"
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
        self.get_state("last_subscription_check")
    }

    /// Set the last subscription check time.
    pub fn set_last_check_time(&self, time: &str) -> Result<(), AppError> {
        self.set_state("last_subscription_check", time)
    }
}
