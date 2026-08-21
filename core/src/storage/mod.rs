// NOTE: A `StorageError(String)` variant must be added to `AppError` in error.rs
// for this module to compile. Example:
//
//     #[error("Storage error: {0}")]
//     StorageError(String),

use rusqlite::Connection;

use crate::error::AppError;
use crate::models::Rating;

mod accounts;
mod consts;
mod library;
mod subscriptions;
mod state_cache;
mod tag_cache;
mod works;
mod works_cache;
mod works_search;

use consts::*;
use state_cache::StateCache;
use tag_cache::TagCache;
use works_cache::WorksCache;

/// Encrypted local storage backed by SQLCipher.
///
/// All Vec/enum fields are stored as JSON strings via serde_json.
/// ContentBlock trees are stored as JSON in the `chapters.content_json` column.
pub struct Storage {
    conn: Connection,
    /// The tags table's in-memory mirror and single write authority — every
    /// post-open write to `tags` goes through its methods, which mutate map
    /// and database together (see tag_cache.rs for the invariant). A tag the
    /// library already knows (with its type) costs no SQL to re-encounter.
    tag_cache: TagCache,
    /// The works (+ work_tags/work_authors) mirror and single write
    /// authority — same contract as `tag_cache` (see works_cache.rs).
    /// Work reads and membership scans cost no SQL; tag names hydrate from
    /// `tag_cache` by id instead of a join.
    works_cache: WorksCache,
    /// The app_state (settings key→value) mirror and single write
    /// authority — same contract as the caches above (see state_cache.rs).
    /// Settings lookups cost no SQL.
    state_cache: StateCache,
}

/// A live write transaction from `Storage::begin_tx`. Commit consumes it;
/// dropping it uncommitted rolls the transaction back and resyncs the
/// in-memory caches so a discarded write can't leave them ahead of the
/// database.
pub struct TxGuard<'a> {
    tx: Option<rusqlite::Transaction<'a>>,
    storage: &'a Storage,
}

impl TxGuard<'_> {
    pub fn commit(mut self) -> Result<(), AppError> {
        let tx = self.tx.take().expect("TxGuard commit is take-once");
        tx.commit().map_err(|e| {
            // A failed commit rolled back server-side; put the caches back
            // on the table truth before surfacing the error.
            self.storage.resync_caches();
            map_sql(e)
        })
    }
}

impl Drop for TxGuard<'_> {
    fn drop(&mut self) {
        if let Some(tx) = self.tx.take() {
            drop(tx); // rusqlite's drop-without-commit is a rollback
            self.storage.resync_caches();
        }
    }
}

/// Account-scoped rows (bookmarks) made while signed out live under this
/// sentinel. Brackets can't appear in an AO3 username, so it can never
/// collide with a real account id.
pub const LOGGED_OUT_ACCOUNT_ID: &str = "[none]";

/// The account id for an AO3 username: the username itself, lowercased —
/// every account is an AO3 account, so the identity needs no other shape.
pub fn account_id_for(username: &str) -> String {
    username.to_lowercase()
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
        Rating::General => RATING_GENERAL,
        Rating::Teen => RATING_TEEN,
        Rating::Mature => RATING_MATURE,
        Rating::Explicit => RATING_EXPLICIT,
        Rating::NotRated => RATING_NOT_RATED,
    }
}

fn str_to_rating(s: &str) -> Rating {
    match s {
        RATING_GENERAL => Rating::General,
        RATING_TEEN => Rating::Teen,
        RATING_MATURE => Rating::Mature,
        RATING_EXPLICIT => Rating::Explicit,
        _ => Rating::NotRated,
    }
}

fn migration_failed(next: impl std::fmt::Display, e: impl std::fmt::Display) -> AppError {
    AppError::StorageError(format!("migration to v{next} failed: {e}"))
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
        // SQLite leaves foreign key enforcement off by default; the join
        // tables (work_tags, collection_tags, collection_works) rely on
        // ON DELETE CASCADE to clean up when a work, collection, or tag
        // row is deleted.
        conn.pragma_update(None, "foreign_keys", "ON").map_err(map_sql)?;

        // Profile every statement this connection runs into the debug log
        // (tag "sql": statement text + duration) — migrations included.
        // See log_sql for when the expanded (values substituted) vs
        // placeholder form is logged. Recursion-safe: log rows go to the
        // logging module's own separate `.log` database connection, which
        // has no hook.
        conn.trace_v2(
            rusqlite::trace::TraceEventCodes::SQLITE_TRACE_PROFILE,
            Some(|event| {
                if let rusqlite::trace::TraceEvent::Profile(stmt, duration) = event {
                    crate::log_sql(&stmt.sql(), || stmt.expanded_sql(), duration);
                }
            }),
        );

        // SQL-visible Unicode lowercasing (SQLite's own lower() is
        // ASCII-only). The compiled library search leans on it so its
        // case-insensitive matching is byte-identical to the Rust-side
        // `contains_ci`/`sort_filtered` semantics it replaces.
        conn.create_scalar_function(
            "ao3_lower",
            1,
            rusqlite::functions::FunctionFlags::SQLITE_UTF8
                | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC,
            |ctx| Ok(ctx.get::<String>(0)?.to_lowercase()),
        )
        .map_err(map_sql)?;

        let storage = Self {
            conn,
            tag_cache: TagCache::default(),
            works_cache: WorksCache::default(),
            state_cache: StateCache::default(),
        };
        storage.migrate()?;
        // Prime the in-memory caches (tags first — work hydration resolves
        // tag ids against it) before anything reads or harvests. Migrations
        // are the one code path allowed to write these tables without the
        // caches — they ran before these loads.
        storage.tag_cache.load(&storage.conn)?;
        storage.works_cache.load(&storage.conn)?;
        storage.state_cache.load(&storage.conn)?;
        // One-time: seed the tags table from works cached before it existed.
        let _ = storage.backfill_tags();
        Ok(storage)
    }

    /// Current schema version (PRAGMA user_version). v1 is the pre-versioning
    /// baseline; every later version is one MIGRATIONS-ladder step. Bump this
    /// when adding a step to `migrate`.
    const SCHEMA_VERSION: u32 = 11;

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
            tx.pragma_update(None, PRAGMA_USER_VERSION, 1).map_err(map_sql)?;
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
                5 => self.migrate_v5(),
                6 => self.migrate_v6(),
                7 => self.migrate_v7(),
                8 => self.migrate_v8(),
                9 => self.migrate_v9(),
                10 => self.migrate_v10(),
                11 => self.migrate_v11(),
                _ => Err(AppError::StorageError(format!("no migration defined for v{next}"))),
            };
            step.map_err(|e| migration_failed(next, e))?;
            tx.pragma_update(None, PRAGMA_USER_VERSION, next).map_err(map_sql)?;
            tx.commit()
                .map_err(|e| migration_failed(next, e))?;
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

    /// v5 — per-route request timeouts. One row per overridden route key
    /// (see client::routes::ROUTES); routes without a row use the global
    /// timeout.
    fn migrate_v5(&self) -> Result<(), AppError> {
        self.conn
            .execute(
                "CREATE TABLE route_timeouts (
                     route_key    TEXT PRIMARY KEY,
                     timeout_secs INTEGER NOT NULL
                 )",
                [],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// v6 — collection cache. Collections were the one browsable thing the
    /// app never cached; every /collections index page now lands here
    /// (upsert by slug), which is also what the library-scoped collection
    /// search reads. Cache-forever like everything else — rows refresh
    /// whenever a browse fetches their page again.
    fn migrate_v6(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "CREATE TABLE collections (
                     name             TEXT PRIMARY KEY,
                     title            TEXT NOT NULL,
                     summary          TEXT NOT NULL DEFAULT '',
                     is_open          INTEGER NOT NULL DEFAULT 0,
                     is_moderated     INTEGER NOT NULL DEFAULT 0,
                     is_anonymous     INTEGER NOT NULL DEFAULT 0,
                     work_count       INTEGER NOT NULL DEFAULT 0,
                     bookmarked_count INTEGER NOT NULL DEFAULT 0,
                     maintainers_json TEXT NOT NULL DEFAULT '[]',
                     collection_type  TEXT NOT NULL DEFAULT '',
                     fetched_at       TEXT NOT NULL DEFAULT ''
                 );
                 CREATE INDEX idx_collections_title ON collections(title COLLATE NOCASE);",
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// v7 — reading position moves onto `works` (2026-08):
    /// * `works.last_chapter_read`: 1-based chapter the reader last had open
    ///   (0 = never opened). Replaces the `reading_progress` table — one
    ///   position per work is all the reader ever tracked.
    /// * `works.last_chapter_read_pos`: character offset (into the chapter's
    ///   plain text) of the first line visible when the reader left. The old
    ///   table stored a scroll *fraction*, which lands somewhere else the
    ///   moment fonts, size, or pane width change — offsets can't be
    ///   converted, so positions reset to chapter top on upgrade (the
    ///   chapter itself is kept).
    fn migrate_v7(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "ALTER TABLE works ADD COLUMN last_chapter_read INTEGER NOT NULL DEFAULT 0;
                 ALTER TABLE works ADD COLUMN last_chapter_read_pos INTEGER NOT NULL DEFAULT 0;",
            )
            .map_err(map_sql)?;
        // A database that skipped the v1 baseline may not have the old
        // table at all — backfill only where there's something to copy.
        let has_old_table: bool = self
            .conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master
                                WHERE type = 'table' AND name = 'reading_progress')",
                [],
                |r| r.get(0),
            )
            .map_err(map_sql)?;
        if has_old_table {
            self.conn
                .execute_batch(
                    "UPDATE works SET last_chapter_read = COALESCE(
                         (SELECT rp.chapter FROM reading_progress rp WHERE rp.work_id = works.id), 0);
                     DROP TABLE reading_progress;",
                )
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// v8 — tags become first-class rows (2026-08). The autocomplete cache
    /// `known_tags` was already the tag table in all but name: it becomes
    /// `tags`, gaining an id and keeping its uses/canonical/last_seen
    /// ranking columns. Tag identity is the name alone — AO3 tag names are
    /// globally unique across every tag type (hence the "- Freeform"
    /// suffixes) — so duplicate (name, type) rows merge: the most-used
    /// row's type wins, uses sum, canonical and last_seen keep their max.
    /// "" for tag_type means "type not yet learned" (e.g. a tag first seen
    /// on a collection profile, which doesn't state types).
    ///
    /// The works table's four tag JSON list columns become `work_tags` join
    /// rows (`tag_type` records which blurb list, `position` AO3's display
    /// order); `collection_tags` and `collection_works` cache what a
    /// collection's /profile and works listing showed. All three join
    /// tables declare ON DELETE CASCADE foreign keys on both sides, so
    /// deleting a work, collection, or tag row deletes its join rows
    /// automatically. `collections.profile_fetched_at` records that the
    /// /profile page was cached (cache-forever guard, like everything else).
    fn migrate_v8(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS known_tags (
                     name      TEXT NOT NULL,
                     tag_type  TEXT NOT NULL,
                     uses      INTEGER NOT NULL DEFAULT 1,
                     canonical INTEGER NOT NULL DEFAULT 0,
                     last_seen TEXT NOT NULL DEFAULT (datetime('now')),
                     PRIMARY KEY (name, tag_type)
                 ); -- a database that skipped the v1 baseline may lack it
                 CREATE TABLE tags (
                     id        INTEGER PRIMARY KEY AUTOINCREMENT,
                     name      TEXT NOT NULL UNIQUE,
                     tag_type  TEXT NOT NULL DEFAULT '',
                     uses      INTEGER NOT NULL DEFAULT 1,
                     canonical INTEGER NOT NULL DEFAULT 0,
                     last_seen TEXT NOT NULL DEFAULT (datetime('now'))
                 );
                 INSERT INTO tags (name, tag_type, uses, canonical, last_seen)
                     SELECT kt.name,
                            (SELECT k2.tag_type FROM known_tags k2 WHERE k2.name = kt.name
                              ORDER BY k2.uses DESC, k2.canonical DESC, k2.last_seen DESC
                              LIMIT 1),
                            SUM(kt.uses), MAX(kt.canonical), MAX(kt.last_seen)
                     FROM known_tags kt GROUP BY kt.name;
                 DROP TABLE known_tags;
                 CREATE INDEX idx_tags_lookup ON tags(tag_type, name COLLATE NOCASE);
                 CREATE TABLE work_tags (
                     work_id  INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                     tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                     tag_type TEXT NOT NULL DEFAULT '',
                     position INTEGER NOT NULL DEFAULT 0,
                     PRIMARY KEY (work_id, tag_id)
                 );
                 CREATE INDEX idx_work_tags_tag ON work_tags(tag_id);
                 CREATE TABLE collection_tags (
                     collection_name TEXT NOT NULL REFERENCES collections(name) ON DELETE CASCADE,
                     tag_id          INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                     position        INTEGER NOT NULL DEFAULT 0,
                     PRIMARY KEY (collection_name, tag_id)
                 );
                 CREATE INDEX idx_collection_tags_tag ON collection_tags(tag_id);
                 CREATE TABLE collection_works (
                     collection_name TEXT NOT NULL REFERENCES collections(name) ON DELETE CASCADE,
                     work_id         INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                     PRIMARY KEY (collection_name, work_id)
                 );
                 CREATE INDEX idx_collection_works_work ON collection_works(work_id);
                 ALTER TABLE collections ADD COLUMN profile_fetched_at TEXT NOT NULL DEFAULT '';",
            )
            .map_err(map_sql)?;
        self.backfill_work_tags_v8()?;
        self.conn
            .execute_batch(
                "ALTER TABLE works DROP COLUMN fandoms_json;
                 ALTER TABLE works DROP COLUMN relationships_json;
                 ALTER TABLE works DROP COLUMN characters_json;
                 ALTER TABLE works DROP COLUMN tags_json;",
            )
            .map_err(map_sql)
    }

    /// v9 — collection bookmark caching (2026-08). `collection_bookmarks`
    /// mirrors `collection_works`: which cached works a collection's
    /// /bookmarks listing showed, in listing order. Also added a
    /// `bookmarks.bookmarker` column, which v10 dropped the same day —
    /// account identity already carries the AO3 username.
    fn migrate_v9(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "ALTER TABLE bookmarks ADD COLUMN bookmarker TEXT NOT NULL DEFAULT '';
                 CREATE TABLE collection_bookmarks (
                     collection_name TEXT NOT NULL REFERENCES collections(name) ON DELETE CASCADE,
                     work_id         INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                     PRIMARY KEY (collection_name, work_id)
                 );
                 CREATE INDEX idx_collection_bookmarks_work ON collection_bookmarks(work_id);",
            )
            .map_err(map_sql)
    }

    /// v10 — account ids are AO3 usernames (2026-08). Every account is an
    /// AO3 account, so the id IS the username, lowercased — no `account-`
    /// prefix, no parallel `ao3:{username}` namespace for bookmarks seen
    /// in fetched listings, no `bookmarker` column duplicating what the
    /// row's account id already says. The one non-account context,
    /// bookmarks made while signed out, moves from "" to the explicit
    /// LOGGED_OUT_ACCOUNT_ID sentinel ("[none]" — brackets can't appear
    /// in an AO3 username, so it can never collide with a real account).
    /// "Mine" remains rows whose account_id matches the active account.
    fn migrate_v10(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "ALTER TABLE bookmarks DROP COLUMN bookmarker;
                 UPDATE accounts SET id = substr(id, 9) WHERE id LIKE 'account-%';
                 UPDATE OR IGNORE bookmarks SET account_id = substr(account_id, 9)
                    WHERE account_id LIKE 'account-%';
                 DELETE FROM bookmarks WHERE account_id LIKE 'account-%';
                 UPDATE OR IGNORE bookmarks SET account_id = substr(account_id, 5)
                    WHERE account_id LIKE 'ao3:%';
                 DELETE FROM bookmarks WHERE account_id LIKE 'ao3:%';
                 UPDATE bookmarks SET account_id = '[none]' WHERE account_id = '';",
            )
            .map_err(map_sql)
    }

    /// v11 — SQL-backed library works search (2026-08): typed filter columns
    /// so the works-search form compiles to one SQL pass instead of
    /// hydrating every row and filtering in Rust.
    /// * `warnings_mask` / `categories_mask`: bitmasks over the fixed AO3
    ///   vocabularies (bit assignments in storage::works_search), backfilled
    ///   from the JSON columns — which stay, for display hydration.
    /// * `fandom_count`: write-time count of fandom tags (crossover = > 1).
    /// * works(date_updated DESC): index for the default sort.
    fn migrate_v11(&self) -> Result<(), AppError> {
        self.conn
            .execute_batch(
                "ALTER TABLE works ADD COLUMN warnings_mask INTEGER NOT NULL DEFAULT 0;
                 ALTER TABLE works ADD COLUMN categories_mask INTEGER NOT NULL DEFAULT 0;
                 ALTER TABLE works ADD COLUMN fandom_count INTEGER NOT NULL DEFAULT 0;
                 CREATE INDEX idx_works_date_updated ON works(date_updated DESC);
                 UPDATE works SET fandom_count =
                     (SELECT COUNT(*) FROM work_tags wt
                       WHERE wt.work_id = works.id AND wt.tag_type = 'fandom');",
            )
            .map_err(map_sql)?;
        self.backfill_search_masks_v11()
    }

    /// A write transaction for multi-row batches. Statements executed on
    /// `self` while the guard lives join the transaction; dropping it
    /// without `commit()` rolls everything back — and resyncs the in-memory
    /// caches, since the rollback may have discarded state they recorded.
    pub fn begin_tx(&self) -> Result<TxGuard<'_>, AppError> {
        Ok(TxGuard {
            tx: Some(self.conn.unchecked_transaction().map_err(map_sql)?),
            storage: self,
        })
    }

    /// Reload the in-memory caches from the database — the recovery for any
    /// rollback that may have discarded rows they already recorded.
    fn resync_caches(&self) {
        let _ = self.tag_cache.load(&self.conn);
        let _ = self.works_cache.load(&self.conn);
        let _ = self.state_cache.load(&self.conn);
    }

    /// Run `f` atomically inside a named savepoint. Unlike BEGIN, savepoints
    /// nest — so a method wrapped this way still composes inside a caller's
    /// begin_tx() batch (or another savepoint).
    pub(super) fn with_savepoint<T>(
        &self,
        sp: Savepoint,
        f: impl FnOnce() -> Result<T, AppError>,
    ) -> Result<T, AppError> {
        let name = sp.name();
        self.conn
            .execute_batch(&format!("{SQL_SAVEPOINT} {name}"))
            .map_err(map_sql)?;
        match f() {
            Ok(v) => {
                self.conn.execute_batch(&format!("{SQL_RELEASE} {name}")).map_err(map_sql)?;
                Ok(v)
            }
            Err(e) => {
                let _ = self
                    .conn
                    .execute_batch(&format!("{SQL_ROLLBACK_TO} {name}; {SQL_RELEASE} {name}"));
                // The rollback may have discarded rows the in-memory caches
                // already recorded (a dead tag id would break later join
                // inserts); resync them with the table truth.
                self.resync_caches();
                Err(e)
            }
        }
    }

    pub fn change_passphrase(&self, new_passphrase: &str) -> Result<(), AppError> {
        if new_passphrase.is_empty() {
            self.conn.pragma_update(None, PRAGMA_REKEY, "").map_err(map_sql)?;
        } else {
            self.conn.pragma_update(None, PRAGMA_REKEY, new_passphrase).map_err(map_sql)?;
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
        // Inline SQL, not get_state/set_state — this runs before the state
        // cache loads, and migration steps stay version-frozen anyway.
        let reset_done: bool = self
            .conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM app_state WHERE key = 'avatar_cache_reset_1')",
                [], |r| r.get(0),
            )
            .unwrap_or(false);
        if !reset_done {
            let _ = self.conn.execute("DELETE FROM image_cache WHERE key LIKE 'avatar:%'", []);
            let _ = self.conn.execute(
                "INSERT OR REPLACE INTO app_state (key, value) VALUES ('avatar_cache_reset_1', '1')",
                [],
            );
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
