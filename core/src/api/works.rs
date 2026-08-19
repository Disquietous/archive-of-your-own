use super::*;

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    pub async fn fetch_search_form(&self) -> Result<Vec<UFormField>, AO3Error> {
        self.run_on_runtime(|client, storage| async move {
            let form = with_recovery(client, storage, OpKind::Fetch { label: "search_form".to_string() }, RetrySafety::Idempotent,
                |client| async move {
                    client.read().await.fetch_search_form().await.map_err(AO3Error::from)
                }).await?;
            Ok(form.fields.into_iter().map(UFormField::from).collect())
        }).await
    }

    /// One page of an author's works. `username` may be a raw byline
    /// ("Pseud (Username)") — it's split here so URLs always carry the
    /// real account name; an explicit `pseud` wins over the byline's.
    /// `op_id`: request-tracking standard (see `fetch_work_full`); a crawl
    /// passes the same id for every page so the whole operation reads as one.
    pub async fn fetch_author_works(&self, username: String, pseud: Option<String>, page: u32, op_id: Option<u64>) -> Result<UPagedWorks, AO3Error> {
        self.run_listing_fetch("author_works", op_id, move |client| {
            let (username, pseud) = (username.clone(), pseud.clone());
            async move {
                let c = client.read().await;
                let (user, byline_pseud) = split_author_byline(&username);
                let pseud = pseud.filter(|p| !p.is_empty()).or(byline_pseud);
                let (works, has_next, total) = c.fetch_author_works(&user, pseud.as_deref(), page).await.map_err(AO3Error::from)?;
                Ok((works, has_next, total, None))
            }
        }).await
    }

    pub async fn fetch_series_works_paged(&self, series_id: u64, page: u32, op_id: Option<u64>) -> Result<UPagedWorks, AO3Error> {
        self.run_listing_fetch("series_works", op_id, move |client| async move {
            let c = client.read().await;
            let (works, has_next, total) = c.fetch_series_works_page(series_id, page).await.map_err(AO3Error::from)?;
            Ok((works, has_next, total, None))
        }).await
    }

    pub async fn browse_works(&self, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        self.run_listing_fetch("browse", None, move |client| async move {
            let c = client.read().await;
            let works = c.browse_works(page).await.map_err(AO3Error::from)?;
            Ok((works, false, 1, None))
        }).await.map(|p| p.works)
    }

    /// `op_id`: request-tracking standard (see `fetch_work_full`).
    pub async fn search_works_raw(&self, keys: Vec<String>, values: Vec<String>, page: u32, op_id: Option<u64>) -> Result<UPagedWorks, AO3Error> {
        let pairs: Vec<(String, String)> = keys.into_iter().zip(values.into_iter()).collect();
        self.run_listing_fetch("search", op_id, move |client| {
            let pairs = pairs.clone();
            async move {
                client.read().await.search_works_raw(&pairs, page).await.map_err(AO3Error::from)
            }
        }).await
    }

    pub async fn search_works(&self, params: USearchParams, page: u32) -> Result<Vec<UWorkSummary>, AO3Error> {
        let search_params: SearchParams = params.into();
        self.run_listing_fetch("search", None, move |client| {
            let search_params = search_params.clone();
            async move {
                let works = client.read().await.search_works(&search_params, page).await.map_err(AO3Error::from)?;
                Ok((works, false, 1, None))
            }
        }).await.map(|p| p.works)
    }

    pub async fn search_by_tag(&self, tag: String, page: u32) -> Result<UPagedWorks, AO3Error> {
        self.run_listing_fetch("tag_browse", None, move |client| {
            let tag = tag.clone();
            async move {
                client.read().await.search_by_tag(&tag, page).await.map_err(AO3Error::from)
            }
        }).await
    }

    /// One page of the public collections index, optionally sorted/filtered
    /// with the index's collection_search[...] criteria (None = the plain
    /// index). Every fetched page is cached into the collections table
    /// (upsert by slug) — the library-scoped collection search reads that
    /// cache.
    /// `op_id`: request-tracking standard (see `fetch_work_full`).
    pub async fn browse_collections(
        &self,
        criteria: Option<UCollectionSearchCriteria>,
        page: u32,
        op_id: Option<u64>,
    ) -> Result<UCollectionsPage, AO3Error> {
        let criteria: Option<CollectionSearchCriteria> = criteria.map(Into::into);
        self.run_on_runtime(move |client, storage| async move {
            let (collections, has_next, total) = with_recovery_as(
                client, storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "collections_browse".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let criteria = criteria.clone();
                    async move {
                        client.read().await.fetch_collections(criteria.as_ref(), page).await
                            .map_err(AO3Error::from)
                    }
                }).await?;
            log_debug!("collections",
                "browse_collections page {page}: parsed {} blurb(s) (has_next={has_next}, total_pages={total}) — saving",
                collections.len());
            {
                let s = storage.lock().await;
                log_db("save_collections", s.save_collections(&collections));
            }
            Ok(UCollectionsPage {
                collections: collections.into_iter().map(UCollection::from).collect(),
                has_next_page: has_next,
                total_pages: total,
            })
        }).await
    }

    // -- Library-scoped search (cached data only, no network). The caller
    // decides whether to cap results; a None limit returns every match. --

    /// Cached works whose title, creators, fandoms, tags, or summary match.
    pub fn search_library_works(&self, term: String, limit: Option<u32>) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_local_works(&term, limit.unwrap_or(0)).map_err(AO3Error::from)?
            .into_iter().map(UWorkSummary::from).collect())
    }

    /// Cached works matching the full works-search form. Blank criteria
    /// match everything, so the default form returns the whole library.
    pub fn search_library_works_filtered(
        &self,
        criteria: ULibrarySearchCriteria,
        limit: Option<u32>,
    ) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_local_works_filtered(&criteria.into(), limit.unwrap_or(0))
            .map_err(AO3Error::from)?
            .into_iter().map(UWorkSummary::from).collect())
    }

    /// Cached tag names matching, across every tag type.
    pub fn search_library_tags(&self, term: String, limit: Option<u32>) -> Result<Vec<UTagHit>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_tags_all(&term, limit.unwrap_or(0)).map_err(AO3Error::from)?
            .into_iter()
            .map(|(name, tag_type)| UTagHit { name, tag_type })
            .collect())
    }

    /// Cached AO3 usernames matching.
    pub fn search_library_users(&self, term: String, limit: Option<u32>) -> Result<Vec<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.search_ao3_usernames(&term, limit.unwrap_or(0)).map_err(AO3Error::from)
    }

    /// Cached collection blurbs matching.
    pub fn search_library_collections(&self, term: String, limit: Option<u32>) -> Result<Vec<UCollection>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_collections(&term, limit.unwrap_or(0)).map_err(AO3Error::from)?
            .into_iter().map(UCollection::from).collect())
    }

    /// The cached works seen in a collection's listing, in listing order —
    /// the library-mode view of a collection's works, no network.
    pub fn get_library_collection_works(&self, name: String) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_collection_works(&name).map_err(AO3Error::from)?
            .into_iter().map(UWorkSummary::from).collect())
    }

    /// The cached works seen in a collection's /bookmarks listing, in
    /// listing order — the library-mode view of a collection's bookmarked
    /// items, no network.
    pub fn get_library_collection_bookmarks(&self, name: String) -> Result<Vec<UWorkSummary>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_collection_bookmarks(&name).map_err(AO3Error::from)?
            .into_iter().map(UWorkSummary::from).collect())
    }

    /// Cached collections matching the full collections sort/filter form —
    /// the same criteria AO3's index accepts, evaluated against the cached
    /// rows. Blank criteria match everything.
    pub fn search_library_collections_filtered(
        &self,
        criteria: UCollectionSearchCriteria,
        limit: Option<u32>,
    ) -> Result<Vec<UCollection>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_collections_filtered(&criteria.into(), limit.unwrap_or(0))
            .map_err(AO3Error::from)?
            .into_iter().map(UCollection::from).collect())
    }

    /// One page of a collection's works, cached like every other listing —
    /// plus the collection↔work relationship, so the library knows which
    /// cached works were seen in which collection.
    pub async fn fetch_collection_works(&self, name: String, page: u32) -> Result<UPagedWorks, AO3Error> {
        let slug = name.clone();
        self.run_on_runtime(move |client, storage| async move {
            let (works, has_next, total, found) = with_recovery(
                client, storage.clone(),
                OpKind::Fetch { label: "collection_works".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let name = name.clone();
                    async move {
                        client.read().await.fetch_collection_works(&name, page).await.map_err(AO3Error::from)
                    }
                }).await?;
            log_debug!("collections",
                "fetch_collection_works '{slug}' page {page}: parsed {} work(s) (has_next={has_next}, total_pages={total}) — saving works + collection_works links",
                works.len());
            let s = storage.lock().await;
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            for w in &works { log_db("save_work", s.save_work(w)); }
            let ids: Vec<u64> = works.iter().map(|w| w.id).collect();
            log_db("save_collection_works", s.add_collection_works(&slug, &ids));
            log_db("commit listing save", tx.commit());
            Ok(UPagedWorks {
                works: works.into_iter().map(UWorkSummary::from).collect(),
                has_next_page: has_next,
                total_pages: total,
                total_works: found,
            })
        }).await
    }

    /// One page of a collection's bookmarked items (series/external
    /// bookmarks are skipped by the parser). Everything the listing showed
    /// is cached: the works like every other listing, the bookmark rows
    /// themselves (scoped to whoever made them — only the active user's
    /// own land in the Bookmarks view), and the collection↔work rows in
    /// collection_bookmarks, so library mode can replay the listing.
    pub async fn fetch_collection_bookmarks(&self, name: String, page: u32) -> Result<UPagedWorks, AO3Error> {
        let slug = name.clone();
        self.run_on_runtime(move |client, storage| async move {
            let (listings, has_next, total, found) = with_recovery(
                client, storage.clone(),
                OpKind::Fetch { label: "collection_bookmarks".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let name = name.clone();
                    async move {
                        client.read().await.fetch_collection_bookmarks(&name, page).await.map_err(AO3Error::from)
                    }
                }).await?;
            let listing_count = listings.len();
            let s = storage.lock().await;
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            let mut works = Vec::new();
            // Ids to link into collection_bookmarks — cached works only.
            let mut cached_ids = Vec::new();
            for l in listings {
                let Some(w) = l.work_summary else { continue };
                // Mystery stubs display in the returned page but are never
                // cached, and never linked into collection_bookmarks —
                // there is no real work data behind them until the reveal.
                if l.mystery {
                    works.push(w);
                    continue;
                }
                log_db("save_work", s.save_work(&w));
                log_db("cache_fetched_bookmark",
                       s.cache_fetched_bookmark(&l.bookmarker, l.work_id, l.ao3_bookmark_id,
                                                &l.note, &l.tags.join(", "), l.rec));
                cached_ids.push(w.id);
                works.push(w);
            }
            log_debug!("collections",
                "fetch_collection_bookmarks '{slug}' page {page}: parsed {listing_count} listing(s), {} with a work blurb ({} skipped: series/external/deleted) (has_next={has_next}, total_pages={total}) — saving works + bookmark rows + collection_bookmarks links",
                works.len(), listing_count - works.len());
            log_db("save_collection_bookmarks", s.add_collection_bookmarks(&slug, &cached_ids));
            log_db("commit listing save", tx.commit());
            Ok(UPagedWorks {
                works: works.into_iter().map(UWorkSummary::from).collect(),
                has_next_page: has_next,
                total_pages: total,
                total_works: found,
            })
        }).await
    }

    /// One page of AO3's /bookmarks/search under the bookmark_search[...]
    /// criteria — full bookmark hits (bookmarker, their tags, note, rec,
    /// date) with the work blurb embedded. Everything the listing showed is
    /// cached like every other listing: the works, and the bookmark rows
    /// attributed to whoever made them (series/external bookmarks are
    /// skipped by the parser).
    /// `op_id`: request-tracking standard (see `fetch_work_full`).
    pub async fn search_bookmarks(&self, criteria: UBookmarkSearchCriteria, page: u32, op_id: Option<u64>) -> Result<UPagedBookmarks, AO3Error> {
        let criteria: BookmarkSearchCriteria = criteria.into();
        self.run_on_runtime(move |client, storage| async move {
            let (listings, has_next, total, found) = with_recovery_as(
                client, storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "bookmark_search".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let criteria = criteria.clone();
                    async move {
                        client.read().await.search_bookmarks(&criteria, page).await.map_err(AO3Error::from)
                    }
                }).await?;
            let listing_count = listings.len();
            let s = storage.lock().await;
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            let mut hits = Vec::new();
            for l in listings {
                let Some(w) = l.work_summary else { continue };
                // Mystery hits display but never cache: the work stub has
                // no real data, and cache-forever would keep showing
                // "Mystery Work" long after the collection reveals it.
                if !l.mystery {
                    log_db("save_work", s.save_work(&w));
                    log_db("cache_fetched_bookmark",
                           s.cache_fetched_bookmark(&l.bookmarker, l.work_id, l.ao3_bookmark_id,
                                                    &l.note, &l.tags.join(", "), l.rec));
                }
                hits.push(BookmarkHit {
                    bookmarker: l.bookmarker,
                    note: l.note,
                    tags: l.tags,
                    rec: l.rec,
                    date_bookmarked: l.date_bookmarked,
                    mystery: l.mystery,
                    mystery_collection_name: l.mystery_collection_name,
                    mystery_collection_title: l.mystery_collection_title,
                    work: w,
                });
            }
            log_debug!("search",
                "search_bookmarks page {page}: parsed {listing_count} listing(s), {} with a work blurb ({} skipped: series/external/deleted) (has_next={has_next}, total_pages={total}) — saving works + bookmark rows",
                hits.len(), listing_count - hits.len());
            log_db("commit listing save", tx.commit());
            Ok(UPagedBookmarks {
                bookmarks: hits.into_iter().map(UBookmarkHit::from).collect(),
                has_next_page: has_next,
                total_pages: total,
                total_found: found,
            })
        }).await
    }

    /// Cached bookmarks matching the full bookmark-search form — every
    /// bookmark row the app has cached, each hit carrying the bookmark's
    /// own fields plus its work's blurb. Blank criteria match everything.
    /// No network.
    pub fn search_library_bookmarks_filtered(
        &self,
        criteria: UBookmarkSearchCriteria,
        limit: Option<u32>,
    ) -> Result<Vec<UBookmarkHit>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.search_local_bookmarks_filtered(&criteria.into(), limit.unwrap_or(0))
            .map_err(AO3Error::from)?
            .into_iter().map(UBookmarkHit::from).collect())
    }

    /// The collection's /profile metadata and tags, fetched once and cached
    /// forever (like everything else): a cached profile answers from the
    /// database without touching the network.
    pub async fn ensure_collection_profile(&self, name: String) -> Result<UCollection, AO3Error> {
        let slug = name.clone();
        self.run_on_runtime(move |client, storage| async move {
            {
                let s = storage.lock().await;
                if s.collection_profile_cached(&slug).map_err(AO3Error::from)? {
                    if let Some(cached) = s.get_collection(&slug).map_err(AO3Error::from)? {
                        log_debug!("collections",
                            "ensure_collection_profile '{slug}': cache hit ({} tag(s), works={}, bookmarks={}) — no fetch",
                            cached.tags.len(), cached.work_count, cached.bookmarked_count);
                        return Ok(UCollection::from(cached));
                    }
                    log_error!("collections",
                        "ensure_collection_profile '{slug}': profile_fetched_at is stamped but the row failed to read back — re-fetching");
                } else {
                    log_debug!("collections",
                        "ensure_collection_profile '{slug}': no cached profile — fetching /profile");
                }
            }
            let profile = with_recovery(
                client, storage.clone(),
                OpKind::Fetch { label: "collection_profile".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let name = name.clone();
                    async move {
                        client.read().await.fetch_collection_profile(&name).await.map_err(AO3Error::from)
                    }
                }).await?;
            log_debug!("collections",
                "ensure_collection_profile '{}': fetched profile (title='{}', {} tag(s), type='{}') — saving",
                profile.name, profile.title, profile.tags.len(), profile.collection_type);
            let s = storage.lock().await;
            log_db("save_collection_profile", s.save_collection_profile(&profile));
            // Return the merged row (profile zeroes keep the blurb's counts).
            Ok(UCollection::from(s.get_collection(&profile.name)
                .map_err(AO3Error::from)?
                .unwrap_or(profile)))
        }).await
    }

    /// `op_id`: a caller-obtained `new_operation_id` ties the fetch to the
    /// requesting view per the request-tracking standard; None = untracked
    /// (the core assigns an internal id).
    pub async fn fetch_work_full(&self, work_id: u64, op_id: Option<u64>) -> Result<UWorkSummary, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (summary, chapters, kudos_names) = super::with_recovery_as(
                client, storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "work".to_string() }, RetrySafety::Idempotent,
                move |client| async move {
                    client.read().await.get_work(work_id).await.map_err(AO3Error::from)
                }).await?;
            let s = storage.lock().await;
            // Work + series + chapters land atomically.
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            log_db("save_work", s.save_work(&summary));
            log_db("set_work_series", s.set_work_series(summary.id, &summary.series));
            record_kudos_if_listed(&s, work_id, &kudos_names);
            for ch in &chapters { log_db("save_chapter", s.save_chapter(work_id, ch)); }
            log_db("commit work save", tx.commit());
            Ok(UWorkSummary::from(summary))
        }).await
    }

    pub async fn fetch_work(&self, work_id: u64, op_id: Option<u64>) -> Result<UWorkSummary, AO3Error> {
        self.fetch_work_full(work_id, op_id).await
    }

    /// `op_id`: request-tracking standard (see `fetch_work_full`).
    pub async fn fetch_chapters(&self, work_id: u64, op_id: Option<u64>) -> Result<Vec<UChapter>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (_, chapters, kudos_names) = super::with_recovery_as(
                client.clone(), storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "chapters".to_string() }, RetrySafety::Idempotent,
                move |client| async move {
                    client.read().await.get_work(work_id).await.map_err(AO3Error::from)
                }).await?;
            let c = client.read().await;
            let s = storage.lock().await;
            record_kudos_if_listed(&s, work_id, &kudos_names);
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            for ch in &chapters { log_db("save_chapter", s.save_chapter(work_id, ch)); }
            log_db("commit chapters", tx.commit());
            // Content pages carry the posting credentials (CSRF token, pseud) —
            // persist what the fetch harvested so later kudos/comment POSTs
            // need no preparatory request.
            persist_posting_credentials(&c, &s);
            Ok(chapters.into_iter().map(UChapter::from).collect())
        }).await
    }

    pub async fn fetch_image(&self, url: String) -> Result<Vec<u8>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            with_recovery(client, storage, OpKind::Image, RetrySafety::Idempotent, move |client| {
                let url = url.clone();
                async move { client.read().await.fetch_image(&url).await.map_err(AO3Error::from) }
            }).await
        }).await
    }

    // -- Chapter images (tap-to-load; bytes cached in image_cache) --

    /// Cache-only lookup — the renderer's synchronous "is it already here".
    /// A cached body that isn't a real image (poison from before the sniff
    /// guard existed) is purged and reported as absent.
    pub fn get_cached_chapter_image(&self, url: String) -> Result<Option<Vec<u8>>, AO3Error> {
        let s = self.storage.blocking_lock();
        let key = chapter_image_key(&url);
        match s.get_cached_image(&key).map_err(AO3Error::from)? {
            Some(data) if crate::client::sniff_image_kind(&data) == "not-an-image" => {
                log_info!("image", "Purging non-image cache entry ({} bytes) for {url}", data.len());
                log_db("delete_cached_image", s.delete_cached_image(&key));
                Ok(None)
            }
            other => Ok(other),
        }
    }

    /// Fetch one embedded image (cache-first, over the private connection).
    /// `max_bytes` 0 = unlimited; an over-cap image errors and is not cached.
    pub async fn fetch_chapter_image(&self, url: String, max_bytes: u64) -> Result<Vec<u8>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            log_info!("image", "Chapter image requested (cap {} bytes): {url}", max_bytes);
            {
                let s = storage.lock().await;
                if let Ok(Some(data)) = s.get_cached_image(&chapter_image_key(&url)) {
                    let kind = crate::client::sniff_image_kind(&data);
                    if kind == "not-an-image" {
                        // Poisoned entry from before the sniff guard — purge
                        // and fall through to a fresh fetch.
                        log_info!("image", "Purging non-image cache entry ({} bytes), refetching {url}", data.len());
                        log_db("delete_cached_image", s.delete_cached_image(&chapter_image_key(&url)));
                    } else {
                        log_info!("image", "Cache hit ({} bytes, {kind}): {url}", data.len());
                        return Ok(data);
                    }
                }
            }
            let url_for_fetch = url.clone();
            let bytes = with_recovery(client, storage.clone(), OpKind::Image, RetrySafety::Idempotent, move |client| {
                let url = url_for_fetch.clone();
                async move { client.read().await.fetch_image(&url).await.map_err(AO3Error::from) }
            }).await?;
            if max_bytes > 0 && bytes.len() as u64 > max_bytes {
                log_info!("image", "Skipping {url}: {} bytes exceeds the {max_bytes}-byte cap", bytes.len());
                return Err(AO3Error::Network {
                    message: format!("Image is {:.1} MB — over the size limit",
                                     bytes.len() as f64 / 1_048_576.0),
                });
            }
            // Never cache non-image bodies, and tell the user what actually
            // happened instead of a downstream decode failure.
            if crate::client::sniff_image_kind(&bytes) == "not-an-image" {
                return Err(AO3Error::Network {
                    message: "The host sent a web page instead of the image — it may be blocking private connections".to_string(),
                });
            }
            let s = storage.lock().await;
            log_db("save_cached_image", s.save_cached_image(&chapter_image_key(&url), &bytes));
            log_info!("image", "Cached {} bytes ({}) for {url}",
                      bytes.len(), crate::client::sniff_image_kind(&bytes));
            Ok(bytes)
        }).await
    }

    /// Prefetch every embedded image of a downloaded work into the cache so
    /// offline reading is complete. Over-cap and failed images are skipped
    /// (logged), not fatal. Returns how many images were newly fetched.
    pub async fn download_work_images(&self, work_id: u64, max_bytes: u64) -> Result<u32, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let srcs: Vec<String> = {
                let s = storage.lock().await;
                let chapters = s.get_chapters(work_id).map_err(AO3Error::from)?;
                let mut srcs = Vec::new();
                for chapter in &chapters {
                    collect_image_srcs(&chapter.content, &mut srcs);
                }
                srcs
            };
            log_info!("image", "Offline prefetch for work {work_id}: {} image(s), cap {max_bytes} bytes",
                      srcs.len());
            let mut fetched = 0u32;
            for src in srcs {
                {
                    let s = storage.lock().await;
                    if let Ok(Some(data)) = s.get_cached_image(&chapter_image_key(&src)) {
                        if crate::client::sniff_image_kind(&data) != "not-an-image" {
                            continue;
                        }
                        // Poisoned entry — purge and refetch below.
                        log_db("delete_cached_image", s.delete_cached_image(&chapter_image_key(&src)));
                    }
                }
                let src_for_fetch = src.clone();
                let result = with_recovery(client.clone(), storage.clone(), OpKind::Image, RetrySafety::Idempotent,
                    move |client| {
                        let src = src_for_fetch.clone();
                        async move { client.read().await.fetch_image(&src).await.map_err(AO3Error::from) }
                    }).await;
                match result {
                    Ok(bytes) => {
                        if max_bytes > 0 && bytes.len() as u64 > max_bytes {
                            log_info!("image", "Offline prefetch skipping {src}: {} bytes over cap", bytes.len());
                            continue;
                        }
                        let s = storage.lock().await;
                        log_db("save_cached_image", s.save_cached_image(&chapter_image_key(&src), &bytes));
                        fetched += 1;
                    }
                    Err(e) => {
                        log_info!("image", "Offline prefetch failed for {src}: {e}");
                    }
                }
            }
            Ok(fetched)
        }).await
    }

    /// Local tag autocomplete — instant, DB-only, works offline. Suggests
    /// from tags harvested off every work the user has seen.
    pub fn search_local_tags(&self, tag_type: String, term: String, limit: u32) -> Result<Vec<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.search_tags(&tag_type, &term, limit).map_err(AO3Error::from)
    }

    /// Explicit AO3 autocomplete lookup (user-triggered only). Successful
    /// results are cached as canonical, permanently improving local
    /// suggestions.
    pub async fn autocomplete_tags_remote(&self, tag_type: String, term: String) -> Result<Vec<String>, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let (tag_type_for_fetch, term_for_fetch) = (tag_type.clone(), term.clone());
            let names = with_recovery(client, storage.clone(), OpKind::Fetch { label: "autocomplete".to_string() }, RetrySafety::Idempotent,
                move |client| {
                    let (tag_type, term) = (tag_type_for_fetch.clone(), term_for_fetch.clone());
                    async move { client.read().await.autocomplete(&tag_type, &term).await.map_err(AO3Error::from) }
                }).await?;
            let s = storage.lock().await;
            log_db("mark_tags_canonical", s.mark_tags_canonical(&tag_type, &names));
            Ok(names)
        }).await
    }

    /// Export a downloaded work as an EPUB3 file. Requires cached chapters.
    pub fn export_epub(&self, work_id: u64, dest_path: String) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let work = s.get_work(work_id).map_err(AO3Error::from)?
            .ok_or(AO3Error::Network { message: "This work isn’t in the local library.".to_string() })?;
        let chapters = s.get_chapters(work_id).map_err(AO3Error::from)?;
        if chapters.is_empty() {
            return Err(AO3Error::Network { message: "No downloaded chapters — download the work first.".to_string() });
        }
        crate::epub::export_epub(&work, &chapters, &dest_path).map_err(AO3Error::from)
    }
}
