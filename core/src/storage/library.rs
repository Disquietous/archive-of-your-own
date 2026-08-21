use rusqlite::params;

use crate::error::AppError;

use super::consts::*;
use super::{map_sql, Storage};

impl Storage {
    /// Record the first time the user opened this work's detail view
    /// (unix-seconds string). First view wins — later opens keep the
    /// original timestamp. Kept out of `save_work` so listing upserts
    /// can't clobber it. No-op when the work has no row yet (only works
    /// discovered by crawls feed the What's New badge, and those always
    /// have blurb rows).
    pub fn mark_work_detail_viewed(&self, work_id: u64, at: &str) -> Result<(), AppError> {
        self.works_cache.mark_detail_viewed(&self.conn, work_id, at)
    }

    /// Stamp "the user just opened a chapter of this work" — every open
    /// overwrites, so the value is always the most recent read.
    pub fn mark_work_read(&self, work_id: u64) -> Result<(), AppError> {
        self.works_cache.mark_read(&self.conn, work_id, &crate::timefmt::now_utc_datetime())
    }

    /// Last-read datetimes for every work that has one, as
    /// `(work_id, "YYYY-MM-DD HH:MM:SS")` — lexicographically sortable UTC.
    /// Answered from the works cache.
    pub fn get_work_last_read_times(&self) -> Result<Vec<(u64, String)>, AppError> {
        Ok(self.works_cache
            .all()
            .into_iter()
            .filter(|e| !e.last_read_dt.is_empty())
            .map(|e| (e.summary.id, e.last_read_dt.clone()))
            .collect())
    }

    /// Ids of every work whose detail view has been opened at least once.
    /// Answered from the works cache.
    pub fn get_detail_viewed_work_ids(&self) -> Result<Vec<u64>, AppError> {
        Ok(self.works_cache
            .all()
            .into_iter()
            .filter(|e| !e.detail_viewed_at.is_empty())
            .map(|e| e.summary.id)
            .collect())
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
        self.works_cache.save_progress(&self.conn, work_id, chapter, position)
    }

    pub fn delete_progress(&self, work_id: u64) -> Result<(), AppError> {
        self.works_cache.clear_progress(&self.conn, work_id)
    }

    pub fn get_progress(&self, work_id: u64) -> Result<Option<(u32, u32)>, AppError> {
        Ok(self.works_cache
            .get(work_id)
            .filter(|e| e.last_chapter_read > 0)
            .map(|e| (e.last_chapter_read, e.last_chapter_read_pos)))
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
        Ok(self.works_cache
            .all()
            .into_iter()
            .filter(|e| e.last_chapter_read > 0)
            .map(|e| (e.summary.id, e.last_chapter_read, e.last_chapter_read_pos))
            .collect())
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
            .unwrap_or_else(|| super::LOGGED_OUT_ACCOUNT_ID.to_string())
    }

    pub fn add_bookmark(&self, work_id: u64, note: Option<&str>, sync_to_ao3: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.add(&self.conn, &acct, work_id, note.unwrap_or(""),
                                 sync_to_ao3, &crate::timefmt::now_utc_datetime())
    }

    /// Cache a bookmark seen in a fetched listing, keyed by the byline
    /// username exactly as any account's bookmarks are keyed — whichever
    /// account is (or later becomes) active sees precisely its own rows.
    /// An existing row only refreshes its AO3 id: locally edited details
    /// stay put, pull_bookmarks remains the explicit overwrite path. An
    /// unattributed blurb (no byline) can't be keyed and isn't cached.
    pub fn cache_fetched_bookmark(&self, bookmarker: &str, work_id: u64,
                                  ao3_bookmark_id: u64, note: &str,
                                  tag_string: &str, rec: bool) -> Result<(), AppError> {
        if bookmarker.is_empty() {
            return Ok(());
        }
        let acct = super::account_id_for(bookmarker);
        self.bookmarks_cache.cache_fetched(&self.conn, &acct, work_id, ao3_bookmark_id,
                                           note, tag_string, rec,
                                           &crate::timefmt::now_utc_datetime())
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: &str) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.update_note(&self.conn, &acct, work_id, note)
    }

    /// Update the full AO3 bookmark object (notes, own tags, collections,
    /// private/rec flags).
    pub fn update_bookmark_details(&self, work_id: u64, note: &str, tag_string: &str,
                                   collection_names: &str, private: bool, rec: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.update_details(&self.conn, &acct, work_id, note, tag_string,
                                            collection_names, private, rec)
    }

    /// Full bookmark row: (note, tag_string, collection_names, private, rec,
    /// sync_to_ao3, ao3_bookmark_id).
    #[allow(clippy::type_complexity)]
    pub fn get_bookmark_details(&self, work_id: u64)
        -> Result<Option<(String, String, String, bool, bool, bool, Option<u64>)>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache.get(&acct, work_id).map(|e| (
            e.note.clone(), e.tag_string.clone(), e.collection_names.clone(),
            e.private, e.rec, e.sync_to_ao3, e.ao3_bookmark_id,
        )))
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.update_sync(&self.conn, &acct, work_id, sync)
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.remove(&self.conn, &acct, work_id)
    }

    pub fn get_bookmarks(&self) -> Result<Vec<u64>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache.for_account(&acct).into_iter().map(|e| e.work_id).collect())
    }

    pub fn get_bookmarks_full(&self) -> Result<Vec<(u64, String, bool)>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache
            .for_account(&acct)
            .into_iter()
            .map(|e| (e.work_id, e.note.clone(), e.sync_to_ao3))
            .collect())
    }

    pub fn get_synced_bookmarks(&self) -> Result<Vec<(u64, String)>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache
            .for_account(&acct)
            .into_iter()
            .filter(|e| e.sync_to_ao3)
            .map(|e| (e.work_id, e.note.clone()))
            .collect())
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache.get(&acct, work_id).is_some())
    }

    pub fn get_bookmark_full(&self, work_id: u64) -> Result<Option<(String, bool, Option<u64>)>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache
            .get(&acct, work_id)
            .map(|e| (e.note.clone(), e.sync_to_ao3, e.ao3_bookmark_id)))
    }

    pub fn set_ao3_bookmark_id(&self, work_id: u64, ao3_id: u64) -> Result<(), AppError> {
        let acct = self.active_account_id();
        self.bookmarks_cache.set_ao3_id(&self.conn, &acct, work_id, ao3_id)
    }

    pub fn get_ao3_bookmark_id(&self, work_id: u64) -> Result<Option<u64>, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache.get(&acct, work_id).and_then(|e| e.ao3_bookmark_id))
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AppError> {
        let acct = self.active_account_id();
        Ok(self.bookmarks_cache.get(&acct, work_id).map(|e| e.sync_to_ao3).unwrap_or(false))
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
        self.with_savepoint(Savepoint::SaveCollections, || {
            let now = crate::timefmt::now_utc_datetime();
            let mut saved: Vec<&str> = Vec::new();
            for c in collections {
                if c.name.is_empty() {
                    crate::log_error!(LOG_TAG_COLLECTIONS,
                        "save_collections: SKIPPING blurb with empty slug (title='{}') — row would be unreachable", c.title);
                    continue;
                }
                if c.title.is_empty() {
                    crate::log_error!(LOG_TAG_COLLECTIONS,
                        "save_collections: blurb '{}' has an empty title — caching anyway, display will be blank", c.name);
                }
                self.collections_cache.upsert_blurb(&self.conn, c, &now)?;
                // Blurbs carry the collection's tags too — cache them right
                // away. A tagless blurb leaves existing links alone (it may
                // simply have none, and a cached /profile knows better).
                if !c.tags.is_empty() {
                    self.replace_collection_tags(&c.name, &c.tags)?;
                }
                saved.push(&c.name);
            }
            crate::log_debug!(LOG_TAG_COLLECTIONS,
                "save_collections: upserted {}/{} blurb(s): [{}]",
                saved.len(), collections.len(), saved.join(", "));
            Ok(())
        })
    }

    /// Library-scope collection search over the cached blurbs: substring on
    /// title, slug, summary, and maintainer names; title matches rank first,
    /// then the biggest collections.
    pub fn search_collections(&self, term: &str, limit: u32) -> Result<Vec<crate::models::CollectionSummary>, AppError> {
        let needle = term.trim().to_ascii_lowercase();
        if needle.is_empty() {
            return Ok(Vec::new());
        }
        let contains = |s: &str| s.to_ascii_lowercase().contains(&needle);
        let mut hits: Vec<_> = self.collections_cache
            .all()
            .into_iter()
            .filter(|e| {
                let s = &e.summary;
                contains(&s.title) || contains(&s.name) || contains(&s.summary)
                    || s.maintainers.iter().any(|m| contains(m))
            })
            .collect();
        hits.sort_by(|a, b| {
            let a_title = a.summary.title.to_ascii_lowercase().starts_with(&needle);
            let b_title = b.summary.title.to_ascii_lowercase().starts_with(&needle);
            b_title.cmp(&a_title)
                .then_with(|| b.summary.work_count.cmp(&a.summary.work_count))
                .then_with(|| a.summary.title.to_ascii_lowercase()
                                .cmp(&b.summary.title.to_ascii_lowercase()))
        });
        if limit > 0 {
            hits.truncate(limit as usize);
        }
        Ok(hits.into_iter()
            .map(|e| self.collections_cache.hydrate(&e, &self.tag_cache))
            .collect())
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
        let title_needle = c.title.trim().to_ascii_lowercase();
        let wanted_tags: Vec<&str> = c.tag.split(',')
            .map(str::trim).filter(|t| !t.is_empty()).collect();

        let mut hits: Vec<_> = self.collections_cache
            .all()
            .into_iter()
            .filter(|e| {
                let s = &e.summary;
                if !title_needle.is_empty()
                    && !s.title.to_ascii_lowercase().contains(&title_needle)
                    && !s.name.to_ascii_lowercase().contains(&title_needle) {
                    return false;
                }
                if !wanted_tags.is_empty() || !matches!(c.multifandom.as_str(), "") {
                    let entity_tags: Vec<_> = e.tag_ids.iter()
                        .filter_map(|id| self.tag_cache.get(*id))
                        .collect();
                    // Tag entries AND together; equality is NOCASE like the
                    // profile-page links they came from.
                    if !wanted_tags.iter().all(|wanted| entity_tags.iter()
                        .any(|t| t.name.eq_ignore_ascii_case(wanted))) {
                        return false;
                    }
                    let fandoms = entity_tags.iter()
                        .filter(|t| t.tag_type == TAG_TYPE_FANDOM)
                        .count();
                    match c.multifandom.as_str() {
                        FORM_TRUE if fandoms <= 1 => return false,
                        FORM_FALSE if fandoms > 1 => return false,
                        _ => {}
                    }
                }
                match c.closed.as_str() {
                    FORM_TRUE if s.is_open => return false,
                    FORM_FALSE if !s.is_open => return false,
                    _ => {}
                }
                match c.moderated.as_str() {
                    FORM_TRUE if !s.is_moderated => return false,
                    FORM_FALSE if s.is_moderated => return false,
                    _ => {}
                }
                match c.challenge_type.as_str() {
                    "GiftExchange" if s.collection_type != "Gift Exchange Challenge" => return false,
                    "PromptMeme" if s.collection_type != "Prompt Meme Challenge" => return false,
                    "no_challenge" if !s.collection_type.is_empty() => return false,
                    _ => {}
                }
                true
            })
            .collect();

        let ascending = c.sort_direction == SORT_ASC;
        hits.sort_by(|a, b| {
            let key = match c.sort_column.as_str() {
                "title.keyword" => a.summary.title.to_ascii_lowercase()
                    .cmp(&b.summary.title.to_ascii_lowercase()),
                "bookmarked_items_count" => a.summary.bookmarked_count.cmp(&b.summary.bookmarked_count),
                "works_count" => a.summary.work_count.cmp(&b.summary.work_count),
                _ => a.fetched_at.cmp(&b.fetched_at), // AO3's created_at default; see doc above
            };
            let key = if ascending { key } else { key.reverse() };
            key.then_with(|| a.summary.title.to_ascii_lowercase()
                              .cmp(&b.summary.title.to_ascii_lowercase()))
        });
        if limit > 0 {
            hits.truncate(limit as usize);
        }
        Ok(hits.into_iter()
            .map(|e| self.collections_cache.hydrate(&e, &self.tag_cache))
            .collect())
    }

    /// The bookmark-search form evaluated against the cached bookmark rows —
    /// the library-scoped twin of AO3's /bookmarks/search. Every cached
    /// bookmark is searched (the active account's own plus any seen in
    /// fetched listings); each hit carries the bookmark's own fields plus
    /// its cached work blurb. Blank criteria match everything. `limit` of 0
    /// means no limit.
    ///
    /// Local mappings where the cache differs from AO3:
    /// * only work bookmarks are cached, so a Series / External Work type
    ///   filter matches nothing;
    /// * the bookmarker (filter and hit field) is the row's account key —
    ///   the lowercased username;
    /// * language compares against the work's language *name* — callers
    ///   pass the display label ("English"), not AO3's code;
    /// * Date Bookmarked is the row's created_at — for bookmarks seen in
    ///   fetched listings that's when the app first cached them, not AO3's
    ///   own date.
    pub fn search_local_bookmarks_filtered(
        &self,
        c: &crate::models::BookmarkSearchCriteria,
        limit: u32,
    ) -> Result<Vec<crate::models::BookmarkHit>, AppError> {
        if !c.bookmarkable_type.is_empty() && c.bookmarkable_type != "Work" {
            return Ok(Vec::new());
        }
        // Every cached bookmark, newest first — from the bookmarks cache.
        let mut all = self.bookmarks_cache.all();
        all.sort_by(|a, b| {
            b.created_at.cmp(&a.created_at).then_with(|| a.work_id.cmp(&b.work_id))
        });

        // Pass 1: bookmark-side criteria — they need no work lookup.
        let mut candidates: Vec<(String, u64, String, Vec<String>, bool, String)> = Vec::new();
        for e in all {
            let (bookmarker, work_id, note, tag_string, rec, created_at) = (
                e.account_id.clone(), e.work_id, e.note.clone(),
                e.tag_string.clone(), e.rec, e.created_at.clone(),
            );
            if c.rec && !rec { continue; }
            if c.with_notes && note.trim().is_empty() { continue; }
            let notes_q = c.bookmark_notes.trim();
            if !notes_q.is_empty() && !Self::contains_ci(&note, notes_q) { continue; }
            let who = c.bookmarker.trim();
            if !who.is_empty() && !Self::contains_ci(&bookmarker, who) { continue; }
            let own_tags: Vec<String> = tag_string.split(',')
                .map(str::trim).filter(|t| !t.is_empty())
                .map(str::to_string).collect();
            if !Self::names_match(&c.other_bookmark_tag_names, &own_tags) { continue; }
            let bq = c.bookmark_query.trim();
            if !bq.is_empty()
                && !Self::contains_ci(&note, bq)
                && !Self::any_ci(&own_tags, bq)
                && !Self::contains_ci(&bookmarker, bq) { continue; }
            if !Self::revised_matches(&c.date, &created_at) { continue; }
            candidates.push((bookmarker, work_id, note, own_tags, rec, created_at));
        }

        // One batched hydration for every surviving work — the work-side
        // pass must not cost one query per bookmark.
        let mut ids: Vec<u64> = candidates.iter().map(|cand| cand.1).collect();
        ids.sort_unstable();
        ids.dedup();
        let works_by_id: std::collections::HashMap<u64, crate::models::WorkSummary> = self
            .get_works_by_ids_ordered(&ids)?
            .into_iter()
            .map(|w| (w.id, w))
            .collect();

        // Pass 2: work-side criteria, mirroring the works-form matcher.
        let mut hits: Vec<(crate::models::BookmarkHit, String)> = Vec::new();
        for (bookmarker, work_id, note, own_tags, rec, created_at) in candidates {
            let Some(w) = works_by_id.get(&work_id) else { continue };
            let wq = c.bookmarkable_query.trim();
            if !wq.is_empty() {
                let hit = Self::contains_ci(&w.title, wq)
                    || Self::any_ci(&w.authors, wq)
                    || Self::any_ci(&w.fandoms, wq)
                    || Self::any_ci(&w.relationships, wq)
                    || Self::any_ci(&w.characters, wq)
                    || Self::any_ci(&w.tags, wq)
                    || Self::contains_ci(&w.summary, wq);
                if !hit { continue; }
            }
            // "Work tags" spans every tag category on the work.
            let all_tags: Vec<String> = w.fandoms.iter()
                .chain(&w.characters).chain(&w.relationships).chain(&w.tags)
                .cloned().collect();
            if !Self::names_match(&c.other_tag_names, &all_tags) { continue; }
            if !Self::range_matches(&c.word_count, w.word_count) { continue; }
            let language = c.language_id.trim();
            if !language.is_empty() && !w.language.eq_ignore_ascii_case(language) { continue; }
            if !Self::revised_matches(&c.bookmarkable_date, &w.date_updated) { continue; }

            let hit = crate::models::BookmarkHit {
                bookmarker,
                note,
                tags: own_tags,
                rec,
                // Date part only — the timestamp is display noise.
                date_bookmarked: created_at.chars().take(10).collect(),
                // Library hits are always real cached works — mystery
                // stubs are never cached.
                mystery: false,
                mystery_collection_name: String::new(),
                mystery_collection_title: String::new(),
                work: w.clone(),
            };
            hits.push((hit, created_at));
        }

        // "Best Match" has no local meaning — it and unknown columns fall
        // back to Date Bookmarked, descending like AO3's default.
        match c.sort_column.as_str() {
            "bookmarkable_date" => hits.sort_by(|a, b| b.0.work.date_updated.cmp(&a.0.work.date_updated)),
            SORT_KEY_WORD_COUNT => hits.sort_by(|a, b| b.0.work.word_count.cmp(&a.0.work.word_count)),
            _ => hits.sort_by(|a, b| b.1.cmp(&a.1)),
        }
        let mut out: Vec<_> = hits.into_iter().map(|(hit, _)| hit).collect();
        if limit > 0 {
            out.truncate(limit as usize);
        }
        Ok(out)
    }

    // -------------------------------------------------------------------
    // Collection tags and works (normalized join tables)
    // -------------------------------------------------------------------

    /// Cache a collection's /profile page: upsert the metadata row, stamp
    /// profile_fetched_at, and rewrite the collection's tag links. The
    /// profile page carries no work/bookmark counts, so zeroes there keep
    /// whatever the index blurb already recorded.
    pub fn save_collection_profile(&self, c: &crate::models::CollectionSummary) -> Result<(), AppError> {
        self.with_savepoint(Savepoint::SaveCollectionProfile, || {
            let mut merged = c.clone();
            let had_blurb = match self.get_collection(&c.name)? {
                Some(existing) => {
                    if merged.work_count == 0 { merged.work_count = existing.work_count; }
                    if merged.bookmarked_count == 0 { merged.bookmarked_count = existing.bookmarked_count; }
                    if merged.summary.is_empty() { merged.summary = existing.summary; }
                    true
                }
                None => false,
            };
            self.save_collections(std::slice::from_ref(&merged))?;
            let stamped = self.collections_cache
                .stamp_profile_fetched(&self.conn, &c.name, &crate::timefmt::now_utc_datetime())?;
            crate::log_debug!(LOG_TAG_COLLECTIONS,
                "save_collection_profile '{}': prior blurb cached={}, profile_fetched_at stamped on {} row(s), merged counts works={} bookmarks={}, {} tag(s) incoming",
                c.name, had_blurb, stamped, merged.work_count, merged.bookmarked_count, c.tags.len());
            if stamped == 0 {
                crate::log_error!(LOG_TAG_COLLECTIONS,
                    "save_collection_profile '{}': no collections row to stamp — profile will re-fetch every time (blurb save was skipped?)", c.name);
            }
            self.replace_collection_tags(&c.name, &c.tags)
        })
    }

    /// Whether a collection's /profile page has ever been cached — the
    /// cache-forever guard for profile fetches. Answered from the
    /// collections cache.
    pub fn collection_profile_cached(&self, name: &str) -> Result<bool, AppError> {
        Ok(self.collections_cache
            .get(name)
            .is_some_and(|e| !e.profile_fetched_at.is_empty()))
    }

    /// The cached collection, tags attached; None when never seen.
    /// Answered from the collections cache.
    pub fn get_collection(&self, name: &str) -> Result<Option<crate::models::CollectionSummary>, AppError> {
        Ok(self.collections_cache
            .get(name)
            .map(|e| self.collections_cache.hydrate(&e, &self.tag_cache)))
    }

    /// Rewrite a collection's tag links in page order. Tags are universal —
    /// the same tags row a work references, keyed by name.
    fn replace_collection_tags(&self, name: &str, tags: &[String]) -> Result<(), AppError> {
        let (removed, inserted) =
            self.collections_cache.replace_tags(&self.conn, &self.tag_cache, name, tags)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "replace_collection_tags '{}': removed {} old link(s), inserted {}/{} incoming tag(s)",
            name, removed, inserted, tags.len());
        if inserted < tags.len() {
            crate::log_error!(LOG_TAG_COLLECTIONS,
                "replace_collection_tags '{}': {} tag link(s) dropped by INSERT OR IGNORE (duplicate tag names on the profile page?) — tags: [{}]",
                name, tags.len() - inserted, tags.join(", "));
        }
        Ok(())
    }

    /// A collection's tag names, in profile-page order. Answered from the
    /// collections + tag caches — no SQL.
    pub fn get_collection_tags(&self, name: &str) -> Result<Vec<String>, AppError> {
        Ok(self.collections_cache
            .get(name)
            .map(|e| e.tag_ids.iter()
                .filter_map(|id| self.tag_cache.get(*id))
                .map(|t| t.name.to_string())
                .collect())
            .unwrap_or_default())
    }

    /// Record works seen in a collection's listing. Accumulates across
    /// pages — a work stays linked until the work or collection is deleted
    /// (the join rows' foreign keys cascade).
    pub fn add_collection_works(&self, name: &str, work_ids: &[u64]) -> Result<(), AppError> {
        // A listing can be fetched for a collection whose blurb was never
        // cached (deep link) — satisfy the foreign key with a stub row the
        // next blurb or profile save will fill in.
        let stub = self.collections_cache.ensure_stub(&self.conn, name)?;
        let inserted = self.collections_cache.add_works(&self.conn, name, work_ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "add_collection_works '{}': {} work id(s) in, {} new link(s), {} already linked{}",
            name, work_ids.len(), inserted, work_ids.len() - inserted,
            if stub { " — collection row was missing, stub created" } else { "" });
        Ok(())
    }

    /// The cached works seen in a collection's listing, in listing order —
    /// the library-mode view of a collection's works. No network; only
    /// what fetches already recorded in collection_works. One id query;
    /// the works themselves hydrate from the works cache.
    pub fn get_collection_works(&self, name: &str) -> Result<Vec<crate::models::WorkSummary>, AppError> {
        let ids = self.get_collection_work_ids(name)?;
        let works = self.get_works_by_ids_ordered(&ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "get_collection_works '{}': {} link row(s), {} work(s) returned", name, ids.len(), works.len());
        if ids.len() != works.len() {
            crate::log_error!(LOG_TAG_COLLECTIONS,
                "get_collection_works '{}': {} link(s) have no matching works row — those works were never cached",
                name, ids.len() - works.len());
        }
        Ok(works)
    }

    /// Record works seen in a collection's /bookmarks listing. Accumulates
    /// across pages like add_collection_works; join rows cascade away with
    /// the work or collection.
    pub fn add_collection_bookmarks(&self, name: &str, work_ids: &[u64]) -> Result<(), AppError> {
        // Same deep-link stub as add_collection_works — the listing can
        // arrive before any blurb or profile cached the collection row.
        let stub = self.collections_cache.ensure_stub(&self.conn, name)?;
        let inserted = self.collections_cache.add_bookmarks(&self.conn, name, work_ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "add_collection_bookmarks '{}': {} work id(s) in, {} new link(s), {} already linked{}",
            name, work_ids.len(), inserted, work_ids.len() - inserted,
            if stub { " — collection row was missing, stub created" } else { "" });
        Ok(())
    }

    /// The cached works seen in a collection's /bookmarks listing, in
    /// listing order — the library-mode view of a collection's bookmarked
    /// items. No network; only what fetches already recorded. One id query;
    /// the works themselves hydrate from the works cache.
    pub fn get_collection_bookmarks(&self, name: &str) -> Result<Vec<crate::models::WorkSummary>, AppError> {
        let ids: Vec<u64> = self.collections_cache
            .get(name)
            .map(|e| e.bookmark_work_ids.clone())
            .unwrap_or_default();
        let works = self.get_works_by_ids_ordered(&ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "get_collection_bookmarks '{}': {} link row(s), {} work(s) returned", name, ids.len(), works.len());
        if ids.len() != works.len() {
            crate::log_error!(LOG_TAG_COLLECTIONS,
                "get_collection_bookmarks '{}': {} link(s) have no matching works row — those works were never cached",
                name, ids.len() - works.len());
        }
        Ok(works)
    }

    /// The cached work ids for a collection, in the order they were seen.
    /// Answered from the collections cache.
    pub fn get_collection_work_ids(&self, name: &str) -> Result<Vec<u64>, AppError> {
        Ok(self.collections_cache
            .get(name)
            .map(|e| e.work_ids.clone())
            .unwrap_or_default())
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

    pub fn get_reading_lists_for_work(&self, work_id: u64) -> Result<Vec<i64>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT list_id FROM reading_list_items WHERE work_id = ?1"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![work_id as i64], |row| {
            row.get::<_, i64>(0)
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
