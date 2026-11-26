//! Wattpad: stories, their authors and each part's comments (its reading
//! lists, community pages, paid-story shop and writing tools are not
//! this app's business).
//!
//! Rules of this source:
//! - **The site's own data service, never its pages.** Everything is read
//!   from the JSON service the site's pages are built on
//!   (`www.wattpad.com/api/v3`, `/v4`, `/v5`); a part's text is the one
//!   HTML fragment (`/apiv2/?m=storytext`). Page addresses are only
//!   recognised as links and shown as the place to open a work.
//! - **An account is optional, and decides what is listed.** Signed out,
//!   the site lists no mature stories. Signed in (the site's own sign-in
//!   form, by name and password), a search asks for them only when the
//!   account's own content setting allows them: the setting is obeyed,
//!   never changed.
//! - **A story is a work, a part a chapter.** One request gives a story's
//!   details and its whole table of contents; each part's text is one
//!   more. A link to a part opens its story.
//! - **A listing states characters, not words.** The site measures a
//!   story's length in characters; a listing row carries that as its own
//!   figure. The word count is the sum of the parts' own, known once the
//!   story's record has been read.
//! - **Comments belong to a part, and only the part's own are shown.**
//!   The site's feed mixes them with the comments readers leave on
//!   single paragraphs; those are dropped. The feed is paged by a cursor,
//!   remembered while the app runs.
//! - **Nothing is written to the site.** Votes and posting comments are
//!   not part of this source yet.
//!
//! Keys: a story by its number, a part link as `p:{number}` until its
//! story is known, a user by username.

pub mod parse;
pub mod search;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tokio::sync::RwLock;

use crate::client::{FailureKind, SiteHooks};
use crate::error::AppError;
use crate::models::{Chapter, CommentsPage, ExternalRef, WorkSummary};
use crate::source::ao3::AO3Client;

use super::{DiscussionShape, FetchedWork, LinkTarget, ListingPage, ReactionShape, Reachability, SessionIdentity, Source,
            SourceCapabilities, UserPane, Vocabulary};

pub const SOURCE_ID: &str = "wattpad";
pub const BASE_URL: &str = "https://www.wattpad.com";
/// The domain the site sets its cookies for.
const COOKIE_DOMAIN: &str = "wattpad.com";
/// The cookie that carries a sign-in.
const TOKEN_COOKIE: &str = "token";
const NAME: &str = "Wattpad";
/// What a part link's key starts with; a story's key is all digits.
const PART_PREFIX: &str = "p:";

/// What is asked for about a story in a listing.
const LISTED_FIELDS: &str = "id,title,description,url,user(name,username,avatar),completed,mature,tags,language(name),\
    createDate,modifyDate,lastPublishedPart(createDate),numParts,length,voteCount,readCount,commentCount,isPaywalled";
/// What is asked for about each part of a story.
const PART_FIELDS: &str = "id,title,draft,wordCount,length,createDate";
const USER_FIELDS: &str = "username,name,avatar,description,createDate,location,numStoriesPublished,numFollowing,numFollowers";

/// How many stories of an author's list are asked for at once.
const AUTHOR_PAGE: u32 = 20;
/// How many rows of a part's comment feed are asked for at once.
const FEED_ROWS: u32 = 50;
/// A page of comments is full at this many of the part's own.
const COMMENTS_PAGE: usize = 20;
/// The most feed requests one page of comments may cost.
const FEED_REQUESTS: usize = 4;
/// The most comments on one page whose replies are fetched with it.
const REPLY_FETCHES: usize = 5;

/// The cookie that proves a sign-in.
pub fn is_login_cookie(name: &str) -> bool {
    name == TOKEN_COOKIE
}

/// What a sign-out drops: the sign-in's token. The site's other cookies
/// are any visitor's.
pub fn is_session_cookie(name: &str) -> bool {
    name == TOKEN_COOKIE
}

struct Hooks;

impl SiteHooks for Hooks {
    fn source(&self) -> &'static str { SOURCE_ID }
}

static HOOKS: Hooks = Hooks;

pub struct WattpadSource {
    client: Arc<RwLock<AO3Client>>,
    capabilities: SourceCapabilities,
    /// Where each page of a part's comments starts in the site's feed, by
    /// (part, page): the cursor the page before it ended on.
    cursors: Mutex<HashMap<(u64, u32), String>>,
    /// Each comment seen, by its number here: the site's own key for it
    /// and its page on the site.
    comments: Mutex<HashMap<u64, (String, String)>>,
    /// Whether the signed-in account lets mature stories be listed, with
    /// the sign-in it was read for.
    mature: Mutex<Option<(String, bool)>>,
}

impl WattpadSource {
    pub fn new(client: Arc<RwLock<AO3Client>>) -> Self {
        WattpadSource {
            client,
            capabilities: Self::declare(),
            cursors: Mutex::new(HashMap::new()),
            comments: Mutex::new(HashMap::new()),
            mature: Mutex::new(None),
        }
    }

    fn declare() -> SourceCapabilities {
        SourceCapabilities {
            id: SOURCE_ID.to_string(),
            name: NAME.to_string(),
            host: "www.wattpad.com".to_string(),
            // Tor is untested against this site; it is not tried until it
            // has been.
            reach: Reachability { tor: false, direct: true },
            // The site's votes are per part; not part of this source yet.
            reaction: ReactionShape::None,
            discussion: DiscussionShape::Threaded,
            chapter_comments: true,
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
                reaction_verb: "Vote".to_string(),
                reply_verb: None,
                rating_label: "Rating".to_string(),
                site_short: "Wattpad".to_string(),
                open_on_site: "Open on Wattpad".to_string(),
                copy_link: "Copy Wattpad link".to_string(),
                refresh: "Refresh from Wattpad".to_string(),
                subscribe_verb: None,
            },
        }
    }

    // -- Keys and addresses ---------------------------------------------------

    pub fn story_url(id: u64) -> String {
        format!("{BASE_URL}/story/{id}")
    }

    pub fn part_url(id: u64) -> String {
        format!("{BASE_URL}/{id}")
    }

    pub fn profile_url(username: &str) -> String {
        format!("{BASE_URL}/user/{username}")
    }

    fn story_ref(id: u64) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: id.to_string(), url: Self::story_url(id) }
    }

    fn part_ref(id: u64) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: format!("{PART_PREFIX}{id}"), url: Self::part_url(id) }
    }

    fn user_ref(username: &str) -> ExternalRef {
        ExternalRef { source: SOURCE_ID.to_string(), external_id: username.to_string(), url: Self::profile_url(username) }
    }

    /// The part a work key names, when it is a part link's key.
    fn part_of_key(external_id: &str) -> Option<u64> {
        external_id.strip_prefix(PART_PREFIX)?.parse().ok()
    }

    /// The path of a link on this site, without query or fragment — None
    /// for any other host.
    fn site_path(input: &str) -> Option<&str> {
        let rest = input.strip_prefix("https://").or_else(|| input.strip_prefix("http://")).unwrap_or(input);
        let rest = rest.strip_prefix("www.").or_else(|| rest.strip_prefix("m.")).unwrap_or(rest);
        let rest = rest.strip_prefix("wattpad.com")?;
        let path = rest.split(['?', '#']).next().unwrap_or("");
        if path.is_empty() { Some("/") } else if path.starts_with('/') { Some(path) } else { None }
    }

    /// The number a path segment opens with (`212587594-no-angel`).
    fn leading_number(segment: &str) -> Option<u64> {
        let digits = segment.split('-').next().filter(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))?;
        digits.parse().ok()
    }

    /// `/story/{number}[-name]` → the story.
    fn story_in(path: &str) -> Option<u64> {
        let segment = path.strip_prefix("/story/")?.trim_end_matches('/');
        if segment.contains('/') { return None }
        Self::leading_number(segment)
    }

    /// `/{number}[-name]` → the part; a comment's page (`/{number}/comment/…`)
    /// names its part the same way.
    fn part_in(path: &str) -> Option<u64> {
        let mut segments = path.strip_prefix('/')?.split('/');
        let part = Self::leading_number(segments.next()?)?;
        match segments.next() {
            None | Some("") | Some("comment") | Some("paragraph") => Some(part),
            _ => None,
        }
    }

    /// `/user/{name}[/…]` → the user.
    fn user_in(path: &str) -> Option<&str> {
        path.strip_prefix("/user/")?.split('/').next().filter(|n| !n.is_empty())
    }

    /// A name as one segment of an address.
    fn segment(name: &str) -> String {
        url::form_urlencoded::byte_serialize(name.as_bytes()).collect::<String>().replace('+', "%20")
    }

    fn query(pairs: &[(String, String)]) -> String {
        url::form_urlencoded::Serializer::new(String::new()).extend_pairs(pairs).finish()
    }

    fn story_request(id: u64) -> String {
        format!("{BASE_URL}/api/v3/stories/{id}?fields={LISTED_FIELDS},parts({PART_FIELDS})")
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

    /// One read from the site, judged by the caller.
    async fn get(&self, url: &str, accept: &str) -> Result<crate::client::PostOutcome, AppError> {
        Self::guard()?;
        let client = self.client.read().await;
        client.transport().get_outcome(url, &[("Accept", accept)], &|status| status < 400, &HOOKS).await
    }

    /// One answer from the site's data service.
    async fn api(&self, url: &str) -> Result<String, AppError> {
        let out = self.get(url, "application/json").await?;
        if out.status >= 400 {
            let said = parse::message(&out.body).map(|m| format!(" ({m})")).unwrap_or_default();
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} for {url}{said}", out.status),
            });
        }
        Ok(out.body)
    }

    /// The sign-in's token as the jar holds it.
    async fn held_token(&self) -> Option<String> {
        self.client.read().await.transport().cookies_for(BASE_URL).split(';').map(str::trim)
            .find_map(|part| part.strip_prefix(TOKEN_COOKIE).and_then(|rest| rest.strip_prefix('=')))
            .filter(|value| !value.is_empty()).map(str::to_string)
    }

    /// Who the site says the jar's sign-in belongs to (one request).
    async fn current_user(&self) -> Result<Option<String>, AppError> {
        let url = format!("{BASE_URL}/api/v3/internal/current_user?fields=username");
        let out = self.get(&url, "application/json").await?;
        if out.status >= 500 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} asking {NAME} who is signed in", out.status),
            });
        }
        // Signed out, the site answers a 400 in its own words.
        Ok(if out.status < 400 { parse::parse_current_user(&out.body) } else { None })
    }

    /// Whether the signed-in account's content setting lets mature
    /// stories be listed. Read once per sign-in (two requests); false
    /// when signed out or when the setting cannot be read.
    async fn allows_mature(&self) -> bool {
        let Some(token) = self.held_token().await else { return false };
        let held = self.mature.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
        if let Some((_, allowed)) = held.filter(|(for_token, _)| *for_token == token) { return allowed }
        let Ok(Some(username)) = self.current_user().await else { return false };
        crate::client::pacing::request_gap().await;
        let url = format!("{BASE_URL}/v5/users/{}/content-settings", Self::segment(&username));
        let read = self.api(&url).await.ok().and_then(|body| parse::includes_mature(&body));
        crate::client::pacing::request_gap().await;
        let Some(allowed) = read else {
            log_info!("wattpad", "the account's content setting could not be read; mature stories are not asked for");
            return false;
        };
        *self.mature.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((token, allowed));
        allowed
    }

    /// The story a part belongs to (one request, then the pause before
    /// the next).
    async fn story_of_part(&self, part: u64) -> Result<u64, AppError> {
        let body = crate::steps::run("Part", self.api(&format!("{BASE_URL}/v4/parts/{part}?fields=id,group(id)"))).await?;
        let story = parse::part_story(&body)
            .ok_or_else(|| AppError::ParseError(format!("{NAME} named no story for part {part}")))?;
        crate::client::pacing::request_gap().await;
        Ok(story)
    }

    // -- Comments -------------------------------------------------------------

    fn cursor(&self, part: u64, page: u32) -> Option<String> {
        self.cursors.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(&(part, page)).cloned()
    }

    fn keep_cursor(&self, part: u64, page: u32, cursor: String) {
        self.cursors.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert((part, page), cursor);
    }

    fn remember_comments<'a>(&self, listed: impl IntoIterator<Item = &'a parse::ListedComment>) {
        let mut held = self.comments.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for c in listed { held.insert(c.comment.id, (c.key.clone(), c.link.clone())); }
    }

    fn comments_request(namespace: &str, key: &str, after: Option<&str>) -> String {
        let mut url = format!("{BASE_URL}/v5/comments/namespaces/{namespace}/resources/{}/comments?limit={FEED_ROWS}", Self::segment(key));
        if let Some(after) = after {
            url.push_str("&after=");
            url.push_str(&Self::segment(after));
        }
        url
    }

    /// One page of a part's own comments, starting at `cursor` in the
    /// site's feed, with where the next page starts. The feed is mostly
    /// paragraph comments, so a page may take several requests; it stops
    /// short of full rather than take more than `FEED_REQUESTS`.
    async fn comments_from(&self, part: u64, mut cursor: Option<String>) -> Result<(Vec<parse::ListedComment>, Option<String>), AppError> {
        let mut kept = Vec::new();
        for request in 0..FEED_REQUESTS {
            if request > 0 { crate::client::pacing::request_gap().await; }
            let url = Self::comments_request("parts", &part.to_string(), cursor.as_deref());
            let answer = parse::parse_comments(&self.api(&url).await?, part, false)?;
            kept.extend(answer.comments);
            cursor = answer.after;
            if cursor.is_none() || kept.len() >= COMMENTS_PAGE { break }
        }
        Ok((kept, cursor))
    }
}

#[async_trait]
impl Source for WattpadSource {
    fn capabilities(&self) -> &SourceCapabilities {
        &self.capabilities
    }

    fn fetches_chapters_individually(&self) -> bool { true }

    /// A story's page names a work; so does a part's, as the story it
    /// belongs to.
    fn resolve(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        if let Some(id) = Self::story_in(path) { return Some(Self::story_ref(id)) }
        Self::part_in(path).map(Self::part_ref)
    }

    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let path = Self::site_path(input.trim())?;
        Self::user_in(path).map(Self::user_ref)
    }

    fn classify(&self, input: &str) -> Option<LinkTarget> {
        let path = Self::site_path(input.trim())?;
        if let Some(work) = self.resolve(input) {
            return Some(LinkTarget::Work { work, entire: false });
        }
        if let Some(name) = Self::user_in(path) {
            return Some(LinkTarget::User { user: Self::user_ref(name), pane: UserPane::Profile });
        }
        // Reading lists, tag pages, the home feed: the site's, with no view here.
        Some(LinkTarget::Unsupported)
    }

    fn work_ref(&self, external_id: &str) -> Option<ExternalRef> {
        if let Some(part) = Self::part_of_key(external_id) { return Some(Self::part_ref(part)) }
        external_id.parse().ok().map(Self::story_ref)
    }

    fn comment_url(&self, comment_id: u64) -> Option<String> {
        self.comments.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&comment_id).map(|(_, link)| link.clone()).filter(|link| !link.is_empty())
    }

    /// The story's record and its table of contents: one request. A part
    /// link's key is first asked which story it belongs to; the work
    /// fetched is then that story, under the story's own key.
    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        let id = match Self::part_of_key(&work.external_id) {
            Some(part) => self.story_of_part(part).await?,
            None => work.external_id.parse::<u64>()
                .map_err(|_| AppError::ElementNotFound(format!("{} is no {NAME} story", work.external_id)))?,
        };
        let body = crate::steps::run("Story", self.api(&Self::story_request(id))).await?;
        let (listed, chapters) = parse::parse_story(&body)?;
        Ok(FetchedWork { summary: listed.summary, chapters, stats: listed.stats, reacted_by: Vec::new(), authors: listed.authors })
    }

    /// One part's whole text: one request.
    async fn fetch_chapter(&self, work: &ExternalRef, chapter: &Chapter) -> Result<Chapter, AppError> {
        let part = chapter.id
            .ok_or_else(|| AppError::ElementNotFound(format!("chapter {} of {} has no id", chapter.number, work.external_id)))?;
        let url = format!("{BASE_URL}/apiv2/?m=storytext&id={part}");
        let out = self.get(&url, "text/html,*/*;q=0.8").await?;
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} for {url}", out.status),
            });
        }
        let content = parse::part_blocks(&out.body, &Self::part_url(part));
        if content.is_empty() {
            // A paid part answers without its text; so might a part the
            // account may not read.
            return Err(AppError::ElementNotFound(format!(
                "{NAME} gave no text for this part. A paid part, or one the account may not read, is not fetched.")));
        }
        Ok(Chapter {
            id: Some(part),
            title: chapter.title.clone(),
            number: chapter.number,
            content,
            notes_before: None,
            notes_after: None,
        })
    }

    /// One page of what the author has published, as the site orders it.
    async fn fetch_author_works(&self, author: &ExternalRef, page: u32) -> Result<ListingPage, AppError> {
        let offset = (page.max(1) - 1) * AUTHOR_PAGE;
        let url = format!("{BASE_URL}/v4/users/{}/stories/published?offset={offset}&limit={AUTHOR_PAGE}&fields=stories({LISTED_FIELDS}),total,nextUrl",
                          Self::segment(&author.external_id));
        let mut listing = parse::parse_listing(&self.api(&url).await?, offset, AUTHOR_PAGE)?;
        // The author's own list need not name them on every story.
        for work in &mut listing.works {
            if work.summary.authors.is_empty() {
                work.summary.authors = vec![author.external_id.clone()];
            }
        }
        Ok(listing)
    }

    async fn fetch_author(&self, author: &ExternalRef) -> Result<crate::models::SourceUserProfile, AppError> {
        let url = format!("{BASE_URL}/api/v3/users/{}?fields={USER_FIELDS}", Self::segment(&author.external_id));
        parse::parse_profile(&self.api(&url).await?)
    }

    /// The site's user search, by name.
    async fn search_users(&self, query: &str) -> Result<Vec<crate::models::AO3User>, AppError> {
        let text = query.trim();
        if text.is_empty() { return Ok(Vec::new()) }
        let url = format!("{BASE_URL}/v4/search/users/?{}&fields=username,name,avatar",
                          Self::query(&[("query".into(), text.to_string()), ("limit".into(), "20".into()), ("offset".into(), "0".into())]));
        parse::parse_users(&self.api(&url).await?)
    }

    /// The site's sign-in form, as its own page sends it. The site
    /// answers either way by sending the reader on: back to the form with
    /// an error, or onward with the sign-in's token set.
    async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        Self::guard()?;
        let url = format!("{BASE_URL}/login?nextUrl=%2Fhome");
        let form = vec![("username".to_string(), username.to_string()), ("password".to_string(), password.to_string())];
        let referer = format!("{BASE_URL}/login");
        let out = {
            let client = self.client.read().await;
            client.transport().post_form(&url, &form, &[("Referer", referer.as_str()), ("Origin", BASE_URL)],
                                         &|status, _| status < 400, &HOOKS).await?
        };
        if out.status >= 400 {
            return Err(AppError::Http {
                kind: FailureKind::from_status(out.status, None),
                detail: format!("HTTP {} signing in to {NAME}", out.status),
            });
        }
        // The site sets its cookies for every host of its domain; the
        // sign-in is kept under the one address the session lives at.
        self.client.read().await.transport().rehome_cookies(BASE_URL, COOKIE_DOMAIN, is_session_cookie);
        let signed_in = self.held_token().await.is_some();
        if !signed_in && !out.final_url.contains("error=") {
            // Names only: what the site set, to tell a changed sign-in
            // from a refused one.
            let names: Vec<String> = out.set_cookies.iter()
                .filter_map(|c| c.split('=').next().map(|n| n.trim().to_string())).filter(|n| !n.is_empty()).collect();
            log_info!("wattpad", "sign-in answered {} at {} without a token; cookies set: {:?}",
                out.status, out.final_url.split('?').next().unwrap_or(""), names);
        }
        Ok(signed_in)
    }

    async fn whoami(&self) -> Result<Option<SessionIdentity>, AppError> {
        if self.held_token().await.is_none() { return Ok(None) }
        Ok(self.current_user().await?.map(|username| SessionIdentity { external_id: username.clone(), username }))
    }

    /// One page of a part's own comments, newest first as the site lists
    /// them, each with its replies when it has few enough to fetch along.
    /// The site pages by cursor: a page not reached before is walked to
    /// from the nearest one that was.
    async fn fetch_discussion(&self, _work: &ExternalRef, chapter: Option<u64>, page: u32) -> Result<CommentsPage, AppError> {
        let Some(part) = chapter else {
            return Err(AppError::NetworkError(format!(
                "{NAME} keeps comments with each part of a story. Open a chapter to see its comments.")));
        };
        let page = page.max(1);
        let mut at = (1..=page).rev().find(|p| *p == 1 || self.cursor(part, *p).is_some()).unwrap_or(1);
        let (mut listed, next) = loop {
            let cursor = if at == 1 { None } else { self.cursor(part, at) };
            let (listed, next) = self.comments_from(part, cursor).await?;
            if let Some(next) = &next { self.keep_cursor(part, at + 1, next.clone()); }
            if at == page || next.is_none() { break (listed, next) }
            at += 1;
            crate::client::pacing::request_gap().await;
        };
        if at < page {
            // The feed ended before the page asked for.
            return Ok(CommentsPage { comments: Vec::new(), current_page: at, total_pages: at });
        }
        self.remember_comments(&listed);
        let mut fetched = 0;
        for c in listed.iter_mut().filter(|c| c.replies > 0) {
            if fetched == REPLY_FETCHES {
                c.comment.more_replies = c.replies;
                continue;
            }
            fetched += 1;
            crate::client::pacing::request_gap().await;
            let url = Self::comments_request("comments", &c.key, None);
            // The comment is listed either way; its replies are extra.
            match self.api(&url).await.and_then(|body| parse::parse_comments(&body, part, true)) {
                Ok(answer) => {
                    self.remember_comments(&answer.comments);
                    c.comment.more_replies = c.replies.saturating_sub(answer.comments.len() as u32);
                    c.comment.replies = answer.comments.into_iter().map(|r| r.comment).collect();
                }
                Err(e) => {
                    log_info!("wattpad", "replies not read: {e}");
                    c.comment.more_replies = c.replies;
                }
            }
        }
        Ok(CommentsPage {
            comments: listed.into_iter().map(|c| c.comment).collect(),
            current_page: page,
            total_pages: page + next.is_some() as u32,
        })
    }

    fn search_schema(&self) -> Option<crate::source::search::SearchSchema> {
        Some(search::schema())
    }

    async fn search(&self, query: &crate::source::search::SearchQuery, page: u32) -> Result<ListingPage, AppError> {
        Self::guard()?;
        let page = page.max(1);
        // Refused before anything is sent, the account's setting included.
        if search::search_params(query, page, false).is_none() {
            return Err(AppError::NetworkError(format!("Type something to search {NAME} for.")));
        }
        let mature = self.allows_mature().await;
        let params = search::search_params(query, page, mature).unwrap_or_default();
        let url = format!("{BASE_URL}/v4/search/stories?{}&fields=stories({LISTED_FIELDS}),total,nextUrl", Self::query(&params));
        parse::parse_listing(&self.api(&url).await?, (page - 1) * search::PAGE_SIZE, search::PAGE_SIZE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::Gate;

    async fn source() -> WattpadSource {
        // A direct client is a reqwest handle; nothing is sent in these tests.
        let client = Arc::new(RwLock::new(AO3Client::new_direct().await.unwrap()));
        WattpadSource::new(client)
    }

    #[tokio::test]
    async fn resolves_story_and_part_links() {
        let s = source().await;
        let r = s.resolve("https://www.wattpad.com/story/55001-the-tide-ledger").unwrap();
        assert_eq!((r.source.as_str(), r.external_id.as_str(), r.url.as_str()), (SOURCE_ID, "55001", "https://www.wattpad.com/story/55001"));
        assert_eq!(s.resolve("wattpad.com/story/55001?utm=x#top").unwrap().external_id, "55001");
        assert_eq!(s.resolve("http://m.wattpad.com/story/55001-the-tide-ledger/").unwrap().external_id, "55001");
        let part = s.resolve("https://www.wattpad.com/700101-the-tide-ledger-the-lamp-room").unwrap();
        assert_eq!((part.external_id.as_str(), part.url.as_str()), ("p:700101", "https://www.wattpad.com/700101"));
        assert_eq!(s.resolve("https://www.wattpad.com/700101/comment/700101__1700000000_e66e44bf51").unwrap().external_id, "p:700101");
        assert!(s.resolve("https://www.wattpad.com/story/the-tide-ledger").is_none());
        assert!(s.resolve("https://www.wattpad.com/story/55001/parts").is_none());
        assert!(s.resolve("https://www.wattpad.com/stories/lighthouse").is_none());
        assert!(s.resolve("https://www.wattpad.com/700101/other").is_none());
        assert!(s.resolve("https://www.wattpad.com/").is_none());
        assert!(s.resolve("https://notwattpad.com/story/55001").is_none());
        assert!(s.resolve("https://www.literotica.com/s/the-tide-ledger").is_none());
        assert_eq!(s.work_ref("55001").unwrap().url, "https://www.wattpad.com/story/55001");
        assert_eq!(s.work_ref("p:700101").unwrap().url, "https://www.wattpad.com/700101");
        assert!(s.work_ref("p:x").is_none() && s.work_ref("").is_none());
    }

    #[tokio::test]
    async fn classifies_the_sites_links() {
        let s = source().await;
        assert!(matches!(s.classify("https://www.wattpad.com/story/55001-the-tide-ledger"),
                         Some(LinkTarget::Work { work, entire: false }) if work.external_id == "55001"));
        assert!(matches!(s.classify("https://www.wattpad.com/user/saltwick"),
                         Some(LinkTarget::User { user, pane: UserPane::Profile }) if user.external_id == "saltwick"));
        assert_eq!(s.resolve_user("https://wattpad.com/user/saltwick/following").unwrap().url, "https://www.wattpad.com/user/saltwick");
        assert_eq!(s.classify("https://www.wattpad.com/list/9911-favourites"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://www.wattpad.com/stories/lighthouse"), Some(LinkTarget::Unsupported));
        assert_eq!(s.classify("https://example.com/story/55001"), None);
    }

    #[test]
    fn the_services_addresses() {
        let story = WattpadSource::story_request(55001);
        assert!(story.starts_with("https://www.wattpad.com/api/v3/stories/55001?fields=id,title,"));
        assert!(story.ends_with(",parts(id,title,draft,wordCount,length,createDate)"));
        assert_eq!(WattpadSource::comments_request("parts", "700101", None),
                   "https://www.wattpad.com/v5/comments/namespaces/parts/resources/700101/comments?limit=50");
        assert_eq!(WattpadSource::comments_request("comments", "700101__1700000000_e66e44bf51", Some("700101_ab_1_cd")),
                   "https://www.wattpad.com/v5/comments/namespaces/comments/resources/700101__1700000000_e66e44bf51/comments?limit=50&after=700101_ab_1_cd");
        assert_eq!(WattpadSource::query(&[("query".into(), "tide #sea".into()), ("limit".into(), "15".into())]), "query=tide+%23sea&limit=15");
        assert_eq!(WattpadSource::segment("Some Name"), "Some%20Name");
    }

    #[tokio::test]
    async fn declares_reading_search_users_and_comments_without_writes() {
        let s = source().await;
        let caps = s.capabilities().clone();
        assert_eq!(caps.sign_in, crate::source::SignInShape::Credentials);
        assert!(caps.login && caps.search && caps.author_listings && caps.user_search && caps.update_checks);
        assert_eq!((caps.discussion, caps.reaction), (DiscussionShape::Threaded, ReactionShape::None));
        assert!(caps.chapter_comments && !caps.discussion_posts);
        assert!(!caps.reach.tor && caps.reach.direct);
        assert!(s.fetches_chapters_individually() && !s.listings_need_details());
        assert_eq!(s.reaction_gate(true), Gate::Hidden);
        assert_eq!(s.post_gate(true), Gate::Hidden);
        assert_eq!(crate::source::session_origin(SOURCE_ID), Some(BASE_URL));
    }

    #[tokio::test]
    async fn the_sign_in_is_the_token_cookie() {
        assert!(is_login_cookie("token") && !is_login_cookie("wp_id"));
        assert!(is_session_cookie("token") && !is_session_cookie("wp_id") && !is_session_cookie("lang"));
        assert!(crate::source::session_logged_in(SOURCE_ID, "wp_id=a; token=b"));
        assert!(!crate::source::session_logged_in(SOURCE_ID, "wp_id=a; token="));
        assert_eq!(crate::source::session_part(SOURCE_ID, "wp_id=a; token=b; lang=1"), "token=b");
        let s = source().await;
        assert_eq!(s.held_token().await, None);
        assert_eq!(s.whoami().await.unwrap(), None, "nothing is asked while signed out");
        assert!(!s.allows_mature().await, "signed out, mature stories are not asked for");
        s.client.read().await.transport().set_cookies(BASE_URL, "wp_id=a; token=b");
        assert_eq!(s.held_token().await.as_deref(), Some("b"));
        s.client.read().await.transport().expire_cookies(BASE_URL, is_session_cookie);
        assert_eq!(s.held_token().await, None, "a sign-out drops it");
    }

    #[tokio::test]
    async fn comments_are_each_parts_and_their_pages_are_remembered() {
        let s = source().await;
        let story = WattpadSource::story_ref(55001);
        let Err(AppError::NetworkError(said)) = s.fetch_discussion(&story, None, 1).await else { panic!("a story has none of its own") };
        assert!(said.contains("each part of a story"));
        assert_eq!(s.cursor(700101, 2), None);
        s.keep_cursor(700101, 2, "700101_ab_1_cd".to_string());
        assert_eq!(s.cursor(700101, 2).as_deref(), Some("700101_ab_1_cd"));
        assert_eq!(s.cursor(700102, 2), None);
        assert_eq!(s.comment_url(7), None);
        let listed = parse::parse_comments(r#"{"comments": [{"resource": {"namespace": "parts"}, "user": {"name": "quillmoor"},
            "commentId": {"resourceId": "700101__1700000000_e66e44bf51"}, "text": "x", "deeplink": "https://www.wattpad.com/700101/comment/k"}]}"#,
            700101, false).unwrap();
        s.remember_comments(&listed.comments);
        assert_eq!(s.comment_url(listed.comments[0].comment.id).as_deref(), Some("https://www.wattpad.com/700101/comment/k"));
    }

    #[tokio::test]
    async fn a_search_without_words_is_refused_before_sending() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        let q = crate::source::search::SearchQuery::new(SOURCE_ID, search::VERSION);
        let Err(AppError::NetworkError(message)) = s.search(&q, 1).await else { panic!("refused before sending") };
        assert_eq!(message, "Type something to search Wattpad for.");
    }

    #[tokio::test]
    async fn refuses_while_the_mock_archive_is_on() {
        let s = source().await;
        let _g = crate::mock_site::tests::toggle_lock();
        crate::mock_site::set_enabled(true);
        let r = s.fetch_work(&WattpadSource::story_ref(55001), None).await;
        crate::mock_site::set_enabled(false);
        assert!(matches!(r, Err(AppError::NetworkError(m)) if m.contains("mock archive")));
    }
}
