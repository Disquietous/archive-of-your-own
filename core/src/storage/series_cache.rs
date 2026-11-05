use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{ExternalRef, SeriesSummary};

use super::{map_json, map_sql};

/// The series table's in-memory mirror and single write authority — same
/// contract as the other storage caches. Keyed by row id, with a
/// (source, external_id) index alongside.
///
/// Series rows exist so a series bookmark, follow, or work membership has
/// a referent; they carry what a series blurb shows, or just a name (a
/// stub from a membership or a link) until a blurb arrives.
#[derive(Default)]
pub(super) struct SeriesCache {
    map: RefCell<HashMap<u64, Arc<SeriesSummary>>>,
    by_external: RefCell<HashMap<(String, String), u64>>,
}

impl SeriesCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT id, source, external_id, url, name, authors_json, summary, word_count,
                        work_count, complete, date_updated, fetched_at
                 FROM series",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                let authors_json: String = r.get(5)?;
                Ok(SeriesSummary {
                    id: r.get::<_, i64>(0)? as u64,
                    source: r.get(1)?,
                    external_id: r.get(2)?,
                    url: r.get(3)?,
                    name: r.get(4)?,
                    authors: serde_json::from_str(&authors_json).unwrap_or_default(),
                    summary: r.get(6)?,
                    word_count: r.get::<_, i64>(7)? as u64,
                    work_count: r.get::<_, i64>(8)? as u32,
                    complete: r.get::<_, i64>(9)? != 0,
                    date_updated: r.get(10)?,
                    fetched_at: r.get(11)?,
                })
            })
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        let mut by_external = self.by_external.borrow_mut();
        map.clear();
        by_external.clear();
        for row in rows {
            let s = row.map_err(map_sql)?;
            by_external.insert((s.source.clone(), s.external_id.clone()), s.id);
            map.insert(s.id, Arc::new(s));
        }
        Ok(())
    }

    pub(super) fn get(&self, id: u64) -> Option<Arc<SeriesSummary>> {
        self.map.borrow().get(&id).cloned()
    }

    pub(super) fn resolve(&self, source: &str, external_id: &str) -> Option<u64> {
        self.by_external.borrow().get(&(source.to_string(), external_id.to_string())).copied()
    }

    fn insert(&self, s: SeriesSummary) {
        self.by_external.borrow_mut().insert((s.source.clone(), s.external_id.clone()), s.id);
        self.map.borrow_mut().insert(s.id, Arc::new(s));
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert a series summary by (source, external_id); the input's `id`
    /// is ignored. Returns the row id. `fetched_at` is stamped by the
    /// caller. Upsert, never REPLACE — a REPLACE deletes the row first,
    /// which would fire the cascade triggers.
    pub(super) fn save(&self, conn: &Connection, series: &SeriesSummary, fetched_at: &str)
        -> Result<u64, AppError>
    {
        let existing = self.resolve(&series.source, &series.external_id);
        conn.execute(
                "INSERT INTO series (source, external_id, url, name, authors_json, summary, word_count,
                                     work_count, complete, date_updated, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(source, external_id) DO UPDATE SET
                    url = ?3, name = ?4, authors_json = ?5, summary = ?6, word_count = ?7,
                    work_count = ?8, complete = ?9, date_updated = ?10, fetched_at = ?11",
                params![
                    series.source,
                    series.external_id,
                    series.url,
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
        let id = existing.unwrap_or_else(|| conn.last_insert_rowid() as u64);
        let mut stored = series.clone();
        stored.id = id;
        stored.fetched_at = fetched_at.to_string();
        self.insert(stored);
        Ok(id)
    }

    /// Ensure a row exists for the external ref (a name-only stub when
    /// nothing better is known) so a bookmark, follow, or membership can
    /// reference it. Leaves an existing row alone. Returns the row id.
    pub(super) fn ensure(&self, conn: &Connection, external: &ExternalRef, name: &str)
        -> Result<u64, AppError>
    {
        if let Some(id) = self.resolve(&external.source, &external.external_id) {
            return Ok(id);
        }
        let stub = SeriesSummary {
            id: 0,
            source: external.source.clone(),
            external_id: external.external_id.clone(),
            url: external.url.clone(),
            name: name.to_string(),
            ..Default::default()
        };
        self.save(conn, &stub, "")
    }

    /// Delete a series row; its bookmarks and follows cascade via trigger
    /// (the dependent caches mirror that separately).
    pub(super) fn delete(&self, conn: &Connection, id: u64) -> Result<(), AppError> {
        conn.execute("DELETE FROM series WHERE id = ?1", params![id as i64])
            .map_err(map_sql)?;
        if let Some(s) = self.map.borrow_mut().remove(&id) {
            self.by_external.borrow_mut().remove(&(s.source.clone(), s.external_id.clone()));
        }
        Ok(())
    }
}
