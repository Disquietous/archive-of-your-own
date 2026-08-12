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

    pub fn get_cached_chapters(&self, work_id: u64) -> Result<Vec<UChapter>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let chapters = storage.get_chapters(work_id).map_err(AO3Error::from)?;
        Ok(chapters.into_iter().map(UChapter::from).collect())
    }

    // -- Bookmarks --

    pub fn add_bookmark(&self, work_id: u64, note: Option<String>, sync_to_ao3: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.add_bookmark(work_id, note.as_deref(), sync_to_ao3).map_err(AO3Error::from)
    }

    pub fn remove_bookmark(&self, work_id: u64) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.remove_bookmark(work_id).map_err(AO3Error::from)
    }

    pub fn is_bookmarked(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmarked(work_id).map_err(AO3Error::from)
    }

    pub fn update_bookmark_note(&self, work_id: u64, note: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_note(work_id, &note).map_err(AO3Error::from)
    }

    pub fn update_bookmark_sync(&self, work_id: u64, sync: bool) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.update_bookmark_sync(work_id, sync).map_err(AO3Error::from)
    }

    pub fn is_bookmark_synced(&self, work_id: u64) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.is_bookmark_synced(work_id).map_err(AO3Error::from)
    }

    pub fn get_synced_bookmark_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bookmarks = storage.get_synced_bookmarks().map_err(AO3Error::from)?;
        Ok(bookmarks.into_iter().map(|(id, _)| id).collect())
    }

    pub fn get_bookmark(&self, work_id: u64) -> Result<Option<UBookmark>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let bm = storage.get_bookmark_full(work_id).map_err(AO3Error::from)?;
        Ok(bm.map(|(note, sync, ao3_id)| UBookmark {
            work_id,
            note,
            sync_to_ao3: sync,
            ao3_bookmark_id: ao3_id.map(|id| id as i64).unwrap_or(-1),
        }))
    }

    pub fn get_all_bookmarks_full(&self) -> Result<Vec<UBookmark>, AO3Error> {
        let storage = self.storage.blocking_lock();
        let ids = storage.get_bookmarks().map_err(AO3Error::from)?;
        let mut result = Vec::new();
        for work_id in ids {
            if let Some((note, sync, ao3_id)) = storage.get_bookmark_full(work_id).map_err(AO3Error::from)? {
                result.push(UBookmark {
                    work_id,
                    note,
                    sync_to_ao3: sync,
                    ao3_bookmark_id: ao3_id.map(|id| id as i64).unwrap_or(-1),
                });
            }
        }
        Ok(result)
    }

    pub async fn pull_bookmarks(&self, username: String) -> Result<Vec<UBookmark>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let mut all_bookmarks = Vec::new();
            let mut page = 1u32;
            loop {
                let username_for_fetch = username.clone();
                let (listings, has_more) = with_recovery(
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
                    // Upsert bookmark with sync_to_ao3=true
                    log_db("add_bookmark", s.add_bookmark(listing.work_id, Some(&listing.note), true));
                    log_db("set_ao3_bookmark_id", s.set_ao3_bookmark_id(listing.work_id, listing.ao3_bookmark_id));
                    // Save work metadata if available
                    if let Some(ref ws) = listing.work_summary {
                        log_db("save_work", s.save_work(ws));
                    }
                    all_bookmarks.push(UBookmark {
                        work_id: listing.work_id,
                        note: listing.note.clone(),
                        sync_to_ao3: true,
                        ao3_bookmark_id: listing.ao3_bookmark_id as i64,
                    });
                }
                log_db("commit bookmark page", tx.commit());
                drop(s);

                if !has_more || listings.is_empty() {
                    break;
                }
                page += 1;
            }
            Ok(all_bookmarks)
        }).await
    }

    pub async fn push_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let details = {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
                s.get_bookmark_details(work_id).map_err(AO3Error::from)?
            };
            let Some((note, tags, collections, private, rec, _, _)) = details else {
                return Err(AO3Error::Network { message: "No local bookmark to push.".to_string() });
            };

            // Creating a bookmark that already exists updates it in place
            // (AO3-side upsert), so a full retry after rotation is safe.
            let ao3_id = with_recovery(client.clone(), storage.clone(), OpKind::Fetch { label: "bookmark_push".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let (note, tags, collections) = (note.clone(), tags.clone(), collections.clone());
                    async move {
                        client.read().await.create_ao3_bookmark(work_id, &note, &tags, &collections, private, rec)
                            .await.map_err(AO3Error::from)
                    }
                }).await?;

            let s = storage.lock().await;
            {
                let c = client.read().await;
                persist_posting_credentials(&c, &s);
            }
            if let Some(id) = ao3_id {
                s.set_ao3_bookmark_id(work_id, id).map_err(AO3Error::from)?;
                Ok(true)
            } else {
                Err(AO3Error::Network { message: "The archive didn’t accept the bookmark.".to_string() })
            }
        }).await
    }

    /// Full bookmark object for a work (notes, tags, collections, flags).
    pub fn get_bookmark_details(&self, work_id: u64) -> Result<Option<UBookmarkDetails>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_bookmark_details(work_id).map_err(AO3Error::from)?
            .map(|(note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id)| {
                UBookmarkDetails { note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id }
            }))
    }

    pub fn update_bookmark_details(&self, work_id: u64, note: String, tag_string: String,
                                   collection_names: String, private: bool, rec: bool) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.update_bookmark_details(work_id, &note, &tag_string, &collection_names, private, rec)
            .map_err(AO3Error::from)
    }

    pub async fn delete_ao3_bookmark(&self, work_id: u64) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let ao3_id = {
                let s = storage.lock().await;
                s.get_ao3_bookmark_id(work_id).map_err(AO3Error::from)?
            };

            match ao3_id {
                Some(id) => {
                    with_recovery(client, storage, OpKind::Fetch { label: "bookmark_delete".to_string() }, RetrySafety::Idempotent,
                        move |client| async move {
                            client.read().await.delete_ao3_bookmark(id).await.map_err(AO3Error::from)
                        }).await
                }
                None => Ok(false),
            }
        }).await
    }

    pub fn get_bookmarked_work_ids(&self) -> Result<Vec<u64>, AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.get_bookmarks().map_err(AO3Error::from)
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
