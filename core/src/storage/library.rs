use rusqlite::params;

use crate::error::AppError;

use super::{map_sql, Storage};

impl Storage {
    /// Record the first time the user opened this work's detail view
    /// (unix-seconds string). First view wins — later opens keep the
    /// original timestamp. Kept out of `save_work` so listing upserts
    /// can't clobber it. No-op when the work has no row yet (only works
    /// discovered by crawls feed the What's New badge, and those always
    /// have blurb rows).
    pub fn mark_work_detail_viewed(&self, work_id: u64, at: &str) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE works SET detail_viewed_at = ?2
                 WHERE id = ?1 AND detail_viewed_at = ''",
                params![work_id as i64, at],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Stamp "the user just opened a chapter of this work" — every open
    /// overwrites, so the value is always the most recent read.
    pub fn mark_work_read(&self, work_id: u64) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE works SET last_read_dt = datetime('now') WHERE id = ?1",
                params![work_id as i64],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Last-read datetimes for every work that has one, as
    /// `(work_id, "YYYY-MM-DD HH:MM:SS")` — lexicographically sortable UTC.
    pub fn get_work_last_read_times(&self) -> Result<Vec<(u64, String)>, AppError> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, last_read_dt FROM works WHERE last_read_dt != ''")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                let at: String = row.get(1)?;
                Ok((id as u64, at))
            })
            .map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Ids of every work whose detail view has been opened at least once.
    pub fn get_detail_viewed_work_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self
            .conn
            .prepare("SELECT id FROM works WHERE detail_viewed_at != ''")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(map_sql)?;
        let mut ids = Vec::new();
        for r in rows {
            ids.push(r.map_err(map_sql)? as u64);
        }
        Ok(ids)
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

    /// Update the full AO3 bookmark object (notes, own tags, collections,
    /// private/rec flags).
    pub fn update_bookmark_details(&self, work_id: u64, note: &str, tag_string: &str,
                                   collection_names: &str, private: bool, rec: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.conn.execute(
            "UPDATE bookmarks SET note = ?3, tag_string = ?4, collection_names = ?5,
                                  private = ?6, rec = ?7
             WHERE account_id = ?1 AND work_id = ?2",
            params![acct, work_id as i64, note, tag_string, collection_names,
                    private as i32, rec as i32],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Full bookmark row: (note, tag_string, collection_names, private, rec,
    /// sync_to_ao3, ao3_bookmark_id).
    #[allow(clippy::type_complexity)]
    pub fn get_bookmark_details(&self, work_id: u64)
        -> Result<Option<(String, String, String, bool, bool, bool, Option<u64>)>, AppError> {
        let acct = self.active_account_id();
        let mut stmt = self.conn.prepare(
            "SELECT note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id
             FROM bookmarks WHERE account_id = ?1 AND work_id = ?2"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![acct, work_id as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i32>(3)? != 0,
                row.get::<_, i32>(4)? != 0,
                row.get::<_, i32>(5)? != 0,
                row.get::<_, Option<i64>>(6)?.map(|v| v as u64),
            ))
        }).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(v)) => Ok(Some(v)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
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
    // Saved searches
    // -------------------------------------------------------------------

    pub fn save_search(&self, name: &str, params_json: &str) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO saved_searches (name, params_json) VALUES (?1, ?2)
             ON CONFLICT(name COLLATE NOCASE) DO UPDATE
                 SET name = excluded.name, params_json = excluded.params_json",
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
    // Kudos (permanent on AO3 — recorded once, never removed)
    // -------------------------------------------------------------------

    pub fn mark_kudos_given(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR IGNORE INTO kudos_given (work_id) VALUES (?1)",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_kudos_given(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare("SELECT work_id FROM kudos_given").map_err(map_sql)?;
        let rows = stmt.query_map([], |row| row.get::<_, i64>(0)).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).map(|id| id as u64).collect())
    }
}
