//! The storage layer's shared string vocabulary — one constant per concept,
//! referenced from every site that means that concept. A literal used in two
//! or more places belongs here; one-off strings may stay inline.
//!
//! Deliberate exception: version-frozen migration/backfill steps (e.g.
//! `backfill_work_tags_v8`) keep their SQL and vocabulary inline, so edits
//! here can never silently change what an already-shipped migration replays.
//!
//! Two constants may hold the same spelling when they name different
//! concepts (the AO3 form key "word_count" vs. the works column
//! "word_count") — sites reference the concept they mean, never the shared
//! spelling.

// ---------------------------------------------------------------------------
// Savepoints
// ---------------------------------------------------------------------------

/// Every savepoint the storage layer uses. `with_savepoint` takes this enum
/// rather than a string so no runtime-built name can ever reach SQL text.
#[derive(Clone, Copy)]
pub(crate) enum Savepoint {
    SaveWork,
    UpsertTags,
    CanonicalTags,
    SaveCollections,
    SaveCollectionProfile,
    SubWorks,
    WorksGone,
    AddSubWorks,
    NewWorkIds,
}

impl Savepoint {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::SaveWork => "save_work",
            Self::UpsertTags => "upsert_tags",
            Self::CanonicalTags => "canonical_tags",
            Self::SaveCollections => "save_collections",
            Self::SaveCollectionProfile => "save_collection_profile",
            Self::SubWorks => "sub_works",
            Self::WorksGone => "works_gone",
            Self::AddSubWorks => "add_sub_works",
            Self::NewWorkIds => "new_work_ids",
        }
    }
}

/// SAVEPOINT verbs — savepoint names are identifiers, which SQL cannot
/// parameterize, so the statements are assembled from these plus
/// `Savepoint::name()`.
pub(super) const SQL_SAVEPOINT: &str = "SAVEPOINT";
pub(super) const SQL_RELEASE: &str = "RELEASE";
pub(super) const SQL_ROLLBACK_TO: &str = "ROLLBACK TO";

// ---------------------------------------------------------------------------
// Whole statements used from more than one site
// ---------------------------------------------------------------------------

pub(super) const SQL_UPSERT_SUBSCRIPTION: &str =
    "INSERT OR REPLACE INTO subscriptions (sub_type, sub_id, name, ao3_id) VALUES (?1, ?2, ?3, ?4)";

/// Stub row satisfying collection foreign keys for deep-linked listings —
/// the next blurb or profile save fills it in.

// ---------------------------------------------------------------------------
// Tag vocabulary (work_tags.tag_type / tags.tag_type values)
// ---------------------------------------------------------------------------

pub(super) const TAG_TYPE_FANDOM: &str = "fandom";
pub(super) const TAG_TYPE_CHARACTER: &str = "character";
pub(super) const TAG_TYPE_RELATIONSHIP: &str = "relationship";
pub(super) const TAG_TYPE_FREEFORM: &str = "freeform";
pub(super) const TAG_TYPE_CREATOR: &str = "creator";

// ---------------------------------------------------------------------------
// Subscription kinds (subscriptions.sub_type values)
// ---------------------------------------------------------------------------

pub(super) const SUB_TYPE_AUTHOR: &str = "author";
pub(super) const SUB_TYPE_SERIES: &str = "series";

// ---------------------------------------------------------------------------
// Rating names as stored in works.rating
// ---------------------------------------------------------------------------

pub(super) const RATING_GENERAL: &str = "General";
pub(super) const RATING_TEEN: &str = "Teen";
pub(super) const RATING_MATURE: &str = "Mature";
pub(super) const RATING_EXPLICIT: &str = "Explicit";
pub(super) const RATING_NOT_RATED: &str = "NotRated";

// ---------------------------------------------------------------------------
// AO3 works-form sort vocabulary (form values, not column names)
// ---------------------------------------------------------------------------

pub(super) const SORT_KEY_TITLE: &str = "title_to_sort_on";
/// AO3's form value for Date Posted.
pub(super) const SORT_KEY_CREATED_AT: &str = "created_at";
pub(super) const SORT_KEY_WORD_COUNT: &str = "word_count";
pub(super) const SORT_KEY_HITS: &str = "hits";
pub(super) const SORT_KEY_KUDOS: &str = "kudos_count";
pub(super) const SORT_KEY_COMMENTS: &str = "comments_count";
pub(super) const SORT_KEY_BOOKMARKS: &str = "bookmarks_count";
pub(super) const SORT_ASC: &str = "asc";
pub(super) const SORT_DESC: &str = "desc";

/// The tri-state include/exclude/any values AO3 forms submit.
pub(super) const FORM_TRUE: &str = "true";
pub(super) const FORM_FALSE: &str = "false";

// ---------------------------------------------------------------------------
// works-table metric columns shared by WORK_COLS and the search compiler
// ---------------------------------------------------------------------------

pub(super) const COL_WORD_COUNT: &str = "word_count";
pub(super) const COL_HITS: &str = "hits";
pub(super) const COL_KUDOS: &str = "kudos";
pub(super) const COL_COMMENTS: &str = "comments";
pub(super) const COL_BOOKMARKS: &str = "bookmarks";

// ---------------------------------------------------------------------------
// app_state keys
// ---------------------------------------------------------------------------

pub(super) const STATE_SUB_CHECK_QUEUE: &str = "subscription_check_queue";
pub(super) const STATE_LAST_SUB_CHECK: &str = "last_subscription_check";
/// Historical name — predates the tags-table rename; keeping it stops
/// already-seeded databases from re-running the backfill.
pub(super) const STATE_KNOWN_TAGS_BACKFILLED: &str = "known_tags_backfilled";

// ---------------------------------------------------------------------------
// SQLite pragmas
// ---------------------------------------------------------------------------

pub(super) const PRAGMA_USER_VERSION: &str = "user_version";
pub(super) const PRAGMA_REKEY: &str = "rekey";

// ---------------------------------------------------------------------------
// Log tags
// ---------------------------------------------------------------------------

pub(super) const LOG_TAG_COLLECTIONS: &str = "collections";

// ---------------------------------------------------------------------------
// IN-list batching
// ---------------------------------------------------------------------------

/// `?, ?, ?` placeholder list for an `IN (...)` clause of `n` bound values.
pub(super) fn sql_placeholders(n: usize) -> String {
    vec!["?"; n].join(", ")
}

// ---------------------------------------------------------------------------
// LIKE pattern builders (input must already be `escape_like`d)
// ---------------------------------------------------------------------------

pub(super) fn like_contains(escaped: &str) -> String {
    format!("%{escaped}%")
}

pub(super) fn like_prefix(escaped: &str) -> String {
    format!("{escaped}%")
}
