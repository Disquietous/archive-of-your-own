//! Local files as a source (Area 11.1–2): a book the user picks is read
//! once, saved into the encrypted library like any fetched work, and the
//! file is not kept. There is no site behind it — nothing to fetch,
//! refresh, follow, rate or discuss — so every capability is off and the
//! adapter exists to give the rows their controls (all hidden).
//!
//! EPUB only in the first pass; `epub::read_epub` is the whole ingest.

use async_trait::async_trait;

use crate::error::AppError;
use crate::models::{ExternalRef, WorkSummary};

use super::{DiscussionShape, FetchedWork, Gate, ReactionShape, Reachability, SignInShape, Source,
            SourceCapabilities, Vocabulary};

pub mod epub;
mod zip;

pub use epub::read_epub;

pub const SOURCE_ID: &str = "local";

pub struct LocalSource {
    capabilities: SourceCapabilities,
}

impl Default for LocalSource {
    fn default() -> Self { Self::new() }
}

impl LocalSource {
    pub fn new() -> Self {
        LocalSource {
            capabilities: SourceCapabilities {
                id: SOURCE_ID.to_string(),
                name: "Local Files".to_string(),
                host: String::new(),
                // No requests are ever made, so no privacy mode rules it out.
                reach: Reachability { tor: true, direct: true },
                reaction: ReactionShape::None,
                discussion: DiscussionShape::None,
                chapter_comments: false,
                search: false,
                browse: false,
                author_listings: false,
                user_search: false,
                tag_listings: false,
                update_checks: false,
                discussion_posts: false,
                login: false,
                sign_in: SignInShape::None,
                remote_bookmarks: false,
                subscriptions: false,
                collections: false,
                inbox: false,
                user_moderation: false,
                username_is_key: false,
                vocabulary: Vocabulary {
                    discussion_title: "Comments".to_string(),
                    reaction_verb: String::new(),
                    reply_verb: None,
                    rating_label: "Rating".to_string(),
                    site_short: "File".to_string(),
                    open_on_site: String::new(),
                    copy_link: String::new(),
                    refresh: "Refresh".to_string(),
                    subscribe_verb: None,
                },
            },
        }
    }
}

#[async_trait]
impl Source for LocalSource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    /// A local work has no link: it enters the library through the file
    /// picker, never by a pasted or tapped string.
    fn resolve(&self, _input: &str) -> Option<ExternalRef> {
        None
    }

    fn library_only(&self) -> bool { true }

    async fn fetch_work(&self, _work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        Err(AppError::NetworkError(
            "This work came from a file, so there is nothing to refresh. Import the file again to replace it."
                .to_string()))
    }

    fn reaction_gate(&self, _signed_in: bool) -> Gate {
        Gate::Hidden
    }
}
