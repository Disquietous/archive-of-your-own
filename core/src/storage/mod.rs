// NOTE: A `StorageError(String)` variant must be added to `AppError` in error.rs
// for this module to compile. Example:
//
//     #[error("Storage error: {0}")]
//     StorageError(String),

use rusqlite::Connection;

use crate::error::AppError;
use crate::models::Rating;

mod accounts;
mod library;
mod subscriptions;
mod works;

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
        storage.migrate()?;
        // One-time: seed the autocomplete tag cache from works cached before
        // the known_tags table existed.
        let _ = storage.backfill_known_tags();
        Ok(storage)
    }

    /// Current schema version (PRAGMA user_version). v1 is the pre-versioning
    /// baseline; every later version is one MIGRATIONS-ladder step. Bump this
    /// when adding a step to `migrate`.
    const SCHEMA_VERSION: u32 = 4;

    pub(crate) fn schema_version(&self) -> Result<u32, AppError> {
        self.conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(map_sql)
    }

    /// Bring the database to SCHEMA_VERSION. Each step runs in its own
    /// transaction with the `user_version` stamp, so a crash mid-migration
    /// rolls back cleanly and the next open resumes. Unlike the legacy
    /// `.ok()` era, a failed step aborts the open loudly — the app surfaces
    /// it instead of running against a half-migrated schema.
    fn migrate(&self) -> Result<(), AppError> {
        let mut version = self.schema_version()?;
        if version > Self::SCHEMA_VERSION {
            return Err(AppError::StorageError(format!(
                "database schema v{version} is newer than this app supports (v{}) — update the app",
                Self::SCHEMA_VERSION
            )));
        }
        if version == 0 {
            // v1 baseline: the entire pre-versioning schema, kept verbatim.
            // Idempotent by construction (CREATE IF NOT EXISTS + swallowed
            // duplicate-column ALTERs) — exactly what every install has run
            // on every open until now, so all legacy DBs land here
            // identically. Fresh DBs build the same baseline then walk the
            // ladder like everyone else: one code path, no fresh/upgraded
            // schema drift possible.
            let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
            self.baseline_schema()?;
            tx.pragma_update(None, "user_version", 1).map_err(map_sql)?;
            tx.commit().map_err(map_sql)?;
            version = 1;
        }
        while version < Self::SCHEMA_VERSION {
            let next = version + 1;
            let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
            let step = match next {
                2 => self.migrate_v2(),
                3 => self.migrate_v3(),
                4 => self.migrate_v4(),
                _ => Err(AppError::StorageError(format!("no migration defined for v{next}"))),
            };
            step.map_err(|e| AppError::StorageError(format!("migration to v{next} failed: {e}")))?;
            tx.pragma_update(None, "user_version", next).map_err(map_sql)?;
            tx.commit()
                .map_err(|e| AppError::StorageError(format!("migration to v{next} failed: {e}")))?;
            version = next;
        }
        Ok(())
    }

    /// v2 — storage hygiene (2026-08):
    /// * `works.fetched_at`: when this summary last arrived from AO3.
    ///   Surfaced to the user only — never a refresh trigger (cache-forever
    ///   is the design; What's-New subscriptions are the update channel).
    /// * `work_authors`: normalized author→work index replacing the
    ///   json_each full-table scan in get_works_by_author.
    /// * One timestamp encoding: legacy epoch-seconds strings become the
    ///   DB-wide UTC "YYYY-MM-DD HH:MM:SS" text everywhere else uses.
    /// * Drops the orphaned `subscription_snapshots_old` table.
    fn migrate_v2(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "ALTER TABLE works ADD COLUMN fetched_at TEXT NOT NULL DEFAULT '';
                 CREATE TABLE work_authors (
                     work_id INTEGER NOT NULL,
                     author  TEXT NOT NULL,
                     PRIMARY KEY (author, work_id)
                 );
                 DROP TABLE IF EXISTS subscription_snapshots_old;
                 UPDATE works SET detail_viewed_at =
                        datetime(CAST(detail_viewed_at AS INTEGER), 'unixepoch')
                    WHERE detail_viewed_at != ''
                      AND detail_viewed_at NOT GLOB '*[^0-9]*';
                 UPDATE subscription_snapshots SET last_census_at =
                        datetime(CAST(last_census_at AS INTEGER), 'unixepoch')
                    WHERE last_census_at IS NOT NULL AND last_census_at != ''
                      AND last_census_at NOT GLOB '*[^0-9]*';
                 UPDATE subscription_snapshots SET works_crawled_at =
                        datetime(CAST(works_crawled_at AS INTEGER), 'unixepoch')
                    WHERE works_crawled_at IS NOT NULL AND works_crawled_at != ''
                      AND works_crawled_at NOT GLOB '*[^0-9]*';
                 UPDATE app_state SET value = datetime(CAST(value AS INTEGER), 'unixepoch')
                    WHERE key = 'last_subscription_check' AND value != ''
                      AND value NOT GLOB '*[^0-9]*';",
            )
            .map_err(map_sql)?;
        self.backfill_work_authors()
    }

    /// v3 — saved-search names become unique, case-insensitively, so
    /// `save_search` can upsert (`ON CONFLICT(name COLLATE NOCASE)`).
    /// Older duplicates are dropped (newest wins), along with the
    /// short-lived case-sensitive index some dev databases carry.
    fn migrate_v3(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "DELETE FROM saved_searches WHERE id NOT IN (
                     SELECT MAX(id) FROM saved_searches GROUP BY name COLLATE NOCASE
                 );
                 DROP INDEX IF EXISTS idx_saved_searches_name;
                 CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_searches_name_nocase
                     ON saved_searches(name COLLATE NOCASE);",
            )
            .map_err(map_sql)
    }

    /// v4 — per-subscription check freshness. `last_checked_at` records when
    /// each subscription's own check last completed; the global queue-drain
    /// stamp only describes a round, which misrepresents rows when a round
    /// is interrupted and resumed later. NULL = never checked, so every
    /// subscription is due immediately after migrating.
    fn migrate_v4(&self) -> Result<(), AppError> {
        self.conn
            .execute("ALTER TABLE subscription_snapshots ADD COLUMN last_checked_at TEXT", [])
            .map_err(map_sql)?;
        Ok(())
    }

    /// A write transaction for multi-row batches. Statements executed on
    /// `self` while the guard lives join the transaction; dropping it
    /// without `commit()` rolls everything back.
    pub fn begin_tx(&self) -> Result<rusqlite::Transaction<'_>, AppError> {
        self.conn.unchecked_transaction().map_err(map_sql)
    }

    /// Run `f` atomically inside a named savepoint. Unlike BEGIN, savepoints
    /// nest — so a method wrapped this way still composes inside a caller's
    /// begin_tx() batch (or another savepoint).
    pub(super) fn with_savepoint<T>(
        &self,
        name: &str,
        f: impl FnOnce() -> Result<T, AppError>,
    ) -> Result<T, AppError> {
        self.conn
            .execute_batch(&format!("SAVEPOINT {name}"))
            .map_err(map_sql)?;
        match f() {
            Ok(v) => {
                self.conn.execute_batch(&format!("RELEASE {name}")).map_err(map_sql)?;
                Ok(v)
            }
            Err(e) => {
                let _ = self
                    .conn
                    .execute_batch(&format!("ROLLBACK TO {name}; RELEASE {name}"));
                Err(e)
            }
        }
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
    // Internal helpers
    // -------------------------------------------------------------------

    fn baseline_schema(&self) -> Result<(), AppError> {
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
                    date_published  TEXT NOT NULL DEFAULT '',
                    date_updated    TEXT NOT NULL,
                    language        TEXT NOT NULL,
                    complete        INTEGER NOT NULL,
                    series_json     TEXT NOT NULL DEFAULT '[]',
                    detail_viewed_at TEXT NOT NULL DEFAULT '',
                    last_read_dt    TEXT NOT NULL DEFAULT ''
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

                CREATE TABLE IF NOT EXISTS subscriptions (
                    sub_type TEXT NOT NULL,
                    sub_id   TEXT NOT NULL,
                    name     TEXT NOT NULL,
                    PRIMARY KEY (sub_type, sub_id)
                );

                CREATE TABLE IF NOT EXISTS subscription_snapshots (
                    sub_type     TEXT NOT NULL,
                    sub_id       TEXT NOT NULL,
                    date_updated TEXT NOT NULL,
                    PRIMARY KEY (sub_type, sub_id)
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

                CREATE TABLE IF NOT EXISTS subscription_new_works (
                    work_id     INTEGER PRIMARY KEY,
                    added_at    TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS inbox_messages (
                    comment_id   INTEGER PRIMARY KEY,
                    author       TEXT NOT NULL,
                    author_url   TEXT NOT NULL DEFAULT '',
                    avatar_url   TEXT NOT NULL DEFAULT '',
                    work_reference TEXT NOT NULL,
                    work_url     TEXT NOT NULL DEFAULT '',
                    posted_at    TEXT NOT NULL,
                    is_unread    INTEGER NOT NULL DEFAULT 1,
                    content_json TEXT NOT NULL DEFAULT '[]',
                    fetched_at   TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_inbox_fetched ON inbox_messages(fetched_at DESC);
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
                CREATE TABLE IF NOT EXISTS kudos_given (
                    work_id INTEGER PRIMARY KEY
                );
                CREATE TABLE IF NOT EXISTS image_cache (
                    key        TEXT PRIMARY KEY,
                    data       BLOB NOT NULL,
                    fetched_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE IF NOT EXISTS known_tags (
                    name      TEXT NOT NULL,
                    tag_type  TEXT NOT NULL,
                    uses      INTEGER NOT NULL DEFAULT 1,
                    canonical INTEGER NOT NULL DEFAULT 0,
                    last_seen TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (name, tag_type)
                );
                CREATE INDEX IF NOT EXISTS idx_known_tags_lookup
                    ON known_tags(tag_type, name COLLATE NOCASE);
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

        // One-time: purge avatars cached by the unscoped icon selector (they
        // captured the signed-in user's chrome icon, not the profile owner's).
        if self.get_state("avatar_cache_reset_1").ok().flatten().is_none() {
            let _ = self.conn.execute("DELETE FROM image_cache WHERE key LIKE 'avatar:%'", []);
            let _ = self.set_state("avatar_cache_reset_1", "1");
        }

        // Migration: AO3 bookmarks are rich objects — notes, own tags,
        // collections, private/rec flags (private defaults on, per the
        // app's privacy-first stance).
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN tag_string TEXT NOT NULL DEFAULT ''", []).ok();
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN collection_names TEXT NOT NULL DEFAULT ''", []).ok();
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN private INTEGER NOT NULL DEFAULT 1", []).ok();
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN rec INTEGER NOT NULL DEFAULT 0", []).ok();

        // Migration: add account_id column to bookmarks (idempotent)
        self.conn.execute("ALTER TABLE bookmarks ADD COLUMN account_id TEXT NOT NULL DEFAULT ''", []).ok();

        // Migration: add date_published column to works (idempotent)
        self.conn.execute("ALTER TABLE works ADD COLUMN date_published TEXT NOT NULL DEFAULT ''", []).ok();

        // Migration: AO3's own subscription record id (from unsubscribe form
        // actions) — lets unsubscribe POST directly without a page fetch.
        self.conn.execute("ALTER TABLE subscriptions ADD COLUMN ao3_id TEXT", []).ok();

        // Migration: rename old per-work subscription_snapshots to _old.
        // The new table (created above) stores one row per subscription.
        // For existing DBs the old table has the 3-column PK; renaming it
        // clears the way for the new schema.  Fresh DBs create the new
        // table directly and this rename is a harmless no-op.
        self.conn.execute(
            "ALTER TABLE subscription_snapshots RENAME TO subscription_snapshots_old",
            [],
        ).ok();
        // Re-create the new-schema table if the rename just consumed it.
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS subscriptions (
                sub_type TEXT NOT NULL,
                sub_id   TEXT NOT NULL,
                name     TEXT NOT NULL,
                PRIMARY KEY (sub_type, sub_id)
            );
            CREATE TABLE IF NOT EXISTS subscription_snapshots (
                sub_type     TEXT NOT NULL,
                sub_id       TEXT NOT NULL,
                date_updated TEXT NOT NULL,
                PRIMARY KEY (sub_type, sub_id)
            );
            CREATE TABLE IF NOT EXISTS subscription_works (
                sub_type TEXT NOT NULL,
                sub_id   TEXT NOT NULL,
                work_id  INTEGER NOT NULL,
                PRIMARY KEY (sub_type, sub_id, work_id)
            );
            CREATE TABLE IF NOT EXISTS followed_items (
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (kind, name)
            );"
        ).ok();

        // Migration: census metadata on subscription snapshots. total_works
        // is the listing's claimed count from the last check (NULL =
        // unknown); last_census_at is a unix-seconds string (NULL = never);
        // census_state is in-progress census JSON (NULL = none running).
        self.conn.execute("ALTER TABLE subscription_snapshots ADD COLUMN total_works INTEGER", []).ok();
        self.conn.execute("ALTER TABLE subscription_snapshots ADD COLUMN last_census_at TEXT", []).ok();
        self.conn.execute("ALTER TABLE subscription_snapshots ADD COLUMN census_state TEXT", []).ok();
        // Migration: when a full works crawl (Refresh Works) last completed
        // for this author/series — unix-seconds string, NULL = never. Drives
        // the drill-in staleness line ("refreshed 3d ago").
        self.conn.execute("ALTER TABLE subscription_snapshots ADD COLUMN works_crawled_at TEXT", []).ok();

        // Migration: works that a census confirmed are no longer listed on
        // AO3 (deleted, restricted, or moved to Anonymous). The cached copy
        // is retained everywhere; this only records the fact.
        self.conn.execute("ALTER TABLE works ADD COLUMN gone_from_ao3 INTEGER NOT NULL DEFAULT 0", []).ok();

        // Migration: series memberships parsed from the work page ('[]'
        // until the work is next fully fetched). Kept out of save_work —
        // listing blurbs don't carry series and would wipe it (same
        // rationale as gone_from_ao3 above); set_work_series writes it.
        self.conn.execute("ALTER TABLE works ADD COLUMN series_json TEXT NOT NULL DEFAULT '[]'", []).ok();

        // Migration: unix-seconds timestamp of the first time the user
        // opened this work's detail view in-app ('' = never). Kept out of
        // save_work like the columns above; feeds the What's New badge
        // (only never-viewed works count).
        self.conn.execute("ALTER TABLE works ADD COLUMN detail_viewed_at TEXT NOT NULL DEFAULT ''", []).ok();

        // Migration: UTC datetime of the last time the user opened a chapter
        // of this work ('' = never). Drives the Currently Reading sort.
        // Kept out of save_work like the columns above.
        self.conn.execute("ALTER TABLE works ADD COLUMN last_read_dt TEXT NOT NULL DEFAULT ''", []).ok();
        // Backfill: works read before last_read_dt existed inherit their
        // most recent progress write, so Currently Reading orders sensibly
        // on the first launch after the upgrade. Idempotent — only ever
        // touches rows still at ''.
        self.conn.execute(
            "UPDATE works SET last_read_dt = COALESCE(
                 (SELECT rp.updated_at FROM reading_progress rp WHERE rp.work_id = works.id), '')
             WHERE last_read_dt = ''", []).ok();

        // Migration: full user profiles + block/mute state on ao3_users.
        // pseuds and bio are JSON (bio is a serialized ContentBlock tree,
        // same encoding comments use). The *_ao3_id columns hold AO3's
        // record ids so undo can POST directly without a confirm-page fetch.
        for ddl in [
            "ALTER TABLE ao3_users ADD COLUMN numeric_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN joined TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN location TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN birthday TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN pseuds_json TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE ao3_users ADD COLUMN bio_json TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE ao3_users ADD COLUMN works_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN series_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN bookmarks_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN collections_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN gifts_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN is_blocked INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN block_ao3_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN is_muted INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE ao3_users ADD COLUMN mute_ao3_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE ao3_users ADD COLUMN profile_fetched_at TEXT NOT NULL DEFAULT ''",
        ] {
            self.conn.execute(ddl, []).ok();
        }

        Ok(())
    }
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests;
