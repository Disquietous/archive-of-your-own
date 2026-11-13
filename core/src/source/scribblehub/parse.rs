//! ScribbleHub page parsers: a series page (work record, first TOC page,
//! reviews), a TOC fragment from the releases endpoint, a chapter page
//! (text, author note, neighbours, comments). Pure functions over HTML;
//! the fetch plan lives in `mod.rs`. Shapes pinned by fixture tests in
//! `tests/fixtures/scribblehub_*.html` (hand-authored, synthetic).

use scraper::{ElementRef, Html, Selector};

use crate::models::{AO3User, Chapter, Comment, ContentBlock, Rating, SourceUserProfile, WorkSummary};
use crate::source::{ListedWork, ListingPage, SourceStat};
use crate::parser::html_to_blocks;

use super::{BASE_URL, SOURCE_ID};

/// One TOC row: the chapter's id, its 1-based order, title and posted date.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TocEntry {
    pub chapter_id: u64,
    pub number: u32,
    pub title: String,
    /// "YYYY-MM-DD" (from the row's full timestamp title).
    pub date: String,
}

/// The story's `/stats` page: the only place the site reports a word
/// count. Numbers are the "Details" table's rows, exact (not abbreviated).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StatsPage {
    pub word_count: Option<u64>,
    /// "Total Views (All)".
    pub views: Option<u64>,
    pub average_words: Option<u64>,
}

/// Everything a series page yields.
#[derive(Debug, Clone)]
pub struct SeriesPage {
    pub summary: WorkSummary,
    /// The author as a site user: `id` is the profile id, with the
    /// profile URL. None when the page names no author link.
    pub author: Option<AO3User>,
    /// Canonical page URL (og:url), with the slug.
    pub canonical_url: String,
    pub status: String,
    pub content_warnings: Vec<String>,
    pub rating_avg: Option<f64>,
    pub rating_count: Option<u32>,
    pub views: Option<u64>,
    pub favorites: Option<u32>,
    pub readers: Option<u32>,
    /// Chapter count the stats strip reports (the TOC may be paginated).
    pub chapter_total: Option<u32>,
    /// Newest-first, as the page lists them.
    pub toc: Vec<TocEntry>,
    pub toc_pages: u32,
    pub reviews: Vec<Comment>,
    pub review_pages: u32,
}

/// A chapter page.
#[derive(Debug, Clone)]
pub struct ChapterPage {
    pub title: String,
    pub content: Vec<ContentBlock>,
    pub notes_after: Option<String>,
    pub prev_chapter_id: Option<u64>,
    pub next_chapter_id: Option<u64>,
    pub comments: Vec<Comment>,
    pub comment_pages: u32,
}

pub(super) fn sel(s: &str) -> Selector {
    Selector::parse(s).expect("static selector")
}

pub(super) fn text(el: &ElementRef) -> String {
    el.text().collect::<Vec<_>>().join("").split_whitespace().collect::<Vec<_>>().join(" ")
}

fn first_text(root: &ElementRef, selector: &str) -> Option<String> {
    root.select(&sel(selector)).next().map(|e| text(&e)).filter(|t| !t.is_empty())
}

pub(super) fn attr<'a>(el: &ElementRef<'a>, name: &str) -> Option<&'a str> {
    el.value().attr(name).map(str::trim).filter(|v| !v.is_empty())
}

/// Trailing digits of a path segment: the id in ".../chapter/2300107/",
/// ".../profile/51230/name/" (first segment after `marker`).
pub(super) fn id_after<'a>(path: &'a str, marker: &str) -> Option<u64> {
    let rest = path.split(marker).nth(1)?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() { None } else { digits.parse().ok() }
}

/// "12.4k" → 12400, "4159" → 4159, "1.2m" → 1_200_000.
pub(super) fn parse_abbreviated(s: &str) -> Option<u64> {
    let s = s.trim().replace(',', "").to_ascii_lowercase();
    if s.is_empty() { return None }
    let (num, mult) = match s.chars().last()? {
        'k' => (&s[..s.len() - 1], 1_000.0),
        'm' => (&s[..s.len() - 1], 1_000_000.0),
        _ => (s.as_str(), 1.0),
    };
    num.trim().parse::<f64>().ok().map(|n| (n * mult).round() as u64)
}

/// "Oct 5, 2026" or "Oct 5, 2026 06:30 PM" → "2026-10-05". Anything the
/// site may format differently comes back unchanged.
pub(super) fn normalize_date(raw: &str) -> String {
    let parts: Vec<&str> = raw.split_whitespace().collect();
    if parts.len() < 3 { return raw.trim().to_string() }
    let month = match parts[0].to_ascii_lowercase().as_str() {
        "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6,
        "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12,
        _ => return raw.trim().to_string(),
    };
    let day: u32 = match parts[1].trim_end_matches(',').parse() { Ok(d) => d, Err(_) => return raw.trim().to_string() };
    let year: u32 = match parts[2].parse() { Ok(y) => y, Err(_) => return raw.trim().to_string() };
    format!("{year:04}-{month:02}-{day:02}")
}

/// The `items: N` of the jQuery pagination bound to `#id`: how many pages
/// the list has. 1 when the page shows no pager.
pub(super) fn pagination_items(html: &str, id: &str) -> u32 {
    let marker = format!("'#{id}').pagination(");
    let Some(start) = html.find(&marker) else { return 1 };
    let tail = &html[start + marker.len()..];
    let Some(items) = tail.find("items:") else { return 1 };
    let digits: String = tail[items + 6..].trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().unwrap_or(1).max(1)
}

/// A commenter as the page shows them: the profile id is the stable key,
/// the same one a story's author or a search hit carries, so one person
/// is one users row however they were first seen. Only a commenter with
/// no profile link gets a namespaced guest id.
fn user_from_link(link: Option<ElementRef>, avatar: Option<String>) -> AO3User {
    let (name, url) = match link {
        Some(a) => (text(&a), attr(&a, "href").map(|h| absolute(h))),
        None => ("Anonymous".to_string(), None),
    };
    let id = url.as_deref().and_then(|u| id_after(u, "/profile/"))
        .map(|n| n.to_string())
        .unwrap_or_else(|| format!("guest:{SOURCE_ID}:{}", name.to_ascii_lowercase()));
    AO3User { source: SOURCE_ID.to_string(), id, username: name, profile_url: url, avatar_url: avatar }
}

fn absolute(href: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") { href.to_string() }
    else if href.starts_with('/') { format!("{BASE_URL}{href}") }
    else { format!("{BASE_URL}/{href}") }
}

/// Emoji sprites are transparent images whose `title` carries the name;
/// render them as text instead of fetching a blank png.
fn inline_emoji(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find("<img") {
        let Some(end_rel) = rest[start..].find('>') else { break };
        let tag = &rest[start..start + end_rel + 1];
        out.push_str(&rest[..start]);
        if tag.contains("mceSmilieSprite") {
            let title = tag.split("title=\"").nth(1).and_then(|t| t.split('"').next()).unwrap_or("");
            if !title.is_empty() { out.push_str(&format!(":{}:", title.replace(' ', "_"))); }
        } else {
            out.push_str(tag);
        }
        rest = &rest[start + end_rel + 1..];
    }
    out.push_str(rest);
    out
}

fn blocks_from_html(html: &str, base: &str) -> Vec<ContentBlock> {
    html_to_blocks(&inline_emoji(html), base)
}

fn plain_text_of(blocks: &[ContentBlock]) -> String {
    fn inline(v: &[crate::models::InlineContent], out: &mut String) {
        use crate::models::InlineContent::*;
        for i in v {
            match i {
                Text { value } => out.push_str(value),
                Bold { content } | Italic { content } | Strikethrough { content } | Superscript { content }
                | Link { content, .. } => inline(content, out),
                LineBreak => out.push('\n'),
            }
        }
    }
    let mut out = String::new();
    for b in blocks {
        match b {
            ContentBlock::Paragraph { text } => { inline(text, &mut out); out.push('\n'); }
            ContentBlock::Heading { text, .. } => { out.push_str(text); out.push('\n'); }
            ContentBlock::Blockquote { blocks } => { out.push_str(&plain_text_of(blocks)); }
            ContentBlock::List { items, .. } => for it in items { out.push_str(&plain_text_of(it)); },
            _ => {}
        }
    }
    out.trim().to_string()
}

// ---------------------------------------------------------------------------
// Series page
// ---------------------------------------------------------------------------

fn parse_toc_rows<'a>(rows: impl Iterator<Item = ElementRef<'a>>) -> Vec<TocEntry> {
    rows.filter_map(|li| {
        let a = li.select(&sel("a.toc_a")).next()?;
        let href = attr(&a, "href")?;
        let chapter_id = id_after(href, "/chapter/")?;
        let number: u32 = attr(&li, "order").and_then(|o| o.parse().ok()).unwrap_or(0);
        let date = li.select(&sel("span.fic_date_pub")).next()
            .and_then(|d| attr(&d, "title").map(str::to_string).or_else(|| Some(text(&d))))
            .map(|d| normalize_date(&d))
            .unwrap_or_default();
        Some(TocEntry { chapter_id, number, title: text(&a), date })
    }).collect()
}

/// The TOC rows of a releases-endpoint response (a bare `<li>` list, or
/// an `<ol>` around them).
pub fn parse_toc_fragment(html: &str) -> Vec<TocEntry> {
    let frag = Html::parse_fragment(html);
    parse_toc_rows(frag.select(&sel("li.toc_w")))
}

fn parse_review(item: &ElementRef, base: &str) -> Option<Comment> {
    let id = attr(item, "id")?.strip_prefix("comment-")?.parse().ok()?;
    let avatar = item.select(&sel("div.rev_left img")).next().and_then(|i| attr(&i, "src").map(str::to_string));
    let author = user_from_link(item.select(&sel("a#revname, a[class^=revname]")).next(), avatar);
    let stars = item.select(&sel("i.userreview")).filter(|i| {
        attr(i, "class").map(|c| c.split_whitespace().any(|k| k == "fa-star")).unwrap_or(false)
    }).count() as u8;
    let posted_at = first_text(item, "div.td_top_second a").unwrap_or_default();
    let status = first_text(item, "span.fic_r_stats");
    let body_html: String = item.select(&sel("div[class^='w-comments-item-text']")).next()
        .map(|body| body.children().filter_map(ElementRef::wrap)
            .filter(|c| !attr(c, "class").map(|k| k.contains("read-more-review")).unwrap_or(false))
            .map(|c| c.html()).collect::<Vec<_>>().join("\n"))
        .unwrap_or_default();
    Some(Comment {
        id,
        author,
        posted_at,
        content: blocks_from_html(&body_html, base),
        replies: Vec::new(),
        chapter_label: status,
        chapter_id: None,
        notice: None,
        more_replies: 0,
        rating: if stars > 0 { Some(stars) } else { None },
    })
}

/// The reviews listed on a series page (one page of them).
pub fn parse_reviews(doc: &Html, base: &str) -> Vec<Comment> {
    doc.select(&sel("div.w-comments-item")).filter_map(|item| parse_review(&item, base)).collect()
}

/// Genre → the AO3-shaped rating the content filter understands. The site
/// has no rating of its own; "Adult" is its explicit-content genre and
/// "Mature" its mature one.
fn rating_from(genres: &[String]) -> Rating {
    if genres.iter().any(|g| g.eq_ignore_ascii_case("Adult")) { Rating::Explicit }
    else if genres.iter().any(|g| g.eq_ignore_ascii_case("Mature")) { Rating::Mature }
    else { Rating::NotRated }
}

pub fn parse_series_page(html: &str, external_id: &str) -> Result<SeriesPage, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let root = doc.root_element();
    let canonical_url = doc.select(&sel("meta[property='og:url']")).next()
        .and_then(|m| attr(&m, "content").map(str::to_string))
        .unwrap_or_else(|| format!("{BASE_URL}/series/{external_id}/"));
    let title = first_text(&root, "div.fic_title")
        .ok_or_else(|| crate::error::AppError::ParseError("ScribbleHub series page has no title".to_string()))?;
    let author = first_text(&root, "span.auth_name_fic")
        .or_else(|| first_text(&root, "[property='author'] [property='name']"))
        .unwrap_or_default();
    let author_user = root.select(&sel("[property='author'] a[href*='/profile/'], span.auth_name_fic"))
        .find_map(|el| {
            let a = if el.value().name() == "a" { el } else {
                let mut cur = el.parent();
                loop {
                    let p = ElementRef::wrap(cur?)?;
                    if p.value().name() == "a" { break p }
                    cur = p.parent();
                }
            };
            let href = attr(&a, "href")?;
            let url = absolute(href);
            let id = id_after(&url, "/profile/")?;
            Some(AO3User { source: SOURCE_ID.to_string(), id: id.to_string(), username: author.clone(), profile_url: Some(url), avatar_url: None })
        });
    let summary_html = root.select(&sel("div.wi_fic_desc")).next().map(|d| d.inner_html()).unwrap_or_default();
    let summary_text = plain_text_of(&blocks_from_html(&summary_html, &canonical_url));
    let genres: Vec<String> = root.select(&sel("a.fic_genre")).map(|a| text(&a)).filter(|t| !t.is_empty()).collect();
    let site_tags: Vec<String> = root.select(&sel("a.stag")).map(|a| text(&a)).filter(|t| !t.is_empty()).collect();
    let content_warnings: Vec<String> = root.select(&sel("li.mature_contains")).map(|li| text(&li)).filter(|t| !t.is_empty()).collect();

    // Stats strip: "<icon> 12.4k <span class=mb_stat>Views</span>".
    let mut views = None; let mut favorites = None; let mut readers = None; let mut chapter_total = None;
    for item in root.select(&sel("div.fic_stats span.st_item")) {
        let label = first_text(&item, "span.mb_stat").unwrap_or_default().to_ascii_lowercase();
        let value = item.text().collect::<String>();
        let value = value.split_whitespace().next().unwrap_or("");
        let n = parse_abbreviated(value);
        match label.as_str() {
            "views" => views = n,
            "favorites" => favorites = n.map(|v| v as u32),
            "readers" => readers = n.map(|v| v as u32),
            "chapters" => chapter_total = n.map(|v| v as u32),
            _ => {}
        }
    }
    let rating_avg = root.select(&sel("#ratefic_user")).next()
        .and_then(|r| attr(&r, "rating")).and_then(|v| v.parse::<f64>().ok()).filter(|v| *v > 0.0);
    let rating_count = first_text(&root, "span.rate_more")
        .and_then(|t| t.split_whitespace().next().map(str::to_string))
        .and_then(|t| parse_abbreviated(&t)).map(|v| v as u32);

    // Sidebar: "<span title='Last updated: …'>Completed</span>" beside the ? icon.
    let (status, last_updated) = root.select(&sel("i.fa-question.status")).next()
        .and_then(|icon| icon.parent().and_then(ElementRef::wrap))
        .and_then(|rnd| rnd.next_siblings().filter_map(ElementRef::wrap).next())
        .map(|span| (text(&span), attr(&span, "title").and_then(|t| t.strip_prefix("Last updated:")).map(|d| normalize_date(d.trim()))))
        .unwrap_or_default();

    let toc = parse_toc_rows(root.select(&sel("ol.toc_ol li.toc_w")));
    let toc_pages = pagination_items(html, "pagination-mesh-toc");
    let reviews = parse_reviews(&doc, &canonical_url);
    let review_pages = pagination_items(html, "pagination-mesh-reviews");

    let complete = status.eq_ignore_ascii_case("completed");
    let chapter_count = chapter_total.unwrap_or(toc.len() as u32);
    let newest = toc.iter().map(|t| t.date.as_str()).max().map(str::to_string);
    let mut tags = genres.clone();
    tags.extend(site_tags);
    let fandoms = if genres.iter().any(|g| g.eq_ignore_ascii_case("Fan Fiction")) { Vec::new() }
                  else { vec!["Original Work".to_string()] };
    let summary = WorkSummary {
        id: 0,
        source: SOURCE_ID.to_string(),
        external_id: external_id.to_string(),
        url: canonical_url.clone(),
        title,
        authors: if author.is_empty() { Vec::new() } else { vec![author] },
        fandoms,
        rating: rating_from(&genres),
        warnings: Vec::new(),
        categories: Vec::new(),
        relationships: Vec::new(),
        characters: Vec::new(),
        tags,
        summary: summary_text,
        word_count: None,
        chapter_count,
        total_chapters: if complete { Some(chapter_count) } else { None },
        kudos: None,
        hits: None,
        bookmarks: None,
        comments: None,
        // Published is the oldest TOC row, which may sit on a later TOC
        // page; the fetcher fills it in once every page is read.
        date_published: toc.iter().map(|t| t.date.clone()).min().unwrap_or_default(),
        date_updated: last_updated.or(newest).unwrap_or_default(),
        language: "English".to_string(),
        complete,
        series: Vec::new(),
        fetched_at: String::new(),
    
        author_ids: Vec::new(),
    };
    Ok(SeriesPage {
        summary, author: author_user, canonical_url, status, content_warnings, rating_avg, rating_count, views, favorites, readers,
        chapter_total, toc, toc_pages, reviews, review_pages,
    })
}

// ---------------------------------------------------------------------------
// Chapter page
// ---------------------------------------------------------------------------

fn parse_chapter_comment(li: &ElementRef, base: &str, chapter_id: u64) -> Option<Comment> {
    let id = attr(li, "id")?.strip_prefix("comment-")?.parse().ok()?;
    let body = li.select(&sel("div.comment-body")).next()?;
    let avatar = body.select(&sel("div.comment-author img")).next().and_then(|i| attr(&i, "src").map(str::to_string));
    let author = user_from_link(body.select(&sel("div.comment-author span.fn a")).next(), avatar);
    let posted_at = body.select(&sel("span.com_date")).next()
        .map(|d| attr(&d, "title").map(str::to_string).unwrap_or_else(|| text(&d)))
        .unwrap_or_default();
    let content = body.select(&sel("div.user-comment")).next()
        .map(|c| blocks_from_html(&c.inner_html(), base)).unwrap_or_default();
    // Replies: the li's own `ul.children` (not a deeper one).
    let replies = li.children().filter_map(ElementRef::wrap)
        .filter(|c| c.value().name() == "ul" && attr(c, "class").map(|k| k.contains("children")).unwrap_or(false))
        .flat_map(|ul| ul.children().filter_map(ElementRef::wrap).filter(|c| c.value().name() == "li").collect::<Vec<_>>())
        .filter_map(|child| parse_chapter_comment(&child, base, chapter_id))
        .collect();
    Some(Comment {
        id, author, posted_at, content, replies,
        chapter_label: None,
        chapter_id: Some(chapter_id),
        notice: None,
        more_replies: 0,
        rating: None,
    })
}

/// The comments on a chapter page (one page; threaded two deep).
pub fn parse_chapter_comments(doc: &Html, base: &str, chapter_id: u64) -> Vec<Comment> {
    let Some(list) = doc.select(&sel("ol.comment-list")).next() else { return Vec::new() };
    list.children().filter_map(ElementRef::wrap)
        .filter(|c| c.value().name() == "li")
        .filter_map(|li| parse_chapter_comment(&li, base, chapter_id))
        .collect()
}

pub fn parse_chapter_page(html: &str, chapter_id: u64) -> Result<ChapterPage, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let root = doc.root_element();
    let base = doc.select(&sel("meta[property='og:url']")).next()
        .and_then(|m| attr(&m, "content").map(str::to_string))
        .unwrap_or_else(|| BASE_URL.to_string());
    let title = first_text(&root, "div.chapter-title").unwrap_or_default();
    let raw = root.select(&sel("div.chp_raw")).next()
        .ok_or_else(|| crate::error::AppError::ParseError("ScribbleHub chapter page has no text".to_string()))?;
    // The author's note is nested inside the text container; split it out
    // so it renders as a note, the way AO3's end notes do.
    let note_el = raw.select(&sel("div.wi_authornotes")).next();
    let note_html = note_el.and_then(|n| n.select(&sel("div.wi_authornotes_body")).next()).map(|b| b.inner_html());
    let mut body_html = raw.inner_html();
    if let Some(n) = note_el {
        let marker = n.html();
        if let Some(pos) = body_html.find(&marker) { body_html.replace_range(pos..pos + marker.len(), ""); }
    }
    let mut content = blocks_from_html(&body_html, &base);
    let mut notes_after = None;
    if let Some(note_html) = note_html {
        let note_blocks = blocks_from_html(&note_html, &base);
        let plain = plain_text_of(&note_blocks);
        if !plain.is_empty() {
            content.push(ContentBlock::Heading { level: 4, text: "Author's note:".to_string() });
            content.push(ContentBlock::HorizontalRule);
            content.extend(note_blocks);
            notes_after = Some(plain);
        }
    }
    let neighbour = |class: &str| root.select(&sel(class)).next()
        .and_then(|a| attr(&a, "href")).and_then(|h| id_after(h, "/chapter/"));
    Ok(ChapterPage {
        title,
        content,
        notes_after,
        prev_chapter_id: neighbour("a.btn-prev"),
        next_chapter_id: neighbour("a.btn-next"),
        comments: parse_chapter_comments(&doc, &base, chapter_id),
        comment_pages: pagination_items(html, "pagination-mesh"),
    })
}

/// A TOC entry as a stub chapter row: title and id, no text yet.
pub fn stub_chapter(entry: &TocEntry) -> Chapter {
    Chapter {
        id: Some(entry.chapter_id),
        title: Some(entry.title.clone()),
        number: entry.number,
        content: Vec::new(),
        notes_before: None,
        notes_after: None,
    }
}

/// The "Details" table of the stats page. Rows are `th` label + `td`
/// value; the site's markup drops a `</tr>` mid-table, so rows are read
/// label by label rather than row by row.
pub fn parse_stats_page(html: &str) -> StatsPage {
    let doc = Html::parse_document(html);
    let th = Selector::parse("table.table_pro_overview th").unwrap();
    let mut stats = StatsPage::default();
    for label in doc.select(&th) {
        let key = label.text().collect::<String>();
        let key = key.trim().trim_end_matches(':').trim();
        let value = label.next_siblings()
            .filter_map(ElementRef::wrap)
            .find(|e| e.value().name() == "td")
            .map(|td| td.text().collect::<String>())
            .and_then(|v| parse_abbreviated(&v));
        match key {
            "Word Count" => stats.word_count = value,
            "Total Views (All)" => stats.views = value,
            "Average Words" => stats.average_words = value,
            _ => {}
        }
    }
    stats
}

/// A page of a user's series list (the profile's Series tab, served by
/// the `wi_perseries` endpoint): one `div.search_main_box` per story
/// with title link, cover, rating "(4.4)", a stats strip ("12.4k Views",
/// "231 Favorites", "5 Chapters", "64 Readers", "2 Reviews", "23.4k
/// Words", a "Last Updated" date, the author link), genres (a
/// "Completed" marker among them) and the blurb with its hidden
/// "more>>" tail. The pager is `#pagination-profile-series`.
pub fn parse_profile_series(html: &str) -> ListingPage {
    parse_series_boxes(html, "pagination-profile-series")
}

/// A Series Finder results page (`/series-finder/?sf=1&…&pg=N`): the
/// same series boxes as a profile's list, paged by the finder's own
/// pager widget.
pub fn parse_finder_results(html: &str) -> ListingPage {
    parse_series_boxes(html, "pagination-profile-recent")
}

/// Series boxes (`div.search_main_box`) wherever the site lists series;
/// `pager_id` names the pagination widget whose item count is the page
/// total.
fn parse_series_boxes(html: &str, pager_id: &str) -> ListingPage {
    let doc = Html::parse_fragment(html);
    let mut works = Vec::new();
    for item in doc.select(&sel("div.search_main_box")) {
        let Some(link) = item.select(&sel("div.search_title a[href]")).next() else { continue };
        let url = absolute(attr(&link, "href").unwrap_or(""));
        let Some(id) = id_after(&url, "/series/") else { continue };
        let title = text(&link);
        if title.is_empty() { continue }

        let author_link = item.select(&sel("span.a_un_st a[href]")).next();
        let author_name = author_link.as_ref().map(text).unwrap_or_default();
        let author_user = author_link.and_then(|a| {
            let url = absolute(attr(&a, "href")?);
            let pid = id_after(&url, "/profile/")?;
            Some(AO3User { source: SOURCE_ID.to_string(), id: pid.to_string(), username: author_name.clone(), profile_url: Some(url), avatar_url: None })
        });

        let mut views = None; let mut favorites = None; let mut readers = None; let mut reviews = None;
        let mut chapters = None; let mut words = None; let mut updated = String::new();
        let mut per_week = None;
        for stat in item.select(&sel("div.search_stats span.nl_stat")) {
            let label = stat.text().collect::<String>();
            let label = label.trim();
            if attr(&stat, "title") == Some("Last Updated") { updated = normalize_date(label); continue }
            if attr(&stat, "title") == Some("Author") { continue }
            let mut parts = label.split_whitespace();
            let (Some(value), Some(unit)) = (parts.next(), parts.next()) else { continue };
            let n = parse_abbreviated(value);
            match unit.to_ascii_lowercase().as_str() {
                "views" => views = n,
                "favorites" => favorites = n,
                "chapters" => chapters = n,
                "readers" => readers = n,
                "reviews" => reviews = n,
                "words" => words = n,
                "chapters/week" => per_week = value.parse::<f64>().ok(),
                _ => {}
            }
        }
        let rating_avg = first_text(&item, "div.search_ratings")
            .and_then(|t| t.trim().trim_matches(|c| c == '(' || c == ')').parse::<f64>().ok())
            .filter(|v| *v > 0.0);
        let mut complete = false;
        let mut genres: Vec<String> = Vec::new();
        for g in item.select(&sel("div.search_genre a.fic_genre")) {
            if attr(&g, "class").is_some_and(|c| c.split_whitespace().any(|w| w == "completed")) { complete = true; continue }
            let name = text(&g);
            if !name.is_empty() { genres.push(name); }
        }
        // The blurb is the body's loose text after the genre row; the
        // "more>>" / "<<less" toggles are links, the hidden tail is text.
        let summary_text = item.select(&sel("div.search_body")).next().map(|body| {
            let mut out = String::new();
            let genre_row = body.select(&sel("div.search_genre")).next();
            let mut after = genre_row.is_none();
            for node in body.children() {
                if let Some(el) = ElementRef::wrap(node) {
                    if Some(el) == genre_row { after = true; continue }
                    if !after { continue }
                    if el.value().has_class("morelink", scraper::CaseSensitivity::AsciiCaseInsensitive)
                        || el.value().has_class("dots", scraper::CaseSensitivity::AsciiCaseInsensitive) { continue }
                    for t in el.text() {
                        if t.contains("<<less") || t.contains("more>>") { continue }
                        out.push_str(t);
                    }
                } else if after {
                    if let Some(t) = node.value().as_text() { out.push_str(t); }
                }
            }
            out.split_whitespace().collect::<Vec<_>>().join(" ")
        }).unwrap_or_default();

        let chapter_count = chapters.unwrap_or(0) as u32;
        let fandoms = if genres.iter().any(|g| g.eq_ignore_ascii_case("Fan Fiction")) { Vec::new() }
                      else { vec!["Original Work".to_string()] };
        let summary = WorkSummary {
            id: 0,
            source: SOURCE_ID.to_string(),
            external_id: id.to_string(),
            url: url.clone(),
            title,
            authors: if author_name.is_empty() { Vec::new() } else { vec![author_name.clone()] },
            fandoms,
            rating: rating_from(&genres),
            warnings: Vec::new(),
            categories: Vec::new(),
            relationships: Vec::new(),
            characters: Vec::new(),
            tags: genres,
            summary: summary_text,
            word_count: words,
            chapter_count,
            total_chapters: if complete { Some(chapter_count) } else { None },
            kudos: None,
            hits: None,
            bookmarks: None,
            comments: None,
            date_published: String::new(),
            date_updated: updated,
            language: "English".to_string(),
            complete,
            series: Vec::new(),
            fetched_at: String::new(),
        
            author_ids: Vec::new(),
        };
        let mut stats = Vec::new();
        if let Some(avg) = rating_avg { stats.push(SourceStat::num("rating", "Rating", avg, 1)); }
        if let Some(n) = views { stats.push(SourceStat::num("views", "Views", n as f64, 3)); }
        if let Some(n) = favorites { stats.push(SourceStat::num("favorites", "Favorites", n as f64, 4)); }
        if let Some(n) = readers { stats.push(SourceStat::num("readers", "Readers", n as f64, 5)); }
        if let Some(n) = reviews { stats.push(SourceStat::num("reviews", "Reviews", n as f64, 8)); }
        if let Some(n) = per_week { stats.push(SourceStat::num("release_rate", "Chapters/Week", n, 7)); }
        if complete {
            stats.push(SourceStat { key: "status".into(), label: "Status".into(), num: None, text: Some("Completed".into()), order: 6 });
        }
        works.push(ListedWork { summary, stats, authors: author_user.into_iter().collect() });
    }
    let total_pages = pagination_items(html, pager_id);
    ListingPage { works, has_next: false, total_pages, total_works: None }
}

/// The live search's users-mode reply: `li.sh-ri` items, each an anchor
/// to a profile with an avatar and the name. Read tolerantly — the item
/// is the anchor's profile link, the name is the first text that is not
/// a count, the avatar the first image — so a restyled widget still
/// parses. The WordPress ajax trailing "0" is ignored by the parser.
pub fn parse_user_search(html: &str) -> Vec<AO3User> {
    let doc = Html::parse_fragment(html);
    let mut out = Vec::new();
    for item in doc.select(&sel("li.sh-ri")) {
        let Some(link) = item.select(&sel("a[href*='/profile/']")).next() else { continue };
        let url = absolute(attr(&link, "href").unwrap_or(""));
        let Some(id) = id_after(&url, "/profile/") else { continue };
        let avatar = item.select(&sel("img.sh-ava, img")).next().and_then(|i| attr(&i, "src").map(str::to_string));
        // The name is `.sh-t`, with the matched letters wrapped in a
        // `<mark>` — so it is the element's whole text, not its first
        // text node. `.sh-m` beside it is the role ("Reader", "Author").
        let name = item.select(&sel(".sh-t")).next()
            .map(|n| n.text().collect::<String>())
            .unwrap_or_else(|| link.text().collect::<String>());
        let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
        if name.is_empty() { continue }
        if out.iter().any(|u: &AO3User| u.id == id.to_string()) { continue }
        out.push(AO3User { source: SOURCE_ID.to_string(), id: id.to_string(), username: name, profile_url: Some(url), avatar_url: avatar });
    }
    out
}

/// A user's profile page (`/profile/{id}/{slug}/`): header (name,
/// avatar, Joined / Followers / Following / Comments pairs), "Personal
/// Information" and "Author Information" tables, and the About text.
/// Every figure is a source property under the site's own name (see
/// `user_fields::SCRIBBLEHUB` for what each maps to); "--" is unset.
pub fn parse_profile_page(html: &str, source_id: &str) -> Result<SourceUserProfile, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let root = doc.root_element();
    let url = doc.select(&sel("meta[property='og:url']")).next()
        .and_then(|m| attr(&m, "content").map(str::to_string))
        .unwrap_or_else(|| format!("{BASE_URL}/profile/{source_id}/"));
    let username = first_text(&root, "div.p_m_username")
        .ok_or_else(|| crate::error::AppError::ParseError("ScribbleHub profile page has no username".to_string()))?;
    let avatar = root.select(&sel("span.p_avatar img")).next().and_then(|i| attr(&i, "src").map(str::to_string))
        .or_else(|| doc.select(&sel("meta[property='og:image']")).next().and_then(|m| attr(&m, "content").map(str::to_string)));

    // Header pairs: <dl class=row_pairs><dt>Label</dt><dd>value</dd>.
    let mut pairs: Vec<(String, String)> = Vec::new();
    for dl in root.select(&sel("dl.row_pairs")) {
        let label = first_text(&dl, "dt").unwrap_or_default();
        let value = first_text(&dl, "dd").unwrap_or_default();
        if !label.is_empty() && !value.is_empty() { pairs.push((label, value)); }
    }
    // Both information tables: <th>Label:</th><td>value</td>.
    for th in root.select(&sel("table.table_pro_overview th")) {
        let label = th.text().collect::<String>();
        let label = label.trim().trim_end_matches(':').trim().to_string();
        let value = th.next_siblings().filter_map(ElementRef::wrap)
            .find(|e| e.value().name() == "td")
            .map(|td| td.text().collect::<String>().trim().to_string())
            .unwrap_or_default();
        if !label.is_empty() && !value.is_empty() && value != "--" { pairs.push((label, value)); }
    }
    let take = |name: &str| pairs.iter().find(|(l, _)| l.eq_ignore_ascii_case(name)).map(|(_, v)| v.clone());
    let number = |name: &str| take(name).and_then(|v| parse_abbreviated(&v)).map(|n| n.to_string());

    let mut properties: Vec<(String, String)> = vec![("profile_url".into(), url)];
    let mut put = |name: &str, value: Option<String>| {
        if let Some(v) = value.filter(|v| !v.is_empty()) { properties.push((name.into(), v)); }
    };
    put("avatar", avatar);
    put("joined", take("Joined").map(|d| normalize_date(&d)));
    put("location", take("Location"));
    put("birthday", take("Birthday"));
    put("gender", take("Gender"));
    put("homepage", take("Homepage"));
    put("last_active", take("Last Active"));
    let bio_html = root.select(&sel("div.user_bio_profile")).next().map(|d| d.inner_html()).unwrap_or_default();
    let bio = blocks_from_html(&bio_html, BASE_URL);
    if !bio.is_empty() { put("about", serde_json::to_string(&bio).ok()); }
    put("series", number("Series"));
    put("followers", number("Followers"));
    put("following", number("Following"));
    put("comments", number("Comments"));
    put("readers", number("Readers"));
    put("total_words", number("Total Words"));
    put("total_pageviews", number("Total Pageviews"));
    put("reviews_received", number("Reviews Received"));

    Ok(SourceUserProfile { source: SOURCE_ID.to_string(), source_id: source_id.to_string(), username, properties })
}

/// The signed-in account, from any page's header: the user menu shows the
/// name (`span.menu_right.username`) and links the account's own profile
/// (`a.user_menu_links` to `/profile/<id>/<slug>/`). None when the page
/// was served signed out (the menu is absent).
pub fn parse_signed_in_user(html: &str) -> Option<crate::source::SessionIdentity> {
    let doc = Html::parse_document(html);
    let root = doc.root_element();
    let id = root.select(&sel("a.user_menu_links")).find_map(|a| {
        let href = attr(&a, "href")?;
        let rest = href.split("/profile/").nth(1)?;
        let id = rest.split('/').next()?;
        (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then(|| id.to_string())
    })?;
    let username = first_text(&root, "span.menu_right.username").filter(|n| !n.is_empty())?;
    Some(crate::source::SessionIdentity { external_id: id, username })
}

/// The site's comment form as a page carries it for a signed-in reader:
/// the review form on a series page, the comment form on a chapter page.
/// It is the site's stock WordPress form, posted as it stands — every
/// field the page put in it rides along, so a field the site adds later
/// is sent without this code knowing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommentForm {
    /// Where the form posts (absolute).
    pub action: String,
    /// The form's fields in page order: (name, value, the input's id).
    pub fields: Vec<(String, String, String)>,
}

impl CommentForm {
    /// Set the field named `name`, adding it when the form has none.
    pub fn set(&mut self, name: &str, value: &str) {
        match self.fields.iter_mut().find(|f| f.0 == name) {
            Some(field) => field.1 = value.to_string(),
            None => self.fields.push((name.to_string(), value.to_string(), String::new())),
        }
    }

    /// Set a field the page names by element id; nothing when absent.
    pub fn set_by_id(&mut self, id: &str, value: &str) {
        if let Some(field) = self.fields.iter_mut().find(|f| f.2 == id) {
            field.1 = value.to_string();
        }
    }

    pub fn pairs(&self) -> Vec<(String, String)> {
        self.fields.iter().map(|(name, value, _)| (name.clone(), value.clone())).collect()
    }
}

/// The form holding the `comment` text area, with its hidden and text
/// inputs as the page filled them and its submit button. None when the
/// page offers no form to write in — a signed-out reader gets a "Login to
/// Post Comment" link and a disabled text area instead.
pub fn parse_comment_form(html: &str, page_url: &str) -> Option<CommentForm> {
    let doc = Html::parse_document(html);
    let form = doc.select(&sel("form")).find(|form| {
        form.select(&sel("textarea[name='comment']")).any(|t| t.value().attr("disabled").is_none())
    })?;
    let action = attr(&form, "action")?;
    let action = page_url.parse::<url::Url>().ok()
        .and_then(|base| base.join(action).ok())
        .map(|u| u.to_string())
        .unwrap_or_else(|| action.to_string());
    let mut fields: Vec<(String, String, String)> = Vec::new();
    for input in form.select(&sel("input[name]")) {
        let kind = input.value().attr("type").unwrap_or("text").to_ascii_lowercase();
        let checked = input.value().attr("checked").is_some();
        let sent = match kind.as_str() {
            "hidden" | "text" | "email" | "url" | "number" => true,
            "checkbox" | "radio" => checked,
            _ => false, // submit buttons are added below; files, buttons never
        };
        if !sent { continue }
        let Some(name) = attr(&input, "name") else { continue };
        fields.push((name.to_string(), input.value().attr("value").unwrap_or("").to_string(),
                     input.value().attr("id").unwrap_or("").to_string()));
    }
    // The button a reader presses is part of what a browser sends.
    let submit = form.select(&sel("button[type='submit'][name], input[type='submit'][name]")).next();
    if let Some(button) = submit {
        if let Some(name) = attr(&button, "name") {
            fields.push((name.to_string(), button.value().attr("value").unwrap_or("").to_string(), String::new()));
        }
    }
    Some(CommentForm { action, fields })
}

/// The reason on the error page WordPress answers a refused comment with
/// ("Duplicate comment detected…", "You are posting comments too
/// quickly…"). None when the page is not that error page.
pub fn parse_post_refusal(html: &str) -> Option<String> {
    let doc = Html::parse_document(html);
    let root = doc.root_element();
    first_text(&root, ".wp-die-message")
        .or_else(|| first_text(&root, "body#error-page p"))
        .map(|message| message.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|message| !message.is_empty())
}

/// The new comment's id in the address the site sends the reader to
/// after a post: `…#comment-N`, or `…?tab=review&cid=N` for a review.
pub fn posted_comment_id(final_url: &str) -> Option<u64> {
    let digits = |rest: &str| -> Option<u64> {
        let n: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        n.parse().ok()
    };
    final_url.split("#comment-").nth(1).and_then(digits)
        .or_else(|| final_url.split("cid=").nth(1).and_then(digits))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // Hand-authored on the site's form markup; ids, names and text invented.
    const REVIEW_FORM: &str = r#"<html><body><div id="respond" class="comment-respond">
        <form action="/wp-comments-post.php" method="post" id="commentform" class="commentform" novalidate>
          <div class="comment-form-title"><input id="cur_chp" name="cur_chp" type="text" value="Chapter 3: Low Tide"/></div>
          <textarea id="comment" name="comment" cols="40" rows="200"></textarea>
          <div class="form-submit chapter">
            <button name="submit" type="submit" id="submit_review" class="btnrev review" value="Post">Submit</button>
            <input type='hidden' name='comment_post_ID' value='700412' id='comment_post_ID' />
            <input type='hidden' name='comment_parent' id='comment_parent' value='0' />
            <input type='hidden' name='quote' id='mycidrpy' value='' />
          </div>
        </form></div></body></html>"#;

    const SIGNED_OUT_FORM: &str = r#"<html><body><div id="respond" class="comment-respond">
        <div class="cant_cmt_chapter">
          <textarea class="login_to_reply_text" name="comment" id="comment" disabled></textarea>
          <a href="https://www.scribblehub.com/wp-login.php" id="submit_chapter">Login to Post Comment</a>
        </div></div></body></html>"#;

    #[test]
    fn the_comment_form_is_read_as_the_page_filled_it() {
        let mut form = parse_comment_form(REVIEW_FORM, "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/").unwrap();
        assert_eq!(form.action, "https://www.scribblehub.com/wp-comments-post.php");
        let field = |form: &CommentForm, name: &str| form.fields.iter().find(|f| f.0 == name).map(|f| f.1.clone());
        assert_eq!(field(&form, "cur_chp").as_deref(), Some("Chapter 3: Low Tide"), "the site's own reading status rides along");
        assert_eq!(field(&form, "comment_post_ID").as_deref(), Some("700412"));
        assert_eq!(field(&form, "comment_parent").as_deref(), Some("0"));
        assert_eq!(field(&form, "submit").as_deref(), Some("Post"));
        assert_eq!(field(&form, "comment"), None, "the text area is filled by the caller");
        form.set("comment", "A fine story.");
        form.set("comment_parent", "2300999");
        form.set_by_id("mycidrpy", "2300999");
        form.set_by_id("nothing_here", "x");
        assert_eq!(field(&form, "comment").as_deref(), Some("A fine story."));
        assert_eq!(field(&form, "comment_parent").as_deref(), Some("2300999"));
        assert_eq!(field(&form, "quote").as_deref(), Some("2300999"));
        assert_eq!(form.pairs().len(), form.fields.len());
    }

    #[test]
    fn a_signed_out_page_offers_no_form() {
        assert_eq!(parse_comment_form(SIGNED_OUT_FORM, "https://www.scribblehub.com/read/700412-x/chapter/2300107/"), None);
    }

    #[test]
    fn a_refused_post_carries_the_sites_reason_and_an_accepted_one_its_id() {
        let die = r#"<html><body id="error-page"><div class="wp-die-message"><p>Duplicate comment detected;
            it looks as though you&#8217;ve already said that!</p></div></body></html>"#;
        assert_eq!(parse_post_refusal(die).as_deref(),
                   Some("Duplicate comment detected; it looks as though you\u{2019}ve already said that!"));
        let older = r#"<html><body id="error-page"><p>You are posting comments too quickly. Slow down.</p></body></html>"#;
        assert_eq!(parse_post_refusal(older).as_deref(), Some("You are posting comments too quickly. Slow down."));
        assert_eq!(parse_post_refusal(REVIEW_FORM), None);
        assert_eq!(posted_comment_id("https://www.scribblehub.com/read/700412-x/chapter/2300107/#comment-2301555"), Some(2301555));
        assert_eq!(posted_comment_id("https://www.scribblehub.com/series/700412/x/?tab=review&cid=2301556"), Some(2301556));
        assert_eq!(posted_comment_id("https://www.scribblehub.com/series/700412/x/"), None);
    }

    fn series() -> SeriesPage {
        let html = fs::read_to_string("tests/fixtures/scribblehub_series.html").unwrap();
        parse_series_page(&html, "700412").unwrap()
    }

    #[test]
    fn signed_in_user_from_the_header_menu() {
        let signed_in = r#"<html><body><div class="header">
            <span id="menu_right_item" class="menu_right username_main">
              <span id="menu_right_item" class="menu_right username">quillfeather</span></span>
            <div class="lo_main loggedin"><div class="lo_box">
              <span><a class="user_menu_links" href="/account/">Account</a></span>
              <span><a class="user_menu_links" href="/profile/70412/quillfeather/">Your Profile Page</a></span>
              <span><a class="user_menu_links" href="https://www.scribblehub.com/logout/">Log Out</a></span>
            </div></div></div></body></html>"#;
        let who = parse_signed_in_user(signed_in).unwrap();
        assert_eq!((who.external_id.as_str(), who.username.as_str()), ("70412", "quillfeather"));
        let signed_out = r#"<html><body><a href="https://www.scribblehub.com/login/">Login</a></body></html>"#;
        assert_eq!(parse_signed_in_user(signed_out), None);
    }

    #[test]
    fn series_page_record() {
        let page = series();
        let s = &page.summary;
        assert_eq!(s.source, SOURCE_ID);
        assert_eq!(s.external_id, "700412");
        assert_eq!(s.url, "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/");
        assert_eq!(s.title, "The Lighthouse Ledger");
        assert_eq!(s.authors, vec!["quill_and_tide"]);
        assert!(s.summary.starts_with("Wren takes the night shift"));
        assert!(s.summary.contains("Every entry is dated tomorrow."));
        assert_eq!(s.tags, vec!["Fantasy", "Mystery", "Slice of Life", "Lighthouses", "Small Town", "Found Family"]);
        assert_eq!(s.fandoms, vec!["Original Work"]);
        assert_eq!(s.rating, Rating::NotRated);
        assert_eq!(s.chapter_count, 5);
        assert!(!s.complete);
        assert_eq!(s.total_chapters, None);
        assert_eq!(s.date_updated, "2026-10-26");
        assert_eq!(s.word_count, None);
        assert!(s.kudos.is_none() && s.hits.is_none());
        assert_eq!(page.status, "Ongoing");
        assert_eq!(page.content_warnings, vec!["Strong Language"]);
    }

    #[test]
    fn series_page_stats() {
        let page = series();
        assert_eq!(page.rating_avg, Some(4.4));
        assert_eq!(page.rating_count, Some(18));
        assert_eq!(page.views, Some(12_400));
        assert_eq!(page.favorites, Some(231));
        assert_eq!(page.readers, Some(64));
        assert_eq!(page.chapter_total, Some(5));
    }

    #[test]
    fn series_page_toc_and_pager() {
        let page = series();
        assert_eq!(page.toc_pages, 2);
        assert_eq!(page.toc.len(), 3);
        assert_eq!(page.toc[0], TocEntry { chapter_id: 2300115, number: 5, title: "Chapter 5: Tomorrow's Entry".into(), date: "2026-10-26".into() });
        assert_eq!(page.toc[2].chapter_id, 2300107);
        assert_eq!(page.toc[2].number, 3);
        let more = parse_toc_fragment(&fs::read_to_string("tests/fixtures/scribblehub_toc_page.html").unwrap());
        assert_eq!(more.len(), 2);
        assert_eq!(more[1], TocEntry { chapter_id: 2300101, number: 1, title: "Chapter 1: The Posting".into(), date: "2026-09-28".into() });
    }

    #[test]
    fn series_page_reviews() {
        let page = series();
        assert_eq!(page.review_pages, 1);
        assert_eq!(page.reviews.len(), 2);
        let r = &page.reviews[0];
        assert_eq!(r.id, 880001);
        assert_eq!(r.rating, Some(5));
        assert_eq!(r.author.username, "harbourmoth");
        assert_eq!(r.author.id, "61001", "a commenter with a profile keys like an author");
        assert_eq!(r.author.profile_url.as_deref(), Some("https://www.scribblehub.com/profile/61001/harbourmoth/"));
        assert_eq!(r.posted_at, "Oct 20, 2026");
        assert_eq!(r.chapter_label.as_deref(), Some("chapter 4: the keeper before"));
        assert_eq!(r.content.len(), 2);
        assert!(r.replies.is_empty());
        let r2 = &page.reviews[1];
        assert_eq!(r2.rating, Some(3));
        assert_eq!(r2.content.len(), 1, "the Read More toggle is not content");
    }

    #[test]
    fn chapter_page_text_note_and_neighbours() {
        let html = fs::read_to_string("tests/fixtures/scribblehub_chapter.html").unwrap();
        let page = parse_chapter_page(&html, 2300107).unwrap();
        assert_eq!(page.title, "Chapter 3: Salt and Signal");
        assert_eq!(page.prev_chapter_id, Some(2300104));
        assert_eq!(page.next_chapter_id, Some(2300110));
        assert_eq!(page.notes_after.as_deref(), Some("Shorter one this week. Chapter 4 is the long one."));
        let text = plain_text_of(&page.content);
        assert!(text.starts_with("The fog came in sideways"));
        assert!(text.contains("Author's note:"));
        assert!(!text.contains("quill_and_tide"), "the note's byline is chrome, not text");
        // The relative in-text link resolved against the page.
        let has_abs_link = page.content.iter().any(|b| matches!(b, ContentBlock::Paragraph { text }
            if text.iter().any(|i| matches!(i, crate::models::InlineContent::Link { href, .. }
                if href == "https://www.scribblehub.com/read/700412-the-lighthouse-ledger/chapter/2300101/"))));
        assert!(has_abs_link);
    }

    #[test]
    fn chapter_page_comments_threaded() {
        let html = fs::read_to_string("tests/fixtures/scribblehub_chapter.html").unwrap();
        let page = parse_chapter_page(&html, 2300107).unwrap();
        assert_eq!(page.comment_pages, 1);
        assert_eq!(page.comments.len(), 2);
        let top = &page.comments[0];
        assert_eq!(top.id, 990101);
        assert_eq!(top.author.username, "quietfathom");
        assert_eq!(top.posted_at, "Oct 13, 2026 01:16 AM");
        assert_eq!(top.chapter_id, Some(2300107));
        assert!(top.rating.is_none());
        assert_eq!(plain_text_of(&top.content), "Sideways fog :Blob_Astonished: the logbook knows.");
        assert_eq!(top.replies.len(), 1);
        assert_eq!(top.replies[0].id, 990103);
        assert_eq!(top.replies[0].author.username, "quill_and_tide");
        assert_eq!(page.comments[1].id, 990102);
        assert!(page.comments[1].replies.is_empty());
    }

    fn fixture(name: &str) -> String {
        fs::read_to_string(format!("tests/fixtures/{name}")).unwrap()
    }

    #[test]
    fn series_page_names_its_author_as_a_user() {
        let page = parse_series_page(&fixture("scribblehub_series.html"), "700412").unwrap();
        let author = page.author.expect("author link");
        assert_eq!(author.id, "51230");
        assert_eq!(author.username, "quill_and_tide");
        assert_eq!(author.profile_url.as_deref(), Some("https://www.scribblehub.com/profile/51230/quill_and_tide/"));
    }

    #[test]
    fn profile_series_listing() {
        let page = parse_profile_series(&fixture("scribblehub_profile_series.html"));
        assert_eq!(page.total_pages, 2);
        assert_eq!(page.works.len(), 2);
        let first = &page.works[0];
        assert_eq!(first.summary.external_id, "700412");
        assert_eq!(first.summary.url, "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/");
        assert_eq!(first.summary.title, "The Lighthouse Ledger");
        assert_eq!(first.summary.authors, vec!["quill_and_tide".to_string()]);
        assert_eq!(first.summary.word_count, Some(23_400));
        assert_eq!(first.summary.chapter_count, 5);
        assert_eq!(first.summary.total_chapters, None);
        assert_eq!(first.summary.date_updated, "2026-10-26");
        assert_eq!(first.summary.tags, vec!["Fantasy", "Mystery", "Slice of Life"]);
        assert!(first.summary.summary.starts_with("A relief keeper takes the winter post"), "{}", first.summary.summary);
        assert!(first.summary.summary.ends_with("do not agree."), "{}", first.summary.summary);
        assert!(!first.summary.summary.contains("more>>") && !first.summary.summary.contains("<<less"));
        assert_eq!(first.authors[0].id, "51230");
        let keys: Vec<&str> = first.stats.iter().map(|s| s.key.as_str()).collect();
        assert_eq!(keys, ["rating", "views", "favorites", "readers", "reviews", "release_rate"]);
        assert_eq!(first.stats[0].num, Some(4.4));
        assert_eq!(first.stats[1].num, Some(12_400.0));
        let second = &page.works[1];
        assert!(second.summary.complete);
        assert_eq!(second.summary.total_chapters, Some(1));
        assert_eq!(second.summary.word_count, Some(1_870));
        assert_eq!(second.summary.rating, Rating::Mature);
        assert_eq!(second.summary.tags, vec!["Fantasy", "Mature"]);
        assert!(second.stats.iter().any(|s| s.key == "status" && s.text.as_deref() == Some("Completed")));
        assert_eq!(second.summary.summary, "One night on the harbour wall, before the ledger.");
    }

    #[test]
    fn user_search_results() {
        let hits = parse_user_search(&fixture("scribblehub_user_search.html"));
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].source, "scribblehub");
        assert_eq!(hits[0].id, "51230");
        assert_eq!(hits[0].username, "quill");
        assert_eq!(hits[0].profile_url.as_deref(), Some("https://www.scribblehub.com/profile/51230/quill/"));
        assert_eq!(hits[0].avatar_url.as_deref(), Some("https://cdn.scribblehub.com/default/avatarnew.png"));
        // Highlight marks split the name across text nodes.
        assert_eq!(hits[1].username, "Quillon Reads");
        assert_eq!(hits[2].username, "inkquill");
        assert_eq!(hits[2].avatar_url.as_deref(), Some("https://cdn.scribblehub.com/avatar/l/1/ava_51232_1700000001.jpg"));
        assert!(parse_user_search("0").is_empty());
    }

    #[test]
    fn profile_page_record() {
        let p = parse_profile_page(&fixture("scribblehub_profile.html"), "51230").unwrap();
        assert_eq!(p.source, "scribblehub");
        assert_eq!(p.source_id, "51230");
        assert_eq!(p.username, "quill_and_tide");
        assert_eq!(p.property("profile_url"), Some("https://www.scribblehub.com/profile/51230/quill_and_tide/"));
        assert_eq!(p.property("avatar"), Some("https://cdn.scribblehub.com/avatar/l/1/ava_51230_1700000000.jpg"));
        assert_eq!(p.property("joined"), Some("2024-03-03"));
        assert_eq!(p.property("location"), Some("A small harbour town"));
        assert_eq!(p.property("birthday"), None);
        assert_eq!(p.property("series"), Some("3"));
        assert_eq!(p.property("followers"), Some("48"));
        assert_eq!(p.property("total_words"), Some("61204"));
        assert_eq!(p.property("last_active"), Some("2 hours ago"));
        let bio: Vec<ContentBlock> = serde_json::from_str(p.property("about").unwrap()).unwrap();
        let text = plain_text_of(&bio);
        assert!(text.starts_with("I write about lighthouses") && text.ends_with("Updates on Sundays."), "{text}");
        // Every name the parser emits is in the source's vocabulary or an
        // acknowledged extra (gender, homepage).
        for (name, _) in &p.properties {
            assert!(crate::user_fields::field_of("scribblehub", name).is_some() || matches!(name.as_str(), "gender" | "homepage"), "{name}");
        }
    }

    #[test]
    fn stats_page_details_table() {
        let html = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/scribblehub_stats.html")).unwrap();
        let stats = parse_stats_page(&html);
        assert_eq!(stats.word_count, Some(23_410));
        assert_eq!(stats.views, Some(12_418));
        assert_eq!(stats.average_words, Some(4_682));
        assert_eq!(parse_stats_page("<html><body>nothing</body></html>"), StatsPage::default());
    }

    #[test]
    fn helpers() {
        assert_eq!(parse_abbreviated("319.6k"), Some(319_600));
        assert_eq!(parse_abbreviated("4159"), Some(4159));
        assert_eq!(parse_abbreviated("1.2m"), Some(1_200_000));
        assert_eq!(normalize_date("Jul 26, 2026 09:14 PM"), "2026-07-26");
        assert_eq!(normalize_date("Apr 5, 2025"), "2025-04-05");
        assert_eq!(id_after("https://www.scribblehub.com/profile/169/name/", "/profile/"), Some(169));
        assert_eq!(pagination_items("x", "pagination-mesh"), 1);
    }
}

