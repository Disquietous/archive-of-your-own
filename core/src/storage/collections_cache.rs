use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{CollectionSummary, SOURCE_AO3};

use super::map_sql;
use super::tag_cache::TagCache;

/// One cached collection, in parsed form.
///
/// `summary` carries the blurb/profile metadata; its `tags` vector is
/// ALWAYS empty here — `hydrate` fills it from `tag_ids` via the tag cache.
/// The id lists mirror the collection_tags / collection_works /
/// collection_bookmarks join tables in their stored order.
#[derive(Clone, Debug)]
pub(super) struct CollectionEntity {
    /// Row id (`collections.id`).
    pub id: i64,
    pub summary: CollectionSummary,
    pub fetched_at: String,
    pub profile_fetched_at: String,
    pub tag_ids: Vec<i64>,
    pub work_ids: Vec<u64>,
    /// Row ids in `ao3_bookmarks` seen in the collection's /bookmarks listing.
    pub bookmark_ids: Vec<i64>,
}

/// The collections tables' in-memory mirror and single write authority
/// (collections + collection_tags/collection_works/collection_bookmarks) —
/// same contract as the other storage caches. Keyed by row id, with the
/// (source, slug) index alongside; the public API addresses collections by
/// slug, so every method here takes the slug and resolves it.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct CollectionsCache {
    map: RefCell<HashMap<i64, Arc<CollectionEntity>>>,
    by_external: RefCell<HashMap<(String, String), i64>>,
}

impl CollectionsCache {
    /// (Re)fill the map — four flat SELECTs, no joins.
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut entities: HashMap<i64, CollectionEntity> = HashMap::new();
        {
            let mut stmt = conn
                .prepare(
                    "SELECT id, source, external_id, url, title, summary, is_open, is_moderated,
                            is_anonymous, work_count, bookmarked_count, maintainers_json,
                            collection_type, fetched_at, profile_fetched_at
                     FROM collections",
                )
                .map_err(map_sql)?;
            let rows = stmt
                .query_map([], |row| {
                    let maintainers_json: String = row.get(11)?;
                    Ok(CollectionEntity {
                        id: row.get(0)?,
                        summary: CollectionSummary {
                            source: row.get(1)?,
                            name: row.get(2)?,
                            url: row.get(3)?,
                            title: row.get(4)?,
                            summary: row.get(5)?,
                            is_open: row.get::<_, i64>(6)? != 0,
                            is_moderated: row.get::<_, i64>(7)? != 0,
                            is_anonymous: row.get::<_, i64>(8)? != 0,
                            work_count: row.get(9)?,
                            bookmarked_count: row.get(10)?,
                            maintainers: serde_json::from_str(&maintainers_json)
                                .unwrap_or_default(),
                            tags: Vec::new(),
                            collection_type: row.get(12)?,
                        },
                        fetched_at: row.get(13)?,
                        profile_fetched_at: row.get(14)?,
                        tag_ids: Vec::new(),
                        work_ids: Vec::new(),
                        bookmark_ids: Vec::new(),
                    })
                })
                .map_err(map_sql)?;
            for row in rows {
                let e = row.map_err(map_sql)?;
                entities.insert(e.id, e);
            }
        }
        for (sql, pick) in [
            ("SELECT collection_id, tag_id FROM collection_tags
              ORDER BY collection_id, position",
             0usize),
            ("SELECT collection_id, work_id FROM collection_works ORDER BY rowid", 1),
            ("SELECT collection_id, bookmark_id FROM collection_bookmarks ORDER BY rowid", 2),
        ] {
            let mut stmt = conn.prepare(sql).map_err(map_sql)?;
            let rows = stmt
                .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
                .map_err(map_sql)?;
            for row in rows {
                let (cid, id) = row.map_err(map_sql)?;
                if let Some(e) = entities.get_mut(&cid) {
                    match pick {
                        0 => e.tag_ids.push(id),
                        1 => e.work_ids.push(id as u64),
                        _ => e.bookmark_ids.push(id),
                    }
                }
            }
        }
        let mut map = self.map.borrow_mut();
        let mut by_external = self.by_external.borrow_mut();
        map.clear();
        by_external.clear();
        for (id, e) in entities {
            by_external.insert((e.summary.source.clone(), e.summary.name.clone()), id);
            map.insert(id, Arc::new(e));
        }
        Ok(())
    }

    /// Row id for a slug (AO3 source — the only one with collections).
    pub(super) fn id_of(&self, name: &str) -> Option<i64> {
        self.by_external.borrow().get(&(SOURCE_AO3.to_string(), name.to_string())).copied()
    }

    pub(super) fn get(&self, name: &str) -> Option<Arc<CollectionEntity>> {
        self.id_of(name).and_then(|id| self.map.borrow().get(&id).cloned())
    }

    /// A snapshot of every entity (unordered).
    pub(super) fn all(&self) -> Vec<Arc<CollectionEntity>> {
        self.map.borrow().values().cloned().collect()
    }

    /// The entity as a `CollectionSummary` with tag names filled from the
    /// tag cache.
    pub(super) fn hydrate(&self, entity: &CollectionEntity, tags: &TagCache) -> CollectionSummary {
        let mut summary = entity.summary.clone();
        summary.tags = entity.tag_ids.iter()
            .filter_map(|id| tags.get(*id))
            .map(|t| t.name.to_string())
            .collect();
        summary
    }

    fn update_entity(&self, id: i64, mutate: impl FnOnce(&mut CollectionEntity)) {
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(&id) {
            let mut e = (**existing).clone();
            mutate(&mut e);
            map.insert(id, Arc::new(e));
        }
    }

    fn insert(&self, e: CollectionEntity) {
        self.by_external.borrow_mut().insert((e.summary.source.clone(), e.summary.name.clone()), e.id);
        self.map.borrow_mut().insert(e.id, Arc::new(e));
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert one collection blurb (index page or merged profile metadata)
    /// by (source, slug). The join-table links and profile stamp survive —
    /// only the metadata row refreshes. Returns the row id.
    pub(super) fn upsert_blurb(&self, conn: &Connection, c: &CollectionSummary, now: &str)
        -> Result<i64, AppError>
    {
        let maintainers = serde_json::to_string(&c.maintainers)
            .unwrap_or_else(|_| "[]".to_string());
        let existing = self.get(&c.name);
        conn.prepare_cached(
                "INSERT INTO collections (source, external_id, url, title, summary, is_open,
                                          is_moderated, is_anonymous, work_count, bookmarked_count,
                                          maintainers_json, collection_type, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(source, external_id) DO UPDATE SET
                     url = excluded.url, title = excluded.title, summary = excluded.summary,
                     is_open = excluded.is_open, is_moderated = excluded.is_moderated,
                     is_anonymous = excluded.is_anonymous, work_count = excluded.work_count,
                     bookmarked_count = excluded.bookmarked_count,
                     maintainers_json = excluded.maintainers_json,
                     collection_type = excluded.collection_type,
                     fetched_at = excluded.fetched_at")
            .map_err(map_sql)?
            .execute(params![
                c.source, c.name, c.url, c.title, c.summary, c.is_open as i64, c.is_moderated as i64,
                c.is_anonymous as i64, c.work_count, c.bookmarked_count,
                maintainers, c.collection_type, now,
            ])
            .map_err(map_sql)?;
        let id = existing.as_ref().map(|e| e.id).unwrap_or_else(|| conn.last_insert_rowid());
        let mut summary = c.clone();
        summary.tags = Vec::new();
        self.insert(CollectionEntity {
            id,
            summary,
            fetched_at: now.to_string(),
            profile_fetched_at: existing.as_ref().map(|o| o.profile_fetched_at.clone()).unwrap_or_default(),
            tag_ids: existing.as_ref().map(|o| o.tag_ids.clone()).unwrap_or_default(),
            work_ids: existing.as_ref().map(|o| o.work_ids.clone()).unwrap_or_default(),
            bookmark_ids: existing.as_ref().map(|o| o.bookmark_ids.clone()).unwrap_or_default(),
        });
        Ok(id)
    }

    /// Stamp that the collection's /profile page has been cached — the
    /// cache-forever guard for profile fetches. Returns how many rows were
    /// stamped (0 = no collection row to stamp).
    pub(super) fn stamp_profile_fetched(&self, conn: &Connection, name: &str, now: &str)
        -> Result<usize, AppError>
    {
        let Some(id) = self.id_of(name) else { return Ok(0) };
        let stamped = conn
            .execute("UPDATE collections SET profile_fetched_at = ?2 WHERE id = ?1",
                     params![id, now])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.profile_fetched_at = now.to_string());
        Ok(stamped)
    }

    /// Rewrite a collection's tag links in page order, resolving names
    /// through the tag cache. Returns (removed, inserted) for the callers'
    /// diagnostics; duplicates collapse like the table's INSERT OR IGNORE.
    pub(super) fn replace_tags(&self, conn: &Connection, tags: &TagCache, name: &str,
                               tag_names: &[String]) -> Result<(usize, usize), AppError> {
        let Some(id) = self.id_of(name) else { return Ok((0, 0)) };
        let removed = conn
            .execute("DELETE FROM collection_tags WHERE collection_id = ?1", params![id])
            .map_err(map_sql)?;
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_tags
                             (collection_id, tag_id, position) VALUES (?1, ?2, ?3)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut tag_ids: Vec<i64> = Vec::new();
        for (position, tag) in tag_names.iter().enumerate() {
            // Profile pages don't state tag types — "" until a work
            // listing teaches us.
            let tag_id = tags.resolve(conn, tag, "")?.id;
            inserted += stmt.execute(params![id, tag_id, position as i64]).map_err(map_sql)?;
            if !tag_ids.contains(&tag_id) {
                tag_ids.push(tag_id);
            }
        }
        self.update_entity(id, |e| e.tag_ids = tag_ids);
        Ok((removed, inserted))
    }

    /// Make sure a collection row exists for join links — a listing can be
    /// fetched for a collection whose blurb was never cached (deep link).
    /// Returns true when a stub row was created.
    pub(super) fn ensure_stub(&self, conn: &Connection, name: &str) -> Result<bool, AppError> {
        if self.id_of(name).is_some() {
            return Ok(false);
        }
        let url = crate::parser::ao3_collection_url(name);
        conn.execute("INSERT INTO collections (source, external_id, url, title) VALUES (?1, ?2, ?3, ?2)",
                     params![SOURCE_AO3, name, url])
            .map_err(map_sql)?;
        let id = conn.last_insert_rowid();
        self.insert(CollectionEntity {
            id,
            summary: CollectionSummary {
                source: SOURCE_AO3.to_string(),
                name: name.to_string(),
                url,
                title: name.to_string(),
                summary: String::new(),
                is_open: false,
                is_moderated: false,
                is_anonymous: false,
                work_count: 0,
                bookmarked_count: 0,
                maintainers: Vec::new(),
                tags: Vec::new(),
                collection_type: String::new(),
            },
            fetched_at: String::new(),
            profile_fetched_at: String::new(),
            tag_ids: Vec::new(),
            work_ids: Vec::new(),
            bookmark_ids: Vec::new(),
        });
        Ok(true)
    }

    /// Record works seen in a collection's listing (accumulates across
    /// pages). Returns how many links were new.
    pub(super) fn add_works(&self, conn: &Connection, name: &str, work_ids: &[u64])
        -> Result<usize, AppError>
    {
        let Some(id) = self.id_of(name) else { return Ok(0) };
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_works
                             (collection_id, work_id) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut new_ids: Vec<u64> = Vec::new();
        for wid in work_ids {
            if stmt.execute(params![id, *wid as i64]).map_err(map_sql)? > 0 {
                inserted += 1;
                new_ids.push(*wid);
            }
        }
        self.update_entity(id, |e| e.work_ids.extend(new_ids));
        Ok(inserted)
    }

    /// Record bookmarks seen in a collection's /bookmarks listing
    /// (accumulates across pages). Returns how many links were new.
    pub(super) fn add_bookmarks(&self, conn: &Connection, name: &str, bookmark_ids: &[i64])
        -> Result<usize, AppError>
    {
        let Some(id) = self.id_of(name) else { return Ok(0) };
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_bookmarks
                             (collection_id, bookmark_id) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut new_ids: Vec<i64> = Vec::new();
        for bid in bookmark_ids {
            if stmt.execute(params![id, *bid]).map_err(map_sql)? > 0 {
                inserted += 1;
                new_ids.push(*bid);
            }
        }
        self.update_entity(id, |e| e.bookmark_ids.extend(new_ids));
        Ok(inserted)
    }

    /// Mirror collection_bookmarks' ON DELETE CASCADE from ao3_bookmarks:
    /// the bookmark rows are gone, so their links left every collection.
    /// (No SQL — the cascade already ran.)
    pub(super) fn purge_bookmarks(&self, bookmark_ids: &[i64]) {
        if bookmark_ids.is_empty() { return; }
        let ids: Vec<i64> = self
            .map
            .borrow()
            .iter()
            .filter(|(_, e)| e.bookmark_ids.iter().any(|id| bookmark_ids.contains(id)))
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            self.update_entity(id, |e| e.bookmark_ids.retain(|id| !bookmark_ids.contains(id)));
        }
    }

    /// Mirror the works table's ON DELETE CASCADE: a deleted work's
    /// collection_works rows are gone, so its id leaves every collection's
    /// works list. (The database rows were removed by the cascade — no SQL
    /// here.) Its bookmarks' links go through `purge_bookmarks`.
    pub(super) fn purge_work(&self, work_id: u64) {
        let ids: Vec<i64> = self
            .map
            .borrow()
            .iter()
            .filter(|(_, e)| e.work_ids.contains(&work_id))
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            self.update_entity(id, |e| e.work_ids.retain(|id| *id != work_id));
        }
    }
}
