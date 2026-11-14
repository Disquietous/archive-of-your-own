use super::*;

#[derive(Debug, Clone, uniffi::Record)]
pub struct ULogEntry {
    pub id: i64,
    pub timestamp: String,
    pub level: String,
    pub tag: String,
    pub message: String,
}

/// Debug-log viewer filter. Each field narrows when set: `level` and
/// `tag` match exactly; `text` matches case-insensitively against any
/// column (message, tag, level, timestamp, id).
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ULogQuery {
    pub level: Option<String>,
    pub tag: Option<String>,
    pub text: Option<String>,
}

/// One recorded HTTP request for the request-audit UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct URequestLogEntry {
    pub id: i64,
    pub started_ms: i64,
    pub method: String,
    pub url: String,
    pub status: u16,
    pub duration_ms: i64,
    pub request_bytes: i64,
    pub response_bytes: i64,
    pub error: Option<String>,
    pub payload: Option<String>,
    /// Tor stream that carried the request — circuit id, exit/guard
    /// fingerprints, connect time, and TLS first-byte offsets (or
    /// "never"). None off Tor.
    pub transport: Option<String>,
    /// The source the request was sent for ("ao3").
    pub source: String,
}

/// A series as a listing shows it (a series bookmark blurb).
#[derive(Debug, Clone, uniffi::Record)]
pub struct USeriesSummary {
    /// Row id.
    pub id: u64,
    pub source: String,
    /// The series' id at its source (AO3 series number).
    pub external_id: String,
    /// Canonical page URL at the source; "" when it has none.
    pub url: String,
    pub name: String,
    pub authors: Vec<String>,
    pub summary: String,
    pub word_count: u64,
    pub work_count: u32,
    pub complete: bool,
    pub date_updated: String,
    pub fetched_at: String,
}

impl From<SeriesSummary> for USeriesSummary {
    fn from(s: SeriesSummary) -> Self {
        USeriesSummary {
            id: s.id, source: s.source, external_id: s.external_id, url: s.url,
            name: s.name, authors: s.authors, summary: s.summary,
            word_count: s.word_count, work_count: s.work_count, complete: s.complete,
            date_updated: s.date_updated, fetched_at: s.fetched_at,
        }
    }
}

/// The full AO3 bookmark object for one target (work or series).
#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmarkDetails {
    /// "work" or "series".
    pub bookmark_type: String,
    /// The work id or series id, per `bookmark_type`.
    pub target_id: u64,
    pub note: String,
    pub tag_string: String,
    pub collection_names: String,
    pub private: bool,
    pub rec: bool,
    pub sync_to_ao3: bool,
    pub ao3_bookmark_id: Option<u64>,
}

/// A request currently in flight — shown live at the top of the request log.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UActiveRequest {
    pub started_ms: i64,
    pub method: String,
    pub url: String,
    pub elapsed_ms: i64,
    /// The timeout governing this request (route override or global),
    /// so progress UIs can show elapsed time against it. 0 = unknown.
    pub timeout_secs: u32,
    /// The operation this request belongs to — stable across the
    /// operation's retries and matching the id on every CoreEvent it
    /// emits, so a view holding a `new_operation_id` can pick out exactly
    /// its own requests. None for requests outside the recovery engine.
    pub op_id: Option<u64>,
}

// UniFFI-compatible record types (flat, no generics)

#[derive(Debug, Clone, uniffi::Record)]
pub struct USeriesMembership {
    /// Series row id.
    pub series_id: u64,
    pub name: String,
    /// 1-based position within the series; 0 = unknown.
    pub part: u32,
    /// The adjacent works' ids at the source (AO3 work numbers) — they are
    /// usually not in the library. Resolve through `sibling_work` before
    /// opening.
    pub prev_work_external_id: Option<String>,
    pub next_work_external_id: Option<String>,
}

impl From<SeriesMembership> for USeriesMembership {
    fn from(s: SeriesMembership) -> Self {
        USeriesMembership {
            series_id: s.series_id,
            name: s.name,
            part: s.part,
            prev_work_external_id: s.prev_work_external_id,
            next_work_external_id: s.next_work_external_id,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkSummary {
    /// Row id. Every id the bridge takes for a work is this.
    pub id: u64,
    pub source: String,
    /// The work's id at its source (AO3 work number). Display only.
    pub external_id: String,
    /// Canonical page URL at the source; "" when it has none. The only
    /// thing "open on site" uses.
    pub url: String,
    pub title: String,
    pub authors: Vec<String>,
    /// The users row behind each byline, parallel to `authors` (0 when
    /// not linked yet) — the identity the UI opens an author with.
    pub author_ids: Vec<u64>,
    pub fandoms: Vec<String>,
    pub rating: String,
    pub warnings: Vec<String>,
    pub categories: Vec<String>,
    pub relationships: Vec<String>,
    pub characters: Vec<String>,
    pub tags: Vec<String>,
    pub summary: String,
    /// Stats are None when the source does not report them — absent, never
    /// zero. AO3 always reports them.
    pub word_count: Option<u64>,
    pub chapter_count: u32,
    pub total_chapters: i32,
    pub kudos: Option<u32>,
    pub hits: Option<u64>,
    pub bookmarks_count: Option<u32>,
    pub comments: Option<u32>,
    pub date_published: String,
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
    /// The work's status as its source words it ("Ongoing", "Complete",
    /// "Hiatus"); "" when the source states none. Display text.
    pub status: String,
    pub series: Vec<USeriesMembership>,
    /// When this summary last arrived from AO3 (UTC "YYYY-MM-DD HH:MM:SS",
    /// "" = unknown). Display metadata only — never a refresh trigger.
    pub fetched_at: String,
}

impl From<WorkSummary> for UWorkSummary {
    fn from(w: WorkSummary) -> Self {
        UWorkSummary {
            id: w.id,
            source: w.source,
            external_id: w.external_id,
            url: w.url,
            title: w.title,
            authors: w.authors,
            author_ids: w.author_ids.iter().map(|id| (*id).max(0) as u64).collect(),
            fandoms: w.fandoms,
            rating: format!("{:?}", w.rating),
            warnings: w.warnings.iter().map(|w| format!("{:?}", w)).collect(),
            categories: w.categories,
            relationships: w.relationships,
            characters: w.characters,
            tags: w.tags,
            summary: w.summary,
            word_count: w.word_count,
            chapter_count: w.chapter_count,
            total_chapters: w.total_chapters.map_or(-1, |t| t as i32),
            kudos: w.kudos,
            hits: w.hits,
            bookmarks_count: w.bookmarks,
            comments: w.comments,
            date_published: w.date_published,
            date_updated: w.date_updated,
            language: w.language,
            complete: w.complete,
            status: w.status,
            series: w.series.into_iter().map(USeriesMembership::from).collect(),
            fetched_at: w.fetched_at,
        }
    }
}

/// One collection blurb from the /collections index.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCollection {
    pub source: String,
    /// The collection's id at its source: the URL slug, the path segment
    /// in /collections/{name}. Collections cross the bridge by this.
    pub name: String,
    /// Canonical page URL at the source.
    pub url: String,
    pub title: String,
    pub summary: String,
    pub is_open: bool,
    pub is_moderated: bool,
    pub is_anonymous: bool,
    pub work_count: u32,
    pub bookmarked_count: u32,
    pub maintainers: Vec<String>,
    /// Tag names on the collection; populated once the /profile page has
    /// been fetched and cached.
    pub tags: Vec<String>,
    /// Challenge type ("Gift Exchange Challenge", "Prompt Meme Challenge");
    /// "" for a plain collection.
    pub collection_type: String,
}

impl From<CollectionSummary> for UCollection {
    fn from(c: CollectionSummary) -> Self {
        UCollection {
            source: c.source,
            name: c.name,
            url: c.url,
            title: c.title,
            summary: c.summary,
            is_open: c.is_open,
            is_moderated: c.is_moderated,
            is_anonymous: c.is_anonymous,
            work_count: c.work_count,
            bookmarked_count: c.bookmarked_count,
            maintainers: c.maintainers,
            tags: c.tags,
            collection_type: c.collection_type,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCollectionsPage {
    pub collections: Vec<UCollection>,
    pub has_next_page: bool,
    /// Highest page number shown in the pagination bar (1 = no pagination).
    pub total_pages: u32,
}

/// The collections index's sort/filter criteria, mirroring AO3's
/// collection_search[...] form. Blank fields mean "don't filter" / AO3's
/// default, so a default record is the plain index. The same record drives
/// the library-scoped search over cached collections.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct UCollectionSearchCriteria {
    /// Substring title filter.
    pub title: String,
    /// Comma-separated tag names (AO3 allows up to 5).
    pub tag: String,
    /// "true", "false", or "" (either).
    pub multifandom: String,
    /// "true", "false", or "" (either).
    pub closed: String,
    /// "true", "false", or "" (either).
    pub moderated: String,
    /// "GiftExchange", "PromptMeme", "no_challenge", or "" (any).
    pub challenge_type: String,
    /// "created_at" (AO3 default), "title.keyword", "bookmarked_items_count",
    /// or "works_count".
    pub sort_column: String,
    /// "asc" or "desc" (AO3 defaults to desc).
    pub sort_direction: String,
}

impl From<UCollectionSearchCriteria> for CollectionSearchCriteria {
    fn from(c: UCollectionSearchCriteria) -> Self {
        CollectionSearchCriteria {
            title: c.title,
            tag: c.tag,
            multifandom: c.multifandom,
            closed: c.closed,
            moderated: c.moderated,
            challenge_type: c.challenge_type,
            sort_column: c.sort_column,
            sort_direction: c.sort_direction,
        }
    }
}

/// AO3's /bookmarks/search criteria, mirroring the bookmark_search[...]
/// form. Blank fields mean "don't filter", so a default record is an
/// unfiltered search. The same record drives the library-scoped search
/// over cached bookmarks — there, language carries the display name
/// ("English") instead of AO3's code.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct UBookmarkSearchCriteria {
    /// Any field on the work.
    pub bookmarkable_query: String,
    /// Comma-separated work tag names.
    pub other_tag_names: String,
    /// "Work", "Series", "External Work", or "" (any).
    pub bookmarkable_type: String,
    /// AO3 numeric range syntax.
    pub word_count: String,
    /// Language value ("en") for AO3 search; display name for library search.
    pub language_id: String,
    /// Work's Date Updated expression.
    pub bookmarkable_date: String,
    /// Any field on the bookmark itself.
    pub bookmark_query: String,
    /// Comma-separated bookmarker's tag names.
    pub other_bookmark_tag_names: String,
    /// Bookmarker username filter.
    pub bookmarker: String,
    /// Text filter on the bookmarker's notes.
    pub bookmark_notes: String,
    /// Recs only.
    pub rec: bool,
    /// Bookmarks with notes only.
    pub with_notes: bool,
    /// Date Bookmarked expression.
    pub date: String,
    /// "" (Best Match), "created_at", "bookmarkable_date", or "word_count".
    pub sort_column: String,
}

impl From<UBookmarkSearchCriteria> for BookmarkSearchCriteria {
    fn from(c: UBookmarkSearchCriteria) -> Self {
        BookmarkSearchCriteria {
            bookmarkable_query: c.bookmarkable_query,
            other_tag_names: c.other_tag_names,
            bookmarkable_type: c.bookmarkable_type,
            word_count: c.word_count,
            language_id: c.language_id,
            bookmarkable_date: c.bookmarkable_date,
            bookmark_query: c.bookmark_query,
            other_bookmark_tag_names: c.other_bookmark_tag_names,
            bookmarker: c.bookmarker,
            bookmark_notes: c.bookmark_notes,
            rec: c.rec,
            with_notes: c.with_notes,
            date: c.date,
            sort_column: c.sort_column,
        }
    }
}

/// One bookmark search hit: the bookmark's own fields plus the bookmarked
/// item's blurb — exactly one of `work` / `series` is set, per
/// `bookmark_type`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmarkHit {
    /// Local bookmark row id; 0 for a remote hit that was not cached.
    pub id: i64,
    /// "work" or "series".
    pub bookmark_type: String,
    /// The work id or series id, per `bookmark_type`.
    pub target_id: u64,
    /// Username the bookmark is attributed to (the library search reports
    /// the lowercased account key).
    pub bookmarker: String,
    pub note: String,
    /// The bookmarker's own tags.
    pub tags: Vec<String>,
    pub rec: bool,
    /// AO3's blurb date for remote hits ("10 Aug 2026"); "YYYY-MM-DD" for
    /// library hits.
    pub date_bookmarked: String,
    /// True when `work` is the synthetic stub for an unrevealed "Mystery
    /// Work" (a bookmark of a work still hidden in a challenge collection).
    pub mystery: bool,
    /// The unrevealed collection's URL name and display title ("Part of
    /// <title>" in the blurb); "" unless mystery.
    pub mystery_collection_name: String,
    pub mystery_collection_title: String,
    pub work: Option<UWorkSummary>,
    pub series: Option<USeriesSummary>,
}

impl From<BookmarkHit> for UBookmarkHit {
    fn from(h: BookmarkHit) -> Self {
        UBookmarkHit {
            id: h.id,
            bookmark_type: h.target.kind().to_string(),
            target_id: h.target.id(),
            bookmarker: h.bookmarker,
            note: h.note,
            tags: h.tags,
            rec: h.rec,
            date_bookmarked: h.date_bookmarked,
            mystery: h.mystery,
            mystery_collection_name: h.mystery_collection_name,
            mystery_collection_title: h.mystery_collection_title,
            work: h.work.map(UWorkSummary::from),
            series: h.series.map(USeriesSummary::from),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UPagedBookmarks {
    pub bookmarks: Vec<UBookmarkHit>,
    pub has_next_page: bool,
    /// Highest page number shown in the pagination bar (1 = no pagination).
    pub total_pages: u32,
    /// The listing's own total result count; None = unknown, never zero.
    pub total_found: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UPagedWorks {
    pub works: Vec<UWorkSummary>,
    pub has_next_page: bool,
    /// Highest page number shown in the listing's pagination bar (1 = no pagination).
    pub total_pages: u32,
    /// The listing's own total result count ("834 Found" / "… of 834 Works"),
    /// when the page carries one. None = unknown, never zero.
    pub total_works: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UChapter {
    pub chapter_id: i64,
    pub number: u32,
    pub title: String,
    pub content_json: String,
    pub notes_before: String,
    pub notes_after: String,
}

impl From<Chapter> for UChapter {
    fn from(c: Chapter) -> Self {
        UChapter {
            chapter_id: c.id.map(|id| id as i64).unwrap_or(-1),
            number: c.number,
            title: c.title.unwrap_or_default(),
            content_json: serde_json::to_string(&c.content).unwrap_or_default(),
            notes_before: c.notes_before.unwrap_or_default(),
            notes_after: c.notes_after.unwrap_or_default(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UReadingProgress {
    pub work_id: u64,
    /// 1-based chapter number the reader last had open.
    pub chapter: u32,
    /// Character offset (into the chapter's plain text) of the first line
    /// visible when the reader left — not a scroll fraction, so it survives
    /// font, size, and layout changes.
    pub position: u32,
    /// Character count of that chapter's cached text (0 when the chapter
    /// isn't cached) — divide `position` by this for a fraction.
    pub chapter_len: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ULastRead {
    pub work_id: u64,
    /// SQLite UTC "YYYY-MM-DD HH:MM:SS" — lexicographically sortable.
    pub last_read_dt: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UHistoryEntry {
    pub work_id: u64,
    pub accessed_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFormOption {
    pub value: String,
    pub label: String,
    pub selected: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFormField {
    pub name: String,
    pub label: String,
    pub field_type: String,
    pub placeholder: String,
    pub options: Vec<UFormOption>,
}

impl From<FormField> for UFormField {
    fn from(f: FormField) -> Self {
        let (field_type, placeholder, options) = match f.field_type {
            FormFieldType::Text { placeholder } => ("text".to_string(), placeholder, Vec::new()),
            FormFieldType::Select { options } => ("select".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Checkboxes { options } => ("checkboxes".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Radio { options } => ("radio".to_string(), String::new(),
                options.into_iter().map(|o| UFormOption { value: o.value, label: o.label, selected: o.selected }).collect()),
            FormFieldType::Hidden { value } => ("hidden".to_string(), value, Vec::new()),
        };
        UFormField { name: f.name, label: f.label, field_type, placeholder, options }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
#[derive(serde::Serialize)]
pub struct CommentJson {
    pub id: u64,
    pub author_id: String,
    pub author_name: String,
    pub author_profile_url: String,
    pub author_avatar_url: String,
    pub posted_at: String,
    pub content_json: String,
    pub replies: Vec<CommentJson>,
    /// Posted without an AO3 account (byline carries "(Guest)").
    pub is_guest: bool,
    /// "on Chapter N" on whole-work comment pages; empty otherwise.
    pub chapter_label: String,
    /// AO3's message for a bodiless comment (deleted/hidden); empty otherwise.
    pub notice: String,
    /// Stars on a review from a rated source; None for a plain comment.
    pub rating: Option<u8>,
    /// Replies cut off behind AO3's "N more comments in this thread" link.
    pub more_replies: u32,
}

impl From<Comment> for CommentJson {
    fn from(c: Comment) -> Self {
        CommentJson {
            is_guest: c.author.profile_url.is_none() && c.author.id.starts_with("guest:"),
            chapter_label: c.chapter_label.unwrap_or_default(),
            notice: c.notice.unwrap_or_default(),
            more_replies: c.more_replies,
            rating: c.rating,
            id: c.id,
            author_id: c.author.id,
            author_name: c.author.username,
            author_profile_url: c.author.profile_url.unwrap_or_default(),
            author_avatar_url: c.author.avatar_url.unwrap_or_default(),
            posted_at: c.posted_at,
            content_json: serde_json::to_string(&c.content).unwrap_or_default(),
            replies: c.replies.into_iter().map(CommentJson::from).collect(),
        }
    }
}

/// The outcome of posting a comment or reply. `posted` false = the
/// archive rejected it. When posted, `comment_json` is the new comment as
/// AO3 rendered it (CommentJson) — empty when it couldn't be located on the
/// page AO3 redirected to, in which case the caller reloads.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UPostResult {
    pub posted: bool,
    pub comment_json: String,
}

/// An unposted comment draft for one composer.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCommentDraft {
    pub parent_comment_id: u64,
    pub body: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCommentsPage {
    pub comments_json: String,
    pub current_page: u32,
    pub total_pages: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USearchParams {
    pub query: String,
    pub title: String,
    pub creators: String,
    pub fandom_names: String,
    pub relationship_names: String,
    pub character_names: String,
    pub freeform_names: String,
    pub word_count: String,
    pub hits: String,
    pub kudos_count: String,
    pub comments_count: String,
    pub bookmarks_count: String,
    pub revised_at: String,
    pub sort_column: String,
    pub sort_direction: String,
    pub rating_id: i32,
    pub warning_ids: Vec<u32>,
    pub category_ids: Vec<u32>,
    pub complete: String,
    pub crossover: String,
    pub single_chapter: bool,
    pub language_id: String,
}

impl From<USearchParams> for SearchParams {
    fn from(u: USearchParams) -> Self {
        SearchParams {
            query: u.query,
            title: u.title,
            creators: u.creators,
            fandom_names: u.fandom_names,
            relationship_names: u.relationship_names,
            character_names: u.character_names,
            freeform_names: u.freeform_names,
            word_count: u.word_count,
            hits: u.hits,
            kudos_count: u.kudos_count,
            comments_count: u.comments_count,
            bookmarks_count: u.bookmarks_count,
            sort_column: u.sort_column,
            sort_direction: u.sort_direction,
            rating_id: if u.rating_id >= 0 { Some(u.rating_id as u32) } else { None },
            warning_ids: u.warning_ids,
            category_ids: u.category_ids,
            complete: u.complete,
            crossover: u.crossover,
            single_chapter: u.single_chapter,
            language_id: u.language_id,
            revised_at: u.revised_at,
        }
    }
}

/// The works-search form's criteria for a library-scoped search, mirroring
/// AO3's fields. Select/checkbox choices are the scraped form's option
/// labels (never numeric ids) — the UI owns the value→label translation,
/// the core owns the matching. Blank fields match everything.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ULibrarySearchCriteria {
    pub query: String,
    pub title: String,
    pub creators: String,
    pub revised_at: String,
    pub complete: String,
    pub crossover: String,
    pub single_chapter: bool,
    /// Library-only: every chapter of a work with an explicit total is
    /// stored locally.
    pub fully_downloaded: bool,
    pub word_count: String,
    pub language: String,
    pub fandom_names: String,
    pub character_names: String,
    pub relationship_names: String,
    pub freeform_names: String,
    pub ratings: Vec<String>,
    pub warnings: Vec<String>,
    pub categories: Vec<String>,
    pub hits: String,
    pub kudos_count: String,
    pub comments_count: String,
    pub bookmarks_count: String,
    pub sort_column: String,
    pub sort_direction: String,
}

impl From<ULibrarySearchCriteria> for LocalSearchCriteria {
    fn from(c: ULibrarySearchCriteria) -> Self {
        LocalSearchCriteria {
            query: c.query,
            title: c.title,
            creators: c.creators,
            revised_at: c.revised_at,
            complete: c.complete,
            crossover: c.crossover,
            single_chapter: c.single_chapter,
            fully_downloaded: c.fully_downloaded,
            word_count: c.word_count,
            language: c.language,
            fandom_names: c.fandom_names,
            character_names: c.character_names,
            relationship_names: c.relationship_names,
            freeform_names: c.freeform_names,
            ratings: c.ratings,
            warnings: c.warnings,
            categories: c.categories,
            hits: c.hits,
            kudos_count: c.kudos_count,
            comments_count: c.comments_count,
            bookmarks_count: c.bookmarks_count,
            sort_column: c.sort_column,
            sort_direction: c.sort_direction,
            extra: Vec::new(),
        }
    }
}

/// One executed library works search held by the core: pass `handle` to
/// `get_library_search_page` to hydrate slices, and to
/// `drop_library_search` when the view is done.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ULibrarySearch {
    pub handle: u64,
    pub total: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USavedSearch {
    pub id: i64,
    pub name: String,
    pub params_json: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UReadingList {
    pub id: i64,
    pub name: String,
    pub work_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCircuitHop {
    pub role: String,
    pub address: String,
    pub country: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmark {
    /// Local bookmark row id.
    pub id: i64,
    /// "work" or "series".
    pub bookmark_type: String,
    /// The work id or series id, per `bookmark_type`.
    pub target_id: u64,
    pub note: String,
    pub sync_to_ao3: bool,
    pub ao3_bookmark_id: i64, // -1 if none
}

/// One library-scoped tag search hit: the tag and its kind ("fandom",
/// "character", "relationship", "freeform", "creator").
#[derive(Debug, Clone, uniffi::Record)]
pub struct UTagHit {
    pub name: String,
    pub tag_type: String,
}

/// One row of the per-route timeout catalog: the request shape (template is
/// the non-dynamic URL form shown to the user) and its current override —
/// None means the route follows the global request timeout.
#[derive(Debug, Clone, uniffi::Record)]
pub struct URouteTimeout {
    pub key: String,
    pub template: String,
    pub label: String,
    pub timeout_secs: Option<u64>,
}

/// One of the signed-in account's AO3 subscriptions — an AO3 record, so
/// `id` is AO3's identifier for the target (username, work number, or
/// series number), never a row id. Open a work or series subscription
/// through `open_link` on its `url`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct USubscription {
    pub sub_type: String,
    pub id: String,
    pub name: String,
    /// AO3's subscription record id (from unsubscribe form actions) —
    /// stored so unsubscribing can POST directly without a page fetch.
    pub ao3_id: Option<String>,
    /// The target's page on AO3.
    pub url: String,
}

/// A follow: a target (author / work / series / fandom) the What's New
/// check watches (fandoms are not checked). Library data, not account data.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UFollow {
    pub kind: String,
    /// author/work/series: the row id (users, works, series); fandom: tag name.
    pub target_id: String,
    pub name: String,
    /// The target's source ("ao3", "scribblehub"); "" for fandoms.
    pub source: String,
    pub added_at: String,
    /// When this follow's own What's New check last ran, whatever its
    /// outcome. None = never.
    pub last_checked_at: Option<String>,
    /// Not-found counter: 0 = last fetch succeeded, n > 0 = n consecutive
    /// 404s, -1 = excluded from What's New checks.
    pub status: i32,
}

impl From<crate::storage::FollowRow> for UFollow {
    fn from(r: crate::storage::FollowRow) -> Self {
        UFollow {
            kind: r.target.kind().to_string(),
            target_id: r.bridge_id,
            name: r.name,
            source: String::new(),
            added_at: r.added_at,
            last_checked_at: r.last_checked_at,
            status: r.status,
        }
    }
}

/// A target's bell state. `subscribed` is the signed-in account's AO3
/// subscription (always false when signed out).
#[derive(Debug, Clone, uniffi::Record)]
pub struct UFollowState {
    pub followed: bool,
    pub subscribed: bool,
}

/// What a target's bell offers: the Followed and Subscribed items, each
/// by its source's gate.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UFollowGates {
    pub follow: crate::source::Gate,
    pub subscribe: crate::source::Gate,
}

/// What a confirmed bell-menu change did.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UFollowChange {
    pub followed: bool,
    pub subscribed: bool,
    /// An AO3 subscribe/unsubscribe request was made and succeeded.
    pub subscription_changed: bool,
    pub follow_added: bool,
    pub follow_removed: bool,
}

impl From<crate::models::Subscription> for USubscription {
    fn from(s: crate::models::Subscription) -> Self {
        USubscription {
            sub_type: s.sub_type,
            id: s.id,
            name: s.name,
            ao3_id: s.ao3_id,
            url: s.url,
        }
    }
}

/// A person at a source, as the UI sees them: identity plus the app's
/// global attributes, each present only when the source reports it. No
/// source-specific property name ever crosses here (`user_fields`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct UUser {
    /// Row id — the one identity the UI holds for a person.
    pub id: u64,
    pub source: String,
    /// The person's key at the source (AO3 username, ScribbleHub profile id).
    pub source_id: String,
    pub username: String,
    pub profile_url: Option<String>,
    pub avatar_url: Option<String>,
    /// Self-description as a serialized ContentBlock tree.
    pub info_json: Option<String>,
    pub joined: Option<String>,
    pub location: Option<String>,
    pub birthday: Option<String>,
    /// Published things: AO3 works, ScribbleHub series.
    pub works: Option<u64>,
    pub series: Option<u64>,
    pub bookmarks: Option<u64>,
    pub collections: Option<u64>,
    pub gifts: Option<u64>,
    pub followers: Option<u64>,
    pub following: Option<u64>,
    pub readers: Option<u64>,
    pub words: Option<u64>,
    pub views: Option<u64>,
    pub reviews: Option<u64>,
    pub comments: Option<u64>,
    pub last_active: Option<String>,
    /// The signed-in viewer's relation to this user (AO3 account features).
    pub blocked: bool,
    pub muted: bool,
    pub subscribed: bool,
    /// Other names the account posts under (AO3 pseuds).
    pub pseuds: Vec<String>,
    /// The source's numeric id when it differs from the key.
    pub numeric_id: Option<String>,
    /// When the profile page was last fetched; None when never.
    pub profile_fetched_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl UUser {
    pub(crate) fn from_record(u: &crate::storage::UserRecord, subscribed: bool) -> UUser {
        use crate::user_fields::UserField as F;
        let text = |f: F| u.field(f).map(str::to_string);
        let num = |f: F| u.field(f).and_then(|v| v.replace(',', "").parse::<f64>().ok()).map(|n| n.round() as u64);
        let flag = |f: F| u.field(f).is_some_and(|v| v != "0");
        UUser {
            id: u.id as u64,
            source: u.source.clone(),
            source_id: u.source_id.clone(),
            username: u.username.clone(),
            profile_url: text(F::ProfileUrl),
            avatar_url: text(F::AvatarUrl),
            info_json: text(F::Info),
            joined: text(F::Joined),
            location: text(F::Location),
            birthday: text(F::Birthday),
            works: num(F::Works),
            series: num(F::Series),
            bookmarks: num(F::Bookmarks),
            collections: num(F::Collections),
            gifts: num(F::Gifts),
            followers: num(F::Followers),
            following: num(F::Following),
            readers: num(F::Readers),
            words: num(F::Words),
            views: num(F::Views),
            reviews: num(F::Reviews),
            comments: num(F::Comments),
            last_active: text(F::LastActive),
            blocked: flag(F::Blocked),
            muted: flag(F::Muted),
            subscribed,
            pseuds: u.field(F::Pseuds).and_then(|j| serde_json::from_str(j).ok()).unwrap_or_default(),
            numeric_id: text(F::NumericId),
            profile_fetched_at: u.property(crate::user_fields::PROFILE_FETCHED_AT).map(str::to_string),
            created_at: u.created_at.clone(),
            updated_at: u.updated_at.clone(),
        }
    }
}

/// One hit of a source's user search: enough to show and to follow
/// (via `ensure_user`); not yet a library row.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UUserHit {
    pub source: String,
    pub source_id: String,
    pub username: String,
    pub profile_url: String,
    pub avatar_url: String,
}

/// The pre-v30 profile record, kept for the iOS UI until it moves to
/// `UUser` (macOS first). Built from the same row.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UUserProfile {
    pub source: String,
    pub url: String,
    pub username: String,
    pub numeric_id: Option<String>,
    pub avatar_url: Option<String>,
    pub pseuds: Vec<String>,
    pub joined: String,
    pub location: String,
    pub birthday: String,
    pub bio_json: String,
    pub works_count: u32,
    pub series_count: u32,
    pub bookmarks_count: u32,
    pub collections_count: u32,
    pub gifts_count: u32,
    pub subscribed: bool,
    pub blocked: bool,
    pub muted: bool,
    pub fetched_at: String,
}

impl From<UUser> for UUserProfile {
    fn from(u: UUser) -> Self {
        UUserProfile {
            source: u.source,
            url: u.profile_url.unwrap_or_default(),
            username: u.username,
            numeric_id: u.numeric_id,
            avatar_url: u.avatar_url,
            pseuds: u.pseuds,
            joined: u.joined.unwrap_or_default(),
            location: u.location.unwrap_or_default(),
            birthday: u.birthday.unwrap_or_default(),
            bio_json: u.info_json.unwrap_or_else(|| "[]".to_string()),
            works_count: u.works.unwrap_or(0) as u32,
            series_count: u.series.unwrap_or(0) as u32,
            bookmarks_count: u.bookmarks.unwrap_or(0) as u32,
            collections_count: u.collections.unwrap_or(0) as u32,
            gifts_count: u.gifts.unwrap_or(0) as u32,
            subscribed: u.subscribed,
            blocked: u.blocked,
            muted: u.muted,
            fetched_at: u.profile_fetched_at.unwrap_or_default(),
        }
    }
}

/// Follows the What's New check has let go stale, for the overdue warning.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UWhatsNewOverdue {
    /// Checked follows last checked longer ago than the threshold, or never.
    pub overdue: u32,
    /// Of `overdue`, the ones never checked at all (e.g. just followed).
    pub never_checked: u32,
    /// Every follow the check covers.
    pub total: u32,
}

/// One source the What's New check can ask, for the source selection.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCheckSource {
    pub id: String,
    pub name: String,
    /// The check asks this source; false leaves its follows out of rounds.
    pub selected: bool,
    /// Checked follows this source holds.
    pub follows: u32,
}

/// One pending item of the What's New check queue, for the monitor UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCheckQueueItem {
    pub kind: String,
    pub target_id: String,
    pub name: String,
    /// A census continuation (deeper listing pages) rather than a page-1
    /// check.
    pub census: bool,
    /// For a census item, the listing page this item will fetch next
    /// (from the persisted census cursor); 0 otherwise.
    pub page: u32,
    /// For a census item, the listing's page count as last parsed; 0 when
    /// unknown or not a census.
    pub total_pages: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UFollowCheckResult {
    pub kind: String,
    pub target_id: String,
    pub name: String,
    pub changed: bool,
    pub remaining: u32,
    pub error: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UNotification {
    pub id: i64,
    pub notif_type: String,
    pub work_id: u64,
    pub author: String,
    pub title: String,
    pub message: String,
    pub created_at: String,
    pub read: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCustomTheme {
    pub id: String,
    pub name: String,
    pub theme_json: String,
}

/// One section's work-list view spec: the sort choice, the section filters
/// (completion / rating / hide-explicit), and the free-form list filter
/// (text over title/author/summary, numeric expressions, tag/fandom
/// toggles). Rating strings use the works cache's encoding ("General",
/// "Teen", "Mature", "Explicit", "NotRated"); None = all ratings.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkListQuery {
    /// "natural" (keep caller order) | "updated" | "kudos" | "words" | "title".
    pub sort: String,
    /// "all" | "complete" | "inProgress".
    pub completion: String,
    pub rating: Option<String>,
    pub hide_explicit: bool,
    pub text: String,
    /// ">" / "<" prefixed comparisons; a plain number means "at least".
    pub kudos_expr: String,
    pub words_expr: String,
    /// OR within the group: a work matches if it carries ANY selected tag.
    pub tags: Vec<String>,
    pub fandoms: Vec<String>,
    /// Keep only works whose posted chapter count equals the declared
    /// total (32/32). An unknown total (5/?) never matches.
    pub completed_only: bool,
    /// The user's manual finished-reading flag: "any" | "finished" |
    /// "unfinished".
    pub finished: String,
}

/// The filter dialog's suggestion pools for one work list.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkFilterOptions {
    pub tags: Vec<String>,
    pub fandoms: Vec<String>,
}
