use rusqlite::{params, OptionalExtension};

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
    /// `chapter` is the 1-based chapter number; `position` is the character
    /// offset (into the chapter's plain text) of the first visible line.
    /// The work must already be cached in `works` — position lives on that
    /// row.
    pub fn save_progress(
        &self,
        work_id: u64,
        chapter: u32,
        position: u32,
    ) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE works SET last_chapter_read = ?2, last_chapter_read_pos = ?3
                 WHERE id = ?1",
                params![work_id as i64, chapter as i64, position as i64],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    pub fn delete_progress(&self, work_id: u64) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE works SET last_chapter_read = 0, last_chapter_read_pos = 0
                 WHERE id = ?1",
                params![work_id as i64],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    pub fn get_progress(&self, work_id: u64) -> Result<Option<(u32, u32)>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT last_chapter_read, last_chapter_read_pos FROM works
                 WHERE id = ?1 AND last_chapter_read > 0",
            )
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(params![work_id as i64], |row| {
                let chapter: i64 = row.get(0)?;
                let position: i64 = row.get(1)?;
                Ok((chapter as u32, position as u32))
            })
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(pair)) => Ok(Some(pair)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    /// Character count of a cached chapter's plain text (0 when the chapter
    /// isn't cached). Lets position offsets read back as a fraction of the
    /// chapter without the UI having to load the text itself.
    pub fn chapter_char_len(&self, work_id: u64, chapter_number: u32) -> u32 {
        use crate::models::{ContentBlock, InlineContent};

        fn inline_len(items: &[InlineContent]) -> usize {
            items
                .iter()
                .map(|i| match i {
                    InlineContent::Text { value } => value.chars().count(),
                    InlineContent::Bold { content }
                    | InlineContent::Italic { content }
                    | InlineContent::Link { content, .. }
                    | InlineContent::Strikethrough { content }
                    | InlineContent::Superscript { content } => inline_len(content),
                    InlineContent::LineBreak => 1,
                })
                .sum()
        }
        fn block_len(blocks: &[ContentBlock]) -> usize {
            blocks
                .iter()
                .map(|b| match b {
                    ContentBlock::Paragraph { text } => inline_len(text) + 1,
                    ContentBlock::Heading { text, .. } => text.chars().count() + 1,
                    ContentBlock::Blockquote { blocks } => block_len(blocks),
                    ContentBlock::HorizontalRule => 1,
                    ContentBlock::List { items, .. } => {
                        items.iter().map(|i| block_len(i)).sum::<usize>()
                    }
                    ContentBlock::PreFormatted { text } => text.chars().count() + 1,
                    ContentBlock::Image { alt, .. } => alt.chars().count() + 1,
                })
                .sum()
        }

        match self.get_chapter(work_id, chapter_number) {
            Ok(Some(chapter)) => block_len(&chapter.content) as u32,
            _ => 0,
        }
    }

    pub fn get_all_progress(&self) -> Result<Vec<(u64, u32, u32)>, AppError> {
        let mut stmt = self.conn
            .prepare(
                "SELECT id, last_chapter_read, last_chapter_read_pos FROM works
                 WHERE last_chapter_read > 0",
            )
            .map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            let work_id: i64 = row.get(0)?;
            let chapter: i64 = row.get(1)?;
            let position: i64 = row.get(2)?;
            Ok((work_id as u64, chapter as u32, position as u32))
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
    // Collections cache (blurbs from the /collections index)
    // -------------------------------------------------------------------

    /// Upsert one fetched index page of collection blurbs — the cache-forever
    /// store the library-scoped collection search reads.
    pub fn save_collections(&self, collections: &[crate::models::CollectionSummary]) -> Result<(), AppError> {
        self.with_savepoint("save_collections", || {
            let mut stmt = self.conn.prepare(
                "INSERT INTO collections (name, title, summary, is_open, is_moderated,
                                          is_anonymous, work_count, bookmarked_count,
                                          maintainers_json, collection_type, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, datetime('now'))
                 ON CONFLICT(name) DO UPDATE SET
                     title = excluded.title, summary = excluded.summary,
                     is_open = excluded.is_open, is_moderated = excluded.is_moderated,
                     is_anonymous = excluded.is_anonymous, work_count = excluded.work_count,
                     bookmarked_count = excluded.bookmarked_count,
                     maintainers_json = excluded.maintainers_json,
                     collection_type = excluded.collection_type,
                     fetched_at = excluded.fetched_at",
            ).map_err(map_sql)?;
            for c in collections {
                let maintainers = serde_json::to_string(&c.maintainers)
                    .unwrap_or_else(|_| "[]".to_string());
                stmt.execute(params![
                    c.name, c.title, c.summary, c.is_open as i64, c.is_moderated as i64,
                    c.is_anonymous as i64, c.work_count, c.bookmarked_count,
                    maintainers, c.collection_type,
                ]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    /// Library-scope collection search over the cached blurbs: substring on
    /// title, slug, summary, and maintainer names; title matches rank first,
    /// then the biggest collections.
    pub fn search_collections(&self, term: &str, limit: u32) -> Result<Vec<crate::models::CollectionSummary>, AppError> {
        let limit = Self::sql_limit(limit);
        let escaped = Self::escape_like(term);
        if escaped.is_empty() {
            return Ok(Vec::new());
        }
        let contains = format!("%{escaped}%");
        let title_prefix = format!("{escaped}%");
        let mut stmt = self.conn.prepare(
            "SELECT name, title, summary, is_open, is_moderated, is_anonymous,
                    work_count, bookmarked_count, maintainers_json, collection_type
             FROM collections
             WHERE title LIKE ?1 ESCAPE '\\'
                OR name LIKE ?1 ESCAPE '\\'
                OR summary LIKE ?1 ESCAPE '\\'
                OR maintainers_json LIKE ?1 ESCAPE '\\'
             ORDER BY (title LIKE ?2 ESCAPE '\\') DESC, work_count DESC, title COLLATE NOCASE
             LIMIT ?3"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![contains, title_prefix, limit],
                                  Self::collection_from_row).map_err(map_sql)?;
        let mut collections: Vec<_> = rows.filter_map(|r| r.ok()).collect();
        for c in &mut collections {
            c.tags = self.get_collection_tags(&c.name)?;
        }
        Ok(collections)
    }

    /// Map a row from the collections SELECT (name..collection_type, the
    /// column order every collections query here uses) into a summary.
    /// Tags come back empty — callers hydrate them via get_collection_tags.
    fn collection_from_row(row: &rusqlite::Row<'_>) -> Result<crate::models::CollectionSummary, rusqlite::Error> {
        let maintainers_json: String = row.get(8)?;
        Ok(crate::models::CollectionSummary {
            name: row.get(0)?,
            title: row.get(1)?,
            summary: row.get(2)?,
            is_open: row.get::<_, i64>(3)? != 0,
            is_moderated: row.get::<_, i64>(4)? != 0,
            is_anonymous: row.get::<_, i64>(5)? != 0,
            work_count: row.get(6)?,
            bookmarked_count: row.get(7)?,
            maintainers: serde_json::from_str(&maintainers_json).unwrap_or_default(),
            tags: Vec::new(),
            collection_type: row.get(9)?,
        })
    }

    /// The collections sort/filter form evaluated against the cached rows —
    /// the library-scoped twin of AO3's /collections criteria. Blank criteria
    /// match everything (the form's default state is the whole cache).
    ///
    /// Local mappings where the cache differs from AO3's index:
    /// * title also matches the URL slug (slugs are how collections are
    ///   often remembered);
    /// * tags match the profile-page tag links, so only collections whose
    ///   /profile has been cached can match a tag filter;
    /// * multifandom counts the collection's fandom-typed tags (>1 = yes) —
    ///   a tag's type is learned from work blurbs, so it's an approximation;
    /// * "Date Created" isn't in the blurbs — the local stand-in is
    ///   fetched_at, when the collection was last cached.
    pub fn search_collections_filtered(
        &self,
        c: &crate::models::CollectionSearchCriteria,
        limit: u32,
    ) -> Result<Vec<crate::models::CollectionSummary>, AppError> {
        let mut sql = String::from(
            "SELECT name, title, summary, is_open, is_moderated, is_anonymous,
                    work_count, bookmarked_count, maintainers_json, collection_type
             FROM collections WHERE 1=1");
        let mut args: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        let title = Self::escape_like(&c.title);
        if !title.is_empty() {
            sql.push_str(" AND (title LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\')");
            let contains = format!("%{title}%");
            args.push(Box::new(contains.clone()));
            args.push(Box::new(contains));
        }
        for tag in c.tag.split(',').map(str::trim).filter(|t| !t.is_empty()) {
            sql.push_str(
                " AND EXISTS (SELECT 1 FROM collection_tags ct
                              JOIN tags t ON t.id = ct.tag_id
                              WHERE ct.collection_name = collections.name
                                AND t.name = ? COLLATE NOCASE)");
            args.push(Box::new(tag.to_string()));
        }
        const FANDOM_TAG_COUNT: &str =
            "(SELECT COUNT(*) FROM collection_tags ct
              JOIN tags t ON t.id = ct.tag_id
              WHERE ct.collection_name = collections.name AND t.tag_type = 'fandom')";
        match c.multifandom.as_str() {
            "true" => sql.push_str(&format!(" AND {FANDOM_TAG_COUNT} > 1")),
            "false" => sql.push_str(&format!(" AND {FANDOM_TAG_COUNT} <= 1")),
            _ => {}
        }
        match c.closed.as_str() {
            "true" => sql.push_str(" AND is_open = 0"),
            "false" => sql.push_str(" AND is_open = 1"),
            _ => {}
        }
        match c.moderated.as_str() {
            "true" => sql.push_str(" AND is_moderated = 1"),
            "false" => sql.push_str(" AND is_moderated = 0"),
            _ => {}
        }
        match c.challenge_type.as_str() {
            "GiftExchange" => sql.push_str(" AND collection_type = 'Gift Exchange Challenge'"),
            "PromptMeme" => sql.push_str(" AND collection_type = 'Prompt Meme Challenge'"),
            "no_challenge" => sql.push_str(" AND collection_type = ''"),
            _ => {}
        }

        let column = match c.sort_column.as_str() {
            "title.keyword" => "title COLLATE NOCASE",
            "bookmarked_items_count" => "bookmarked_count",
            "works_count" => "work_count",
            _ => "fetched_at", // AO3's created_at default; see doc above
        };
        let direction = if c.sort_direction == "asc" { "ASC" } else { "DESC" };
        sql.push_str(&format!(" ORDER BY {column} {direction}, title COLLATE NOCASE LIMIT ?"));
        args.push(Box::new(Self::sql_limit(limit)));

        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(args.iter().map(|a| a.as_ref())),
                       Self::collection_from_row)
            .map_err(map_sql)?;
        let mut collections: Vec<_> = rows.filter_map(|r| r.ok()).collect();
        for coll in &mut collections {
            coll.tags = self.get_collection_tags(&coll.name)?;
        }
        Ok(collections)
    }

    // -------------------------------------------------------------------
    // Collection tags and works (normalized join tables)
    // -------------------------------------------------------------------

    /// Cache a collection's /profile page: upsert the metadata row, stamp
    /// profile_fetched_at, and rewrite the collection's tag links. The
    /// profile page carries no work/bookmark counts, so zeroes there keep
    /// whatever the index blurb already recorded.
    pub fn save_collection_profile(&self, c: &crate::models::CollectionSummary) -> Result<(), AppError> {
        self.with_savepoint("save_collection_profile", || {
            let mut merged = c.clone();
            if let Some(existing) = self.get_collection(&c.name)? {
                if merged.work_count == 0 { merged.work_count = existing.work_count; }
                if merged.bookmarked_count == 0 { merged.bookmarked_count = existing.bookmarked_count; }
                if merged.summary.is_empty() { merged.summary = existing.summary; }
            }
            self.save_collections(std::slice::from_ref(&merged))?;
            self.conn
                .execute("UPDATE collections SET profile_fetched_at = datetime('now')
                          WHERE name = ?1", params![c.name])
                .map_err(map_sql)?;
            self.replace_collection_tags(&c.name, &c.tags)
        })
    }

    /// Whether a collection's /profile page has ever been cached — the
    /// cache-forever guard for profile fetches.
    pub fn collection_profile_cached(&self, name: &str) -> Result<bool, AppError> {
        let fetched: Option<String> = self.conn
            .query_row("SELECT profile_fetched_at FROM collections WHERE name = ?1",
                       params![name], |r| r.get(0))
            .optional()
            .map_err(map_sql)?;
        Ok(fetched.is_some_and(|f| !f.is_empty()))
    }

    /// The cached collection row, tags attached; None when never seen.
    pub fn get_collection(&self, name: &str) -> Result<Option<crate::models::CollectionSummary>, AppError> {
        let row = self.conn
            .query_row(
                "SELECT name, title, summary, is_open, is_moderated, is_anonymous,
                        work_count, bookmarked_count, maintainers_json, collection_type
                 FROM collections WHERE name = ?1",
                params![name],
                |row| {
                    let maintainers_json: String = row.get(8)?;
                    Ok(crate::models::CollectionSummary {
                        name: row.get(0)?,
                        title: row.get(1)?,
                        summary: row.get(2)?,
                        is_open: row.get::<_, i64>(3)? != 0,
                        is_moderated: row.get::<_, i64>(4)? != 0,
                        is_anonymous: row.get::<_, i64>(5)? != 0,
                        work_count: row.get(6)?,
                        bookmarked_count: row.get(7)?,
                        maintainers: serde_json::from_str(&maintainers_json).unwrap_or_default(),
                        tags: Vec::new(),
                        collection_type: row.get(9)?,
                    })
                })
            .optional()
            .map_err(map_sql)?;
        match row {
            Some(mut c) => {
                c.tags = self.get_collection_tags(&c.name)?;
                Ok(Some(c))
            }
            None => Ok(None),
        }
    }

    /// Rewrite a collection's tag join rows in page order. Tags are
    /// universal — the same tags row a work references, keyed by name.
    fn replace_collection_tags(&self, name: &str, tags: &[String]) -> Result<(), AppError> {
        self.conn
            .execute("DELETE FROM collection_tags WHERE collection_name = ?1", params![name])
            .map_err(map_sql)?;
        let mut stmt = self.conn
            .prepare_cached("INSERT OR IGNORE INTO collection_tags
                             (collection_name, tag_id, position) VALUES (?1, ?2, ?3)")
            .map_err(map_sql)?;
        for (position, tag) in tags.iter().enumerate() {
            // Profile pages don't state tag types — "" until a work
            // listing teaches us.
            let tag_id = self.tag_row_id(tag, "")?;
            stmt.execute(params![name, tag_id, position as i64]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// A collection's tag names, in profile-page order.
    pub fn get_collection_tags(&self, name: &str) -> Result<Vec<String>, AppError> {
        let mut stmt = self.conn
            .prepare_cached(
                "SELECT t.name FROM collection_tags ct
                 JOIN tags t ON t.id = ct.tag_id
                 WHERE ct.collection_name = ?1
                 ORDER BY ct.position")
            .map_err(map_sql)?;
        let rows = stmt.query_map(params![name], |r| r.get::<_, String>(0)).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Record works seen in a collection's listing. Accumulates across
    /// pages — a work stays linked until the work or collection is deleted
    /// (the join rows' foreign keys cascade).
    pub fn add_collection_works(&self, name: &str, work_ids: &[u64]) -> Result<(), AppError> {
        // A listing can be fetched for a collection whose blurb was never
        // cached (deep link) — satisfy the foreign key with a stub row the
        // next blurb or profile save will fill in.
        self.conn
            .execute("INSERT OR IGNORE INTO collections (name, title) VALUES (?1, ?1)",
                     params![name])
            .map_err(map_sql)?;
        let mut stmt = self.conn
            .prepare_cached("INSERT OR IGNORE INTO collection_works
                             (collection_name, work_id) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        for id in work_ids {
            stmt.execute(params![name, *id as i64]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// The cached works seen in a collection's listing, in listing order —
    /// the library-mode view of a collection's works. No network; only
    /// what fetches already recorded in collection_works.
    pub fn get_collection_works(&self, name: &str) -> Result<Vec<crate::models::WorkSummary>, AppError> {
        let mut stmt = self.conn
            .prepare_cached(&format!(
                "SELECT {} FROM collection_works cw
                 JOIN works w ON w.id = cw.work_id
                 WHERE cw.collection_name = ?1
                 ORDER BY cw.rowid", Self::work_select("w.")))
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![name], |row| Ok(Self::work_from_row(row)))
            .map_err(map_sql)?;
        let mut works = Vec::new();
        for row in rows {
            works.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        self.attach_work_tags(&mut works)?;
        Ok(works)
    }

    /// The cached work ids for a collection, in the order they were seen.
    pub fn get_collection_work_ids(&self, name: &str) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn
            .prepare_cached("SELECT work_id FROM collection_works
                             WHERE collection_name = ?1 ORDER BY rowid")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![name], |r| r.get::<_, i64>(0))
            .map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).map(|id| id as u64).collect())
    }

    // -------------------------------------------------------------------
    // Per-route request timeouts
    // -------------------------------------------------------------------

    pub fn get_route_timeouts(&self) -> Result<Vec<(String, u64)>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT route_key, timeout_secs FROM route_timeouts"
        ).map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?.max(0) as u64))
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Upsert one route's timeout override; None removes it (back to the
    /// global default).
    pub fn set_route_timeout(&self, route_key: &str, timeout_secs: Option<u64>) -> Result<(), AppError> {
        match timeout_secs {
            Some(secs) => {
                self.conn.execute(
                    "INSERT INTO route_timeouts (route_key, timeout_secs) VALUES (?1, ?2)
                     ON CONFLICT(route_key) DO UPDATE SET timeout_secs = excluded.timeout_secs",
                    params![route_key, secs as i64],
                ).map_err(map_sql)?;
            }
            None => {
                self.conn.execute(
                    "DELETE FROM route_timeouts WHERE route_key = ?1",
                    params![route_key],
                ).map_err(map_sql)?;
            }
        }
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
