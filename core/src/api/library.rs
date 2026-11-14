use super::*;

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    pub fn get_all_progress(&self) -> Result<Vec<UReadingProgress>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let entries = storage.get_all_progress().map_err(AO3Error::from)?;
        Ok(entries.into_iter().map(|(wid, ch, pos)| UReadingProgress {
            work_id: wid, chapter: ch, position: pos,
            chapter_len: storage.chapter_char_len(wid, ch),
        }).collect())
    }

    pub fn mark_downloaded(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.mark_downloaded(work_id).map_err(AO3Error::from)
    }

    pub fn unmark_downloaded(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.unmark_downloaded(work_id).map_err(AO3Error::from)
    }

    pub fn get_downloaded_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_downloaded_ids().map_err(AO3Error::from)
    }

    pub fn set_current_work(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.set_state("current_work_id", &work_id.to_string()).map_err(AO3Error::from)
    }

    pub fn get_current_work(&self) -> Result<Option<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let v = storage.get_state("current_work_id").map_err(AO3Error::from)?;
        Ok(v.and_then(|s| s.parse().ok()))
    }

    pub fn purge_stale_chapters(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.purge_non_retained_chapters().map_err(AO3Error::from)
    }

    // -- Saved searches --

    pub fn save_search(&self, name: String, params_json: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_search(&name, &params_json).map_err(AO3Error::from)
    }

    pub fn get_saved_searches(&self) -> Result<Vec<USavedSearch>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_saved_searches().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, params)| USavedSearch { id, name, params_json: params }).collect())
    }

    pub fn delete_saved_search(&self, search_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_saved_search(search_id).map_err(AO3Error::from)
    }

    // -- Custom Themes --

    pub fn save_custom_theme(&self, id: String, name: String, json: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_theme(&id, &name, &json).map_err(AO3Error::from)
    }

    pub fn get_custom_themes(&self) -> Result<Vec<UCustomTheme>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_all_themes().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, theme_json)| UCustomTheme { id, name, theme_json }).collect())
    }

    pub fn delete_custom_theme(&self, id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_theme(&id).map_err(AO3Error::from)
    }

    // -- Reading Lists --

    pub fn create_reading_list(&self, name: String) -> Result<i64, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.create_reading_list(&name).map_err(AO3Error::from)
    }

    pub fn rename_reading_list(&self, list_id: i64, name: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.rename_reading_list(list_id, &name).map_err(AO3Error::from)
    }

    pub fn delete_reading_list(&self, list_id: i64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_reading_list(list_id).map_err(AO3Error::from)
    }

    pub fn get_reading_lists(&self) -> Result<Vec<UReadingList>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let rows = storage.get_reading_lists().map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, name, count)| UReadingList { id, name, work_count: count }).collect())
    }

    pub fn add_to_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_to_reading_list(list_id, work_id).map_err(AO3Error::from)
    }

    pub fn remove_from_reading_list(&self, list_id: i64, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_from_reading_list(list_id, work_id).map_err(AO3Error::from)
    }

    pub fn get_reading_list_items(&self, list_id: i64) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_reading_list_items(list_id).map_err(AO3Error::from)
    }

    pub fn get_reading_lists_for_work(&self, work_id: u64) -> Result<Vec<i64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_reading_lists_for_work(work_id).map_err(AO3Error::from)
    }

    pub fn get_all_cached_works(&self) -> Result<Vec<UWorkSummary>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let works = storage.get_all_works().map_err(AO3Error::from)?;
        Ok(works.into_iter().map(UWorkSummary::from).collect())
    }

    pub fn get_cached_work(&self, work_id: u64) -> Result<Option<UWorkSummary>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let work = storage.get_work(work_id).map_err(AO3Error::from)?;
        Ok(work.map(UWorkSummary::from))
    }

    /// Chapter titles only — for a chapter picker, which must not decode
    /// every chapter's text to label its rows.
    pub fn get_cached_chapter_titles(&self, work_id: u64) -> Result<Vec<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_chapter_titles(work_id).map_err(AO3Error::from)
    }

    pub fn get_cached_chapters(&self, work_id: u64) -> Result<Vec<UChapter>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let chapters = storage.get_chapters(work_id).map_err(AO3Error::from)?;
        Ok(chapters.into_iter().map(UChapter::from).collect())
    }

    // -- Bookmarks --
    //
    // Two independent things (Area 7): the app bookmark is a flag on a
    // work or series of any source — add / remove / is / get_bookmarked_*
    // below touch nothing else. The AO3 bookmark is the active AO3
    // account's record (note, tags, collections, private, rec, AO3 id) —
    // the *_details / *_sync / push / delete / pull functions — and
    // exists whether or not the target carries the flag. The
    // `*(work_id)` functions are the work-target forms; the `*_series_*`
    // forms are their series twins.

    pub fn add_bookmark(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_bookmark(work_id).map_err(AO3Error::from)
    }

    /// Bookmark a series. The series must be cached (a series bookmark
    /// blurb or series page fetched it) — the database rejects a bookmark
    /// of an unknown target.
    pub fn add_series_bookmark(&self, series_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_bookmark_for(BookmarkTarget::Series(series_id))
            .map(|_| ()).map_err(AO3Error::from)
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_bookmark(work_id).map_err(AO3Error::from)
    }

    pub fn remove_series_bookmark(&self, series_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_bookmark_for(BookmarkTarget::Series(series_id)).map_err(AO3Error::from)
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmarked(work_id).map_err(AO3Error::from)
    }

    pub fn is_series_bookmarked(&self, series_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmarked_for(BookmarkTarget::Series(series_id)).map_err(AO3Error::from)
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_note(work_id, &note).map_err(AO3Error::from)
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_sync(work_id, sync).map_err(AO3Error::from)
    }

    pub fn update_series_bookmark_sync(&self, series_id: u64, sync: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_sync_for(BookmarkTarget::Series(series_id), sync).map_err(AO3Error::from)
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmark_synced(work_id).map_err(AO3Error::from)
    }

    /// Work ids of the active account's AO3-synced bookmarks.
    pub fn get_synced_bookmark_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bookmarks = storage.get_synced_bookmarks().map_err(AO3Error::from)?;
        Ok(bookmarks.into_iter().filter_map(|(t, _)| t.work_id()).collect())
    }

    /// Series ids of the active account's AO3-synced bookmarks.
    pub fn get_synced_series_bookmark_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bookmarks = storage.get_synced_bookmarks().map_err(AO3Error::from)?;
        Ok(bookmarks.into_iter().filter_map(|(t, _)| t.series_id()).collect())
    }

    /// The active AO3 account's own bookmark records, newest first: those
    /// on AO3 and those kept only in the app so far. Library only.
    pub fn get_own_ao3_bookmarks(&self) -> Result<Vec<UBookmarkHit>, AO3Error> {
        let storage = self.storage.blocking_lock();
        Ok(storage.get_own_ao3_bookmarks().map_err(AO3Error::from)?
            .into_iter().map(UBookmarkHit::from).collect())
    }

    /// Pull the signed-in user's own bookmark listing and mirror it locally
    /// as AO3 records (the explicit overwrite path: each listed bookmark's
    /// note replaces the local one). Targets are cached first — the
    /// blurb's work or series — so every record has its referent. No app
    /// flag is set: an AO3 bookmark does not make an app bookmark.
    pub async fn pull_bookmarks(&self, username: String) -> Result<Vec<UBookmark>, AO3Error> {
        // AO3 lists 20 bookmarks a page; this is 10,000 bookmarks. A
        // listing that still claims a next page past it is a parser or
        // site fault, not a bigger collection, and must not crawl forever.
        const MAX_PAGES: u32 = 500;
        self.run_on_runtime(move |client, storage| async move {
            let mut all_bookmarks = Vec::new();
            let mut page = 1u32;
            loop {
                let username_for_fetch = username.clone();
                let (listings, has_more, _, _) = with_recovery(
                    client.clone(), storage.clone(), OpKind::Fetch { label: "bookmarks".to_string() }, RetrySafety::Idempotent,
                    move |client| {
                        let username = username_for_fetch.clone();
                        async move {
                            client.read().await.fetch_user_bookmarks(&username, page).await.map_err(AO3Error::from)
                        }
                    }).await?;

                let s = storage.lock().await;
                // One transaction per pulled page.
                let tx = s.begin_tx().map_err(AO3Error::from)?;
                for listing in &listings {
                    // Mystery bookmarks (unrevealed challenge works) carry
                    // only a synthetic display stub — no real work data to
                    // cache, so a local bookmark row would render blank.
                    // Skip; the pull picks the work up after the reveal.
                    if listing.mystery { continue; }
                    let target = match listing.kind {
                        BookmarkKind::Work => {
                            let Some(ws) = listing.work_summary.as_ref() else { continue };
                            match s.save_listed_work(ws) {
                                Ok(id) => BookmarkTarget::Work(id),
                                Err(e) => { log_error!("db", "save_work failed: {e}"); continue; }
                            }
                        }
                        BookmarkKind::Series => {
                            let Some(sr) = listing.series_summary.as_ref() else { continue };
                            match s.save_series(sr) {
                                Ok(id) => BookmarkTarget::Series(id),
                                Err(e) => { log_error!("db", "save_series failed: {e}"); continue; }
                            }
                        }
                    };
                    // Upsert the record: note from the listing, AO3 id
                    // (which also marks it as synced).
                    if let Err(e) = s.update_bookmark_note_for(target, &listing.note) {
                        log_error!("db", "bookmark record upsert failed: {e}");
                        continue;
                    }
                    log_db("set_ao3_bookmark_id",
                           s.set_ao3_bookmark_id_for(target, listing.ao3_bookmark_id));
                    let id = s.get_ao3_bookmark_record_id(target).ok().flatten().unwrap_or(0);
                    all_bookmarks.push(Self::ubookmark(target, listing.note.clone(), true,
                                                       Some(listing.ao3_bookmark_id), id));
                }
                log_db("commit bookmark page", tx.commit());
                drop(s);

                if !has_more || listings.is_empty() {
                    break;
                }
                if page >= MAX_PAGES {
                    log_error!("bookmarks", "bookmark pull stopped at the {MAX_PAGES}-page cap with more pages claimed");
                    break;
                }
                page += 1;
            }
            Ok(all_bookmarks)
        }).await
    }

    pub async fn push_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.push_bookmark_for(BookmarkTarget::Work(work_id)).await
    }

    pub async fn push_series_bookmark(&self, series_id: u64) -> Result<bool, AO3Error> {
        self.push_bookmark_for(BookmarkTarget::Series(series_id)).await
    }

    /// Full bookmark object for a work (notes, tags, collections, flags).
    pub fn get_bookmark_details(&self, work_id: u64) -> Result<Option<UBookmarkDetails>, AO3Error> {
        self.get_bookmark_details_for(BookmarkTarget::Work(work_id))
    }

    /// Full bookmark object for a series.
    pub fn get_series_bookmark_details(&self, series_id: u64) -> Result<Option<UBookmarkDetails>, AO3Error> {
        self.get_bookmark_details_for(BookmarkTarget::Series(series_id))
    }

    pub fn update_bookmark_details(&self, work_id: u64, note: String, tag_string: String,
                                   collection_names: String, private: bool, rec: bool) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.update_bookmark_details(work_id, &note, &tag_string, &collection_names, private, rec)
            .map_err(AO3Error::from)
    }

    pub fn update_series_bookmark_details(&self, series_id: u64, note: String, tag_string: String,
                                          collection_names: String, private: bool, rec: bool) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.update_bookmark_details_for(BookmarkTarget::Series(series_id), &note, &tag_string,
                                      &collection_names, private, rec)
            .map_err(AO3Error::from)
    }

    pub async fn delete_ao3_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.delete_ao3_bookmark_for(BookmarkTarget::Work(work_id)).await
    }

    pub async fn delete_ao3_series_bookmark(&self, series_id: u64) -> Result<bool, AO3Error> {
        self.delete_ao3_bookmark_for(BookmarkTarget::Series(series_id)).await
    }

    pub fn get_bookmarked_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_bookmarks().map_err(AO3Error::from)
    }

    pub fn get_bookmarked_series_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_bookmarked_series().map_err(AO3Error::from)
    }

    /// A cached series summary (from a series bookmark blurb), if any.
    pub fn get_cached_series(&self, series_id: u64) -> Result<Option<USeriesSummary>, AO3Error> {
        let storage = self.storage.blocking_lock();
        Ok(storage.get_series(series_id).map_err(AO3Error::from)?.map(USeriesSummary::from))
    }

    // -- Reading Progress --

    pub fn save_progress(&self, work_id: u64, chapter: u32, position: u32) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.save_progress(work_id, chapter, position).map_err(AO3Error::from)
    }

    pub fn delete_progress(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.delete_progress(work_id).map_err(AO3Error::from)
    }

    pub fn get_progress(&self, work_id: u64) -> Result<Option<UReadingProgress>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let prog = storage.get_progress(work_id).map_err(AO3Error::from)?;
        Ok(prog.map(|(ch, pos)| UReadingProgress {
            work_id,
            chapter: ch,
            position: pos,
            chapter_len: storage.chapter_char_len(work_id, ch),
        }))
    }

    // -- History --

    pub fn add_to_history(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_to_history(work_id).map_err(AO3Error::from)
    }

    pub fn get_history(&self) -> Result<Vec<UHistoryEntry>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let entries = storage.get_history().map_err(AO3Error::from)?;
        Ok(entries.into_iter().map(|(id, ts)| UHistoryEntry {
            work_id: id,
            accessed_at: ts,
        }).collect())
    }

    pub fn clear_history(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_history().map_err(AO3Error::from)
    }

    // -- Session Cache --

    pub fn set_session_cache(&self, key: String, data: String, session_id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.set_cache(&key, &data, &session_id).map_err(AO3Error::from)
    }

    pub fn get_session_cache(&self, key: String, session_id: String) -> Result<Option<String>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_cache(&key, &session_id).map_err(AO3Error::from)
    }

    pub fn invalidate_session_cache(&self, key: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.invalidate_cache(&key).map_err(AO3Error::from)
    }

    pub fn clear_all_session_cache(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.clear_session_cache().map_err(AO3Error::from)
    }
}

/// Bookmark helpers shared by the work and series forms above — a separate
/// block so UniFFI does not try to export them (BookmarkTarget is not an
/// FFI type).
impl AO3App {
    fn ubookmark(target: BookmarkTarget, note: String, sync: bool, ao3_id: Option<u64>, id: i64) -> UBookmark {
        UBookmark {
            id,
            bookmark_type: target.kind().to_string(),
            target_id: target.id(),
            note,
            sync_to_ao3: sync,
            ao3_bookmark_id: ao3_id.map(|id| id as i64).unwrap_or(-1),
        }
    }

    async fn push_bookmark_for(&self, target: BookmarkTarget) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let details = {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
                s.get_bookmark_details_for(target).map_err(AO3Error::from)?
            };
            let Some((note, tags, collections, private, rec, _, _)) = details else {
                return Err(AO3Error::Network { message: "No AO3 bookmark to send.".to_string() });
            };

            // The client speaks AO3 numbers; the target is a row id.
            let (kind, number) = {
                let s = storage.lock().await;
                match target {
                    BookmarkTarget::Work(id) => (BookmarkKind::Work, ao3_work_number(&s, id)?),
                    BookmarkTarget::Series(id) => (BookmarkKind::Series, ao3_series_number(&s, id)?),
                }
            };
            // Creating a bookmark that already exists updates it in place
            // (AO3-side upsert), so a full retry after rotation is safe.
            let ao3_id = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "bookmark_push".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let (note, tags, collections) = (note.clone(), tags.clone(), collections.clone());
                    async move {
                        client.read().await.create_ao3_bookmark(kind, number, &note, &tags, &collections, private, rec)
                            .await.map_err(AO3Error::from)
                    }
                }).await?;

            let s = storage.lock().await;
            {
                let c = client.read().await;
                persist_posting_credentials(&c, &s);
            }
            if let Some(id) = ao3_id {
                s.set_ao3_bookmark_id_for(target, id).map_err(AO3Error::from)?;
                Ok(true)
            } else {
                Err(AO3Error::Network { message: "The archive didn’t accept the bookmark.".to_string() })
            }
        }).await
    }

    fn get_bookmark_details_for(&self, target: BookmarkTarget) -> Result<Option<UBookmarkDetails>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_bookmark_details_for(target).map_err(AO3Error::from)?
            .map(|(note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id)| {
                UBookmarkDetails {
                    bookmark_type: target.kind().to_string(), target_id: target.id(),
                    note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id,
                }
            }))
    }

    async fn delete_ao3_bookmark_for(&self, target: BookmarkTarget) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let ao3_id = {
                let s = storage.lock().await;
                s.get_ao3_bookmark_id_for(target).map_err(AO3Error::from)?
            };

            // A record that reached AO3 is deleted there first; the local
            // record goes only once AO3 confirms, so a failed request
            // leaves it to retry. One that never left the app just goes.
            if let Some(id) = ao3_id {
                let deleted = with_recovery(client, storage.clone(), OpKind::Fetch { label: "bookmark_delete".to_string() }, RetrySafety::Idempotent,
                    move |client| async move {
                        client.read().await.delete_ao3_bookmark(id).await.map_err(AO3Error::from)
                    }).await?;
                if !deleted {
                    return Ok(false);
                }
            }
            storage.lock().await.remove_ao3_bookmark_for(target).map_err(AO3Error::from)?;
            Ok(true)
        }).await
    }

}

/// Whether `passphrase` opens the library at `db_path` — the key check on
/// a throwaway connection, without building an `AO3App` (runtime, caches,
/// migrations) to find out. Ok(false) is a rejected key; Err is anything
/// else wrong with the file.
#[uniffi::export]
pub fn library_passphrase_valid(db_path: String, passphrase: String) -> Result<bool, AO3Error> {
    match Storage::check_passphrase(&db_path, &passphrase) {
        Ok(()) => Ok(true),
        Err(AppError::WrongPassphrase) => Ok(false),
        Err(e) => Err(AO3Error::from(e)),
    }
}
