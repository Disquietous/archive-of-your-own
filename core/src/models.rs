use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct FormField {
    pub name: String,
    pub label: String,
    pub field_type: FormFieldType,
}

#[derive(Debug, Clone)]
pub enum FormFieldType {
    Text { placeholder: String },
    Select { options: Vec<FormOption> },
    Checkboxes { options: Vec<FormOption> },
    Radio { options: Vec<FormOption> },
    Hidden { value: String },
}

#[derive(Debug, Clone)]
pub struct FormOption {
    pub value: String,
    pub label: String,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct SearchForm {
    pub fields: Vec<FormField>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Rating {
    General,
    Teen,
    Mature,
    Explicit,
    NotRated,
}

impl Rating {
    pub fn from_ao3_tag(s: &str) -> Self {
        let lower = s.to_lowercase();
        if lower.contains("general") {
            Rating::General
        } else if lower.contains("teen") {
            Rating::Teen
        } else if lower.contains("mature") {
            Rating::Mature
        } else if lower.contains("explicit") {
            Rating::Explicit
        } else {
            Rating::NotRated
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Warning {
    None,
    CreatorChoseNotToWarn,
    Violence,
    CharacterDeath,
    Underage,
    Noncon,
}

impl Warning {
    pub fn from_ao3_tag(s: &str) -> Self {
        let lower = s.to_lowercase();
        if lower.contains("no archive warnings") {
            Warning::None
        } else if lower.contains("chose not") {
            Warning::CreatorChoseNotToWarn
        } else if lower.contains("graphic depictions") || lower.contains("violence") {
            Warning::Violence
        } else if lower.contains("major character death") {
            Warning::CharacterDeath
        } else if lower.contains("underage") {
            Warning::Underage
        } else if lower.contains("rape") || lower.contains("non-con") {
            Warning::Noncon
        } else {
            Warning::CreatorChoseNotToWarn
        }
    }
}

/// The source every record carried before the library learned a second
/// one. Adapters name their own; the core compares, never interprets.
pub const SOURCE_AO3: &str = "ao3";

/// Where a stored entity came from: its source and the id that source
/// knows it by, plus the canonical page URL ("" for sources without
/// one). This is the only shape in which an external identifier leaves
/// the core — row ids identify everything else.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExternalRef {
    pub source: String,
    pub external_id: String,
    pub url: String,
}

impl ExternalRef {
    pub fn ao3(external_id: impl Into<String>, url: impl Into<String>) -> Self {
        ExternalRef { source: SOURCE_AO3.to_string(), external_id: external_id.into(), url: url.into() }
    }
}

/// A follow's target, by row id. Works and series are what the What's New
/// check fetches; authors are users rows; fandoms are tag rows (followed,
/// never checked).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FollowTarget {
    Work(u64),
    Series(u64),
    Author(i64),
    Fandom(i64),
}

impl FollowTarget {
    /// The `follows.kind` column value.
    pub fn kind(&self) -> &'static str {
        match self {
            FollowTarget::Work(_) => "work",
            FollowTarget::Series(_) => "series",
            FollowTarget::Author(_) => "author",
            FollowTarget::Fandom(_) => "fandom",
        }
    }

    /// The `follows.target_id` column value.
    pub fn id(&self) -> i64 {
        match self {
            FollowTarget::Work(id) | FollowTarget::Series(id) => *id as i64,
            FollowTarget::Author(id) | FollowTarget::Fandom(id) => *id,
        }
    }

    pub fn from_parts(kind: &str, id: i64) -> Option<Self> {
        match kind {
            "work" => Some(FollowTarget::Work(id as u64)),
            "series" => Some(FollowTarget::Series(id as u64)),
            "author" => Some(FollowTarget::Author(id)),
            "fandom" => Some(FollowTarget::Fandom(id)),
            _ => None,
        }
    }
}

/// One "Part N of <series>" membership from a work page, including the
/// adjacent works in that series when AO3 provides the links. The series
/// itself resolves to a row id when the work is saved (`series_id` is 0
/// on a freshly parsed membership); the adjacent works stay external
/// ids — they are usually not in the library, and a stub is only made
/// when the user opens one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SeriesMembership {
    /// Series row id; 0 until the owning work is saved.
    #[serde(default)]
    pub series_id: u64,
    /// The series' id at its source (AO3 series number).
    pub series_external_id: String,
    pub name: String,
    /// 1-based position within the series; 0 when the position text
    /// couldn't be parsed.
    pub part: u32,
    pub prev_work_external_id: Option<String>,
    pub next_work_external_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkSummary {
    /// Row id; 0 for a freshly parsed summary that has not been saved.
    pub id: u64,
    pub source: String,
    /// The work's id at its source (AO3 work number).
    pub external_id: String,
    /// Canonical page URL at the source; "" when the source has none.
    pub url: String,
    pub title: String,
    pub authors: Vec<String>,
    /// The `users` row behind each byline, in the same order (0 when the
    /// library has not linked that author yet). Filled by storage; never
    /// parsed, never persisted in the summary itself.
    #[serde(default)]
    pub author_ids: Vec<i64>,
    pub fandoms: Vec<String>,
    pub rating: Rating,
    pub warnings: Vec<Warning>,
    pub categories: Vec<String>,
    pub relationships: Vec<String>,
    pub characters: Vec<String>,
    pub tags: Vec<String>,
    pub summary: String,
    /// Stats are absent (None), never zero, when the source does not
    /// report them. AO3 always does.
    pub word_count: Option<u64>,
    pub chapter_count: u32,
    pub total_chapters: Option<u32>,
    pub kudos: Option<u32>,
    pub hits: Option<u64>,
    pub bookmarks: Option<u32>,
    pub comments: Option<u32>,
    pub date_published: String,
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
    /// The work's status in its source's own terms, set by the adapter:
    /// AO3 has "Ongoing" / "Complete" (from `complete`), ScribbleHub its
    /// three story statuses. "" when the source states none.
    #[serde(default)]
    pub status: String,
    /// Series this work belongs to (work pages only; listing blurbs leave
    /// this empty). Default keeps previously serialized summaries readable.
    #[serde(default)]
    pub series: Vec<SeriesMembership>,
    /// When this summary last arrived from AO3 (UTC "YYYY-MM-DD HH:MM:SS");
    /// set by storage on save, "" for freshly parsed summaries. Display
    /// metadata only — never a refresh trigger.
    #[serde(default)]
    pub fetched_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Chapter {
    pub id: Option<u64>,
    pub title: Option<String>,
    pub number: u32,
    pub content: Vec<ContentBlock>,
    pub notes_before: Option<String>,
    pub notes_after: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct SearchParams {
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
    pub sort_column: String,
    pub sort_direction: String,
    pub rating_id: Option<u32>,
    pub warning_ids: Vec<u32>,
    pub category_ids: Vec<u32>,
    pub complete: String,
    pub crossover: String,
    pub single_chapter: bool,
    pub language_id: String,
    pub revised_at: String,
}

/// Criteria for searching the local works cache, mirroring AO3's works
/// search form field-for-field. Select/checkbox choices arrive as the
/// scraped form's option *labels* (never AO3's numeric ids), so matching
/// compares against the names stored on cached works. Blank criteria
/// match everything — the form's default state returns the whole library.
#[derive(Debug, Clone, Default)]
pub struct LocalSearchCriteria {
    pub query: String,
    pub title: String,
    pub creators: String,
    pub revised_at: String,
    /// "" any · "T" complete only · "F" in-progress only
    pub complete: String,
    /// "" any · "T" crossovers only · "F" no crossovers
    pub crossover: String,
    pub single_chapter: bool,
    /// Library-only: keep works whose stored chapter rows number exactly
    /// the explicit total chapter count. A "?" total never matches.
    pub fully_downloaded: bool,
    pub word_count: String,
    /// Language option label, e.g. "English".
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
    /// Filters the fixed fields above cannot express: source stats, tag
    /// kinds beyond AO3's four, date windows. Produced by the schema
    /// translator (`source::library`), never by the UI.
    pub extra: Vec<ExtraPredicate>,
}

/// A library filter beyond the AO3-shaped criteria fields.
#[derive(Debug, Clone, PartialEq)]
pub enum ExtraPredicate {
    /// `work_stats` value of a registry field within [min, max] (either
    /// bound optional). Limits results to works of `source`.
    StatRange { source: String, key: String, min: Option<f64>, max: Option<f64> },
    /// Tags of one kind by exact name (ASCII case-insensitive): every
    /// `include` when `all`, else any; none of `exclude`.
    TagSet { tag_type: String, include: Vec<String>, exclude: Vec<String>, all: bool },
    /// A date column within [from, to] (ISO dates, inclusive, either
    /// bound optional). `column` is a works date column name.
    DateBetween { column: String, from: Option<String>, to: Option<String> },
    /// A numeric works column within [min, max] (either bound optional);
    /// `column` must be one the compiler whitelists.
    ColumnRange { column: String, min: Option<f64>, max: Option<f64> },
}

/// What a bookmark points at, by row id. AO3 also allows external-work
/// bookmarks; those are not modelled (the parser skips them).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BookmarkTarget {
    Work(u64),
    Series(u64),
}

/// The kind of a bookmark's target, before the target has a row id (a
/// parsed listing names its work or series by external id only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BookmarkKind {
    Work,
    Series,
}

impl BookmarkKind {
    pub fn with_id(self, id: u64) -> BookmarkTarget {
        match self {
            BookmarkKind::Work => BookmarkTarget::Work(id),
            BookmarkKind::Series => BookmarkTarget::Series(id),
        }
    }
}

impl BookmarkTarget {
    pub fn kind_of(&self) -> BookmarkKind {
        match self {
            BookmarkTarget::Work(_) => BookmarkKind::Work,
            BookmarkTarget::Series(_) => BookmarkKind::Series,
        }
    }

    /// The `bookmarks.bookmark_type` column value.
    pub fn kind(&self) -> &'static str {
        match self {
            BookmarkTarget::Work(_) => "work",
            BookmarkTarget::Series(_) => "series",
        }
    }

    /// The `bookmarks.target_id` column value.
    pub fn id(&self) -> u64 {
        match self {
            BookmarkTarget::Work(id) | BookmarkTarget::Series(id) => *id,
        }
    }

    pub fn from_parts(kind: &str, id: u64) -> Option<Self> {
        match kind {
            "work" => Some(BookmarkTarget::Work(id)),
            "series" => Some(BookmarkTarget::Series(id)),
            _ => None,
        }
    }

    pub fn work_id(&self) -> Option<u64> {
        match self { BookmarkTarget::Work(id) => Some(*id), _ => None }
    }

    pub fn series_id(&self) -> Option<u64> {
        match self { BookmarkTarget::Series(id) => Some(*id), _ => None }
    }
}

/// An AO3 series as a listing shows it (a series bookmark blurb or the
/// series page header). Rows in the `series` table.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SeriesSummary {
    /// Row id; 0 for a freshly parsed summary that has not been saved.
    pub id: u64,
    pub source: String,
    /// The series' id at its source (AO3 series number).
    pub external_id: String,
    pub url: String,
    pub name: String,
    pub authors: Vec<String>,
    pub summary: String,
    pub word_count: u64,
    pub work_count: u32,
    pub complete: bool,
    pub date_updated: String,
    /// When this summary last arrived from AO3 (DB datetime text; "" for
    /// freshly parsed summaries — storage stamps it on save).
    #[serde(default)]
    pub fetched_at: String,
}

#[derive(Debug, Clone)]
pub struct BookmarkListing {
    /// Work or series — the blurb names the target by external id only
    /// (inside `work_summary` / `series_summary`); the row id exists once
    /// the target is saved.
    pub kind: BookmarkKind,
    pub ao3_bookmark_id: u64,
    pub note: String,
    /// AO3 username the blurb's "Bookmarked by" byline attributes the
    /// bookmark to; "" when the byline is absent.
    pub bookmarker: String,
    /// The bookmarker's own tags on the bookmark (the user module's tag
    /// links, distinct from the work's tags).
    pub tags: Vec<String>,
    /// True when the blurb carries the Rec symbol.
    pub rec: bool,
    /// The user module's datetime text ("10 Aug 2026"); "" when absent.
    pub date_bookmarked: String,
    /// True for a "Mystery Work" blurb — a bookmark of a work still hidden
    /// in an unrevealed challenge collection. The blurb carries no work
    /// link, author, or stats; `work_summary` is a synthetic stub for
    /// display and must never be cached (cache-forever would fossilize the
    /// stub past the reveal).
    pub mystery: bool,
    /// Mystery blurbs name the collection the work will be revealed from
    /// ("Part of <a href=/collections/{name}>{title}</a>"). URL name and
    /// display title; "" unless mystery.
    pub mystery_collection_name: String,
    pub mystery_collection_title: String,
    /// The work blurb (work bookmarks; a synthetic stub for mystery ones).
    pub work_summary: Option<WorkSummary>,
    /// The series blurb (series bookmarks).
    pub series_summary: Option<SeriesSummary>,
}

/// One bookmark search hit: the bookmark's own fields plus the bookmarked
/// item's blurb — what a bookmark listing row displays. Exactly one of
/// `work` / `series` is set, per `target`.
#[derive(Debug, Clone)]
pub struct BookmarkHit {
    /// Local row id (0 for remote hits that were not cached).
    pub id: i64,
    /// Target by row id; id 0 for a remote hit whose target was not
    /// cached (a mystery blurb).
    pub target: BookmarkTarget,
    pub bookmarker: String,
    pub note: String,
    /// The bookmarker's own tags.
    pub tags: Vec<String>,
    pub rec: bool,
    /// AO3's blurb date for remote hits ("10 Aug 2026"); the local row's
    /// creation date ("YYYY-MM-DD") for library hits.
    pub date_bookmarked: String,
    /// True when `work` is the synthetic stub for an unrevealed "Mystery
    /// Work" — see BookmarkListing. Never true for library hits (mystery
    /// stubs are never cached).
    pub mystery: bool,
    /// The unrevealed collection's URL name and display title; "" unless
    /// mystery.
    pub mystery_collection_name: String,
    pub mystery_collection_title: String,
    pub work: Option<WorkSummary>,
    pub series: Option<SeriesSummary>,
}

/// AO3's /bookmarks/search form (bookmark_search[...] GET params). Every
/// field is optional — "" / false means "don't filter" — so a blank record
/// is an unfiltered search. The same record drives the library-scoped
/// search over cached bookmark rows.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BookmarkSearchCriteria {
    /// bookmark_search[bookmarkable_query] — any field on the work.
    pub bookmarkable_query: String,
    /// bookmark_search[other_tag_names] — comma-separated work tag names.
    pub other_tag_names: String,
    /// bookmark_search[bookmarkable_type] — "Work", "Series",
    /// "External Work", or "" (any). External bookmarks are never cached,
    /// so that filter matches nothing locally.
    pub bookmarkable_type: String,
    /// bookmark_search[word_count] — AO3 numeric range syntax.
    pub word_count: String,
    /// bookmark_search[language_id] — AO3's language value for the remote
    /// search (e.g. "en"); the library matcher compares it (and callers may
    /// pass the display name instead) against the work's language name.
    pub language_id: String,
    /// bookmark_search[bookmarkable_date] — work's Date Updated expression.
    pub bookmarkable_date: String,
    /// bookmark_search[bookmark_query] — any field on the bookmark itself.
    pub bookmark_query: String,
    /// bookmark_search[other_bookmark_tag_names] — comma-separated
    /// bookmarker's tag names.
    pub other_bookmark_tag_names: String,
    /// bookmark_search[bookmarker] — bookmarker username filter.
    pub bookmarker: String,
    /// bookmark_search[bookmark_notes] — text filter on the notes.
    pub bookmark_notes: String,
    /// bookmark_search[rec] — recs only.
    pub rec: bool,
    /// bookmark_search[with_notes] — bookmarks with notes only.
    pub with_notes: bool,
    /// bookmark_search[date] — Date Bookmarked expression.
    pub date: String,
    /// bookmark_search[sort_column] — "" (Best Match), "created_at" (Date
    /// Bookmarked), "bookmarkable_date" (Date Updated), or "word_count".
    pub sort_column: String,
}

/// One collection blurb from the /collections index (li.collection.blurb).
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionSummary {
    pub source: String,
    /// The collection's external id: its URL slug, the path segment in
    /// /collections/{name}. The row id never leaves storage.
    pub name: String,
    pub url: String,
    /// Display title from the blurb heading link.
    pub title: String,
    /// Plain-text summary (blockquote.userstuff.summary), "" when absent.
    pub summary: String,
    pub is_open: bool,
    pub is_moderated: bool,
    pub is_anonymous: bool,
    pub work_count: u32,
    pub bookmarked_count: u32,
    /// Maintainer usernames from the heading's "by …" owner links.
    pub maintainers: Vec<String>,
    /// Tag names on the collection. Only the /profile page carries these —
    /// index blurbs leave the list empty.
    pub tags: Vec<String>,
    /// Challenge type from the p.type line, e.g. "Gift Exchange Challenge"
    /// or "Prompt Meme Challenge"; "" for a plain (non-challenge) collection.
    pub collection_type: String,
}

/// The collections index's sort/filter form (/collections,
/// collection_search[...] GET params). Every field is optional — "" means
/// "don't filter" / "AO3's default" — so a blank record is the plain index.
/// The same record drives the library-scoped search over cached collections.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CollectionSearchCriteria {
    /// collection_search[title] — substring title filter.
    pub title: String,
    /// collection_search[tag] — comma-separated tag names (AO3's token
    /// field allows up to 5).
    pub tag: String,
    /// collection_search[multifandom] — "true", "false", or "" (either).
    pub multifandom: String,
    /// collection_search[closed] — "true", "false", or "" (either).
    pub closed: String,
    /// collection_search[moderated] — "true", "false", or "" (either).
    pub moderated: String,
    /// collection_search[challenge_type] — "GiftExchange", "PromptMeme",
    /// "no_challenge", or "" (any).
    pub challenge_type: String,
    /// collection_search[sort_column] — "created_at" (AO3's default),
    /// "title.keyword", "bookmarked_items_count", or "works_count".
    pub sort_column: String,
    /// collection_search[sort_direction] — "asc" or "desc" (AO3 defaults
    /// to desc).
    pub sort_direction: String,
}

impl CollectionSearchCriteria {
    /// True when every field is blank — the plain unfiltered index.
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

/// A subscription entry from AO3's subscriptions page.
#[derive(Debug, Clone)]
pub struct Subscription {
    pub sub_type: String,  // "author", "work", "series"
    pub id: String,        // AO3 username, work number, or series number
    pub name: String,      // display name
    /// AO3's subscription record id (from the unsubscribe form action) —
    /// lets unsubscribe POST directly without a page fetch.
    pub ao3_id: Option<String>,
    /// The subscribed target's page on AO3.
    pub url: String,
}

/// A sighting of a user at a source: who, and where their profile is.
/// `id` is the user's key at the source — the AO3 username (or a
/// `guest:` id for logged-out commenters), a ScribbleHub profile id.
/// Never a library identity; storage resolves it to a `users` row.
#[derive(Debug, Clone)]
pub struct AO3User {
    pub source: String,
    pub id: String,
    pub username: String,
    pub profile_url: Option<String>,
    pub avatar_url: Option<String>,
}

impl AO3User {
    pub fn ao3(id: &str, username: &str, profile_url: Option<String>, avatar_url: Option<String>) -> AO3User {
        AO3User { source: SOURCE_AO3.to_string(), id: id.to_string(), username: username.to_string(), profile_url, avatar_url }
    }
}

/// A user's profile as a source reports it: the sighting plus every
/// property the page shows, under the source's own names (see
/// `user_fields` for the names each source uses and what they map to).
#[derive(Debug, Clone, Default)]
pub struct SourceUserProfile {
    pub source: String,
    pub source_id: String,
    pub username: String,
    pub properties: Vec<(String, String)>,
}

impl SourceUserProfile {
    pub fn property(&self, name: &str) -> Option<&str> {
        self.properties.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }
}

/// AO3's profile page also tells a signed-in viewer their own relation
/// to the user; that is subscription state, not a user property.
#[derive(Debug, Clone, Default)]
pub struct AO3ProfilePage {
    pub profile: SourceUserProfile,
    /// Whether the page rendered a subscribe form — i.e. the viewer was
    /// signed in. When false the subscribe field carries no signal.
    pub viewer_signed_in: bool,
    pub subscribed: bool,
    pub subscription_ao3_id: Option<String>,
}

/// A user's full profile page (/users/{username}/profile): identity and
/// bio, sidebar counts, and — when the viewer is signed in — the live
/// subscribe/block/mute state with AO3's record ids for direct undo POSTs.
#[derive(Debug, Clone)]
pub struct Comment {
    pub id: u64,
    pub author: AO3User,
    pub posted_at: String,
    pub content: Vec<ContentBlock>,
    pub replies: Vec<Comment>,
    /// "on Chapter N" from the byline — set on whole-work comment pages,
    /// where comments from every chapter are listed together.
    pub chapter_label: Option<String>,
    /// The chapter the comment is on, from the "on Chapter N" link (whole-
    /// work pages) or the stored row. None when AO3 doesn't say — a
    /// chapter page, or a one-chapter work.
    pub chapter_id: Option<u64>,
    /// AO3's message in place of a body ("(Previous comment deleted.)",
    /// hidden/awaiting-moderation notices). None for a normal comment.
    pub notice: Option<String>,
    /// Replies AO3 left off this page behind an "N more comments in this
    /// thread" link (fetched on demand via the comment's thread page).
    pub more_replies: u32,
    /// The stars a review carries on a rated source (Area 12); None for
    /// a plain comment.
    pub rating: Option<u8>,
}

#[derive(Debug, Clone)]
pub struct CommentsPage {
    pub comments: Vec<Comment>,
    pub current_page: u32,
    pub total_pages: u32,
}

#[derive(Debug, Clone)]
pub struct InboxItem {
    pub comment_id: u64,
    pub author: String,
    pub author_url: Option<String>,
    pub avatar_url: Option<String>,
    pub work_reference: String,
    pub work_url: Option<String>,
    pub posted_at: String,
    pub is_unread: bool,
    pub content: Vec<ContentBlock>,
}

#[derive(Debug, Clone)]
pub struct InboxPage {
    pub items: Vec<InboxItem>,
    pub unread_count: u32,
    pub has_next_page: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ContentBlock {
    Paragraph { text: Vec<InlineContent> },
    Heading { level: u8, text: String },
    Blockquote { blocks: Vec<ContentBlock> },
    HorizontalRule,
    List { ordered: bool, items: Vec<Vec<ContentBlock>> },
    PreFormatted { text: String },
    /// An embedded image, kept block-level (AO3 fics embed images as figures
    /// between paragraphs). Only the resolved URL and alt text are stored;
    /// bytes live in image_cache and are fetched on demand (tap-to-load).
    Image { src: String, alt: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InlineContent {
    Text { value: String },
    Bold { content: Vec<InlineContent> },
    Italic { content: Vec<InlineContent> },
    Link { href: String, content: Vec<InlineContent> },
    Strikethrough { content: Vec<InlineContent> },
    Superscript { content: Vec<InlineContent> },
    LineBreak,
}

/// AO3 bylines render as "Pseud (Username)" (also without the space) when
/// the pseud differs from the account name. Returns (username, pseud) —
/// plain names pass through as (name, None). Real usernames never contain
/// spaces or parens, so URLs must always use the split-out account name.
pub fn split_author_byline(author: &str) -> (String, Option<String>) {
    let t = author.trim();
    if let Some(open) = t.rfind('(') {
        if t.ends_with(')') {
            let user = t[open + 1..t.len() - 1].trim();
            let pseud = t[..open].trim();
            if !user.is_empty() {
                return (user.to_string(),
                        Some(pseud.to_string()).filter(|p| !p.is_empty()));
            }
        }
    }
    (t.to_string(), None)
}

/// The inverse of `split_author_byline`: how AO3 renders an author —
/// "Pseud (account)" when the pseud differs from the account name, else
/// the bare account name.
pub fn join_author_byline(account: &str, pseud: Option<&str>) -> String {
    match pseud.map(str::trim).filter(|p| !p.is_empty() && !p.eq_ignore_ascii_case(account)) {
        Some(p) => format!("{p} ({account})"),
        None => account.to_string(),
    }
}
