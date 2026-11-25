//! Literotica: stories only (its poems, audio, illustrations and shop are
//! not this app's business).
//!
//! Rules of this source:
//! - **The site's own data service, never its pages.** Everything is read
//!   from the JSON service the site's pages are built on
//!   (`literotica.com/api/3`). The pages themselves (`www.literotica.com`)
//!   sit behind a visitor check and are never asked for; their addresses
//!   are only recognised as links and shown as the place to open a work.
//! - **An account is optional.** Reading, searching and a story's
//!   comments need none. Signed in (the site's own sign-in service, by
//!   name and password), the reader can rate a story and comment on one.
//!   The sign-in is a token the service hands out and renews; it rides
//!   on every request to the data service while it lasts.
//! - **Ratings and comments belong to a story.** The site has neither
//!   for a series as a whole: a series here takes no rating, and its
//!   comments are each chapter's.
//! - **A series is one work.** The site publishes a long story as
//!   separate stories in a series; here the series is the work and each
//!   story a chapter. A story in no series is a work of one chapter. A
//!   link to a part opens its series.
//! - **A listing costs one request.** A search result or an author's
//!   list names a series only through one of its parts, so the row says
//!   what that part says about the series and nothing more (no word
//!   count, no figures). The series' own record arrives with the work's
//!   fetch — the queued download, or the reader opening it.
//! - **A chapter is a whole story.** The site splits a long story into
//!   pages and serves one per request; a chapter fetch asks for each in
//!   turn, paced, and joins them.
//!
//! Keys: a story by its address name (`/s/{name}`), a series as
//! `se:{number}`, a user by username. The site lists a user's stories by
//! its own number for them, which is looked up by name once and
//! remembered while the app runs.

pub mod parse;
pub mod search;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio::sync::RwLock;

use crate::client::{FailureKind, SiteHooks};
use crate::error::AppError;
use crate::models::{Chapter, CommentsPage, ExternalRef, WorkSummary};
use crate::source::ao3::AO3Client;

use super::{DiscussionPost, DiscussionShape, FetchedWork, Gate, LinkTarget, ListingPage, PostedDiscussion, Reaction,
            ReactionOutcome, ReactionShape, Reachability, SessionIdentity, Source, SourceCapabilities, UserPane, Vocabulary};

pub const SOURCE_ID: &str = "literotica";
pub const BASE_URL: &str = "https://www.literotica.com";
/// The data service the site's own pages read.
const API_URL: &str = "https://literotica.com/api/3";
/// The site's sign-in service. The session it hands out is held under
/// this address alone.
pub const AUTH_URL: &str = "https://auth.literotica.com";
/// The domain the sign-in service sets its cookies for.
const COOKIE_DOMAIN: &str = "literotica.com";
/// The cookie that carries the sign-in's token.
const TOKEN_COOKIE: &str = "auth_token";
/// A token this close to its end (seconds) is renewed before use.
const TOKEN_MARGIN: u64 = 60;
const NAME: &str = "Literotica";

/// The cookie that proves a sign-in.
pub fn is_login_cookie(name: &str) -> bool {
    name == TOKEN_COOKIE
}

/// Everything the sign-in service keeps for the account. Its names
/// beyond the token are the service's own business, so all of them count
/// but the ones its network front sets for any visitor.
pub fn is_session_cookie(name: &str) -> bool {
    !name.is_empty() && !["__cf", "_cf", "cf_"].iter().any(|front| name.starts_with(front))
}
/// What a series' key starts with; no story's address name holds a colon.
const SERIES_PREFIX: &str = "se:";

struct Hooks;

impl SiteHooks for Hooks {
    fn source(&self) -> &'static str { SOURCE_ID }
}

static HOOKS: Hooks = Hooks;

pub struct LiteroticaSource {
    client: Arc<RwLock<AO3Client>>,
    capabilities: SourceCapabilities,
    /// The site's number for each user seen, by lowercased username.
    user_ids: Mutex<HashMap<String, u64>>,
    /// The first page of the story a work fetch last read, kept so the
    /// chapter fetch that follows does not ask for it again.
    first_page: Mutex<Option<parse::StoryPage>>,
    /// Each story seen, by the site's number, with its address name: a
    /// rating is sent by the number, comments are asked for by the name.
    stories: Mutex<HashMap<u64, String>>,
}

impl LiteroticaSource {
    pub fn new(client: Arc<RwLock<AO3Client>>) -> Self {
        LiteroticaSource {
            client,
            capabilities: Self::declare(),
            user_ids: Mutex::new(HashMap::new()),
            first_page: Mutex::new(None),
            stories: Mutex::new(HashMap::new()),
        }
    }

    fn declare() -> SourceCapabilities {
        SourceCapabilities {
            id: SOURCE_ID.to_string(),
            name: NAME.to_string(),
            host: "www.literotica.com".to_string(),
            // Tor is untested against this site; it is not tried until it
            // has been.
            reach: Reachability { tor: false, direct: true },
            reaction: ReactionShape::StarRating { max: 5 },
            discussion: DiscussionShape::Threaded,
            chapter_comments: true,
            search: true,
            browse: false,
            author_listings: true,
            user_search: true,
            tag_listings: false,
            update_checks: true,
            discussion_posts: true,
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
                reaction_verb: "Rate this story".to_string(),
                reply_verb: Some("Reply".to_string()),
                rating_label: "Rating".to_string(),
                site_short: "Lit".to_string(),
                open_on_site: "Open on Literotica".to_string(),
                copy_link: "Copy Literotica link".to_string(),
                refresh: "Refresh from Literotica".to_string(),
                subscribe_verb: None,
            },
        }
    }

    // -- Keys and addresses ---------------------------------------------------

    pub fn story_url(slug: &str) -> String {
        format!("{BASE_URL}/s/{slug}")
    }

    pub fn series_url(id: u64) -> String {
        format!("{BASE_URL}/series/se/{id}")
    }

    pub fn profile_url(username: &str) -> String {
        format!("{BASE_URL}/authors/{username}")
    }

    pub fn series_key(id: u64) -> String {
        format!("{SERIES_PREFIX}{id}")
    }

    /// The series a work key names, when it names one.
    fn series_of_key(external_id: &str) -> Option<u64> {
        external_id.strip_prefix(SERIES_PREFIX)?.parse().ok()
    }

    fn valid_slug(slug: &str) -> bool {
        !slug.is_empty() && slug.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    }

    fn story_ref(slug: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: slug.to_string(), url: Self::story_url(slug) }
    }

    fn series_ref(id: u64) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: Self::series_key(id), url: Self::series_url(id) }
    }

    fn user_ref(username: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: username.to_string(), url: Self::profile_url(username) }
    }

    /// The path of a link on this site (`/s/…`), without query or
    /// fragment — None for any other host, the site's other hosts (its
    /// search, tags and forum) among them.
    fn site_path(input: &str) -> Option<&str> {
        let rest = input.strip_prefix("https://").or_else(|| input.strip_prefix("http://")).unwrap_or(input);
        let rest = rest.strip_prefix("www.").unwrap_or(rest);
        let rest = rest.strip_prefix("literotica.com")?;
        let path = rest.split(['?', '#']).next().unwrap_or("");
        if path.is_empty() { Some("/") } else if path.starts_with('/') { Some(path) } else { None }
    }

    /// `/s/{name}` → the story's address name.
    fn story_in(path: &str) -> Option<&str> {
        let slug = path.strip_prefix("/s/")?.trim_end_matches('/');
        Self::valid_slug(slug).then_some(slug)
    }

    /// `/series/se/{number}` → the series.
    fn series_in(path: &str) -> Option<u64> {
        let id = path.strip_prefix("/series/se/")?.trim_end_matches('/');
        (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then(|| id.parse().ok()).flatten()
    }

    /// `/authors/{name}` is a user's profile, `/authors/{name}/works[/…]`
    /// what they have published.
    fn user_in(path: &str) -> Option<(&str, UserPane)> {
        let rest = path.strip_prefix("/authors/")?;
        let mut parts = rest.split('/');
        let name = parts.next().filter(|n| !n.is_empty())?;
        match parts.next() {
            None | Some("") => Some((name, UserPane::Profile)),
            Some("works") => Some((name, UserPane::Works)),
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

    /// The service's address for `path`, its parameters as the one JSON
    /// value the service reads them from.
    fn api_url(path: &str, params: Option<&Value>) -> String {
        match params {
            Some(params) => {
                let encoded: String = url::form_urlencoded::byte_serialize(params.to_string().as_bytes()).collect();
                // A space travels as %20 (a literal plus is already %2B).
                format!("{API_URL}{path}?params={}", encoded.replace('+', "%20"))
            }
            None => format!("{API_URL}{path}"),
        }
    }

    /// The jar's cookies at the sign-in service.
    async fn session_cookies(&self) -> String {
        self.client.read().await.transport().cookies_for(AUTH_URL)
    }

    /// The sign-in's token as the jar holds it, whatever its age.
    async fn held_token(&self) -> Option<String> {
        self.session_cookies().await.split(';').map(str::trim)
            .find_map(|part| part.strip_prefix(TOKEN_COOKIE).and_then(|rest| rest.strip_prefix('=')))
            .filter(|value| !value.is_empty()).map(str::to_string)
    }

    /// Whether the sign-in service holds a session for this jar: it marks
    /// one with its own flag cookie.
    async fn session_open(&self) -> bool {
        self.session_cookies().await.split(';').any(|part| part.trim() == "authenticated=1")
    }

    /// Keep what the sign-in service just set under its own address: it
    /// sets its cookies for every host of the site.
    async fn settle_session(&self) {
        self.client.read().await.transport().rehome_cookies(AUTH_URL, COOKIE_DOMAIN, is_session_cookie);
    }

    /// Ask the sign-in service for a fresh token (one request). The
    /// service answers by setting it; a refusal means the sign-in is over.
    async fn renew_token(&self) -> Result<Option<String>, AppError> {
        Self::guard()?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let url = format!("{AUTH_URL}/check?timestamp={now}");
        let out = {
            let client = self.client.read().await;
            client.transport().get_outcome(&url, &[("Accept", "application/json")], &|status| status < 400 || status == 401, &HOOKS).await?
        };
        if out.status == 401 || out.status == 403 { return Ok(None) }
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} renewing the {NAME} sign-in", out.status),
            });
        }
        self.settle_session().await;
        Ok(self.held_token().await)
    }

    /// The token to send now: the jar's, renewed first when its time is
    /// up. None when no account is signed in.
    async fn token(&self) -> Result<Option<String>, AppError> {
        let Some(token) = self.held_token().await else {
            // Signed in but no token yet: the sign-in itself only opens
            // the session, and the service hands the token out when asked
            // (as the site's own pages ask before their first request).
            return if self.session_open().await { self.renew_token().await } else { Ok(None) };
        };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        match parse::token_expiry(&token) {
            Some(end) if end <= now + TOKEN_MARGIN => self.renew_token().await,
            _ => Ok(Some(token)),
        }
    }

    /// One exchange with the data service, signed with the account's
    /// token when one is signed in. `send` = the method and body of a
    /// write; None reads. A token the service no longer takes is renewed
    /// once and the request sent again.
    async fn exchange(&self, url: &str, send: Option<(&str, &Value)>) -> Result<crate::client::PostOutcome, AppError> {
        Self::guard()?;
        let mut token = self.token().await?;
        let mut renewed = false;
        loop {
            let bearer = token.as_ref().map(|t| format!("Bearer {t}"));
            let mut headers: Vec<(&str, &str)> = vec![("Accept", "application/json")];
            if let Some(bearer) = &bearer { headers.push(("Authorization", bearer.as_str())); }
            let out = {
                let client = self.client.read().await;
                match send {
                    None => client.transport().get_outcome(url, &headers, &|status| status < 400, &HOOKS).await?,
                    Some((method, body)) => client.transport()
                        .send_json(method, url, body, &headers, &|status, _| status < 400, &HOOKS).await?,
                }
            };
            if out.status == 401 {
                // What the refusal was answering, never the token itself:
                // whether one was sent, how long it had left, and whether
                // the sign-in service still marks a session.
                let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                let left = token.as_deref().and_then(parse::token_expiry).map(|end| end as i64 - now as i64);
                log_info!("literotica", "401 for {url}: token sent {}, seconds left {:?}, session open {}, already renewed {}, said {:?}",
                    token.is_some(), left, self.session_open().await, renewed, out.body.chars().take(300).collect::<String>());
            }
            if out.status == 401 && token.is_some() && !renewed {
                renewed = true;
                token = self.renew_token().await?;
                log_info!("literotica", "renewal after the 401 gave a token: {}", token.is_some());
                // The sign-in is over: what anyone may read is asked for
                // again without it; a write has nothing to fall back to.
                if token.is_some() || send.is_none() { continue }
            }
            return Ok(out);
        }
    }

    /// One answer from the site's data service.
    async fn api(&self, path: &str, params: Option<Value>) -> Result<String, AppError> {
        let url = Self::api_url(path, params.as_ref());
        let out = self.exchange(&url, None).await?;
        if out.status >= 400 {
            let said = parse::message(&out.body).map(|m| format!(" ({m})")).unwrap_or_default();
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} for {url}{said}", out.status),
            });
        }
        Ok(out.body)
    }

    /// A write to the data service on the signed-in account's behalf.
    /// The site's refusal (a 4xx) comes back as its own words; no account
    /// signed in is refused before anything is sent.
    async fn write(&self, method: &str, path: &str, body: Value, doing: &str) -> Result<Result<String, String>, AppError> {
        if self.held_token().await.is_none() {
            return Err(AppError::NetworkError(format!("Sign in to {NAME} to {doing}.")));
        }
        let url = Self::api_url(path, None);
        let out = self.exchange(&url, Some((method, &body))).await?;
        match out.status {
            401 | 403 => Err(AppError::NetworkError(format!("Sign in to {NAME} to {doing}."))),
            400..=499 => Ok(Err(parse::refusal(&out.body).unwrap_or_else(|| format!("HTTP {}", out.status)))),
            status if status >= 500 => Err(AppError::Http {
                kind: FailureKind::from_status(status, None),
                detail: format!("HTTP {status} for {url}"),
            }),
            _ => match serde_json::from_str::<Value>(out.body.trim()) {
                Ok(v) if v.get("success").and_then(Value::as_bool) == Some(false) =>
                    Ok(Err(parse::refusal(&out.body).unwrap_or_else(|| "no reason given".to_string()))),
                _ => Ok(Ok(out.body)),
            },
        }
    }

    fn remember_stories(&self, stories: impl IntoIterator<Item = (u64, String)>) {
        let mut held = self.stories.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for (id, slug) in stories { held.insert(id, slug); }
    }

    fn known_story_slug(&self, id: u64) -> Option<String> {
        self.stories.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(&id).cloned()
    }

    fn known_story_id(&self, slug: &str) -> Option<u64> {
        self.stories.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter().find(|(_, held)| held.as_str() == slug).map(|(id, _)| *id)
    }

    /// A story by either of its keys (`key` = its address name or its
    /// number): remembered, or asked for (one request, then the pause
    /// before the next).
    async fn story_keys(&self, key: &str) -> Result<(u64, String), AppError> {
        let known = match key.parse::<u64>() {
            Ok(id) => self.known_story_slug(id).map(|slug| (id, slug)),
            Err(_) => self.known_story_id(key).map(|id| (id, key.to_string())),
        };
        if let Some(known) = known { return Ok(known) }
        let page = parse::parse_story(&self.api(&format!("/stories/{}", Self::segment(key)), None).await?)?;
        self.remember_stories([(page.id, page.slug.clone())]);
        crate::client::pacing::request_gap().await;
        Ok((page.id, page.slug))
    }

    /// The story a discussion belongs to: a chapter's own story, or the
    /// work itself when it is a story. A series has no comments of its own.
    async fn discussed_story(&self, work: &ExternalRef, chapter: Option<u64>) -> Result<(u64, String), AppError> {
        let series = Self::series_of_key(&work.external_id).is_some();
        match chapter {
            Some(id) if series => self.story_keys(&id.to_string()).await,
            None if series => Err(AppError::NetworkError(format!(
                "{NAME} keeps comments with each part of a series. Open a chapter to see its comments."))),
            _ => self.story_keys(&work.external_id).await,
        }
    }

    fn remember_users(&self, users: impl IntoIterator<Item = (String, u64)>) {
        let mut ids = self.user_ids.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for (username, id) in users { ids.insert(username.to_lowercase(), id); }
    }

    fn known_user_id(&self, username: &str) -> Option<u64> {
        self.user_ids.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(&username.to_lowercase()).copied()
    }

    /// The site's number for a user: remembered, or asked for by name
    /// (one request, then the pause before the next).
    async fn user_id(&self, username: &str) -> Result<u64, AppError> {
        if let Some(id) = self.known_user_id(username) { return Ok(id) }
        let body = self.api(&format!("/users/{}", Self::segment(username)), None).await?;
        let (_, id) = parse::parse_profile(&body)?;
        let id = id.ok_or_else(|| AppError::ParseError(format!("{NAME} gave no number for {username}")))?;
        self.remember_users([(username.to_string(), id)]);
        crate::client::pacing::request_gap().await;
        Ok(id)
    }

    /// A name as one segment of an address.
    fn segment(name: &str) -> String {
        url::form_urlencoded::byte_serialize(name.as_bytes()).collect::<String>().replace('+', "%20")
    }

    /// A series' record and its parts: two requests.
    async fn fetch_series(&self, id: u64) -> Result<FetchedWork, AppError> {
        let record = crate::steps::run("Series", self.api(&format!("/series/{id}"), None)).await?;
        crate::client::pacing::request_gap().await;
        let parts = crate::steps::run("Series parts", self.api(&format!("/series/{id}/works"), None)).await?;
        let page = parse::parse_series(&record, &parts)?;
        self.remember_stories(page.stories);
        Ok(FetchedWork {
            summary: page.work.summary,
            chapters: page.chapters,
            stats: page.work.stats,
            reacted_by: Vec::new(),
            authors: page.work.authors,
        })
    }

    fn keep_first_page(&self, page: parse::StoryPage) {
        *self.first_page.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(page);
    }

    fn take_first_page(&self, story_id: u64) -> Option<parse::StoryPage> {
        let mut kept = self.first_page.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if kept.as_ref().is_some_and(|p| p.id == story_id) { kept.take() } else { None }
    }
}

#[async_trait]
impl Source for LiteroticaSource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn fetches_chapters_individually(&self) -> bool { true }

    /// A story's page (any of its pages) and a series' page each name a
    /// work.
    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        if let Some(slug) = Self::story_in(path) { return Some(Self::story_ref(slug)) }
        Self::series_in(path).map(Self::series_ref)
    }

    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        Self::user_in(path).map(|(name, _)| Self::user_ref(name))
    }

    fn classify(&self, input: &str) -> Option<LinkTarget> {
        let path = Self::site_path(input.trim())?;
        if let Some(work) = self.resolve(input) {
            return Some(LinkTarget::Work { work, entire: false });
        }
        if let Some((name, pane)) = Self::user_in(path) {
            return Some(LinkTarget::User { user: Self::user_ref(name), pane });
        }
        // Poems, categories, a user's favorites: the site's, with no view here.
        Some(LinkTarget::Unsupported)
    }

    fn work_ref(&self, external_id: &str) -> Option<ExternalRef> {
        if let Some(id) = Self::series_of_key(external_id) { return Some(Self::series_ref(id)) }
        Self::valid_slug(external_id).then(|| Self::story_ref(external_id))
    }

    /// A series: its record and parts. A story: its first page, which
    /// says whether it is a part of a series — then that series is the
    /// work fetched, under the series' own key.
    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        if let Some(id) = Self::series_of_key(&work.external_id) {
            return self.fetch_series(id).await;
        }
        let body = crate::steps::run("Story", self.api(&format!("/stories/{}", Self::segment(&work.external_id)), None)).await?;
        let page = parse::parse_story(&body)?;
        self.remember_stories([(page.id, page.slug.clone())]);
        if let Some(series) = page.series {
            crate::client::pacing::request_gap().await;
            return self.fetch_series(series).await;
        }
        let fetched = FetchedWork {
            summary: page.work.summary.clone(),
            chapters: vec![Chapter {
                id: Some(page.id),
                title: Some(page.title.clone()),
                number: 1,
                content: Vec::new(),
                notes_before: None,
                notes_after: None,
            }],
            stats: page.work.stats.clone(),
            reacted_by: Vec::new(),
            authors: page.work.authors.clone(),
        };
        self.keep_first_page(page);
        Ok(fetched)
    }

    /// One chapter is one story: every page the site splits it into, in
    /// order, with the shared pause between requests.
    async fn fetch_chapter(&self, work: &ExternalRef, chapter: &Chapter) -> Result<Chapter, AppError> {
        let story_id = chapter.id
            .ok_or_else(|| AppError::ElementNotFound(format!("chapter {} of {} has no id", chapter.number, work.external_id)))?;
        let path = format!("/stories/{story_id}");
        let first = match self.take_first_page(story_id) {
            Some(page) => page,
            None => parse::parse_story(&crate::steps::run("Page 1", self.api(&path, None)).await?)?,
        };
        self.remember_stories([(first.id, first.slug.clone())]);
        let mut text = first.text;
        let page_step = |number: u32| format!("Page {number} of {}", first.pages);
        crate::steps::plan((2..=first.pages).map(page_step));
        for number in 2..=first.pages {
            crate::client::pacing::request_gap().await;
            let body = crate::steps::run(&page_step(number), self.api(&path, Some(json!({ "contentPage": number })))).await?;
            let page = parse::parse_story(&body)?;
            text.push_str("\r\n\r\n");
            text.push_str(&page.text);
        }
        Ok(Chapter {
            id: Some(story_id),
            title: chapter.title.clone().filter(|t| !t.is_empty()).or(Some(first.title)),
            number: chapter.number,
            content: parse::blocks(&text, &Self::story_url(&first.slug)),
            notes_before: None,
            notes_after: None,
        })
    }

    /// One page of the author's stories, newest first; the parts of a
    /// series are listed once, as the series.
    async fn fetch_author_works(&self, author: &ExternalRef, page: u32) -> Result<ListingPage, AppError> {
        let id = self.user_id(&author.external_id).await?;
        let page = page.max(1);
        let body = self.api(&format!("/users/{id}/stories"), Some(json!({ "type": "story", "page": page, "sort": "date" }))).await?;
        parse::parse_listing(&body, page, false)
    }

    async fn fetch_author(&self, author: &ExternalRef) -> Result<crate::models::SourceUserProfile, AppError> {
        let body = self.api(&format!("/users/{}", Self::segment(&author.external_id)), None).await?;
        let (profile, id) = parse::parse_profile(&body)?;
        if let Some(id) = id { self.remember_users([(profile.username.clone(), id)]); }
        Ok(profile)
    }

    /// The site's member search, by name only.
    async fn search_users(&self, query: &str) -> Result<Vec<crate::models::AO3User>, AppError> {
        let text = query.trim();
        if text.is_empty() { return Ok(Vec::new()) }
        let body = self.api("/search/members", Some(json!({ "q": text, "page": 1 }))).await?;
        let members = parse::parse_members(&body)?;
        self.remember_users(members.iter().filter_map(|(user, id)| id.map(|id| (user.username.clone(), id))));
        Ok(members.into_iter().map(|(user, _)| user).collect())
    }

    /// The site's sign-in service takes the name and password as the
    /// site's own page sends them and answers by opening the session; a
    /// wrong pair is a 401 in its own words. The token every later
    /// request carries is then asked of the service, as the site's pages
    /// ask it.
    async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        Self::guard()?;
        let url = format!("{AUTH_URL}/login");
        let body = json!({ "login": username, "password": password });
        let out = {
            let client = self.client.read().await;
            client.transport().send_json(
                "POST", &url, &body, &[("Accept", "application/json"), ("Origin", BASE_URL)],
                &|status, _| status < 400 || status == 401, &HOOKS).await?
        };
        if out.status == 401 { return Ok(false) }
        if out.status >= 400 {
            let said = parse::refusal(&out.body).map(|m| format!(" ({m})")).unwrap_or_default();
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} signing in to {NAME}{said}", out.status),
            });
        }
        self.settle_session().await;
        // The sign-in opens the session; the token is asked for next.
        let signed_in = match self.held_token().await {
            Some(_) => true,
            None => self.renew_token().await?.is_some(),
        };
        if !signed_in {
            // Names only: what the service set, to tell a changed sign-in
            // from a refused one.
            let names: Vec<String> = self.session_cookies().await.split(';')
                .filter_map(|part| part.trim().split('=').next().map(str::to_string)).filter(|n| !n.is_empty()).collect();
            log_info!("literotica", "sign-in answered {} without a token; cookies set: {:?}", out.status, names);
        }
        Ok(signed_in)
    }

    /// The data service names the account its token belongs to; failing
    /// that, the token's own statement does.
    async fn whoami(&self) -> Result<Option<SessionIdentity>, AppError> {
        let Some(token) = self.token().await? else { return Ok(None) };
        let out = self.exchange(&Self::api_url("/users/session", None), None).await?;
        if out.status >= 500 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} asking {NAME} who is signed in", out.status),
            });
        }
        let named = if out.status < 400 { parse::parse_session(&out.body) } else { None };
        let Some((who, id)) = named.or_else(|| parse::token_identity(&token)) else {
            if out.status < 400 { log_info!("literotica", "the session answer names no account"); }
            return Ok(None);
        };
        if let Some(id) = id { self.remember_users([(who.username.clone(), id)]); }
        Ok(Some(who))
    }

    /// A rating belongs to a story: a series takes none.
    fn reaction_gate_for(&self, work: &ExternalRef, signed_in: bool) -> Gate {
        if Self::series_of_key(&work.external_id).is_some() { return Gate::Hidden }
        self.reaction_gate(signed_in)
    }

    /// The story page's stars: one to five, sent by the story's number.
    /// The site has no way to withdraw a rating.
    async fn react(&self, work: &ExternalRef, reaction: Reaction) -> Result<ReactionOutcome, AppError> {
        Self::guard()?;
        let refused = ReactionOutcome { accepted: false, value: None };
        let value = match reaction {
            Reaction::Stars { value } if (1..=5).contains(&value) => value,
            _ => return Ok(refused),
        };
        if Self::series_of_key(&work.external_id).is_some() { return Ok(refused) }
        if self.held_token().await.is_none() {
            return Err(AppError::NetworkError(format!("Sign in to {NAME} to rate.")));
        }
        let (id, _) = self.story_keys(&work.external_id).await?;
        match self.write("PATCH", &format!("/stories/{id}/rate"), json!({ "rate": value }), "rate").await? {
            Ok(_) => Ok(ReactionOutcome { accepted: true, value: Some(value) }),
            Err(said) => {
                log_info!("literotica", "rating {value} for {} answered: {said}", work.external_id);
                Ok(refused)
            }
        }
    }

    /// A story's comments, five to a page as the site serves them, newest
    /// first. The site lists them flat: a reply stands among the rest.
    async fn fetch_discussion(&self, work: &ExternalRef, chapter: Option<u64>, page: u32) -> Result<CommentsPage, AppError> {
        let (id, slug) = self.discussed_story(work, chapter).await?;
        let page = page.max(1);
        let params = (page > 1).then(|| json!({ "page": page }));
        let body = self.api(&format!("/stories/{}/comments", Self::segment(&slug)), params).await?;
        parse::parse_comments(&body, page, &Self::story_url(&slug), chapter.map(|_| id))
    }

    /// A comment on a story, or a reply to one, as the story page sends
    /// it. The answer is the story's newest comments, asked for after the
    /// usual pause.
    async fn post_discussion(&self, work: &ExternalRef, post: &DiscussionPost) -> Result<PostedDiscussion, AppError> {
        Self::guard()?;
        let text = post.body.trim();
        if text.is_empty() {
            return Err(AppError::NetworkError("Write something to post.".to_string()));
        }
        if self.held_token().await.is_none() {
            return Err(AppError::NetworkError(format!("Sign in to {NAME} to post.")));
        }
        let (id, slug) = self.discussed_story(work, post.chapter).await?;
        let mut body = json!({ "content": text });
        if let Some(parent) = post.parent { body["parent_id"] = json!(parent); }
        let path = format!("/stories/{}/comments", Self::segment(&slug));
        let answer = self.write("POST", &path, body, "post").await?
            .map_err(|said| AppError::NetworkError(format!("{NAME} did not take the comment: {said}")))?;
        let comment_id = parse::posted_comment_id(&answer);
        crate::client::pacing::request_gap().await;
        // The comment is posted; a failed read of the list is not a failed post.
        let page = match self.api(&path, None).await {
            Ok(listed) => parse::parse_comments(&listed, 1, &Self::story_url(&slug), post.chapter.map(|_| id))
                .unwrap_or(CommentsPage { comments: Vec::new(), current_page: 1, total_pages: 1 }),
            Err(_) => CommentsPage { comments: Vec::new(), current_page: 1, total_pages: 1 },
        };
        Ok(PostedDiscussion { page, comment_id })
    }

    fn search_schema(&self) -> Option<crate::source::search::SearchSchema> {
        Some(search::schema())
    }

    async fn search(&self, query: &crate::source::search::SearchQuery, page: u32) -> Result<ListingPage, AppError> {
        let page = page.max(1);
        let params = search::search_params(query, page)
            .ok_or_else(|| AppError::NetworkError(format!("Type something to search {NAME} for.")))?;
        let body = self.api("/search/stories", Some(params)).await?;
        self.remember_users(parse::listed_users(&body));
        parse::parse_listing(&body, page, true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn source() -> LiteroticaSource {
        // A direct client is a reqwest handle; nothing is sent in these tests.
        let client = Arc::new(RwLock::new(AO3Client::new_direct().await.unwrap()));
        LiteroticaSource::new(client)
    }

    #[tokio::test]
    async fn resolves_story_and_series_links() {
        let s = source().await;
        let story = "https://www.literotica.com/s/the-tide-ledger";
        let r = s.resolve(story).unwrap();
        assert_eq!((r.source.as_str(), r.external_id.as_str(), r.url.as_str()), (SOURCE_ID, "the-tide-ledger", story));
        assert_eq!(s.resolve("literotica.com/s/the-tide-ledger?page=3#top").unwrap().url, story);
        assert_eq!(s.resolve("http://literotica.com/s/the-tide-ledger/").unwrap().url, story);
        let series = s.resolve("https://www.literotica.com/series/se/77001").unwrap();
        assert_eq!((series.external_id.as_str(), series.url.as_str()), ("se:77001", "https://www.literotica.com/series/se/77001"));
        assert!(s.resolve("https://www.literotica.com/s/").is_none());
        assert!(s.resolve("https://www.literotica.com/p/a-poem").is_none());
        assert!(s.resolve("https://www.literotica.com/series/se/abc").is_none());
        assert!(s.resolve("https://search.literotica.com/s/the-tide-ledger").is_none());
        assert!(s.resolve("https://notliterotica.com/s/the-tide-ledger").is_none());
        assert!(s.resolve("https://www.scribblehub.com/series/40112/x/").is_none());
        assert_eq!(s.work_ref("the-tide-ledger").unwrap().url, story);
        assert_eq!(s.work_ref("se:77001").unwrap().url, "https://www.literotica.com/series/se/77001");
        assert!(s.work_ref("se:x").is_none() && s.work_ref("").is_none());
    }

    #[tokio::test]
    async fn classifies_the_sites_links() {
        let s = source().await;
        assert!(matches!(s.classify("https://www.literotica.com/s/the-tide-ledger"), Some(LinkTarget::Work { entire: false, .. })));
        assert!(matches!(s.classify("https://www.literotica.com/series/se/77001"),
                         Some(LinkTarget::Work { work, .. }) if work.external_id == "se:77001"));
        assert!(matches!(s.classify("https://www.literotica.com/authors/Marrowmere"),
                         Some(LinkTarget::User { user, pane: UserPane::Profile }) if user.external_id == "Marrowmere"));
        assert!(matches!(s.classify("https://www.literotica.com/authors/Marrowmere/works/stories"),
                         Some(LinkTarget::User { pane: UserPane::Works, .. })));
        assert_eq!(s.classify("https://www.literotica.com/authors/Marrowmere/favorites"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://www.literotica.com/c/romance"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://example.com/s/the-tide-ledger"), None);
        assert_eq!(s.resolve_user("https://literotica.com/authors/Marrowmere/works/stories").unwrap().url,
                   "https://www.literotica.com/authors/Marrowmere");
    }

    #[test]
    fn the_services_addresses() {
        assert_eq!(LiteroticaSource::api_url("/series/77001", None), "https://literotica.com/api/3/series/77001");
        assert_eq!(LiteroticaSource::api_url("/search/members", Some(&json!({ "q": "a b+c" }))),
                   "https://literotica.com/api/3/search/members?params=%7B%22q%22%3A%22a%20b%2Bc%22%7D");
        assert_eq!(LiteroticaSource::segment("Some Name"), "Some%20Name");
        assert_eq!(LiteroticaSource::series_of_key("se:77001"), Some(77001));
        assert_eq!(LiteroticaSource::series_of_key("the-tide-ledger"), None);
    }

    #[tokio::test]
    async fn declares_search_sign_in_ratings_and_comments() {
        let s = source().await;
        let caps = s.capabilities().clone();
        assert_eq!(caps.sign_in, crate::source::SignInShape::Credentials);
        assert!(caps.login && caps.search && caps.author_listings && caps.user_search && caps.update_checks);
        assert_eq!((caps.discussion, caps.reaction), (DiscussionShape::Threaded, ReactionShape::StarRating { max: 5 }));
        assert!(caps.chapter_comments && caps.discussion_posts);
        assert!(!caps.reach.tor && caps.reach.direct);
        assert!(s.fetches_chapters_individually() && !s.listings_need_details());
        assert_eq!(s.post_gate(true), Gate::Enabled);
        assert!(matches!(s.post_gate(false), Gate::Disabled { .. }));
        assert_eq!(crate::source::session_origin(SOURCE_ID), Some(AUTH_URL));
    }

    #[tokio::test]
    async fn a_rating_belongs_to_a_story_not_a_series() {
        let s = source().await;
        let story = LiteroticaSource::story_ref("the-tide-ledger");
        let series = LiteroticaSource::series_ref(77001);
        assert_eq!(s.reaction_gate_for(&story, true), Gate::Enabled);
        assert!(matches!(s.reaction_gate_for(&story, false), Gate::Disabled { .. }));
        assert_eq!(s.reaction_gate_for(&series, true), Gate::Hidden);
        // Refused before anything is sent: a series, a value out of range,
        // a withdrawal the site has no way to take.
        let _g = crate::mock_site::tests::toggle_lock();
        for (work, reaction) in [(&series, Reaction::Stars { value: 4 }), (&story, Reaction::Stars { value: 6 }),
                                 (&story, Reaction::Clear), (&story, Reaction::Kudos)] {
            assert_eq!(s.react(work, reaction).await.unwrap(), ReactionOutcome { accepted: false, value: None });
        }
        let Err(AppError::NetworkError(said)) = s.react(&story, Reaction::Stars { value: 4 }).await else { panic!("needs a sign-in") };
        assert_eq!(said, "Sign in to Literotica to rate.");
    }

    #[tokio::test]
    async fn the_session_is_held_at_the_sign_in_service() {
        assert!(is_login_cookie("auth_token") && !is_login_cookie("authenticated"));
        assert!(is_session_cookie("auth_token") && is_session_cookie("authenticated") && is_session_cookie("sid"));
        assert!(!is_session_cookie("__cf_bm") && !is_session_cookie("cf_clearance") && !is_session_cookie(""));
        assert!(crate::source::session_logged_in(SOURCE_ID, "authenticated=1; auth_token=a.b.c"));
        assert!(!crate::source::session_logged_in(SOURCE_ID, "authenticated=1"));
        let s = source().await;
        assert_eq!(s.held_token().await, None);
        s.client.read().await.transport().set_cookies(AUTH_URL, "authenticated=1; auth_token=a.b.c; __cf_bm=x");
        s.settle_session().await;
        assert_eq!(s.held_token().await.as_deref(), Some("a.b.c"));
        let client = s.client.read().await;
        assert_eq!(client.transport().cookies_for("https://literotica.com"), "", "held for the sign-in service alone");
        client.transport().expire_cookies(AUTH_URL, is_session_cookie);
        drop(client);
        assert_eq!(s.held_token().await, None, "a sign-out drops it");
    }

    #[tokio::test]
    async fn comments_are_each_storys_and_posting_needs_an_account() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        let series = LiteroticaSource::series_ref(77001);
        let Err(AppError::NetworkError(said)) = s.fetch_discussion(&series, None, 1).await else { panic!("a series has none") };
        assert!(said.contains("each part of a series"));
        s.remember_stories([(800201, "the-glass-orchard-pt-01".to_string())]);
        assert_eq!(s.discussed_story(&series, Some(800201)).await.unwrap(), (800201, "the-glass-orchard-pt-01".to_string()));
        assert_eq!(s.known_story_id("the-glass-orchard-pt-01"), Some(800201));
        let story = LiteroticaSource::story_ref("the-tide-ledger");
        let post = DiscussionPost { chapter: None, parent: None, body: "  ".into() };
        assert!(matches!(s.post_discussion(&story, &post).await, Err(AppError::NetworkError(m)) if m == "Write something to post."));
        let post = DiscussionPost { chapter: None, parent: None, body: "Lovely.".into() };
        assert!(matches!(s.post_discussion(&story, &post).await, Err(AppError::NetworkError(m)) if m == "Sign in to Literotica to post."));
    }

    #[tokio::test]
    async fn users_numbers_are_remembered_by_name() {
        let s = source().await;
        assert_eq!(s.known_user_id("Marrowmere"), None);
        s.remember_users([("Marrowmere".to_string(), 5120)]);
        assert_eq!(s.known_user_id("marrowmere"), Some(5120));
    }

    #[tokio::test]
    async fn a_search_without_words_is_refused_before_sending() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        let q = crate::source::search::SearchQuery::new(SOURCE_ID, search::VERSION);
        let Err(AppError::NetworkError(message)) = s.search(&q, 1).await else { panic!("refused before sending") };
        assert_eq!(message, "Type something to search Literotica for.");
    }

    #[tokio::test]
    async fn refuses_while_the_mock_archive_is_on() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        crate::mock_site::set_enabled(true);
        let work = ExternalRef { source: SOURCE_ID.into(), external_id: "the-tide-ledger".into(), url: String::new() };
        let r = s.fetch_work(&work, None).await;
        crate::mock_site::set_enabled(false);
        assert!(matches!(r, Err(AppError::NetworkError(m)) if m.contains("mock archive")));
    }
}
