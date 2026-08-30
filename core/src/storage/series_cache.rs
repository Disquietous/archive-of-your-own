use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::SeriesSummary;

use super::{map_json, map_sql};

/// The series table's in-memory mirror and single write authority — same
/// contract as the other storage caches. Keyed by the AO3 series id
/// (`series.id`), exactly as works are keyed by the AO3 work id.
///
/// Series rows exist so a series bookmark has a referent (the bookmarks
/// target-exists trigger checks this table); they carry what a series
/// blurb shows.
#[derive(Default)]
pub(super) struct SeriesCache {
    map: RefCell<HashMap<u64, Arc<SeriesSummary>>>,
}

impl SeriesCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT id, name, authors_json, summary, word_count, work_count, complete,
                        date_updated, fetched_at
                 FROM series",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                let authors_json: String = r.get(2)?;
                Ok(SeriesSummary {
                    id: r.get::<_, i64>(0)? as u64,
                    name: r.get(1)?,
                    authors: serde_json::from_str(&authors_json).unwrap_or_default(),
                    summary: r.get(3)?,
                    word_count: r.get::<_, i64>(4)? as u64,
                    work_count: r.get::<_, i64>(5)? as u32,
                    complete: r.get::<_, i64>(6)? != 0,
                    date_updated: r.get(7)?,
                    fetched_at: r.get(8)?,
                })
            })
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        map.clear();
        for row in rows {
            let s = row.map_err(map_sql)?;
            map.insert(s.id, Arc::new(s));
        }
        Ok(())
    }

    pub(super) fn get(&self, id: u64) -> Option<Arc<SeriesSummary>> {
        self.map.borrow().get(&id).cloned()
    }

    pub(super) fn contains(&self, id: u64) -> bool {
        self.map.borrow().contains_key(&id)
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert a series summary. `fetched_at` is stamped by the caller.
    /// Upsert, never REPLACE — a REPLACE deletes the row first, which
    /// would fire the bookmarks cascade trigger.
    pub(super) fn save(&self, conn: &Connection, series: &SeriesSummary, fetched_at: &str)
        -> Result<(), AppError>
    {
        conn.execute(
                "INSERT INTO series (id, name, authors_json, summary, word_count, work_count,
                                     complete, date_updated, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(id) DO UPDATE SET
                    name = ?2, authors_json = ?3, summary = ?4, word_count = ?5,
                    work_count = ?6, complete = ?7, date_updated = ?8, fetched_at = ?9",
                params![
                    series.id as i64,
                    series.name,
                    serde_json::to_string(&series.authors).map_err(map_json)?,
                    series.summary,
                    series.word_count as i64,
                    series.work_count as i64,
                    series.complete as i64,
                    series.date_updated,
                    fetched_at,
                ],
            )
            .map_err(map_sql)?;
        let mut stored = series.clone();
        stored.fetched_at = fetched_at.to_string();
        self.map.borrow_mut().insert(series.id, Arc::new(stored));
        Ok(())
    }

    /// Ensure a row exists for `id` (a bare stub when nothing better is
    /// known) so a bookmark can reference it. Leaves an existing row alone.
    pub(super) fn ensure(&self, conn: &Connection, id: u64, name: &str, fetched_at: &str)
        -> Result<bool, AppError>
    {
        if self.contains(id) {
            return Ok(false);
        }
        let stub = SeriesSummary { id, name: name.to_string(), ..Default::default() };
        self.save(conn, &stub, fetched_at)?;
        Ok(true)
    }

    /// Delete a series row; its bookmarks cascade via trigger (the
    /// bookmarks cache mirrors that separately).
    pub(super) fn delete(&self, conn: &Connection, id: u64) -> Result<(), AppError> {
        conn.execute("DELETE FROM series WHERE id = ?1", params![id as i64])
            .map_err(map_sql)?;
        self.map.borrow_mut().remove(&id);
        Ok(())
    }
}
