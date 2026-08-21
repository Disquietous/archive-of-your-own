use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;

use super::map_sql;

/// One cached row of the tags table. Tag identity is the name alone — AO3
/// tag names are globally unique across every tag type (hence the
/// "- Freeform" suffixes), so the same tag is one row wherever it appears:
/// on works, on collections, anywhere.
#[derive(Debug)]
pub(crate) struct TagEntity {
    pub id: i64,
    pub name: Arc<str>,
    /// "" = type not yet learned (e.g. first seen on a collection profile,
    /// which doesn't state types).
    pub tag_type: String,
    pub canonical: bool,
}

impl TagEntity {
    pub(super) fn type_known(&self) -> bool {
        !self.tag_type.is_empty()
    }
}

/// Two views of one entity set: every `TagEntity` lives in a single `Arc`
/// allocation, and both indexes hold pointer clones of it — the by-name
/// key is a clone of the entity's own `Arc<str>`, so even the name string
/// exists once. Ids and names are immutable, so the (rare) mutations —
/// '' learning a real type, canonical flips — swap a replacement entity
/// into both indexes without ever re-keying.
#[derive(Default)]
struct Indexes {
    by_id: HashMap<i64, Arc<TagEntity>>,
    by_name: HashMap<Arc<str>, Arc<TagEntity>>,
}

/// The tags table's in-memory mirror and single write authority.
///
/// Every post-open INSERT/UPDATE/DELETE against `tags` lives in this module,
/// and each one mutates the indexes and the database in the same call — so
/// the cache can never drift from the table, and any code holding a tag id
/// or name can retrieve the full entity without SQL.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback, since a
///   rolled-back INSERT would otherwise strand a dead id in the indexes
#[derive(Default)]
pub(super) struct TagCache {
    inner: RefCell<Indexes>,
}

impl TagCache {
    /// (Re)fill both indexes from the tags table — run once at open, after
    /// migrations, and again after a rollback that may have discarded rows
    /// the indexes already recorded.
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare("SELECT id, name, tag_type, canonical FROM tags")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?, r.get::<_, i64>(3)?))
            })
            .map_err(map_sql)?;
        let mut inner = self.inner.borrow_mut();
        inner.by_id.clear();
        inner.by_name.clear();
        for row in rows {
            let (id, name, tag_type, canonical) = row.map_err(map_sql)?;
            Self::index(&mut inner, TagEntity {
                id, name: Arc::from(name.as_str()), tag_type, canonical: canonical != 0,
            });
        }
        Ok(())
    }

    /// Insert (or replace) an entity in both indexes. The single mutation
    /// path — keeping it in one place is what guarantees the indexes always
    /// point at the same allocation.
    fn index(inner: &mut Indexes, entity: TagEntity) -> Arc<TagEntity> {
        let entity = Arc::new(entity);
        inner.by_id.insert(entity.id, Arc::clone(&entity));
        inner.by_name.insert(Arc::clone(&entity.name), Arc::clone(&entity));
        entity
    }

    pub(super) fn get(&self, id: i64) -> Option<Arc<TagEntity>> {
        self.inner.borrow().by_id.get(&id).cloned()
    }

    pub(super) fn get_by_name(&self, name: &str) -> Option<Arc<TagEntity>> {
        self.inner.borrow().by_name.get(name).cloned()
    }

    /// Whether a (name, tag_type) sighting still needs a database write:
    /// unknown names always do; known names only for the rare type upgrade
    /// ('' learning a real type). Lets batch paths skip the savepoint when
    /// nothing would write.
    pub(super) fn needs_write(&self, name: &str, tag_type: &str) -> bool {
        match self.get_by_name(name) {
            Some(e) => !e.type_known() && !tag_type.is_empty(),
            None => true,
        }
    }

    /// The entity for a name, inserting the tags row if new. `tag_type`
    /// fills in an existing row's type only when it hasn't been learned yet.
    /// Answered from the indexes: a known tag with a known type costs no SQL.
    pub(super) fn resolve(&self, conn: &Connection, name: &str, tag_type: &str)
        -> Result<Arc<TagEntity>, AppError>
    {
        let cached = self.inner.borrow().by_name.get(name).cloned();
        if let Some(e) = cached {
            if e.type_known() || tag_type.is_empty() {
                return Ok(e);
            }
            // Rare: an unknown-typed row (e.g. from a collection profile)
            // learning its real type from a work listing.
            conn.prepare_cached("UPDATE tags SET tag_type = ?2 WHERE id = ?1 AND tag_type = ''")
                .map_err(map_sql)?
                .execute(params![e.id, tag_type])
                .map_err(map_sql)?;
            let mut inner = self.inner.borrow_mut();
            return Ok(Self::index(&mut inner, TagEntity {
                id: e.id,
                name: Arc::clone(&e.name),
                tag_type: tag_type.to_string(),
                canonical: e.canonical,
            }));
        }
        conn.prepare_cached(
                "INSERT INTO tags (name, tag_type) VALUES (?1, ?2)
                 ON CONFLICT(name) DO UPDATE SET tag_type = excluded.tag_type
                     WHERE tags.tag_type = '' AND excluded.tag_type <> ''")
            .map_err(map_sql)?
            .execute(params![name, tag_type])
            .map_err(map_sql)?;
        self.cache_db_row(conn, name)
    }

    /// Record a name confirmed canonical by AO3's autocomplete, inserting
    /// the row if new. `learned_type` teaches the row's type when non-empty
    /// (the any-type "tag" endpoint passes "" and never touches one already
    /// learned).
    pub(super) fn mark_canonical(&self, conn: &Connection, name: &str, learned_type: &str)
        -> Result<(), AppError>
    {
        conn.prepare_cached(
                "INSERT INTO tags (name, tag_type, canonical) VALUES (?1, ?2, 1)
                 ON CONFLICT(name) DO UPDATE SET
                     canonical = 1,
                     last_seen = datetime('now'),
                     tag_type = CASE WHEN excluded.tag_type <> '' THEN excluded.tag_type
                                     ELSE tags.tag_type END")
            .map_err(map_sql)?
            .execute(params![name, learned_type])
            .map_err(map_sql)?;
        let cached = self.inner.borrow().by_name.get(name).cloned();
        match cached {
            Some(e) => {
                let tag_type = if e.type_known() || learned_type.is_empty() {
                    e.tag_type.clone()
                } else {
                    learned_type.to_string()
                };
                let mut inner = self.inner.borrow_mut();
                Self::index(&mut inner, TagEntity {
                    id: e.id, name: Arc::clone(&e.name), tag_type, canonical: true,
                });
            }
            None => {
                self.cache_db_row(conn, name)?;
            }
        }
        Ok(())
    }

    /// Read one row back from the table and index it — the write paths call
    /// this after inserting a name the indexes don't know, so the cached
    /// entity is exactly what the database resolved (id, final type,
    /// canonical state).
    fn cache_db_row(&self, conn: &Connection, name: &str) -> Result<Arc<TagEntity>, AppError> {
        let (id, tag_type, canonical): (i64, String, i64) = conn
            .prepare_cached("SELECT id, tag_type, canonical FROM tags WHERE name = ?1")
            .map_err(map_sql)?
            .query_row(params![name], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(map_sql)?;
        let mut inner = self.inner.borrow_mut();
        Ok(Self::index(&mut inner, TagEntity {
            id, name: Arc::from(name), tag_type, canonical: canonical != 0,
        }))
    }

    // -------------------------------------------------------------------
    // In-memory reads (replace SQL scans of the tags table)
    // -------------------------------------------------------------------

    /// Substring search over the entities — ASCII-case-insensitive, ordered
    /// by name NOCASE with a byte-order tiebreak, exactly the semantics of
    /// the `LIKE ... ORDER BY name COLLATE NOCASE` queries it replaces.
    /// `tag_type` of None searches every type. `limit` caps the result
    /// (usize::MAX = unlimited).
    pub(super) fn search(&self, tag_type: Option<&str>, term: &str, limit: usize)
        -> Vec<Arc<TagEntity>>
    {
        let needle = term.trim().to_ascii_lowercase();
        if needle.is_empty() {
            return Vec::new();
        }
        let inner = self.inner.borrow();
        let mut hits: Vec<Arc<TagEntity>> = inner
            .by_id
            .values()
            .filter(|e| tag_type.map_or(true, |t| e.tag_type == t))
            .filter(|e| e.name.to_ascii_lowercase().contains(&needle))
            .cloned()
            .collect();
        hits.sort_by(|a, b| {
            a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase())
                .then_with(|| a.name.cmp(&b.name))
        });
        hits.truncate(limit);
        hits
    }

    /// Ids of every tag whose name contains the (pre-lowered, Unicode)
    /// needle — the substring semantics of the search oracle's `any_ci`
    /// over tag names. Sorted so callers embed a deterministic id list.
    pub(super) fn ids_containing(&self, needle_lower: &str) -> Vec<i64> {
        let inner = self.inner.borrow();
        let mut ids: Vec<i64> = inner
            .by_id
            .values()
            .filter(|e| e.name.to_lowercase().contains(needle_lower))
            .map(|e| e.id)
            .collect();
        ids.sort_unstable();
        ids
    }
}
