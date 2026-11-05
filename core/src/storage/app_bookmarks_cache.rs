use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::BookmarkTarget;

use super::map_sql;

/// One row of `app_bookmarks` — the app's own "bookmark this" flag: an
/// account (None = made while signed out), a target, and when. Nothing
/// AO3-specific lives here (Area 7.1).
#[derive(Clone, Debug)]
pub(super) struct AppBookmarkEntity {
    pub id: i64,
    pub account_id: Option<i64>,
    pub target: BookmarkTarget,
    pub created_at: String,
}

/// The app_bookmarks table's in-memory mirror and single write authority
/// — same contract as the other storage caches. Primary key is the row
/// id; `(account, target)` is unique.
///
/// Referential integrity lives in the database: a target-exists trigger
/// rejects a bookmark of an uncached work/series, and delete triggers on
/// works/series cascade their bookmarks (the cache mirrors those via
/// `purge_target`).
#[derive(Default)]
pub(super) struct AppBookmarksCache {
    map: RefCell<HashMap<i64, Arc<AppBookmarkEntity>>>,
    by_target: RefCell<HashMap<(Option<i64>, BookmarkTarget), i64>>,
}

impl AppBookmarksCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare("SELECT id, account_id, kind, target_id, created_at FROM app_bookmarks")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                let kind: String = r.get(2)?;
                let target_id = r.get::<_, i64>(3)? as u64;
                Ok((kind, target_id, AppBookmarkEntity {
                    id: r.get(0)?,
                    account_id: r.get(1)?,
                    target: BookmarkTarget::Work(0), // replaced below
                    created_at: r.get(4)?,
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
            by_target.insert((e.account_id, target), e.id);
            map.insert(e.id, Arc::new(e));
        }
        Ok(())
    }

    pub(super) fn id_of(&self, account_id: Option<i64>, target: BookmarkTarget) -> Option<i64> {
        self.by_target.borrow().get(&(account_id, target)).copied()
    }

    /// One account's flags, newest first (created_at descending, row id
    /// as a deterministic tiebreak).
    pub(super) fn for_account(&self, account_id: Option<i64>) -> Vec<Arc<AppBookmarkEntity>> {
        let mut rows: Vec<Arc<AppBookmarkEntity>> = self
            .map
            .borrow()
            .values()
            .filter(|e| e.account_id == account_id)
            .cloned()
            .collect();
        rows.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));
        rows
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Set the flag. An existing flag keeps its row id but takes the new
    /// timestamp (re-bookmarking moves it to the top). Returns the row id.
    pub(super) fn add(&self, conn: &Connection, account_id: Option<i64>, target: BookmarkTarget, now: &str)
        -> Result<i64, AppError>
    {
        if let Some(id) = self.id_of(account_id, target) {
            conn.execute("UPDATE app_bookmarks SET created_at = ?2 WHERE id = ?1", params![id, now])
                .map_err(map_sql)?;
            let mut map = self.map.borrow_mut();
            if let Some(existing) = map.get(&id) {
                let mut e = (**existing).clone();
                e.created_at = now.to_string();
                map.insert(id, Arc::new(e));
            }
            return Ok(id);
        }
        conn.execute(
                "INSERT INTO app_bookmarks (account_id, kind, target_id, created_at)
                 VALUES (?1, ?2, ?3, ?4)",
                params![account_id, target.kind(), target.id() as i64, now],
            )
            .map_err(map_sql)?;
        let id = conn.last_insert_rowid();
        self.by_target.borrow_mut().insert((account_id, target), id);
        self.map.borrow_mut().insert(id, Arc::new(AppBookmarkEntity {
            id, account_id, target, created_at: now.to_string(),
        }));
        Ok(id)
    }

    pub(super) fn remove(&self, conn: &Connection, id: i64) -> Result<(), AppError> {
        conn.execute("DELETE FROM app_bookmarks WHERE id = ?1", params![id]).map_err(map_sql)?;
        self.forget(id);
        Ok(())
    }

    fn forget(&self, id: i64) {
        if let Some(e) = self.map.borrow_mut().remove(&id) {
            self.by_target.borrow_mut().remove(&(e.account_id, e.target));
        }
    }

    /// Mirror the database's delete-cascade trigger: the target row is
    /// gone, so every account's flag on it left the table. (No SQL — the
    /// trigger already ran.)
    pub(super) fn purge_target(&self, target: BookmarkTarget) {
        let ids: Vec<i64> = self.map.borrow().values()
            .filter(|e| e.target == target)
            .map(|e| e.id)
            .collect();
        for id in ids {
            self.forget(id);
        }
    }
}
