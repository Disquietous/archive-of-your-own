//! AO3 behind the source contract. A wrapper over the existing
//! `AO3Client`, not a move of its code: the fetch plan, parsers and social
//! paths stay where they are until AO3 is reachable and the move can be
//! verified live. The client is the app's shared one, so a connect or a
//! circuit rotation that swaps it is seen here too.

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::RwLock;

use crate::client::AO3Client;
use crate::error::AppError;
use crate::models::{CommentsPage, ExternalRef, WorkSummary, SOURCE_AO3};

use super::{DiscussionShape, FetchedWork, ReactionShape, Reachability, Source, SourceCapabilities, Vocabulary};

pub struct AO3Source {
    client: Arc<RwLock<AO3Client>>,
    capabilities: SourceCapabilities,
}

impl AO3Source {
    pub fn new(client: Arc<RwLock<AO3Client>>) -> Self {
        AO3Source { client, capabilities: Self::declare() }
    }

    fn declare() -> SourceCapabilities {
        SourceCapabilities {
            id: SOURCE_AO3.to_string(),
            name: "Archive of Our Own".to_string(),
            reach: Reachability { tor: true, direct: true },
            reaction: ReactionShape::Kudos,
            discussion: DiscussionShape::Threaded,
            chapter_comments: true,
            search: true,
            browse: true,
            author_listings: true,
            user_search: false,
            tag_listings: true,
            update_checks: true,
            login: true,
            remote_bookmarks: true,
            subscriptions: true,
            collections: true,
            inbox: true,
            vocabulary: Vocabulary {
                discussion_title: "Comments".to_string(),
                reaction_verb: "Leave kudos".to_string(),
                reply_verb: Some("Reply".to_string()),
                rating_label: "Rating".to_string(),
            },
        }
    }

    /// The AO3 work number in a work or chapter URL, on either host.
    pub fn work_number_in(input: &str) -> Option<u64> {
        let rest = input
            .strip_prefix("https://")
            .or_else(|| input.strip_prefix("http://"))
            .unwrap_or(input);
        let rest = rest.strip_prefix("www.").unwrap_or(rest);
        let path = rest.strip_prefix("archiveofourown.org/")?;
        let after = path.strip_prefix("works/")?;
        let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() { return None }
        // "/works/123" followed by nothing, a slash, a query, or a fragment.
        match after[digits.len()..].chars().next() {
            None | Some('/') | Some('?') | Some('#') => digits.parse().ok(),
            _ => None,
        }
    }

    fn number(external_id: &str) -> Result<u64, AppError> {
        external_id.parse().map_err(|_| AppError::InvalidWorkId(external_id.to_string()))
    }
}

#[async_trait]
impl Source for AO3Source {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let number = Self::work_number_in(input)?;
        Some(ExternalRef::ao3(number.to_string(), crate::parser::ao3_work_url(number)))
    }

    /// `archiveofourown.org/users/{name}[/pseuds/…|/profile|/works]`.
    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let lower = input.to_ascii_lowercase();
        let host_at = lower.find("archiveofourown.org/")?;
        let path = &input[host_at + "archiveofourown.org/".len()..];
        let rest = path.strip_prefix("users/")?;
        let name: String = rest.chars().take_while(|c| !matches!(c, '/' | '?' | '#')).collect();
        if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return None;
        }
        Some(ExternalRef::ao3(name.clone(), crate::parser::ao3_user_url(&name)))
    }

    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        let number = Self::number(&work.external_id)?;
        let (summary, chapters, kudos_names) = self.client.read().await.get_work(number).await?;
        Ok(FetchedWork { summary, chapters, stats: Vec::new(), reacted_by: kudos_names, authors: Vec::new() })
    }

    async fn fetch_discussion(&self, work: &ExternalRef, chapter: Option<u64>, page: u32)
        -> Result<CommentsPage, AppError>
    {
        let number = Self::number(&work.external_id)?;
        let client = self.client.read().await;
        match chapter {
            Some(chapter_id) => client.fetch_comments_for_chapter(number, chapter_id, page).await,
            None => client.fetch_comments_for_work(number, page).await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_work_and_chapter_links() {
        let n = AO3Source::work_number_in;
        assert_eq!(n("https://archiveofourown.org/works/123"), Some(123));
        assert_eq!(n("http://www.archiveofourown.org/works/123/chapters/9?view_adult=true"), Some(123));
        assert_eq!(n("archiveofourown.org/works/123#main"), Some(123));
        assert_eq!(n("https://archiveofourown.org/works/123abc"), None);
        assert_eq!(n("https://archiveofourown.org/series/123"), None);
        assert_eq!(n("https://rated.mock/story/1"), None);
    }
}
