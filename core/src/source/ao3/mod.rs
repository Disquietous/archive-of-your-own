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

use super::search::{SearchQuery, SearchSchema};
use super::{DiscussionShape, FetchedWork, Gate, LinkTarget, ListedWork, ListingPage, Reaction, ReactionOutcome,
            ReactionShape, Reachability, Source, SourceCapabilities, UpdatePage, UpdateTarget, UserPane, Vocabulary};

pub mod search;

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
            host: "archiveofourown.org".to_string(),
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
            sign_in: super::SignInShape::Credentials,
            remote_bookmarks: true,
            subscriptions: true,
            collections: true,
            inbox: true,
            user_moderation: true,
            username_is_key: true,
            vocabulary: Vocabulary {
                discussion_title: "Comments".to_string(),
                reaction_verb: "Leave kudos".to_string(),
                reply_verb: Some("Reply".to_string()),
                rating_label: "Rating".to_string(),
                site_short: "AO3".to_string(),
                open_on_site: "Open on AO3".to_string(),
                copy_link: "Copy AO3 link".to_string(),
                refresh: "Refresh from AO3".to_string(),
                subscribe_verb: Some("Subscribe".to_string()),
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

    /// An archive URL's path segments, percent-decoded, with the parsed
    /// URL. None when the input is not an http(s) link to the archive (a
    /// missing scheme is assumed).
    fn archive_path(input: &str) -> Option<(url::Url, Vec<String>)> {
        let candidate = if input.contains("://") { input.to_string() } else { format!("https://{input}") };
        let url = url::Url::parse(&candidate).ok()?;
        if !matches!(url.scheme(), "http" | "https") { return None }
        let host = url.host_str()?.to_ascii_lowercase();
        if host != "archiveofourown.org" && !host.ends_with(".archiveofourown.org") { return None }
        let parts = url.path_segments()
            .map(|segments| segments.filter(|s| !s.is_empty()).map(Self::decode_segment).collect())
            .unwrap_or_default();
        Some((url, parts))
    }

    fn decode_segment(segment: &str) -> String {
        let bytes = segment.as_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            let hex = (bytes[i] == b'%' && i + 2 < bytes.len())
                .then(|| std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()))
                .flatten();
            match hex {
                Some(b) => { out.push(b); i += 3; }
                None => { out.push(bytes[i]); i += 1; }
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    fn is_id(s: &str) -> bool {
        !s.is_empty() && s.parse::<u64>().is_ok()
    }

    fn work(id: &str) -> Option<ExternalRef> {
        let number: u64 = id.parse().ok()?;
        Some(ExternalRef::ao3(number.to_string(), crate::parser::ao3_work_url(number)))
    }

    /// `/works/{id}`, `/works/{id}/navigate`, `/works/{id}/chapters/{id}`;
    /// `view_full_work=true` asks for the whole work.
    fn work_link(parts: &[String], url: &url::Url) -> Option<LinkTarget> {
        let work = Self::work(parts.get(1)?)?;
        let entire = url.query_pairs().any(|(k, v)| k == "view_full_work" && v == "true");
        match parts.len() {
            2 => Some(LinkTarget::Work { work, entire }),
            3 if parts[2] == "navigate" => Some(LinkTarget::Work { work, entire: false }),
            4 if parts[2] == "chapters" && Self::is_id(&parts[3]) => Some(if entire {
                LinkTarget::Work { work, entire: true }
            } else {
                LinkTarget::Chapter { work, chapter_id: parts[3].clone() }
            }),
            _ => None,
        }
    }

    /// `/users/{name}[/pseuds/{pseud}][/profile|works|bookmarks|…]`.
    /// Pseuds share their user's profile.
    fn user_link(parts: &[String]) -> Option<LinkTarget> {
        let name = parts.get(1).filter(|n| !n.is_empty())?;
        let mut rest = &parts[2..];
        if rest.first().map(String::as_str) == Some("pseuds") {
            rest = if rest.len() >= 2 { &rest[2..] } else { &[] };
        }
        let pane = match rest.first().map(String::as_str) {
            None | Some("profile") | Some("series") | Some("gifts") => UserPane::Profile,
            Some("works") => UserPane::Works,
            Some("bookmarks") => UserPane::Bookmarks,
            Some("collections") => UserPane::Collections,
            _ => return None, // inbox, readings, subscriptions, …
        };
        Some(LinkTarget::User { user: ExternalRef::ao3(name.clone(), crate::parser::ao3_user_url(name)), pane })
    }

    /// The archive escapes characters that can't sit in a tag's path
    /// segment: `*s*` = "/", `*a*` = "&", `*d*` = ".", `*q*` = "?",
    /// `*h*` = "#".
    fn decode_tag(segment: &str) -> String {
        segment.replace("*s*", "/").replace("*a*", "&").replace("*d*", ".").replace("*q*", "?").replace("*h*", "#")
    }

    /// Works, chapters, users, series, collections and tag listings; any
    /// other archive page is the archive's but has no view here.
    pub fn classify_link(input: &str) -> Option<LinkTarget> {
        let (url, parts) = Self::archive_path(input)?;
        let target = match parts.first().map(String::as_str) {
            Some("works") => Self::work_link(&parts, &url),
            Some("users") => Self::user_link(&parts),
            Some("series") if parts.len() == 2 && Self::is_id(&parts[1]) => parts[1].parse().ok().map(|n: u64| {
                LinkTarget::Series { series: ExternalRef::ao3(n.to_string(), crate::parser::ao3_series_url(n)) }
            }),
            Some("collections") if parts.len() >= 2 => {
                // A work shown inside a collection is still the work.
                if parts.len() >= 4 && parts[2] == "works" {
                    Self::work_link(&parts[2..], &url)
                } else {
                    Some(LinkTarget::Collection { name: parts[1].clone() })
                }
            }
            Some("tags") if parts.len() == 2 || (parts.len() == 3 && parts[2] == "works") => {
                let name = Self::decode_tag(&parts[1]);
                (!name.is_empty()).then_some(LinkTarget::Tag { name })
            }
            _ => None,
        };
        Some(target.unwrap_or(LinkTarget::Unsupported))
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

    fn classify(&self, input: &str) -> Option<LinkTarget> {
        Self::classify_link(input)
    }

    fn work_ref(&self, external_id: &str) -> Option<ExternalRef> {
        Self::work(external_id)
    }

    fn comment_url(&self, comment_id: u64) -> Option<String> {
        Some(format!("{}/comments/{comment_id}", crate::client::BASE_URL))
    }

    /// Archive requests show as their path.
    fn display_url(&self, url: &str) -> Option<String> {
        url.strip_prefix(crate::client::BASE_URL).map(str::to_string)
    }

    async fn fetch_work(&self, work: &ExternalRef, _known: Option<&WorkSummary>) -> Result<FetchedWork, AppError> {
        let number = Self::number(&work.external_id)?;
        let (summary, chapters, kudos_names) = self.client.read().await.get_work(number).await?;
        Ok(FetchedWork { summary, chapters, stats: Vec::new(), reacted_by: kudos_names, authors: Vec::new() })
    }

    /// The check's own light requests, as it has always made them: the
    /// user's or series' works listing (page 1 without a page parameter),
    /// or the work page. A listing that fails to parse is an error — read
    /// as "no works" it would make a census flag every known work gone. A
    /// work page that fails to parse reports nothing.
    async fn fetch_updates(&self, target: &UpdateTarget, page: u32) -> Result<UpdatePage, AppError> {
        let base = crate::client::BASE_URL;
        let id = &target.external().external_id;
        let url = match (target, page) {
            (UpdateTarget::Author(_), 0 | 1) => format!("{base}/users/{id}/works"),
            (UpdateTarget::Author(_), p) => format!("{base}/users/{id}/works?page={p}"),
            (UpdateTarget::Series(_), 0 | 1) => format!("{base}/series/{id}"),
            (UpdateTarget::Series(_), p) => format!("{base}/series/{id}?page={p}"),
            (UpdateTarget::Work(_), _) => format!("{base}/works/{id}?view_adult=true"),
        };
        let html = {
            let client = self.client.read().await;
            let timeout = client.timeout_for_url(&url);
            client.fetch_with_progress(&url, timeout).await?
        };
        let listed = |summary| ListedWork { summary, stats: Vec::new(), authors: Vec::new() };
        if let UpdateTarget::Work(_) = target {
            let work = id.parse::<u64>().ok()
                .and_then(|number| crate::parser::parse_work_page(&html, number).ok())
                .map(|(summary, _)| summary);
            return Ok(UpdatePage { works: work.into_iter().map(listed).collect(), has_next: false, total_pages: 1, total_works: None });
        }
        let works = crate::parser::parse_work_listings(&html)?;
        Ok(UpdatePage {
            works: works.into_iter().map(listed).collect(),
            has_next: crate::parser::has_next_page(&html),
            total_pages: crate::parser::total_pages(&html),
            total_works: crate::parser::parse_listing_works_total(&html),
        })
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

    /// The archive's login form, as the client has always sent it.
    async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        self.client.read().await.login(username, password).await
    }

    /// Kudos are open to guests; the site counts them by IP then.
    fn reaction_gate(&self, _signed_in: bool) -> Gate {
        Gate::Enabled
    }

    /// Kudos only — AO3 has no rating to set or clear. The client answers
    /// false when the archive refuses (own work, already left).
    async fn react(&self, work: &ExternalRef, reaction: Reaction) -> Result<ReactionOutcome, AppError> {
        match reaction {
            Reaction::Kudos => {
                let number = Self::number(&work.external_id)?;
                let accepted = self.client.read().await.leave_kudos(number).await?;
                Ok(ReactionOutcome { accepted, value: None })
            }
            Reaction::Stars { .. } | Reaction::Clear => {
                Err(AppError::NetworkError("AO3 has kudos, not ratings".to_string()))
            }
        }
    }

    /// `/tags/{tag}/works`, with AO3's own substitutions for the characters
    /// a tag may carry that a path may not.
    fn tag_url(&self, tag: &str) -> Option<String> {
        let substituted = tag.replace('/', "*s*").replace('&', "*a*").replace('.', "*d*");
        let mut encoded = String::with_capacity(substituted.len());
        for b in substituted.bytes() {
            let keep = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'~' | b'*' | b'!' | b'$' | b'\'' | b'(' | b')' | b',' | b';' | b'=' | b':' | b'@');
            if keep { encoded.push(b as char) } else { encoded.push_str(&format!("%{b:02X}")) }
        }
        Some(format!("https://archiveofourown.org/tags/{encoded}/works"))
    }

    fn search_schema(&self) -> Option<SearchSchema> {
        Some(search::schema())
    }

    async fn search(&self, query: &SearchQuery, page: u32) -> Result<ListingPage, AppError> {
        let pairs = search::encode(query);
        let (works, has_next, total_pages, total_works) = self.client.read().await.search_works_raw(&pairs, page).await?;
        Ok(ListingPage {
            works: works.into_iter().map(|summary| ListedWork { summary, stats: Vec::new(), authors: Vec::new() }).collect(),
            has_next,
            total_pages,
            total_works,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(input: &str) -> Option<LinkTarget> {
        AO3Source::classify_link(input)
    }

    fn work(id: &str, entire: bool) -> Option<LinkTarget> {
        Some(LinkTarget::Work { work: AO3Source::work(id).unwrap(), entire })
    }

    fn user(pane: UserPane) -> Option<LinkTarget> {
        Some(LinkTarget::User {
            user: ExternalRef::ao3("sample_user", "https://archiveofourown.org/users/sample_user"),
            pane,
        })
    }

    #[tokio::test]
    async fn the_update_check_reads_listings_and_work_pages() {
        let _g = crate::mock_site::tests::toggle_lock();
        let source = AO3Source::new(Arc::new(RwLock::new(AO3Client::new_direct().await.unwrap())));
        let author = ExternalRef::ao3("quietcartographer", "https://archiveofourown.org/users/quietcartographer");
        crate::mock_site::set_enabled(true);
        let listing = source.fetch_updates(&UpdateTarget::Author(author), 1).await;
        let first = listing.as_ref().ok().and_then(|p| p.works.first()).map(|w| w.summary.external_id.clone());
        let work = match &first {
            Some(id) => Some(source.fetch_updates(&UpdateTarget::Work(AO3Source::work(id).unwrap()), 1).await),
            None => None,
        };
        crate::mock_site::set_enabled(false);
        let listing = listing.unwrap();
        assert_eq!(listing.works.len(), 3);
        assert!(listing.works.iter().all(|w| w.summary.source == SOURCE_AO3 && w.stats.is_empty()));
        assert!(!listing.has_next);
        let work = work.expect("the listing names a work").unwrap();
        assert_eq!(work.works.len(), 1);
        assert_eq!(Some(&work.works[0].summary.external_id), first.as_ref());
        assert_eq!(work.total_works, None);
    }

    #[test]
    fn classifies_work_links() {
        let base = "https://archiveofourown.org";
        assert_eq!(target(&format!("{base}/works/111")), work("111", false));
        assert_eq!(target("archiveofourown.org/works/111"), work("111", false));
        assert_eq!(target(&format!("{base}/works/111?view_adult=true#main")), work("111", false));
        assert_eq!(target(&format!("{base}/works/111/navigate")), work("111", false));
        assert_eq!(target(&format!("{base}/works/111/chapters/222#workskin")),
                   Some(LinkTarget::Chapter { work: AO3Source::work("111").unwrap(), chapter_id: "222".to_string() }));
        assert_eq!(target(&format!("{base}/works/111?view_full_work=true")), work("111", true));
        assert_eq!(target(&format!("{base}/works/111/chapters/222?view_full_work=true")), work("111", true));
        assert_eq!(target(&format!("{base}/collections/Some_Fest/works/111")), work("111", false));
        assert_eq!(target("https://www.archiveofourown.org/works/111"), work("111", false));
    }

    #[test]
    fn classifies_user_series_collection_and_tag_links() {
        let base = "https://archiveofourown.org";
        assert_eq!(target(&format!("{base}/users/sample_user")), user(UserPane::Profile));
        assert_eq!(target(&format!("{base}/users/sample_user/profile")), user(UserPane::Profile));
        assert_eq!(target(&format!("{base}/users/sample_user/works")), user(UserPane::Works));
        assert_eq!(target(&format!("{base}/users/sample_user/bookmarks")), user(UserPane::Bookmarks));
        assert_eq!(target(&format!("{base}/users/sample_user/collections")), user(UserPane::Collections));
        assert_eq!(target(&format!("{base}/users/sample_user/pseuds/alt")), user(UserPane::Profile));
        assert_eq!(target(&format!("{base}/users/sample_user/pseuds/alt/works")), user(UserPane::Works));
        assert_eq!(target(&format!("{base}/series/333")), Some(LinkTarget::Series {
            series: ExternalRef::ao3("333", "https://archiveofourown.org/series/333"),
        }));
        let collection = Some(LinkTarget::Collection { name: "Some_Fest".to_string() });
        assert_eq!(target(&format!("{base}/collections/Some_Fest")), collection);
        assert_eq!(target(&format!("{base}/collections/Some_Fest/bookmarks")), collection);
        let tag = |name: &str| Some(LinkTarget::Tag { name: name.to_string() });
        assert_eq!(target(&format!("{base}/tags/Fluff/works")), tag("Fluff"));
        assert_eq!(target(&format!("{base}/tags/Alpha*s*Beta%20Pair/works")), tag("Alpha/Beta Pair"));
        assert_eq!(target(&format!("{base}/tags/Q*a*A")), tag("Q&A"));
    }

    #[test]
    fn archive_pages_without_a_view_are_unsupported_and_other_hosts_are_not_ours() {
        let base = "https://archiveofourown.org";
        for path in ["/", "/works/search?work_search%5Bquery%5D=x", "/works/111/comments", "/chapters/222",
                     "/users/sample_user/inbox", "/series/abc", "/tags/Fluff/bookmarks", "/admin_posts/5"] {
            assert_eq!(target(&format!("{base}{path}")), Some(LinkTarget::Unsupported), "{path}");
        }
        for other in ["https://notarchiveofourown.org/works/111", "https://example.com/works/111",
                      "ftp://archiveofourown.org/works/111", "just some words", ""] {
            assert_eq!(target(other), None, "{other}");
        }
    }

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
