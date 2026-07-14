// NOTE: A `StorageError(String)` variant must be added to `AppError` in error.rs
// for this module to compile. Example:
//
//     #[error("Storage error: {0}")]
//     StorageError(String),

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{
    AO3User, Chapter, Comment, ContentBlock, Rating, Warning, WorkSummary,
};

/// Encrypted local storage backed by SQLCipher.
///
/// All Vec/enum fields are stored as JSON strings via serde_json.
/// ContentBlock trees are stored as JSON in the `chapters.content_json` column.
pub struct Storage {
    conn: Connection,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn map_sql(e: rusqlite::Error) -> AppError {
    AppError::StorageError(e.to_string())
}

fn map_json(e: serde_json::Error) -> AppError {
    AppError::StorageError(e.to_string())
}

fn rating_to_str(r: &Rating) -> &'static str {
    match r {
        Rating::General => "General",
        Rating::Teen => "Teen",
        Rating::Mature => "Mature",
        Rating::Explicit => "Explicit",
        Rating::NotRated => "NotRated",
    }
}

fn str_to_rating(s: &str) -> Rating {
    match s {
        "General" => Rating::General,
        "Teen" => Rating::Teen,
        "Mature" => Rating::Mature,
        "Explicit" => Rating::Explicit,
        _ => Rating::NotRated,
    }
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

impl Storage {
    /// Open (or create) an encrypted database at the given filesystem path.
    pub fn open(path: &str, passphrase: &str) -> Result<Self, AppError> {
        let conn = Connection::open(path).map_err(map_sql)?;
        Self::configure(conn, passphrase)
    }

    /// Open an **in-memory** encrypted database — useful for tests.
    pub fn open_in_memory(passphrase: &str) -> Result<Self, AppError> {
        let conn = Connection::open_in_memory().map_err(map_sql)?;
        Self::configure(conn, passphrase)
    }

    fn configure(conn: Connection, passphrase: &str) -> Result<Self, AppError> {
        if !passphrase.is_empty() {
            conn.pragma_update(None, "key", passphrase).map_err(map_sql)?;
        }
        conn.pragma_update(None, "journal_mode", "WAL").map_err(map_sql)?;

        let storage = Self { conn };
        storage.create_tables()?;
        Ok(storage)
    }

    pub fn change_passphrase(&self, new_passphrase: &str) -> Result<(), AppError> {
        if new_passphrase.is_empty() {
            self.conn.pragma_update(None, "rekey", "").map_err(map_sql)?;
        } else {
            self.conn.pragma_update(None, "rekey", new_passphrase).map_err(map_sql)?;
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Works
    // -------------------------------------------------------------------

    /// Insert or replace a `WorkSummary`.
    pub fn save_work(&self, work: &WorkSummary) -> Result<(), AppError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO works (
                    id, title, authors_json, fandoms_json, rating,
                    warnings_json, categories_json, relationships_json,
                    characters_json, tags_json, summary, word_count,
                    chapter_count, total_chapters, kudos, hits,
                    bookmarks, comments, date_updated, language, complete
                ) VALUES (
                    ?1, ?2, ?3, ?4, ?5,
                    ?6, ?7, ?8,
                    ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16,
                    ?17, ?18, ?19, ?20, ?21
                )",
                params![
                    work.id as i64,
                    work.title,
                    serde_json::to_string(&work.authors).map_err(map_json)?,
                    serde_json::to_string(&work.fandoms).map_err(map_json)?,
                    rating_to_str(&work.rating),
                    serde_json::to_string(&work.warnings).map_err(map_json)?,
                    serde_json::to_string(&work.categories).map_err(map_json)?,
                    serde_json::to_string(&work.relationships).map_err(map_json)?,
                    serde_json::to_string(&work.characters).map_err(map_json)?,
                    serde_json::to_string(&work.tags).map_err(map_json)?,
                    work.summary,
                    work.word_count as i64,
                    work.chapter_count as i64,
                    work.total_chapters.map(|c| c as i64),
                    work.kudos as i64,
                    work.hits as i64,
                    work.bookmarks as i64,
                    work.comments as i64,
                    work.date_updated,
                    work.language,
                    work.complete as i32,
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Retrieve a single work by its AO3 id, or `None` if not stored.
    pub fn get_work(&self, work_id: u64) -> Result<Option<WorkSummary>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, title, authors_json, fandoms_json, rating,
                        warnings_json, categories_json, relationships_json,
                        characters_json, tags_json, summary, word_count,
                        chapter_count, total_chapters, kudos, hits,
                        bookmarks, comments, date_updated, language, complete
                 FROM works WHERE id = ?1",
            )
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(params![work_id as i64], |row| {
                Ok(Self::work_from_row(row))
            })
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(inner)) => Ok(Some(inner.map_err(map_sql)?)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    /// Return every stored work (unordered).
    pub fn get_all_works(&self) -> Result<Vec<WorkSummary>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, title, authors_json, fandoms_json, rating,
                        warnings_json, categories_json, relationships_json,
                        characters_json, tags_json, summary, word_count,
                        chapter_count, total_chapters, kudos, hits,
                        bookmarks, comments, date_updated, language, complete
                 FROM works",
            )
            .map_err(map_sql)?;

        let rows = stmt
            .query_map([], |row| Ok(Self::work_from_row(row)))
            .map_err(map_sql)?;

        let mut works = Vec::new();
        for row in rows {
            works.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        Ok(works)
    }

    /// Delete a work (and its chapters, progress, bookmark, and history).
    pub fn delete_work(&self, work_id: u64) -> Result<(), AppError> {
        let id = work_id as i64;
        self.conn
            .execute("DELETE FROM chapters WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM reading_progress WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM bookmarks WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM history WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM works WHERE id = ?1", params![id])
            .map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Chapters
    // -------------------------------------------------------------------

    /// Insert or replace a chapter for the given work.
    pub fn save_chapter(&self, work_id: u64, chapter: &Chapter) -> Result<(), AppError> {
        let content_json = serde_json::to_string(&chapter.content).map_err(map_json)?;
        self.conn
            .execute(
                "INSERT OR REPLACE INTO chapters
                    (work_id, number, chapter_id, title, content_json,
                     notes_before, notes_after)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    work_id as i64,
                    chapter.number as i64,
                    chapter.id.map(|id| id as i64),
                    chapter.title,
                    content_json,
                    chapter.notes_before,
                    chapter.notes_after,
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// All chapters for a work, ordered by chapter number.
    pub fn get_chapters(&self, work_id: u64) -> Result<Vec<Chapter>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT chapter_id, title, number, content_json,
                        notes_before, notes_after
                 FROM chapters WHERE work_id = ?1 ORDER BY number ASC",
            )
            .map_err(map_sql)?;

        let rows = stmt
            .query_map(params![work_id as i64], |row| {
                Ok(Self::chapter_from_row(row))
            })
            .map_err(map_sql)?;

        let mut chapters = Vec::new();
        for row in rows {
            chapters.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        Ok(chapters)
    }

    /// A single chapter by work id and chapter number.
    pub fn get_chapter(
        &self,
        work_id: u64,
        chapter_number: u32,
    ) -> Result<Option<Chapter>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT chapter_id, title, number, content_json,
                        notes_before, notes_after
                 FROM chapters WHERE work_id = ?1 AND number = ?2",
            )
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(
                params![work_id as i64, chapter_number as i64],
                |row| Ok(Self::chapter_from_row(row)),
            )
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(inner)) => Ok(Some(inner.map_err(map_sql)?)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Reading progress
    // -------------------------------------------------------------------

    /// Save the reader's position inside a work.
    /// `chapter` is the 1-based chapter number; `position` is a normalised
    /// scroll offset (0.0 – 1.0).
    pub fn save_progress(
        &self,
        work_id: u64,
        chapter: u32,
        position: f64,
    ) -> Result<(), AppError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO reading_progress
                    (work_id, chapter, position, updated_at)
                 VALUES (?1, ?2, ?3, datetime('now'))",
                params![work_id as i64, chapter as i64, position],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    pub fn delete_progress(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM reading_progress WHERE work_id = ?1", params![work_id as i64]).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_progress(&self, work_id: u64) -> Result<Option<(u32, f64)>, AppError> {
        let mut stmt = self
            .conn
            .prepare("SELECT chapter, position FROM reading_progress WHERE work_id = ?1")
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(params![work_id as i64], |row| {
                let chapter: i64 = row.get(0)?;
                let position: f64 = row.get(1)?;
                Ok((chapter as u32, position))
            })
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(pair)) => Ok(Some(pair)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    pub fn get_all_progress(&self) -> Result<Vec<(u64, u32, f64)>, AppError> {
        let mut stmt = self.conn
            .prepare("SELECT work_id, chapter, position FROM reading_progress")
            .map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            let work_id: i64 = row.get(0)?;
            let chapter: i64 = row.get(1)?;
            let position: f64 = row.get(2)?;
            Ok((work_id as u64, chapter as u32, position))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Bookmarks
    // -------------------------------------------------------------------

    /// Bookmark a work, optionally attaching a note.
    fn active_account_id(&self) -> String {
        self.get_active_account()
            .ok()
            .flatten()
            .map(|(id, _, _)| id)
            .unwrap_or_default()
    }

    pub fn add_bookmark(&self, work_id: u64, note: Option<&str>, sync_to_ao3: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "INSERT OR REPLACE INTO bookmarks (account_id, work_id, note, sync_to_ao3) VALUES (?1, ?2, ?3, ?4)",
            params![acct, work_id as i64, note.unwrap_or(""), sync_to_ao3 as i32],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: &str) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "UPDATE bookmarks SET note = ?3 WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64, note],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "UPDATE bookmarks SET sync_to_ao3 = ?3 WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64, sync as i32],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "DELETE FROM bookmarks WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_bookmarks(&self) -> Result<Vec<u64>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT work_id FROM bookmarks WHERE account_id = ?1 ORDER BY created_at DESC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![acct], |row| { let id: i64 = row.get(0)?; Ok(id as u64) }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn get_bookmarks_full(&self) -> Result<Vec<(u64, String, bool)>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT work_id, note, sync_to_ao3 FROM bookmarks WHERE account_id = ?1 ORDER BY created_at DESC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![acct], |row| {
            let id: i64 = row.get(0)?;
            let note: String = row.get(1)?;
            let sync: i32 = row.get(2)?;
            Ok((id as u64, note, sync != 0))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn get_synced_bookmarks(&self) -> Result<Vec<(u64, String)>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT work_id, note FROM bookmarks WHERE account_id = ?1 AND sync_to_ao3 = 1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![acct], |row| {
            let id: i64 = row.get(0)?;
            let note: String = row.get(1)?;
            Ok((id as u64, note))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AppError> {
        let acct = self.active_account_id();
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM bookmarks WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64], |row| row.get(0),
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    pub fn get_bookmark_full(&self, work_id: u64) -> Result<Option<(String, bool, Option<u64>)>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT note, sync_to_ao3, ao3_bookmark_id FROM bookmarks WHERE account_id = ?1 AND work_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![acct, work_id as i64], |row| {
            let note: String = row.get(0)?;
            let sync: i32 = row.get(1)?;
            let ao3_id: Option<i64> = row.get(2)?;
            Ok((note, sync != 0, ao3_id.map(|id| id as u64)))
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(Some(v)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    pub fn set_ao3_bookmark_id(&self, work_id: u64, ao3_id: u64) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "UPDATE bookmarks SET ao3_bookmark_id = ?3 WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64, ao3_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_ao3_bookmark_id(&self, work_id: u64) -> Result<Option<u64>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT ao3_bookmark_id FROM bookmarks WHERE account_id = ?1 AND work_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![acct, work_id as i64], |row| {
            let id: Option<i64> = row.get(0)?;
            Ok(id.map(|v| v as u64))
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(v),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AppError> {
        let acct = self.active_account_id();
        let sync: i32 = self.conn.query_row(
            "SELECT COALESCE(sync_to_ao3, 0) FROM bookmarks WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64], |row| row.get(0),
        ).unwrap_or(0);
        Ok(sync != 0)
    }

    // -------------------------------------------------------------------
    // History
    // -------------------------------------------------------------------

    /// Record that the user opened a work.  Multiple accesses create
    /// multiple history rows, producing a timeline.
    pub fn add_to_history(&self, work_id: u64) -> Result<(), AppError> {
        self.conn
            .execute(
                "INSERT INTO history (work_id, accessed_at)
                 VALUES (?1, datetime('now'))",
                params![work_id as i64],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Return history entries most-recent-first as `(work_id, timestamp)`.
    pub fn get_history(&self) -> Result<Vec<(u64, String)>, AppError> {
        let mut stmt = self
            .conn
            .prepare("SELECT work_id, accessed_at FROM history ORDER BY accessed_at DESC")
            .map_err(map_sql)?;

        let rows = stmt
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                let ts: String = row.get(1)?;
                Ok((id as u64, ts))
            })
            .map_err(map_sql)?;

        let mut entries = Vec::new();
        for row in rows {
            entries.push(row.map_err(map_sql)?);
        }
        Ok(entries)
    }

    /// Wipe the reading history table.
    pub fn clear_history(&self) -> Result<(), AppError> {
        self.conn
            .execute("DELETE FROM history", [])
            .map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Downloads (intentional user downloads)
    // -------------------------------------------------------------------

    pub fn mark_downloaded(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO downloads (work_id) VALUES (?1)",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn unmark_downloaded(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM downloads WHERE work_id = ?1",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn is_downloaded(&self, work_id: u64) -> Result<bool, AppError> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM downloads WHERE work_id = ?1",
            params![work_id as i64],
            |row| row.get(0),
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    pub fn get_downloaded_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare("SELECT work_id FROM downloads").map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            let id: i64 = row.get(0)?;
            Ok(id as u64)
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // App state (key-value)
    // -------------------------------------------------------------------

    pub fn set_state(&self, key: &str, value: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO app_state (key, value) VALUES (?1, ?2)",
            params![key, value],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_state(&self, key: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT value FROM app_state WHERE key = ?1"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![key], |row| row.get(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(Some(v)),
            _ => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Saved searches
    // -------------------------------------------------------------------

    pub fn save_search(&self, name: &str, params_json: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO saved_searches (name, params_json) VALUES (?1, ?2)",
            params![name, params_json],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_saved_searches(&self) -> Result<Vec<(i64, String, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, params_json FROM saved_searches ORDER BY created_at DESC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn delete_saved_search(&self, id: i64) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM saved_searches WHERE id = ?1", params![id]).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Reading Lists
    // -------------------------------------------------------------------

    pub fn create_reading_list(&self, name: &str) -> Result<i64, AppError> {
        self.conn.execute(
            "INSERT INTO reading_lists (name) VALUES (?1)",
            params![name],
        ).map_err(map_sql)?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn rename_reading_list(&self, list_id: i64, name: &str) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE reading_lists SET name = ?2 WHERE id = ?1",
            params![list_id, name],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn delete_reading_list(&self, list_id: i64) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM reading_list_items WHERE list_id = ?1", params![list_id]).map_err(map_sql)?;
        self.conn.execute("DELETE FROM reading_lists WHERE id = ?1", params![list_id]).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_reading_lists(&self) -> Result<Vec<(i64, String, u32)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT rl.id, rl.name, COUNT(rli.work_id)
             FROM reading_lists rl
             LEFT JOIN reading_list_items rli ON rl.id = rli.list_id
             GROUP BY rl.id
             ORDER BY rl.created_at ASC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, u32>(2)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn add_to_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AppError> {
        let max_order: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(sort_order), -1) FROM reading_list_items WHERE list_id = ?1",
            params![list_id], |row| row.get(0),
        ).unwrap_or(-1);
        self.conn.execute(
            "INSERT OR IGNORE INTO reading_list_items (list_id, work_id, sort_order) VALUES (?1, ?2, ?3)",
            params![list_id, work_id as i64, max_order + 1],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn remove_from_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM reading_list_items WHERE list_id = ?1 AND work_id = ?2",
            params![list_id, work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_reading_list_items(&self, list_id: i64) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT work_id FROM reading_list_items WHERE list_id = ?1 ORDER BY sort_order ASC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![list_id], |row| {
            let id: i64 = row.get(0)?;
            Ok(id as u64)
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Subscription snapshots
    // -------------------------------------------------------------------

    /// Insert or replace a subscription snapshot for diff-based notification detection.
    pub fn save_snapshot(
        &self,
        sub_type: &str,
        sub_id: &str,
        work_id: u64,
        chapter_count: u32,
        word_count: u64,
        date_updated: &str,
    ) -> Result<(), AppError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO subscription_snapshots
                    (sub_type, sub_id, work_id, chapter_count, word_count, date_updated)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    sub_type,
                    sub_id,
                    work_id as i64,
                    chapter_count as i64,
                    word_count as i64,
                    date_updated,
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Get all snapshots for a given subscription (type + id).
    /// Returns Vec of (work_id, chapter_count, word_count, date_updated).
    pub fn get_snapshots(
        &self,
        sub_type: &str,
        sub_id: &str,
    ) -> Result<Vec<(u64, u32, u64, String)>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT work_id, chapter_count, word_count, date_updated
                 FROM subscription_snapshots
                 WHERE sub_type = ?1 AND sub_id = ?2",
            )
            .map_err(map_sql)?;

        let rows = stmt
            .query_map(params![sub_type, sub_id], |row| {
                let work_id: i64 = row.get(0)?;
                let chapter_count: i64 = row.get(1)?;
                let word_count: i64 = row.get(2)?;
                let date_updated: String = row.get(3)?;
                Ok((work_id as u64, chapter_count as u32, word_count as u64, date_updated))
            })
            .map_err(map_sql)?;

        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Notifications
    // -------------------------------------------------------------------

    /// Add a notification to the database. Returns the new notification id.
    pub fn add_notification(
        &self,
        notif_type: &str,
        work_id: u64,
        author: &str,
        title: &str,
        message: &str,
    ) -> Result<i64, AppError> {
        // Check for existing unread notification for same work and type
        let existing: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM notifications WHERE notif_type = ?1 AND work_id = ?2 AND read = 0",
            params![notif_type, work_id as i64],
            |row| row.get(0),
        ).unwrap_or(0);
        if existing > 0 {
            return Ok(-1);
        }

        self.conn
            .execute(
                "INSERT INTO notifications (notif_type, work_id, author, title, message)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![notif_type, work_id as i64, author, title, message],
            )
            .map_err(map_sql)?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Get all notifications, most recent first.
    /// Returns Vec of (id, notif_type, work_id, author, title, message, created_at, read).
    pub fn get_notifications(
        &self,
    ) -> Result<Vec<(i64, String, u64, String, String, String, String, bool)>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, notif_type, work_id, author, title, message, created_at, read
                 FROM notifications
                 ORDER BY created_at DESC",
            )
            .map_err(map_sql)?;

        let rows = stmt
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                let notif_type: String = row.get(1)?;
                let work_id: i64 = row.get(2)?;
                let author: String = row.get(3)?;
                let title: String = row.get(4)?;
                let message: String = row.get(5)?;
                let created_at: String = row.get(6)?;
                let read: i32 = row.get(7)?;
                Ok((id, notif_type, work_id as u64, author, title, message, created_at, read != 0))
            })
            .map_err(map_sql)?;

        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Get the count of unread notifications.
    pub fn get_unread_count(&self) -> Result<u32, AppError> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM notifications WHERE read = 0",
                [],
                |row| row.get(0),
            )
            .map_err(map_sql)?;
        Ok(count as u32)
    }

    /// Mark a single notification as read.
    pub fn mark_notification_read(&self, id: i64) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE notifications SET read = 1 WHERE id = ?1",
                params![id],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Mark all notifications as read.
    pub fn mark_all_read(&self) -> Result<(), AppError> {
        self.conn
            .execute("UPDATE notifications SET read = 1", [])
            .map_err(map_sql)?;
        Ok(())
    }

    /// Delete all read notifications.
    pub fn clear_read_notifications(&self) -> Result<(), AppError> {
        self.conn
            .execute("DELETE FROM notifications WHERE read = 1", [])
            .map_err(map_sql)?;
        Ok(())
    }

    /// Get the last time subscriptions were checked, using the app_state table.
    pub fn get_last_check_time(&self) -> Result<Option<String>, AppError> {
        self.get_state("last_subscription_check")
    }

    /// Set the last subscription check time.
    pub fn set_last_check_time(&self, time: &str) -> Result<(), AppError> {
        self.set_state("last_subscription_check", time)
    }

    // -------------------------------------------------------------------
    // -------------------------------------------------------------------
    // Session Cache
    // -------------------------------------------------------------------

    pub fn set_cache(&self, key: &str, data: &str, session_id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO session_cache (cache_key, data_json, session_id) VALUES (?1, ?2, ?3)",
            params![key, data, session_id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_cache(&self, key: &str, session_id: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT data_json FROM session_cache WHERE cache_key = ?1 AND session_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![key, session_id], |row| row.get::<_, String>(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(Some(v)),
            _ => Ok(None),
        }
    }

    pub fn invalidate_cache(&self, key: &str) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM session_cache WHERE cache_key = ?1",
            params![key],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn clear_session_cache(&self) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM session_cache", []).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Debug Log
    // -------------------------------------------------------------------

    pub fn log(&self, level: &str, tag: &str, message: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO debug_log (level, tag, message) VALUES (?1, ?2, ?3)",
            params![level, tag, message],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_logs(&self, limit: u32) -> Result<Vec<(i64, String, String, String, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp, level, tag, message FROM debug_log ORDER BY id DESC LIMIT ?1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?,
                row.get::<_, String>(3)?, row.get::<_, String>(4)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn clear_logs(&self) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM debug_log", []).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Request Audit Log
    // -------------------------------------------------------------------

    /// Insert drained request records; caps the table at 2000 rows.
    #[allow(clippy::type_complexity)]
    pub fn insert_request_logs(
        &self,
        records: &[(u64, String, String, u16, u64, u64, u64, Option<String>, Option<String>)],
    ) -> Result<(), AppError> {
        for (started, method, url, status, dur, req_b, resp_b, error, payload) in records {
            self.conn.execute(
                "INSERT INTO request_log
                 (started_ms, method, url, status, duration_ms, req_bytes, resp_bytes, error, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![*started as i64, method, url, *status as i64, *dur as i64,
                        *req_b as i64, *resp_b as i64, error, payload],
            ).map_err(map_sql)?;
        }
        if !records.is_empty() {
            self.conn.execute(
                "DELETE FROM request_log WHERE id NOT IN
                 (SELECT id FROM request_log ORDER BY id DESC LIMIT 2000)",
                [],
            ).map_err(map_sql)?;
        }
        Ok(())
    }

    #[allow(clippy::type_complexity)]
    pub fn get_request_logs(
        &self,
        limit: u32,
    ) -> Result<Vec<(i64, u64, String, String, u16, u64, u64, u64, Option<String>, Option<String>)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, started_ms, method, url, status, duration_ms, req_bytes, resp_bytes, error, payload
             FROM request_log ORDER BY id DESC LIMIT ?1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)? as u64,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)? as u16,
                row.get::<_, i64>(5)? as u64,
                row.get::<_, i64>(6)? as u64,
                row.get::<_, i64>(7)? as u64,
                row.get::<_, Option<String>>(8)?,
                row.get::<_, Option<String>>(9)?,
            ))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn clear_request_logs(&self) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM request_log", []).map_err(map_sql)?;
        Ok(())
    }

    pub fn dump_logs(&self, limit: u32) -> Result<String, AppError> {
        let logs = self.get_logs(limit)?;
        let mut output = String::new();
        for (id, ts, level, tag, msg) in logs.iter().rev() {
            output.push_str(&format!("[{}] {} [{}] {}: {}\n", id, ts, level, tag, msg));
        }
        Ok(output)
    }

    // -------------------------------------------------------------------
    // Custom Themes
    // -------------------------------------------------------------------

    pub fn save_theme(&self, id: &str, name: &str, json: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO custom_themes (id, name, theme_json, updated_at)
             VALUES (?1, ?2, ?3, datetime('now'))",
            params![id, name, json],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_all_themes(&self) -> Result<Vec<(String, String, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, theme_json FROM custom_themes ORDER BY created_at ASC"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    pub fn delete_theme(&self, id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM custom_themes WHERE id = ?1",
            params![id],
        ).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Cleanup — purge chapters for works that aren't downloaded or currently reading
    // -------------------------------------------------------------------

    pub fn purge_non_retained_chapters(&self, current_work_id: Option<u64>) -> Result<(), AppError> {
        let current = current_work_id.unwrap_or(0) as i64;
        self.conn.execute(
            "DELETE FROM chapters WHERE work_id NOT IN (SELECT work_id FROM downloads) AND work_id != ?1",
            params![current],
        ).map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------

    fn create_tables(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS works (
                    id              INTEGER PRIMARY KEY,
                    title           TEXT NOT NULL,
                    authors_json    TEXT NOT NULL,
                    fandoms_json    TEXT NOT NULL,
                    rating          TEXT NOT NULL,
                    warnings_json   TEXT NOT NULL,
                    categories_json TEXT NOT NULL,
                    relationships_json TEXT NOT NULL,
                    characters_json TEXT NOT NULL,
                    tags_json       TEXT NOT NULL,
                    summary         TEXT NOT NULL,
                    word_count      INTEGER NOT NULL,
                    chapter_count   INTEGER NOT NULL,
                    total_chapters  INTEGER,
                    kudos           INTEGER NOT NULL,
                    hits            INTEGER NOT NULL,
                    bookmarks       INTEGER NOT NULL,
                    comments        INTEGER NOT NULL,
                    date_updated    TEXT NOT NULL,
                    language        TEXT NOT NULL,
                    complete        INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS chapters (
                    work_id      INTEGER NOT NULL,
                    number       INTEGER NOT NULL,
                    chapter_id   INTEGER,
                    title        TEXT,
                    content_json TEXT NOT NULL,
                    notes_before TEXT,
                    notes_after  TEXT,
                    PRIMARY KEY (work_id, number)
                );

                CREATE TABLE IF NOT EXISTS reading_progress (
                    work_id    INTEGER PRIMARY KEY,
                    chapter    INTEGER NOT NULL,
                    position   REAL NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS bookmarks (
                    account_id TEXT NOT NULL DEFAULT '',
                    work_id    INTEGER NOT NULL,
                    note       TEXT DEFAULT '',
                    sync_to_ao3 INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (account_id, work_id)
                );

                CREATE TABLE IF NOT EXISTS history (
                    work_id     INTEGER NOT NULL,
                    accessed_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE INDEX IF NOT EXISTS idx_history_accessed
                    ON history (accessed_at DESC);

                CREATE TABLE IF NOT EXISTS downloads (
                    work_id     INTEGER PRIMARY KEY,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS saved_searches (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    name        TEXT NOT NULL,
                    params_json TEXT NOT NULL,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS app_state (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS accounts (
                    id          TEXT PRIMARY KEY,
                    username    TEXT NOT NULL,
                    password    TEXT NOT NULL DEFAULT '',
                    cookies     TEXT NOT NULL DEFAULT '',
                    is_active   INTEGER NOT NULL DEFAULT 0,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts(username);

                CREATE TABLE IF NOT EXISTS reading_lists (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    name        TEXT NOT NULL,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS reading_list_items (
                    list_id     INTEGER NOT NULL,
                    work_id     INTEGER NOT NULL,
                    added_at    TEXT NOT NULL DEFAULT (datetime('now')),
                    sort_order  INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (list_id, work_id),
                    FOREIGN KEY (list_id) REFERENCES reading_lists(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS subscription_snapshots (
                    sub_type      TEXT NOT NULL,
                    sub_id        TEXT NOT NULL,
                    work_id       INTEGER NOT NULL,
                    chapter_count INTEGER NOT NULL,
                    word_count    INTEGER NOT NULL,
                    date_updated  TEXT NOT NULL,
                    PRIMARY KEY (sub_type, sub_id, work_id)
                );

                CREATE TABLE IF NOT EXISTS notifications (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    notif_type  TEXT NOT NULL,
                    work_id     INTEGER NOT NULL,
                    author      TEXT NOT NULL,
                    title       TEXT NOT NULL,
                    message     TEXT NOT NULL,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                    read        INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS session_cache (
                    cache_key   TEXT PRIMARY KEY,
                    data_json   TEXT NOT NULL,
                    session_id  TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS debug_log (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp   TEXT NOT NULL DEFAULT (datetime('now')),
                    level       TEXT NOT NULL,
                    tag         TEXT NOT NULL,
                    message     TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS request_log (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_ms  INTEGER NOT NULL,
                    method      TEXT NOT NULL,
                    url         TEXT NOT NULL,
                    status      INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    req_bytes   INTEGER NOT NULL,
                    resp_bytes  INTEGER NOT NULL,
                    error       TEXT,
                    payload     TEXT
                );

                CREATE TABLE IF NOT EXISTS custom_themes (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    theme_json  TEXT NOT NULL,
                    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );
                ",
            )
            .map_err(map_sql)?;

        self.conn
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS ao3_users (
                    id          TEXT PRIMARY KEY,
                    username    TEXT NOT NULL,
                    profile_url TEXT NOT NULL DEFAULT '',
                    avatar_url  TEXT NOT NULL DEFAULT '',
                    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_ao3_users_username ON ao3_users(username);

                CREATE TABLE IF NOT EXISTS comments (
                    id              INTEGER PRIMARY KEY,
                    work_id         INTEGER NOT NULL DEFAULT 0,
                    chapter_id      INTEGER NOT NULL DEFAULT 0,
                    parent_id       INTEGER NOT NULL DEFAULT 0,
                    author_id       TEXT NOT NULL,
                    posted_at       TEXT NOT NULL DEFAULT '',
                    content_json    TEXT NOT NULL DEFAULT '[]',
                    cached_at       TEXT NOT NULL DEFAULT (datetime('now')),
                    FOREIGN KEY (author_id) REFERENCES ao3_users(id)
                );
                CREATE INDEX IF NOT EXISTS idx_comments_work ON comments(work_id);
                CREATE INDEX IF NOT EXISTS idx_comments_chapter ON comments(chapter_id);
                CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id);
                ",
            )
            .map_err(map_sql)?;

        // Migration: add ao3_bookmark_id column (idempotent — .ok() for existing dbs)
        self.conn
            .execute(
                "ALTER TABLE bookmarks ADD COLUMN ao3_bookmark_id INTEGER",
                [],
            )
            .ok();

        // Migration: add account_id column to bookmarks (idempotent)
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN account_id TEXT NOT NULL DEFAULT ''", []).ok();

        Ok(())
    }

    /// Map a row from the `works` SELECT into a `WorkSummary`.
    /// Column order must match the SELECT used by get_work / get_all_works.
    fn work_from_row(row: &rusqlite::Row<'_>) -> Result<WorkSummary, rusqlite::Error> {
        let id: i64 = row.get(0)?;
        let title: String = row.get(1)?;
        let authors_json: String = row.get(2)?;
        let fandoms_json: String = row.get(3)?;
        let rating_str: String = row.get(4)?;
        let warnings_json: String = row.get(5)?;
        let categories_json: String = row.get(6)?;
        let relationships_json: String = row.get(7)?;
        let characters_json: String = row.get(8)?;
        let tags_json: String = row.get(9)?;
        let summary: String = row.get(10)?;
        let word_count: i64 = row.get(11)?;
        let chapter_count: i64 = row.get(12)?;
        let total_chapters: Option<i64> = row.get(13)?;
        let kudos: i64 = row.get(14)?;
        let hits: i64 = row.get(15)?;
        let bookmarks: i64 = row.get(16)?;
        let comments: i64 = row.get(17)?;
        let date_updated: String = row.get(18)?;
        let language: String = row.get(19)?;
        let complete: i32 = row.get(20)?;

        // Deserialize JSON columns — use unwrap_or_default so a corrupted
        // row doesn't crash the whole query; the caller can still surface the
        // remaining intact fields.
        let authors: Vec<String> =
            serde_json::from_str(&authors_json).unwrap_or_default();
        let fandoms: Vec<String> =
            serde_json::from_str(&fandoms_json).unwrap_or_default();
        let warnings: Vec<Warning> =
            serde_json::from_str(&warnings_json).unwrap_or_default();
        let categories: Vec<String> =
            serde_json::from_str(&categories_json).unwrap_or_default();
        let relationships: Vec<String> =
            serde_json::from_str(&relationships_json).unwrap_or_default();
        let characters: Vec<String> =
            serde_json::from_str(&characters_json).unwrap_or_default();
        let tags: Vec<String> =
            serde_json::from_str(&tags_json).unwrap_or_default();

        Ok(WorkSummary {
            id: id as u64,
            title,
            authors,
            fandoms,
            rating: str_to_rating(&rating_str),
            warnings,
            categories,
            relationships,
            characters,
            tags,
            summary,
            word_count: word_count as u64,
            chapter_count: chapter_count as u32,
            total_chapters: total_chapters.map(|c| c as u32),
            kudos: kudos as u32,
            hits: hits as u64,
            bookmarks: bookmarks as u32,
            comments: comments as u32,
            date_updated,
            language,
            complete: complete != 0,
        })
    }

    /// Map a row from the `chapters` SELECT into a `Chapter`.
    fn chapter_from_row(row: &rusqlite::Row<'_>) -> Result<Chapter, rusqlite::Error> {
        let chapter_id: Option<i64> = row.get(0)?;
        let title: Option<String> = row.get(1)?;
        let number: i64 = row.get(2)?;
        let content_json: String = row.get(3)?;
        let notes_before: Option<String> = row.get(4)?;
        let notes_after: Option<String> = row.get(5)?;

        let content: Vec<ContentBlock> =
            serde_json::from_str(&content_json).unwrap_or_default();

        Ok(Chapter {
            id: chapter_id.map(|i| i as u64),
            title,
            number: number as u32,
            content,
            notes_before,
            notes_after,
        })
    }

    // -- Accounts -------------------------------------------------------------

    pub fn create_account(&self, id: &str, username: &str, cookies: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO accounts (id, username, password, cookies) VALUES (?1, ?2, '', ?3)",
            params![id, username, cookies],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn set_active_account(&self, id: &str) -> Result<(), AppError> {
        self.conn.execute("UPDATE accounts SET is_active = 0", []).map_err(map_sql)?;
        self.conn.execute("UPDATE accounts SET is_active = 1 WHERE id = ?1", params![id]).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_active_account(&self) -> Result<Option<(String, String, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, username, cookies FROM accounts WHERE is_active = 1"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map([], |row| {
            Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,String>(2)?))
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(r)) => Ok(Some(r)),
            _ => Ok(None),
        }
    }

    pub fn get_all_accounts(&self) -> Result<Vec<(String, String, bool)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, username, is_active FROM accounts ORDER BY created_at"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,i64>(2)? != 0))
        }).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn update_account_cookies(&self, id: &str, cookies: &str) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE accounts SET cookies = ?2 WHERE id = ?1",
            params![id, cookies],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn clear_account_cookies(&self, id: &str) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE accounts SET cookies = '' WHERE id = ?1",
            params![id],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn delete_account(&self, id: &str) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM accounts WHERE id = ?1", params![id]).map_err(map_sql)?;
        Ok(())
    }

    pub fn migrate_legacy_credentials(&self) -> Result<Option<String>, AppError> {
        // Clear any stored passwords from existing accounts
        self.conn.execute("UPDATE accounts SET password = ''", []).map_err(map_sql)?;

        let username = self.get_state("ao3_username")?;
        let cookies = self.get_state("ao3_session_cookies")?;

        if let Some(ref u) = username {
            if !u.is_empty() {
                let id = format!("migrated-{}", u);
                let c = cookies.unwrap_or_default();
                self.create_account(&id, u, &c)?;
                self.set_active_account(&id)?;
                self.set_state("ao3_username", "")?;
                self.set_state("ao3_password", "")?;
                self.set_state("ao3_session_cookies", "")?;
                return Ok(Some(id));
            }
        }
        Ok(None)
    }

    // -- Comments -------------------------------------------------------------

    pub fn save_comment(&self, work_id: u64, chapter_id: u64, comment: &Comment) -> Result<(), AppError> {
        self.save_comment_recursive(work_id, chapter_id, 0, comment)
    }

    pub fn upsert_ao3_user(&self, user: &AO3User) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO ao3_users (id, username, profile_url, avatar_url)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
                username = excluded.username,
                profile_url = excluded.profile_url,
                avatar_url = CASE WHEN excluded.avatar_url = '' THEN ao3_users.avatar_url ELSE excluded.avatar_url END,
                updated_at = datetime('now')",
            params![
                user.id,
                user.username,
                user.profile_url.as_deref().unwrap_or(""),
                user.avatar_url.as_deref().unwrap_or(""),
            ],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_ao3_user(&self, user_id: &str) -> Result<Option<AO3User>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, username, profile_url, avatar_url FROM ao3_users WHERE id = ?1"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![user_id], |row| {
            let id: String = row.get(0)?;
            let username: String = row.get(1)?;
            let profile_url: String = row.get(2)?;
            let avatar_url: String = row.get(3)?;
            Ok(AO3User {
                id,
                username,
                profile_url: if profile_url.is_empty() { None } else { Some(profile_url) },
                avatar_url: if avatar_url.is_empty() { None } else { Some(avatar_url) },
            })
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(u)) => Ok(Some(u)),
            _ => Ok(None),
        }
    }

    fn save_comment_recursive(&self, work_id: u64, chapter_id: u64, parent_id: u64, comment: &Comment) -> Result<(), AppError> {
        self.upsert_ao3_user(&comment.author)?;

        let content_json = serde_json::to_string(&comment.content).map_err(map_json)?;
        self.conn.execute(
            "INSERT OR REPLACE INTO comments (id, work_id, chapter_id, parent_id, author_id, posted_at, content_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                comment.id as i64,
                work_id as i64,
                chapter_id as i64,
                parent_id as i64,
                comment.author.id,
                comment.posted_at,
                content_json,
            ],
        ).map_err(map_sql)?;

        for reply in &comment.replies {
            self.save_comment_recursive(work_id, chapter_id, comment.id, reply)?;
        }
        Ok(())
    }

    pub fn get_comments(&self, work_id: u64, chapter_id: u64) -> Result<Vec<Comment>, AppError> {
        let (where_clause, param_val): (&str, i64) = if chapter_id > 0 {
            ("chapter_id = ?1", chapter_id as i64)
        } else {
            ("work_id = ?1", work_id as i64)
        };
        let sql = format!(
            "SELECT c.id, c.posted_at, c.content_json, c.parent_id,
                    u.id, u.username, u.profile_url, u.avatar_url
             FROM comments c
             LEFT JOIN ao3_users u ON c.author_id = u.id
             WHERE c.{} ORDER BY c.id",
            where_clause
        );
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows: Vec<(i64, String, String, i64, String, String, String, String)> = stmt
            .query_map(params![param_val], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?,
                    row.get::<_, String>(4).unwrap_or_default(),
                    row.get::<_, String>(5).unwrap_or_default(),
                    row.get::<_, String>(6).unwrap_or_default(),
                    row.get::<_, String>(7).unwrap_or_default()))
            })
            .map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();

        let mut all: Vec<(Comment, u64)> = rows.into_iter().map(|(id, posted_at, content_json, parent_id, user_id, username, profile_url, avatar_url)| {
            let content: Vec<ContentBlock> = serde_json::from_str(&content_json).unwrap_or_default();
            let c = Comment {
                id: id as u64,
                author: AO3User {
                    id: user_id,
                    username: if username.is_empty() { "Anonymous".to_string() } else { username },
                    profile_url: if profile_url.is_empty() { None } else { Some(profile_url) },
                    avatar_url: if avatar_url.is_empty() { None } else { Some(avatar_url) },
                },
                posted_at,
                content,
                replies: Vec::new(),
            };
            (c, parent_id as u64)
        }).collect();

        // Build tree: collect replies under their parents
        let ids: Vec<u64> = all.iter().map(|(c, _)| c.id).collect();
        let mut top_level = Vec::new();

        // Two-pass: first extract all, then nest
        // Use indices to avoid borrow issues
        let mut comments_map: std::collections::HashMap<u64, Comment> = std::collections::HashMap::new();
        let mut parent_map: Vec<(u64, u64)> = Vec::new();

        for (c, parent_id) in all.drain(..) {
            parent_map.push((c.id, parent_id));
            comments_map.insert(c.id, c);
        }

        // Process in reverse order so children are added before parents try to collect them
        let mut children_map: std::collections::HashMap<u64, Vec<Comment>> = std::collections::HashMap::new();
        for &(id, parent_id) in parent_map.iter().rev() {
            let mut comment = comments_map.remove(&id).unwrap();
            if let Some(children) = children_map.remove(&id) {
                comment.replies = children;
            }
            if parent_id == 0 || !ids.contains(&parent_id) {
                top_level.push(comment);
            } else {
                children_map.entry(parent_id).or_default().push(comment);
            }
        }

        top_level.reverse();
        Ok(top_level)
    }

    pub fn clear_comments(&self, work_id: u64, chapter_id: u64) -> Result<(), AppError> {
        if chapter_id > 0 {
            self.conn.execute("DELETE FROM comments WHERE chapter_id = ?1", params![chapter_id as i64]).map_err(map_sql)?;
        } else {
            self.conn.execute("DELETE FROM comments WHERE work_id = ?1", params![work_id as i64]).map_err(map_sql)?;
        }
        Ok(())
    }
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{ContentBlock, InlineContent, Rating, Warning};

    fn sample_work(id: u64) -> WorkSummary {
        WorkSummary {
            id,
            title: format!("Test Work {id}"),
            authors: vec!["Author1".into(), "Author2".into()],
            fandoms: vec!["Fandom A".into()],
            rating: Rating::Teen,
            warnings: vec![Warning::None],
            categories: vec!["F/M".into()],
            relationships: vec!["A/B".into()],
            characters: vec!["Character A".into()],
            tags: vec!["Fluff".into(), "Angst".into()],
            summary: "A test summary".into(),
            word_count: 12_345,
            chapter_count: 3,
            total_chapters: Some(10),
            kudos: 42,
            hits: 1000,
            bookmarks: 5,
            comments: 8,
            date_updated: "2025-01-15".into(),
            language: "English".into(),
            complete: false,
        }
    }

    fn sample_chapter(number: u32) -> Chapter {
        Chapter {
            id: Some(900 + number as u64),
            title: Some(format!("Chapter {number}")),
            number,
            content: vec![
                ContentBlock::Heading {
                    level: 1,
                    text: format!("Chapter {number} Title"),
                },
                ContentBlock::Paragraph {
                    text: vec![InlineContent::Text {
                        value: "Hello world.".into(),
                    }],
                },
            ],
            notes_before: Some("Start notes".into()),
            notes_after: None,
        }
    }

    fn open_test_db() -> Storage {
        Storage::open_in_memory("test-passphrase").expect("open in-memory db")
    }

    #[test]
    fn test_save_and_load_work() {
        let db = open_test_db();
        let work = sample_work(42);

        db.save_work(&work).expect("save_work");

        // Retrieve by id
        let loaded = db.get_work(42).expect("get_work").expect("should exist");
        assert_eq!(loaded.id, work.id);
        assert_eq!(loaded.title, work.title);
        assert_eq!(loaded.authors, work.authors);
        assert_eq!(loaded.fandoms, work.fandoms);
        assert_eq!(loaded.rating, work.rating);
        assert_eq!(loaded.warnings, work.warnings);
        assert_eq!(loaded.categories, work.categories);
        assert_eq!(loaded.relationships, work.relationships);
        assert_eq!(loaded.characters, work.characters);
        assert_eq!(loaded.tags, work.tags);
        assert_eq!(loaded.summary, work.summary);
        assert_eq!(loaded.word_count, work.word_count);
        assert_eq!(loaded.chapter_count, work.chapter_count);
        assert_eq!(loaded.total_chapters, work.total_chapters);
        assert_eq!(loaded.kudos, work.kudos);
        assert_eq!(loaded.hits, work.hits);
        assert_eq!(loaded.bookmarks, work.bookmarks);
        assert_eq!(loaded.comments, work.comments);
        assert_eq!(loaded.date_updated, work.date_updated);
        assert_eq!(loaded.language, work.language);
        assert_eq!(loaded.complete, work.complete);

        // get_all_works
        let work2 = sample_work(99);
        db.save_work(&work2).expect("save second work");
        let all = db.get_all_works().expect("get_all_works");
        assert_eq!(all.len(), 2);

        // Missing work
        assert!(db.get_work(9999).expect("get missing").is_none());

        // Delete cascades
        db.save_chapter(42, &sample_chapter(1)).unwrap();
        db.save_progress(42, 1, 0.5).unwrap();
        db.add_bookmark(42, None, false).unwrap();
        db.add_to_history(42).unwrap();

        db.delete_work(42).expect("delete_work");
        assert!(db.get_work(42).expect("after delete").is_none());
        assert!(db.get_chapters(42).expect("chapters after delete").is_empty());
        assert!(db.get_progress(42).expect("progress after delete").is_none());
        assert!(!db.is_bookmarked(42).expect("bookmark after delete"));
        assert!(db.get_history().expect("history after delete").is_empty());
    }

    #[test]
    fn test_chapters() {
        let db = open_test_db();
        let work = sample_work(1);
        db.save_work(&work).unwrap();

        let ch1 = sample_chapter(1);
        let ch2 = sample_chapter(2);
        db.save_chapter(1, &ch1).unwrap();
        db.save_chapter(1, &ch2).unwrap();

        let chapters = db.get_chapters(1).unwrap();
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].number, 1);
        assert_eq!(chapters[1].number, 2);
        assert_eq!(chapters[0].content.len(), 2); // Heading + Paragraph

        // Single chapter lookup
        let single = db.get_chapter(1, 2).unwrap().unwrap();
        assert_eq!(single.number, 2);
        assert_eq!(single.title.as_deref(), Some("Chapter 2"));

        // Missing chapter
        assert!(db.get_chapter(1, 99).unwrap().is_none());

        // Overwrite existing chapter
        let mut ch1_updated = sample_chapter(1);
        ch1_updated.title = Some("Updated Title".into());
        db.save_chapter(1, &ch1_updated).unwrap();
        let reloaded = db.get_chapter(1, 1).unwrap().unwrap();
        assert_eq!(reloaded.title.as_deref(), Some("Updated Title"));
    }

    #[test]
    fn test_bookmarks() {
        let db = open_test_db();

        assert!(!db.is_bookmarked(1).unwrap());
        assert!(db.get_bookmarks().unwrap().is_empty());

        db.add_bookmark(1, Some("great fic"), false).unwrap();
        assert!(db.is_bookmarked(1).unwrap());

        db.add_bookmark(2, None, false).unwrap();
        let bm = db.get_bookmarks().unwrap();
        assert_eq!(bm.len(), 2);

        db.remove_bookmark(1).unwrap();
        assert!(!db.is_bookmarked(1).unwrap());
        assert_eq!(db.get_bookmarks().unwrap().len(), 1);
    }

    #[test]
    fn test_reading_progress() {
        let db = open_test_db();

        assert!(db.get_progress(1).unwrap().is_none());

        db.save_progress(1, 3, 0.75).unwrap();
        let (ch, pos) = db.get_progress(1).unwrap().unwrap();
        assert_eq!(ch, 3);
        assert!((pos - 0.75).abs() < f64::EPSILON);

        // Overwrite
        db.save_progress(1, 4, 0.1).unwrap();
        let (ch2, pos2) = db.get_progress(1).unwrap().unwrap();
        assert_eq!(ch2, 4);
        assert!((pos2 - 0.1).abs() < f64::EPSILON);
    }

    #[test]
    fn test_history() {
        let db = open_test_db();
        assert!(db.get_history().unwrap().is_empty());

        db.add_to_history(10).unwrap();
        db.add_to_history(20).unwrap();
        db.add_to_history(10).unwrap(); // duplicate — allowed

        let hist = db.get_history().unwrap();
        assert_eq!(hist.len(), 3);
        // Most recent first
        assert_eq!(hist[0].0, 10);
        assert_eq!(hist[1].0, 20);
        assert_eq!(hist[2].0, 10);

        db.clear_history().unwrap();
        assert!(db.get_history().unwrap().is_empty());
    }

    #[test]
    fn test_subscription_snapshots() {
        let db = open_test_db();

        // Initially empty
        let snaps = db.get_snapshots("author", "testuser").unwrap();
        assert!(snaps.is_empty());

        // Save some snapshots
        db.save_snapshot("author", "testuser", 100, 5, 10000, "2025-01-15").unwrap();
        db.save_snapshot("author", "testuser", 200, 3, 5000, "2025-02-01").unwrap();

        let snaps = db.get_snapshots("author", "testuser").unwrap();
        assert_eq!(snaps.len(), 2);

        // Find the work 100 snapshot
        let w100 = snaps.iter().find(|s| s.0 == 100).unwrap();
        assert_eq!(w100.1, 5);   // chapter_count
        assert_eq!(w100.2, 10000); // word_count
        assert_eq!(w100.3, "2025-01-15");

        // Update existing snapshot (INSERT OR REPLACE)
        db.save_snapshot("author", "testuser", 100, 7, 15000, "2025-03-01").unwrap();
        let snaps = db.get_snapshots("author", "testuser").unwrap();
        assert_eq!(snaps.len(), 2); // still 2, not 3
        let w100 = snaps.iter().find(|s| s.0 == 100).unwrap();
        assert_eq!(w100.1, 7); // updated chapter_count

        // Different sub_type/sub_id is separate
        let snaps2 = db.get_snapshots("work", "100").unwrap();
        assert!(snaps2.is_empty());
    }

    #[test]
    fn test_notifications() {
        let db = open_test_db();

        // Initially empty
        assert_eq!(db.get_unread_count().unwrap(), 0);
        assert!(db.get_notifications().unwrap().is_empty());

        // Add notifications
        let id1 = db.add_notification("new_work", 100, "author1", "Work Title", "New work posted").unwrap();
        let id2 = db.add_notification("new_chapter", 200, "author2", "Another Work", "Chapter 5 added").unwrap();
        assert!(id1 > 0);
        assert!(id2 > 0);
        assert_ne!(id1, id2);

        // Check counts
        assert_eq!(db.get_unread_count().unwrap(), 2);

        // Get all notifications
        let notifs = db.get_notifications().unwrap();
        assert_eq!(notifs.len(), 2);

        // Find the new_chapter notification (order may vary when created_at is identical)
        let n2 = notifs.iter().find(|n| n.0 == id2).unwrap();
        assert_eq!(n2.1, "new_chapter");
        assert_eq!(n2.2, 200);
        assert_eq!(n2.3, "author2");
        assert_eq!(n2.4, "Another Work");
        assert_eq!(n2.5, "Chapter 5 added");
        assert!(!n2.7); // not read

        // Mark one as read
        db.mark_notification_read(id1).unwrap();
        assert_eq!(db.get_unread_count().unwrap(), 1);
        let notifs = db.get_notifications().unwrap();
        let n1 = notifs.iter().find(|n| n.0 == id1).unwrap();
        assert!(n1.7); // read

        // Mark all as read
        db.mark_all_read().unwrap();
        assert_eq!(db.get_unread_count().unwrap(), 0);

        // Clear read notifications
        db.clear_read_notifications().unwrap();
        assert!(db.get_notifications().unwrap().is_empty());
    }

    #[test]
    fn test_custom_themes() {
        let db = open_test_db();

        // Initially empty
        let themes = db.get_all_themes().unwrap();
        assert!(themes.is_empty());

        // Save a theme
        db.save_theme("theme-1", "My Theme", r#"{"bgColor":"FFF"}"#).unwrap();
        let themes = db.get_all_themes().unwrap();
        assert_eq!(themes.len(), 1);
        assert_eq!(themes[0].0, "theme-1");
        assert_eq!(themes[0].1, "My Theme");
        assert_eq!(themes[0].2, r#"{"bgColor":"FFF"}"#);

        // Save another theme
        db.save_theme("theme-2", "Dark Theme", r#"{"bgColor":"000"}"#).unwrap();
        let themes = db.get_all_themes().unwrap();
        assert_eq!(themes.len(), 2);

        // Update existing theme (INSERT OR REPLACE)
        db.save_theme("theme-1", "My Theme Updated", r#"{"bgColor":"EEE"}"#).unwrap();
        let themes = db.get_all_themes().unwrap();
        assert_eq!(themes.len(), 2);
        let t1 = themes.iter().find(|t| t.0 == "theme-1").unwrap();
        assert_eq!(t1.1, "My Theme Updated");
        assert_eq!(t1.2, r#"{"bgColor":"EEE"}"#);

        // Delete a theme
        db.delete_theme("theme-1").unwrap();
        let themes = db.get_all_themes().unwrap();
        assert_eq!(themes.len(), 1);
        assert_eq!(themes[0].0, "theme-2");

        // Delete non-existent theme (no error)
        db.delete_theme("nonexistent").unwrap();
    }

    #[test]
    fn test_last_check_time() {
        let db = open_test_db();

        // Initially none
        assert!(db.get_last_check_time().unwrap().is_none());

        // Set it
        db.set_last_check_time("2025-06-01T12:00:00Z").unwrap();
        assert_eq!(
            db.get_last_check_time().unwrap().as_deref(),
            Some("2025-06-01T12:00:00Z")
        );

        // Update it
        db.set_last_check_time("2025-06-02T14:00:00Z").unwrap();
        assert_eq!(
            db.get_last_check_time().unwrap().as_deref(),
            Some("2025-06-02T14:00:00Z")
        );
    }
}
