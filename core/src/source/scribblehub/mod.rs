//! ScribbleHub (multi-source plan Phase 9a): the first real second
//! source. Original fiction with 1–5 star ratings, flat rated reviews on
//! the story and threaded comments on each chapter; blocks Tor exits, so
//! it is reachable only through the direct (VPN / Open) transport.
//!
//! Fetch plan — a series page is the work: record, stats, the newest 15
//! TOC rows and the first page of reviews. Further TOC pages come from
//! the site's releases endpoint (the same POST its own pager makes).
//! Chapters are one page each and are fetched on demand, so a work
//! lands as stubs (id + title per chapter) and the reader fills them in
//! one at a time; a 79-chapter story never costs 79 requests up front.
//! Field mapping and the open verification items are in
//! design/scribblehub-adapter-plan.md.

pub mod parse;

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::RwLock;

use crate::client::{AO3Client, SiteHooks};
use crate::error::AppError;
use crate::models::{Chapter, CommentsPage, ExternalRef, WorkSummary};

use super::{DiscussionShape, FetchedWork, ListingPage, ReactionShape, Reachability, Source, SourceCapabilities, SourceStat,
            Vocabulary};

pub const SOURCE_ID: &str = "scribblehub";
pub const BASE_URL: &str = "https://www.scribblehub.com";
const RELEASES_ENDPOINT: &str = "https://www.scribblehub.com/wp-admin/admin-ajax.php";

/// The site has none of AO3's page quirks: nothing to harvest or strip,
/// no session-expiry redirect to recognise (reads are public).
struct Hooks;

impl SiteHooks for Hooks {
    fn source(&self) -> &'static str { SOURCE_ID }
    fn user_agent(&self) -> Option<String> { crate::client::clearance::user_agent(SOURCE_ID) }
}

static HOOKS: Hooks = Hooks;

pub struct ScribbleHubSource {
    client: Arc<RwLock<AO3Client>>,
    capabilities: SourceCapabilities,
}

impl ScribbleHubSource {
    pub fn new(client: Arc<RwLock<AO3Client>>) -> Self {
        ScribbleHubSource { client, capabilities: Self::declare() }
    }

    fn declare() -> SourceCapabilities {
        SourceCapabilities {
            id: SOURCE_ID.to_string(),
            name: "ScribbleHub".to_string(),
            reach: Reachability { tor: false, direct: true },
            reaction: ReactionShape::StarRating { max: 5 },
            discussion: DiscussionShape::Reviews,
            chapter_comments: true,
            search: false,
            browse: false,
            author_listings: true,
            user_search: true,
            tag_listings: false,
            // Phase 7 wires the update check; the adapter can already
            // compare TOCs, so the capability is declared.
            update_checks: true,
            // Reads are public; writing a rating or review is Phase 9b.
            login: false,
            remote_bookmarks: false,
            subscriptions: false,
            collections: false,
            inbox: false,
            vocabulary: Vocabulary {
                discussion_title: "Reviews".to_string(),
                reaction_verb: "Rate this story".to_string(),
                reply_verb: None,
                rating_label: "Rating".to_string(),
            },
        }
    }

    // -- URLs ---------------------------------------------------------------

    pub fn series_url(id: &str, slug: &str) -> String {
        if slug.is_empty() { format!("{BASE_URL}/series/{id}/") } else { format!("{BASE_URL}/series/{id}/{slug}/") }
    }

    /// The story's statistics page (`Statistics` in its nav): no trailing
    /// slash, as the site links it.
    pub fn stats_url(id: &str, slug: &str) -> String {
        format!("{}stats", Self::series_url(id, slug))
    }

    pub fn read_url(id: &str, slug: &str, chapter_id: u64) -> String {
        if slug.is_empty() { format!("{BASE_URL}/read/{id}/chapter/{chapter_id}/") }
        else { format!("{BASE_URL}/read/{id}-{slug}/chapter/{chapter_id}/") }
    }

    /// The slug in a stored series URL ("…/series/700412/the-slug/" →
    /// "the-slug"); "" when the URL carries none.
    fn slug_of(url: &str) -> String {
        url.split("/series/").nth(1)
            .and_then(|rest| rest.split('/').nth(1))
            .map(|s| s.split(['?', '#']).next().unwrap_or("").to_string())
            .unwrap_or_default()
    }

    /// The site path of a link, with scheme and host stripped — None for
    /// any other host.
    fn site_path(input: &str) -> Option<&str> {
        let rest = input.strip_prefix("https://").or_else(|| input.strip_prefix("http://")).unwrap_or(input);
        let rest = rest.strip_prefix("www.").unwrap_or(rest);
        rest.strip_prefix("scribblehub.com/")
    }

    fn digits_then(s: &str) -> (&str, &str) {
        let n = s.chars().take_while(|c| c.is_ascii_digit()).count();
        s.split_at(n)
    }

    // -- Requests -------------------------------------------------------------

    fn guard() -> Result<(), AppError> {
        // The mock archive stands in for the network; nothing real goes out
        // while it is on, and this source has no mock of its own.
        if crate::mock_site::enabled() {
            return Err(AppError::NetworkError("ScribbleHub is not served by the mock archive".to_string()));
        }
        Ok(())
    }

    async fn page(&self, url: &str) -> Result<String, AppError> {
        Self::guard()?;
        let client = self.client.read().await;
        let timeout = client.timeout_for_url(url);
        client.transport().get_page(url, timeout, false, &HOOKS).await
    }

    /// One page of TOC rows beyond the first, from the releases endpoint
    /// the site's own pager calls.
    async fn toc_page(&self, id: &str, page: u32) -> Result<String, AppError> {
        Self::guard()?;
        let form = [
            ("action".to_string(), "wi_getreleases_pagination".to_string()),
            ("pagenum".to_string(), page.to_string()),
            ("mypostid".to_string(), id.to_string()),
        ];
        let client = self.client.read().await;
        let out = client.transport().post_form(
            RELEASES_ENDPOINT, &form, &[("X-Requested-With", "XMLHttpRequest")],
            &|status, _| status < 400, &HOOKS).await?;
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: crate::client::FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} from the releases endpoint (TOC page {page})", out.status),
            });
        }
        Ok(out.body)
    }

    fn stats_of(page: &parse::SeriesPage) -> Vec<SourceStat> {
        let mut stats = Vec::new();
        if let Some(avg) = page.rating_avg { stats.push(SourceStat::num("rating", "Rating", avg, 1)); }
        if let Some(n) = page.rating_count { stats.push(SourceStat::num("rating_count", "Ratings", n as f64, 2)); }
        if let Some(n) = page.views { stats.push(SourceStat::num("views", "Views", n as f64, 3)); }
        if let Some(n) = page.favorites { stats.push(SourceStat::num("favorites", "Favorites", n as f64, 4)); }
        if let Some(n) = page.readers { stats.push(SourceStat::num("readers", "Readers", n as f64, 5)); }
        if !page.status.is_empty() {
            stats.push(SourceStat { key: "status".into(), label: "Status".into(), num: None, text: Some(page.status.clone()), order: 6 });
        }
        if !page.content_warnings.is_empty() {
            stats.push(SourceStat { key: "content_warnings".into(), label: "Content warnings".into(), num: None,
                                    text: Some(page.content_warnings.join(", ")), order: 7 });
        }
        stats
    }
}

#[async_trait]
impl Source for ScribbleHubSource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn fetches_chapters_individually(&self) -> bool { true }

    /// Series pages (`/series/{id}/{slug}/`) and chapter pages
    /// (`/read/{id}-{slug}/chapter/{n}/`) both name the story.
    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        let (id, slug) = if let Some(rest) = path.strip_prefix("series/") {
            let (id, after) = Self::digits_then(rest);
            if id.is_empty() || !matches!(after.chars().next(), None | Some('/') | Some('?') | Some('#')) { return None }
            let slug = after.strip_prefix('/').map(|s| s.split(['/', '?', '#']).next().unwrap_or("")).unwrap_or("");
            (id, slug)
        } else if let Some(rest) = path.strip_prefix("read/") {
            let (id, after) = Self::digits_then(rest);
            if id.is_empty() { return None }
            let slug = match after.chars().next() {
                Some('-') => after[1..].split(['/', '?', '#']).next().unwrap_or(""),
                Some('/') => "",
                _ => return None,
            };
            (id, slug)
        } else {
            return None;
        };
        Some(ExternalRef { source: SOURCE_ID.to_string(), external_id: id.to_string(), url: Self::series_url(id, slug) })
    }

    /// Profile pages: `/profile/{id}/{slug}/`.
    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        let rest = path.strip_prefix("profile/")?;
        let (id, after) = Self::digits_then(rest);
        if id.is_empty() || !matches!(after.chars().next(), None | Some('/') | Some('?') | Some('#')) { return None }
        let slug = after.strip_prefix('/').map(|s| s.split(['/', '?', '#']).next().unwrap_or("")).unwrap_or("");
        let url = if slug.is_empty() { format!("{BASE_URL}/profile/{id}/") } else { format!("{BASE_URL}/profile/{id}/{slug}/") };
        Some(ExternalRef { source: SOURCE_ID.to_string(), external_id: id.to_string(), url })
    }

    async fn fetch_work(&self, work: &ExternalRef, known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        let id = work.external_id.as_str();
        let url = if work.url.contains("/series/") { work.url.clone() } else { Self::series_url(id, "") };
        let html = self.page(&url).await?;
        let page = parse::parse_series_page(&html, id)?;
        let mut toc = page.toc.clone();
        for n in 2..=page.toc_pages {
            toc.extend(parse::parse_toc_fragment(&self.toc_page(id, n).await?));
        }
        toc.sort_by_key(|t| t.chapter_id);
        toc.dedup_by_key(|t| t.chapter_id);
        if toc.iter().any(|t| t.number == 0) {
            // No order attribute: number by id, which the site assigns in
            // posting order.
            for (i, t) in toc.iter_mut().enumerate() { t.number = i as u32 + 1; }
        }
        toc.sort_by_key(|t| t.number);
        let mut summary = page.summary.clone();
        if !toc.is_empty() {
            summary.chapter_count = toc.len() as u32;
            if summary.complete { summary.total_chapters = Some(summary.chapter_count); }
            if let Some(oldest) = toc.iter().map(|t| t.date.as_str()).filter(|d| !d.is_empty()).min() {
                summary.date_published = oldest.to_string();
            }
            if summary.date_updated.is_empty() {
                if let Some(newest) = toc.iter().map(|t| t.date.as_str()).max() { summary.date_updated = newest.to_string(); }
            }
        }
        let mut stats = Self::stats_of(&page);
        // The series page never reports a word count. A count the library
        // already holds (from the author's series list) is kept; only a
        // work with none costs the extra stats-page request.
        if summary.word_count.is_none() {
            summary.word_count = known.and_then(|k| k.word_count);
        }
        if summary.word_count.is_none() {
            let slug = Self::slug_of(&page.canonical_url);
            let slug = if slug.is_empty() { Self::slug_of(&work.url) } else { slug };
            match self.page(&Self::stats_url(id, &slug)).await {
                Ok(html) => {
                    let extra = parse::parse_stats_page(&html);
                    summary.word_count = extra.word_count;
                    if let Some(exact) = extra.views {
                        // Exact total, replacing the strip's abbreviated figure.
                        stats.retain(|s| s.key != "views");
                        stats.push(SourceStat::num("views", "Views", exact as f64, 3));
                    }
                }
                // A story without its stats page is still a story.
                Err(e) => { log_info!("scribblehub", "stats page for {id} skipped: {e}"); }
            }
        }
        let chapters = toc.iter().map(parse::stub_chapter).collect();
        Ok(FetchedWork { summary, chapters, stats, reacted_by: Vec::new(), authors: page.author.iter().cloned().collect() })
    }

    /// One page of the author's series list — the profile's Series tab,
    /// which the site fills by POSTing `wi_perseries` to admin-ajax with
    /// the profile id (`intAuthorID`) and page (`pagenum`); `isMobile` and
    /// `str_isapp` are the desktop web page's values.
    async fn fetch_author_works(&self, author: &ExternalRef, page: u32) -> Result<ListingPage, AppError> {
        Self::guard()?;
        let form = [
            ("action".to_string(), "wi_perseries".to_string()),
            ("pagenum".to_string(), page.to_string()),
            ("intAuthorID".to_string(), author.external_id.clone()),
            ("isMobile".to_string(), "0".to_string()),
            ("str_isapp".to_string(), String::new()),
        ];
        let client = self.client.read().await;
        let out = client.transport().post_form(
            RELEASES_ENDPOINT, &form, &[("X-Requested-With", "XMLHttpRequest")],
            &|status, _| status < 400, &HOOKS).await?;
        drop(client);
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: crate::client::FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} from the series-list endpoint (page {page})", out.status),
            });
        }
        let mut listing = parse::parse_profile_series(&out.body);
        listing.has_next = page < listing.total_pages;
        Ok(listing)
    }

    /// The site header's live search in users mode: POST admin-ajax
    /// `wi_ajaxsearchmain` with `strOne` (the text) and `strType=users`
    /// (from fic_wi_all.js `showSearch`, which also skips queries under two
    /// characters). The reply is an HTML fragment with a trailing "0".
    async fn search_users(&self, query: &str) -> Result<Vec<crate::models::AO3User>, AppError> {
        Self::guard()?;
        let text = query.trim();
        if text.chars().count() < 2 { return Ok(Vec::new()) }
        let form = [
            ("action".to_string(), "wi_ajaxsearchmain".to_string()),
            ("strOne".to_string(), text.to_string()),
            ("strType".to_string(), "users".to_string()),
        ];
        let client = self.client.read().await;
        let out = client.transport().post_form(
            RELEASES_ENDPOINT, &form, &[("X-Requested-With", "XMLHttpRequest")],
            &|status, _| status < 400, &HOOKS).await?;
        drop(client);
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: crate::client::FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} from the search endpoint", out.status),
            });
        }
        Ok(parse::parse_user_search(&out.body))
    }

    /// The author's profile page, by the URL recorded with the work (the
    /// site accepts `/profile/{id}/` without the slug too).
    async fn fetch_author(&self, author: &ExternalRef) -> Result<crate::models::SourceUserProfile, AppError> {
        let url = if author.url.is_empty() { format!("{BASE_URL}/profile/{}/", author.external_id) } else { author.url.clone() };
        let html = self.page(&url).await?;
        parse::parse_profile_page(&html, &author.external_id)
    }

    async fn fetch_chapter(&self, work: &ExternalRef, chapter: &Chapter) -> Result<Chapter, AppError> {
        let chapter_id = chapter.id
            .ok_or_else(|| AppError::ElementNotFound(format!("chapter {} of story {} has no id", chapter.number, work.external_id)))?;
        let url = Self::read_url(&work.external_id, &Self::slug_of(&work.url), chapter_id);
        let html = self.page(&url).await?;
        let page = parse::parse_chapter_page(&html, chapter_id)?;
        Ok(Chapter {
            id: Some(chapter_id),
            title: if page.title.is_empty() { chapter.title.clone() } else { Some(page.title) },
            number: chapter.number,
            content: page.content,
            notes_before: None,
            notes_after: page.notes_after,
        })
    }

    /// Reviews on the story (`chapter` None) or a chapter's comments. Page
    /// 1 is the page itself; later pages use the pager's own query
    /// (`?rp=` / `?gb=`), see the adapter plan for its verification state.
    async fn fetch_discussion(&self, work: &ExternalRef, chapter: Option<u64>, page: u32)
        -> Result<CommentsPage, AppError>
    {
        let id = work.external_id.as_str();
        let slug = Self::slug_of(&work.url);
        match chapter {
            None => {
                let mut url = Self::series_url(id, &slug);
                if page > 1 { url.push_str(&format!("?rp={page}")); }
                let html = self.page(&url).await?;
                let doc = scraper::Html::parse_document(&html);
                let comments = parse::parse_reviews(&doc, &url);
                Ok(CommentsPage { comments, current_page: page.max(1), total_pages: parse::pagination_items(&html, "pagination-mesh-reviews") })
            }
            Some(chapter_id) => {
                let mut url = Self::read_url(id, &slug, chapter_id);
                if page > 1 { url.push_str(&format!("?gb={page}")); }
                let html = self.page(&url).await?;
                let parsed = parse::parse_chapter_page(&html, chapter_id)?;
                Ok(CommentsPage { comments: parsed.comments, current_page: page.max(1), total_pages: parsed.comment_pages })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn source() -> ScribbleHubSource {
        // A direct client is a reqwest handle; nothing is sent in these tests.
        let client = Arc::new(RwLock::new(AO3Client::new_direct().await.unwrap()));
        ScribbleHubSource::new(client)
    }

    #[tokio::test]
    async fn resolves_series_and_chapter_links() {
        let s = source().await;
        let r = s.resolve("https://www.scribblehub.com/series/700412/the-lighthouse-ledger/").unwrap();
        assert_eq!((r.source.as_str(), r.external_id.as_str()), (SOURCE_ID, "700412"));
        assert_eq!(r.url, "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/");
        let r = s.resolve("scribblehub.com/read/700412-the-lighthouse-ledger/chapter/2300107/?cid=1").unwrap();
        assert_eq!(r.external_id, "700412");
        assert_eq!(r.url, "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/");
        assert_eq!(s.resolve("https://www.scribblehub.com/series/700412").unwrap().url, "https://www.scribblehub.com/series/700412/");
        assert!(s.resolve("https://www.scribblehub.com/profile/51230/quill_and_tide/").is_none());
        assert!(s.resolve("https://www.scribblehub.com/series/abc/").is_none());
        assert!(s.resolve("https://archiveofourown.org/works/700412").is_none());
        assert!(s.resolve("https://rated.mock/story/1").is_none());
    }

    #[test]
    fn urls_round_trip_the_slug() {
        let slug = ScribbleHubSource::slug_of("https://www.scribblehub.com/series/700412/the-lighthouse-ledger/");
        assert_eq!(slug, "the-lighthouse-ledger");
        assert_eq!(ScribbleHubSource::read_url("700412", &slug, 2300107),
                   "https://www.scribblehub.com/read/700412-the-lighthouse-ledger/chapter/2300107/");
        assert_eq!(ScribbleHubSource::slug_of("https://www.scribblehub.com/series/700412/"), "");
        assert_eq!(ScribbleHubSource::read_url("700412", "", 5), "https://www.scribblehub.com/read/700412/chapter/5/");
        assert_eq!(ScribbleHubSource::stats_url("700412", &slug), "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/stats");
    }

    #[tokio::test]
    async fn declares_the_rated_shapes_and_no_tor() {
        let s = source().await;
        let caps = s.capabilities().clone();
        assert_eq!(caps.reaction, ReactionShape::StarRating { max: 5 });
        assert_eq!(caps.discussion, DiscussionShape::Reviews);
        assert!(caps.chapter_comments);
        assert!(!caps.reach.tor && caps.reach.direct);
        assert!(s.fetches_chapters_individually());
    }

    #[tokio::test]
    async fn refuses_while_the_mock_archive_is_on() {
        let s = source().await;
        crate::mock_site::set_enabled(true);
        let r = s.fetch_work(&ExternalRef { source: SOURCE_ID.into(), external_id: "1".into(), url: String::new() }, None).await;
        crate::mock_site::set_enabled(false);
        assert!(matches!(r, Err(AppError::NetworkError(_))));
    }
}
