use rusqlite::{params, OptionalExtension};

use crate::error::AppError;
use crate::models::{split_author_byline, AO3User, Comment, ContentBlock, UserProfile, SOURCE_AO3};

use super::consts::*;

pub type NotificationRow = (i64, String, u64, String, String, String, String, bool);
pub type LogRow = (i64, String, String, String, String);
pub type InboxRow = (u64, String, String, String, String, String, String, bool, String);
use super::users_cache::comment_byline;
use super::{map_json, map_sql, Storage};

/// One accounts row: a sign-in at one source. `external_id` is the
/// account's key at the source (the lowercased AO3 username); `username`
/// keeps the spelling the user signed in with.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountRow {
    pub id: i64,
    pub source: String,
    pub external_id: String,
    pub username: String,
    pub cookies: String,
    pub is_active: bool,
}

impl AccountRow {
    /// Logged in = the stored session carries the source's auth cookie;
    /// independent of which account is active.
    pub fn logged_in(&self) -> bool {
        crate::client::has_login_cookie(&self.cookies)
    }
}

impl Storage {
    /// Whether the app has an ao3_users row for this name — account
    /// username, "Pseud (account)" byline, or a recorded pseud. Answered
    /// from the users cache.
    pub fn has_ao3_user_with_username(&self, username: &str) -> Result<bool, AppError> {
        Ok(self.users_cache.has_user(username))
    }

    // -------------------------------------------------------------------
    // App state (key-value)
    // -------------------------------------------------------------------

    /// Write-through via the state cache — the single write authority for
    /// app_state.
    pub fn set_state(&self, key: &str, value: &str) -> Result<(), AppError> {
        self.state_cache.set(&self.conn, key, value)
    }

    /// Answered from the state cache — no SQL.
    pub fn get_state(&self, key: &str) -> Result<Option<String>, AppError> {
        Ok(self.state_cache.get(key))
    }

    // -------------------------------------------------------------------
    // Notifications
    // -------------------------------------------------------------------

    /// Add a notification to the database. Returns the new notification id.
    /// `ref_id` is whatever the notification is about — for inbox
    /// notifications, the AO3 comment number (the column keeps its
    /// historical name `work_id`).
    pub fn add_notification(
        &self,
        notif_type: &str,
        ref_id: u64,
        author: &str,
        title: &str,
        message: &str,
    ) -> Result<i64, AppError> {
        // Check for existing unread notification for same ref and type
        let existing: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM notifications WHERE notif_type = ?1 AND work_id = ?2 AND read = 0",
            params![notif_type, ref_id as i64],
            |row| row.get(0),
        ).unwrap_or(0);
        if existing > 0 {
            return Ok(-1);
        }

        self.conn
            .execute(
                "INSERT INTO notifications (notif_type, work_id, author, title, message)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![notif_type, ref_id as i64, author, title, message],
            )
            .map_err(map_sql)?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Get all notifications, most recent first.
    /// Returns Vec of (id, notif_type, ref_id, author, title, message, created_at, read).
    pub fn get_notifications(
        &self,
    ) -> Result<Vec<NotificationRow>, AppError> {
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
                let ref_id: i64 = row.get(2)?;
                let author: String = row.get(3)?;
                let title: String = row.get(4)?;
                let message: String = row.get(5)?;
                let created_at: String = row.get(6)?;
                let read: i32 = row.get(7)?;
                Ok((id, notif_type, ref_id as u64, author, title, message, created_at, read != 0))
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

    pub fn get_logs(&self, limit: u32) -> Result<Vec<LogRow>, AppError> {
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

    /// Insert drained request records; `max_rows` caps the table (oldest
    /// dropped), None = unlimited — the caller reads it from the
    /// request-log settings so the cap tracks the user's row limit.
    /// Each record names the source it was sent for.
    #[allow(clippy::type_complexity)]
    pub fn insert_request_logs(
        &self,
        records: &[(u64, String, String, u16, u64, u64, u64, Option<String>, Option<String>, Option<String>, String)],
        max_rows: Option<u64>,
    ) -> Result<(), AppError> {
        for (started, method, url, status, dur, req_b, resp_b, error, payload, transport, source) in records {
            self.conn.execute(
                "INSERT INTO request_log
                 (started_ms, method, url, status, duration_ms, req_bytes, resp_bytes, error, payload, transport, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![*started as i64, method, url, *status as i64, *dur as i64,
                        *req_b as i64, *resp_b as i64, error, payload, transport, source],
            ).map_err(map_sql)?;
        }
        if let Some(max) = max_rows.filter(|_| !records.is_empty()) {
            self.conn.execute(
                "DELETE FROM request_log WHERE id NOT IN
                 (SELECT id FROM request_log ORDER BY id DESC LIMIT ?1)",
                params![max as i64],
            ).map_err(map_sql)?;
        }
        Ok(())
    }

    /// Delete up to `batch` request-log rows started before `cutoff_ms`.
    /// Returns the count deleted; the upkeep task loops until 0, taking
    /// the storage lock per batch so other work interleaves.
    pub fn trim_request_logs_before(&self, cutoff_ms: i64, batch: u32) -> Result<usize, AppError> {
        self.conn.execute(
            "DELETE FROM request_log WHERE id IN
             (SELECT id FROM request_log WHERE started_ms < ?1 ORDER BY id LIMIT ?2)",
            params![cutoff_ms, batch as i64],
        ).map_err(map_sql)
    }

    /// Delete up to `batch` of the oldest request-log rows beyond
    /// `max_rows`. Returns the count deleted (0 = under the cap).
    pub fn trim_request_logs_over(&self, max_rows: u64, batch: u32) -> Result<usize, AppError> {
        let count: i64 = self.conn.query_row("SELECT COUNT(*) FROM request_log", [], |r| r.get(0))
            .map_err(map_sql)?;
        let excess = count - max_rows as i64;
        if excess <= 0 { return Ok(0); }
        self.conn.execute(
            "DELETE FROM request_log WHERE id IN
             (SELECT id FROM request_log ORDER BY id LIMIT ?1)",
            params![excess.min(batch as i64)],
        ).map_err(map_sql)
    }

    #[allow(clippy::type_complexity)]
    pub fn get_request_logs(
        &self,
        limit: u32,
    ) -> Result<Vec<(i64, u64, String, String, u16, u64, u64, u64, Option<String>, Option<String>, Option<String>, String)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, started_ms, method, url, status, duration_ms, req_bytes, resp_bytes, error, payload, transport, source
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
                row.get::<_, Option<String>>(10)?,
                row.get::<_, String>(11)?,
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

    // -- Accounts -------------------------------------------------------------
    //
    // One row per sign-in at a source, keyed by row id. "Active" is per
    // source (Area 1.2); account-scoped data keys on the row id, never
    // the username (Area 1.3).

    fn account_from_row(row: &rusqlite::Row<'_>) -> Result<AccountRow, rusqlite::Error> {
        Ok(AccountRow {
            id: row.get(0)?,
            source: row.get(1)?,
            external_id: row.get(2)?,
            username: row.get(3)?,
            cookies: row.get(4)?,
            is_active: row.get::<_, i64>(5)? != 0,
        })
    }

    const ACCOUNT_COLS: &'static str = "id, source, external_id, username, cookies, is_active";

    /// Create (or refresh the session of) the AO3 account for `username`
    /// — the same account signing in again reuses its row. AO3 bookmark
    /// records already cached under this username become the account's
    /// own. Returns the row id.
    pub fn create_account(&self, username: &str, cookies: &str) -> Result<i64, AppError> {
        let external_id = super::owner_key_for(username);
        self.conn.execute(
            "INSERT INTO accounts (source, external_id, username, cookies)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(source, external_id) DO UPDATE SET username = ?3, cookies = ?4",
            params![SOURCE_AO3, external_id, username.trim(), cookies],
        ).map_err(map_sql)?;
        let id: i64 = self.conn.query_row(
            "SELECT id FROM accounts WHERE source = ?1 AND external_id = ?2",
            params![SOURCE_AO3, external_id], |r| r.get(0),
        ).map_err(map_sql)?;
        self.ao3_bookmarks.claim_owner(&self.conn, &external_id, id)?;
        Ok(id)
    }

    /// Make `id` the active account of its source. Subscriptions are
    /// account data: activating a different account empties them (the
    /// new account's list loads on demand).
    pub fn set_active_account(&self, id: i64) -> Result<(), AppError> {
        let Some(target) = self.get_account(id)? else {
            return Err(AppError::StorageError(format!("no account with id {id}")));
        };
        let previous = self.get_active_account()?.map(|a| a.id);
        if previous != Some(id) {
            self.clear_subscriptions()?;
        }
        self.conn.execute("UPDATE accounts SET is_active = 0 WHERE source = ?1", params![target.source])
            .map_err(map_sql)?;
        self.conn.execute("UPDATE accounts SET is_active = 1 WHERE id = ?1", params![id])
            .map_err(map_sql)?;
        Ok(())
    }

    pub fn get_account(&self, id: i64) -> Result<Option<AccountRow>, AppError> {
        self.conn.query_row(
            &format!("SELECT {} FROM accounts WHERE id = ?1", Self::ACCOUNT_COLS),
            params![id], Self::account_from_row,
        ).optional().map_err(map_sql)
    }

    /// The active AO3 account (the only source with accounts today).
    pub fn get_active_account(&self) -> Result<Option<AccountRow>, AppError> {
        self.conn.query_row(
            &format!("SELECT {} FROM accounts WHERE source = ?1 AND is_active = 1", Self::ACCOUNT_COLS),
            params![SOURCE_AO3], Self::account_from_row,
        ).optional().map_err(map_sql)
    }

    fn is_active_account(&self, id: i64) -> Result<bool, AppError> {
        Ok(self.get_active_account()?.is_some_and(|a| a.id == id))
    }

    /// Every account, oldest first.
    pub fn get_all_accounts(&self) -> Result<Vec<AccountRow>, AppError> {
        let mut stmt = self.conn.prepare(
            &format!("SELECT {} FROM accounts ORDER BY created_at, id", Self::ACCOUNT_COLS)
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], Self::account_from_row).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// The AO3 account row for a username, if the user has signed in as
    /// it on this device.
    pub fn find_account(&self, username: &str) -> Result<Option<AccountRow>, AppError> {
        self.conn.query_row(
            &format!("SELECT {} FROM accounts WHERE source = ?1 AND external_id = ?2", Self::ACCOUNT_COLS),
            params![SOURCE_AO3, super::owner_key_for(username)], Self::account_from_row,
        ).optional().map_err(map_sql)
    }

    pub fn update_account_cookies(&self, id: i64, cookies: &str) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE accounts SET cookies = ?2 WHERE id = ?1",
            params![id, cookies],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Signing out. Signing the active account out empties subscriptions.
    pub fn clear_account_cookies(&self, id: i64) -> Result<(), AppError> {
        if self.is_active_account(id)? {
            self.clear_subscriptions()?;
        }
        self.conn.execute(
            "UPDATE accounts SET cookies = '' WHERE id = ?1",
            params![id],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Remove an account. Its subscriptions, drafts, and app bookmarks
    /// cascade away; its AO3 bookmark records stay as that user's cached
    /// bookmarks (the account link is cleared).
    pub fn delete_account(&self, id: i64) -> Result<(), AppError> {
        if self.is_active_account(id)? {
            self.clear_subscriptions()?;
        }
        self.conn.execute("DELETE FROM accounts WHERE id = ?1", params![id]).map_err(map_sql)?;
        // Cascades the caches hold: app flags gone, AO3 records unlinked.
        self.app_bookmarks.load(&self.conn)?;
        self.ao3_bookmarks.unlink_account(id);
        Ok(())
    }

    pub fn migrate_legacy_credentials(&self) -> Result<Option<i64>, AppError> {
        // Clear any stored passwords from existing accounts
        self.conn.execute("UPDATE accounts SET password = ''", []).map_err(map_sql)?;

        let username = self.get_state("ao3_username")?;
        let cookies = self.get_state("ao3_session_cookies")?;

        if let Some(ref u) = username {
            if !u.is_empty() {
                let c = cookies.unwrap_or_default();
                let id = self.create_account(u, &c)?;
                self.set_active_account(id)?;
                self.set_state("ao3_username", "")?;
                self.set_state("ao3_password", "")?;
                self.set_state("ao3_session_cookies", "")?;
                return Ok(Some(id));
            }
        }

        // The account row is the only home for a session. Older builds also
        // kept a copy in app_state (and saved there when no account was
        // active); hand a live one to the active account if its row has
        // none, then retire the key either way.
        if let Some(c) = cookies.filter(|c| !c.is_empty()) {
            if let Some(active) = self.get_active_account()? {
                if !active.logged_in() && crate::client::has_login_cookie(&c) {
                    self.update_account_cookies(active.id, &c)?;
                }
            }
            self.set_state("ao3_session_cookies", "")?;
        }
        Ok(None)
    }

    // -- Inbox persistence ---------------------------------------------------
    //
    // Inbox messages are keyed by row id with the AO3 comment number as
    // their external id; the API addresses them by that number.

    /// Whether an inbox message is already stored locally.
    pub fn has_inbox_message(&self, comment_id: u64) -> Result<bool, AppError> {
        let mut stmt = self.conn
            .prepare("SELECT 1 FROM inbox_messages WHERE source = ?1 AND external_id = ?2 LIMIT 1")
            .map_err(map_sql)?;
        stmt.exists(params![SOURCE_AO3, comment_id.to_string()]).map_err(map_sql)
    }

    pub fn save_inbox_messages(&self, items: &[crate::models::InboxItem]) -> Result<(), AppError> {
        let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO inbox_messages
                 (source, external_id, author, author_url, avatar_url, work_reference, work_url, posted_at,
                  is_unread, content_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(source, external_id) DO UPDATE SET
                     author = excluded.author, author_url = excluded.author_url,
                     avatar_url = excluded.avatar_url, work_reference = excluded.work_reference,
                     work_url = excluded.work_url, posted_at = excluded.posted_at,
                     is_unread = excluded.is_unread, content_json = excluded.content_json,
                     fetched_at = datetime('now')"
            ).map_err(map_sql)?;
            for item in items {
                let content_json = serde_json::to_string(&item.content).unwrap_or_else(|_| "[]".to_string());
                stmt.execute(params![
                    SOURCE_AO3,
                    item.comment_id.to_string(),
                    item.author,
                    item.author_url.as_deref().unwrap_or(""),
                    item.avatar_url.as_deref().unwrap_or(""),
                    item.work_reference,
                    item.work_url.as_deref().unwrap_or(""),
                    item.posted_at,
                    item.is_unread as i32,
                    content_json,
                ]).map_err(map_sql)?;
            }
        }
        tx.commit().map_err(map_sql)?;
        Ok(())
    }

    /// Cached inbox messages, newest comment first (AO3 comment numbers
    /// are sequential).
    pub fn get_inbox_messages(&self, page: u32, per_page: u32) -> Result<Vec<InboxRow>, AppError> {
        let offset = (page.saturating_sub(1)) * per_page;
        let mut stmt = self.conn.prepare(
            "SELECT external_id, author, author_url, avatar_url, work_reference, work_url, posted_at, is_unread, content_json
             FROM inbox_messages ORDER BY CAST(external_id AS INTEGER) DESC LIMIT ?1 OFFSET ?2"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![per_page, offset], |row| {
            let external: String = row.get(0)?;
            let is_unread: i32 = row.get(7)?;
            Ok((
                external.parse::<u64>().unwrap_or(0),
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                is_unread != 0,
                row.get::<_, String>(8)?,
            ))
        }).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn get_inbox_message_count(&self) -> Result<(u32, u32), AppError> {
        let total: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM inbox_messages", [], |row| row.get(0)
        ).unwrap_or(0);
        let unread: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM inbox_messages WHERE is_unread = 1", [], |row| row.get(0)
        ).unwrap_or(0);
        Ok((total, unread))
    }

    // -- Comment operations ---------------------------------------------------
    //
    // Comment rows are keyed by row id with the AO3 comment number as
    // their external id. The row id never leaves storage: comments are a
    // cache that is cleared and refetched, so the API addresses them by
    // AO3 number (`Comment.id`) and parents by row.

    /// Cache a comment tree under a work (row id) and chapter (AO3 chapter
    /// id, 0 = whole work). Top-level comments have no parent.
    pub fn save_comment(&self, work_id: u64, chapter_id: u64, comment: &Comment) -> Result<(), AppError> {
        self.save_comment_recursive(work_id, chapter_id, None, comment)
    }

    /// Re-save a cached comment (and its reply tree) in place: the row keeps
    /// the work/chapter/parent context it was first stored under, so new
    /// replies parsed from a thread page land in the same thread. None
    /// when the comment has never been cached.
    pub fn save_comment_in_place(&self, comment: &Comment) -> Result<bool, AppError> {
        let Some((work_id, chapter_id, parent_row)) = self.comment_row_context(comment.id)? else {
            return Ok(false);
        };
        self.save_comment_recursive(work_id, chapter_id, parent_row, comment)?;
        Ok(true)
    }

    /// Row id of a cached comment by AO3 number.
    fn comment_row_id(&self, comment_id: u64) -> Result<Option<i64>, AppError> {
        self.conn.query_row(
            "SELECT id FROM comments WHERE source = ?1 AND external_id = ?2",
            params![SOURCE_AO3, comment_id.to_string()],
            |row| row.get(0),
        ).optional().map_err(map_sql)
    }

    /// (work row id, chapter id, parent row id) of a cached comment.
    fn comment_row_context(&self, comment_id: u64) -> Result<Option<(u64, u64, Option<i64>)>, AppError> {
        self.conn.query_row(
            "SELECT work_id, chapter_id, parent_id FROM comments WHERE source = ?1 AND external_id = ?2",
            params![SOURCE_AO3, comment_id.to_string()],
            |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, i64>(1)? as u64,
                      row.get::<_, Option<i64>>(2)?)),
        ).optional().map_err(map_sql)
    }

    /// (work row id, chapter id, parent AO3 comment number — 0 when top
    /// level) of a cached comment.
    pub fn comment_context(&self, comment_id: u64) -> Result<Option<(u64, u64, u64)>, AppError> {
        self.conn.query_row(
            "SELECT c.work_id, c.chapter_id, COALESCE(p.external_id, '0')
             FROM comments c LEFT JOIN comments p ON p.id = c.parent_id
             WHERE c.source = ?1 AND c.external_id = ?2",
            params![SOURCE_AO3, comment_id.to_string()],
            |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, i64>(1)? as u64,
                      row.get::<_, String>(2)?.parse::<u64>().unwrap_or(0))),
        ).optional().map_err(map_sql)
    }

    /// Record a sighting of an AO3 user. `user.username` is the byline as
    /// AO3 rendered it — "Pseud (account)" folds into the account's single
    /// row and teaches it the pseud. Write-through via the users cache.
    pub fn upsert_ao3_user(&self, user: &AO3User) -> Result<(), AppError> {
        self.users_cache.record(&self.conn, user, &crate::timefmt::now_utc_datetime())
            .map(|_| ())
    }

    /// Record author bylines seen on AO3 data (work blurbs, bookmarks,
    /// series pages): ensures each account row and learns any pseud.
    pub fn record_author_bylines(&self, bylines: &[String]) -> Result<(), AppError> {
        let now = crate::timefmt::now_utc_datetime();
        for b in bylines {
            self.users_cache.record_byline(&self.conn, b, &now)?;
        }
        Ok(())
    }

    /// The users row id for any name form (account username, byline, or
    /// recorded pseud), creating the account row when it has never been
    /// seen. Follows and crawl stamps point at this.
    pub fn ensure_user_row(&self, name: &str) -> Result<Option<i64>, AppError> {
        Ok(self.users_cache
            .record_byline(&self.conn, name, &crate::timefmt::now_utc_datetime())?
            .map(|e| e.id))
    }

    /// The users row id for a name the library already knows; None when
    /// never seen.
    pub fn user_row_id(&self, name: &str) -> Option<i64> {
        self.users_cache.resolve(name).map(|e| e.id)
    }

    /// The account username behind a users row id.
    pub fn user_name_for_row(&self, id: i64) -> Option<String> {
        self.users_cache.get(id).map(|e| e.username.clone())
    }

    /// The account for any name form (account username, byline, pseud,
    /// guest id). Answered from the users cache — no SQL.
    pub fn get_ao3_user(&self, name: &str) -> Result<Option<AO3User>, AppError> {
        Ok(self.users_cache.resolve(name).map(|e| e.to_ao3_user()))
    }

    /// Library-scope user search: every AO3 account the app has cached
    /// (from works, comments, profiles, subscriptions) whose username or
    /// any pseud matches. Prefix matches rank first. Answered from the
    /// users cache; `limit` of 0 means no limit.
    pub fn search_ao3_usernames(&self, term: &str, limit: u32) -> Result<Vec<String>, AppError> {
        let limit = if limit == 0 { usize::MAX } else { limit as usize };
        Ok(self.users_cache.search_usernames(term, limit))
    }

    /// Persist a fetched profile onto the account's row, creating it when
    /// the user has never been seen.
    pub fn upsert_user_profile(&self, p: &UserProfile) -> Result<(), AppError> {
        self.users_cache.update_profile(&self.conn, p, &crate::timefmt::now_utc_datetime())
    }

    /// The cached profile for a name (account username, byline, or pseud),
    /// with the signed-in account's subscription state joined in from the
    /// local subscriptions table. None when the account has never had a profile fetch recorded.
    pub fn get_user_profile(&self, username: &str) -> Result<Option<UserProfile>, AppError> {
        let Some(entity) = self.users_cache
            .resolve(username)
            .filter(|e| !e.profile_fetched_at.is_empty())
        else { return Ok(None) };
        let mut profile = entity.to_profile();
        if let Some(account) = self.subscription_account() {
            profile.subscribed = self.has_subscription(account.id, SUB_TYPE_AUTHOR, &profile.username)?;
            profile.subscription_ao3_id =
                self.get_subscription_ao3_id(account.id, SUB_TYPE_AUTHOR, &profile.username)?;
        }
        Ok(Some(profile))
    }

    /// Record block state locally (mirrors an AO3-side change). Creates the
    /// account row when needed so state is never dropped.
    pub fn set_user_block_state(&self, username: &str, blocked: bool,
                                ao3_id: Option<&str>) -> Result<(), AppError> {
        self.users_cache.set_block_state(&self.conn, username, blocked,
                                         ao3_id.unwrap_or(""),
                                         &crate::timefmt::now_utc_datetime())
    }

    /// Record mute state locally (mirrors an AO3-side change).
    pub fn set_user_mute_state(&self, username: &str, muted: bool,
                               ao3_id: Option<&str>) -> Result<(), AppError> {
        self.users_cache.set_mute_state(&self.conn, username, muted,
                                        ao3_id.unwrap_or(""),
                                        &crate::timefmt::now_utc_datetime())
    }

    fn save_comment_recursive(&self, work_id: u64, chapter_id: u64, parent_row: Option<i64>,
                              comment: &Comment) -> Result<(), AppError> {
        // The author row is the account; which of its pseuds posted the
        // comment rides on the comment row so the byline can be rebuilt.
        let author = self.users_cache.record(
            &self.conn, &comment.author, &crate::timefmt::now_utc_datetime())?;
        let pseud = if author.is_guest() { String::new() } else {
            split_author_byline(&comment.author.username).1.unwrap_or_default()
        };

        // Whole-work pages name each comment's chapter; replies sit on
        // their thread's chapter. A known id is never overwritten with 0.
        let chapter_id = if chapter_id > 0 { chapter_id } else { comment.chapter_id.unwrap_or(0) };
        let content_json = serde_json::to_string(&comment.content).map_err(map_json)?;
        self.conn.execute(
            "INSERT INTO comments (source, external_id, work_id, chapter_id, parent_id, author_id, author_pseud,
                                   posted_at, content_json, chapter_label, notice, more_replies)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT (source, external_id) DO UPDATE SET
                 work_id = excluded.work_id,
                 chapter_id = CASE WHEN excluded.chapter_id > 0 THEN excluded.chapter_id ELSE comments.chapter_id END,
                 parent_id = excluded.parent_id,
                 author_id = excluded.author_id,
                 author_pseud = excluded.author_pseud,
                 posted_at = excluded.posted_at,
                 content_json = excluded.content_json,
                 chapter_label = CASE WHEN excluded.chapter_label != '' THEN excluded.chapter_label
                                      ELSE comments.chapter_label END,
                 notice = excluded.notice,
                 more_replies = excluded.more_replies,
                 cached_at = datetime('now')",
            params![
                SOURCE_AO3,
                comment.id.to_string(),
                work_id as i64,
                chapter_id as i64,
                parent_row,
                author.id,
                pseud,
                comment.posted_at,
                content_json,
                comment.chapter_label.as_deref().unwrap_or(""),
                comment.notice.as_deref().unwrap_or(""),
                comment.more_replies,
            ],
        ).map_err(map_sql)?;
        let row_id = self.comment_row_id(comment.id)?;

        for reply in &comment.replies {
            self.save_comment_recursive(work_id, chapter_id, row_id, reply)?;
        }
        Ok(())
    }

    /// Cached comments of a work (row id) or chapter (AO3 chapter id,
    /// when > 0), as trees in AO3 order.
    pub fn get_comments(&self, work_id: u64, chapter_id: u64) -> Result<Vec<Comment>, AppError> {
        let (where_clause, param_val): (&str, i64) = if chapter_id > 0 {
            ("c.chapter_id = ?1", chapter_id as i64)
        } else {
            ("c.work_id = ?1", work_id as i64)
        };
        let sql = format!(
            "SELECT c.id, c.external_id, c.posted_at, c.content_json, c.parent_id, c.author_id,
                    c.author_pseud, c.chapter_label, c.notice, c.more_replies, c.chapter_id
             FROM comments c WHERE {} ORDER BY CAST(c.external_id AS INTEGER)",
            where_clause
        );
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        type Row = (i64, String, String, String, Option<i64>, i64, String, String, String, u32, i64);
        let rows: Vec<Row> = stmt
            .query_map(params![param_val], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?,
                    row.get(5)?, row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?, row.get(10)?))
            })
            .map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();

        // Authors come from the users cache: the account row plus the
        // pseud the comment was posted under.
        let mut all: Vec<(i64, Comment, Option<i64>)> = rows.into_iter().map(
            |(row_id, external_id, posted_at, content_json, parent_row, author_row, author_pseud,
              chapter_label, notice, more_replies, chapter_id)| {
            let content: Vec<ContentBlock> = serde_json::from_str(&content_json).unwrap_or_default();
            let author = match self.users_cache.get(author_row) {
                Some(e) => {
                    let mut u = e.to_ao3_user();
                    if !e.is_guest() {
                        u.username = comment_byline(&e.username, &author_pseud);
                    }
                    u
                }
                None => AO3User {
                    id: String::new(),
                    username: "Anonymous".to_string(),
                    profile_url: None,
                    avatar_url: None,
                },
            };
            let c = Comment {
                id: external_id.parse::<u64>().unwrap_or(0),
                author,
                posted_at,
                content,
                replies: Vec::new(),
                chapter_label: Some(chapter_label).filter(|s| !s.is_empty()),
                chapter_id: Some(chapter_id as u64).filter(|&id| id > 0),
                notice: Some(notice).filter(|s| !s.is_empty()),
                more_replies,
            };
            (row_id, c, parent_row)
        }).collect();

        // Build tree: collect replies under their parents (by row id). A
        // parent outside this selection makes its reply top-level.
        let ids: Vec<i64> = all.iter().map(|(row, _, _)| *row).collect();
        let mut top_level = Vec::new();
        let mut comments_map: std::collections::HashMap<i64, Comment> = std::collections::HashMap::new();
        let mut parent_map: Vec<(i64, Option<i64>)> = Vec::new();

        for (row, c, parent) in all.drain(..) {
            parent_map.push((row, parent));
            comments_map.insert(row, c);
        }

        // Process in reverse order so children are added before parents try to collect them
        let mut children_map: std::collections::HashMap<i64, Vec<Comment>> = std::collections::HashMap::new();
        for &(row, parent) in parent_map.iter().rev() {
            let mut comment = comments_map.remove(&row).unwrap();
            if let Some(children) = children_map.remove(&row) {
                comment.replies = children;
            }
            match parent {
                Some(p) if ids.contains(&p) => children_map.entry(p).or_default().push(comment),
                _ => top_level.push(comment),
            }
        }

        top_level.reverse();
        Ok(top_level)
    }

    /// Walk up from `comment_id` (AO3 number) to the root via parent rows,
    /// then return the full thread tree starting from that root. Returns
    /// None if the comment isn't in the cache.
    pub fn get_comment_thread(&self, comment_id: u64) -> Result<Option<Comment>, AppError> {
        let Some(mut current) = self.comment_row_id(comment_id)? else { return Ok(None) };
        loop {
            let parent: Option<i64> = self.conn.query_row(
                "SELECT parent_id FROM comments WHERE id = ?1",
                params![current],
                |row| row.get(0),
            ).optional().map_err(map_sql)?.flatten();
            match parent {
                Some(p) => current = p,
                None => break,
            }
        }

        let (work_id, root_external): (i64, String) = self.conn.query_row(
            "SELECT work_id, external_id FROM comments WHERE id = ?1",
            params![current],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).map_err(map_sql)?;
        let root_id = root_external.parse::<u64>().unwrap_or(0);

        // Load all comments for this work and find the root thread
        let all = self.get_comments(work_id as u64, 0)?;
        Ok(all.iter().find(|c| c.id == root_id).cloned())
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
