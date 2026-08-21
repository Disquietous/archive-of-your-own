use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::CollectionSummary;

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
    pub summary: CollectionSummary,
    pub fetched_at: String,
    pub profile_fetched_at: String,
    pub tag_ids: Vec<i64>,
    pub work_ids: Vec<u64>,
    pub bookmark_work_ids: Vec<u64>,
}

/// The collections tables' in-memory mirror and single write authority
/// (collections + collection_tags/collection_works/collection_bookmarks) —
/// same contract as the other storage caches. Keyed by the URL slug.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct CollectionsCache {
    map: RefCell<HashMap<String, Arc<CollectionEntity>>>,
}

impl CollectionsCache {
    /// (Re)fill the map — four flat SELECTs, no joins.
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut entities: HashMap<String, CollectionEntity> = HashMap::new();
        {
            let mut stmt = conn
                .prepare(
                    "SELECT name, title, summary, is_open, is_moderated, is_anonymous,
                            work_count, bookmarked_count, maintainers_json, collection_type,
                            fetched_at, profile_fetched_at
                     FROM collections",
                )
                .map_err(map_sql)?;
            let rows = stmt
                .query_map([], |row| {
                    let maintainers_json: String = row.get(8)?;
                    Ok(CollectionEntity {
                        summary: CollectionSummary {
                            name: row.get(0)?,
                            title: row.get(1)?,
                            summary: row.get(2)?,
                            is_open: row.get::<_, i64>(3)? != 0,
                            is_moderated: row.get::<_, i64>(4)? != 0,
                            is_anonymous: row.get::<_, i64>(5)? != 0,
                            work_count: row.get(6)?,
                            bookmarked_count: row.get(7)?,
                            maintainers: serde_json::from_str(&maintainers_json)
                                .unwrap_or_default(),
                            tags: Vec::new(),
                            collection_type: row.get(9)?,
                        },
                        fetched_at: row.get(10)?,
                        profile_fetched_at: row.get(11)?,
                        tag_ids: Vec::new(),
                        work_ids: Vec::new(),
                        bookmark_work_ids: Vec::new(),
                    })
                })
                .map_err(map_sql)?;
            for row in rows {
                let e = row.map_err(map_sql)?;
                entities.insert(e.summary.name.clone(), e);
            }
        }
        for (sql, pick) in [
            ("SELECT collection_name, tag_id FROM collection_tags
              ORDER BY collection_name, position",
             0usize),
            ("SELECT collection_name, work_id FROM collection_works ORDER BY rowid", 1),
            ("SELECT collection_name, work_id FROM collection_bookmarks ORDER BY rowid", 2),
        ] {
            let mut stmt = conn.prepare(sql).map_err(map_sql)?;
            let rows = stmt
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
                .map_err(map_sql)?;
            for row in rows {
                let (name, id) = row.map_err(map_sql)?;
                if let Some(e) = entities.get_mut(&name) {
                    match pick {
                        0 => e.tag_ids.push(id),
                        1 => e.work_ids.push(id as u64),
                        _ => e.bookmark_work_ids.push(id as u64),
                    }
                }
            }
        }
        let mut map = self.map.borrow_mut();
        map.clear();
        for (name, e) in entities {
            map.insert(name, Arc::new(e));
        }
        Ok(())
    }

    pub(super) fn get(&self, name: &str) -> Option<Arc<CollectionEntity>> {
        self.map.borrow().get(name).cloned()
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

    fn update_entity(&self, name: &str, mutate: impl FnOnce(&mut CollectionEntity)) {
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(name) {
            let mut e = (**existing).clone();
            mutate(&mut e);
            map.insert(name.to_string(), Arc::new(e));
        }
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert one collection blurb (index page or merged profile metadata).
    /// The join-table links and profile stamp survive — only the metadata
    /// row refreshes.
    pub(super) fn upsert_blurb(&self, conn: &Connection, c: &CollectionSummary, now: &str)
        -> Result<(), AppError>
    {
        let maintainers = serde_json::to_string(&c.maintainers)
            .unwrap_or_else(|_| "[]".to_string());
        conn.prepare_cached(
                "INSERT INTO collections (name, title, summary, is_open, is_moderated,
                                          is_anonymous, work_count, bookmarked_count,
                                          maintainers_json, collection_type, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(name) DO UPDATE SET
                     title = excluded.title, summary = excluded.summary,
                     is_open = excluded.is_open, is_moderated = excluded.is_moderated,
                     is_anonymous = excluded.is_anonymous, work_count = excluded.work_count,
                     bookmarked_count = excluded.bookmarked_count,
                     maintainers_json = excluded.maintainers_json,
                     collection_type = excluded.collection_type,
                     fetched_at = excluded.fetched_at")
            .map_err(map_sql)?
            .execute(params![
                c.name, c.title, c.summary, c.is_open as i64, c.is_moderated as i64,
                c.is_anonymous as i64, c.work_count, c.bookmarked_count,
                maintainers, c.collection_type, now,
            ])
            .map_err(map_sql)?;
        let mut summary = c.clone();
        summary.tags = Vec::new();
        let mut map = self.map.borrow_mut();
        let old = map.get(&c.name).cloned();
        map.insert(c.name.clone(), Arc::new(CollectionEntity {
            summary,
            fetched_at: now.to_string(),
            profile_fetched_at: old.as_ref().map(|o| o.profile_fetched_at.clone()).unwrap_or_default(),
            tag_ids: old.as_ref().map(|o| o.tag_ids.clone()).unwrap_or_default(),
            work_ids: old.as_ref().map(|o| o.work_ids.clone()).unwrap_or_default(),
            bookmark_work_ids: old.as_ref().map(|o| o.bookmark_work_ids.clone()).unwrap_or_default(),
        }));
        Ok(())
    }

    /// Stamp that the collection's /profile page has been cached — the
    /// cache-forever guard for profile fetches. Returns how many rows were
    /// stamped (0 = no collection row to stamp).
    pub(super) fn stamp_profile_fetched(&self, conn: &Connection, name: &str, now: &str)
        -> Result<usize, AppError>
    {
        let stamped = conn
            .execute("UPDATE collections SET profile_fetched_at = ?2 WHERE name = ?1",
                     params![name, now])
            .map_err(map_sql)?;
        self.update_entity(name, |e| e.profile_fetched_at = now.to_string());
        Ok(stamped)
    }

    /// Rewrite a collection's tag links in page order, resolving names
    /// through the tag cache. Returns (removed, inserted) for the callers'
    /// diagnostics; duplicates collapse like the table's INSERT OR IGNORE.
    pub(super) fn replace_tags(&self, conn: &Connection, tags: &TagCache, name: &str,
                               tag_names: &[String]) -> Result<(usize, usize), AppError> {
        let removed = conn
            .execute("DELETE FROM collection_tags WHERE collection_name = ?1", params![name])
            .map_err(map_sql)?;
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_tags
                             (collection_name, tag_id, position) VALUES (?1, ?2, ?3)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut tag_ids: Vec<i64> = Vec::new();
        for (position, tag) in tag_names.iter().enumerate() {
            // Profile pages don't state tag types — "" until a work
            // listing teaches us.
            let tag_id = tags.resolve(conn, tag, "")?.id;
            inserted += stmt.execute(params![name, tag_id, position as i64]).map_err(map_sql)?;
            if !tag_ids.contains(&tag_id) {
                tag_ids.push(tag_id);
            }
        }
        self.update_entity(name, |e| e.tag_ids = tag_ids);
        Ok((removed, inserted))
    }

    /// Make sure a collection row exists for join links — a listing can be
    /// fetched for a collection whose blurb was never cached (deep link).
    /// Returns true when a stub row was created.
    pub(super) fn ensure_stub(&self, conn: &Connection, name: &str) -> Result<bool, AppError> {
        let created = conn
            .execute("INSERT OR IGNORE INTO collections (name, title) VALUES (?1, ?1)",
                     params![name])
            .map_err(map_sql)?;
        if created > 0 {
            self.map.borrow_mut().insert(name.to_string(), Arc::new(CollectionEntity {
                summary: CollectionSummary {
                    name: name.to_string(),
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
                bookmark_work_ids: Vec::new(),
            }));
        }
        Ok(created > 0)
    }

    /// Record works seen in a collection's listing (accumulates across
    /// pages). Returns how many links were new.
    pub(super) fn add_works(&self, conn: &Connection, name: &str, work_ids: &[u64])
        -> Result<usize, AppError>
    {
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_works
                             (collection_name, work_id) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut new_ids: Vec<u64> = Vec::new();
        for id in work_ids {
            if stmt.execute(params![name, *id as i64]).map_err(map_sql)? > 0 {
                inserted += 1;
                new_ids.push(*id);
            }
        }
        self.update_entity(name, |e| e.work_ids.extend(new_ids));
        Ok(inserted)
    }

    /// Record works seen in a collection's /bookmarks listing (accumulates
    /// across pages). Returns how many links were new.
    pub(super) fn add_bookmarks(&self, conn: &Connection, name: &str, work_ids: &[u64])
        -> Result<usize, AppError>
    {
        let mut stmt = conn
            .prepare_cached("INSERT OR IGNORE INTO collection_bookmarks
                             (collection_name, work_id) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        let mut inserted = 0;
        let mut new_ids: Vec<u64> = Vec::new();
        for id in work_ids {
            if stmt.execute(params![name, *id as i64]).map_err(map_sql)? > 0 {
                inserted += 1;
                new_ids.push(*id);
            }
        }
        self.update_entity(name, |e| e.bookmark_work_ids.extend(new_ids));
        Ok(inserted)
    }

    /// Mirror the works table's ON DELETE CASCADE: a deleted work's join
    /// rows are gone, so its id leaves every collection's lists. (The
    /// database rows were removed by the cascade — no SQL here.)
    pub(super) fn purge_work(&self, work_id: u64) {
        let names: Vec<String> = self
            .map
            .borrow()
            .iter()
            .filter(|(_, e)| {
                e.work_ids.contains(&work_id) || e.bookmark_work_ids.contains(&work_id)
            })
            .map(|(name, _)| name.clone())
            .collect();
        for name in names {
            self.update_entity(&name, |e| {
                e.work_ids.retain(|id| *id != work_id);
                e.bookmark_work_ids.retain(|id| *id != work_id);
            });
        }
    }
}
