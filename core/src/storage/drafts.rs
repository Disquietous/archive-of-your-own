use rusqlite::{params, OptionalExtension};

use crate::error::AppError;

use super::{map_sql, Storage};

/// An unposted comment: the text in one composer (a work's whole-work box
/// or one chapter's box) and the comment it replies to (0 = top-level).
#[derive(Debug, Clone, PartialEq)]
pub struct CommentDraft {
    pub parent_comment_id: u64,
    pub body: String,
    pub updated_at: String,
}

impl Storage {
    /// The signed-in account's draft for a composer; None when there is
    /// none (or nobody is signed in). `chapter_id` 0 = whole-work comments.
    pub fn get_comment_draft(&self, work_id: u64, chapter_id: u64) -> Result<Option<CommentDraft>, AppError> {
        let Some(account) = self.subscription_account() else { return Ok(None) };
        self.conn.query_row(
            "SELECT parent_comment_id, body, updated_at FROM comment_drafts
             WHERE account_id = ?1 AND work_id = ?2 AND chapter_id = ?3",
            params![account, work_id as i64, chapter_id as i64],
            |row| Ok(CommentDraft {
                parent_comment_id: row.get::<_, i64>(0)? as u64,
                body: row.get(1)?,
                updated_at: row.get(2)?,
            }),
        ).optional().map_err(map_sql)
    }

    /// Save the composer's text and reply target. A blank body deletes the
    /// row — drafts exist only while there is text. No-op when signed out.
    pub fn save_comment_draft(&self, work_id: u64, chapter_id: u64,
                              parent_comment_id: u64, body: &str) -> Result<(), AppError> {
        if body.trim().is_empty() {
            return self.clear_comment_draft(work_id, chapter_id);
        }
        let Some(account) = self.subscription_account() else { return Ok(()) };
        self.conn.execute(
            "INSERT INTO comment_drafts (account_id, work_id, chapter_id, parent_comment_id, body, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT (account_id, work_id, chapter_id) DO UPDATE SET
                 parent_comment_id = excluded.parent_comment_id,
                 body = excluded.body,
                 updated_at = excluded.updated_at",
            params![account, work_id as i64, chapter_id as i64, parent_comment_id as i64,
                    body, crate::timefmt::now_utc_datetime()],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Drop the signed-in account's draft for a composer (after a post).
    pub fn clear_comment_draft(&self, work_id: u64, chapter_id: u64) -> Result<(), AppError> {
        let Some(account) = self.subscription_account() else { return Ok(()) };
        self.conn.execute(
            "DELETE FROM comment_drafts WHERE account_id = ?1 AND work_id = ?2 AND chapter_id = ?3",
            params![account, work_id as i64, chapter_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }
}
