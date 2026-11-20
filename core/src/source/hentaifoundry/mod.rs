//! Hentai Foundry: stories only (the site is mainly an art gallery; its
//! pictures are not this app's business). Plan, survey results and the
//! decisions behind every rule here: design/hentaifoundry-adapter-plan.md.
//!
//! Rules of this source:
//! - **Signed in or nothing.** A signed-out session is shown a filtered
//!   site (whole kinds of content hidden by default), so listings would be
//!   silently incomplete. Every fetch needs the account's session; without
//!   one the request is refused before it is sent.
//! - **The account's own settings stand.** What the site shows, and in
//!   what order, follows the content filters and sort saved in the
//!   reader's account. This adapter never posts the site's filter form.
//! - **No discussion.** Comments are neither read nor posted (posting
//!   needs a captcha only a browser can answer).
//! - The site's automatic visitor check is answered here (`check`), and
//!   its age page is passed on the reader's behalf.
//!
//! Fetch plan — a story page is the work: its record and its chapter
//! list. Chapters are one page each, fetched on demand, so a work lands
//! as stubs the reader fills in.

pub mod check;
pub mod parse;
pub mod search;

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::RwLock;

use crate::client::{FailureKind, SiteHooks};
use crate::error::AppError;
use crate::models::{Chapter, ExternalRef, WorkSummary};
use crate::source::ao3::AO3Client;

use super::{DiscussionShape, FetchedWork, LinkTarget, ListingPage, ReactionShape, Reachability, Source, SourceCapabilities,
            UserPane, Vocabulary};

pub const SOURCE_ID: &str = "hentaifoundry";
pub const BASE_URL: &str = "https://www.hentai-foundry.com";
const NAME: &str = "Hentai Foundry";

/// The site's "remember me" cookie is named by a 32-digit hex string of
/// its own configuration; it is told by that shape.
pub fn is_login_cookie(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The login cookie and the PHP session that holds the signed-in state.
pub fn is_session_cookie(name: &str) -> bool {
    is_login_cookie(name) || name == "PHPSESSID"
}

struct Hooks;

impl SiteHooks for Hooks {
    fn source(&self) -> &'static str { SOURCE_ID }
}

static HOOKS: Hooks = Hooks;

/// Whether a page may be asked for without the account's session: only
/// the sign-in itself.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Access {
    SignedIn,
    Open,
}

pub struct HentaiFoundrySource {
    client: Arc<RwLock<AO3Client>>,
    capabilities: SourceCapabilities,
}

impl HentaiFoundrySource {
    pub fn new(client: Arc<RwLock<AO3Client>>) -> Self {
        HentaiFoundrySource { client, capabilities: Self::declare() }
    }

    fn declare() -> SourceCapabilities {
        SourceCapabilities {
            id: SOURCE_ID.to_string(),
            name: NAME.to_string(),
            host: "www.hentai-foundry.com".to_string(),
            // Tor is untested against this site; it is not tried until it
            // has been.
            reach: Reachability { tor: false, direct: true },
            reaction: ReactionShape::None,
            discussion: DiscussionShape::None,
            chapter_comments: false,
            search: true,
            browse: false,
            author_listings: true,
            user_search: true,
            tag_listings: false,
            update_checks: true,
            discussion_posts: false,
            login: true,
            sign_in: super::SignInShape::Credentials,
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
                rating_label: "Votes".to_string(),
                site_short: "HF".to_string(),
                open_on_site: "Open on Hentai Foundry".to_string(),
                copy_link: "Copy Hentai Foundry link".to_string(),
                refresh: "Refresh from Hentai Foundry".to_string(),
                subscribe_verb: None,
            },
        }
    }

    // -- URLs ---------------------------------------------------------------

    pub fn story_url(user: &str, id: &str, slug: &str) -> String {
        if slug.is_empty() { format!("{BASE_URL}/stories/user/{user}/{id}") }
        else { format!("{BASE_URL}/stories/user/{user}/{id}/{slug}") }
    }

    /// A story by its id alone: the site sends this on to the story's
    /// full address.
    fn story_url_by_id(id: &str) -> String {
        format!("{BASE_URL}/stories/{id}")
    }

    pub fn profile_url(user: &str) -> String {
        format!("{BASE_URL}/user/{user}/profile")
    }

    /// A chapter's page. The site finds the chapter by the two ids and
    /// sends the reader on to its full address, so the trailing title
    /// segment need not be known.
    fn chapter_url(story_url: &str, chapter_id: u64, number: u32) -> String {
        format!("{story_url}/{chapter_id}/Chapter-{number}/x")
    }

    /// The story's own page for a stored reference: its recorded address,
    /// or the by-id form when the reference carries no more than the id.
    fn story_page_url(work: &ExternalRef) -> String {
        match Self::site_path(&work.url).and_then(|p| parse::story_path(p)) {
            Some((user, id, slug, _)) => Self::story_url(user, id, slug),
            None => Self::story_url_by_id(&work.external_id),
        }
    }

    /// The path of a link on this site (`/stories/user/…`), without query
    /// or fragment — None for any other host.
    fn site_path(input: &str) -> Option<&str> {
        let rest = input.strip_prefix("https://").or_else(|| input.strip_prefix("http://")).unwrap_or(input);
        let rest = rest.strip_prefix("www.").unwrap_or(rest);
        let rest = rest.strip_prefix("hentai-foundry.com")?;
        let path = rest.split(['?', '#']).next().unwrap_or("");
        if path.is_empty() { Some("/") } else if path.starts_with('/') { Some(path) } else { None }
    }

    fn work_of(user: &str, id: &str, slug: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: id.to_string(), url: Self::story_url(user, id, slug) }
    }

    fn user_of(name: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: name.to_string(), url: Self::profile_url(name) }
    }

    /// `/user/{name}[/profile]` and `/stories/user/{name}[/page/N]` name a
    /// user; which of their pages is the second value.
    fn user_in(path: &str) -> Option<(&str, UserPane)> {
        let valid = |name: &str| !name.is_empty() && !name.contains('.');
        if let Some(rest) = path.strip_prefix("/user/") {
            let mut parts = rest.split('/');
            let name = parts.next().filter(|n| valid(n))?;
            return match parts.next() {
                None | Some("") | Some("profile") => Some((name, UserPane::Profile)),
                _ => None,
            };
        }
        let rest = path.strip_prefix("/stories/user/")?;
        let mut parts = rest.split('/');
        let name = parts.next().filter(|n| valid(n))?;
        match parts.next() {
            None | Some("") | Some("page") => Some((name, UserPane::Works)),
            _ => None,
        }
    }

    // -- Requests -------------------------------------------------------------

    fn guard() -> Result<(), AppError> {
        // The mock archive stands in for the network; nothing real goes out
        // while it is on, and this source has no mock of its own.
        if crate::mock_site::enabled() {
            return Err(AppError::NetworkError(format!("{NAME} is not served by the mock archive")));
        }
        Ok(())
    }

    async fn has_session(&self) -> bool {
        let client = self.client.read().await;
        super::session_logged_in(SOURCE_ID, &client.transport().cookies_for(BASE_URL))
    }

    /// The page's address with the age page's own "Enter" answer on it.
    fn entering(url: &str) -> String {
        let (base, fragment) = url.split_once('#').map(|(b, f)| (b, Some(f))).unwrap_or((url, None));
        let mut out = format!("{base}{}enterAgree=1", if base.contains('?') { '&' } else { '?' });
        if let Some(f) = fragment { out.push('#'); out.push_str(f); }
        out
    }

    /// Answer the site's visitor check for `url` and return the page the
    /// check then sends the visitor on to. The check page is asked for
    /// again here: a challenge is single-use and the first response's
    /// body is not kept by the page fetch.
    async fn pass_check(&self, url: &str) -> Result<String, AppError> {
        let client = self.client.read().await;
        let asked = client.transport().get_outcome(url, &[], &|status| status == 401 || status < 400, &HOOKS).await?;
        let Some(challenge) = check::parse_challenge(&asked.body) else {
            if asked.status < 400 { return Ok(asked.body) }
            return Err(AppError::Http {
                kind: FailureKind::from_status(asked.status, None),
                detail: format!("HTTP {} for {url}", asked.status),
            });
        };
        if !check::supported(&challenge) {
            return Err(AppError::NetworkError(format!(
                "{NAME}'s visitor check asked for something this app cannot do ({}, difficulty {}).",
                challenge.algorithm, challenge.difficulty)));
        }
        let started = std::time::Instant::now();
        let work = challenge.clone();
        let answer = tokio::task::spawn_blocking(move || check::solve(&work)).await
            .map_err(|e| AppError::NetworkError(format!("{NAME}'s visitor check could not be worked: {e}")))?;
        let elapsed = (started.elapsed().as_millis() as u64).max(1);
        log_info!("hentaifoundry", "visitor check answered (difficulty {}, {} ms)", challenge.difficulty, elapsed);
        let pass = check::pass_url(BASE_URL, &challenge, &answer, url, elapsed);
        let passed = client.transport().get_outcome(&pass, &[("Referer", url)], &|status| status < 400, &HOOKS).await?;
        if passed.status >= 400 || check::parse_challenge(&passed.body).is_some() {
            return Err(AppError::NetworkError(format!("{NAME}'s visitor check did not accept the answer (HTTP {}).", passed.status)));
        }
        Ok(passed.body)
    }

    /// One page of the site, through everything that can stand in front
    /// of it: the visitor check (a 401, answered once), the age page
    /// (answered once), and — for all but the sign-in itself — the
    /// account's session, without which nothing is asked for.
    async fn page(&self, url: &str, access: Access) -> Result<String, AppError> {
        let html = self.answer(url, access).await?;
        if access == Access::SignedIn && !html.contains("/site/logout") {
            return Err(AppError::NetworkError(format!("Your {NAME} sign-in has expired. Sign in again.")));
        }
        Ok(html)
    }

    /// What the site answers for `url` once the visitor check and the age
    /// page are out of the way. Not every answer is a page (the username
    /// lookup answers a bare list), so the signed-in marker is `page`'s
    /// to look for, not this one's.
    async fn answer(&self, url: &str, access: Access) -> Result<String, AppError> {
        Self::guard()?;
        if access == Access::SignedIn && !self.has_session().await {
            return Err(AppError::NetworkError(format!("Sign in to {NAME} to use it.")));
        }
        let mut url = url.to_string();
        let (mut checked, mut entered) = (false, false);
        let html = loop {
            let fetched = {
                let client = self.client.read().await;
                let timeout = client.timeout_for_url(&url);
                client.transport().get_page(&url, timeout, false, &HOOKS).await
            };
            let html = match fetched {
                Ok(html) => html,
                Err(AppError::Http { kind: FailureKind::Http { code: 401 }, .. }) if !checked => {
                    checked = true;
                    self.pass_check(&url).await?
                }
                Err(e) => return Err(e),
            };
            if parse::is_age_page(&html) {
                if entered {
                    return Err(AppError::NetworkError(format!("{NAME} kept showing its age page.")));
                }
                entered = true;
                url = Self::entering(&url);
                continue;
            }
            break html;
        };
        Ok(html)
    }
}

#[async_trait]
impl Source for HentaiFoundrySource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn fetches_chapters_individually(&self) -> bool { true }

    /// A story's page, any of its chapters' pages, its PDF link, and the
    /// short by-id form all name the story.
    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        if let Some((user, id, slug, _)) = parse::story_path(path) {
            return Some(Self::work_of(user, id, slug.strip_suffix(".pdf").unwrap_or(slug)));
        }
        let id = path.strip_prefix("/stories/")?.trim_end_matches('/');
        (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then(|| ExternalRef {
            source: SOURCE_ID.to_string(), external_id: id.to_string(), url: Self::story_url_by_id(id),
        })
    }

    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        Self::user_in(path).map(|(name, _)| Self::user_of(name))
    }

    fn classify(&self, input: &str) -> Option<LinkTarget> {
        let path = Self::site_path(input.trim())?;
        if let Some((user, id, slug, rest)) = parse::story_path(path) {
            let work = Self::work_of(user, id, slug.strip_suffix(".pdf").unwrap_or(slug));
            let chapter = rest.split('/').next().filter(|c| !c.is_empty() && c.bytes().all(|b| b.is_ascii_digit()));
            return Some(match chapter {
                Some(chapter_id) => LinkTarget::Chapter { work, chapter_id: chapter_id.to_string() },
                None => LinkTarget::Work { work, entire: false },
            });
        }
        if let Some(work) = self.resolve(input) {
            return Some(LinkTarget::Work { work, entire: false });
        }
        if let Some((name, pane)) = Self::user_in(path) {
            return Some(LinkTarget::User { user: Self::user_of(name), pane });
        }
        // Pictures, categories, the forum links: the site's, with no view here.
        Some(LinkTarget::Unsupported)
    }

    fn work_ref(&self, external_id: &str) -> Option<ExternalRef> {
        (!external_id.is_empty() && external_id.bytes().all(|b| b.is_ascii_digit())).then(|| ExternalRef {
            source: SOURCE_ID.to_string(), external_id: external_id.to_string(), url: Self::story_url_by_id(external_id),
        })
    }

    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        let html = self.page(&Self::story_page_url(work), Access::SignedIn).await?;
        let page = parse::parse_story_page(&html, &work.external_id)?;
        let mut summary = page.work.summary;
        if !page.chapters.is_empty() {
            summary.chapter_count = page.chapters.len() as u32;
            if summary.complete { summary.total_chapters = Some(summary.chapter_count); }
        }
        Ok(FetchedWork {
            summary,
            chapters: page.chapters.iter().map(parse::stub_chapter).collect(),
            stats: page.work.stats,
            reacted_by: Vec::new(),
            authors: page.work.authors,
        })
    }

    async fn fetch_chapter(&self, work: &ExternalRef, chapter: &Chapter) -> Result<Chapter, AppError> {
        let chapter_id = chapter.id
            .ok_or_else(|| AppError::ElementNotFound(format!("chapter {} of story {} has no id", chapter.number, work.external_id)))?;
        // Without the story's own address the site still finds the
        // chapter by the two ids.
        let story = match Self::site_path(&work.url).and_then(|p| parse::story_path(p)) {
            Some((user, id, slug, _)) if !slug.is_empty() => Self::story_url(user, id, slug),
            _ => Self::story_url("x", &work.external_id, "x"),
        };
        let html = self.page(&Self::chapter_url(&story, chapter_id, chapter.number), Access::SignedIn).await?;
        let page = parse::parse_chapter_page(&html)?;
        Ok(Chapter {
            id: Some(chapter_id),
            title: if page.title.is_empty() { chapter.title.clone() } else { Some(page.title) },
            number: chapter.number,
            content: page.content,
            notes_before: None,
            notes_after: None,
        })
    }

    /// One page of the author's stories, in the order the reader's
    /// account has saved.
    async fn fetch_author_works(&self, author: &ExternalRef, page: u32) -> Result<ListingPage, AppError> {
        let mut url = format!("{BASE_URL}/stories/user/{}", author.external_id);
        if page > 1 { url.push_str(&format!("/page/{page}")); }
        let html = self.page(&url, Access::SignedIn).await?;
        Ok(parse::parse_listing(&html))
    }

    async fn fetch_author(&self, author: &ExternalRef) -> Result<crate::models::SourceUserProfile, AppError> {
        let html = self.page(&Self::profile_url(&author.external_id), Access::SignedIn).await?;
        parse::parse_profile_page(&html, &author.external_id)
    }

    /// The lookup behind the search form's "Limit User" box: up to ten
    /// usernames starting with what was typed, the exact one first. A
    /// username is the user's key here, so a name is a whole hit.
    async fn search_users(&self, query: &str) -> Result<Vec<crate::models::AO3User>, AppError> {
        let text = query.trim();
        if text.is_empty() { return Ok(Vec::new()) }
        let term: String = url::form_urlencoded::byte_serialize(text.as_bytes()).collect();
        let body = self.answer(&format!("{BASE_URL}/users/UsernameAutocomplete?term={term}"), Access::SignedIn).await?;
        Ok(parse::parse_usernames(&body)?.into_iter().map(|name| crate::models::AO3User {
            source: SOURCE_ID.to_string(), profile_url: Some(Self::profile_url(&name)),
            id: name.clone(), username: name, avatar_url: None,
        }).collect())
    }

    /// The site's own login form, sent as the page sends it: the form's
    /// token is read from the login page first. The site answers a good
    /// sign-in by sending the reader to its front page, signed in.
    async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        let login_url = format!("{BASE_URL}/site/login");
        let html = self.page(&login_url, Access::Open).await?;
        let token = parse::csrf_token(&html)
            .ok_or_else(|| AppError::ParseError(format!("{NAME}'s login page has no form token")))?;
        let form = [
            ("YII_CSRF_TOKEN".to_string(), token),
            ("LoginForm[username]".to_string(), username.to_string()),
            ("LoginForm[password]".to_string(), password.to_string()),
            ("LoginForm[rememberMe]".to_string(), "1".to_string()),
            ("yt0".to_string(), "Login".to_string()),
        ];
        let out = {
            let client = self.client.read().await;
            client.transport().post_form(
                &login_url, &form, &[("Referer", login_url.as_str()), ("Origin", BASE_URL)],
                &|status, _| status < 400, &HOOKS).await?
        };
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} signing in to {NAME}", out.status),
            });
        }
        Ok(parse::signed_in_user(&out.body).is_some())
    }

    /// The front page's header names the signed-in account.
    async fn whoami(&self) -> Result<Option<super::SessionIdentity>, AppError> {
        let html = self.page(&format!("{BASE_URL}/"), Access::Open).await?;
        Ok(parse::signed_in_user(&html))
    }

    fn search_schema(&self) -> Option<crate::source::search::SearchSchema> {
        Some(search::schema())
    }

    async fn search(&self, query: &crate::source::search::SearchQuery, page: u32) -> Result<ListingPage, AppError> {
        let html = self.page(&search::search_url(query, page), Access::SignedIn).await?;
        Ok(parse::parse_listing(&html))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn source() -> HentaiFoundrySource {
        // A direct client is a reqwest handle; nothing is sent in these tests.
        let client = Arc::new(RwLock::new(AO3Client::new_direct().await.unwrap()));
        HentaiFoundrySource::new(client)
    }

    #[tokio::test]
    async fn resolves_story_chapter_and_short_links() {
        let s = source().await;
        let story = "https://www.hentai-foundry.com/stories/user/Marrowmere/40112/The-Glass-Orchard";
        let r = s.resolve(story).unwrap();
        assert_eq!((r.source.as_str(), r.external_id.as_str(), r.url.as_str()), (SOURCE_ID, "40112", story));
        assert_eq!(s.resolve(&format!("{story}/88019/Chapter-1/First-Harvest?x=1#c")).unwrap().url, story);
        assert_eq!(s.resolve("hentai-foundry.com/stories/user/Marrowmere/40112/The-Glass-Orchard.pdf").unwrap().url, story);
        assert_eq!(s.resolve("http://hentai-foundry.com/stories/40112").unwrap().url, "https://www.hentai-foundry.com/stories/40112");
        assert!(s.resolve("https://www.hentai-foundry.com/stories/user/Marrowmere").is_none());
        assert!(s.resolve("https://www.hentai-foundry.com/pictures/user/Marrowmere/40112/A-Picture").is_none());
        assert!(s.resolve("https://www.scribblehub.com/series/40112/x/").is_none());
        assert!(s.resolve("https://nothentai-foundry.com/stories/40112").is_none());
        assert_eq!(s.work_ref("40112").unwrap().url, "https://www.hentai-foundry.com/stories/40112");
        assert!(s.work_ref("abc").is_none());
    }

    #[tokio::test]
    async fn classifies_the_sites_links() {
        let s = source().await;
        let story = "https://www.hentai-foundry.com/stories/user/Marrowmere/40112/The-Glass-Orchard";
        assert!(matches!(s.classify(story), Some(LinkTarget::Work { entire: false, .. })));
        assert!(matches!(s.classify(&format!("{story}/88019/Chapter-1/First-Harvest")),
                         Some(LinkTarget::Chapter { chapter_id, .. }) if chapter_id == "88019"));
        assert!(matches!(s.classify("https://www.hentai-foundry.com/user/Marrowmere/profile"),
                         Some(LinkTarget::User { user, pane: UserPane::Profile }) if user.external_id == "Marrowmere"));
        assert!(matches!(s.classify("https://www.hentai-foundry.com/stories/user/Marrowmere/page/2"),
                         Some(LinkTarget::User { pane: UserPane::Works, .. })));
        assert_eq!(s.classify("https://www.hentai-foundry.com/pictures/user/Marrowmere"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://www.hentai-foundry.com/user/Marrowmere/faves/stories"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://example.com/stories/40112"), None);
        assert_eq!(s.resolve_user("https://www.hentai-foundry.com/user/Marrowmere").unwrap().url,
                   "https://www.hentai-foundry.com/user/Marrowmere/profile");
    }

    #[test]
    fn urls() {
        let story = HentaiFoundrySource::story_url("Marrowmere", "40112", "The-Glass-Orchard");
        assert_eq!(HentaiFoundrySource::chapter_url(&story, 88019, 2),
                   "https://www.hentai-foundry.com/stories/user/Marrowmere/40112/The-Glass-Orchard/88019/Chapter-2/x");
        let by_id = ExternalRef { source: SOURCE_ID.into(), external_id: "40112".into(), url: "https://www.hentai-foundry.com/stories/40112".into() };
        assert_eq!(HentaiFoundrySource::story_page_url(&by_id), "https://www.hentai-foundry.com/stories/40112");
        let stored = ExternalRef { url: format!("{story}/88019/Chapter-1/x"), ..by_id };
        assert_eq!(HentaiFoundrySource::story_page_url(&stored), story);
        assert_eq!(HentaiFoundrySource::entering("https://h/a"), "https://h/a?enterAgree=1");
        assert_eq!(HentaiFoundrySource::entering("https://h/a?page=2#top"), "https://h/a?page=2&enterAgree=1#top");
    }

    #[test]
    fn the_login_cookie_is_told_by_its_shape() {
        assert!(is_login_cookie("0123456789abcdef0123456789abcdef"));
        assert!(!is_login_cookie("PHPSESSID"));
        assert!(!is_login_cookie("0123456789ABCDEF0123456789ABCDEF"));
        assert!(!is_login_cookie("techaro.lol-anubis-auth-0123abcd"));
        assert!(is_session_cookie("PHPSESSID") && !is_session_cookie("YII_CSRF_TOKEN"));
        let jar = "PHPSESSID=p; YII_CSRF_TOKEN=t; 0123456789abcdef0123456789abcdef=who";
        assert!(crate::source::session_logged_in(SOURCE_ID, jar));
        assert!(!crate::source::session_logged_in(SOURCE_ID, "PHPSESSID=p; YII_CSRF_TOKEN=t"), "a session alone is no login");
        assert_eq!(crate::source::session_part(SOURCE_ID, jar), "PHPSESSID=p; 0123456789abcdef0123456789abcdef=who");
    }

    #[tokio::test]
    async fn declares_sign_in_search_and_no_discussion() {
        let s = source().await;
        let caps = s.capabilities().clone();
        assert_eq!(caps.sign_in, crate::source::SignInShape::Credentials);
        assert!(caps.login && caps.search && caps.author_listings);
        assert_eq!(caps.discussion, DiscussionShape::None);
        assert!(!caps.discussion_posts && !caps.chapter_comments);
        assert_eq!(caps.reaction, ReactionShape::None);
        assert!(!caps.reach.tor && caps.reach.direct);
        assert!(s.fetches_chapters_individually() && !s.listings_need_details());
        assert_eq!(s.post_gate(true), crate::source::Gate::Hidden);
    }

    #[tokio::test]
    async fn nothing_is_asked_for_signed_out() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        let work = ExternalRef { source: SOURCE_ID.into(), external_id: "1".into(), url: String::new() };
        let Err(AppError::NetworkError(message)) = s.fetch_work(&work, None).await else { panic!("refused before sending") };
        assert_eq!(message, "Sign in to Hentai Foundry to use it.");
        let q = crate::source::search::SearchQuery::new(SOURCE_ID, search::VERSION);
        assert!(matches!(s.search(&q, 1).await, Err(AppError::NetworkError(_))));
    }

    #[tokio::test]
    async fn refuses_while_the_mock_archive_is_on() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        crate::mock_site::set_enabled(true);
        let r = s.login("someone", "secret").await;
        crate::mock_site::set_enabled(false);
        assert!(matches!(r, Err(AppError::NetworkError(m)) if m.contains("mock archive")));
    }
}
