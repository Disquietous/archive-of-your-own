use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::BookmarkTarget;

use super::map_sql;

/// One cached row of the bookmarks table — one AO3 bookmark: an account's
/// bookmark of a work or a series. Rows are account-scoped: the active
/// account (or the logged-out sentinel) sees exactly its own.
#[derive(Clone, Debug)]
pub(super) struct BookmarkEntity {
    /// Surrogate row id (`bookmarks.id`).
    pub id: i64,
    pub account_id: String,
    pub target: BookmarkTarget,
    pub note: String,
    pub sync_to_ao3: bool,
    pub created_at: String,
    pub ao3_bookmark_id: Option<u64>,
    pub tag_string: String,
    pub collection_names: String,
    pub private: bool,
    pub rec: bool,
}

/// The bookmarks table's in-memory mirror and single write authority —
/// same contract as the other storage caches. Primary key is the row id;
/// `(account_id, target)` is unique and indexed for the account-scoped
/// lookups every caller makes.
///
/// Referential integrity lives in the database: a target-exists trigger
/// rejects a bookmark of an uncached work/series, and delete triggers on
/// works/series cascade their bookmarks (the cache mirrors those via
/// `purge_target`).
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct BookmarksCache {
    map: RefCell<HashMap<i64, Arc<BookmarkEntity>>>,
    by_target: RefCell<HashMap<(String, BookmarkTarget), i64>>,
}

impl BookmarksCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT id, account_id, bookmark_type, target_id, note, sync_to_ao3, created_at,
                        ao3_bookmark_id, tag_string, collection_names, private, rec
                 FROM bookmarks",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                let kind: String = r.get(2)?;
                let target_id = r.get::<_, i64>(3)? as u64;
                Ok((kind, target_id, BookmarkEntity {
                    id: r.get(0)?,
                    account_id: r.get(1)?,
                    target: BookmarkTarget::Work(0), // replaced below
                    note: r.get(4)?,
                    sync_to_ao3: r.get::<_, i64>(5)? != 0,
                    created_at: r.get(6)?,
                    ao3_bookmark_id: r.get::<_, Option<i64>>(7)?.map(|v| v as u64),
                    tag_string: r.get(8)?,
                    collection_names: r.get(9)?,
                    private: r.get::<_, i64>(10)? != 0,
                    rec: r.get::<_, i64>(11)? != 0,
                }))
            })
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        let mut by_target = self.by_target.borrow_mut();
        map.clear();
        by_target.clear();
        for row in rows {
            let (kind, target_id, mut e) = row.map_err(map_sql)?;
            // The CHECK constraint guarantees a known kind.
            let Some(target) = BookmarkTarget::from_parts(&kind, target_id) else { continue };
            e.target = target;
            by_target.insert((e.account_id.clone(), target), e.id);
            map.insert(e.id, Arc::new(e));
        }
        Ok(())
    }

    fn insert_entity(&self, e: BookmarkEntity) {
        self.by_target.borrow_mut().insert((e.account_id.clone(), e.target), e.id);
        self.map.borrow_mut().insert(e.id, Arc::new(e));
    }

    pub(super) fn id_of(&self, account_id: &str, target: BookmarkTarget) -> Option<i64> {
        self.by_target.borrow().get(&(account_id.to_string(), target)).copied()
    }

    pub(super) fn get_by_id(&self, id: i64) -> Option<Arc<BookmarkEntity>> {
        self.map.borrow().get(&id).cloned()
    }

    pub(super) fn get(&self, account_id: &str, target: BookmarkTarget) -> Option<Arc<BookmarkEntity>> {
        self.id_of(account_id, target).and_then(|id| self.get_by_id(id))
    }

    /// A snapshot of every entity (unordered).
    pub(super) fn all(&self) -> Vec<Arc<BookmarkEntity>> {
        self.map.borrow().values().cloned().collect()
    }

    /// One account's bookmarks, newest first (created_at descending, row
    /// id as a deterministic tiebreak).
    pub(super) fn for_account(&self, account_id: &str) -> Vec<Arc<BookmarkEntity>> {
        let mut rows: Vec<Arc<BookmarkEntity>> = self
            .map
            .borrow()
            .values()
            .filter(|e| e.account_id == account_id)
            .cloned()
            .collect();
        rows.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));
        rows
    }

    fn update_entity(&self, id: i64, mutate: impl FnOnce(&mut BookmarkEntity)) {
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(&id) {
            let mut e = (**existing).clone();
            mutate(&mut e);
            map.insert(id, Arc::new(e));
        }
    }

    fn row_id(conn: &Connection, account_id: &str, target: BookmarkTarget) -> Result<i64, AppError> {
        conn.query_row(
                "SELECT id FROM bookmarks
                 WHERE account_id = ?1 AND bookmark_type = ?2 AND target_id = ?3",
                params![account_id, target.kind(), target.id() as i64],
                |r| r.get(0),
            )
            .map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Create (or fully reset) a bookmark — the local "bookmark this"
    /// action. Reset semantics on purpose: any previous row's details go
    /// back to their defaults along with the timestamp. The row id is
    /// preserved (upsert, never REPLACE — collection links reference it).
    pub(super) fn add(&self, conn: &Connection, account_id: &str, target: BookmarkTarget,
                      note: &str, sync_to_ao3: bool, now: &str)
        -> Result<i64, AppError>
    {
        conn.execute(
                "INSERT INTO bookmarks
                     (account_id, bookmark_type, target_id, note, sync_to_ao3, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(account_id, bookmark_type, target_id) DO UPDATE SET
                     note = ?4, sync_to_ao3 = ?5, created_at = ?6,
                     tag_string = '', collection_names = '', private = 1, rec = 0,
                     ao3_bookmark_id = NULL",
                params![account_id, target.kind(), target.id() as i64, note,
                        sync_to_ao3 as i32, now],
            )
            .map_err(map_sql)?;
        let id = Self::row_id(conn, account_id, target)?;
        self.insert_entity(BookmarkEntity {
            id,
            account_id: account_id.to_string(),
            target,
            note: note.to_string(),
            sync_to_ao3,
            created_at: now.to_string(),
            ao3_bookmark_id: None,
            tag_string: String::new(),
            collection_names: String::new(),
            private: true, // column default
            rec: false,
        });
        Ok(id)
    }

    /// Cache a bookmark seen in a fetched listing. An existing row only
    /// refreshes its AO3 id — locally edited details stay put; a new row
    /// records what the listing showed (public by construction). Returns
    /// the row id.
    pub(super) fn cache_fetched(&self, conn: &Connection, account_id: &str,
                                target: BookmarkTarget, ao3_bookmark_id: u64, note: &str,
                                tag_string: &str, rec: bool, now: &str)
        -> Result<i64, AppError>
    {
        if let Some(id) = self.id_of(account_id, target) {
            self.set_ao3_id(conn, id, ao3_bookmark_id)?;
            return Ok(id);
        }
        conn.execute(
                "INSERT INTO bookmarks
                     (account_id, bookmark_type, target_id, note, sync_to_ao3, ao3_bookmark_id,
                      private, tag_string, rec, created_at)
                 VALUES (?1, ?2, ?3, ?4, 1, ?5, 0, ?6, ?7, ?8)",
                params![account_id, target.kind(), target.id() as i64, note,
                        ao3_bookmark_id as i64, tag_string, rec as i32, now],
            )
            .map_err(map_sql)?;
        let id = conn.last_insert_rowid();
        self.insert_entity(BookmarkEntity {
            id,
            account_id: account_id.to_string(),
            target,
            note: note.to_string(),
            // The bookmark exists on AO3 by construction.
            sync_to_ao3: true,
            created_at: now.to_string(),
            ao3_bookmark_id: Some(ao3_bookmark_id),
            tag_string: tag_string.to_string(),
            collection_names: String::new(),
            private: false,
            rec,
        });
        Ok(id)
    }

    pub(super) fn update_note(&self, conn: &Connection, id: i64, note: &str)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE bookmarks SET note = ?2 WHERE id = ?1", params![id, note])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.note = note.to_string());
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn update_details(&self, conn: &Connection, id: i64,
                                 note: &str, tag_string: &str, collection_names: &str,
                                 private: bool, rec: bool) -> Result<(), AppError> {
        conn.execute(
                "UPDATE bookmarks SET note = ?2, tag_string = ?3, collection_names = ?4,
                                      private = ?5, rec = ?6
                 WHERE id = ?1",
                params![id, note, tag_string, collection_names, private as i32, rec as i32],
            )
            .map_err(map_sql)?;
        self.update_entity(id, |e| {
            e.note = note.to_string();
            e.tag_string = tag_string.to_string();
            e.collection_names = collection_names.to_string();
            e.private = private;
            e.rec = rec;
        });
        Ok(())
    }

    pub(super) fn update_sync(&self, conn: &Connection, id: i64, sync: bool)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE bookmarks SET sync_to_ao3 = ?2 WHERE id = ?1", params![id, sync as i32])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.sync_to_ao3 = sync);
        Ok(())
    }

    pub(super) fn set_ao3_id(&self, conn: &Connection, id: i64, ao3_id: u64)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE bookmarks SET ao3_bookmark_id = ?2 WHERE id = ?1",
                     params![id, ao3_id as i64])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.ao3_bookmark_id = Some(ao3_id));
        Ok(())
    }

    pub(super) fn remove(&self, conn: &Connection, id: i64) -> Result<(), AppError> {
        conn.execute("DELETE FROM bookmarks WHERE id = ?1", params![id]).map_err(map_sql)?;
        self.forget(id);
        Ok(())
    }

    fn forget(&self, id: i64) {
        if let Some(e) = self.map.borrow_mut().remove(&id) {
            self.by_target.borrow_mut().remove(&(e.account_id.clone(), e.target));
        }
    }

    /// Mirror the database's delete-cascade trigger: the target row is
    /// gone, so every account's bookmark of it left the table. (No SQL —
    /// the trigger already ran.) Returns the purged row ids so dependent
    /// caches (collection links) can drop them too.
    pub(super) fn purge_target(&self, target: BookmarkTarget) -> Vec<i64> {
        let ids: Vec<i64> = self.map.borrow().values()
            .filter(|e| e.target == target)
            .map(|e| e.id)
            .collect();
        for id in &ids {
            self.forget(*id);
        }
        ids
    }
}
