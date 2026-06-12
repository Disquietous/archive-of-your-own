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
    pub date_updated: String,
    pub language: String,
    pub complete: bool,
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

#[derive(Debug, Clone)]
pub struct BookmarkListing {
    pub work_id: u64,
    pub ao3_bookmark_id: u64,
    pub note: String,
    pub work_summary: Option<WorkSummary>,
}

/// A subscription entry from AO3's subscriptions page.
#[derive(Debug, Clone)]
pub struct Subscription {
    pub sub_type: String,  // "author", "work", "series"
    pub id: String,        // username, work_id, or series_id
    pub name: String,      // display name
}

#[derive(Debug, Clone)]
pub struct AO3User {
    pub id: String,
    pub username: String,
    pub profile_url: Option<String>,
    pub avatar_url: Option<String>,
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
