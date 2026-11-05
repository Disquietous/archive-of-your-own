use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::BookmarkTarget;

use super::map_sql;

/// One row of `ao3_bookmarks` — an AO3 bookmark record: whose it is
/// (`owner`, the lowercased bookmarker username; "" when unknown), the
/// local account it belongs to when that user is signed in here, the
/// target, AO3's own id once it exists there, and the bookmark's fields.
/// Own rows made in the app but not yet pushed carry `ao3_bookmark_id`
/// None and `sync_to_ao3` as the push intent (Area 7.2).
#[derive(Clone, Debug)]
pub(super) struct Ao3BookmarkEntity {
    pub id: i64,
    pub account_id: Option<i64>,
    pub owner: String,
    pub target: BookmarkTarget,
    pub ao3_bookmark_id: Option<u64>,
    pub note: String,
    pub tag_string: String,
    pub collection_names: String,
    pub private: bool,
    pub rec: bool,
    pub sync_to_ao3: bool,
    pub created_at: String,
}

/// The ao3_bookmarks table's in-memory mirror and single write authority
/// — same contract as the other storage caches. Primary key is the row
/// id; `(owner, target)` is unique and indexed for the owner-scoped
/// lookups every caller makes.
#[derive(Default)]
pub(super) struct Ao3BookmarksCache {
    map: RefCell<HashMap<i64, Arc<Ao3BookmarkEntity>>>,
    by_target: RefCell<HashMap<(String, BookmarkTarget), i64>>,
}

impl Ao3BookmarksCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT id, account_id, owner, kind, target_id, ao3_bookmark_id, note, tag_string,
                        collection_names, private, rec, sync_to_ao3, created_at
                 FROM ao3_bookmarks",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                let kind: String = r.get(3)?;
                let target_id = r.get::<_, i64>(4)? as u64;
                Ok((kind, target_id, Ao3BookmarkEntity {
                    id: r.get(0)?,
                    account_id: r.get(1)?,
                    owner: r.get(2)?,
                    target: BookmarkTarget::Work(0), // replaced below
                    ao3_bookmark_id: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    note: r.get(6)?,
                    tag_string: r.get(7)?,
                    collection_names: r.get(8)?,
                    private: r.get::<_, i64>(9)? != 0,
                    rec: r.get::<_, i64>(10)? != 0,
                    sync_to_ao3: r.get::<_, i64>(11)? != 0,
                    created_at: r.get(12)?,
                }))
            })
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        let mut by_target = self.by_target.borrow_mut();
        map.clear();
        by_target.clear();
        for row in rows {
            let (kind, target_id, mut e) = row.map_err(map_sql)?;
            let Some(target) = BookmarkTarget::from_parts(&kind, target_id) else { continue };
            e.target = target;
            by_target.insert((e.owner.clone(), target), e.id);
            map.insert(e.id, Arc::new(e));
        }
        Ok(())
    }

    fn insert_entity(&self, e: Ao3BookmarkEntity) {
        self.by_target.borrow_mut().insert((e.owner.clone(), e.target), e.id);
        self.map.borrow_mut().insert(e.id, Arc::new(e));
    }

    pub(super) fn id_of(&self, owner: &str, target: BookmarkTarget) -> Option<i64> {
        self.by_target.borrow().get(&(owner.to_string(), target)).copied()
    }

    pub(super) fn get_by_id(&self, id: i64) -> Option<Arc<Ao3BookmarkEntity>> {
        self.map.borrow().get(&id).cloned()
    }

    pub(super) fn get(&self, owner: &str, target: BookmarkTarget) -> Option<Arc<Ao3BookmarkEntity>> {
        self.id_of(owner, target).and_then(|id| self.get_by_id(id))
    }

    /// A snapshot of every entity (unordered).
    pub(super) fn all(&self) -> Vec<Arc<Ao3BookmarkEntity>> {
        self.map.borrow().values().cloned().collect()
    }

    /// One owner's rows, newest first (created_at descending, row id as a
    /// deterministic tiebreak).
    pub(super) fn for_owner(&self, owner: &str) -> Vec<Arc<Ao3BookmarkEntity>> {
        let mut rows: Vec<Arc<Ao3BookmarkEntity>> = self
            .map
            .borrow()
            .values()
            .filter(|e| e.owner == owner)
            .cloned()
            .collect();
        rows.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));
        rows
    }

    fn update_entity(&self, id: i64, mutate: impl FnOnce(&mut Ao3BookmarkEntity)) {
        let mut map = self.map.borrow_mut();
        if let Some(existing) = map.get(&id) {
            let mut e = (**existing).clone();
            mutate(&mut e);
            map.insert(id, Arc::new(e));
        }
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Create (or fully reset) an owner's record for a target — the local
    /// "bookmark this with a note / sync it" action. Reset semantics on
    /// purpose: any previous row's details go back to their defaults along
    /// with the timestamp. The row id is preserved (upsert, never REPLACE
    /// — collection links reference it). Returns the row id.
    pub(super) fn add(&self, conn: &Connection, account_id: Option<i64>, owner: &str,
                      target: BookmarkTarget, note: &str, sync_to_ao3: bool, now: &str)
        -> Result<i64, AppError>
    {
        conn.execute(
                "INSERT INTO ao3_bookmarks
                     (account_id, owner, kind, target_id, note, sync_to_ao3, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(owner, kind, target_id) DO UPDATE SET
                     account_id = ?1, note = ?5, sync_to_ao3 = ?6, created_at = ?7,
                     tag_string = '', collection_names = '', private = 1, rec = 0,
                     ao3_bookmark_id = NULL",
                params![account_id, owner, target.kind(), target.id() as i64, note,
                        sync_to_ao3 as i32, now],
            )
            .map_err(map_sql)?;
        let id = match self.id_of(owner, target) {
            Some(id) => id,
            None => conn.last_insert_rowid(),
        };
        self.insert_entity(Ao3BookmarkEntity {
            id,
            account_id,
            owner: owner.to_string(),
            target,
            ao3_bookmark_id: None,
            note: note.to_string(),
            tag_string: String::new(),
            collection_names: String::new(),
            private: true, // column default
            rec: false,
            sync_to_ao3,
            created_at: now.to_string(),
        });
        Ok(id)
    }

    /// Cache a bookmark seen in a fetched listing. An existing row only
    /// refreshes its AO3 id — locally edited details stay put; a new row
    /// records what the listing showed (public by construction). Returns
    /// the row id.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn cache_fetched(&self, conn: &Connection, account_id: Option<i64>, owner: &str,
                                target: BookmarkTarget, ao3_bookmark_id: u64, note: &str,
                                tag_string: &str, rec: bool, now: &str)
        -> Result<i64, AppError>
    {
        if let Some(id) = self.id_of(owner, target) {
            self.set_ao3_id(conn, id, ao3_bookmark_id)?;
            return Ok(id);
        }
        conn.execute(
                "INSERT INTO ao3_bookmarks
                     (account_id, owner, kind, target_id, note, sync_to_ao3, ao3_bookmark_id,
                      private, tag_string, rec, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, 0, ?7, ?8, ?9)",
                params![account_id, owner, target.kind(), target.id() as i64, note,
                        ao3_bookmark_id as i64, tag_string, rec as i32, now],
            )
            .map_err(map_sql)?;
        let id = conn.last_insert_rowid();
        self.insert_entity(Ao3BookmarkEntity {
            id,
            account_id,
            owner: owner.to_string(),
            target,
            ao3_bookmark_id: Some(ao3_bookmark_id),
            note: note.to_string(),
            tag_string: tag_string.to_string(),
            collection_names: String::new(),
            private: false,
            rec,
            // The bookmark exists on AO3 by construction.
            sync_to_ao3: true,
            created_at: now.to_string(),
        });
        Ok(id)
    }

    pub(super) fn update_note(&self, conn: &Connection, id: i64, note: &str)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE ao3_bookmarks SET note = ?2 WHERE id = ?1", params![id, note])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.note = note.to_string());
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn update_details(&self, conn: &Connection, id: i64,
                                 note: &str, tag_string: &str, collection_names: &str,
                                 private: bool, rec: bool) -> Result<(), AppError> {
        conn.execute(
                "UPDATE ao3_bookmarks SET note = ?2, tag_string = ?3, collection_names = ?4,
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
        conn.execute("UPDATE ao3_bookmarks SET sync_to_ao3 = ?2 WHERE id = ?1", params![id, sync as i32])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.sync_to_ao3 = sync);
        Ok(())
    }

    pub(super) fn set_ao3_id(&self, conn: &Connection, id: i64, ao3_id: u64)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE ao3_bookmarks SET ao3_bookmark_id = ?2 WHERE id = ?1",
                     params![id, ao3_id as i64])
            .map_err(map_sql)?;
        self.update_entity(id, |e| e.ao3_bookmark_id = Some(ao3_id));
        Ok(())
    }

    /// Link rows of `owner` to the account that just signed in here.
    pub(super) fn claim_owner(&self, conn: &Connection, owner: &str, account_id: i64)
        -> Result<(), AppError>
    {
        conn.execute("UPDATE ao3_bookmarks SET account_id = ?2 WHERE owner = ?1 AND account_id IS NULL",
                     params![owner, account_id])
            .map_err(map_sql)?;
        let ids: Vec<i64> = self.map.borrow().values()
            .filter(|e| e.owner == owner && e.account_id.is_none())
            .map(|e| e.id)
            .collect();
        for id in ids {
            self.update_entity(id, |e| e.account_id = Some(account_id));
        }
        Ok(())
    }

    pub(super) fn remove(&self, conn: &Connection, id: i64) -> Result<(), AppError> {
        conn.execute("DELETE FROM ao3_bookmarks WHERE id = ?1", params![id]).map_err(map_sql)?;
        self.forget(id);
        Ok(())
    }

    fn forget(&self, id: i64) {
        if let Some(e) = self.map.borrow_mut().remove(&id) {
            self.by_target.borrow_mut().remove(&(e.owner.clone(), e.target));
        }
    }

    /// Mirror the database's delete-cascade trigger: the target row is
    /// gone, so every owner's record of it left the table. (No SQL — the
    /// trigger already ran.) Returns the purged row ids so dependent
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

    /// Mirror `ON DELETE SET NULL` from accounts: the account is gone, its
    /// rows stay as that user's cached bookmarks.
    pub(super) fn unlink_account(&self, account_id: i64) {
        let ids: Vec<i64> = self.map.borrow().values()
            .filter(|e| e.account_id == Some(account_id))
            .map(|e| e.id)
            .collect();
        for id in ids {
            self.update_entity(id, |e| e.account_id = None);
        }
    }
}
