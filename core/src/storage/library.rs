use rusqlite::{params, OptionalExtension};

use crate::error::AppError;
use crate::models::{BookmarkHit, BookmarkTarget};

use super::ao3_bookmarks_cache::Ao3BookmarkEntity;
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
    /// chapter without the UI having to load the text itself. Read from
    /// `chapters.char_len`, which save_chapter writes; a row from before
    /// that column (NULL) is measured once here and the result stored.
    pub fn chapter_char_len(&self, work_id: u64, chapter_number: u32) -> u32 {
        let stored: Option<Option<i64>> = self.conn.query_row(
            "SELECT char_len FROM chapters WHERE work_id = ?1 AND number = ?2",
            params![work_id as i64, chapter_number as i64],
            |r| r.get(0),
        ).optional().unwrap_or(None);
        match stored {
            None => 0,
            Some(Some(n)) => n.max(0) as u32,
            Some(None) => {
                let len = match self.get_chapter(work_id, chapter_number) {
                    Ok(Some(chapter)) => content_char_len(&chapter.content),
                    _ => 0,
                };
                let _ = self.conn.execute(
                    "UPDATE chapters SET char_len = ?3 WHERE work_id = ?1 AND number = ?2",
                    params![work_id as i64, chapter_number as i64, len as i64],
                );
                len
            }
        }
    }

    /// Titles of a work's cached chapters in order ("" for an untitled
    /// chapter), without decoding any chapter text.
    pub fn get_chapter_titles(&self, work_id: u64) -> Result<Vec<String>, AppError> {
        let mut stmt = self.conn
            .prepare("SELECT title FROM chapters WHERE work_id = ?1 ORDER BY number ASC")
            .map_err(map_sql)?;
        let rows = stmt.query_map(params![work_id as i64], |r| {
            Ok(r.get::<_, Option<String>>(0)?.unwrap_or_default())
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }
}

/// Character count of chapter content as the readers measure it: text
/// characters, one per line break, rule and block end. Reading positions
/// are offsets in this count, so it has one definition.
pub fn content_char_len(blocks: &[crate::models::ContentBlock]) -> u32 {
    use crate::models::{ContentBlock, InlineContent};

    {
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

        block_len(blocks) as u32
    }
}

impl Storage {
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
    //
    // Two tables since v26 (Area 7): `app_bookmarks` is the app's own
    // flag; `ao3_bookmarks` is the AO3 record (note, tags, collections,
    // private/rec, sync intent, AO3's id). Until Phase 5 rebuilds the UI
    // around the split, the pre-v26 API below is served over both: the
    // flag says "bookmarked", the record carries everything else, and a
    // record exists for the active account only once it has details, sync
    // intent, or an AO3 id. The `*_for` functions take the target; the
    // plain `work_id` functions are the work-target wrappers every
    // existing caller uses.

    /// The active account's row id and owner key — (None, "") when signed
    /// out.
    fn active_owner(&self) -> (Option<i64>, String) {
        match self.get_active_account().ok().flatten() {
            Some(a) => (Some(a.id), a.external_id),
            None => (None, String::new()),
        }
    }

    fn active_flag_id(&self, target: BookmarkTarget) -> Option<i64> {
        let (account_id, _) = self.active_owner();
        self.app_bookmarks.id_of(account_id, target)
    }

    fn active_record_id(&self, target: BookmarkTarget) -> Option<i64> {
        let (_, owner) = self.active_owner();
        self.ao3_bookmarks.id_of(&owner, target)
    }

    /// The active account's AO3 record for a flagged target, created with
    /// defaults when the flag exists without one. None when the target is
    /// not bookmarked at all.
    fn active_record_for_update(&self, target: BookmarkTarget) -> Result<Option<i64>, AppError> {
        if let Some(id) = self.active_record_id(target) {
            return Ok(Some(id));
        }
        if self.active_flag_id(target).is_none() {
            return Ok(None);
        }
        let (account_id, owner) = self.active_owner();
        self.ao3_bookmarks.add(&self.conn, account_id, &owner, target, "", false,
                               &crate::timefmt::now_utc_datetime()).map(Some)
    }

    /// Bookmark a work or series, optionally attaching a note. The target
    /// must already be cached (works/series row) — the database trigger
    /// rejects a dangling bookmark. Sets the flag. An existing AO3 record
    /// for the active account (one cached from a listing, say) is adopted
    /// as is — its AO3 id and details stay — with the note and sync intent
    /// applied when given; otherwise a note or sync intent creates the
    /// record. Returns the flag's row id.
    pub fn add_bookmark_for(&self, target: BookmarkTarget, note: Option<&str>, sync_to_ao3: bool)
        -> Result<i64, AppError>
    {
        let (account_id, owner) = self.active_owner();
        let now = crate::timefmt::now_utc_datetime();
        let flag = self.app_bookmarks.add(&self.conn, account_id, target, &now)?;
        let note = note.unwrap_or("");
        match self.ao3_bookmarks.id_of(&owner, target) {
            Some(id) => {
                if !note.is_empty() {
                    self.ao3_bookmarks.update_note(&self.conn, id, note)?;
                }
                if sync_to_ao3 {
                    self.ao3_bookmarks.update_sync(&self.conn, id, true)?;
                }
            }
            None if !note.is_empty() || sync_to_ao3 => {
                self.ao3_bookmarks.add(&self.conn, account_id, &owner, target, note, sync_to_ao3, &now)?;
            }
            None => {}
        }
        Ok(flag)
    }

    pub fn add_bookmark(&self, work_id: u64, note: Option<&str>, sync_to_ao3: bool) -> Result<(), AppError> {
        self.add_bookmark_for(BookmarkTarget::Work(work_id), note, sync_to_ao3).map(|_| ())
    }

    /// Cache an AO3 bookmark seen in a fetched listing, under the byline
    /// username's owner key — whichever account is (or later becomes)
    /// active sees precisely its own rows. An existing record only
    /// refreshes its AO3 id: locally edited details stay put,
    /// pull_bookmarks remains the explicit overwrite path. An unattributed
    /// blurb (no byline) can't be keyed and isn't cached (returns None).
    /// The target must already be cached. Never sets the app flag.
    pub fn cache_fetched_bookmark_for(&self, bookmarker: &str, target: BookmarkTarget,
                                      ao3_bookmark_id: u64, note: &str,
                                      tag_string: &str, rec: bool) -> Result<Option<i64>, AppError> {
        if bookmarker.trim().is_empty() {
            return Ok(None);
        }
        let owner = super::owner_key_for(bookmarker);
        let account_id = self.find_account(bookmarker)?.map(|a| a.id);
        self.ao3_bookmarks.cache_fetched(&self.conn, account_id, &owner, target, ao3_bookmark_id,
                                         note, tag_string, rec,
                                         &crate::timefmt::now_utc_datetime())
            .map(Some)
    }

    pub fn cache_fetched_bookmark(&self, bookmarker: &str, work_id: u64,
                                  ao3_bookmark_id: u64, note: &str,
                                  tag_string: &str, rec: bool) -> Result<(), AppError> {
        self.cache_fetched_bookmark_for(bookmarker, BookmarkTarget::Work(work_id),
                                        ao3_bookmark_id, note, tag_string, rec).map(|_| ())
    }

    pub fn update_bookmark_note_for(&self, target: BookmarkTarget, note: &str) -> Result<(), AppError> {
        match self.active_record_for_update(target)? {
            Some(id) => self.ao3_bookmarks.update_note(&self.conn, id, note),
            None => Ok(()),
        }
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: &str) -> Result<(), AppError> {
        self.update_bookmark_note_for(BookmarkTarget::Work(work_id), note)
    }

    /// Update the full AO3 bookmark object (notes, own tags, collections,
    /// private/rec flags).
    pub fn update_bookmark_details_for(&self, target: BookmarkTarget, note: &str, tag_string: &str,
                                       collection_names: &str, private: bool, rec: bool) -> Result<(), AppError> {
        match self.active_record_for_update(target)? {
            Some(id) => self.ao3_bookmarks.update_details(&self.conn, id, note, tag_string,
                                                          collection_names, private, rec),
            None => Ok(()),
        }
    }

    pub fn update_bookmark_details(&self, work_id: u64, note: &str, tag_string: &str,
                                   collection_names: &str, private: bool, rec: bool) -> Result<(), AppError> {
        self.update_bookmark_details_for(BookmarkTarget::Work(work_id), note, tag_string,
                                         collection_names, private, rec)
    }

    /// Full bookmark object for a flagged target: (note, tag_string,
    /// collection_names, private, rec, sync_to_ao3, ao3_bookmark_id) —
    /// the record's values, or the defaults when the flag has no record
    /// yet. None when the target is not bookmarked.
    #[allow(clippy::type_complexity)]
    pub fn get_bookmark_details_for(&self, target: BookmarkTarget)
        -> Result<Option<(String, String, String, bool, bool, bool, Option<u64>)>, AppError> {
        if self.active_flag_id(target).is_none() {
            return Ok(None);
        }
        let (_, owner) = self.active_owner();
        Ok(Some(match self.ao3_bookmarks.get(&owner, target) {
            Some(e) => (e.note.clone(), e.tag_string.clone(), e.collection_names.clone(),
                        e.private, e.rec, e.sync_to_ao3, e.ao3_bookmark_id),
            None => (String::new(), String::new(), String::new(), true, false, false, None),
        }))
    }

    #[allow(clippy::type_complexity)]
    pub fn get_bookmark_details(&self, work_id: u64)
        -> Result<Option<(String, String, String, bool, bool, bool, Option<u64>)>, AppError> {
        self.get_bookmark_details_for(BookmarkTarget::Work(work_id))
    }

    /// The active account's flag row id for a target, if any.
    pub fn get_bookmark_id(&self, target: BookmarkTarget) -> Result<Option<i64>, AppError> {
        Ok(self.active_flag_id(target))
    }

    pub fn update_bookmark_sync_for(&self, target: BookmarkTarget, sync: bool) -> Result<(), AppError> {
        match self.active_record_for_update(target)? {
            Some(id) => self.ao3_bookmarks.update_sync(&self.conn, id, sync),
            None => Ok(()),
        }
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AppError> {
        self.update_bookmark_sync_for(BookmarkTarget::Work(work_id), sync)
    }

    /// Un-bookmark: the flag goes, and so does the active account's AO3
    /// record (its collection links cascade).
    pub fn remove_bookmark_for(&self, target: BookmarkTarget) -> Result<(), AppError> {
        if let Some(id) = self.active_flag_id(target) {
            self.app_bookmarks.remove(&self.conn, id)?;
        }
        if let Some(id) = self.active_record_id(target) {
            self.ao3_bookmarks.remove(&self.conn, id)?;
            self.collections_cache.purge_bookmarks(&[id]);
        }
        Ok(())
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AppError> {
        self.remove_bookmark_for(BookmarkTarget::Work(work_id))
    }

    /// The active account's bookmark targets, newest first.
    pub fn get_bookmark_targets(&self) -> Result<Vec<BookmarkTarget>, AppError> {
        let (account_id, _) = self.active_owner();
        Ok(self.app_bookmarks.for_account(account_id).into_iter().map(|e| e.target).collect())
    }

    /// The active account's bookmarked work ids, newest first.
    pub fn get_bookmarks(&self) -> Result<Vec<u64>, AppError> {
        Ok(self.get_bookmark_targets()?.into_iter().filter_map(|t| t.work_id()).collect())
    }

    /// The active account's bookmarked series ids, newest first.
    pub fn get_bookmarked_series(&self) -> Result<Vec<u64>, AppError> {
        Ok(self.get_bookmark_targets()?.into_iter().filter_map(|t| t.series_id()).collect())
    }

    pub fn get_bookmarks_full(&self) -> Result<Vec<(u64, String, bool)>, AppError> {
        let (account_id, owner) = self.active_owner();
        Ok(self.app_bookmarks
            .for_account(account_id)
            .into_iter()
            .filter_map(|e| e.target.work_id().map(|w| {
                let record = self.ao3_bookmarks.get(&owner, e.target);
                (w,
                 record.as_ref().map(|r| r.note.clone()).unwrap_or_default(),
                 record.as_ref().is_some_and(|r| r.sync_to_ao3))
            }))
            .collect())
    }

    /// (target, note) for every bookmark the active account syncs to AO3.
    pub fn get_synced_bookmarks(&self) -> Result<Vec<(BookmarkTarget, String)>, AppError> {
        let (_, owner) = self.active_owner();
        Ok(self.ao3_bookmarks
            .for_owner(&owner)
            .into_iter()
            .filter(|e| e.sync_to_ao3)
            .map(|e| (e.target, e.note.clone()))
            .collect())
    }

    pub fn is_bookmarked_for(&self, target: BookmarkTarget) -> Result<bool, AppError> {
        Ok(self.active_flag_id(target).is_some())
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AppError> {
        self.is_bookmarked_for(BookmarkTarget::Work(work_id))
    }

    /// (note, sync_to_ao3, ao3_bookmark_id) for the active account's
    /// bookmark of a target; None when not bookmarked.
    pub fn get_bookmark_full_for(&self, target: BookmarkTarget)
        -> Result<Option<(String, bool, Option<u64>)>, AppError>
    {
        Ok(self.get_bookmark_details_for(target)?
            .map(|(note, _, _, _, _, sync, ao3_id)| (note, sync, ao3_id)))
    }

    pub fn get_bookmark_full(&self, work_id: u64) -> Result<Option<(String, bool, Option<u64>)>, AppError> {
        self.get_bookmark_full_for(BookmarkTarget::Work(work_id))
    }

    /// Record AO3's id for the active account's bookmark of a target (it
    /// now exists on AO3, so the record carries sync intent too).
    pub fn set_ao3_bookmark_id_for(&self, target: BookmarkTarget, ao3_id: u64) -> Result<(), AppError> {
        match self.active_record_for_update(target)? {
            Some(id) => {
                self.ao3_bookmarks.set_ao3_id(&self.conn, id, ao3_id)?;
                self.ao3_bookmarks.update_sync(&self.conn, id, true)
            }
            None => Ok(()),
        }
    }

    pub fn set_ao3_bookmark_id(&self, work_id: u64, ao3_id: u64) -> Result<(), AppError> {
        self.set_ao3_bookmark_id_for(BookmarkTarget::Work(work_id), ao3_id)
    }

    pub fn get_ao3_bookmark_id_for(&self, target: BookmarkTarget) -> Result<Option<u64>, AppError> {
        let (_, owner) = self.active_owner();
        Ok(self.ao3_bookmarks.get(&owner, target).and_then(|e| e.ao3_bookmark_id))
    }

    pub fn get_ao3_bookmark_id(&self, work_id: u64) -> Result<Option<u64>, AppError> {
        self.get_ao3_bookmark_id_for(BookmarkTarget::Work(work_id))
    }

    pub fn is_bookmark_synced_for(&self, target: BookmarkTarget) -> Result<bool, AppError> {
        let (_, owner) = self.active_owner();
        Ok(self.ao3_bookmarks.get(&owner, target).map(|e| e.sync_to_ao3).unwrap_or(false))
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AppError> {
        self.is_bookmark_synced_for(BookmarkTarget::Work(work_id))
    }

    /// An AO3 bookmark record as a listing hit — its own fields plus the
    /// cached target blurb. None when the target isn't cached (the trigger
    /// makes that impossible for live rows; defensive for cache resyncs).
    fn hit_for_entity(&self, e: &Ao3BookmarkEntity) -> Option<BookmarkHit> {
        let (work, series) = match e.target {
            BookmarkTarget::Work(id) => (Some(self.get_work(id).ok().flatten()?), None),
            BookmarkTarget::Series(id) => (None, Some((*self.series_cache.get(id)?).clone())),
        };
        Some(BookmarkHit {
            id: e.id,
            target: e.target,
            bookmarker: e.owner.clone(),
            note: e.note.clone(),
            tags: e.tag_string.split(',')
                .map(str::trim).filter(|t| !t.is_empty())
                .map(str::to_string).collect(),
            rec: e.rec,
            // Date part only — the timestamp is display noise.
            date_bookmarked: e.created_at.chars().take(10).collect(),
            // Library hits are always real cached targets — mystery stubs
            // are never cached.
            mystery: false,
            mystery_collection_name: String::new(),
            mystery_collection_title: String::new(),
            work,
            series,
        })
    }

    /// Every cached AO3 bookmark attributed to `username` (any owner's
    /// rows, keyed the way fetched listings key them), newest first — the
    /// library-mode view of a user's public bookmarks. Records that exist
    /// only in the app (no `ao3_bookmark_id`) are not on AO3 and are
    /// excluded, even when the user is the signed-in account.
    pub fn get_user_bookmarks(&self, username: &str) -> Result<Vec<BookmarkHit>, AppError> {
        let owner = super::owner_key_for(username);
        Ok(self.ao3_bookmarks.for_owner(&owner)
            .iter()
            .filter(|e| e.ao3_bookmark_id.is_some())
            .filter_map(|e| self.hit_for_entity(e))
            .collect())
    }

    /// AO3 bookmark records by row id, in the given order (unknown ids
    /// skipped).
    pub fn get_bookmark_hits_by_ids(&self, ids: &[i64]) -> Result<Vec<BookmarkHit>, AppError> {
        Ok(ids.iter()
            .filter_map(|id| self.ao3_bookmarks.get_by_id(*id))
            .filter_map(|e| self.hit_for_entity(&e))
            .collect())
    }

    /// Every bookmark the library knows, as AO3-record entities: the
    /// cached records, plus a default-valued stand-in for each app flag
    /// that has no record (so a plain local bookmark still shows in the
    /// library bookmark search, as it did before the split). Stand-ins
    /// carry row id 0.
    fn all_bookmark_entities(&self) -> Vec<std::sync::Arc<Ao3BookmarkEntity>> {
        let mut all = self.ao3_bookmarks.all();
        let accounts: std::collections::HashMap<i64, String> = self.get_all_accounts()
            .unwrap_or_default()
            .into_iter()
            .map(|a| (a.id, a.external_id))
            .collect();
        let flags: Vec<_> = self.app_bookmarks.for_account(None).into_iter()
            .chain(accounts.keys().flat_map(|id| self.app_bookmarks.for_account(Some(*id))))
            .collect();
        for f in flags {
            let owner = f.account_id.and_then(|id| accounts.get(&id).cloned()).unwrap_or_default();
            if self.ao3_bookmarks.id_of(&owner, f.target).is_some() {
                continue;
            }
            all.push(std::sync::Arc::new(Ao3BookmarkEntity {
                id: 0,
                account_id: f.account_id,
                owner,
                target: f.target,
                ao3_bookmark_id: None,
                note: String::new(),
                tag_string: String::new(),
                collection_names: String::new(),
                private: true,
                rec: false,
                sync_to_ao3: false,
                created_at: f.created_at.clone(),
            }));
        }
        all
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
    /// Cached bookmarks matching the full bookmark-search form — every
    /// cached bookmark row (any bookmarker), each hit carrying the
    /// bookmark's own fields plus its target's blurb. Blank criteria match
    /// everything. `limit` of 0 means no limit.
    ///
    /// Local mappings where the cache differs from AO3:
    /// * external-work bookmarks are never cached, so that type filter
    ///   matches nothing;
    /// * the bookmarker (filter and hit field) is the row's account key —
    ///   the lowercased username;
    /// * language compares against the work's language *name* — callers
    ///   pass the display label ("English"), not AO3's code; series carry
    ///   no language, so a language filter excludes them;
    /// * work-tag filters apply to works only (series blurbs carry none);
    /// * Date Bookmarked is the row's created_at — for bookmarks seen in
    ///   fetched listings that's when the app first cached them, not AO3's
    ///   own date.
    pub fn search_local_bookmarks_filtered(
        &self,
        c: &crate::models::BookmarkSearchCriteria,
        limit: u32,
    ) -> Result<Vec<crate::models::BookmarkHit>, AppError> {
        let type_filter = match c.bookmarkable_type.as_str() {
            "" => None,
            "Work" => Some("work"),
            "Series" => Some("series"),
            _ => return Ok(Vec::new()),
        };
        // Every bookmark the library knows, newest first.
        let mut all = self.all_bookmark_entities();
        all.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));

        // Pass 1: bookmark-side criteria — they need no target lookup.
        let mut candidates: Vec<std::sync::Arc<Ao3BookmarkEntity>> = Vec::new();
        for e in all {
            if type_filter.is_some_and(|k| k != e.target.kind()) { continue; }
            if c.rec && !e.rec { continue; }
            if c.with_notes && e.note.trim().is_empty() { continue; }
            let notes_q = c.bookmark_notes.trim();
            if !notes_q.is_empty() && !Self::contains_ci(&e.note, notes_q) { continue; }
            let who = c.bookmarker.trim();
            if !who.is_empty() && !Self::contains_ci(&e.owner, who) { continue; }
            let own_tags: Vec<String> = e.tag_string.split(',')
                .map(str::trim).filter(|t| !t.is_empty())
                .map(str::to_string).collect();
            if !Self::names_match(&c.other_bookmark_tag_names, &own_tags) { continue; }
            let bq = c.bookmark_query.trim();
            if !bq.is_empty()
                && !Self::contains_ci(&e.note, bq)
                && !Self::any_ci(&own_tags, bq)
                && !Self::contains_ci(&e.owner, bq) { continue; }
            if !Self::revised_matches(&c.date, &e.created_at) { continue; }
            candidates.push(e);
        }

        // One batched hydration for every surviving work — the target-side
        // pass must not cost one query per bookmark.
        let mut ids: Vec<u64> = candidates.iter().filter_map(|e| e.target.work_id()).collect();
        ids.sort_unstable();
        ids.dedup();
        let works_by_id: std::collections::HashMap<u64, crate::models::WorkSummary> = self
            .get_works_by_ids_ordered(&ids)?
            .into_iter()
            .map(|w| (w.id, w))
            .collect();

        // Pass 2: target-side criteria, mirroring the works-form matcher.
        let wq = c.bookmarkable_query.trim();
        let language = c.language_id.trim();
        let mut hits: Vec<(crate::models::BookmarkHit, String)> = Vec::new();
        for e in candidates {
            let (work, series) = match e.target {
                BookmarkTarget::Work(id) => {
                    let Some(w) = works_by_id.get(&id) else { continue };
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
                    if !Self::range_matches_opt(&c.word_count, w.word_count) { continue; }
                    if !language.is_empty() && !w.language.eq_ignore_ascii_case(language) { continue; }
                    if !Self::revised_matches(&c.bookmarkable_date, &w.date_updated) { continue; }
                    (Some(w.clone()), None)
                }
                BookmarkTarget::Series(id) => {
                    let Some(sr) = self.series_cache.get(id) else { continue };
                    if !wq.is_empty() {
                        let hit = Self::contains_ci(&sr.name, wq)
                            || Self::any_ci(&sr.authors, wq)
                            || Self::contains_ci(&sr.summary, wq);
                        if !hit { continue; }
                    }
                    if !Self::names_match(&c.other_tag_names, &[]) { continue; }
                    if !Self::range_matches(&c.word_count, sr.word_count) { continue; }
                    if !language.is_empty() { continue; }
                    if !Self::revised_matches(&c.bookmarkable_date, &sr.date_updated) { continue; }
                    (None, Some((*sr).clone()))
                }
            };
            let created_at = e.created_at.clone();
            let mut hit = match self.hit_for_entity(&e) { Some(h) => h, None => continue };
            hit.work = work;
            hit.series = series;
            hits.push((hit, created_at));
        }

        // "Best Match" has no local meaning — it and unknown columns fall
        // back to Date Bookmarked, descending like AO3's default.
        let updated = |h: &crate::models::BookmarkHit| -> String {
            h.work.as_ref().map(|w| w.date_updated.clone())
                .or_else(|| h.series.as_ref().map(|s| s.date_updated.clone()))
                .unwrap_or_default()
        };
        let words = |h: &crate::models::BookmarkHit| -> Option<u64> {
            h.work.as_ref().map(|w| w.word_count)
                .unwrap_or_else(|| h.series.as_ref().map(|s| s.word_count))
        };
        match c.sort_column.as_str() {
            "bookmarkable_date" => hits.sort_by_key(|h| std::cmp::Reverse(updated(&h.0))),
            SORT_KEY_WORD_COUNT => hits.sort_by_key(|h| std::cmp::Reverse(words(&h.0))),
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

    /// Record bookmarks seen in a collection's /bookmarks listing (by
    /// bookmark row id). Accumulates across pages like
    /// add_collection_works; link rows cascade away with the bookmark or
    /// the collection.
    pub fn add_collection_bookmarks(&self, name: &str, bookmark_ids: &[i64]) -> Result<(), AppError> {
        // Same deep-link stub as add_collection_works — the listing can
        // arrive before any blurb or profile cached the collection row.
        let stub = self.collections_cache.ensure_stub(&self.conn, name)?;
        let inserted = self.collections_cache.add_bookmarks(&self.conn, name, bookmark_ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "add_collection_bookmarks '{}': {} bookmark id(s) in, {} new link(s), {} already linked{}",
            name, bookmark_ids.len(), inserted, bookmark_ids.len() - inserted,
            if stub { " — collection row was missing, stub created" } else { "" });
        Ok(())
    }

    /// The cached bookmarks seen in a collection's /bookmarks listing, in
    /// listing order — the library-mode view of a collection's bookmarked
    /// items. No network; only what fetches already recorded.
    pub fn get_collection_bookmarks(&self, name: &str) -> Result<Vec<BookmarkHit>, AppError> {
        let ids: Vec<i64> = self.collections_cache
            .get(name)
            .map(|e| e.bookmark_ids.clone())
            .unwrap_or_default();
        let hits = self.get_bookmark_hits_by_ids(&ids)?;
        crate::log_debug!(LOG_TAG_COLLECTIONS,
            "get_collection_bookmarks '{}': {} link row(s), {} hit(s) returned", name, ids.len(), hits.len());
        Ok(hits)
    }

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

    // -------------------------------------------------------------------
    // Reactions the reader can set and clear (a star rating)
    // -------------------------------------------------------------------

    pub fn set_work_reaction(&self, work_id: u64, value: u8) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO work_reactions (work_id, value) VALUES (?1, ?2)",
            params![work_id as i64, value as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn clear_work_reaction(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM work_reactions WHERE work_id = ?1", params![work_id as i64]).map_err(map_sql)?;
        Ok(())
    }

    pub fn get_work_reaction(&self, work_id: u64) -> Result<Option<u8>, AppError> {
        self.conn.query_row("SELECT value FROM work_reactions WHERE work_id = ?1", params![work_id as i64],
                            |r| r.get::<_, i64>(0)).optional().map_err(map_sql).map(|v| v.map(|v| v as u8))
    }

    /// Every (work id, value) the reader has set.
    pub fn get_work_reactions(&self) -> Result<Vec<(u64, u8)>, AppError> {
        let mut stmt = self.conn.prepare("SELECT work_id, value FROM work_reactions").map_err(map_sql)?;
        let rows = stmt.query_map([], |row| Ok((row.get::<_, i64>(0)? as u64, row.get::<_, i64>(1)? as u8))).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }
}
