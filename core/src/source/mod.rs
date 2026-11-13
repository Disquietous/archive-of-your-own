//! Sources: where works come from, behind one contract (multi-source plan
//! Areas 4, 8 and 12).
//!
//! A `Source` resolves a link to an external id, fetches a work with its
//! chapters, and optionally serves its discussion. What it offers beyond
//! that is declared as `SourceCapabilities`: not AO3's verbs as flags, but
//! *shapes* the UI renders by (a kudos button or a star control, threaded
//! comments or rated reviews) plus the vocabulary to label them. The UI
//! never asks which source a work is from; it asks what shape to draw.
//!
//! The AO3 adapter (`ao3.rs`) wraps the existing AO3 client rather than
//! moving its code: that move waits until AO3 is reachable again and its
//! request path can be re-verified live. The rated mock (`mock_rated.rs`)
//! exercises the second set of shapes offline.

pub mod ao3;
pub mod mock_rated;
pub mod scribblehub;
pub mod search;

use std::sync::Arc;

use async_trait::async_trait;

use crate::error::AppError;
use crate::models::{Chapter, CommentsPage, ExternalRef, WorkSummary};
use search::{Autocomplete, FieldOption, SearchQuery, SearchSchema};

/// How a reader reacts to a work on this source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReactionShape {
    /// No reaction of any kind (a local file).
    None,
    /// One tap, counted, permanent (AO3 kudos).
    Kudos,
    /// A star rating 1..=max; the reader's own value is readable and, with
    /// a login, settable. The site's average is a separate stat.
    StarRating { max: u8 },
}

/// What discussion a work carries on this source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscussionShape {
    None,
    /// Threaded comments with replies (AO3).
    Threaded,
    /// Flat reviews, each carrying a star rating.
    Reviews,
}

/// Which private transports can reach the source. A source that blocks
/// Tor is refused with a message in Tor mode rather than tried.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Reachability {
    pub tor: bool,
    pub direct: bool,
}

/// The words the UI uses for this source's shapes. Never hard-coded per
/// source in Swift.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Vocabulary {
    /// Title of the discussion panel ("Comments", "Reviews").
    pub discussion_title: String,
    /// The reaction verb ("Leave kudos", "Rate this story").
    pub reaction_verb: String,
    /// The reply verb when the discussion is threaded; None otherwise.
    pub reply_verb: Option<String>,
    /// Label for the site-wide rating stat chip ("Rating").
    pub rating_label: String,
    /// Short site name for a button caption or badge ("AO3", "SH").
    pub site_short: String,
    /// "Open on AO3" — the open-on-site control's label.
    pub open_on_site: String,
    /// "Copy AO3 link".
    pub copy_link: String,
    /// "Refresh from AO3" — the refresh control's label; the fetch itself
    /// is dispatched by the row's source, never chosen by the UI.
    pub refresh: String,
    /// The subscribe verb ("Subscribe"); None when the source has no
    /// subscriptions.
    pub subscribe_verb: Option<String>,
}

/// How an account at the source is signed in (Area 1): not at all, with a
/// username and password the app sends itself (AO3), or by the user on
/// the site's own sign-in page in a web view the platform shows, whose
/// cookies become the session (a site behind a human check).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SignInShape {
    None,
    Credentials,
    Site,
}

/// Who a live session belongs to, as the source names them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionIdentity {
    /// The account's key at the source (AO3's lowercased username, a
    /// numeric profile id elsewhere).
    pub external_id: String,
    pub username: String,
}

/// Whether a stored session string (`name=value; ...`) carries the
/// source's login cookie. Static, by source id: storage rows are read
/// without an adapter instance at hand.
pub fn session_logged_in(source: &str, cookies: &str) -> bool {
    cookies.split(';').any(|part| {
        let (name, value) = part.trim().split_once('=').unwrap_or((part.trim(), ""));
        !value.is_empty() && is_login_cookie(source, name)
    })
}

/// Whether `name` is one of the cookies that prove a login at `source`.
pub fn is_login_cookie(source: &str, name: &str) -> bool {
    match source {
        crate::models::SOURCE_AO3 => crate::client::is_ao3_login_cookie(name),
        scribblehub::SOURCE_ID => scribblehub::is_login_cookie(name),
        _ => false,
    }
}

/// Whether `name` is a cookie a sign-out at `source` must drop: the login
/// cookies and anything else that carries the session. The site's other
/// cookies, a passed human check among them, are not the account's.
pub fn is_session_cookie(source: &str, name: &str) -> bool {
    match source {
        crate::models::SOURCE_AO3 => crate::client::is_ao3_login_cookie(name) || name == "_otwarchive_session",
        scribblehub::SOURCE_ID => scribblehub::is_session_cookie(name),
        _ => false,
    }
}

/// The origin a source's session cookies live under in the shared jar;
/// None for a source without accounts.
pub fn session_origin(source: &str) -> Option<&'static str> {
    match source {
        crate::models::SOURCE_AO3 => Some(crate::client::BASE_URL),
        scribblehub::SOURCE_ID => Some(scribblehub::BASE_URL),
        _ => None,
    }
}

/// The session cookies out of a `name=value; ...` string, same format.
pub fn session_part(source: &str, cookies: &str) -> String {
    cookies.split(';').map(str::trim)
        .filter(|part| is_session_cookie(source, part.split('=').next().unwrap_or("")))
        .collect::<Vec<_>>().join("; ")
}

/// Where and how the user signs in on the site itself (`SignInShape::Site`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SiteSignIn {
    /// The site's sign-in page.
    pub url: String,
    /// Name prefix of the cookie whose arrival means the sign-in is done.
    pub login_cookie_prefix: String,
}

/// Everything a source offers, declared once by its adapter. Gating means
/// hidden: a shape of None or a false flag draws nothing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SourceCapabilities {
    /// Stable id stored on every row ("ao3").
    pub id: String,
    /// Display name ("Archive of Our Own").
    pub name: String,
    /// The site's host as shown to the user ("archiveofourown.org").
    pub host: String,
    pub reach: Reachability,
    pub reaction: ReactionShape,
    pub discussion: DiscussionShape,
    /// Chapters carry their own comments as well as the work (ScribbleHub).
    pub chapter_comments: bool,
    pub search: bool,
    pub browse: bool,
    pub author_listings: bool,
    /// The source can find users by name (ScribbleHub's live search).
    /// Without it, a user is reached by profile link — or, on AO3, by
    /// username, which is the key there.
    pub user_search: bool,
    pub tag_listings: bool,
    pub update_checks: bool,
    pub login: bool,
    /// How an account is signed in; `None` exactly when `login` is false.
    pub sign_in: SignInShape,
    /// The site keeps its own bookmark records (AO3 bookmarks).
    pub remote_bookmarks: bool,
    pub subscriptions: bool,
    pub collections: bool,
    pub inbox: bool,
    /// The site lets a signed-in account block or mute another user.
    pub user_moderation: bool,
    /// A bare username is a user's key at the source (AO3), so a typed
    /// name reaches a profile and follows key by name. Elsewhere users are
    /// reached by profile link or the source's user search.
    pub username_is_key: bool,
    pub vocabulary: Vocabulary,
}

/// One source-specific number or text on a work, by registry key. The
/// label and order seed the fields registry on first sight.
#[derive(Debug, Clone, PartialEq)]
pub struct SourceStat {
    pub key: String,
    pub label: String,
    pub num: Option<f64>,
    pub text: Option<String>,
    pub order: i64,
}

impl SourceStat {
    pub fn num(key: &str, label: &str, value: f64, order: i64) -> Self {
        SourceStat { key: key.into(), label: label.into(), num: Some(value), text: None, order }
    }
}

/// What a fetch of one work returns: the AO3-shaped record, its chapters
/// (stubs allowed), any source-specific stats, and the names the page
/// shows as having reacted (AO3's kudos list), for "did I react
/// elsewhere" bookkeeping.
#[derive(Debug, Clone)]
pub struct FetchedWork {
    pub summary: WorkSummary,
    pub chapters: Vec<Chapter>,
    pub stats: Vec<SourceStat>,
    pub reacted_by: Vec<String>,
    /// The work's authors as users of the source, when the source keys
    /// users by something other than the byline (`id` = its profile id,
    /// with the profile URL). AO3 leaves this empty: its bylines are the
    /// account keys and are recorded from `summary.authors`.
    pub authors: Vec<crate::models::AO3User>,
}

/// One work as a listing shows it: the blurb's summary, the source's
/// own figures, and its authors as source users.
#[derive(Debug, Clone)]
pub struct ListedWork {
    pub summary: WorkSummary,
    pub stats: Vec<SourceStat>,
    pub authors: Vec<crate::models::AO3User>,
}

/// One page of a listing (an author's works).
#[derive(Debug, Clone, Default)]
pub struct ListingPage {
    pub works: Vec<ListedWork>,
    pub has_next: bool,
    /// Highest page the pager shows (1 = no pager).
    pub total_pages: u32,
    /// The listing's own result count when the page states one.
    pub total_works: Option<u32>,
}

// ---------------------------------------------------------------------------
// Controls (design/source-controls-plan.md)
// ---------------------------------------------------------------------------
//
// A control is what the user can do with one row right now. The UI never
// asks which source a row is from: it asks for the row's controls and draws
// each one natively. Gating means hidden — a control the source has no
// shape for is `Hidden`; one that exists but needs a sign-in is `Disabled`
// with the reason to show.

/// Whether one control is drawn, and whether it can be used.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Gate {
    Hidden,
    Enabled,
    Disabled { reason: String },
}

impl Gate {
    pub fn when(shown: bool, enabled: bool, reason: &str) -> Gate {
        if !shown { Gate::Hidden } else if enabled { Gate::Enabled } else { Gate::Disabled { reason: reason.to_string() } }
    }
    pub fn is_shown(&self) -> bool { !matches!(self, Gate::Hidden) }
    pub fn is_enabled(&self) -> bool { matches!(self, Gate::Enabled) }
}

/// What the reader sends when reacting to a work.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Reaction {
    /// One tap, counted, permanent.
    Kudos,
    /// A star value 1..=max.
    Stars { value: u8 },
    /// Withdraw the reader's own rating.
    Clear,
}

/// What the source answered to a reaction. `accepted` false is the site
/// refusing (own work, duplicate, signed out), not a transport failure.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReactionOutcome {
    pub accepted: bool,
    /// The reader's own rating as the site now holds it; None for kudos.
    pub value: Option<u8>,
}

/// The stat key a star-rated source reports its site average under.
pub const STAT_SITE_RATING: &str = "rating";

/// The reaction control for one work: its shape, the reader's own state,
/// and whether it can be used.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ReactionControl {
    None,
    Kudos { given: bool, gate: Gate },
    /// `average` is the site's average as the control shows it, one
    /// decimal ("4.1"); None when the work has no rating yet.
    StarRating { max: u8, mine: Option<u8>, average: Option<String>, gate: Gate },
}

/// The lists a user's profile offers to open.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UserList {
    Works,
    Bookmarks,
    Collections,
}

/// Everything the UI draws for one work beyond the app-local controls
/// (download, reading lists, finished…), resolved from the row, its
/// source's capabilities and that source's account state. No network.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkControls {
    pub source: String,
    /// The stored canonical URL; None when the work has none (a local
    /// file), which hides open-on-site and copy-link.
    pub site_url: Option<String>,
    pub reaction: ReactionControl,
    pub discussion: DiscussionShape,
    pub chapter_comments: bool,
    pub subscribe: Gate,
    pub remote_bookmark: Gate,
    pub vocabulary: Vocabulary,
}

/// Same for a user (author or commenter).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UserControls {
    pub source: String,
    pub site_url: Option<String>,
    pub subscribe: Gate,
    /// Block and mute, together.
    pub moderation: Gate,
    pub lists: Vec<UserList>,
    pub author_listings: bool,
    pub username_is_key: bool,
    pub vocabulary: Vocabulary,
}

/// Same for a tag on a source.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagControls {
    pub source: String,
    pub site_url: Option<String>,
    pub vocabulary: Vocabulary,
}

/// Which of a user's pages a link names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UserPane {
    Profile,
    Works,
    Bookmarks,
    Collections,
}

/// What a link points at, as its source's adapter reads it (Area 10).
/// The adapter owns its URL shapes; the bridge turns the references into
/// row ids.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkTarget {
    /// `entire`: the link asks for the whole work on one page.
    Work { work: ExternalRef, entire: bool },
    /// `chapter_id` is the source's own chapter id.
    Chapter { work: ExternalRef, chapter_id: String },
    User { user: ExternalRef, pane: UserPane },
    Series { series: ExternalRef },
    Collection { name: String },
    Tag { name: String },
    /// A page of this source the app has no view for.
    Unsupported,
}

/// The ingest contract (Area 4): read-only, plus the one social write
/// every source shapes the same way (`react`). Other writes sit behind
/// source-specific interfaces reached by capability.
#[async_trait]
pub trait Source: Send + Sync {
    fn capabilities(&self) -> &SourceCapabilities;

    fn id(&self) -> &str {
        &self.capabilities().id
    }

    /// Whether `input` (a URL, or a path for file sources) names a work on
    /// this source, and which one. The adapter owns its URL shapes.
    fn resolve(&self, input: &str) -> Option<ExternalRef>;

    /// Whether `input` is a link to a user's profile on this source, and
    /// which user (`external_id` = the source's key for them). Default: none.
    fn resolve_user(&self, input: &str) -> Option<ExternalRef> {
        let _ = input;
        None
    }

    /// What a link on this source points at; None when the link is not
    /// this source's. Default: a work or a profile, as `resolve` and
    /// `resolve_user` read it.
    fn classify(&self, input: &str) -> Option<LinkTarget> {
        if let Some(work) = self.resolve(input) {
            return Some(LinkTarget::Work { work, entire: false });
        }
        self.resolve_user(input).map(|user| LinkTarget::User { user, pane: UserPane::Profile })
    }

    /// The reference for one of this source's works named by its id alone
    /// (a series' previous/next link). None when the id is not enough to
    /// address the work.
    fn work_ref(&self, external_id: &str) -> Option<ExternalRef> {
        let _ = external_id;
        None
    }

    /// The site page for one comment, when comments have their own pages.
    fn comment_url(&self, comment_id: u64) -> Option<String> {
        let _ = comment_id;
        None
    }

    /// A request URL as the request log shows it. Default: unchanged.
    fn display_url(&self, url: &str) -> Option<String> {
        let _ = url;
        None
    }

    /// Whether the source serves one page per chapter. When true,
    /// `fetch_work` returns stub chapters (id + title, no text) and the
    /// reader fills them in through `fetch_chapter` one at a time; the
    /// save path then never overwrites fetched text with a stub.
    fn fetches_chapters_individually(&self) -> bool { false }

    /// The work and every chapter. The adapter owns the fetch plan (one
    /// page, or TOC plus per-chapter pages). `work.url` is the stored
    /// canonical URL, for sources whose addresses carry more than the id.
    /// `known` is what the library already holds for the work (a listing
    /// blurb, an earlier fetch): an adapter whose work page lacks a figure
    /// the library has (ScribbleHub's word count) skips the extra request.
    async fn fetch_work(&self, work: &ExternalRef, known: Option<&WorkSummary>) -> Result<FetchedWork, AppError>;

    /// One chapter's text. Default: the whole work, then that chapter —
    /// right for sources that serve a work as one page.
    async fn fetch_chapter(&self, work: &ExternalRef, chapter: &Chapter) -> Result<Chapter, AppError> {
        let fetched = self.fetch_work(work, None).await?;
        fetched.chapters.into_iter().find(|c| c.number == chapter.number)
            .ok_or_else(|| AppError::ElementNotFound(format!("chapter {} of {}", chapter.number, work.external_id)))
    }

    /// One page of a user's works listing. Default: none — AO3's own
    /// listing paths stay in the client until the AO3Source move.
    async fn fetch_author_works(&self, author: &ExternalRef, page: u32) -> Result<ListingPage, AppError> {
        let _ = (author, page);
        Err(AppError::NetworkError(format!("{} has no author listings to fetch", self.capabilities().name)))
    }

    /// Users whose names match `query`, as the source's own search ranks
    /// them. Default: none.
    async fn search_users(&self, query: &str) -> Result<Vec<crate::models::AO3User>, AppError> {
        let _ = query;
        Err(AppError::NetworkError(format!("{} has no user search", self.capabilities().name)))
    }

    /// A user's profile page. Default: none — AO3's own profile path stays
    /// in the client until the AO3Source move.
    async fn fetch_author(&self, author: &ExternalRef) -> Result<crate::models::SourceUserProfile, AppError> {
        let _ = author;
        Err(AppError::NetworkError(format!("{} has no profiles to fetch", self.capabilities().name)))
    }

    /// One page of the work's discussion (reviews or top-level comments),
    /// or a chapter's when `chapter` is given. Default: none.
    async fn fetch_discussion(&self, work: &ExternalRef, chapter: Option<u64>, page: u32)
        -> Result<CommentsPage, AppError>
    {
        let _ = (work, chapter, page);
        Err(AppError::NetworkError(format!("{} has no discussion to fetch", self.capabilities().name)))
    }

    /// The page the user signs in on, for `SignInShape::Site`.
    fn site_sign_in(&self) -> Option<SiteSignIn> { None }

    /// Sign in with a username and password (`SignInShape::Credentials`);
    /// the session lands in the jar. False = the site refused them.
    async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        let _ = (username, password);
        Err(AppError::NetworkError(format!("{} has no sign-in by password", self.capabilities().name)))
    }

    /// Who the jar's session at this source belongs to; None when it is
    /// not signed in. One request to the site.
    async fn whoami(&self) -> Result<Option<SessionIdentity>, AppError> {
        Ok(None)
    }

    /// Whether the reader can react right now. The adapter decides, not
    /// the UI: AO3 takes guest kudos, a star rating needs the site's login.
    fn reaction_gate(&self, signed_in: bool) -> Gate {
        match self.capabilities().reaction {
            ReactionShape::None => Gate::Hidden,
            ReactionShape::Kudos => Gate::Enabled,
            ReactionShape::StarRating { .. } => Gate::when(true, signed_in, "Sign in to rate"),
        }
    }

    /// Send the reader's reaction. Default: the source takes none.
    async fn react(&self, work: &ExternalRef, reaction: Reaction) -> Result<ReactionOutcome, AppError> {
        let _ = (work, reaction);
        Err(AppError::NetworkError(format!("{} takes no reactions", self.capabilities().name)))
    }

    /// The site page for a tag's works, when the source has tag pages.
    fn tag_url(&self, tag: &str) -> Option<String> {
        let _ = tag;
        None
    }

    /// The source's search form as static configuration
    /// (design/source-search-plan.md). None ⇔ `capabilities().search` is
    /// false. Never fetched: a site form change ships as a new version.
    fn search_schema(&self) -> Option<SearchSchema> {
        None
    }

    /// One page of results for a query built against `search_schema`.
    /// The adapter encodes its own request and parses its own listing.
    async fn search(&self, query: &SearchQuery, page: u32) -> Result<ListingPage, AppError> {
        let _ = (query, page);
        Err(AppError::NetworkError(format!("{} has no search", self.capabilities().name)))
    }

    /// Remote suggestions for an open-text field, run only on an explicit
    /// user action (the local known-tags cache answers keystrokes).
    async fn autocomplete(&self, kind: &Autocomplete, prefix: &str) -> Result<Vec<FieldOption>, AppError> {
        let _ = (kind, prefix);
        Err(AppError::NetworkError(format!("{} has no suggestions", self.capabilities().name)))
    }
}

/// Every source the app knows, in display order. Lookups by id and by
/// link.
#[derive(Default)]
pub struct SourceRegistry {
    sources: Vec<Arc<dyn Source>>,
}

impl SourceRegistry {
    pub fn new(sources: Vec<Arc<dyn Source>>) -> Self {
        SourceRegistry { sources }
    }

    pub fn all(&self) -> &[Arc<dyn Source>] {
        &self.sources
    }

    pub fn by_id(&self, id: &str) -> Option<Arc<dyn Source>> {
        self.sources.iter().find(|s| s.id() == id).cloned()
    }

    /// The first source that recognises the input, with what it resolved.
    pub fn resolve(&self, input: &str) -> Option<(Arc<dyn Source>, ExternalRef)> {
        let input = input.trim();
        self.sources.iter().find_map(|s| s.resolve(input).map(|r| (s.clone(), r)))
    }

    /// The first source that recognises a profile link.
    pub fn resolve_user(&self, input: &str) -> Option<(Arc<dyn Source>, ExternalRef)> {
        let input = input.trim();
        self.sources.iter().find_map(|s| s.resolve_user(input).map(|r| (s.clone(), r)))
    }

    /// The first source that claims a link, with what it points at.
    pub fn classify(&self, input: &str) -> Option<(Arc<dyn Source>, LinkTarget)> {
        let input = input.trim();
        self.sources.iter().find_map(|s| s.classify(input).map(|t| (s.clone(), t)))
    }

    pub fn capabilities(&self) -> Vec<SourceCapabilities> {
        self.sources.iter().map(|s| s.capabilities().clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The search capability flag and the schema agree, and every declared
    /// schema is well-formed. The registry here mirrors `api::sources`.
    #[tokio::test]
    async fn search_capability_matches_declared_schema() {
        // A direct client is a reqwest handle; nothing is sent here.
        let client = Arc::new(tokio::sync::RwLock::new(crate::client::AO3Client::new_direct().await.unwrap()));
        let sources: Vec<Arc<dyn Source>> = vec![
            Arc::new(ao3::AO3Source::new(client.clone())),
            Arc::new(scribblehub::ScribbleHubSource::new(client)),
            Arc::new(mock_rated::MockRatedSource::new()),
        ];
        for s in &sources {
            let schema = s.search_schema();
            assert_eq!(s.capabilities().search, schema.is_some(), "{}: search flag vs schema", s.id());
            if let Some(schema) = schema {
                assert_eq!(schema.source, s.id());
                schema.validate().unwrap_or_else(|e| panic!("{}: {e}", s.id()));
            }
        }
    }

    #[test]
    fn registry_resolves_by_link_and_id() {
        let reg = SourceRegistry::new(vec![
            Arc::new(mock_rated::MockRatedSource::new()),
        ]);
        assert!(reg.by_id("mockrated").is_some());
        assert!(reg.by_id("nope").is_none());
        let (s, r) = reg.resolve("  https://rated.mock/story/2  ").unwrap();
        assert_eq!(s.id(), "mockrated");
        assert_eq!(r.external_id, "2");
        assert!(reg.resolve("https://example.com/x").is_none());
    }

    #[test]
    fn capabilities_are_shapes_not_flags() {
        let caps = mock_rated::MockRatedSource::new().capabilities().clone();
        assert_eq!(caps.reaction, ReactionShape::StarRating { max: 5 });
        assert_eq!(caps.discussion, DiscussionShape::Reviews);
        assert!(caps.chapter_comments);
        assert!(!caps.reach.tor && caps.reach.direct);
        assert_eq!(caps.vocabulary.discussion_title, "Reviews");
        assert!(caps.vocabulary.reply_verb.is_none());
        assert!(caps.vocabulary.subscribe_verb.is_none());
        assert!(!caps.username_is_key && !caps.user_moderation);
    }

    #[test]
    fn session_cookies_are_told_apart_by_source() {
        let jar = "cf_clearance=c; wordpress_logged_in_abc=t; wordpress_sec_abc=s; theme=dark";
        assert_eq!(session_part("scribblehub", jar), "wordpress_logged_in_abc=t; wordpress_sec_abc=s");
        assert!(session_logged_in("scribblehub", jar));
        assert!(!session_logged_in("scribblehub", "wordpress_logged_in_abc=; wordpress_sec_abc=s"), "an empty value is no login");
        assert!(!session_logged_in("ao3", jar));
        assert!(session_logged_in("ao3", "_otwarchive_session=a; remember_user_token=t"));
        assert_eq!(session_part("ao3", "_otwarchive_session=a; cf_clearance=c"), "_otwarchive_session=a");
        assert_eq!(session_origin("mockrated"), None);
        assert_eq!(session_part("mockrated", jar), "");
    }

    #[tokio::test]
    async fn reaction_gate_follows_the_shape_unless_the_adapter_says_otherwise() {
        let client = Arc::new(tokio::sync::RwLock::new(crate::client::AO3Client::new_direct().await.unwrap()));
        let ao3 = ao3::AO3Source::new(client.clone());
        assert_eq!(ao3.reaction_gate(false), Gate::Enabled, "guest kudos");
        let sh = scribblehub::ScribbleHubSource::new(client);
        assert_eq!(sh.reaction_gate(false), Gate::Disabled { reason: "Sign in to rate".to_string() });
        assert_eq!(sh.reaction_gate(true), Gate::Enabled);
        // The mock has no login and rates anyway, so the control is exercised offline.
        assert_eq!(mock_rated::MockRatedSource::new().reaction_gate(false), Gate::Enabled);
    }

    #[tokio::test]
    async fn ao3_tag_pages_are_built_by_the_adapter() {
        let client = Arc::new(tokio::sync::RwLock::new(crate::client::AO3Client::new_direct().await.unwrap()));
        let ao3 = ao3::AO3Source::new(client);
        assert_eq!(ao3.tag_url("Hurt/Comfort").as_deref(), Some("https://archiveofourown.org/tags/Hurt*s*Comfort/works"));
        assert_eq!(ao3.tag_url("Tom & Jerry").as_deref(), Some("https://archiveofourown.org/tags/Tom%20*a*%20Jerry/works"));
        assert!(mock_rated::MockRatedSource::new().tag_url("x").is_none());
    }
}
