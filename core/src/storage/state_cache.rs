use std::cell::RefCell;
use std::collections::HashMap;

use rusqlite::{params, Connection};

use crate::error::AppError;

use super::map_sql;

/// The app_state table's in-memory mirror and single write authority —
/// the same contract as `TagCache`/`WorksCache`.
///
/// app_state is a string key → string value settings store; every lookup
/// used to be its own SELECT. All of it fits in one map loaded at open:
/// `get` costs no SQL, and `set` mutates the map and the row in the same
/// call so the two can never drift.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback, since a
///   rolled-back write would otherwise strand stale state in the map
#[derive(Default)]
pub(super) struct StateCache {
    map: RefCell<HashMap<String, String>>,
}

impl StateCache {
    /// (Re)fill the map from the app_state table — run once at open, after
    /// migrations, and again after a rollback that may have discarded
    /// writes the map already recorded.
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare("SELECT key, value FROM app_state")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        map.clear();
        for row in rows {
            let (key, value) = row.map_err(map_sql)?;
            map.insert(key, value);
        }
        Ok(())
    }

    /// Answered from the map — no SQL.
    pub(super) fn get(&self, key: &str) -> Option<String> {
        self.map.borrow().get(key).cloned()
    }

    /// Write-through upsert: the row and the map change in the same call.
    /// Skips the SQL entirely when the stored value already matches.
    pub(super) fn set(&self, conn: &Connection, key: &str, value: &str) -> Result<(), AppError> {
        if self.map.borrow().get(key).is_some_and(|v| v.as_str() == value) {
            return Ok(());
        }
        conn.prepare_cached("INSERT OR REPLACE INTO app_state (key, value) VALUES (?1, ?2)")
            .map_err(map_sql)?
            .execute(params![key, value])
            .map_err(map_sql)?;
        self.map.borrow_mut().insert(key.to_string(), value.to_string());
        Ok(())
    }
}
