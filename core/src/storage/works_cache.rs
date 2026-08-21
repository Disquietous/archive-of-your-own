use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{SeriesMembership, WorkSummary};

use super::consts::*;
use super::tag_cache::TagCache;
use super::{map_json, map_sql, rating_to_str, Storage};

/// One tag on a work: the tag-cache id plus how this work uses it (which
/// blurb list it came from). Refs keep AO3's blurb order; names hydrate
/// from the tag cache by id.
#[derive(Clone, Debug)]
pub(super) struct WorkTagRef {
    pub tag_id: i64,
    pub tag_type: String,
}

/// One cached row of the works table, in parsed form.
///
/// `summary` carries every scalar column; its four tag-name vectors are
/// ALWAYS empty here — `WorksCache::hydrate` fills them from `tags` via the
/// tag cache. The remaining fields are the library-state columns that live
/// on the works row but outside `WorkSummary`.
#[derive(Clone, Debug)]
pub(super) struct WorkEntity {
    pub summary: WorkSummary,
    pub tags: Vec<WorkTagRef>,
    pub detail_viewed_at: String,
    pub last_read_dt: String,
    pub last_chapter_read: u32,
    pub last_chapter_read_pos: u32,
    pub gone_from_ao3: bool,
}

/// The works table's in-memory mirror and single write authority (the
/// `work_tags` and `work_authors` index tables ride along — they are
/// derived from the same save).
///
/// Every post-open INSERT/UPDATE/DELETE against those tables lives in this
/// module, and each one mutates the map and the database in the same call —
/// so the map can never drift from the table, and reads (single work, whole
/// library, membership scans) cost no SQL. SELECTs against the tables
/// remain fair game for set-selection queries (the compiled library search);
/// write-through is what keeps their results consistent with the map.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback, since a
///   rolled-back write would otherwise strand stale state in the map
#[derive(Default)]
pub(super) struct WorksCache {
    map: RefCell<HashMap<u64, Arc<WorkEntity>>>,
}

impl WorksCache {
    /// (Re)fill the map from the works and work_tags tables — two flat
    /// SELECTs, no join. Run once at open, after migrations, and again
    /// after a rollback that may have discarded state the map already
    /// recorded.
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut entities: HashMap<u64, WorkEntity> = HashMap::new();
        {
            let sql = format!(
                "SELECT {}, detail_viewed_at, last_read_dt, last_chapter_read,
                        last_chapter_read_pos, gone_from_ao3 FROM works",
                Storage::work_select("")
            );
            let mut stmt = conn.prepare(&sql).map_err(map_sql)?;
            let rows = stmt
                .query_map([], |row| {
                    let summary = Storage::work_from_row(row)?;
                    let detail_viewed_at: String = row.get(20)?;
                    let last_read_dt: String = row.get(21)?;
                    let last_chapter_read: i64 = row.get(22)?;
                    let last_chapter_read_pos: i64 = row.get(23)?;
                    let gone_from_ao3: i64 = row.get(24)?;
                    Ok(WorkEntity {
                        summary,
                        tags: Vec::new(),
                        detail_viewed_at,
                        last_read_dt,
                        last_chapter_read: last_chapter_read as u32,
                        last_chapter_read_pos: last_chapter_read_pos as u32,
                        gone_from_ao3: gone_from_ao3 != 0,
                    })
                })
                .map_err(map_sql)?;
            for row in rows {
                let entity = row.map_err(map_sql)?;
                entities.insert(entity.summary.id, entity);
            }
        }
        {
            let mut stmt = conn
                .prepare("SELECT work_id, tag_id, tag_type FROM work_tags
                          ORDER BY work_id, position")
                .map_err(map_sql)?;
            let rows = stmt
                .query_map([], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?))
                })
                .map_err(map_sql)?;
            for row in rows {
                let (work_id, tag_id, tag_type) = row.map_err(map_sql)?;
                if let Some(entity) = entities.get_mut(&(work_id as u64)) {
                    entity.tags.push(WorkTagRef { tag_id, tag_type });
                }
            }
        }
        let mut map = self.map.borrow_mut();
        map.clear();
        for (id, entity) in entities {
            map.insert(id, Arc::new(entity));
        }
        Ok(())
    }

    pub(super) fn get(&self, id: u64) -> Option<Arc<WorkEntity>> {
        self.map.borrow().get(&id).cloned()
    }

    /// A snapshot of every entity (unordered).
    pub(super) fn all(&self) -> Vec<Arc<WorkEntity>> {
        self.map.borrow().values().cloned().collect()
    }

    /// The entity as a `WorkSummary` with its tag-name vectors filled from
    /// the tag cache — the in-memory replacement for the works↔tags join.
    pub(super) fn hydrate(&self, entity: &WorkEntity, tags: &TagCache) -> WorkSummary {
        let mut summary = entity.summary.clone();
        for tag_ref in &entity.tags {
            let Some(tag) = tags.get(tag_ref.tag_id) else { continue };
            let name = tag.name.to_string();
            match tag_ref.tag_type.as_str() {
                TAG_TYPE_FANDOM => summary.fandoms.push(name),
                TAG_TYPE_CHARACTER => summary.characters.push(name),
                TAG_TYPE_RELATIONSHIP => summary.relationships.push(name),
                _ => summary.tags.push(name),
            }
        }
        summary
    }

    /// Clone-mutate-swap an existing entity. A no-op when the work isn't
    /// cached — mirroring the UPDATE statements this backs, which no-op on
    /// a missing row.
    fn update_entity(&self, id: u64, mutate: impl FnOnce(&mut WorkEntity)) {
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(&id) {
            let mut entity = (**existing).clone();
            mutate(&mut entity);
            map.insert(id, Arc::new(entity));
        }
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert a work summary plus its author- and tag-index rows.
    /// `fetched_at` is stamped by the caller so entity and row agree.
    /// Blurbs never carry series or library state, so those survive from
    /// the existing entity/row (upsert, NOT INSERT OR REPLACE — replace
    /// would re-create the row and wipe them).
    pub(super) fn save_work(&self, conn: &Connection, tags: &TagCache,
                            work: &WorkSummary, fetched_at: &str)
        -> Result<(), AppError>
    {
        conn.execute(
                "INSERT INTO works (
                    id, title, authors_json, rating,
                    warnings_json, categories_json, summary, word_count,
                    chapter_count, total_chapters, kudos, hits,
                    bookmarks, comments, date_published, date_updated, language, complete,
                    fetched_at, warnings_mask, categories_mask, fandom_count
                ) VALUES (
                    ?1, ?2, ?3, ?4,
                    ?5, ?6, ?7, ?8,
                    ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16, ?17, ?18,
                    ?19, ?20, ?21, ?22
                )
                ON CONFLICT(id) DO UPDATE SET
                    title = ?2, authors_json = ?3, rating = ?4,
                    warnings_json = ?5, categories_json = ?6, summary = ?7, word_count = ?8,
                    chapter_count = ?9, total_chapters = ?10, kudos = ?11, hits = ?12,
                    bookmarks = ?13, comments = ?14, date_published = ?15, date_updated = ?16,
                    language = ?17, complete = ?18, fetched_at = ?19,
                    warnings_mask = ?20, categories_mask = ?21, fandom_count = ?22",
                params![
                    work.id as i64,
                    work.title,
                    serde_json::to_string(&work.authors).map_err(map_json)?,
                    rating_to_str(&work.rating),
                    serde_json::to_string(&work.warnings).map_err(map_json)?,
                    serde_json::to_string(&work.categories).map_err(map_json)?,
                    work.summary,
                    work.word_count as i64,
                    work.chapter_count as i64,
                    work.total_chapters.map(|c| c as i64),
                    work.kudos as i64,
                    work.hits as i64,
                    work.bookmarks as i64,
                    work.comments as i64,
                    work.date_published,
                    work.date_updated,
                    work.language,
                    work.complete as i32,
                    fetched_at,
                    super::works_search::warnings_mask(&work.warnings),
                    super::works_search::categories_mask(&work.categories),
                    work.fandoms.len() as i64,
                ],
            )
            .map_err(map_sql)?;
        self.replace_work_authors(conn, work.id, &work.authors)?;
        let tag_refs = self.replace_work_tag_rows(conn, tags, work)?;

        let mut summary = work.clone();
        summary.fandoms.clear();
        summary.characters.clear();
        summary.relationships.clear();
        summary.tags.clear();
        summary.fetched_at = fetched_at.to_string();
        let mut map = self.map.borrow_mut();
        let old = map.get(&work.id).cloned();
        summary.series = old.as_ref()
            .map(|o| o.summary.series.clone())
            .unwrap_or_default();
        let entity = WorkEntity {
            summary,
            tags: tag_refs,
            detail_viewed_at: old.as_ref().map(|o| o.detail_viewed_at.clone()).unwrap_or_default(),
            last_read_dt: old.as_ref().map(|o| o.last_read_dt.clone()).unwrap_or_default(),
            last_chapter_read: old.as_ref().map(|o| o.last_chapter_read).unwrap_or(0),
            last_chapter_read_pos: old.as_ref().map(|o| o.last_chapter_read_pos).unwrap_or(0),
            gone_from_ao3: old.as_ref().map(|o| o.gone_from_ao3).unwrap_or(false),
        };
        map.insert(work.id, Arc::new(entity));
        Ok(())
    }

    /// Rewrite a work's tag join rows. `tag_type` records which blurb list
    /// each tag came from; `position` runs across the four lists in AO3's
    /// blurb order. Returns the refs for the entity — first sighting wins
    /// on a duplicate name, like the table's INSERT OR IGNORE.
    fn replace_work_tag_rows(&self, conn: &Connection, tags: &TagCache, work: &WorkSummary)
        -> Result<Vec<WorkTagRef>, AppError>
    {
        conn.execute("DELETE FROM work_tags WHERE work_id = ?1", params![work.id as i64])
            .map_err(map_sql)?;
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO work_tags (work_id, tag_id, tag_type, position)
                             VALUES (?1, ?2, ?3, ?4)")
            .map_err(map_sql)?;
        let mut refs = Vec::new();
        let mut seen = HashSet::new();
        let mut position = 0i64;
        for (list, tag_type) in [
            (&work.fandoms, TAG_TYPE_FANDOM),
            (&work.characters, TAG_TYPE_CHARACTER),
            (&work.relationships, TAG_TYPE_RELATIONSHIP),
            (&work.tags, TAG_TYPE_FREEFORM),
        ] {
            for name in list {
                let tag_id = tags.resolve(conn, name, tag_type)?.id;
                stmt.execute(params![work.id as i64, tag_id, tag_type, position])
                    .map_err(map_sql)?;
                position += 1;
                if seen.insert(tag_id) {
                    refs.push(WorkTagRef { tag_id, tag_type: tag_type.to_string() });
                }
            }
        }
        Ok(refs)
    }

    /// Rewrite the author-index rows for one work.
    fn replace_work_authors(&self, conn: &Connection, work_id: u64, authors: &[String])
        -> Result<(), AppError>
    {
        conn.execute("DELETE FROM work_authors WHERE work_id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO work_authors (work_id, author) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        for author in authors {
            stmt.execute(params![work_id as i64, author]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// Persist series memberships. The work page is authoritative, so an
    /// empty slice clears.
    pub(super) fn set_series(&self, conn: &Connection, work_id: u64,
                             series: &[SeriesMembership])
        -> Result<(), AppError>
    {
        conn.execute(
                "UPDATE works SET series_json = ?2 WHERE id = ?1",
                params![work_id as i64, serde_json::to_string(series).map_err(map_json)?],
            )
            .map_err(map_sql)?;
        self.update_entity(work_id, |e| e.summary.series = series.to_vec());
        Ok(())
    }

    /// First detail-view timestamp — first view wins, later opens keep the
    /// original. No-op when the work has no row.
    pub(super) fn mark_detail_viewed(&self, conn: &Connection, work_id: u64, at: &str)
        -> Result<(), AppError>
    {
        conn.execute(
                "UPDATE works SET detail_viewed_at = ?2
                 WHERE id = ?1 AND detail_viewed_at = ''",
                params![work_id as i64, at],
            )
            .map_err(map_sql)?;
        self.update_entity(work_id, |e| {
            if e.detail_viewed_at.is_empty() {
                e.detail_viewed_at = at.to_string();
            }
        });
        Ok(())
    }

    /// Stamp "the user just opened a chapter" — every open overwrites.
    pub(super) fn mark_read(&self, conn: &Connection, work_id: u64, at: &str)
        -> Result<(), AppError>
    {
        conn.execute(
                "UPDATE works SET last_read_dt = ?2 WHERE id = ?1",
                params![work_id as i64, at],
            )
            .map_err(map_sql)?;
        self.update_entity(work_id, |e| e.last_read_dt = at.to_string());
        Ok(())
    }

    pub(super) fn save_progress(&self, conn: &Connection, work_id: u64,
                                chapter: u32, position: u32)
        -> Result<(), AppError>
    {
        conn.execute(
                "UPDATE works SET last_chapter_read = ?2, last_chapter_read_pos = ?3
                 WHERE id = ?1",
                params![work_id as i64, chapter as i64, position as i64],
            )
            .map_err(map_sql)?;
        self.update_entity(work_id, |e| {
            e.last_chapter_read = chapter;
            e.last_chapter_read_pos = position;
        });
        Ok(())
    }

    pub(super) fn clear_progress(&self, conn: &Connection, work_id: u64) -> Result<(), AppError> {
        conn.execute(
                "UPDATE works SET last_chapter_read = 0, last_chapter_read_pos = 0
                 WHERE id = ?1",
                params![work_id as i64],
            )
            .map_err(map_sql)?;
        self.update_entity(work_id, |e| {
            e.last_chapter_read = 0;
            e.last_chapter_read_pos = 0;
        });
        Ok(())
    }

    /// Mark (or clear) works as no longer listed on AO3.
    pub(super) fn set_gone(&self, conn: &Connection, work_ids: &[u64], gone: bool)
        -> Result<(), AppError>
    {
        let mut stmt = conn
            .prepare_cached("UPDATE works SET gone_from_ao3 = ?2 WHERE id = ?1")
            .map_err(map_sql)?;
        for id in work_ids {
            stmt.execute(params![id, gone as i64]).map_err(map_sql)?;
            self.update_entity(*id, |e| e.gone_from_ao3 = gone);
        }
        Ok(())
    }

    /// Delete the works row (work_tags and collection rows cascade via
    /// their foreign keys; the entity's tag refs go with it).
    pub(super) fn delete(&self, conn: &Connection, work_id: u64) -> Result<(), AppError> {
        conn.execute("DELETE FROM works WHERE id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        self.map.borrow_mut().remove(&work_id);
        Ok(())
    }
}
