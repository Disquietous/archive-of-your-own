//! A synthetic archive served from inside the process — for exercising
//! every fetch, parse, and persist path end to end while the real AO3 is
//! unreachable (or without touching it at all). While enabled, the client
//! answers every request from here and the real transport is refused
//! outright (`AO3Client::http`), so no byte leaves the device.
//!
//! The catalog (`data`) is entirely invented, with ids far above AO3's
//! range; pages (`render`) use the exact markup shapes the parsers expect;
//! the viewer's actions (`state`) persist for the session so a POST shows
//! up on the next GET; comment threads (`comments`) are generated.

pub mod comments;
pub mod data;
pub mod render;
pub mod state;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use data::*;
use render::{RenderBookmark, RenderComment};
use state::MockState;

static ENABLED: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<Option<MockState>> = Mutex::new(None);

pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// Switch the mock on or off. Switching off forgets the session's
/// actions; switching on starts from a clean, signed-out archive.
pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::Relaxed);
    *lock() = if on { Some(MockState::default()) } else { None };
    if !on { data::set_snapshot(0); }
    crate::log_info!("mock", "Mock archive {}", if on { "enabled — every request is answered locally" } else { "disabled" });
}

/// Forget the session's actions and return to the baseline snapshot
/// without touching the enabled flag (tests drive the router directly;
/// enabling the mock process-wide would hijack other tests' requests).
#[cfg(test)]
fn reset() {
    *lock() = Some(MockState::default());
    data::set_snapshot(0);
}

fn lock() -> std::sync::MutexGuard<'static, Option<MockState>> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn with_state<R>(f: impl FnOnce(&mut MockState) -> R) -> R {
    let mut guard = lock();
    let state = guard.get_or_insert_with(MockState::default);
    f(state)
}

pub struct MockResponse {
    pub status: u16,
    pub body: String,
}

fn ok(body: String) -> MockResponse { MockResponse { status: 200, body } }

fn not_found(url: &str) -> MockResponse {
    crate::log_info!("mock", "No mock page for {url}");
    MockResponse { status: 404, body: format!("<html><body><h2 class=\"heading\">Error 404</h2><p>The mock archive has no page at {}.</p></body></html>", render::esc(url)) }
}

// ---------------------------------------------------------------------------
// URL parsing
// ---------------------------------------------------------------------------

pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => { out.push(b' '); i += 1; }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok());
                match hex {
                    Some(b) => { out.push(b); i += 3; }
                    None => { out.push(b'%'); i += 1; }
                }
            }
            b => { out.push(b); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

struct Request {
    path: Vec<String>,
    query: Vec<(String, String)>,
}

impl Request {
    fn parse(url: &str) -> Request {
        let after_scheme = url.split("://").nth(1).unwrap_or(url);
        let path_and_query = match after_scheme.find('/') { Some(i) => &after_scheme[i..], None => "/" };
        let (path, query) = path_and_query.split_once('?').unwrap_or((path_and_query, ""));
        let path = path.split('#').next().unwrap_or(path);
        Request {
            path: path.split('/').filter(|s| !s.is_empty()).map(percent_decode).collect(),
            query: query.split('&').filter(|p| !p.is_empty()).map(|p| {
                let (k, v) = p.split_once('=').unwrap_or((p, ""));
                (percent_decode(k), percent_decode(v))
            }).collect(),
        }
    }
    fn q(&self, key: &str) -> Option<&str> {
        self.query.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str()).filter(|v| !v.is_empty())
    }
    fn has(&self, key: &str) -> bool { self.query.iter().any(|(k, _)| k == key) }
    fn page(&self) -> u32 { self.q("page").and_then(|p| p.parse().ok()).unwrap_or(1) }
    fn segs(&self) -> Vec<&str> { self.path.iter().map(String::as_str).collect() }
}

// ---------------------------------------------------------------------------
// GET
// ---------------------------------------------------------------------------

/// The mock login cookie carries the username, so a restored jar (the
/// app persists session cookies across launches) signs the viewer back
/// in here as it does on the archive.
pub const LOGIN_COOKIE_PREFIX: &str = "mock-user-";

fn viewer_from_cookies(cookies: &str) -> Option<String> {
    cookies.split(';').map(str::trim)
        .find_map(|c| c.strip_prefix("remember_user_token="))
        .and_then(|v| v.strip_prefix(LOGIN_COOKIE_PREFIX))
        .filter(|u| !u.is_empty())
        .map(str::to_string)
}

fn adopt_viewer(state: &mut MockState, cookies: &str) {
    if state.viewer.is_none() {
        state.viewer = viewer_from_cookies(cookies);
    }
}

/// Answer a page fetch. `ajax` requests get fragments where AO3 serves
/// them (comment pages, autocomplete). `cookies` is the client's jar
/// (Cookie header form).
pub fn respond_get(url: &str, ajax: bool, cookies: &str) -> MockResponse {
    let req = Request::parse(url);
    with_state(|state| {
        adopt_viewer(state, cookies);
        route_get(&req, ajax, state).unwrap_or_else(|| not_found(url))
    })
}

fn route_get(req: &Request, _ajax: bool, state: &mut MockState) -> Option<MockResponse> {
    let segs = req.segs();
    let page_no = req.page();
    let body = match segs.as_slice() {
        [] => render::home_page(state),

        ["users", "login"] => render::login_page(state),

        // -- Works --
        ["works"] => {
            let all: Vec<usize> = sorted_by_updated(live());
            let heading = render::range_heading(all.len(), page_no, "");
            render::page("Works", "works-index region", &render::listing(&heading, &all, page_no, "/works", ""), state)
        }
        ["works", "search"] if req.has("edit_search") => include_str!("../../tests/fixtures/search_form.html").to_string(),
        ["works", "search"] => {
            let hits = search(req);
            let heading = format!("<h3 class=\"heading\">{} Found</h3>", hits.len());
            let base = format!("/works/search?{}", req.query.iter().filter(|(k, _)| k != "page")
                .map(|(k, v)| format!("{}={}", k, urlencode(v))).collect::<Vec<_>>().join("&"));
            render::page("Search Works", "works-search region", &render::listing(&heading, &hits, page_no, &base, ""), state)
        }
        ["works", id] => {
            let idx = work_index(id.parse().ok()?)?;
            // ?show_comments=true on a work renders chapter 1 with that
            // chapter's comments (works#show), as the archive does.
            let comments = if req.has("show_comments") {
                let chapter = 1;
                comments_page(&comments::chapter_threads(idx, chapter, false, state), page_no, &format!("/comments/show_comments?chapter_id={}", chapter_id(idx, chapter)))
            } else { String::new() };
            render::work_page(idx, req.has("view_full_work"), 1, state, &comments)
        }
        ["works", id, "chapters", cid] => {
            let idx = work_index(id.parse().ok()?)?;
            let (cidx, n) = chapter_from_id(cid.parse().ok()?)?;
            if cidx != idx { return None; }
            let comments = if req.has("show_comments") {
                comments_page(&comments::chapter_threads(idx, n, false, state), page_no, &format!("/comments/show_comments?chapter_id={cid}"))
            } else { String::new() };
            render::work_page(idx, false, n, state, &comments)
        }
        ["works", id, "bookmarks"] => {
            let idx = work_index(id.parse().ok()?)?;
            let items = canned_bookmarks().into_iter().filter(|b| b.work_idx == Some(idx)).collect::<Vec<_>>();
            let heading = format!("<h2 class=\"heading\">{} Bookmarks of {}</h2>", items.len(), render::esc(WORKS[idx].title));
            render::page("Bookmarks", "bookmarks-index region", &render::bookmarks_listing(&heading, &items, page_no, &format!("/works/{id}/bookmarks")), state)
        }

        // -- Comments --
        ["comments", "show_comments"] => {
            let (threads, base) = if let Some(w) = req.q("work_id") {
                let idx = work_index(w.parse().ok()?)?;
                (comments::work_threads(idx, state), format!("/comments/show_comments?work_id={w}"))
            } else {
                let c = req.q("chapter_id")?;
                let (idx, n) = chapter_from_id(c.parse().ok()?)?;
                (comments::chapter_threads(idx, n, false, state), format!("/comments/show_comments?chapter_id={c}"))
            };
            comments_page(&threads, page_no, &base)
        }
        ["comments", id] => {
            let (_, root) = comments::subtree(id.parse().ok()?, state)?;
            render::page("Comment", "comments-show region", &render::comments_fragment(std::slice::from_ref(&root), 1, 1, ""), state)
        }

        // -- Tags, series, collections --
        ["tags", tag, "works"] => {
            let hits = sorted_by_updated(works_with_tag(tag));
            let heading = render::range_heading(hits.len(), page_no, &format!("in <a class=\"tag\">{}</a>", render::esc(tag)));
            render::page(tag, "works-index region", &render::listing(&heading, &hits, page_no, &format!("/tags/{}/works", render::tag_path(tag)), ""), state)
        }
        ["series", id] => render::series_page(series_index(id.parse().ok()?)?, page_no, state),
        ["series", id, "bookmarks"] => {
            let si = series_index(id.parse().ok()?)?;
            let items: Vec<RenderBookmark> = Vec::new();
            let heading = format!("<h2 class=\"heading\">0 Bookmarks of {}</h2>", render::esc(SERIES[si].title));
            render::page("Bookmarks", "bookmarks-index region", &render::bookmarks_listing(&heading, &items, 1, ""), state)
        }
        ["collections"] => render::collections_index(&(0..COLLECTIONS.len()).collect::<Vec<_>>(), "Collections in the Mock Archive", state),
        ["collections", name, "works"] => render::collection_works(collection_index(name)?, page_no, state),
        ["collections", name, "profile"] | ["collections", name] => render::collection_profile(collection_index(name)?, state),
        ["collections", name, "bookmarks"] => {
            let ci = collection_index(name)?;
            let items = canned_bookmarks().into_iter()
                .filter(|b| b.work_idx.is_some_and(|w| COLLECTIONS[ci].works.contains(&w) && visible(w))).collect::<Vec<_>>();
            let heading = format!("<h2 class=\"heading\">{} Bookmarked Items in {}</h2>", items.len(), render::esc(COLLECTIONS[ci].title));
            render::page("Bookmarks", "bookmarks-index region", &render::bookmarks_listing(&heading, &items, page_no, &format!("/collections/{name}/bookmarks")), state)
        }
        ["collections", name, "works", id] => {
            collection_index(name)?;
            render::work_page(work_index(id.parse().ok()?)?, req.has("view_full_work"), 1, state, "")
        }

        // -- Bookmarks --
        ["bookmarks", "search"] => {
            let q = req.q("bookmark_search[bookmarkable_query]").map(str::to_lowercase);
            let mut items = all_bookmarks(state);
            if let Some(q) = q {
                items.retain(|b| b.work_idx.is_some_and(|w| WORKS[w].title.to_lowercase().contains(&q))
                    || b.series_idx.is_some_and(|s| SERIES[s].title.to_lowercase().contains(&q)));
            }
            if req.q("bookmark_search[rec]") == Some("1") { items.retain(|b| b.rec); }
            if req.q("bookmark_search[with_notes]") == Some("1") { items.retain(|b| !b.note.is_empty()); }
            let heading = format!("<h3 class=\"heading\">{} Found</h3>", items.len());
            render::page("Search Bookmarks", "bookmarks-search region", &render::bookmarks_listing(&heading, &items, page_no, "/bookmarks/search"), state)
        }
        ["bookmarks", id] => {
            let id: u64 = id.parse().ok()?;
            let b = all_bookmarks(state).into_iter().find(|b| b.id == id)?;
            render::bookmark_page(&b, state)
        }

        // -- Users --
        ["users", user, "profile"] | ["users", user] => {
            if !user_exists(user, state) { return None; }
            render::user_profile(user, state)
        }
        ["users", user, "works"] | ["users", user, "pseuds", _, "works"] => {
            if !user_exists(user, state) { return None; }
            let (hits, label) = match author_index(user) {
                Some(ai) => {
                    let pseud = if let ["users", _, "pseuds", p, "works"] = segs.as_slice() { Some(*p) } else { None };
                    let by_pseud = pseud.filter(|p| !p.eq_ignore_ascii_case(user));
                    let mut hits: Vec<usize> = live().into_iter().filter(|&i| WORKS[i].author == ai).collect();
                    if let Some(p) = by_pseud { if AUTHORS[ai].pseud != Some(p) { hits.clear(); } }
                    (sorted_by_updated(hits), AUTHORS[ai].user.to_string())
                }
                None => (Vec::new(), user.to_string()),
            };
            let heading = render::range_heading(hits.len(), page_no, &format!("by {}", render::esc(&label)));
            render::page(&format!("{label} - Works"), "works-index region", &render::listing(&heading, &hits, page_no, &format!("/users/{user}/works"), ""), state)
        }
        ["users", user, "bookmarks"] => {
            if !user_exists(user, state) { return None; }
            let items = user_bookmarks(user, state);
            let heading = format!("<h2 class=\"heading\">{} Bookmarks by {}</h2>", items.len(), render::esc(user));
            render::page("Bookmarks", "bookmarks-index region", &render::bookmarks_listing(&heading, &items, page_no, &format!("/users/{user}/bookmarks")), state)
        }
        ["users", user, "collections"] => {
            if !user_exists(user, state) { return None; }
            let owned: Vec<usize> = (0..COLLECTIONS.len())
                .filter(|&c| COLLECTIONS[c].owners.iter().any(|&o| AUTHORS[o].user.eq_ignore_ascii_case(user))).collect();
            render::collections_index(&owned, &format!("{}'s Collections", render::esc(user)), state)
        }
        ["users", _, "inbox"] => render::inbox_page(state),
        ["users", _, "subscriptions"] => render::subscriptions_page(state),
        ["users", _, "blocked", "users"] => render::moderation_index(state, "blocked"),
        ["users", _, "muted", "users"] => render::moderation_index(state, "muted"),

        ["autocomplete", kind] => {
            let term = req.q("term").unwrap_or("").to_lowercase();
            let names: Vec<&str> = match *kind {
                "fandom" => live().into_iter().flat_map(|i| WORKS[i].fandoms.iter().copied()).collect(),
                "character" => live().into_iter().flat_map(|i| WORKS[i].characters.iter().copied()).collect(),
                "relationship" => live().into_iter().flat_map(|i| WORKS[i].relationships.iter().copied()).collect(),
                "pseud" => AUTHORS.iter().map(|a| a.user).collect(),
                _ => live().into_iter().flat_map(|i| WORKS[i].tags.iter().copied()).collect(),
            };
            let mut seen: Vec<&str> = Vec::new();
            for n in names { if n.to_lowercase().contains(&term) && !seen.contains(&n) { seen.push(n); } }
            let json = seen.iter().map(|n| format!("{{\"id\":\"{0}\",\"name\":\"{0}\"}}", n.replace('"', "\\\""))).collect::<Vec<_>>().join(",");
            return Some(ok(format!("[{json}]")));
        }
        _ => return None,
    };
    Some(ok(body))
}

const COMMENTS_PER_PAGE: usize = 8;

fn comments_page(threads: &[RenderComment], page_no: u32, base: &str) -> String {
    let total_pages = ((threads.len() + COMMENTS_PER_PAGE - 1) / COMMENTS_PER_PAGE).max(1) as u32;
    let page_no = page_no.clamp(1, total_pages);
    let start = ((page_no - 1) as usize) * COMMENTS_PER_PAGE;
    let slice = if start < threads.len() { &threads[start..(start + COMMENTS_PER_PAGE).min(threads.len())] } else { &[] };
    render::comments_fragment(slice, page_no, total_pages, base)
}

/// The archive knows its authors, its readers, and whoever is signed in;
/// any other name is a 404, as on AO3 (so a typo cannot be followed).
fn user_exists(user: &str, state: &MockState) -> bool {
    author_index(user).is_some()
        || READERS.iter().any(|r| r.eq_ignore_ascii_case(user))
        || state.viewer.as_deref().is_some_and(|v| v.eq_ignore_ascii_case(user))
}

fn urlencode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

fn sorted_by_updated(mut idx: Vec<usize>) -> Vec<usize> {
    idx.sort_by(|&a, &b| work(b).updated.cmp(work(a).updated).then(WORKS[b].id.cmp(&WORKS[a].id)));
    idx
}

fn works_with_tag(tag: &str) -> Vec<usize> {
    let t = tag.to_lowercase();
    live().into_iter().filter(|&i| {
        let w = &WORKS[i];
        w.fandoms.iter().chain(w.characters).chain(w.relationships).chain(w.tags)
            .chain(std::iter::once(&w.rating)).chain(w.warnings).chain(w.categories)
            .any(|x| x.to_lowercase() == t)
    }).collect()
}

/// The search form's fields, applied as substring filters.
fn search(req: &Request) -> Vec<usize> {
    let field = |k: &str| req.q(&format!("work_search[{k}]")).map(str::to_lowercase);
    let mut hits: Vec<usize> = live();
    if let Some(q) = field("query") {
        hits.retain(|&i| {
            let w = &WORKS[i];
            let hay = format!("{} {} {} {} {}", w.title, w.summary, AUTHORS[w.author].user,
                              w.fandoms.join(" "), w.tags.join(" ")).to_lowercase();
            q.split_whitespace().all(|term| hay.contains(term))
        });
    }
    if let Some(t) = field("title") { hits.retain(|&i| WORKS[i].title.to_lowercase().contains(&t)); }
    if let Some(c) = field("creators") { hits.retain(|&i| byline(&AUTHORS[WORKS[i].author]).to_lowercase().contains(&c)); }
    for (key, pick) in [
        ("fandom_names", 0), ("character_names", 1), ("relationship_names", 2), ("freeform_names", 3),
    ] {
        if let Some(v) = field(key) {
            for term in v.split(',').map(str::trim).filter(|t| !t.is_empty()) {
                hits.retain(|&i| {
                    let w = &WORKS[i];
                    let list: &[&str] = match pick { 0 => w.fandoms, 1 => w.characters, 2 => w.relationships, _ => w.tags };
                    list.iter().any(|x| x.to_lowercase().contains(term))
                });
            }
        }
    }
    if field("complete").as_deref() == Some("t") {
        hits.retain(|&i| work(i).total.is_some_and(|t| work(i).chapters >= t));
    }
    match field("sort_column").as_deref() {
        Some("kudos_count") => hits.sort_by_key(|&i| std::cmp::Reverse(work(i).kudos)),
        Some("hits") => hits.sort_by_key(|&i| std::cmp::Reverse(WORKS[i].hits)),
        Some("word_count") => hits.sort_by_key(|&i| std::cmp::Reverse(word_count(i))),
        Some("created_at") => hits.sort_by(|&a, &b| WORKS[b].published.cmp(WORKS[a].published)),
        _ => hits = sorted_by_updated(hits),
    }
    hits
}

/// Readers' bookmarks, fixed per catalog.
fn canned_bookmarks() -> Vec<RenderBookmark> {
    let mut out = Vec::new();
    let mut id = 94_000_000;
    for (ri, reader) in READERS.iter().enumerate() {
        for (k, &w) in [ri % 12, (ri * 3 + 1) % 12].iter().enumerate() {
            id += 1;
            if !visible(w) { continue; }
            out.push(RenderBookmark {
                id, work_idx: Some(w), series_idx: None, bookmarker: reader.to_string(),
                date: format!("2026-0{}-{:02}", 1 + (ri % 8), 1 + (k * 9 + ri) % 27),
                tags: if k == 0 { vec!["Comfort Read".to_string()] } else { Vec::new() },
                note: if (ri + k) % 2 == 0 { "Reread this every winter.".to_string() } else { String::new() },
                rec: (ri + k) % 3 == 0,
            });
        }
    }
    id += 1;
    out.push(RenderBookmark {
        id, work_idx: None, series_idx: Some(0), bookmarker: READERS[1].to_string(), date: "2026-02-14".to_string(),
        tags: vec!["Series".to_string()], note: String::new(), rec: true,
    });
    out
}

fn viewer_bookmarks(state: &MockState) -> Vec<RenderBookmark> {
    let Some(v) = &state.viewer else { return Vec::new() };
    state.bookmarks.iter().map(|b| RenderBookmark {
        id: b.id,
        work_idx: if b.kind == "Work" { work_index(b.number) } else { None },
        series_idx: if b.kind == "Series" { series_index(b.number) } else { None },
        bookmarker: v.clone(), date: b.date.clone(),
        tags: b.tags.split(',').map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect(),
        note: b.note.clone(), rec: b.rec,
    }).collect()
}

fn all_bookmarks(state: &MockState) -> Vec<RenderBookmark> {
    let mut all = viewer_bookmarks(state);
    all.extend(canned_bookmarks());
    all
}

fn user_bookmarks(user: &str, state: &MockState) -> Vec<RenderBookmark> {
    if state.viewer.as_deref().is_some_and(|v| v.eq_ignore_ascii_case(user)) {
        return viewer_bookmarks(state);
    }
    canned_bookmarks().into_iter().filter(|b| b.bookmarker.eq_ignore_ascii_case(user)).collect()
}

// ---------------------------------------------------------------------------
// POST
// ---------------------------------------------------------------------------

fn param<'a>(params: &'a [(String, String)], key: &str) -> Option<&'a str> {
    params.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// Answer a form POST. Mirrors what AO3 redirects to after each action,
/// so the client's success checks read the same pages they would live.
pub fn respond_post(url: &str, params: &[(String, String)], cookies: &str) -> MockResponse {
    let req = Request::parse(url);
    with_state(|state| {
        adopt_viewer(state, cookies);
        if state.viewer.is_none() {
            return MockResponse { status: 200, body: render::login_page(state) };
        }
        route_post(&req, params, state).unwrap_or_else(|| not_found(url))
    })
}

fn route_post(req: &Request, params: &[(String, String)], state: &mut MockState) -> Option<MockResponse> {
    let segs = req.segs();
    let is_delete = param(params, "_method") == Some("delete");
    let body = match segs.as_slice() {
        // Subscriptions: the page after carries the form in its new state.
        ["users", _, "subscriptions"] => {
            let kind = param(params, "subscription[subscribable_type]").unwrap_or("Work").to_string();
            let target = param(params, "subscription[subscribable_id]")?.to_string();
            state.subscribe(&kind, &target);
            subscription_result_page(&kind, &target, state)
        }
        ["users", _, "subscriptions", id] if is_delete => {
            let removed = state.unsubscribe(id.parse().ok()?)?;
            subscription_result_page(&removed.kind, &removed.target, state)
        }

        // Bookmarks
        ["works", n, "bookmarks"] | ["series", n, "bookmarks"] => {
            let kind = if segs[0] == "works" { "Work" } else { "Series" };
            let number: u64 = n.parse().ok()?;
            let id = state.add_bookmark(kind, number,
                param(params, "bookmark[bookmarker_notes]").unwrap_or(""),
                param(params, "bookmark[tag_string]").unwrap_or(""),
                param(params, "bookmark[rec]") == Some("1"),
                param(params, "bookmark[private]") == Some("1"));
            let b = viewer_bookmarks(state).into_iter().find(|b| b.id == id)?;
            render::bookmark_page(&b, state)
        }
        ["bookmarks", id] if is_delete => {
            state.remove_bookmark(id.parse().ok()?);
            render::page("Bookmarks", "bookmarks-index region", "<p class=\"notice\">Bookmark was successfully deleted.</p><ol class=\"bookmark index group\"></ol>", state)
        }

        // Moderation: the index after the change.
        ["users", _, kind @ ("blocked" | "muted"), "users"] => {
            let target = param(params, if *kind == "blocked" { "blocked_id" } else { "muted_id" })?;
            state.set_moderation(kind, target);
            render::moderation_index(state, kind)
        }
        ["users", _, kind @ ("blocked" | "muted"), "users", rid] if is_delete => {
            state.clear_moderation(kind, rid.parse().ok()?);
            render::moderation_index(state, kind)
        }

        // Comments: the thread page with the new comment in it.
        ["works", ..] | ["chapters", ..] | ["comments", ..] => {
            let (work_idx, chapter, parent) = comments::target_of_post(&segs, state)?;
            let text = param(params, "comment[comment_content]").unwrap_or("").to_string();
            let id = state.add_comment(work_idx, chapter, parent, &text);
            let threads = match parent {
                Some(p) => comments::subtree(p, state).map(|(_, root)| vec![root]).unwrap_or_default(),
                None if chapter == 0 => comments::work_threads(work_idx, state),
                None => comments::chapter_threads(work_idx, chapter, false, state),
            };
            let _ = id;
            render::page("Comments", "comments-index region", &format!("<p class=\"notice\">Comment created!</p>{}", render::comments_fragment(&threads, 1, 1, "")), state)
        }
        _ => return None,
    };
    Some(ok(body))
}

fn subscription_result_page(kind: &str, target: &str, state: &MockState) -> String {
    let form = render::subscription_form(state, kind, target);
    render::page("Subscription", "subscriptions region", &format!("<ul class=\"navigation actions\"><li>{form}</li></ul>"), state)
}

// ---------------------------------------------------------------------------
// Login, kudos, images
// ---------------------------------------------------------------------------

/// Any username signs in; the password "wrong" is refused so the failure
/// path can be exercised too. Returns the cookie string to put in the
/// jar — the same names a real login sets, so `has_login_cookie` agrees.
pub fn login(username: &str, password: &str) -> Option<String> {
    let username = username.trim();
    if username.is_empty() || password == "wrong" { return None; }
    with_state(|s| s.viewer = Some(username.to_string()));
    Some(format!("remember_user_token={LOGIN_COOKIE_PREFIX}{username}; _otwarchive_session=mock-session"))
}

/// (status, body) as AO3's kudos endpoint answers: 201 the first time,
/// 422 "already left kudos" after.
pub fn kudos(work_id: u64, cookies: &str) -> (u16, String) {
    with_state(|s| {
        adopt_viewer(s, cookies);
        if s.viewer.is_none() {
            return (401, "{\"errors\":{\"user\":[\"must be signed in\"]}}".to_string());
        }
        if s.kudos.insert(work_id) {
            (201, "{}".to_string())
        } else {
            (422, "{\"errors\":{\"user_id\":[\"has already left kudos here. :)\"]}}".to_string())
        }
    })
}

/// Every image URL decodes to a small PNG; the colour follows the URL so
/// different images look different.
pub fn image(url: &str) -> Vec<u8> {
    let seed = url.bytes().fold(7u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32));
    let rgb = [120 + (seed % 100) as u8, 110 + ((seed >> 8) % 100) as u8, 100 + ((seed >> 16) % 100) as u8];
    if url.contains("icon") { render::png(64, 64, rgb) } else { render::png(240, 160, rgb) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;

    fn get(url: &str) -> String {
        let r = respond_get(&format!("{}{url}", crate::client::BASE_URL), false, "");
        assert_eq!(r.status, 200, "{url}");
        r.body
    }

    /// The mock is process-wide state; these tests share it, so they run
    /// one at a time, each from a fresh signed-out archive.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn setup() -> std::sync::MutexGuard<'static, ()> {
        let guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        guard
    }

    #[test]
    fn every_author_lists_their_works() {
        let _g = setup();
        for (ai, a) in AUTHORS.iter().enumerate() {
            let expect = live().into_iter().filter(|&i| WORKS[i].author == ai).count();
            let html = get(&format!("/users/{}/works?page=1", a.user));
            let works = parser::parse_work_listings(&html).unwrap();
            assert_eq!(works.len(), expect, "{} listing:\n{}", a.user, html);
            assert_eq!(parser::parse_listing_works_total(&html), Some(expect as u32), "{}", a.user);
            assert!(parser::parse_user_profile(&get(&format!("/users/{}/profile", a.user))).is_ok(), "{}", a.user);
        }
    }

    #[test]
    fn snapshots_change_what_update_detection_sees() {
        let _g = setup();
        let baseline = parser::parse_work_page(&get("/works/9100002?view_full_work=true"), 9100002).unwrap().0;
        assert_eq!(baseline.chapter_count, 7);
        let drift_before = parser::parse_work_page(&get("/works/9100004?view_full_work=true"), 9100004).unwrap().0;
        assert_eq!(parser::parse_work_listings(&get("/users/quietcartographer/works?page=1")).unwrap().len(), 3);
        assert_eq!(parser::parse_work_listings(&get("/series/9200001?page=1")).unwrap().len(), 3);
        assert_eq!(respond_get("https://archiveofourown.org/works/9100013", false, "").status, 404);

        data::set_snapshot(1);
        let (updated, chapters) = parser::parse_work_page(&get("/works/9100002?view_full_work=true"), 9100002).unwrap();
        assert_eq!(updated.chapter_count, 8);
        assert_eq!(chapters.len(), 8);
        assert!(updated.word_count > baseline.word_count);
        assert_ne!(updated.date_updated, baseline.date_updated);
        // Date drift only: the date moves, nothing countable does.
        let drift_after = parser::parse_work_page(&get("/works/9100004?view_full_work=true"), 9100004).unwrap().0;
        assert_ne!(drift_after.date_updated, drift_before.date_updated);
        assert_eq!(drift_after.chapter_count, drift_before.chapter_count);
        assert_eq!(drift_after.word_count, drift_before.word_count);
        // A new work by a followed author; a removed one is gone everywhere.
        let by_author = parser::parse_work_listings(&get("/users/quietcartographer/works?page=1")).unwrap();
        assert_eq!(by_author.len(), 4);
        assert!(by_author.iter().any(|w| w.external_id == "9100013"));
        assert_eq!(respond_get("https://archiveofourown.org/works/9100012?view_full_work=true", false, "").status, 404);
        let series = parser::parse_work_listings(&get("/series/9200001?page=1")).unwrap();
        assert_eq!(series.len(), 2);
        assert!(series.iter().all(|w| w.external_id != "9100012"));
        assert!(parser::parse_work_listings(&get("/works?page=3")).unwrap().iter().all(|w| w.external_id != "9100012"));

        data::set_snapshot(2);
        let done = parser::parse_work_page(&get("/works/9100002?view_full_work=true"), 9100002).unwrap().0;
        assert_eq!((done.chapter_count, done.total_chapters, done.complete), (9, Some(9), true));
        assert_eq!(respond_get("https://archiveofourown.org/works/9100012?view_full_work=true", false, "").status, 200);
        let series = parser::parse_work_listings(&get("/series/9200001?page=1")).unwrap();
        assert_eq!(series.len(), 4);
        let tide = parser::parse_work_page(&get("/works/9100001?view_full_work=true"), 9100001).unwrap().0;
        assert_eq!(tide.kudos, Some(1901));

        data::set_snapshot(99);
        assert_eq!(data::snapshot(), data::snapshot_count() - 1);
        data::set_snapshot(0);
    }

    #[test]
    fn every_work_parses_with_all_chapters() {
        let _g = setup();
        for w in live().into_iter().map(work) {
            let w = &w;
            let html = get(&format!("/works/{}?view_full_work=true&view_adult=true", w.id));
            let (summary, chapters) = parser::parse_work_page(&html, w.id).unwrap();
            assert_eq!(summary.title, w.title);
            assert_eq!(chapters.len() as u32, w.chapters, "{}", w.title);
            assert_eq!(summary.chapter_count, w.chapters);
            assert_eq!(summary.total_chapters, w.total);
            assert!(summary.word_count.unwrap() > 0);
            assert_eq!(summary.series.len(), memberships(work_index(w.id).unwrap()).len());
            if w.chapters > 1 {
                assert!(chapters.iter().all(|c| c.id.is_some() && c.title.is_some()), "{}", w.title);
            }
            for c in &chapters { assert!(!c.content.is_empty()); }
        }
    }

    #[test]
    fn listings_paginate_and_parse() {
        let _g = setup();
        let html = get("/works?page=1");
        let works = parser::parse_work_listings(&html).unwrap();
        assert_eq!(works.len(), render::PAGE_SIZE);
        assert!(parser::has_next_page(&html));
        assert_eq!(parser::total_pages(&html), 3);
        let last = get("/works?page=3");
        assert_eq!(parser::parse_work_listings(&last).unwrap().len(), live().len() - 2 * render::PAGE_SIZE);
        assert!(!parser::has_next_page(&last));

        let search = get("/works/search?page=1&commit=Search&work_search%5Bquery%5D=tide");
        let hits = parser::parse_work_listings(&search).unwrap();
        assert!(hits.iter().any(|h| h.title == "The Clockwork Tide"));
        assert!(hits.len() < live().len());
        assert_eq!(parser::parse_results_total(&search), Some(hits.len() as u32));

        let empty = get("/works/search?page=1&work_search%5Btitle%5D=zzz-no-such-title");
        assert!(parser::parse_work_listings(&empty).unwrap().is_empty());

        let tag = get("/tags/Slow%20Burn/works?page=1");
        assert_eq!(parser::parse_work_listings(&tag).unwrap().len(), 2);
        assert_eq!(parser::parse_results_total(&tag), Some(2));

        let author = get("/users/quietcartographer/works?page=1");
        assert_eq!(parser::parse_work_listings(&author).unwrap().len(), 3);
        let pseud = get("/users/quietcartographer/pseuds/inkandwaterline/works?page=1");
        assert_eq!(parser::parse_work_listings(&pseud).unwrap().len(), 3);

        let series = get("/series/9200001?page=1");
        assert_eq!(parser::parse_work_listings(&series).unwrap().len(), 3);
        assert_eq!(parser::parse_listing_works_total(&series), Some(3));

        assert!(parser::parse_search_form(&get("/works/search?edit_search=true")).is_ok());
    }

    #[test]
    fn comments_profiles_collections_parse() {
        let _g = setup();
        let w = &WORKS[0];
        let whole = get(&format!("/comments/show_comments?work_id={}&page=1", w.id));
        let page = parser::parse_comments(&whole);
        assert!(!page.comments.is_empty());
        assert!(page.total_pages >= 1);
        let cid = chapter_id(0, 1);
        let chapter = get(&format!("/works/{}/chapters/{cid}?show_comments=true&view_adult=true", w.id));
        assert!(!parser::parse_comments(&chapter).comments.is_empty());
        let first = page.comments[0].id;
        let thread = get(&format!("/comments/{first}"));
        assert_eq!(parser::parse_comments(&thread).comments[0].id, first);

        let profile = parser::parse_user_profile(&get("/users/Marrow_and_Moss/profile")).unwrap();
        assert_eq!(profile.profile.username, "Marrow_and_Moss");
        assert_eq!(profile.profile.property("works"), Some("3"));
        assert!(!profile.viewer_signed_in);

        let cols = parser::parse_collections_page(&get("/collections?page=1")).unwrap();
        assert_eq!(cols.len(), COLLECTIONS.len());
        assert!(parser::parse_collection_profile(&get("/collections/hollow_orrery_exchange/profile"), "hollow_orrery_exchange").is_ok());
        assert_eq!(parser::parse_work_listings(&get("/collections/hollow_orrery_exchange/works?page=1")).unwrap().len(), 3);
        let bms = parser::parse_bookmark_listings(&get("/users/driftwoodreader/bookmarks?page=1")).unwrap();
        assert_eq!(bms.len(), 2);
        assert!(parser::parse_bookmark_listings(&get("/bookmarks/search?page=1")).unwrap().len() > 2);
        assert_eq!(respond_get("https://archiveofourown.org/users/x/gifts", false, "").status, 404);
        assert_eq!(respond_get("https://archiveofourown.org/users/TallowAndTide./profile", false, "").status, 404);
        assert_eq!(respond_get("https://archiveofourown.org/users/TallowAndTide./works?page=1", false, "").status, 404);
        assert_eq!(respond_get("https://archiveofourown.org/users/driftwoodreader/profile", false, "").status, 200);
    }

    #[test]
    fn signed_in_actions_round_trip() {
        let _g = setup();
        assert!(login("someone", "wrong").is_none());
        let cookie = login("tester", "pw").unwrap();
        assert!(crate::client::has_login_cookie(&cookie));
        assert_eq!(viewer_from_cookies(&cookie).as_deref(), Some("tester"));
        // A relaunch restores the jar but not the mock's memory: the cookie signs the viewer back in.
        reset();
        assert_eq!(respond_get("https://archiveofourown.org/users/tester/profile", false, &cookie).status, 200);
        assert!(parser::parse_user_profile(&get("/users/Marrow_and_Moss/profile")).unwrap().viewer_signed_in);
        let w = &WORKS[2];
        let html = get(&format!("/works/{}?view_adult=true", w.id));
        let form = parser::parse_work_subscription_form(&html).unwrap();
        assert!(!form.subscribed);
        assert_eq!(form.subscribable_id, w.id.to_string());
        assert!(parser::parse_kudos_usernames(&html).iter().all(|n| n != "tester"));

        // Subscribe → the result page and the work page both show it; unsubscribe clears it.
        let r = respond_post(&format!("{}/users/tester/subscriptions", crate::client::BASE_URL), &[
            ("subscription[subscribable_id]".into(), w.id.to_string()),
            ("subscription[subscribable_type]".into(), "Work".into()),
        ], "");
        let f = parser::parse_work_subscription_form(&r.body).unwrap();
        assert!(f.subscribed);
        let sid = f.action.rsplit('/').next().unwrap().to_string();
        assert!(parser::parse_work_subscription_form(&get(&format!("/works/{}?view_adult=true", w.id))).unwrap().subscribed);
        let subs = parser::parse_subscriptions_page(&get("/users/tester/subscriptions?page=1")).unwrap();
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].ao3_id.as_deref(), Some(sid.as_str()));
        let r = respond_post(&format!("{}/users/tester/subscriptions/{sid}", crate::client::BASE_URL),
                             &[("_method".into(), "delete".into())], "");
        assert!(!parser::parse_work_subscription_form(&r.body).unwrap().subscribed);

        // Kudos: once, then "already".
        assert_eq!(kudos(w.id, "").0, 201);
        assert!(kudos(w.id, "").1.contains("already left kudos"));
        assert!(parser::parse_kudos_usernames(&get(&format!("/works/{}?view_adult=true", w.id))).contains(&"tester".to_string()));

        // Bookmark create → listed under the viewer; delete → gone.
        let r = respond_post(&format!("{}/works/{}/bookmarks", crate::client::BASE_URL, w.id), &[
            ("bookmark[bookmarker_notes]".into(), "keep".into()),
            ("bookmark[tag_string]".into(), "Comfort Read, Reread".into()),
            ("bookmark[rec]".into(), "1".into()),
        ], "");
        let id = r.body.split("id=\"bookmark_").nth(1).unwrap().split('"').next().unwrap().parse::<u64>().unwrap();
        let mine = parser::parse_bookmark_listings(&get("/users/tester/bookmarks?page=1")).unwrap();
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].ao3_bookmark_id, id);
        assert!(mine[0].rec && mine[0].tags.len() == 2 && mine[0].note == "keep");
        respond_post(&format!("{}/bookmarks/{id}", crate::client::BASE_URL), &[("_method".into(), "delete".into())], "");
        assert!(parser::parse_bookmark_listings(&get("/users/tester/bookmarks?page=1")).unwrap().is_empty());

        // Comment on a chapter, then reply to it; both show in the thread.
        let cid = chapter_id(2, 1);
        let r = respond_post(&format!("{}/chapters/{cid}/comments", crate::client::BASE_URL), &[
            ("comment[comment_content]".into(), "A fresh comment from the test".into()),
        ], "");
        assert!(r.body.contains("Comment created") && r.body.contains("A fresh comment from the test"));
        let posted = parser::parse_comments(&r.body).comments.into_iter().find(|c| c.author.username == "tester").unwrap();
        let r = respond_post(&format!("{}/comments/{}/comments", crate::client::BASE_URL, posted.id), &[
            ("comment[comment_content]".into(), "and a reply".into()),
        ], "");
        let tree = parser::parse_comments(&r.body).comments;
        assert_eq!(tree[0].id, posted.id);
        assert_eq!(tree[0].replies.len(), 1);

        // Block, then unblock, through the profile links and index.
        let p = parser::parse_user_profile(&get("/users/Marrow_and_Moss/profile")).unwrap();
        assert!(p.viewer_signed_in && p.profile.property("blocked").is_none());
        let r = respond_post(&format!("{}/users/tester/blocked/users", crate::client::BASE_URL),
                             &[("blocked_id".into(), "Marrow_and_Moss".into())], "");
        let list = parser::parse_moderation_list(&r.body, "confirm_unblock");
        assert_eq!(list.len(), 1);
        let rid = list[0].1.clone().unwrap();
        assert!(parser::parse_user_profile(&get("/users/Marrow_and_Moss/profile")).unwrap().profile.property("blocked").is_some());
        let r = respond_post(&format!("{}/users/tester/blocked/users/{rid}", crate::client::BASE_URL),
                             &[("_method".into(), "delete".into())], "");
        assert!(parser::parse_moderation_list(&r.body, "confirm_unblock").is_empty());

        let inbox = parser::parse_inbox(&get("/users/tester/inbox?page=1"));
        assert_eq!(inbox.items.len(), 3);
        assert_eq!(inbox.items.iter().filter(|i| i.is_unread).count(), 2);
        // Every inbox entry's thread is reachable the way the app fetches
        // it: crawl the work's comment pages until the id turns up.
        for item in &inbox.items {
            let work_id: u64 = item.work_url.as_deref().unwrap_or("")
                .split('/').find_map(|s| s.parse().ok()).expect("work id in inbox link");
            let mut page = 1;
            let mut found = false;
            loop {
                let r = respond_get(&format!("{}/comments/show_comments?work_id={work_id}&page={page}", crate::client::BASE_URL), true, "");
                assert_eq!(r.status, 200);
                let cp = parser::parse_comments(&r.body);
                fn has(list: &[crate::models::Comment], id: u64) -> bool {
                    list.iter().any(|c| c.id == id || has(&c.replies, id))
                }
                if has(&cp.comments, item.comment_id) { found = true; break; }
                if page >= cp.total_pages.max(1) { break; }
                page += 1;
            }
            assert!(found, "inbox comment {} not on any comment page of work {work_id}", item.comment_id);
            assert_eq!(respond_get(&format!("{}/comments/{}", crate::client::BASE_URL, item.comment_id), false, "").status, 200);
        }

        let img = image("/images/mock/long-table-9100010.png");
        assert_eq!(crate::client::sniff_image_kind(&img), "png");
    }
}
