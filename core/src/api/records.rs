use super::*;

#[derive(Debug, Clone, uniffi::Record)]
pub struct ULogEntry {
    pub id: i64,
    pub timestamp: String,
    pub level: String,
    pub tag: String,
    pub message: String,
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
}

/// The full AO3 bookmark object for one work.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmarkDetails {
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
}

// UniFFI-compatible record types (flat, no generics)

#[derive(Debug, Clone, uniffi::Record)]
pub struct USeriesMembership {
    pub series_id: u64,
    pub name: String,
    /// 1-based position within the series; 0 = unknown.
    pub part: u32,
    pub prev_work_id: Option<u64>,
    pub next_work_id: Option<u64>,
}

impl From<SeriesMembership> for USeriesMembership {
    fn from(s: SeriesMembership) -> Self {
        USeriesMembership {
            series_id: s.series_id,
            name: s.name,
            part: s.part,
            prev_work_id: s.prev_work_id,
            next_work_id: s.next_work_id,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkSummary {
    pub id: u64,
    pub title: String,
    pub authors: Vec<String>,
    pub fandoms: Vec<String>,
    pub rating: String,
    pub warnings: Vec<String>,
    pub categories: Vec<String>,
    pub relationships: Vec<String>,
    pub characters: Vec<String>,
    pub tags: Vec<String>,
    pub summary: String,
    pub word_count: u64,
    pub chapter_count: u32,
    pub total_chapters: i32,
    pub kudos: u32,
    pub hits: u64,
    pub bookmarks_count: u32,
    pub comments: u32,
    pub date_published: String,
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
    pub series: Vec<USeriesMembership>,
    /// When this summary last arrived from AO3 (UTC "YYYY-MM-DD HH:MM:SS",
    /// "" = unknown). Display metadata only — never a refresh trigger.
    pub fetched_at: String,
}

impl From<WorkSummary> for UWorkSummary {
    fn from(w: WorkSummary) -> Self {
        UWorkSummary {
            id: w.id,
            title: w.title,
            authors: w.authors,
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
            series: w.series.into_iter().map(USeriesMembership::from).collect(),
            fetched_at: w.fetched_at,
        }
    }
}

/// One collection blurb from the /collections index.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCollection {
    /// URL slug — the path segment in /collections/{name}.
    pub name: String,
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
            name: c.name,
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
/// work's blurb.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UBookmarkHit {
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
    pub work: UWorkSummary,
}

impl From<BookmarkHit> for UBookmarkHit {
    fn from(h: BookmarkHit) -> Self {
        UBookmarkHit {
            bookmarker: h.bookmarker,
            note: h.note,
            tags: h.tags,
            rec: h.rec,
            date_bookmarked: h.date_bookmarked,
            work: UWorkSummary::from(h.work),
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
}

impl From<Comment> for CommentJson {
    fn from(c: Comment) -> Self {
        CommentJson {
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
        }
    }
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
    pub work_id: u64,
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

#[derive(Debug, Clone, uniffi::Record)]
pub struct USubscription {
    pub sub_type: String,
    pub id: String,
    pub name: String,
    /// AO3's subscription record id (from unsubscribe form actions) —
    /// stored so unsubscribing can POST directly without a page fetch.
    pub ao3_id: Option<String>,
}

impl From<crate::models::Subscription> for USubscription {
    fn from(s: crate::models::Subscription) -> Self {
        USubscription {
            sub_type: s.sub_type,
            id: s.id,
            name: s.name,
            ao3_id: s.ao3_id,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UUserProfile {
    pub username: String,
    /// AO3's numeric user id — needed for the direct subscribe POST.
    pub numeric_id: Option<String>,
    pub avatar_url: Option<String>,
    pub pseuds: Vec<String>,
    pub joined: String,
    pub location: String,
    pub birthday: String,
    /// Bio as a serialized ContentBlock tree (same JSON encoding as
    /// comment content) — "[]" when the profile has none.
    pub bio_json: String,
    pub works_count: u32,
    pub series_count: u32,
    pub bookmarks_count: u32,
    pub collections_count: u32,
    pub gifts_count: u32,
    pub subscribed: bool,
    pub blocked: bool,
    pub muted: bool,
    /// When this profile was last fetched from AO3; empty for a profile
    /// that just arrived off the network.
    pub fetched_at: String,
}

impl From<crate::models::UserProfile> for UUserProfile {
    fn from(p: crate::models::UserProfile) -> Self {
        UUserProfile {
            username: p.username,
            numeric_id: p.numeric_id,
            avatar_url: p.avatar_url,
            pseuds: p.pseuds,
            joined: p.joined,
            location: p.location,
            birthday: p.birthday,
            bio_json: serde_json::to_string(&p.bio).unwrap_or_else(|_| "[]".to_string()),
            works_count: p.works_count,
            series_count: p.series_count,
            bookmarks_count: p.bookmarks_count,
            collections_count: p.collections_count,
            gifts_count: p.gifts_count,
            subscribed: p.subscribed,
            blocked: p.blocked,
            muted: p.muted,
            fetched_at: p.fetched_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct USubscriptionCheckResult {
    pub sub_type: String,
    pub sub_id: String,
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
}

/// The filter dialog's suggestion pools for one work list.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UWorkFilterOptions {
    pub tags: Vec<String>,
    pub fandoms: Vec<String>,
}
