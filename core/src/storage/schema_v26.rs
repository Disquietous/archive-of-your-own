//! v26 — every entity gets its own row id (2026-11, multi-source Phase 1).
//!
//! Before this version the AO3 identifier *was* the key: works and series
//! by AO3 number, collections by slug, users and accounts by username,
//! comments and inbox messages by AO3 comment number, and every dependent
//! table borrowed those keys as loose integers or text. From v26 on each
//! entity has an integer row id, its origin is `source` + `external_id`
//! (unique together) plus the canonical `url`, and every dependent table
//! points at row ids with a real foreign key (or, for polymorphic targets,
//! kind + id guarded by triggers). Existing works, series, comments and
//! inbox rows keep their AO3 numbers as row ids so nothing the UI holds
//! changes value; text-keyed entities (accounts, users, collections) are
//! renumbered and their dependents re-pointed through mapping tables.
//!
//! Also here, because they are one schema version (Area 6.5):
//! * work stats become nullable (absent, never zero — Area 3.1);
//! * the `fields` registry and `work_stats` (Area 3.3), empty for AO3;
//! * the bookmarks split into `app_bookmarks` and `ao3_bookmarks` (Area 7);
//! * `request_log.source`.
//!
//! Version-frozen: inline SQL and inline vocabulary only, never the live
//! helpers or constants, so later edits can't change what this replays.
//! The whole step runs with foreign keys OFF (table rebuilds would
//! otherwise cascade-delete children when the old parent is dropped) and
//! ends with `PRAGMA foreign_key_check`, which must come back empty.

use rusqlite::{params, OptionalExtension};

use crate::error::AppError;

use super::{map_sql, Storage};

const AO3: &str = "ao3";
const BASE: &str = "https://archiveofourown.org";

/// Shape of a pre-v26 `series_json` entry, frozen here so the rewrite
/// below never depends on the live model.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct OldMembership {
    series_id: u64,
    name: String,
    #[serde(default)]
    part: u32,
    #[serde(default)]
    prev_work_id: Option<u64>,
    #[serde(default)]
    next_work_id: Option<u64>,
}

#[derive(serde::Serialize)]
struct NewMembership {
    series_id: u64,
    series_external_id: String,
    name: String,
    part: u32,
    prev_work_external_id: Option<String>,
    next_work_external_id: Option<String>,
}

impl Storage {
    pub(super) fn migrate_v26(&self) -> Result<(), AppError> {
        let fk_on: bool = self.conn
            .query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
            .map_err(map_sql)? != 0;
        if fk_on {
            return Err(AppError::StorageError(
                "v26 must run with foreign keys off (table rebuilds)".into()));
        }
        // Each step guards on its own table's shape, so a library that is
        // partly in the v26 shape (a resumed migration, or a test that
        // rewinds one table over a current schema) rebuilds only what is
        // still old. A hand-built pre-versioning library may lack tables
        // the baseline would have created; they are created empty first.
        self.v26_ensure_legacy_tables()?;
        // The v15 bookmark triggers name `works` and `series`, which the
        // rebuild drops and recreates; a trigger pointing at a missing
        // table makes the schema unparseable in between. They are
        // recreated against the new tables in the bookmarks split.
        self.v26_exec(
            "DROP TRIGGER IF EXISTS bookmarks_target_exists_ins;
             DROP TRIGGER IF EXISTS bookmarks_target_exists_upd;
             DROP TRIGGER IF EXISTS bookmarks_cascade_work;
             DROP TRIGGER IF EXISTS bookmarks_cascade_series;
             CREATE TEMP TABLE IF NOT EXISTS v26_acct_map (old_id TEXT NOT NULL PRIMARY KEY, new_id INTEGER NOT NULL);
             CREATE TEMP TABLE IF NOT EXISTS v26_user_map (old_id TEXT NOT NULL COLLATE NOCASE PRIMARY KEY, new_id INTEGER NOT NULL);
             CREATE TEMP TABLE IF NOT EXISTS v26_coll_map (old_name TEXT NOT NULL PRIMARY KEY, new_id INTEGER NOT NULL);
             CREATE TEMP TABLE IF NOT EXISTS v26_bm_map (old_id INTEGER NOT NULL PRIMARY KEY, new_id INTEGER NOT NULL);",
        )?;
        self.v26_accounts()?;
        self.v26_users()?;
        self.v26_works()?;
        self.v26_series()?;
        self.v26_collections()?;
        self.v26_comments_and_inbox()?;
        self.v26_work_dependents()?;
        self.v26_follows_and_stamps()?;
        self.v26_subscriptions_and_drafts()?;
        self.v26_bookmarks_split()?;
        self.v26_collection_joins()?;
        self.v26_fields()?;
        self.v26_request_log()?;
        self.v26_rewrite_series_json()?;
        self.v26_purge_orphans()?;
        self.conn.execute_batch(
            "DROP TABLE IF EXISTS v26_acct_map;
             DROP TABLE IF EXISTS v26_user_map;
             DROP TABLE IF EXISTS v26_coll_map;
             DROP TABLE IF EXISTS v26_bm_map;",
        ).map_err(map_sql)?;
        self.v26_foreign_key_check()
    }

    fn v26_exec(&self, sql: &str) -> Result<(), AppError> {
        self.conn.execute_batch(sql).map_err(map_sql)
    }

    fn v26_table_exists(&self, table: &str) -> Result<bool, AppError> {
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table], |r| r.get(0),
        ).map_err(map_sql)?;
        Ok(n > 0)
    }

    /// Whether a table's CREATE statement mentions `needle` — how the
    /// rebuilt join tables (same columns, new foreign keys) are told apart
    /// from their pre-v26 shape.
    fn v26_table_sql_contains(&self, table: &str, needle: &str) -> Result<bool, AppError> {
        let sql: Option<String> = self.conn.query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table], |r| r.get(0),
        ).optional().map_err(map_sql)?;
        Ok(sql.is_some_and(|s| s.contains(needle)))
    }

    /// Every table the rebuild reads, in its pre-v26 shape, created empty
    /// when missing. A real library has them all (the baseline created
    /// them on every open); a hand-built pre-versioning fixture may not.
    /// Version-frozen like the rest of this file.
    fn v26_ensure_legacy_tables(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, username TEXT NOT NULL,
                password TEXT NOT NULL DEFAULT '', cookies TEXT NOT NULL DEFAULT '',
                is_active INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS ao3_users (id TEXT PRIMARY KEY, username TEXT NOT NULL,
                profile_url TEXT NOT NULL DEFAULT '', avatar_url TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL DEFAULT (datetime('now')), numeric_id TEXT NOT NULL DEFAULT '',
                joined TEXT NOT NULL DEFAULT '', location TEXT NOT NULL DEFAULT '',
                birthday TEXT NOT NULL DEFAULT '', pseuds_json TEXT NOT NULL DEFAULT '[]',
                bio_json TEXT NOT NULL DEFAULT '[]', works_count INTEGER NOT NULL DEFAULT 0,
                series_count INTEGER NOT NULL DEFAULT 0, bookmarks_count INTEGER NOT NULL DEFAULT 0,
                collections_count INTEGER NOT NULL DEFAULT 0, gifts_count INTEGER NOT NULL DEFAULT 0,
                is_blocked INTEGER NOT NULL DEFAULT 0, block_ao3_id TEXT NOT NULL DEFAULT '',
                is_muted INTEGER NOT NULL DEFAULT 0, mute_ao3_id TEXT NOT NULL DEFAULT '',
                profile_fetched_at TEXT NOT NULL DEFAULT '');
             CREATE TABLE IF NOT EXISTS series (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
                authors_json TEXT NOT NULL DEFAULT '[]', summary TEXT NOT NULL DEFAULT '',
                word_count INTEGER NOT NULL DEFAULT 0, work_count INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 0, date_updated TEXT NOT NULL DEFAULT '',
                fetched_at TEXT NOT NULL DEFAULT '');
             CREATE TABLE IF NOT EXISTS collections (name TEXT PRIMARY KEY, title TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '', is_open INTEGER NOT NULL DEFAULT 0,
                is_moderated INTEGER NOT NULL DEFAULT 0, is_anonymous INTEGER NOT NULL DEFAULT 0,
                work_count INTEGER NOT NULL DEFAULT 0, bookmarked_count INTEGER NOT NULL DEFAULT 0,
                maintainers_json TEXT NOT NULL DEFAULT '[]', collection_type TEXT NOT NULL DEFAULT '',
                fetched_at TEXT NOT NULL DEFAULT '', profile_fetched_at TEXT NOT NULL DEFAULT '');
             CREATE TABLE IF NOT EXISTS comments (id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL DEFAULT 0,
                chapter_id INTEGER NOT NULL DEFAULT 0, parent_id INTEGER NOT NULL DEFAULT 0,
                author_id TEXT NOT NULL, posted_at TEXT NOT NULL DEFAULT '',
                content_json TEXT NOT NULL DEFAULT '[]', cached_at TEXT NOT NULL DEFAULT (datetime('now')),
                author_pseud TEXT NOT NULL DEFAULT '', chapter_label TEXT NOT NULL DEFAULT '',
                notice TEXT NOT NULL DEFAULT '', more_replies INTEGER NOT NULL DEFAULT 0);
             CREATE TABLE IF NOT EXISTS inbox_messages (comment_id INTEGER PRIMARY KEY, author TEXT NOT NULL,
                author_url TEXT NOT NULL DEFAULT '', avatar_url TEXT NOT NULL DEFAULT '',
                work_reference TEXT NOT NULL, work_url TEXT NOT NULL DEFAULT '', posted_at TEXT NOT NULL,
                is_unread INTEGER NOT NULL DEFAULT 1, content_json TEXT NOT NULL DEFAULT '[]',
                fetched_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS chapters (work_id INTEGER NOT NULL, number INTEGER NOT NULL,
                chapter_id INTEGER, title TEXT, content_json TEXT NOT NULL, notes_before TEXT,
                notes_after TEXT, comments_fetched_at INTEGER, PRIMARY KEY (work_id, number));
             CREATE TABLE IF NOT EXISTS work_authors (work_id INTEGER NOT NULL, author TEXT NOT NULL,
                PRIMARY KEY (author, work_id));
             CREATE TABLE IF NOT EXISTS downloads (work_id INTEGER PRIMARY KEY,
                created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS history (work_id INTEGER NOT NULL,
                accessed_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS kudos_given (work_id INTEGER PRIMARY KEY);
             CREATE TABLE IF NOT EXISTS subscription_new_works (work_id INTEGER PRIMARY KEY,
                added_at TEXT NOT NULL DEFAULT (datetime('now')), seen_at TEXT NOT NULL DEFAULT '');
             CREATE TABLE IF NOT EXISTS reading_lists (id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS reading_list_items (list_id INTEGER NOT NULL, work_id INTEGER NOT NULL,
                added_at TEXT NOT NULL DEFAULT (datetime('now')), sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (list_id, work_id));
             CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
                tag_type TEXT NOT NULL DEFAULT '', uses INTEGER NOT NULL DEFAULT 1,
                canonical INTEGER NOT NULL DEFAULT 0, last_seen TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS follows (kind TEXT NOT NULL, target_id TEXT NOT NULL COLLATE NOCASE,
                name TEXT NOT NULL, added_at TEXT NOT NULL DEFAULT (datetime('now')), date_updated TEXT,
                last_checked_at TEXT, total_works INTEGER, last_census_at TEXT, census_state TEXT,
                status INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (kind, target_id));
             CREATE TABLE IF NOT EXISTS crawl_stamps (kind TEXT NOT NULL, target_id TEXT NOT NULL COLLATE NOCASE,
                crawled_at TEXT NOT NULL, PRIMARY KEY (kind, target_id));
             CREATE TABLE IF NOT EXISTS subscriptions (account TEXT NOT NULL COLLATE NOCASE, sub_type TEXT NOT NULL,
                sub_id TEXT NOT NULL COLLATE NOCASE, name TEXT NOT NULL, ao3_id TEXT,
                PRIMARY KEY (account, sub_type, sub_id));
             CREATE TABLE IF NOT EXISTS comment_drafts (account_id TEXT NOT NULL COLLATE NOCASE,
                work_id INTEGER NOT NULL, chapter_id INTEGER NOT NULL DEFAULT 0,
                parent_comment_id INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL, updated_at TEXT NOT NULL,
                PRIMARY KEY (account_id, work_id, chapter_id));
             CREATE TABLE IF NOT EXISTS bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL DEFAULT '[none]', bookmark_type TEXT NOT NULL,
                target_id INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', tag_string TEXT NOT NULL DEFAULT '',
                collection_names TEXT NOT NULL DEFAULT '', private INTEGER NOT NULL DEFAULT 1,
                rec INTEGER NOT NULL DEFAULT 0, sync_to_ao3 INTEGER NOT NULL DEFAULT 0,
                ao3_bookmark_id INTEGER, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS collection_tags (collection_name TEXT NOT NULL, tag_id INTEGER NOT NULL,
                position INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (collection_name, tag_id));
             CREATE TABLE IF NOT EXISTS collection_works (collection_name TEXT NOT NULL, work_id INTEGER NOT NULL,
                PRIMARY KEY (collection_name, work_id));
             CREATE TABLE IF NOT EXISTS collection_bookmarks (collection_name TEXT NOT NULL, bookmark_id INTEGER NOT NULL,
                PRIMARY KEY (collection_name, bookmark_id));",
        )
    }

    fn v26_column_exists(&self, table: &str, column: &str) -> Result<bool, AppError> {
        let mut stmt = self.conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .map_err(map_sql)?;
        let names = stmt.query_map([], |r| r.get::<_, String>(1)).map_err(map_sql)?;
        for n in names {
            if n.map_err(map_sql)? == column {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Accounts: integer row id, source, external id = lowercased
    /// username. Duplicate spellings of one username (a legacy
    /// `migrated-x` row beside `x`) fold into one row, the active or
    /// signed-in one winning; `v26_acct_map` records old id → new id for
    /// the dependents.
    fn v26_accounts(&self) -> Result<(), AppError> {
        if self.v26_column_exists("accounts", "source")? {
            return self.v26_exec(
                "INSERT OR IGNORE INTO v26_acct_map (old_id, new_id) SELECT CAST(id AS TEXT), id FROM accounts;");
        }
        self.v26_exec(
            "CREATE TABLE accounts_v26 (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                source      TEXT NOT NULL DEFAULT 'ao3',
                external_id TEXT NOT NULL,
                username    TEXT NOT NULL,
                password    TEXT NOT NULL DEFAULT '',
                cookies     TEXT NOT NULL DEFAULT '',
                is_active   INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE (source, external_id)
             );
             CREATE UNIQUE INDEX idx_accounts_active ON accounts_v26 (source) WHERE is_active = 1;
             INSERT OR IGNORE INTO accounts_v26 (source, external_id, username, cookies, created_at)
                 SELECT 'ao3', lower(username), username, cookies, created_at FROM accounts
                 WHERE username != ''
                 ORDER BY is_active DESC, (cookies != '') DESC, created_at DESC;
             INSERT INTO v26_acct_map (old_id, new_id)
                 SELECT a.id, n.id FROM accounts a JOIN accounts_v26 n ON n.external_id = lower(a.username);
             UPDATE accounts_v26 SET is_active = 1 WHERE id = (
                 SELECT m.new_id FROM accounts a JOIN v26_acct_map m ON m.old_id = a.id
                 WHERE a.is_active = 1 ORDER BY a.created_at DESC LIMIT 1);
             DROP TABLE accounts;
             ALTER TABLE accounts_v26 RENAME TO accounts;",
        )
    }

    /// Users: integer row id; `external_id` is the old text key (the
    /// account username as first seen, or a `guest:` key); `url`
    /// replaces `profile_url`.
    fn v26_users(&self) -> Result<(), AppError> {
        if self.v26_column_exists("ao3_users", "external_id")? {
            return self.v26_exec(
                "INSERT OR IGNORE INTO v26_user_map (old_id, new_id) SELECT external_id, id FROM ao3_users;");
        }
        self.v26_exec(
            "CREATE TABLE ao3_users_v26 (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                source            TEXT NOT NULL DEFAULT 'ao3',
                external_id       TEXT NOT NULL COLLATE NOCASE,
                url               TEXT NOT NULL DEFAULT '',
                username          TEXT NOT NULL,
                avatar_url        TEXT NOT NULL DEFAULT '',
                updated_at        TEXT NOT NULL DEFAULT (datetime('now')),
                numeric_id        TEXT NOT NULL DEFAULT '',
                joined            TEXT NOT NULL DEFAULT '',
                location          TEXT NOT NULL DEFAULT '',
                birthday          TEXT NOT NULL DEFAULT '',
                pseuds_json       TEXT NOT NULL DEFAULT '[]',
                bio_json          TEXT NOT NULL DEFAULT '[]',
                works_count       INTEGER NOT NULL DEFAULT 0,
                series_count      INTEGER NOT NULL DEFAULT 0,
                bookmarks_count   INTEGER NOT NULL DEFAULT 0,
                collections_count INTEGER NOT NULL DEFAULT 0,
                gifts_count       INTEGER NOT NULL DEFAULT 0,
                is_blocked        INTEGER NOT NULL DEFAULT 0,
                block_ao3_id      TEXT NOT NULL DEFAULT '',
                is_muted          INTEGER NOT NULL DEFAULT 0,
                mute_ao3_id       TEXT NOT NULL DEFAULT '',
                profile_fetched_at TEXT NOT NULL DEFAULT '',
                UNIQUE (source, external_id)
             );
             INSERT OR IGNORE INTO ao3_users_v26 (source, external_id, url, username, avatar_url, updated_at,
                     numeric_id, joined, location, birthday, pseuds_json, bio_json, works_count, series_count,
                     bookmarks_count, collections_count, gifts_count, is_blocked, block_ao3_id, is_muted,
                     mute_ao3_id, profile_fetched_at)
                 SELECT 'ao3', id, profile_url, username, avatar_url, updated_at,
                     numeric_id, joined, location, birthday, pseuds_json, bio_json, works_count, series_count,
                     bookmarks_count, collections_count, gifts_count, is_blocked, block_ao3_id, is_muted,
                     mute_ao3_id, profile_fetched_at
                 FROM ao3_users ORDER BY (profile_fetched_at != '') DESC, updated_at DESC;
             INSERT INTO v26_user_map (old_id, new_id)
                 SELECT u.id, n.id FROM ao3_users u JOIN ao3_users_v26 n ON n.external_id = u.id;
             DROP TABLE ao3_users;
             ALTER TABLE ao3_users_v26 RENAME TO ao3_users;
             CREATE INDEX idx_ao3_users_username ON ao3_users (username COLLATE NOCASE);",
        )
    }

    /// Works keep their AO3 numbers as row ids. Stats become nullable;
    /// the AO3 backfill keeps every value.
    fn v26_works(&self) -> Result<(), AppError> {
        if self.v26_column_exists("works", "external_id")? {
            return Ok(());
        }
        self.v26_exec(
            "CREATE TABLE works_v26 (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                source          TEXT NOT NULL DEFAULT 'ao3',
                external_id     TEXT NOT NULL,
                url             TEXT NOT NULL DEFAULT '',
                stub            INTEGER NOT NULL DEFAULT 0,
                title           TEXT NOT NULL,
                authors_json    TEXT NOT NULL,
                rating          TEXT NOT NULL,
                warnings_json   TEXT NOT NULL,
                categories_json TEXT NOT NULL,
                summary         TEXT NOT NULL,
                word_count      INTEGER,
                chapter_count   INTEGER NOT NULL,
                total_chapters  INTEGER,
                kudos           INTEGER,
                hits            INTEGER,
                bookmarks       INTEGER,
                comments        INTEGER,
                date_published  TEXT NOT NULL DEFAULT '',
                date_updated    TEXT NOT NULL,
                language        TEXT NOT NULL,
                complete        INTEGER NOT NULL,
                series_json     TEXT NOT NULL DEFAULT '[]',
                detail_viewed_at TEXT NOT NULL DEFAULT '',
                last_read_dt    TEXT NOT NULL DEFAULT '',
                gone_from_ao3   INTEGER NOT NULL DEFAULT 0,
                fetched_at      TEXT NOT NULL DEFAULT '',
                last_chapter_read INTEGER NOT NULL DEFAULT 0,
                last_chapter_read_pos INTEGER NOT NULL DEFAULT 0,
                warnings_mask   INTEGER NOT NULL DEFAULT 0,
                categories_mask INTEGER NOT NULL DEFAULT 0,
                fandom_count    INTEGER NOT NULL DEFAULT 0,
                finished        INTEGER NOT NULL DEFAULT 0,
                UNIQUE (source, external_id)
             );
             INSERT INTO works_v26 (id, source, external_id, url, title, authors_json, rating, warnings_json,
                     categories_json, summary, word_count, chapter_count, total_chapters, kudos, hits, bookmarks,
                     comments, date_published, date_updated, language, complete, series_json, detail_viewed_at,
                     last_read_dt, gone_from_ao3, fetched_at, last_chapter_read, last_chapter_read_pos,
                     warnings_mask, categories_mask, fandom_count, finished)
                 SELECT id, 'ao3', CAST(id AS TEXT), 'https://archiveofourown.org/works/' || id, title,
                     authors_json, rating, warnings_json, categories_json, summary, word_count, chapter_count,
                     total_chapters, kudos, hits, bookmarks, comments, date_published, date_updated, language,
                     complete, series_json, detail_viewed_at, last_read_dt, gone_from_ao3, fetched_at,
                     last_chapter_read, last_chapter_read_pos, warnings_mask, categories_mask, fandom_count,
                     finished
                 FROM works;
             DROP TABLE works;
             ALTER TABLE works_v26 RENAME TO works;
             CREATE INDEX idx_works_date_updated ON works (date_updated DESC);
             CREATE INDEX idx_works_stub ON works (stub);",
        )
    }

    fn v26_series(&self) -> Result<(), AppError> {
        if self.v26_column_exists("series", "external_id")? {
            return Ok(());
        }
        self.v26_exec(
            "CREATE TABLE series_v26 (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                source       TEXT NOT NULL DEFAULT 'ao3',
                external_id  TEXT NOT NULL,
                url          TEXT NOT NULL DEFAULT '',
                name         TEXT NOT NULL DEFAULT '',
                authors_json TEXT NOT NULL DEFAULT '[]',
                summary      TEXT NOT NULL DEFAULT '',
                word_count   INTEGER NOT NULL DEFAULT 0,
                work_count   INTEGER NOT NULL DEFAULT 0,
                complete     INTEGER NOT NULL DEFAULT 0,
                date_updated TEXT NOT NULL DEFAULT '',
                fetched_at   TEXT NOT NULL DEFAULT '',
                UNIQUE (source, external_id)
             );
             INSERT INTO series_v26 (id, source, external_id, url, name, authors_json, summary, word_count,
                     work_count, complete, date_updated, fetched_at)
                 SELECT id, 'ao3', CAST(id AS TEXT), 'https://archiveofourown.org/series/' || id, name,
                     authors_json, summary, word_count, work_count, complete, date_updated, fetched_at
                 FROM series;
             DROP TABLE series;
             ALTER TABLE series_v26 RENAME TO series;",
        )
    }

    /// Collections: integer row id; the slug becomes `external_id`.
    fn v26_collections(&self) -> Result<(), AppError> {
        if self.v26_column_exists("collections", "external_id")? {
            return self.v26_exec(
                "INSERT OR IGNORE INTO v26_coll_map (old_name, new_id) SELECT external_id, id FROM collections;");
        }
        self.v26_exec(
            "CREATE TABLE collections_v26 (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                source           TEXT NOT NULL DEFAULT 'ao3',
                external_id      TEXT NOT NULL,
                url              TEXT NOT NULL DEFAULT '',
                title            TEXT NOT NULL,
                summary          TEXT NOT NULL DEFAULT '',
                is_open          INTEGER NOT NULL DEFAULT 0,
                is_moderated     INTEGER NOT NULL DEFAULT 0,
                is_anonymous     INTEGER NOT NULL DEFAULT 0,
                work_count       INTEGER NOT NULL DEFAULT 0,
                bookmarked_count INTEGER NOT NULL DEFAULT 0,
                maintainers_json TEXT NOT NULL DEFAULT '[]',
                collection_type  TEXT NOT NULL DEFAULT '',
                fetched_at       TEXT NOT NULL DEFAULT '',
                profile_fetched_at TEXT NOT NULL DEFAULT '',
                UNIQUE (source, external_id)
             );
             INSERT INTO collections_v26 (source, external_id, url, title, summary, is_open, is_moderated,
                     is_anonymous, work_count, bookmarked_count, maintainers_json, collection_type, fetched_at,
                     profile_fetched_at)
                 SELECT 'ao3', name, 'https://archiveofourown.org/collections/' || name, title, summary, is_open,
                     is_moderated, is_anonymous, work_count, bookmarked_count, maintainers_json, collection_type,
                     fetched_at, profile_fetched_at
                 FROM collections ORDER BY rowid;
             INSERT INTO v26_coll_map (old_name, new_id)
                 SELECT c.name, n.id FROM collections c JOIN collections_v26 n ON n.external_id = c.name;
             DROP TABLE collections;
             ALTER TABLE collections_v26 RENAME TO collections;
             CREATE INDEX idx_collections_title ON collections (title COLLATE NOCASE);",
        )
    }

    /// Comments keep their AO3 numbers as row ids; parents become real
    /// (nullable) self-references, authors point at user rows, and the
    /// work reference is enforced — cached rows that lost their work (or
    /// whose work was never recorded) are dropped, as is any reply whose
    /// parent is not cached. Inbox messages get the same treatment.
    fn v26_comments_and_inbox(&self) -> Result<(), AppError> {
        if !self.v26_column_exists("comments", "external_id")? {
            self.v26_comments()?;
        }
        if !self.v26_column_exists("inbox_messages", "external_id")? {
            self.v26_inbox()?;
        }
        Ok(())
    }

    fn v26_comments(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE comments_v26 (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                source        TEXT NOT NULL DEFAULT 'ao3',
                external_id   TEXT NOT NULL,
                work_id       INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                chapter_id    INTEGER NOT NULL DEFAULT 0,
                parent_id     INTEGER REFERENCES comments(id) ON DELETE CASCADE,
                author_id     INTEGER NOT NULL REFERENCES ao3_users(id) ON DELETE CASCADE,
                author_pseud  TEXT NOT NULL DEFAULT '',
                posted_at     TEXT NOT NULL DEFAULT '',
                content_json  TEXT NOT NULL DEFAULT '[]',
                cached_at     TEXT NOT NULL DEFAULT (datetime('now')),
                chapter_label TEXT NOT NULL DEFAULT '',
                notice        TEXT NOT NULL DEFAULT '',
                more_replies  INTEGER NOT NULL DEFAULT 0,
                UNIQUE (source, external_id)
             );
             -- Keep exactly the comments reachable from a cached root
             -- (parent 0) through cached parents, each on a cached work
             -- with a mapped author: a reply whose parent is missing goes,
             -- and so does everything beneath it, so no kept row can
             -- point at a dropped parent.
             WITH RECURSIVE kept(id) AS (
                 SELECT c.id FROM comments c
                  WHERE c.parent_id = 0
                    AND EXISTS (SELECT 1 FROM works w WHERE w.id = c.work_id)
                    AND EXISTS (SELECT 1 FROM v26_user_map m WHERE m.old_id = c.author_id)
                 UNION
                 SELECT c.id FROM comments c JOIN kept k ON k.id = c.parent_id
                  WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = c.work_id)
                    AND EXISTS (SELECT 1 FROM v26_user_map m WHERE m.old_id = c.author_id)
             )
             INSERT INTO comments_v26 (id, source, external_id, work_id, chapter_id, parent_id, author_id,
                     author_pseud, posted_at, content_json, cached_at, chapter_label, notice, more_replies)
                 SELECT c.id, 'ao3', CAST(c.id AS TEXT), c.work_id, c.chapter_id,
                     NULLIF(c.parent_id, 0),
                     m.new_id, c.author_pseud, c.posted_at, c.content_json, c.cached_at, c.chapter_label,
                     c.notice, c.more_replies
                 FROM comments c
                 JOIN v26_user_map m ON m.old_id = c.author_id
                 WHERE c.id IN (SELECT id FROM kept);
             DROP TABLE comments;
             ALTER TABLE comments_v26 RENAME TO comments;
             CREATE INDEX idx_comments_work ON comments (work_id);
             CREATE INDEX idx_comments_chapter ON comments (chapter_id);
             CREATE INDEX idx_comments_parent ON comments (parent_id);
             CREATE INDEX idx_comments_author ON comments (author_id);",
        )
    }

    fn v26_inbox(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE inbox_messages_v26 (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                source         TEXT NOT NULL DEFAULT 'ao3',
                external_id    TEXT NOT NULL,
                author         TEXT NOT NULL,
                author_url     TEXT NOT NULL DEFAULT '',
                avatar_url     TEXT NOT NULL DEFAULT '',
                work_reference TEXT NOT NULL,
                work_url       TEXT NOT NULL DEFAULT '',
                posted_at      TEXT NOT NULL,
                is_unread      INTEGER NOT NULL DEFAULT 1,
                content_json   TEXT NOT NULL DEFAULT '[]',
                fetched_at     TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE (source, external_id)
             );
             INSERT INTO inbox_messages_v26 (id, source, external_id, author, author_url, avatar_url,
                     work_reference, work_url, posted_at, is_unread, content_json, fetched_at)
                 SELECT comment_id, 'ao3', CAST(comment_id AS TEXT), author, author_url, avatar_url,
                     work_reference, work_url, posted_at, is_unread, content_json, fetched_at
                 FROM inbox_messages;
             DROP TABLE inbox_messages;
             ALTER TABLE inbox_messages_v26 RENAME TO inbox_messages;
             CREATE INDEX idx_inbox_fetched ON inbox_messages (fetched_at DESC);",
        )
    }

    /// Every table that borrowed the work number: rebuilt with a real
    /// foreign key, orphans dropped. `work_tags` already had one.
    fn v26_work_dependents(&self) -> Result<(), AppError> {
        if self.v26_table_sql_contains("chapters", "REFERENCES works")? {
            return Ok(());
        }
        self.v26_exec(
            "CREATE TABLE chapters_v26 (
                work_id      INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                number       INTEGER NOT NULL,
                chapter_id   INTEGER,
                title        TEXT,
                content_json TEXT NOT NULL,
                notes_before TEXT,
                notes_after  TEXT,
                comments_fetched_at INTEGER,
                PRIMARY KEY (work_id, number)
             );
             INSERT INTO chapters_v26 SELECT work_id, number, chapter_id, title, content_json, notes_before,
                     notes_after, comments_fetched_at FROM chapters c
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = c.work_id);
             DROP TABLE chapters;
             ALTER TABLE chapters_v26 RENAME TO chapters;

             CREATE TABLE work_authors_v26 (
                work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                author  TEXT NOT NULL,
                PRIMARY KEY (author, work_id)
             );
             INSERT INTO work_authors_v26 SELECT work_id, author FROM work_authors a
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = a.work_id);
             DROP TABLE work_authors;
             ALTER TABLE work_authors_v26 RENAME TO work_authors;

             CREATE TABLE downloads_v26 (
                work_id    INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             INSERT INTO downloads_v26 SELECT work_id, created_at FROM downloads d
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = d.work_id);
             DROP TABLE downloads;
             ALTER TABLE downloads_v26 RENAME TO downloads;

             CREATE TABLE history_v26 (
                work_id     INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                accessed_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             INSERT INTO history_v26 SELECT work_id, accessed_at FROM history h
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = h.work_id);
             DROP TABLE history;
             ALTER TABLE history_v26 RENAME TO history;
             CREATE INDEX idx_history_accessed ON history (accessed_at DESC);

             CREATE TABLE kudos_given_v26 (
                work_id INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE
             );
             INSERT INTO kudos_given_v26 SELECT work_id FROM kudos_given k
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = k.work_id);
             DROP TABLE kudos_given;
             ALTER TABLE kudos_given_v26 RENAME TO kudos_given;

             CREATE TABLE subscription_new_works_v26 (
                work_id  INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE,
                added_at TEXT NOT NULL DEFAULT (datetime('now')),
                seen_at  TEXT NOT NULL DEFAULT ''
             );
             INSERT INTO subscription_new_works_v26 SELECT work_id, added_at, seen_at FROM subscription_new_works n
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = n.work_id);
             DROP TABLE subscription_new_works;
             ALTER TABLE subscription_new_works_v26 RENAME TO subscription_new_works;

             CREATE TABLE reading_list_items_v26 (
                list_id    INTEGER NOT NULL REFERENCES reading_lists(id) ON DELETE CASCADE,
                work_id    INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                added_at   TEXT NOT NULL DEFAULT (datetime('now')),
                sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (list_id, work_id)
             );
             INSERT INTO reading_list_items_v26 SELECT list_id, work_id, added_at, sort_order
                 FROM reading_list_items i
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = i.work_id)
                   AND EXISTS (SELECT 1 FROM reading_lists l WHERE l.id = i.list_id);
             DROP TABLE reading_list_items;
             ALTER TABLE reading_list_items_v26 RENAME TO reading_list_items;",
        )
    }

    /// Follows and crawl stamps point at row ids. A followed author gets a
    /// users row if it has none; a followed work or series the library
    /// never cached gets a stub row under its AO3 number so the follow
    /// (and its check state) survives; a followed fandom resolves to its
    /// tag row.
    fn v26_follows_and_stamps(&self) -> Result<(), AppError> {
        if self.v26_column_exists("follows", "id")? {
            return Ok(());
        }
        self.v26_exec(
            "DROP TRIGGER IF EXISTS follows_target_exists_ins;
             DROP TRIGGER IF EXISTS crawl_stamps_target_exists_ins;
             DROP TRIGGER IF EXISTS follows_cascade_work;
             DROP TRIGGER IF EXISTS follows_cascade_series;
             DROP TRIGGER IF EXISTS follows_cascade_user;
             DROP TRIGGER IF EXISTS follows_cascade_tag;
             CREATE TABLE follows_v26 (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                kind            TEXT NOT NULL,
                target_id       INTEGER NOT NULL,
                name            TEXT NOT NULL,
                added_at        TEXT NOT NULL DEFAULT (datetime('now')),
                date_updated    TEXT,
                last_checked_at TEXT,
                total_works     INTEGER,
                last_census_at  TEXT,
                census_state    TEXT,
                status          INTEGER NOT NULL DEFAULT 0,
                UNIQUE (kind, target_id)
             );
             CREATE TABLE crawl_stamps_v26 (
                kind       TEXT NOT NULL,
                target_id  INTEGER NOT NULL,
                crawled_at TEXT NOT NULL,
                PRIMARY KEY (kind, target_id)
             );",
        )?;
        // Targets first, so every follow and stamp has a row to point at.
        self.v26_exec(
            "INSERT OR IGNORE INTO ao3_users (source, external_id, url, username)
                 SELECT 'ao3', target_id, 'https://archiveofourown.org/users/' || target_id, target_id
                 FROM follows WHERE kind = 'author' AND target_id != ''
                   AND NOT EXISTS (SELECT 1 FROM ao3_users u WHERE u.external_id = follows.target_id COLLATE NOCASE);
             INSERT OR IGNORE INTO ao3_users (source, external_id, url, username)
                 SELECT 'ao3', target_id, 'https://archiveofourown.org/users/' || target_id, target_id
                 FROM crawl_stamps WHERE kind = 'author' AND target_id != ''
                   AND NOT EXISTS (SELECT 1 FROM ao3_users u WHERE u.external_id = crawl_stamps.target_id COLLATE NOCASE);
             INSERT OR IGNORE INTO works (id, source, external_id, url, stub, title, authors_json, rating,
                     warnings_json, categories_json, summary, chapter_count, date_updated, language, complete)
                 SELECT CAST(target_id AS INTEGER), 'ao3', target_id,
                     'https://archiveofourown.org/works/' || target_id, 1, name, '[]', 'NotRated', '[]', '[]',
                     '', 0, '', '', 0
                 FROM follows WHERE kind = 'work' AND target_id GLOB '[0-9]*' AND target_id NOT GLOB '*[^0-9]*'
                   AND NOT EXISTS (SELECT 1 FROM works w WHERE w.external_id = follows.target_id);
             INSERT OR IGNORE INTO series (id, source, external_id, url, name)
                 SELECT CAST(target_id AS INTEGER), 'ao3', target_id,
                     'https://archiveofourown.org/series/' || target_id, name
                 FROM follows WHERE kind = 'series' AND target_id GLOB '[0-9]*' AND target_id NOT GLOB '*[^0-9]*'
                   AND NOT EXISTS (SELECT 1 FROM series s WHERE s.external_id = follows.target_id);
             INSERT OR IGNORE INTO series (id, source, external_id, url, name)
                 SELECT CAST(target_id AS INTEGER), 'ao3', target_id,
                     'https://archiveofourown.org/series/' || target_id, ''
                 FROM crawl_stamps WHERE kind = 'series' AND target_id GLOB '[0-9]*' AND target_id NOT GLOB '*[^0-9]*'
                   AND NOT EXISTS (SELECT 1 FROM series s WHERE s.external_id = crawl_stamps.target_id);
             INSERT OR IGNORE INTO tags (name, tag_type)
                 SELECT target_id, 'fandom' FROM follows WHERE kind = 'fandom' AND target_id != '';",
        )?;
        self.v26_exec(
            "INSERT OR IGNORE INTO follows_v26 (kind, target_id, name, added_at, date_updated, last_checked_at,
                     total_works, last_census_at, census_state, status)
                 SELECT f.kind,
                     CASE f.kind
                         WHEN 'author' THEN (SELECT u.id FROM ao3_users u WHERE u.external_id = f.target_id COLLATE NOCASE)
                         WHEN 'work'   THEN (SELECT w.id FROM works w WHERE w.external_id = f.target_id)
                         WHEN 'series' THEN (SELECT s.id FROM series s WHERE s.external_id = f.target_id)
                         WHEN 'fandom' THEN (SELECT t.id FROM tags t WHERE t.name = f.target_id)
                     END,
                     f.name, f.added_at, f.date_updated, f.last_checked_at, f.total_works, f.last_census_at,
                     f.census_state, f.status
                 FROM follows f WHERE f.kind IN ('author', 'work', 'series', 'fandom')
                 ORDER BY f.rowid;
             DELETE FROM follows_v26 WHERE target_id IS NULL;
             INSERT OR IGNORE INTO crawl_stamps_v26 (kind, target_id, crawled_at)
                 SELECT c.kind,
                     CASE c.kind
                         WHEN 'author' THEN (SELECT u.id FROM ao3_users u WHERE u.external_id = c.target_id COLLATE NOCASE)
                         WHEN 'series' THEN (SELECT s.id FROM series s WHERE s.external_id = c.target_id)
                     END,
                     c.crawled_at
                 FROM crawl_stamps c WHERE c.kind IN ('author', 'series');
             DELETE FROM crawl_stamps_v26 WHERE target_id IS NULL;
             DROP TABLE follows;
             ALTER TABLE follows_v26 RENAME TO follows;
             DROP TABLE crawl_stamps;
             ALTER TABLE crawl_stamps_v26 RENAME TO crawl_stamps;

             CREATE TRIGGER follows_target_exists_ins BEFORE INSERT ON follows BEGIN
                SELECT RAISE(ABORT, 'follow target missing') WHERE NOT EXISTS (
                    SELECT 1 FROM works     WHERE NEW.kind = 'work'   AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM series    WHERE NEW.kind = 'series' AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM ao3_users WHERE NEW.kind = 'author' AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM tags      WHERE NEW.kind = 'fandom' AND id = NEW.target_id);
             END;
             CREATE TRIGGER crawl_stamps_target_exists_ins BEFORE INSERT ON crawl_stamps BEGIN
                SELECT RAISE(ABORT, 'crawl stamp target missing') WHERE NOT EXISTS (
                    SELECT 1 FROM series    WHERE NEW.kind = 'series' AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM ao3_users WHERE NEW.kind = 'author' AND id = NEW.target_id);
             END;
             CREATE TRIGGER follows_cascade_work AFTER DELETE ON works BEGIN
                DELETE FROM follows WHERE kind = 'work' AND target_id = OLD.id;
             END;
             CREATE TRIGGER follows_cascade_series AFTER DELETE ON series BEGIN
                DELETE FROM follows WHERE kind = 'series' AND target_id = OLD.id;
                DELETE FROM crawl_stamps WHERE kind = 'series' AND target_id = OLD.id;
             END;
             CREATE TRIGGER follows_cascade_user AFTER DELETE ON ao3_users BEGIN
                DELETE FROM follows WHERE kind = 'author' AND target_id = OLD.id;
                DELETE FROM crawl_stamps WHERE kind = 'author' AND target_id = OLD.id;
             END;
             CREATE TRIGGER follows_cascade_tag AFTER DELETE ON tags BEGIN
                DELETE FROM follows WHERE kind = 'fandom' AND target_id = OLD.id;
             END;",
        )
    }

    /// Subscriptions and comment drafts key on the account row id. Rows
    /// whose account no longer exists are dropped.
    fn v26_subscriptions_and_drafts(&self) -> Result<(), AppError> {
        if !self.v26_column_exists("subscriptions", "account_id")? {
            self.v26_subscriptions()?;
        }
        if !self.v26_table_sql_contains("comment_drafts", "REFERENCES accounts")? {
            self.v26_drafts()?;
        }
        Ok(())
    }

    fn v26_subscriptions(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE subscriptions_v26 (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                sub_type   TEXT NOT NULL,
                sub_id     TEXT NOT NULL COLLATE NOCASE,
                name       TEXT NOT NULL,
                ao3_id     TEXT,
                UNIQUE (account_id, sub_type, sub_id)
             );
             INSERT OR IGNORE INTO subscriptions_v26 (account_id, sub_type, sub_id, name, ao3_id)
                 SELECT a.id, s.sub_type, s.sub_id, s.name, s.ao3_id
                 FROM subscriptions s JOIN accounts a ON a.external_id = lower(s.account);
             DROP TABLE subscriptions;
             ALTER TABLE subscriptions_v26 RENAME TO subscriptions;",
        )
    }

    fn v26_drafts(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE comment_drafts_v26 (
                account_id        INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                work_id           INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                chapter_id        INTEGER NOT NULL DEFAULT 0,
                parent_comment_id INTEGER NOT NULL DEFAULT 0,
                body              TEXT    NOT NULL,
                updated_at        TEXT    NOT NULL,
                PRIMARY KEY (account_id, work_id, chapter_id)
             );
             INSERT OR IGNORE INTO comment_drafts_v26 (account_id, work_id, chapter_id, parent_comment_id, body, updated_at)
                 SELECT a.id, d.work_id, d.chapter_id, d.parent_comment_id, d.body, d.updated_at
                 FROM comment_drafts d JOIN accounts a ON a.external_id = lower(d.account_id)
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = d.work_id);
             DROP TABLE comment_drafts;
             ALTER TABLE comment_drafts_v26 RENAME TO comment_drafts;",
        )
    }

    /// The bookmarks split (Area 7). `app_bookmarks` is the flag;
    /// `ao3_bookmarks` is the AO3 record. A pre-v26 row copies to the app
    /// side when it belongs to a local account or was made signed out, and
    /// to the AO3 side when it has an AO3 id, sync intent, or any detail.
    /// `v26_bm_map` carries old row id → ao3_bookmarks id for the
    /// collection links.
    fn v26_bookmarks_split(&self) -> Result<(), AppError> {
        if self.v26_table_exists("app_bookmarks")? {
            return Ok(());
        }
        self.v26_exec(
            "DROP TRIGGER IF EXISTS bookmarks_target_exists_ins;
             DROP TRIGGER IF EXISTS bookmarks_target_exists_upd;
             DROP TRIGGER IF EXISTS bookmarks_cascade_work;
             DROP TRIGGER IF EXISTS bookmarks_cascade_series;

             CREATE TABLE app_bookmarks (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER REFERENCES accounts(id) ON DELETE CASCADE,
                kind       TEXT NOT NULL CHECK (kind IN ('work', 'series')),
                target_id  INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE UNIQUE INDEX idx_app_bookmarks_unique
                 ON app_bookmarks (COALESCE(account_id, 0), kind, target_id);
             CREATE INDEX idx_app_bookmarks_target ON app_bookmarks (kind, target_id);

             CREATE TABLE ao3_bookmarks (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                source           TEXT NOT NULL DEFAULT 'ao3',
                account_id       INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                owner            TEXT NOT NULL DEFAULT '',
                kind             TEXT NOT NULL CHECK (kind IN ('work', 'series')),
                target_id        INTEGER NOT NULL,
                ao3_bookmark_id  INTEGER,
                note             TEXT    NOT NULL DEFAULT '',
                tag_string       TEXT    NOT NULL DEFAULT '',
                collection_names TEXT    NOT NULL DEFAULT '',
                private          INTEGER NOT NULL DEFAULT 1,
                rec              INTEGER NOT NULL DEFAULT 0,
                sync_to_ao3      INTEGER NOT NULL DEFAULT 0,
                created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
                UNIQUE (owner, kind, target_id)
             );
             CREATE INDEX idx_ao3_bookmarks_target ON ao3_bookmarks (kind, target_id);
             CREATE INDEX idx_ao3_bookmarks_account ON ao3_bookmarks (account_id, created_at DESC);
             CREATE UNIQUE INDEX idx_ao3_bookmarks_ao3 ON ao3_bookmarks (ao3_bookmark_id)
                 WHERE ao3_bookmark_id IS NOT NULL;

             INSERT INTO app_bookmarks (account_id, kind, target_id, created_at)
                 SELECT CASE WHEN b.account_id = '[none]' THEN NULL ELSE a.id END,
                        b.bookmark_type, b.target_id, b.created_at
                 FROM bookmarks b LEFT JOIN accounts a ON a.external_id = lower(b.account_id)
                 WHERE (b.account_id = '[none]' OR a.id IS NOT NULL)
                   AND ((b.bookmark_type = 'work'   AND EXISTS (SELECT 1 FROM works  w WHERE w.id = b.target_id))
                     OR (b.bookmark_type = 'series' AND EXISTS (SELECT 1 FROM series s WHERE s.id = b.target_id)))
                 ORDER BY b.created_at, b.id;

             INSERT INTO ao3_bookmarks (source, account_id, owner, kind, target_id, ao3_bookmark_id, note,
                     tag_string, collection_names, private, rec, sync_to_ao3, created_at)
                 SELECT 'ao3', a.id, CASE WHEN b.account_id = '[none]' THEN '' ELSE lower(b.account_id) END,
                        b.bookmark_type, b.target_id, b.ao3_bookmark_id, b.note, b.tag_string,
                        b.collection_names, b.private, b.rec, b.sync_to_ao3, b.created_at
                 FROM bookmarks b LEFT JOIN accounts a ON a.external_id = lower(b.account_id)
                 WHERE (b.ao3_bookmark_id IS NOT NULL OR b.sync_to_ao3 = 1 OR b.note != '' OR b.tag_string != ''
                        OR b.collection_names != '' OR b.rec = 1 OR b.private = 0)
                   AND ((b.bookmark_type = 'work'   AND EXISTS (SELECT 1 FROM works  w WHERE w.id = b.target_id))
                     OR (b.bookmark_type = 'series' AND EXISTS (SELECT 1 FROM series s WHERE s.id = b.target_id)))
                 ORDER BY b.created_at, b.id;
             INSERT INTO v26_bm_map (old_id, new_id)
                 SELECT b.id, n.id FROM bookmarks b JOIN ao3_bookmarks n
                   ON n.owner = CASE WHEN b.account_id = '[none]' THEN '' ELSE lower(b.account_id) END
                  AND n.kind = b.bookmark_type AND n.target_id = b.target_id;
             DROP TABLE bookmarks;

             CREATE TRIGGER app_bookmarks_target_exists_ins BEFORE INSERT ON app_bookmarks BEGIN
                SELECT RAISE(ABORT, 'bookmark target missing') WHERE NOT EXISTS (
                    SELECT 1 FROM works  WHERE NEW.kind = 'work'   AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM series WHERE NEW.kind = 'series' AND id = NEW.target_id);
             END;
             CREATE TRIGGER ao3_bookmarks_target_exists_ins BEFORE INSERT ON ao3_bookmarks BEGIN
                SELECT RAISE(ABORT, 'bookmark target missing') WHERE NOT EXISTS (
                    SELECT 1 FROM works  WHERE NEW.kind = 'work'   AND id = NEW.target_id
                    UNION ALL
                    SELECT 1 FROM series WHERE NEW.kind = 'series' AND id = NEW.target_id);
             END;
             CREATE TRIGGER bookmarks_cascade_work AFTER DELETE ON works BEGIN
                DELETE FROM app_bookmarks WHERE kind = 'work' AND target_id = OLD.id;
                DELETE FROM ao3_bookmarks WHERE kind = 'work' AND target_id = OLD.id;
             END;
             CREATE TRIGGER bookmarks_cascade_series AFTER DELETE ON series BEGIN
                DELETE FROM app_bookmarks WHERE kind = 'series' AND target_id = OLD.id;
                DELETE FROM ao3_bookmarks WHERE kind = 'series' AND target_id = OLD.id;
             END;",
        )
    }

    /// Collection join tables point at the collection row id; the
    /// bookmark links move to `ao3_bookmarks`.
    fn v26_collection_joins(&self) -> Result<(), AppError> {
        if !self.v26_column_exists("collection_tags", "collection_id")? {
            self.v26_collection_tags()?;
        }
        if !self.v26_column_exists("collection_works", "collection_id")? {
            self.v26_collection_works()?;
        }
        if !self.v26_column_exists("collection_bookmarks", "collection_id")? {
            self.v26_collection_bookmarks()?;
        }
        Ok(())
    }

    fn v26_collection_tags(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE collection_tags_v26 (
                collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                tag_id        INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                position      INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (collection_id, tag_id)
             );
             INSERT OR IGNORE INTO collection_tags_v26 (collection_id, tag_id, position)
                 SELECT m.new_id, t.tag_id, t.position FROM collection_tags t
                 JOIN v26_coll_map m ON m.old_name = t.collection_name
                 WHERE EXISTS (SELECT 1 FROM tags g WHERE g.id = t.tag_id);
             DROP TABLE collection_tags;
             ALTER TABLE collection_tags_v26 RENAME TO collection_tags;
             CREATE INDEX idx_collection_tags_tag ON collection_tags (tag_id);",
        )
    }

    fn v26_collection_works(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE collection_works_v26 (
                collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                work_id       INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                PRIMARY KEY (collection_id, work_id)
             );
             INSERT OR IGNORE INTO collection_works_v26 (collection_id, work_id)
                 SELECT m.new_id, c.work_id FROM collection_works c
                 JOIN v26_coll_map m ON m.old_name = c.collection_name
                 WHERE EXISTS (SELECT 1 FROM works w WHERE w.id = c.work_id)
                 ORDER BY c.rowid;
             DROP TABLE collection_works;
             ALTER TABLE collection_works_v26 RENAME TO collection_works;
             CREATE INDEX idx_collection_works_work ON collection_works (work_id);",
        )
    }

    fn v26_collection_bookmarks(&self) -> Result<(), AppError> {
        self.v26_exec(
            "CREATE TABLE collection_bookmarks_v26 (
                collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                bookmark_id   INTEGER NOT NULL REFERENCES ao3_bookmarks(id) ON DELETE CASCADE,
                PRIMARY KEY (collection_id, bookmark_id)
             );
             INSERT OR IGNORE INTO collection_bookmarks_v26 (collection_id, bookmark_id)
                 SELECT m.new_id, b.new_id FROM collection_bookmarks c
                 JOIN v26_coll_map m ON m.old_name = c.collection_name
                 JOIN v26_bm_map b ON b.old_id = c.bookmark_id
                 ORDER BY c.rowid;
             DROP TABLE collection_bookmarks;
             ALTER TABLE collection_bookmarks_v26 RENAME TO collection_bookmarks;
             CREATE INDEX idx_collection_bookmarks_bookmark ON collection_bookmarks (bookmark_id);",
        )
    }

    /// The source-specific field registry and per-work stats (Area 3.3).
    /// Empty for AO3: its stats are columns.
    fn v26_fields(&self) -> Result<(), AppError> {
        if self.v26_table_exists("fields")? {
            return Ok(());
        }
        self.v26_exec(
            "CREATE TABLE fields (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                source        TEXT NOT NULL,
                key           TEXT NOT NULL,
                label         TEXT NOT NULL,
                value_type    TEXT NOT NULL CHECK (value_type IN ('num', 'text')),
                display_order INTEGER NOT NULL DEFAULT 0,
                UNIQUE (source, key)
             );
             CREATE TABLE work_stats (
                work_id    INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                field_id   INTEGER NOT NULL REFERENCES fields(id) ON DELETE CASCADE,
                num_value  REAL,
                text_value TEXT,
                PRIMARY KEY (work_id, field_id)
             );
             CREATE INDEX idx_work_stats_field ON work_stats (field_id, num_value);",
        )
    }

    fn v26_request_log(&self) -> Result<(), AppError> {
        if !self.v26_table_exists("request_log")? {
            return Ok(());
        }
        if !self.v26_column_exists("request_log", "source")? {
            self.v26_exec("ALTER TABLE request_log ADD COLUMN source TEXT NOT NULL DEFAULT 'ao3';")?;
        }
        Ok(())
    }

    /// `works.series_json` entries gain the series row id and name their
    /// adjacent works by external id. A series the membership names but
    /// the library never cached gets a stub row under its AO3 number.
    fn v26_rewrite_series_json(&self) -> Result<(), AppError> {
        let rows: Vec<(i64, String)> = {
            let mut stmt = self.conn
                .prepare("SELECT id, series_json FROM works WHERE series_json != '[]'")
                .map_err(map_sql)?;
            let mapped = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map_err(map_sql)?;
            mapped.collect::<Result<Vec<_>, _>>().map_err(map_sql)?
        };
        let mut ensure = self.conn.prepare(
            "INSERT OR IGNORE INTO series (id, source, external_id, url, name)
             VALUES (?1, ?2, ?3, ?4, ?5)").map_err(map_sql)?;
        let mut lookup = self.conn.prepare(
            "SELECT id FROM series WHERE source = ?1 AND external_id = ?2").map_err(map_sql)?;
        let mut update = self.conn.prepare(
            "UPDATE works SET series_json = ?2 WHERE id = ?1").map_err(map_sql)?;
        for (work_id, json) in rows {
            let old: Vec<OldMembership> = match serde_json::from_str(&json) {
                Ok(v) => v,
                Err(_) => continue, // already in the new shape, or unreadable: leave it
            };
            let mut new = Vec::with_capacity(old.len());
            for m in old {
                let external = m.series_id.to_string();
                ensure.execute(params![
                    m.series_id as i64, AO3, external, format!("{BASE}/series/{}", m.series_id), m.name,
                ]).map_err(map_sql)?;
                let row_id: i64 = lookup
                    .query_row(params![AO3, external], |r| r.get(0))
                    .map_err(map_sql)?;
                new.push(NewMembership {
                    series_id: row_id as u64,
                    series_external_id: external,
                    name: m.name,
                    part: m.part,
                    prev_work_external_id: m.prev_work_id.map(|id| id.to_string()),
                    next_work_external_id: m.next_work_id.map(|id| id.to_string()),
                });
            }
            let json = serde_json::to_string(&new)
                .map_err(|e| AppError::StorageError(e.to_string()))?;
            update.execute(params![work_id, json]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// `work_tags` has carried a real foreign key since v8, but rows for
    /// works deleted while enforcement was off (an earlier rebuild, a
    /// crash) survive in real libraries and would fail the final check.
    /// A join row without its work is garbage by definition.
    fn v26_purge_orphans(&self) -> Result<(), AppError> {
        self.v26_exec(
            "DELETE FROM work_tags WHERE NOT EXISTS (SELECT 1 FROM works w WHERE w.id = work_tags.work_id)
                OR NOT EXISTS (SELECT 1 FROM tags t WHERE t.id = work_tags.tag_id);",
        )
    }

    fn v26_foreign_key_check(&self) -> Result<(), AppError> {
        let mut stmt = self.conn.prepare("PRAGMA foreign_key_check").map_err(map_sql)?;
        let violations: Vec<(String, i64, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(map_sql)?
            .collect::<Result<_, _>>()
            .map_err(map_sql)?;
        if violations.is_empty() {
            return Ok(());
        }
        let mut by_table: std::collections::BTreeMap<String, (usize, i64)> = Default::default();
        for (t, row, parent) in &violations {
            let e = by_table.entry(format!("{t} → {parent}")).or_insert((0, *row));
            e.0 += 1;
        }
        let summary: Vec<String> = by_table.iter()
            .map(|(k, (n, first))| format!("{k}: {n} row(s), first {first}"))
            .collect();
        Err(AppError::StorageError(format!(
            "v26 left {} foreign key violation(s): {}", violations.len(), summary.join("; "))))
    }
}
