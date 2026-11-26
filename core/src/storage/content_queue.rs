//! The content queue: works whose full text is still to be fetched.
//!
//! A work joins the queue when it is added to the library or when a save
//! changes its chapter or word count (`Storage::save_work`). The core's
//! background worker (`api::content_queue`) takes one work at a time and
//! runs the same download a user's "Download for offline" runs, so the
//! triggering save never waits on chapter text.
//!
//! A queued work carries the chapters asked for (`ChapterSpan`): the
//! whole work, or a range of chapter numbers. The queue stays one row a
//! work — a second request for a work already queued widens its row to
//! cover both. A change to a work the library already holds queues only
//! the chapters past the ones it counted before, so a long work that
//! gains a chapter is not walked from its first chapter again.
//!
//! A failed work stays queued with a later retry time; after
//! `CONTENT_MAX_ATTEMPTS` failures it is left alone until the work is
//! queued again (its next change), which resets the count.

use rusqlite::{params, OptionalExtension};

use crate::error::AppError;

use super::{map_sql, Storage};

/// Failures after which a queued work is left until it is queued again.
pub const CONTENT_MAX_ATTEMPTS: u32 = 5;

/// Signalled whenever a work is queued, so the worker wakes at once
/// instead of on its next poll.
pub static CONTENT_QUEUED: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// The chapters of a work a queue row asks for, by chapter number.
/// `first` 0 (or 1) = from the first chapter; `last` 0 = to the last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChapterSpan {
    pub first: u32,
    pub last: u32,
}

impl ChapterSpan {
    /// Every chapter of the work.
    pub const WHOLE: ChapterSpan = ChapterSpan { first: 0, last: 0 };

    /// Every chapter after number `count`.
    pub fn after(count: u32) -> Self {
        ChapterSpan { first: count.saturating_add(1), last: 0 }
    }

    pub fn is_whole(&self) -> bool {
        self.first <= 1 && self.last == 0
    }

    pub fn contains(&self, number: u32) -> bool {
        number >= self.first && (self.last == 0 || number <= self.last)
    }

    /// The one span that covers both.
    pub fn widened(&self, other: ChapterSpan) -> Self {
        ChapterSpan {
            first: self.first.min(other.first),
            last: if self.last == 0 || other.last == 0 { 0 } else { self.last.max(other.last) },
        }
    }
}

/// One queued work as the queue holds it, for the monitor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentQueueRow {
    pub work_id: u64,
    /// The chapters asked for.
    pub span: ChapterSpan,
    /// UTC "YYYY-MM-DD HH:MM:SS".
    pub queued_at: String,
    pub attempts: u32,
    /// Epoch seconds the work is held back until; 0 = not held.
    pub retry_at: u64,
    pub last_error: String,
}

impl Storage {
    /// Everything queued, in the order the worker gets to it at `now`
    /// (epoch seconds): the works that are due (fewest failures first,
    /// then longest queued), then the held-back ones by retry time, then
    /// the ones left alone after `CONTENT_MAX_ATTEMPTS` failures.
    pub fn content_queue_items(&self, now: u64) -> Result<Vec<ContentQueueRow>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT work_id, queued_at, attempts, retry_at, last_error, first_chapter, last_chapter FROM content_queue
             ORDER BY attempts >= ?1, retry_at > ?2,
                      CASE WHEN retry_at > ?2 THEN retry_at ELSE 0 END, attempts, id",
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![CONTENT_MAX_ATTEMPTS, now as i64], |row| Ok(ContentQueueRow {
            work_id: row.get::<_, i64>(0)? as u64,
            queued_at: row.get(1)?,
            attempts: row.get::<_, i64>(2)? as u32,
            retry_at: row.get::<_, i64>(3)? as u64,
            last_error: row.get(4)?,
            span: ChapterSpan { first: row.get::<_, i64>(5)? as u32, last: row.get::<_, i64>(6)? as u32 },
        })).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Queue a work for a full content fetch. Queuing a work that is
    /// already queued clears its failure count and retry time.
    pub fn queue_content(&self, work_id: u64) -> Result<(), AppError> {
        self.queue_content_span(work_id, ChapterSpan::WHOLE)
    }

    /// Queue the chapters of a work that `span` names. A work already
    /// queued keeps its one row, widened to cover both requests, with
    /// its failure count and retry time cleared.
    pub fn queue_content_span(&self, work_id: u64, span: ChapterSpan) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT INTO content_queue (work_id, first_chapter, last_chapter) VALUES (?1, ?2, ?3)
             ON CONFLICT(work_id) DO UPDATE SET attempts = 0, retry_at = 0, last_error = '',
                 first_chapter = MIN(content_queue.first_chapter, excluded.first_chapter),
                 last_chapter = CASE WHEN content_queue.last_chapter = 0 OR excluded.last_chapter = 0 THEN 0
                                     ELSE MAX(content_queue.last_chapter, excluded.last_chapter) END",
            params![work_id as i64, span.first as i64, span.last as i64],
        ).map_err(map_sql)?;
        CONTENT_QUEUED.notify_one();
        crate::events::emit(crate::events::CoreEvent::ContentQueueChanged);
        Ok(())
    }

    /// The next work to fetch at `now` (epoch seconds): the fewest
    /// failures first, then the longest queued. None when nothing is due.
    pub fn next_content_item(&self, now: u64) -> Result<Option<u64>, AppError> {
        self.conn.query_row(
            "SELECT work_id FROM content_queue
             WHERE attempts < ?1 AND retry_at <= ?2
             ORDER BY attempts, id LIMIT 1",
            params![CONTENT_MAX_ATTEMPTS, now as i64],
            |row| row.get::<_, i64>(0),
        ).optional().map(|id| id.map(|id| id as u64)).map_err(map_sql)
    }

    /// The work's content is in the library (or can never be fetched):
    /// drop it from the queue.
    pub fn finish_content_item(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM content_queue WHERE work_id = ?1",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Hold a queued work back until `retry_at` (epoch seconds).
    /// `failed` counts the hold as a failed attempt; a hold that is no
    /// fault of the work (its source can't be reached in the current
    /// privacy mode) does not.
    pub fn defer_content_item(&self, work_id: u64, retry_at: u64, error: &str, failed: bool) -> Result<(), AppError> {
        self.conn.execute(
            "UPDATE content_queue SET retry_at = ?2, last_error = ?3, attempts = attempts + ?4
             WHERE work_id = ?1",
            params![work_id as i64, retry_at as i64, error, failed as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// The chapters a queued work's row asks for. None when the work is
    /// not queued.
    pub fn content_item_span(&self, work_id: u64) -> Result<Option<ChapterSpan>, AppError> {
        self.conn.query_row(
            "SELECT first_chapter, last_chapter FROM content_queue WHERE work_id = ?1",
            params![work_id as i64],
            |row| Ok(ChapterSpan { first: row.get::<_, i64>(0)? as u32, last: row.get::<_, i64>(1)? as u32 }),
        ).optional().map_err(map_sql)
    }

    /// How many failed attempts a queued work has had. None when the
    /// work is not queued.
    pub fn content_item_attempts(&self, work_id: u64) -> Result<Option<u32>, AppError> {
        self.conn.query_row(
            "SELECT attempts FROM content_queue WHERE work_id = ?1",
            params![work_id as i64],
            |row| row.get::<_, i64>(0),
        ).optional().map(|n| n.map(|n| n as u32)).map_err(map_sql)
    }
}
