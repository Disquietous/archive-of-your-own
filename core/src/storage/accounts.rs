use rusqlite::params;

use crate::error::AppError;
use crate::models::{AO3User, Comment, ContentBlock, UserProfile};

use super::{map_json, map_sql, Storage};

impl Storage {
    /// Whether any ao3_users row exists for this username.
    pub fn has_ao3_user_with_username(&self, username: &str) -> Result<bool, AppError> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM ao3_users WHERE username = ?1 COLLATE NOCASE",
            params![username], |row| row.get(0)
        ).map_err(map_sql)?;
        Ok(count > 0)
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

    // -- Inbox persistence ---------------------------------------------------

    /// Whether an inbox message is already stored locally.
    pub fn has_inbox_message(&self, comment_id: u64) -> Result<bool, AppError> {
        let mut stmt = self.conn
            .prepare("SELECT 1 FROM inbox_messages WHERE comment_id = ?1 LIMIT 1")
            .map_err(map_sql)?;
        stmt.exists(params![comment_id as i64]).map_err(map_sql)
    }

    pub fn save_inbox_messages(&self, items: &[crate::models::InboxItem]) -> Result<(), AppError> {
        let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
        {
            let mut stmt = tx.prepare(
                "INSERT OR REPLACE INTO inbox_messages
                 (comment_id, author, author_url, avatar_url, work_reference, work_url, posted_at, is_unread, content_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"
            ).map_err(map_sql)?;
            for item in items {
                let content_json = serde_json::to_string(&item.content).unwrap_or_else(|_| "[]".to_string());
                stmt.execute(params![
                    item.comment_id as i64,
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

    pub fn get_inbox_messages(&self, page: u32, per_page: u32) -> Result<Vec<(u64, String, String, String, String, String, String, bool, String)>, AppError> {
        let offset = (page.saturating_sub(1)) * per_page;
        let mut stmt = self.conn.prepare(
            "SELECT comment_id, author, author_url, avatar_url, work_reference, work_url, posted_at, is_unread, content_json
             FROM inbox_messages ORDER BY comment_id DESC LIMIT ?1 OFFSET ?2"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![per_page, offset], |row| {
            let id: i64 = row.get(0)?;
            let is_unread: i32 = row.get(7)?;
            Ok((
                id as u64,
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

    /// Library-scope user search: every AO3 user the app has cached (from
    /// works, comments, kudos, profiles) whose username matches. Prefix
    /// matches rank first.
    pub fn search_ao3_usernames(&self, term: &str, limit: u32) -> Result<Vec<String>, AppError> {
        let escaped = Self::escape_like(term);
        if escaped.is_empty() {
            return Ok(Vec::new());
        }
        let contains = format!("%{escaped}%");
        let prefix = format!("{escaped}%");
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT username FROM ao3_users
             WHERE username LIKE ?1 ESCAPE '\\'
             ORDER BY (username LIKE ?2 ESCAPE '\\') DESC, username COLLATE NOCASE
             LIMIT ?3"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![contains, prefix, limit], |row| {
            row.get::<_, String>(0)
        }).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Persist a fetched profile onto the user's ao3_users row (keyed by
    /// username, matching how author rows are recorded elsewhere).
    /// Creates the row when the user has never been seen.
    pub fn upsert_user_profile(&self, p: &UserProfile) -> Result<(), AppError> {
        self.upsert_ao3_user(&AO3User {
            id: p.username.clone(),
            username: p.username.clone(),
            profile_url: Some(format!("{}/users/{}", crate::client::BASE_URL, p.username)),
            avatar_url: p.avatar_url.clone(),
        })?;
        let pseuds_json = serde_json::to_string(&p.pseuds).map_err(map_json)?;
        let bio_json = serde_json::to_string(&p.bio).map_err(map_json)?;
        self.conn.execute(
            "UPDATE ao3_users SET
                numeric_id = CASE WHEN ?2 = '' THEN numeric_id ELSE ?2 END,
                joined = ?3, location = ?4, birthday = ?5,
                pseuds_json = ?6, bio_json = ?7,
                works_count = ?8, series_count = ?9, bookmarks_count = ?10,
                collections_count = ?11, gifts_count = ?12,
                is_blocked = ?13, block_ao3_id = ?14,
                is_muted = ?15, mute_ao3_id = ?16,
                profile_fetched_at = datetime('now'),
                updated_at = datetime('now')
             WHERE username = ?1 COLLATE NOCASE",
            params![
                p.username,
                p.numeric_id.as_deref().unwrap_or(""),
                p.joined, p.location, p.birthday,
                pseuds_json, bio_json,
                p.works_count, p.series_count, p.bookmarks_count,
                p.collections_count, p.gifts_count,
                p.blocked as i64, p.block_ao3_id.as_deref().unwrap_or(""),
                p.muted as i64, p.mute_ao3_id.as_deref().unwrap_or(""),
            ],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// The cached profile for a username, with live subscription state
    /// joined in from the local subscriptions table. None when the user
    /// has never had a profile fetch recorded.
    pub fn get_user_profile(&self, username: &str) -> Result<Option<UserProfile>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT username, numeric_id, avatar_url, pseuds_json, joined, location, birthday,
                    bio_json, works_count, series_count, bookmarks_count, collections_count,
                    gifts_count, is_blocked, block_ao3_id, is_muted, mute_ao3_id, profile_fetched_at
             FROM ao3_users
             WHERE username = ?1 COLLATE NOCASE AND profile_fetched_at != ''
             ORDER BY updated_at DESC LIMIT 1"
        ).map_err(map_sql)?;
        let row = stmt.query_map(params![username], |row| {
            let opt = |s: String| if s.is_empty() { None } else { Some(s) };
            Ok(UserProfile {
                username: row.get::<_, String>(0)?,
                numeric_id: opt(row.get(1)?),
                avatar_url: opt(row.get(2)?),
                pseuds: serde_json::from_str(&row.get::<_, String>(3)?).unwrap_or_default(),
                joined: row.get(4)?,
                location: row.get(5)?,
                birthday: row.get(6)?,
                bio: serde_json::from_str(&row.get::<_, String>(7)?).unwrap_or_default(),
                works_count: row.get(8)?,
                series_count: row.get(9)?,
                bookmarks_count: row.get(10)?,
                collections_count: row.get(11)?,
                gifts_count: row.get(12)?,
                blocked: row.get::<_, i64>(13)? != 0,
                block_ao3_id: opt(row.get(14)?),
                muted: row.get::<_, i64>(15)? != 0,
                mute_ao3_id: opt(row.get(16)?),
                viewer_signed_in: false,
                subscribed: false,
                subscription_ao3_id: None,
                fetched_at: row.get(17)?,
            })
        }).map_err(map_sql)?.next();
        let Some(Ok(mut profile)) = row else { return Ok(None) };
        profile.subscribed = self.has_subscription("author", &profile.username)?;
        profile.subscription_ao3_id =
            self.get_subscription_ao3_id("author", &profile.username)?;
        Ok(Some(profile))
    }

    /// Record block state locally (mirrors an AO3-side change). Creates a
    /// minimal user row when needed so state is never dropped.
    pub fn set_user_block_state(&self, username: &str, blocked: bool,
                                ao3_id: Option<&str>) -> Result<(), AppError> {
        self.ensure_ao3_user_row(username)?;
        self.conn.execute(
            "UPDATE ao3_users SET is_blocked = ?2, block_ao3_id = ?3,
                updated_at = datetime('now')
             WHERE username = ?1 COLLATE NOCASE",
            params![username, blocked as i64, ao3_id.unwrap_or("")],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Record mute state locally (mirrors an AO3-side change).
    pub fn set_user_mute_state(&self, username: &str, muted: bool,
                               ao3_id: Option<&str>) -> Result<(), AppError> {
        self.ensure_ao3_user_row(username)?;
        self.conn.execute(
            "UPDATE ao3_users SET is_muted = ?2, mute_ao3_id = ?3,
                updated_at = datetime('now')
             WHERE username = ?1 COLLATE NOCASE",
            params![username, muted as i64, ao3_id.unwrap_or("")],
        ).map_err(map_sql)?;
        Ok(())
    }

    fn ensure_ao3_user_row(&self, username: &str) -> Result<(), AppError> {
        if !self.has_ao3_user_with_username(username)? {
            self.upsert_ao3_user(&AO3User {
                id: username.to_string(),
                username: username.to_string(),
                profile_url: Some(format!("{}/users/{username}", crate::client::BASE_URL)),
                avatar_url: None,
            })?;
        }
        Ok(())
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

    /// Walk up from `comment_id` to the root via parent_id, then return the
    /// full thread tree starting from that root.  Returns None if the comment
    /// isn't in the cache.
    pub fn get_comment_thread(&self, comment_id: u64) -> Result<Option<Comment>, AppError> {
        // 1. Find the root by walking parent_id
        let mut current = comment_id;
        loop {
            let parent: i64 = self.conn.query_row(
                "SELECT parent_id FROM comments WHERE id = ?1",
                params![current as i64],
                |row| row.get(0),
            ).unwrap_or(-1);
            if parent <= 0 { break; }
            current = parent as u64;
        }

        // If the comment doesn't exist at all, return None
        if current == comment_id {
            let exists: bool = self.conn.query_row(
                "SELECT COUNT(*) > 0 FROM comments WHERE id = ?1",
                params![comment_id as i64],
                |row| row.get(0),
            ).unwrap_or(false);
            if !exists { return Ok(None); }
        }

        // 2. Load the whole subtree from root
        let root_id = current;
        let work_id: i64 = self.conn.query_row(
            "SELECT work_id FROM comments WHERE id = ?1",
            params![root_id as i64],
            |row| row.get(0),
        ).unwrap_or(0);

        // Load all comments for this work and find the root thread
        let all = self.get_comments(work_id as u64, 0)?;
        fn find_root<'a>(comments: &'a [Comment], root_id: u64) -> Option<&'a Comment> {
            for c in comments {
                if c.id == root_id { return Some(c); }
            }
            None
        }
        Ok(find_root(&all, root_id).cloned())
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
