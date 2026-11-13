//! A synthetic second source with the shapes AO3 lacks: a 1–5 star rating
//! with a site average, flat rated reviews on the story, and plain
//! comments on chapters. Mirrors what ScribbleHub offers so the shape
//! rendering, stats registry and discussion panel are exercised offline
//! before a real adapter exists. Everything here is invented; ids are its
//! own and never collide with another source's. Answers only while the
//! mock archive is on, like the AO3 mock.

use async_trait::async_trait;

use crate::error::AppError;
use crate::models::{AO3User, Chapter, Comment, CommentsPage, ContentBlock, ExternalRef, InlineContent, Rating,
                    WorkSummary};

use super::{DiscussionShape, FetchedWork, Gate, Reaction, ReactionOutcome, ReactionShape, Reachability, Source,
            SourceCapabilities, SourceStat, Vocabulary};

pub const SOURCE_ID: &str = "mockrated";
pub const BASE_URL: &str = "https://rated.mock";

struct Story {
    id: u64,
    title: &'static str,
    author: &'static str,
    genres: &'static [&'static str],
    summary: &'static str,
    chapters: u32,
    complete: bool,
    published: &'static str,
    updated: &'static str,
    words: u64,
    /// Site average over every reader, and how many rated.
    rating_avg: f64,
    rating_count: u32,
    views: u64,
    favorites: u32,
}

const STORIES: &[Story] = &[
    Story {
        id: 1, title: "The Cartographer's Apprentice", author: "inkwell_and_compass",
        genres: &["Fantasy", "Adventure"], chapters: 4, complete: false,
        summary: "Mira signs on to map a coastline that keeps moving, under a master who will not say why.",
        published: "2026-02-11", updated: "2026-10-30", words: 18_420,
        rating_avg: 4.6, rating_count: 312, views: 48_201, favorites: 1_104,
    },
    Story {
        id: 2, title: "Low Tide Protocol", author: "saltglass",
        genres: &["Science Fiction", "Mystery"], chapters: 3, complete: true,
        summary: "A harbour AI stops answering at low tide. The engineer sent to fix it starts keeping the same hours.",
        published: "2025-11-02", updated: "2026-01-19", words: 9_870,
        rating_avg: 4.1, rating_count: 87, views: 12_930, favorites: 240,
    },
    Story {
        id: 3, title: "Nine Lamps for the Ferry", author: "pennyfarthing_",
        genres: &["Slice of Life"], chapters: 2, complete: false,
        summary: "Every lamp on the night ferry is lit by someone who refuses to say what they are waiting for.",
        published: "2026-09-01", updated: "2026-09-21", words: 4_310,
        rating_avg: 3.8, rating_count: 19, views: 2_204, favorites: 41,
    },
];

const REVIEWERS: &[&str] = &["driftwoodreader", "the_eighth_bell", "hexmaps", "quietcartographer"];
const REVIEW_TEXT: &[&str] = &[
    "Read it in one sitting. The pacing in the middle chapters is the best thing about it.",
    "Lovely prose, but the plot leans on the same reveal twice.",
    "Didn't expect to care about a harbour this much.",
    "Short and strange and exactly as long as it needs to be.",
];
const CHAPTER_COMMENT_TEXT: &[&str] = &[
    "That last line.",
    "Calling it now: the master knows exactly why the coast moves.",
    "Typo in paragraph three, otherwise great.",
];

/// Comment ids: story * 10_000 + chapter * 100 + slot. Reviews are
/// chapter 0.
fn comment_id(story: u64, chapter: u32, slot: u32) -> u64 {
    90_000_000 + story * 10_000 + chapter as u64 * 100 + slot as u64
}

pub struct MockRatedSource {
    capabilities: SourceCapabilities,
}

impl Default for MockRatedSource {
    fn default() -> Self { Self::new() }
}

impl MockRatedSource {
    pub fn new() -> Self {
        MockRatedSource {
            capabilities: SourceCapabilities {
                id: SOURCE_ID.to_string(),
                name: "Rated Mock".to_string(),
                host: "rated.mock".to_string(),
                // Like ScribbleHub: blocks Tor exits, fine over a VPN.
                reach: Reachability { tor: false, direct: true },
                reaction: ReactionShape::StarRating { max: 5 },
                discussion: DiscussionShape::Reviews,
                chapter_comments: true,
                search: false,
                browse: false,
                author_listings: false,
                user_search: false,
                tag_listings: false,
                update_checks: true,
                login: false,
                sign_in: super::SignInShape::None,
                remote_bookmarks: false,
                subscriptions: false,
                collections: false,
                inbox: false,
                user_moderation: false,
                username_is_key: false,
                vocabulary: Vocabulary {
                    discussion_title: "Reviews".to_string(),
                    reaction_verb: "Rate this story".to_string(),
                    reply_verb: None,
                    rating_label: "Rating".to_string(),
                    site_short: "Mock".to_string(),
                    open_on_site: "Open on Rated Mock".to_string(),
                    copy_link: "Copy Rated Mock link".to_string(),
                    refresh: "Refresh from Rated Mock".to_string(),
                    subscribe_verb: None,
                },
            },
        }
    }

    pub fn story_url(id: u64) -> String {
        format!("{BASE_URL}/story/{id}")
    }

    fn story(external_id: &str) -> Result<&'static Story, AppError> {
        let id: u64 = external_id.parse().map_err(|_| AppError::InvalidWorkId(external_id.to_string()))?;
        STORIES.iter().find(|s| s.id == id)
            .ok_or_else(|| AppError::Http { kind: crate::client::FailureKind::Http { code: 404 },
                                            detail: format!("no mock story {id}") })
    }

    fn guard() -> Result<(), AppError> {
        if crate::mock_site::enabled() { Ok(()) } else { Err(AppError::NetworkDisabled) }
    }

    fn user(name: &str) -> AO3User {
        // Reviewers have no account row of their own yet (users from a
        // second source are a Phase 9a concern); guests are source-neutral.
        AO3User { source: SOURCE_ID.to_string(), id: format!("guest:{name}"), username: name.to_string(), profile_url: None, avatar_url: None }
    }

    fn prose(story: &Story, chapter: u32) -> Vec<ContentBlock> {
        let pool = crate::mock_site::data::PROSE;
        let start = (story.id as usize * 7 + chapter as usize * 3) % pool.len();
        (0..5).map(|i| ContentBlock::Paragraph {
            text: vec![InlineContent::Text { value: pool[(start + i) % pool.len()].to_string() }],
        }).collect()
    }

    fn summary(story: &Story) -> WorkSummary {
        WorkSummary {
            id: 0,
            source: SOURCE_ID.to_string(),
            external_id: story.id.to_string(),
            url: Self::story_url(story.id),
            title: story.title.to_string(),
            authors: vec![story.author.to_string()],
            fandoms: vec!["Original Work".to_string()],
            rating: Rating::NotRated,
            warnings: Vec::new(),
            categories: Vec::new(),
            relationships: Vec::new(),
            characters: Vec::new(),
            tags: story.genres.iter().map(|g| g.to_string()).collect(),
            summary: story.summary.to_string(),
            word_count: Some(story.words),
            chapter_count: story.chapters,
            total_chapters: if story.complete { Some(story.chapters) } else { None },
            kudos: None,
            hits: None,
            bookmarks: None,
            comments: None,
            date_published: story.published.to_string(),
            date_updated: story.updated.to_string(),
            language: "English".to_string(),
            complete: story.complete,
            series: Vec::new(),
            fetched_at: crate::timefmt::now_utc_datetime(),
            author_ids: Vec::new(),
        }
    }

    fn review(story: &Story, slot: u32) -> Comment {
        let who = REVIEWERS[slot as usize % REVIEWERS.len()];
        let stars = [5u8, 3, 4, 4][slot as usize % 4];
        Comment {
            id: comment_id(story.id, 0, slot),
            author: Self::user(who),
            posted_at: format!("2026-10-{:02}", 2 + slot * 5),
            content: vec![ContentBlock::Paragraph {
                text: vec![InlineContent::Text { value: REVIEW_TEXT[slot as usize % REVIEW_TEXT.len()].to_string() }],
            }],
            replies: Vec::new(),
            chapter_label: None,
            chapter_id: None,
            notice: None,
            more_replies: 0,
            rating: Some(stars),
        }
    }

    fn chapter_comment(story: &Story, chapter: u32, slot: u32) -> Comment {
        let who = REVIEWERS[(slot as usize + chapter as usize) % REVIEWERS.len()];
        Comment {
            id: comment_id(story.id, chapter, slot),
            author: Self::user(who),
            posted_at: format!("2026-10-{:02}", 10 + chapter * 2 + slot),
            content: vec![ContentBlock::Paragraph {
                text: vec![InlineContent::Text { value: CHAPTER_COMMENT_TEXT[slot as usize % CHAPTER_COMMENT_TEXT.len()].to_string() }],
            }],
            replies: Vec::new(),
            chapter_label: Some(format!("Chapter {chapter}")),
            chapter_id: Some(chapter as u64),
            notice: None,
            more_replies: 0,
            rating: None,
        }
    }
}

#[async_trait]
impl Source for MockRatedSource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let rest = input.strip_prefix(BASE_URL)?.strip_prefix("/story/")?;
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() { return None }
        Some(ExternalRef { source: SOURCE_ID.to_string(), external_id: digits.clone(), url: Self::story_url(digits.parse().ok()?) })
    }

    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        Self::guard()?;
        let story = Self::story(&work.external_id)?;
        let chapters = (1..=story.chapters).map(|n| Chapter {
            id: Some(n as u64),
            title: Some(format!("Chapter {n}")),
            number: n,
            content: Self::prose(story, n),
            notes_before: None,
            notes_after: None,
        }).collect();
        let stats = vec![
            SourceStat::num("rating", "Rating", story.rating_avg, 1),
            SourceStat::num("rating_count", "Ratings", story.rating_count as f64, 2),
            SourceStat::num("views", "Views", story.views as f64, 3),
            SourceStat::num("favorites", "Favorites", story.favorites as f64, 4),
        ];
        Ok(FetchedWork { summary: Self::summary(story), chapters, stats, reacted_by: Vec::new(), authors: Vec::new() })
    }

    /// No login to speak of: the mock rates for anyone, so the star
    /// control is exercised offline.
    fn reaction_gate(&self, _signed_in: bool) -> Gate {
        Gate::Enabled
    }

    /// Accepts any star value in range and any clear; kudos is not a shape
    /// here. Nothing is remembered site-side — the library row holds the
    /// reader's value.
    async fn react(&self, work: &ExternalRef, reaction: Reaction) -> Result<ReactionOutcome, AppError> {
        Self::guard()?;
        Self::story(&work.external_id)?;
        match reaction {
            Reaction::Stars { value } if (1..=5).contains(&value) => Ok(ReactionOutcome { accepted: true, value: Some(value) }),
            Reaction::Stars { .. } => Ok(ReactionOutcome { accepted: false, value: None }),
            Reaction::Clear => Ok(ReactionOutcome { accepted: true, value: None }),
            Reaction::Kudos => Err(AppError::NetworkError("Rated Mock has ratings, not kudos".to_string())),
        }
    }

    async fn fetch_discussion(&self, work: &ExternalRef, chapter: Option<u64>, _page: u32)
        -> Result<CommentsPage, AppError>
    {
        Self::guard()?;
        let story = Self::story(&work.external_id)?;
        let comments = match chapter {
            None => (0..3).map(|slot| Self::review(story, slot)).collect(),
            Some(ch) if ch >= 1 && ch <= story.chapters as u64 =>
                (0..2).map(|slot| Self::chapter_comment(story, ch as u32, slot)).collect(),
            Some(_) => Vec::new(),
        };
        Ok(CommentsPage { comments, current_page: 1, total_pages: 1 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn story_ref(id: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: id.to_string(), url: MockRatedSource::story_url(id.parse().unwrap()) }
    }

    #[tokio::test]
    async fn fetches_a_story_with_stats_and_reviews() {
        let _g = crate::mock_site::tests::toggle_lock();
        let src = MockRatedSource::new();
        crate::mock_site::set_enabled(true);
        let work = src.fetch_work(&story_ref("1"), None).await;
        let reviews = src.fetch_discussion(&story_ref("1"), None, 1).await;
        let chapter = src.fetch_discussion(&story_ref("1"), Some(2), 1).await;
        crate::mock_site::set_enabled(false);
        let work = work.unwrap();
        assert_eq!(work.summary.source, SOURCE_ID);
        assert_eq!(work.summary.title, "The Cartographer's Apprentice");
        assert_eq!(work.chapters.len(), 4);
        assert!(work.summary.kudos.is_none(), "a rated source has no kudos");
        let rating = work.stats.iter().find(|s| s.key == "rating").unwrap();
        assert_eq!(rating.num, Some(4.6));
        let reviews = reviews.unwrap();
        assert_eq!(reviews.comments.len(), 3);
        assert!(reviews.comments.iter().all(|c| c.rating.is_some()));
        let chapter = chapter.unwrap();
        assert_eq!(chapter.comments.len(), 2);
        assert!(chapter.comments.iter().all(|c| c.rating.is_none()));
    }

    #[tokio::test]
    async fn refuses_outside_the_mock() {
        let _g = crate::mock_site::tests::toggle_lock();
        let src = MockRatedSource::new();
        assert!(matches!(src.fetch_work(&story_ref("1"), None).await, Err(AppError::NetworkDisabled)));
    }

    #[tokio::test]
    async fn rates_and_clears_while_on() {
        let _g = crate::mock_site::tests::toggle_lock();
        let src = MockRatedSource::new();
        crate::mock_site::set_enabled(true);
        let four = src.react(&story_ref("1"), Reaction::Stars { value: 4 }).await;
        let six = src.react(&story_ref("1"), Reaction::Stars { value: 6 }).await;
        let clear = src.react(&story_ref("1"), Reaction::Clear).await;
        let kudos = src.react(&story_ref("1"), Reaction::Kudos).await;
        crate::mock_site::set_enabled(false);
        assert_eq!(four.unwrap(), ReactionOutcome { accepted: true, value: Some(4) });
        assert_eq!(six.unwrap(), ReactionOutcome { accepted: false, value: None });
        assert_eq!(clear.unwrap(), ReactionOutcome { accepted: true, value: None });
        assert!(kudos.is_err());
    }

    #[test]
    fn resolves_its_own_links_only() {
        let src = MockRatedSource::new();
        assert_eq!(src.resolve("https://rated.mock/story/2").unwrap().external_id, "2");
        assert!(src.resolve("https://rated.mock/author/x").is_none());
        assert!(src.resolve("https://archiveofourown.org/works/2").is_none());
    }
}
