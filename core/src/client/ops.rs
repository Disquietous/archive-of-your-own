use crate::error::AppError;
use crate::models::*;
use crate::parser;

use super::{AO3Client, BASE_URL, FailureKind};
use super::audit::{ActiveRequestGuard, AuditCtx};
use super::helpers::{ao3_tag_encode, extract_bookmark_id_from_response, sniff_image_kind,
                     sub_id_from_action, urlencoded};

impl AO3Client {
    // -- Public API ---------------------------------------------------------

    /// Fetch the search form structure from /works/search?edit_search=true
    pub async fn fetch_search_form(&self) -> Result<SearchForm, AppError> {
        let url = format!("{BASE_URL}/works/search?edit_search=true");
        let html = self.fetch(&url).await?;
        parser::parse_search_form(&html)
    }

    /// Browse latest works (returns one page from /works).
    pub async fn browse_works(&self, page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let url = format!("{BASE_URL}/works?page={page}");
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Search works with raw query string parameters.
    /// Returns (works, has_next_page, total_pages, total_works) — pagination
    /// read from the results page itself, not inferred from the page size.
    pub async fn search_works_raw(&self, query_pairs: &[(String, String)], page: u32) -> Result<(Vec<WorkSummary>, bool, u32, Option<u32>), AppError> {
        let mut parts: Vec<String> = vec![format!("page={page}"), "commit=Search".to_string()];
        for (key, value) in query_pairs {
            if !value.is_empty() {
                let encoded_key = key.replace('[', "%5B").replace(']', "%5D");
                parts.push(format!("{}={}", encoded_key, urlencoded(value)));
            }
        }
        let url = format!("{BASE_URL}/works/search?{}", parts.join("&"));
        let html = self.fetch(&url).await?;
        let works = parser::parse_work_listings(&html)?;
        Ok((works, parser::has_next_page(&html), parser::total_pages(&html),
            parser::parse_results_total(&html)))
    }

    /// Search works using AO3's search engine (/works/search).
    /// Mirrors the full search form at archiveofourown.org/works/search.
    pub async fn search_works(&self, params: &SearchParams, page: u32) -> Result<Vec<WorkSummary>, AppError> {
        let mut parts: Vec<String> = Vec::new();
        parts.push(format!("page={page}"));
        parts.push("commit=Search".to_string());

        if !params.query.is_empty() {
            parts.push(format!("work_search%5Bquery%5D={}", urlencoded(&params.query)));
        }
        if !params.title.is_empty() {
            parts.push(format!("work_search%5Btitle%5D={}", urlencoded(&params.title)));
        }
        if !params.creators.is_empty() {
            parts.push(format!("work_search%5Bcreators%5D={}", urlencoded(&params.creators)));
        }
        if !params.fandom_names.is_empty() {
            parts.push(format!("work_search%5Bfandom_names%5D={}", urlencoded(&params.fandom_names)));
        }
        if !params.relationship_names.is_empty() {
            parts.push(format!("work_search%5Brelationship_names%5D={}", urlencoded(&params.relationship_names)));
        }
        if !params.character_names.is_empty() {
            parts.push(format!("work_search%5Bcharacter_names%5D={}", urlencoded(&params.character_names)));
        }
        if !params.freeform_names.is_empty() {
            parts.push(format!("work_search%5Bfreeform_names%5D={}", urlencoded(&params.freeform_names)));
        }
        if !params.word_count.is_empty() {
            parts.push(format!("work_search%5Bword_count%5D={}", urlencoded(&params.word_count)));
        }
        if !params.hits.is_empty() {
            parts.push(format!("work_search%5Bhits%5D={}", urlencoded(&params.hits)));
        }
        if !params.kudos_count.is_empty() {
            parts.push(format!("work_search%5Bkudos_count%5D={}", urlencoded(&params.kudos_count)));
        }
        if !params.comments_count.is_empty() {
            parts.push(format!("work_search%5Bcomments_count%5D={}", urlencoded(&params.comments_count)));
        }
        if !params.bookmarks_count.is_empty() {
            parts.push(format!("work_search%5Bbookmarks_count%5D={}", urlencoded(&params.bookmarks_count)));
        }
        if !params.revised_at.is_empty() {
            parts.push(format!("work_search%5Brevised_at%5D={}", urlencoded(&params.revised_at)));
        }
        if !params.sort_column.is_empty() {
            parts.push(format!("work_search%5Bsort_column%5D={}", urlencoded(&params.sort_column)));
        }
        if !params.sort_direction.is_empty() {
            parts.push(format!("work_search%5Bsort_direction%5D={}", urlencoded(&params.sort_direction)));
        }
        if let Some(rating_id) = params.rating_id {
            parts.push(format!("work_search%5Brating_ids%5D={rating_id}"));
        }
        for wid in &params.warning_ids {
            parts.push(format!("work_search%5Barchive_warning_ids%5D%5B%5D={wid}"));
        }
        for cid in &params.category_ids {
            parts.push(format!("work_search%5Bcategory_ids%5D%5B%5D={cid}"));
        }
        if !params.complete.is_empty() {
            parts.push(format!("work_search%5Bcomplete%5D={}", urlencoded(&params.complete)));
        }
        if !params.crossover.is_empty() {
            parts.push(format!("work_search%5Bcrossover%5D={}", urlencoded(&params.crossover)));
        }
        if params.single_chapter {
            parts.push("work_search%5Bsingle_chapter%5D=1".to_string());
        }
        if !params.language_id.is_empty() {
            parts.push(format!("work_search%5Blanguage_id%5D={}", urlencoded(&params.language_id)));
        }

        let url = format!("{BASE_URL}/works/search?{}", parts.join("&"));
        let html = self.fetch(&url).await?;
        parser::parse_work_listings(&html)
    }

    /// Browse works by tag (returns one page from /tags/{tag}/works).
    /// Returns (works, has_next_page, total_pages, total_works), as
    /// search_works_raw.
    pub async fn search_by_tag(&self, tag: &str, page: u32) -> Result<(Vec<WorkSummary>, bool, u32, Option<u32>), AppError> {
        let encoded_tag = ao3_tag_encode(tag);
        let url = format!("{BASE_URL}/tags/{encoded_tag}/works?page={page}");
        let html = self.fetch(&url).await?;
        let works = parser::parse_work_listings(&html)?;
        Ok((works, parser::has_next_page(&html), parser::total_pages(&html),
            parser::parse_results_total(&html)))
    }

    /// Browse the public collections index (/collections?page=N), optionally
    /// sorted/filtered via the index's collection_search[...] GET params —
    /// the same query string AO3's own "Sort and Filter" form submits.
    /// Returns (collections, has_next_page, total_pages) — pagination read
    /// from the page itself.
    pub async fn fetch_collections(
        &self,
        criteria: Option<&CollectionSearchCriteria>,
        page: u32,
    ) -> Result<(Vec<CollectionSummary>, bool, u32), AppError> {
        let mut url = format!("{BASE_URL}/collections?page={page}");
        if let Some(c) = criteria {
            for (key, value) in [
                ("sort_column", c.sort_column.as_str()),
                ("sort_direction", c.sort_direction.as_str()),
                ("title", c.title.as_str()),
                ("tag", c.tag.as_str()),
                ("multifandom", c.multifandom.as_str()),
                ("closed", c.closed.as_str()),
                ("moderated", c.moderated.as_str()),
                ("challenge_type", c.challenge_type.as_str()),
            ] {
                if !value.is_empty() {
                    url.push_str(&format!("&collection_search%5B{key}%5D={}", urlencoded(value)));
                }
            }
        }
        let html = self.fetch(&url).await?;
        let collections = parser::parse_collections_page(&html)?;
        Ok((collections, parser::has_next_page(&html), parser::total_pages(&html)))
    }

    /// A collection's /profile page: full metadata plus the collection's
    /// tag links, which the index blurbs don't carry.
    pub async fn fetch_collection_profile(&self, name: &str) -> Result<CollectionSummary, AppError> {
        let url = format!("{BASE_URL}/collections/{}/profile", urlencoded(name));
        let html = self.fetch(&url).await?;
        parser::parse_collection_profile(&html, name)
    }

    /// One page of a collection's approved works
    /// (/collections/{name}/works — standard li.work.blurb markup).
    /// Returns (works, has_next_page, total_pages, total_works), as
    /// search_by_tag.
    pub async fn fetch_collection_works(&self, name: &str, page: u32) -> Result<(Vec<WorkSummary>, bool, u32, Option<u32>), AppError> {
        let url = format!("{BASE_URL}/collections/{}/works?page={page}", urlencoded(name));
        let html = self.fetch(&url).await?;
        let works = parser::parse_work_listings(&html)?;
        Ok((works, parser::has_next_page(&html), parser::total_pages(&html),
            parser::parse_results_total(&html)))
    }

    /// One page of a collection's bookmarked items
    /// (/collections/{name}/bookmarks — li.bookmark blurbs wrapping standard
    /// work blurbs; series/external bookmarks are skipped).
    /// Returns (works, has_next_page, total_pages, total_found).
    pub async fn fetch_collection_bookmarks(&self, name: &str, page: u32) -> Result<(Vec<WorkSummary>, bool, u32, Option<u32>), AppError> {
        let url = format!("{BASE_URL}/collections/{}/bookmarks?page={page}", urlencoded(name));
        let html = self.fetch(&url).await?;
        let works = parser::parse_bookmarked_works(&html)?;
        Ok((works, parser::has_next_page(&html), parser::total_pages(&html),
            parser::parse_results_total(&html)))
    }

    /// Fetch a single work's metadata and all its chapters.
    /// Returns the parsed work plus the usernames visible in the page's
    /// kudos list — the caller checks the signed-in user against them to
    /// learn about kudos left outside the app (website, other devices).
    pub async fn get_work(&self, work_id: u64) -> Result<(WorkSummary, Vec<Chapter>, Vec<String>), AppError> {
        let url = format!("{BASE_URL}/works/{work_id}?view_full_work=true&view_adult=true");
        let html = self.fetch(&url).await?;
        let (mut summary, chapters) = parser::parse_work_page(&html)?;
        summary.id = work_id;
        let kudos_names = parser::parse_kudos_usernames(&html);
        Ok((summary, chapters, kudos_names))
    }

    // -- Inbox operations -----------------------------------------------------

    pub async fn fetch_inbox(&self, username: &str, page: u32) -> Result<InboxPage, AppError> {
        let url = format!("{BASE_URL}/users/{username}/inbox?page={page}");
        let html = self.fetch(&url).await?;
        Ok(parser::parse_inbox(&html))
    }

    // -- Comment operations ---------------------------------------------------

    pub async fn fetch_comments_for_chapter(&self, work_id: u64, chapter_id: u64, page: u32) -> Result<CommentsPage, AppError> {
        if page <= 1 {
            let url = format!("{BASE_URL}/works/{work_id}/chapters/{chapter_id}?show_comments=true&view_adult=true");
            let html = self.fetch(&url).await?;
            Ok(parser::parse_comments(&html))
        } else {
            let url = format!("{BASE_URL}/comments/show_comments?chapter_id={chapter_id}&page={page}");
            let html = self.fetch_ajax(&url).await?;
            Ok(parser::parse_comments(&html))
        }
    }

    pub async fn fetch_comments_for_work(&self, work_id: u64, page: u32) -> Result<CommentsPage, AppError> {
        if page <= 1 {
            let url = format!("{BASE_URL}/works/{work_id}?show_comments=true&view_adult=true");
            let html = self.fetch(&url).await?;
            Ok(parser::parse_comments(&html))
        } else {
            let url = format!("{BASE_URL}/comments/show_comments?work_id={work_id}&page={page}");
            let html = self.fetch_ajax(&url).await?;
            Ok(parser::parse_comments(&html))
        }
    }

    pub async fn fetch_image(&self, url: &str) -> Result<Vec<u8>, AppError> {
        let _active = ActiveRequestGuard::new("GET (image)", url);
        // Every terminal outcome lands in the request log, like page fetches.
        let audit = AuditCtx::new("GET (image)", url, None);

        self.enforce_rate_limit().await;
        let client = self.http();
        let timeout = self.request_timeout();

        // Resolve the full URL for relative paths
        let full_url = if url.starts_with('/') {
            format!("{BASE_URL}{url}")
        } else {
            url.to_string()
        };

        log_info!("image", "Fetching {}", full_url);
        // Image-appropriate headers (override the client's document-navigation
        // defaults): a CDN seeing Accept: text/html on an image URL may serve
        // its HTML viewer/block page instead of the bytes.
        let request = client.get(&full_url)
            .header("Accept", "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5")
            .header("Sec-Fetch-Dest", "image")
            .header("Sec-Fetch-Mode", "no-cors")
            .header("Sec-Fetch-Site", "cross-site");
        let response = match tokio::time::timeout(timeout, request.send()).await {
            Err(_) => {
                log_error!("image", "Timeout connecting to {}", full_url);
                audit.record(0, 0, Some("timeout".to_string()));
                return Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() });
            }
            Ok(Err(e)) => {
                log_error!("image", "Error fetching {}: {}", full_url, e);
                audit.record(0, 0, Some(format!("{e}")));
                return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") });
            }
            Ok(Ok(r)) => r,
        };

        let status = response.status();
        let content_type = response.headers().get("content-type")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        let content_encoding = response.headers().get("content-encoding")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        let content_length = response.headers().get("content-length")
            .and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
        log_info!("image", "HTTP {} type={} encoding={} length={} for {}",
                  status.as_u16(), content_type, content_encoding, content_length, full_url);

        if !status.is_success() {
            let detail = format!("HTTP {status}");
            audit.record(status.as_u16(), 0, Some(detail.clone()));
            return Err(AppError::Http { kind: FailureKind::from_status(status.as_u16(), None), detail });
        }

        let bytes = match tokio::time::timeout(timeout, response.bytes()).await {
            Err(_) => {
                log_error!("image", "Timeout reading body of {}", full_url);
                audit.record(status.as_u16(), 0, Some("body timeout".to_string()));
                // Headers already arrived — the request reached the origin.
                return Err(AppError::Http { kind: FailureKind::ResponseTimeout, detail: "timeout".to_string() });
            }
            Ok(Err(e)) => {
                log_error!("image", "Failed reading body of {}: {}", full_url, e);
                let detail = format!("{e}");
                audit.record(status.as_u16(), 0, Some(detail.clone()));
                return Err(AppError::Http { kind: FailureKind::from_transport(&e), detail });
            }
            Ok(Ok(b)) => b,
        };

        let kind = sniff_image_kind(&bytes);
        log_info!("image", "Downloaded {} bytes ({}) from {}", bytes.len(), kind, full_url);
        if kind == "not-an-image" {
            // The body isn't any known image format — log what the host
            // actually sent so decode failures are diagnosable.
            let snippet: String = String::from_utf8_lossy(&bytes[..bytes.len().min(300)])
                .chars().filter(|c| !c.is_control()).collect();
            log_error!("image", "Body of {} is not a recognized image (type={} encoding={}): {}",
                       full_url, content_type, content_encoding, snippet);
        }
        audit.record(status.as_u16(), bytes.len() as u64, None);
        Ok(bytes.to_vec())
    }

    pub async fn post_reply(&self, parent_comment_id: u64, comment: &str) -> Result<bool, AppError> {
        let endpoint = format!("{BASE_URL}/comments/{parent_comment_id}/comments");
        // Credential-refresh page on failure: the parent comment's thread.
        let form_page = format!("{BASE_URL}/comments/{parent_comment_id}");
        self.post_comment_direct(&endpoint, "comments", &form_page, comment).await
    }

    // -- Bookmark operations -------------------------------------------------

    /// Fetch a page of user bookmarks.
    /// Returns (bookmarks, has_more_pages).
    pub async fn fetch_user_bookmarks(
        &self,
        username: &str,
        page: u32,
    ) -> Result<(Vec<crate::models::BookmarkListing>, bool), AppError> {
        let url = format!("{BASE_URL}/users/{username}/bookmarks?page={page}");
        let html = self.fetch(&url).await?;
        let bookmarks = parser::parse_bookmark_listings(&html)?;
        let has_more = parser::has_next_page(&html);
        Ok((bookmarks, has_more))
    }

    /// Create a bookmark on AO3, mirroring the site's form exactly
    /// (bookmark.html reference): pseud_id, bookmarker_notes, tag_string,
    /// collection_names, private, rec. Posts from cached credentials with
    /// no preparatory GET; refreshes them ONCE (work-page fetch) on a miss
    /// or rejection. Returns the ao3_bookmark_id on success.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_ao3_bookmark(
        &self,
        work_id: u64,
        note: &str,
        tag_string: &str,
        collection_names: &str,
        private: bool,
        rec: bool,
    ) -> Result<Option<u64>, AppError> {
        let endpoint = format!("{BASE_URL}/works/{work_id}/bookmarks");
        let form_page = format!("{BASE_URL}/works/{work_id}?view_adult=true");
        let mut refreshed = false;
        loop {
            let (token, pseud) = (self.cached_csrf_token(), self.cached_pseud_id());
            let (Some(token), Some(pseud)) = (token, pseud) else {
                if refreshed {
                    return Err(AppError::ParseError(
                        "no posting credentials — are you signed in?".to_string()));
                }
                self.fetch(&form_page).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let params = vec![
                ("authenticity_token".to_string(), token),
                ("bookmark[pseud_id]".to_string(), pseud),
                ("bookmark[bookmarker_notes]".to_string(), note.to_string()),
                ("bookmark[tag_string]".to_string(), tag_string.to_string()),
                ("bookmark[collection_names]".to_string(), collection_names.to_string()),
                ("bookmark[private]".to_string(), if private { "1" } else { "0" }.to_string()),
                ("bookmark[rec]".to_string(), if rec { "1" } else { "0" }.to_string()),
                ("commit".to_string(), "Create".to_string()),
            ];
            let body = self.post_form_raw(&endpoint, params).await?;
            // Success redirects to the bookmark's page — the id is in the markup.
            if let Some(id) = extract_bookmark_id_from_response(&body) {
                return Ok(Some(id));
            }
            if !refreshed {
                refreshed = true;
                self.fetch(&form_page).await?;
                continue;
            }
            log_info!("bookmark", "Rejected POST to {endpoint}: {}",
                      body.chars().take(300).collect::<String>());
            return Ok(None);
        }
    }

    /// Delete a bookmark from AO3.
    /// Returns true if the delete appeared successful.
    pub async fn delete_ao3_bookmark(
        &self,
        ao3_bookmark_id: u64,
    ) -> Result<bool, AppError> {
        let url = format!("{BASE_URL}/bookmarks/{ao3_bookmark_id}");
        let params = vec![
            ("_method".to_string(), "delete".to_string()),
        ];
        let body = self.post_form(&url, &params).await?;
        // AO3 typically redirects or shows a page without the bookmark
        Ok(!body.contains("Error") && !body.contains("Sorry, you don't have permission"))
    }

    // -- Subscription operations -----------------------------------------------

    /// Shared page-fetch subscription toggler for works and users: reads the
    /// page's live form (create vs destroy) and submits it only when the
    /// state actually differs — intent-aware, so a retry after an ambiguous
    /// direct POST can never double-toggle. `default_type` fills in when the
    /// form omits subscribable_type. Returns the resulting state and AO3's
    /// subscription record id when subscribed.
    async fn set_subscription_via_page(&self, page_url: &str, subscribe: bool, default_type: &str)
        -> Result<(bool, Option<String>), AppError> {
        let html = self.fetch(page_url).await?;
        let form = parser::parse_work_subscription_form(&html)
            .ok_or_else(|| AppError::ElementNotFound(
                "subscription form — are you signed in?".to_string()))?;
        if form.subscribed == subscribe {
            // Already in the desired state — just harvest the record id.
            return Ok((form.subscribed, sub_id_from_action(&form.action)));
        }
        let action = if form.action.starts_with('/') {
            format!("{BASE_URL}{}", form.action)
        } else {
            form.action.clone()
        };
        let mut params = vec![("authenticity_token".to_string(), form.token.clone())];
        if form.subscribed {
            params.push(("_method".to_string(), "delete".to_string()));
            params.push(("commit".to_string(), "Unsubscribe".to_string()));
        } else {
            params.push(("subscription[subscribable_id]".to_string(), form.subscribable_id.clone()));
            params.push(("subscription[subscribable_type]".to_string(),
                         if form.subscribable_type.is_empty() { default_type.to_string() }
                         else { form.subscribable_type.clone() }));
            params.push(("commit".to_string(), "Subscribe".to_string()));
        }
        let body = self.post_form_raw(&action, params).await?;
        // The POST redirects to a page carrying the form again — read the
        // resulting state (and new record id) from it when possible.
        match parser::parse_work_subscription_form(&body) {
            Some(f) => Ok((f.subscribed, sub_id_from_action(&f.action))),
            None => Ok((subscribe, None)),
        }
    }

    /// Work subscription, page-fetch path (see set_subscription_via_page).
    pub async fn set_work_subscription(&self, work_id: u64, subscribe: bool)
        -> Result<(bool, Option<String>), AppError> {
        let page_url = format!("{BASE_URL}/works/{work_id}?view_adult=true");
        self.set_subscription_via_page(&page_url, subscribe, "Work").await
    }

    /// Shared direct subscribe using the cached CSRF token — one POST, no
    /// page fetch. Ok(Some(id)) is definite success; Ok(None) means no
    /// cached token (caller should use the page-fetch path). Success
    /// redirects to a page whose form is now the destroy variant carrying
    /// the fresh record id.
    async fn subscribe_direct(&self, username: &str, subscribable_id: &str, subscribable_type: &str)
        -> Result<Option<String>, AppError> {
        let Some(token) = self.cached_csrf_token() else { return Ok(None) };
        let url = format!("{BASE_URL}/users/{}/subscriptions", urlencoded(username));
        let params = vec![
            ("authenticity_token".to_string(), token),
            ("subscription[subscribable_id]".to_string(), subscribable_id.to_string()),
            ("subscription[subscribable_type]".to_string(), subscribable_type.to_string()),
            ("commit".to_string(), "Subscribe".to_string()),
        ];
        let body = self.post_form_raw(&url, params).await?;
        Ok(parser::parse_work_subscription_form(&body)
            .filter(|f| f.subscribed)
            .and_then(|f| sub_id_from_action(&f.action)))
    }

    /// Direct work subscribe (see subscribe_direct).
    pub async fn subscribe_work_direct(&self, username: &str, work_id: u64)
        -> Result<Option<String>, AppError> {
        self.subscribe_direct(username, &work_id.to_string(), "Work").await
    }

    /// Direct unsubscribe using a stored record id + cached CSRF token —
    /// one POST, no page fetch. Ok(true) on apparent success; Ok(false)
    /// when there's no token or the archive rejected it (stale id).
    pub async fn unsubscribe_work_direct(&self, username: &str, ao3_sub_id: &str)
        -> Result<bool, AppError> {
        let Some(token) = self.cached_csrf_token() else { return Ok(false) };
        let url = format!("{BASE_URL}/users/{}/subscriptions/{}", urlencoded(username), ao3_sub_id);
        let params = vec![
            ("authenticity_token".to_string(), token),
            ("_method".to_string(), "delete".to_string()),
            ("commit".to_string(), "Unsubscribe".to_string()),
        ];
        let body = self.post_form_raw(&url, params).await?;
        Ok(!body.contains("Error 404") && !body.contains("Sorry, you don't have permission"))
    }

    /// A user's full profile page — identity, pseuds, counts, bio, and
    /// (when signed in) live subscribe/block/mute state. One request; the
    /// page fetch also refreshes the cached CSRF token, so a follow-up
    /// direct POST from the profile screen never needs a second fetch.
    pub async fn fetch_user_profile_full(&self, username: &str)
        -> Result<crate::models::UserProfile, AppError> {
        let html = self.fetch(&format!("{BASE_URL}/users/{}/profile", urlencoded(username))).await?;
        parser::parse_user_profile(&html)
    }

    /// User subscription, page-fetch path (see set_subscription_via_page).
    pub async fn set_user_subscription(&self, target: &str, subscribe: bool)
        -> Result<(bool, Option<String>), AppError> {
        let page_url = format!("{BASE_URL}/users/{}/profile", urlencoded(target));
        self.set_subscription_via_page(&page_url, subscribe, "User").await
    }

    /// Direct user subscribe via the target's numeric id (see subscribe_direct).
    pub async fn subscribe_user_direct(&self, me: &str, target_numeric_id: &str)
        -> Result<Option<String>, AppError> {
        self.subscribe_direct(me, target_numeric_id, "User").await
    }

    /// Set block or mute state for another user. `kind` is "blocked" or
    /// "muted". Prefers a direct POST with the cached CSRF token; falls
    /// back to a profile fetch when the token or (for undo) the record id
    /// is missing — that fetch also short-circuits when AO3 already has
    /// the desired state. Returns (state, AO3 record id when on).
    pub async fn set_user_moderation(&self, me: &str, target: &str, kind: &str,
                                     on: bool, record_id: Option<&str>)
        -> Result<(bool, Option<String>), AppError> {
        let (param, confirm_tail) = match kind {
            "blocked" => ("blocked_id", "confirm_unblock"),
            "muted" => ("muted_id", "confirm_unmute"),
            other => return Err(AppError::ParseError(format!("unknown moderation kind {other}"))),
        };

        let mut token = self.cached_csrf_token();
        let mut known_record = record_id.map(str::to_string);
        let mut verified_state: Option<(bool, Option<String>)> = None;
        if token.is_none() || (!on && known_record.is_none()) {
            let profile = self.fetch_user_profile_full(target).await?;
            token = self.cached_csrf_token();
            let (state, rid) = if kind == "blocked" {
                (profile.blocked, profile.block_ao3_id)
            } else {
                (profile.muted, profile.mute_ao3_id)
            };
            if state == on {
                return Ok((state, rid));
            }
            if known_record.is_none() { known_record = rid.clone(); }
            verified_state = Some((state, rid));
        }
        let Some(token) = token else {
            return Err(AppError::ElementNotFound(
                "CSRF token — are you signed in?".to_string()));
        };

        let me_enc = urlencoded(me);
        let (url, params) = if on {
            (format!("{BASE_URL}/users/{me_enc}/{kind}/users"),
             vec![
                 ("authenticity_token".to_string(), token),
                 (param.to_string(), target.to_string()),
             ])
        } else {
            let Some(rid) = known_record.clone() else {
                return Err(AppError::ElementNotFound(
                    format!("{kind} record id for {target}")));
            };
            (format!("{BASE_URL}/users/{me_enc}/{kind}/users/{rid}"),
             vec![
                 ("authenticity_token".to_string(), token),
                 ("_method".to_string(), "delete".to_string()),
             ])
        };

        let body = self.post_form_raw(&url, params).await?;
        if body.contains("The change you wanted was rejected")
            || body.contains("Sorry, you don't have permission") {
            return Err(AppError::NetworkError(format!("{kind} POST rejected")));
        }

        // The POST redirects to the blocked/muted index — read the result
        // straight off it. An absent entry after an undo is success; an
        // absent entry after a create is ambiguous, so verify via the
        // profile unless this call already fetched it.
        let list = parser::parse_moderation_list(&body, confirm_tail);
        let entry = list.iter().find(|(n, _)| n.eq_ignore_ascii_case(target));
        match (on, entry) {
            (true, Some((_, rid))) => Ok((true, rid.clone())),
            (false, None) => Ok((false, None)),
            (false, Some(_)) => Err(AppError::NetworkError(
                format!("{target} still present after un-{kind} POST"))),
            (true, None) => {
                if verified_state.is_some() {
                    // Profile said "not yet" moments ago and the POST wasn't
                    // rejected — treat the redirect as success without a
                    // record id (the next profile fetch will backfill it).
                    return Ok((true, None));
                }
                let profile = self.fetch_user_profile_full(target).await?;
                let (state, rid) = if kind == "blocked" {
                    (profile.blocked, profile.block_ao3_id)
                } else {
                    (profile.muted, profile.mute_ao3_id)
                };
                if state == on { Ok((state, rid)) }
                else { Err(AppError::NetworkError(format!("{kind} did not stick for {target}"))) }
            }
        }
    }

    /// Fetch a page of user subscriptions.
    /// Returns (subscriptions, has_more_pages).
    pub async fn fetch_subscriptions(
        &self,
        username: &str,
        page: u32,
    ) -> Result<(Vec<crate::models::Subscription>, bool), AppError> {
        let url = format!("{BASE_URL}/users/{username}/subscriptions?page={page}");
        let html = self.fetch(&url).await?;
        let subs = parser::parse_subscriptions_page(&html)?;
        let has_more = parser::has_next_page(&html);
        Ok((subs, has_more))
    }

    /// Fetch one page of an author's works.
    /// Returns (works, has_next_page, total_pages).
    /// One page of an author's works. With a pseud, fetches the
    /// pseud-scoped list (/users/{user}/pseuds/{pseud}/works) — bylines
    /// like "saltedriceball (tealvneu)" are pseud saltedriceball of user
    /// tealvneu, and the works shown should match the byline clicked.
    pub async fn fetch_author_works(
        &self,
        username: &str,
        pseud: Option<&str>,
        page: u32,
    ) -> Result<(Vec<WorkSummary>, bool, u32), AppError> {
        let base = match pseud.filter(|p| !p.is_empty() && !p.eq_ignore_ascii_case(username)) {
            Some(p) => format!("{BASE_URL}/users/{}/pseuds/{}/works",
                               urlencoded(username), urlencoded(p)),
            None => format!("{BASE_URL}/users/{}/works", urlencoded(username)),
        };
        let url = format!("{base}?page={page}");
        log_info!("http"," Starting: {url}");
        let start = std::time::Instant::now();
        match self.fetch(&url).await {
            Ok(html) => {
                log_info!("http"," Success in {:?}: {} bytes from {url}", start.elapsed(), html.len());
                let works = parser::parse_work_listings(&html)?;
                let has_next = parser::has_next_page(&html);
                let total = parser::total_pages(&html);
                Ok((works, has_next, total))
            }
            Err(e) => {
                log_info!("http"," Failed in {:?}: {e} for {url}", start.elapsed());
                Err(e)
            }
        }
    }

    /// Fetch one page of a series' works as full blurbs (series pages use the
    /// same li.work.blurb markup as author pages).
    /// Returns (works, has_next_page, total_pages).
    pub async fn fetch_series_works_page(
        &self,
        series_id: u64,
        page: u32,
    ) -> Result<(Vec<WorkSummary>, bool, u32), AppError> {
        let url = format!("{BASE_URL}/series/{series_id}?page={page}");
        let html = self.fetch(&url).await?;
        let works = parser::parse_work_listings(&html)?;
        let has_next = parser::has_next_page(&html);
        let total = parser::total_pages(&html);
        Ok((works, has_next, total))
    }
}
