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

/// One "Part N of <series>" membership from a work page, including the
/// adjacent works in that series when AO3 provides the links.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SeriesMembership {
    pub series_id: u64,
    pub name: String,
    /// 1-based position within the series; 0 when the position text
    /// couldn't be parsed.
    pub part: u32,
    pub prev_work_id: Option<u64>,
    pub next_work_id: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkSummary {
    pub id: u64,
    pub title: String,
    pub authors: Vec<String>,
    pub fandoms: Vec<String>,
    pub rating: Rating,
    pub warnings: Vec<Warning>,
    pub categories: Vec<String>,
    pub relationships: Vec<String>,
    pub characters: Vec<String>,
    pub tags: Vec<String>,
    pub summary: String,
    pub word_count: u64,
    pub chapter_count: u32,
    pub total_chapters: Option<u32>,
    pub kudos: u32,
    pub hits: u64,
    pub bookmarks: u32,
    pub comments: u32,
    pub date_published: String,
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
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
}

#[derive(Debug, Clone)]
pub struct BookmarkListing {
    pub work_id: u64,
    pub ao3_bookmark_id: u64,
    pub note: String,
    pub work_summary: Option<WorkSummary>,
}

/// One collection blurb from the /collections index (li.collection.blurb).
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionSummary {
    /// URL slug — the path segment in /collections/{name}.
    pub name: String,
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

/// A subscription entry from AO3's subscriptions page.
#[derive(Debug, Clone)]
pub struct Subscription {
    pub sub_type: String,  // "author", "work", "series"
    pub id: String,        // username, work_id, or series_id
    pub name: String,      // display name
    /// AO3's subscription record id (from the unsubscribe form action) —
    /// lets unsubscribe POST directly without a page fetch.
    pub ao3_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AO3User {
    pub id: String,
    pub username: String,
    pub profile_url: Option<String>,
    pub avatar_url: Option<String>,
}

/// A user's full profile page (/users/{username}/profile): identity and
/// bio, sidebar counts, and — when the viewer is signed in — the live
/// subscribe/block/mute state with AO3's record ids for direct undo POSTs.
#[derive(Debug, Clone)]
pub struct UserProfile {
    pub username: String,
    /// AO3's numeric user id — the subscribe form's subscribable_id, or the
    /// "My user ID is" meta row when no form renders (logged out).
    pub numeric_id: Option<String>,
    pub avatar_url: Option<String>,
    pub pseuds: Vec<String>,
    pub joined: String,
    pub location: String,
    pub birthday: String,
    pub bio: Vec<ContentBlock>,
    pub works_count: u32,
    pub series_count: u32,
    pub bookmarks_count: u32,
    pub collections_count: u32,
    pub gifts_count: u32,
    /// Whether the page rendered a subscribe form — i.e. the viewer was
    /// signed in. When false the subscribe/block/mute fields carry no
    /// signal and must not overwrite locally known state.
    pub viewer_signed_in: bool,
    pub subscribed: bool,
    pub subscription_ao3_id: Option<String>,
    pub blocked: bool,
    pub block_ao3_id: Option<String>,
    pub muted: bool,
    pub mute_ao3_id: Option<String>,
    /// When this profile was last fetched from AO3 (set by storage on
    /// cached reads; empty on a fresh network parse).
    pub fetched_at: String,
}

#[derive(Debug, Clone)]
pub struct Comment {
    pub id: u64,
    pub author: AO3User,
    pub posted_at: String,
    pub content: Vec<ContentBlock>,
    pub replies: Vec<Comment>,
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
