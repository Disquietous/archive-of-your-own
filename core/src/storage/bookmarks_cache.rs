use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;

use super::map_sql;

/// One cached row of the bookmarks table. Rows are account-scoped: the
/// active account (or the logged-out sentinel) sees exactly its own.
#[derive(Clone, Debug)]
pub(super) struct BookmarkEntity {
    pub account_id: String,
    pub work_id: u64,
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
/// same contract as the other storage caches. Keyed (account_id, work_id).
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct BookmarksCache {
    map: RefCell<HashMap<(String, u64), Arc<BookmarkEntity>>>,
}

impl BookmarksCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT account_id, work_id, note, sync_to_ao3, created_at,
                        ao3_bookmark_id, tag_string, collection_names, private, rec
                 FROM bookmarks",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(BookmarkEntity {
                    account_id: r.get(0)?,
                    work_id: r.get::<_, i64>(1)? as u64,
                    note: r.get(2)?,
                    sync_to_ao3: r.get::<_, i64>(3)? != 0,
                    created_at: r.get(4)?,
                    ao3_bookmark_id: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    tag_string: r.get(6)?,
                    collection_names: r.get(7)?,
                    private: r.get::<_, i64>(8)? != 0,
                    rec: r.get::<_, i64>(9)? != 0,
                })
            })
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        map.clear();
        for row in rows {
            let e = row.map_err(map_sql)?;
            map.insert((e.account_id.clone(), e.work_id), Arc::new(e));
        }
        Ok(())
    }

    pub(super) fn get(&self, account_id: &str, work_id: u64) -> Option<Arc<BookmarkEntity>> {
        self.map.borrow().get(&(account_id.to_string(), work_id)).cloned()
    }

    /// A snapshot of every entity (unordered).
    pub(super) fn all(&self) -> Vec<Arc<BookmarkEntity>> {
        self.map.borrow().values().cloned().collect()
    }

    /// One account's bookmarks, newest first (created_at descending, work
    /// id as a deterministic tiebreak).
    pub(super) fn for_account(&self, account_id: &str) -> Vec<Arc<BookmarkEntity>> {
        let mut rows: Vec<Arc<BookmarkEntity>> = self
            .map
            .borrow()
            .values()
            .filter(|e| e.account_id == account_id)
            .cloned()
            .collect();
        rows.sort_by(|a, b| {
            b.created_at.cmp(&a.created_at).then_with(|| a.work_id.cmp(&b.work_id))
        });
        rows
    }

    fn update_entity(&self, account_id: &str, work_id: u64,
                     mutate: impl FnOnce(&mut BookmarkEntity)) {
        let key = (account_id.to_string(), work_id);
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(&key) {
            let mut e = (**existing).clone();
            mutate(&mut e);
            map.insert(key, Arc::new(e));
        }
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Create (or fully reset) a bookmark — the local "bookmark this work"
    /// action. REPLACE semantics on purpose: any previous row's details are
    /// reset along with the timestamp.
    pub(super) fn add(&self, conn: &Connection, account_id: &str, work_id: u64,
                      note: &str, sync_to_ao3: bool, now: &str)
        -> Result<(), AppError>
    {
        conn.execute(
                "INSERT OR REPLACE INTO bookmarks
                     (account_id, work_id, note, sync_to_ao3, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![account_id, work_id as i64, note, sync_to_ao3 as i32, now],
            )
            .map_err(map_sql)?;
        self.map.borrow_mut().insert(
            (account_id.to_string(), work_id),
            Arc::new(BookmarkEntity {
                account_id: account_id.to_string(),
                work_id,
                note: note.to_string(),
                sync_to_ao3,
                created_at: now.to_string(),
                ao3_bookmark_id: None,
                tag_string: String::new(),
                collection_names: String::new(),
                private: true, // column default
                rec: false,
            }),
        );
        Ok(())
    }

    /// Cache a bookmark seen in a fetched listing. An existing row only
    /// refreshes its AO3 id — locally edited details stay put; a new row
    /// records what the listing showed (public by construction).
    pub(super) fn cache_fetched(&self, conn: &Connection, account_id: &str, work_id: u64,
                                ao3_bookmark_id: u64, note: &str, tag_string: &str,
                                rec: bool, now: &str)
        -> Result<(), AppError>
    {
        if self.get(account_id, work_id).is_some() {
            return self.set_ao3_id(conn, account_id, work_id, ao3_bookmark_id);
        }
        conn.execute(
                "INSERT INTO bookmarks
                     (account_id, work_id, note, sync_to_ao3, ao3_bookmark_id, private,
                      tag_string, rec, created_at)
                 VALUES (?1, ?2, ?3, 1, ?4, 0, ?5, ?6, ?7)",
                params![account_id, work_id as i64, note, ao3_bookmark_id as i64,
                        tag_string, rec as i32, now],
            )
            .map_err(map_sql)?;
        self.map.borrow_mut().insert(
            (account_id.to_string(), work_id),
            Arc::new(BookmarkEntity {
                account_id: account_id.to_string(),
                work_id,
                note: note.to_string(),
                // The bookmark exists on AO3 by construction.
                sync_to_ao3: true,
                created_at: now.to_string(),
                ao3_bookmark_id: Some(ao3_bookmark_id),
                tag_string: tag_string.to_string(),
                collection_names: String::new(),
                private: false,
                rec,
            }),
        );
        Ok(())
    }

    pub(super) fn update_note(&self, conn: &Connection, account_id: &str, work_id: u64,
                              note: &str) -> Result<(), AppError> {
        conn.execute(
                "UPDATE bookmarks SET note = ?3 WHERE account_id = ?1 AND work_id = ?2",
                params![account_id, work_id as i64, note],
            )
            .map_err(map_sql)?;
        self.update_entity(account_id, work_id, |e| e.note = note.to_string());
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn update_details(&self, conn: &Connection, account_id: &str, work_id: u64,
                                 note: &str, tag_string: &str, collection_names: &str,
                                 private: bool, rec: bool) -> Result<(), AppError> {
        conn.execute(
                "UPDATE bookmarks SET note = ?3, tag_string = ?4, collection_names = ?5,
                                      private = ?6, rec = ?7
                 WHERE account_id = ?1 AND work_id = ?2",
                params![account_id, work_id as i64, note, tag_string, collection_names,
                        private as i32, rec as i32],
            )
            .map_err(map_sql)?;
        self.update_entity(account_id, work_id, |e| {
            e.note = note.to_string();
            e.tag_string = tag_string.to_string();
            e.collection_names = collection_names.to_string();
            e.private = private;
            e.rec = rec;
        });
        Ok(())
    }

    pub(super) fn update_sync(&self, conn: &Connection, account_id: &str, work_id: u64,
                              sync: bool) -> Result<(), AppError> {
        conn.execute(
                "UPDATE bookmarks SET sync_to_ao3 = ?3 WHERE account_id = ?1 AND work_id = ?2",
                params![account_id, work_id as i64, sync as i32],
            )
            .map_err(map_sql)?;
        self.update_entity(account_id, work_id, |e| e.sync_to_ao3 = sync);
        Ok(())
    }

    pub(super) fn set_ao3_id(&self, conn: &Connection, account_id: &str, work_id: u64,
                             ao3_id: u64) -> Result<(), AppError> {
        conn.execute(
                "UPDATE bookmarks SET ao3_bookmark_id = ?3 WHERE account_id = ?1 AND work_id = ?2",
                params![account_id, work_id as i64, ao3_id as i64],
            )
            .map_err(map_sql)?;
        self.update_entity(account_id, work_id, |e| e.ao3_bookmark_id = Some(ao3_id));
        Ok(())
    }

    pub(super) fn remove(&self, conn: &Connection, account_id: &str, work_id: u64)
        -> Result<(), AppError>
    {
        conn.execute(
                "DELETE FROM bookmarks WHERE account_id = ?1 AND work_id = ?2",
                params![account_id, work_id as i64],
            )
            .map_err(map_sql)?;
        self.map.borrow_mut().remove(&(account_id.to_string(), work_id));
        Ok(())
    }

    /// Delete every account's bookmark of a work — the delete_work path.
    pub(super) fn remove_for_work(&self, conn: &Connection, work_id: u64)
        -> Result<(), AppError>
    {
        conn.execute("DELETE FROM bookmarks WHERE work_id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        self.map.borrow_mut().retain(|(_, wid), _| *wid != work_id);
        Ok(())
    }
}
