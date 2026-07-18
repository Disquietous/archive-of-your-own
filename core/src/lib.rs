pub mod error;
pub mod models;
pub mod storage;

use std::sync::Arc;

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
pub mod api;
pub mod epub;

pub use error::AppError;
pub use models::*;
pub use parser::{parse_work_listings, parse_work_page};
pub use client::AO3Client;
pub use storage::Storage;
pub use api::{AO3App, AO3Error};

uniffi::setup_scaffolding!();
