pub mod error;
pub mod models;
pub mod storage;
pub mod timefmt;

static GLOBAL_LOG_DB: std::sync::OnceLock<std::sync::Mutex<rusqlite::Connection>> = std::sync::OnceLock::new();

pub fn init_logging(db_path: &str, passphrase: &str) {
    if GLOBAL_LOG_DB.get().is_some() { return; }
    let log_path = format!("{}.log", db_path);
    if let Some(conn) = open_log_db(&log_path, passphrase)
        .or_else(|| {
            // Key mismatch from a previous session — delete and retry.
            let _ = std::fs::remove_file(&log_path);
            let _ = std::fs::remove_file(format!("{}-wal", &log_path));
            let _ = std::fs::remove_file(format!("{}-shm", &log_path));
            open_log_db(&log_path, passphrase)
        })
    {
        let _ = GLOBAL_LOG_DB.set(std::sync::Mutex::new(conn));
    }
}

fn open_log_db(path: &str, passphrase: &str) -> Option<rusqlite::Connection> {
    let conn = rusqlite::Connection::open(path).ok()?;
    if !passphrase.is_empty() {
        conn.pragma_update(None, "key", passphrase).ok()?;
    }
    conn.pragma_update(None, "journal_mode", "WAL").ok()?;
    conn.busy_timeout(std::time::Duration::from_millis(5000)).ok()?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS debug_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL DEFAULT (datetime('now')),
            level TEXT NOT NULL,
            tag TEXT NOT NULL,
            message TEXT NOT NULL
        );"
    ).ok()?;
    Some(conn)
}

pub fn with_log_db<F, R>(f: F) -> Option<R>
where
    F: FnOnce(&rusqlite::Connection) -> R,
{
    GLOBAL_LOG_DB.get()
        .and_then(|db| db.lock().ok())
        .map(|conn| f(&conn))
}

/// Delete up to `batch` debug-log rows older than `minutes`. Returns the
/// count deleted; the upkeep task loops until 0, taking the log-db lock
/// per batch so live logging interleaves.
pub fn trim_debug_log_before(minutes: u64, batch: u32) -> usize {
    with_log_db(|conn| {
        conn.execute(
            "DELETE FROM debug_log WHERE id IN
             (SELECT id FROM debug_log WHERE timestamp < datetime('now', ?1) ORDER BY id LIMIT ?2)",
            rusqlite::params![format!("-{minutes} minutes"), batch as i64],
        ).unwrap_or(0)
    }).unwrap_or(0)
}

/// Delete up to `batch` of the oldest debug-log rows beyond `max_rows`.
/// Returns the count deleted (0 = under the cap).
pub fn trim_debug_log_over(max_rows: u64, batch: u32) -> usize {
    with_log_db(|conn| {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM debug_log", [], |r| r.get(0))
            .unwrap_or(0);
        let excess = count - max_rows as i64;
        if excess <= 0 { return 0; }
        conn.execute(
            "DELETE FROM debug_log WHERE id IN
             (SELECT id FROM debug_log ORDER BY id LIMIT ?1)",
            rusqlite::params![excess.min(batch as i64)],
        ).unwrap_or(0)
    }).unwrap_or(0)
}

pub fn dlog(level: &str, tag: &str, message: &str) {
    if let Some(db) = GLOBAL_LOG_DB.get() {
        if let Ok(conn) = db.lock() {
            let _ = conn.execute(
                "INSERT INTO debug_log (level, tag, message) VALUES (?1, ?2, ?3)",
                rusqlite::params![level, tag, message],
            );
        }
    }
}

/// SQLite profile-hook target: one DEBUG row (tag "sql") per completed
/// statement on a profiled connection, with the statement text and its
/// duration. Logs the *expanded* SQL (bound parameters substituted in)
/// except in two cases, which log the placeholder form instead:
/// * statements touching the `accounts` table — its rows carry session
///   cookies, which must never land in the log;
/// * statements whose expanded text exceeds the size cap — those are big
///   because of bound blobs (chapter content JSON), and a truncated blob
///   is both useless and a content leak, while the placeholder form shows
///   the whole statement shape.
/// `expanded` is lazy so the expansion cost is skipped whenever it won't
/// be used. No-op until `init_logging` has run (which also skips all
/// formatting cost in tests and on the very first pre-logging open).
pub fn log_sql(
    sql: &str,
    expanded: impl FnOnce() -> Option<String>,
    duration: std::time::Duration,
) {
    if GLOBAL_LOG_DB.get().is_none() {
        return;
    }
    const MAX_SQL_CHARS: usize = 2000;
    let touches_accounts = sql.to_ascii_lowercase().contains("accounts");
    let text = if touches_accounts { None } else { expanded() }
        .filter(|e| e.len() <= MAX_SQL_CHARS)
        .unwrap_or_else(|| sql.to_string());
    // One line per statement: multi-line SQL collapses to single spaces,
    // and an outsized placeholder form (giant compiled IN lists) is capped.
    let mut text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if let Some((cut, _)) = text.char_indices().nth(MAX_SQL_CHARS) {
        let dropped = text[cut..].chars().count();
        text.truncate(cut);
        text.push_str(&format!("… (+{dropped} chars)"));
    }
    dlog(
        "DEBUG",
        "sql",
        &format!("{:.3}ms  {text}", duration.as_secs_f64() * 1000.0),
    );
}

#[macro_export]
macro_rules! log_debug {
    ($tag:expr, $($arg:tt)*) => {
        $crate::dlog("DEBUG", $tag, &format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_info {
    ($tag:expr, $($arg:tt)*) => {
        $crate::dlog("INFO", $tag, &format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_error {
    ($tag:expr, $($arg:tt)*) => {
        $crate::dlog("ERROR", $tag, &format!($($arg)*));
    };
}

pub mod parser;
pub mod client;
pub mod events;
pub mod api;
pub mod epub;

pub use error::AppError;
pub use models::*;
pub use parser::{parse_work_listings, parse_work_page};
pub use client::AO3Client;
pub use storage::Storage;
pub use api::{AO3App, AO3Error};

uniffi::setup_scaffolding!();
