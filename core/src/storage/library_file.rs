//! Whole-file operations on the encrypted library: export a complete
//! copy under another key, swap a replacement file in underneath the
//! live connection, and inspect a closed copy. These are the primitives
//! behind iCloud sync and backups (api/cloud_sync.rs) — the library is
//! moved around as one SQLCipher file, never merged row by row.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection};

use super::{map_sql, Storage};
use crate::error::AppError;

/// `app_state` keys the exporter stamps into a copy so a reader can tell
/// who wrote it and which version it is without any side file.
pub const EMBED_PREFIX: &str = "cloud:";

fn io_err(what: &str, e: std::io::Error) -> AppError {
    AppError::StorageError(format!("{what}: {e}"))
}

fn sidecars(path: &Path) -> [PathBuf; 2] {
    let s = path.as_os_str().to_string_lossy();
    [PathBuf::from(format!("{s}-wal")), PathBuf::from(format!("{s}-shm"))]
}

fn remove_sidecars(path: &Path) {
    for p in sidecars(path) {
        let _ = std::fs::remove_file(p);
    }
}

impl Storage {
    /// `n` random bytes as lowercase hex, from SQLite's CSPRNG.
    pub fn random_hex(&self, n: u32) -> Result<String, AppError> {
        self.conn
            .query_row("SELECT lower(hex(randomblob(?1)))", params![n], |r| r.get(0))
            .map_err(map_sql)
    }

    pub fn db_path(&self) -> Option<&str> {
        self.path.as_deref()
    }

    pub fn passphrase(&self) -> &str {
        &self.passphrase
    }

    fn require_path(&self) -> Result<PathBuf, AppError> {
        self.path
            .as_deref()
            .map(PathBuf::from)
            .ok_or_else(|| AppError::StorageError("in-memory store has no file to operate on".into()))
    }

    /// Unix ms of the newest write to the database file or its WAL, as
    /// the filesystem saw it. Cheap "changed since" probe for sync.
    pub fn last_modified_ms(&self) -> Option<i64> {
        let path = self.path.as_deref()?;
        let path = Path::new(path);
        let mut newest: Option<i64> = None;
        for p in std::iter::once(path.to_path_buf()).chain(sidecars(path)) {
            if let Ok(meta) = std::fs::metadata(&p) {
                if let Ok(m) = meta.modified() {
                    if let Ok(d) = m.duration_since(std::time::UNIX_EPOCH) {
                        let ms = d.as_millis() as i64;
                        newest = Some(newest.map_or(ms, |n| n.max(ms)));
                    }
                }
            }
        }
        newest
    }

    /// Write a complete, consistent copy of the library to `dest`,
    /// encrypted with `key`, with `embed` stamped into the copy's
    /// `app_state` (keys should carry `EMBED_PREFIX`). The live database
    /// is untouched. Returns the copy's size in bytes.
    pub fn export_copy(&self, dest: &Path, key: &str, embed: &[(&str, &str)]) -> Result<u64, AppError> {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| io_err("create export dir", e))?;
        }
        let _ = std::fs::remove_file(dest);
        remove_sidecars(dest);
        let dest_str = dest.to_string_lossy().to_string();

        // sqlcipher_export copies tables in creation order; FK checks on
        // the attached copy could reject a child before its parent lands.
        self.conn.pragma_update(None, "foreign_keys", "OFF").map_err(map_sql)?;
        let result = (|| -> Result<(), AppError> {
            self.conn
                .execute("ATTACH DATABASE ?1 AS export KEY ?2", params![dest_str, key])
                .map_err(map_sql)?;
            let inner = (|| -> Result<(), AppError> {
                self.conn
                    .query_row("SELECT sqlcipher_export('export')", [], |_| Ok(()))
                    .map_err(map_sql)?;
                for (k, v) in embed {
                    self.conn
                        .execute("INSERT OR REPLACE INTO export.app_state (key, value) VALUES (?1, ?2)", params![k, v])
                        .map_err(map_sql)?;
                }
                self.conn
                    .pragma_update(Some("export"), "user_version", Self::SCHEMA_VERSION)
                    .map_err(map_sql)?;
                Ok(())
            })();
            let detach = self.conn.execute_batch("DETACH DATABASE export").map_err(map_sql);
            inner.and(detach)
        })();
        let fk = self.conn.pragma_update(None, "foreign_keys", "ON").map_err(map_sql);
        result.and(fk)?;

        std::fs::metadata(dest)
            .map(|m| m.len())
            .map_err(|e| io_err("stat export", e))
    }

    /// Replace the live database with `incoming` — a file already keyed
    /// with this store's passphrase — moving the current file to
    /// `backup_dest` first. The connection is closed for the swap and
    /// reopened on the new file (migrations run if it is older), and every
    /// in-memory cache is rebuilt from it.
    ///
    /// If the reopen fails the swap is undone so the store keeps working
    /// on what it had.
    pub fn replace_with(&mut self, incoming: &Path, backup_dest: &Path) -> Result<(), AppError> {
        let path = self.require_path()?;
        if backup_dest.exists() {
            return Err(AppError::StorageError(format!("backup target already exists: {}", backup_dest.display())));
        }
        if !incoming.exists() {
            return Err(AppError::StorageError(format!("replacement file missing: {}", incoming.display())));
        }
        if let Some(parent) = backup_dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| io_err("create backup dir", e))?;
        }

        // Fold the WAL into the main file so the backup is one file.
        self.conn
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .map_err(map_sql)?;
        let placeholder = Connection::open_in_memory().map_err(map_sql)?;
        let old = std::mem::replace(&mut self.conn, placeholder);
        drop(old);
        remove_sidecars(&path);

        std::fs::rename(&path, backup_dest).map_err(|e| io_err("move current library to backup", e))?;
        if let Err(e) = std::fs::rename(incoming, &path) {
            let _ = std::fs::rename(backup_dest, &path);
            let _ = self.reopen(&path);
            return Err(io_err("move replacement into place", e));
        }
        remove_sidecars(incoming);

        match self.reopen(&path) {
            Ok(()) => Ok(()),
            Err(e) => {
                // Put the old file back and come up on it.
                let _ = std::fs::rename(&path, incoming);
                remove_sidecars(&path);
                let _ = std::fs::rename(backup_dest, &path);
                let _ = self.reopen(&path);
                Err(AppError::StorageError(format!("replacement library could not be opened: {e}")))
            }
        }
    }

    fn reopen(&mut self, path: &Path) -> Result<(), AppError> {
        let conn = Connection::open(path).map_err(map_sql)?;
        self.conn = Self::prepare_connection(conn, &self.passphrase)?;
        self.tag_cache = Default::default();
        self.works_cache = Default::default();
        self.state_cache = Default::default();
        self.bookmarks_cache = Default::default();
        self.collections_cache = Default::default();
        self.users_cache = Default::default();
        self.series_cache = Default::default();
        self.migrate_and_load()
    }
}

// ---------------------------------------------------------------------------
// Closed-file helpers
// ---------------------------------------------------------------------------

/// Open a library file that no live store holds, verifying the key by
/// reading the schema.
pub fn open_closed(path: &Path, key: &str) -> Result<Connection, AppError> {
    if !path.exists() {
        return Err(AppError::StorageError(format!("library file missing: {}", path.display())));
    }
    let conn = Connection::open(path).map_err(map_sql)?;
    if !key.is_empty() {
        conn.pragma_update(None, "key", key).map_err(map_sql)?;
    }
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))
        .map_err(|_| AppError::StorageError("library file is not readable with this key".into()))?;
    Ok(conn)
}

pub fn user_version(conn: &Connection) -> Result<u32, AppError> {
    conn.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(map_sql)
}

/// The `cloud:*` rows an export stamped into a copy (empty for a file
/// that never went through `export_copy`).
pub fn read_embedded(conn: &Connection) -> Result<HashMap<String, String>, AppError> {
    let has_table: bool = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'app_state'",
            [],
            |r| r.get::<_, i64>(0).map(|n| n > 0),
        )
        .map_err(map_sql)?;
    if !has_table {
        return Ok(HashMap::new());
    }
    let mut stmt = conn
        .prepare("SELECT key, value FROM app_state WHERE key LIKE ?1")
        .map_err(map_sql)?;
    let rows = stmt
        .query_map(params![format!("{EMBED_PREFIX}%")], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(map_sql)?;
    rows.collect::<Result<_, _>>().map_err(map_sql)
}

/// Re-encrypt a closed library file in place.
pub fn rekey_file(path: &Path, old_key: &str, new_key: &str) -> Result<(), AppError> {
    let conn = open_closed(path, old_key)?;
    conn.pragma_update(None, "rekey", new_key).map_err(map_sql)?;
    drop(conn);
    remove_sidecars(path);
    // Prove the result opens under the new key before anyone relies on it.
    open_closed(path, new_key).map(|_| ())
}

/// Delete a library file and any journal siblings.
pub fn remove_file_set(path: &Path) {
    let _ = std::fs::remove_file(path);
    remove_sidecars(path);
}
