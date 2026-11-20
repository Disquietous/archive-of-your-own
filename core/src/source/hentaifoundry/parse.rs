//! Hentai Foundry page parsers. The site lists a story the same way
//! everywhere — one `div.storyRow` block — on search results, an author's
//! story list, a category list and at the head of the story's own page,
//! so one row parser serves them all. Markup and field mapping:
//! design/hentaifoundry-adapter-plan.md. Fixtures are hand-authored on
//! the site's markup with invented stories and authors.

use scraper::{ElementRef, Html, Selector};

use crate::models::{AO3User, Chapter, ContentBlock, Rating, SourceUserProfile, WorkSummary};
use crate::parser::html_to_blocks;
use crate::source::{ListedWork, ListingPage, SessionIdentity, SourceStat};

use super::{BASE_URL, SOURCE_ID};

fn sel(s: &str) -> Selector {
    Selector::parse(s).expect("static selector")
}

fn text(el: &ElementRef) -> String {
    el.text().collect::<Vec<_>>().join("").split_whitespace().collect::<Vec<_>>().join(" ")
}

fn attr<'a>(el: &ElementRef<'a>, name: &str) -> Option<&'a str> {
    el.value().attr(name).map(str::trim).filter(|v| !v.is_empty())
}

/// A site link as a full URL (`/x` and the protocol-relative `//host/x`
/// the site uses for its image hosts).
fn absolute(href: &str) -> String {
    if let Some(rest) = href.strip_prefix("//") { format!("https://{rest}") }
    else if href.starts_with('/') { format!("{BASE_URL}{href}") }
    else { href.to_string() }
}

/// "March 3, 2021" → "2021-03-03". Anything else comes back trimmed.
pub(super) fn normalize_date(raw: &str) -> String {
    let parts: Vec<&str> = raw.split_whitespace().collect();
    if parts.len() < 3 { return raw.trim().to_string() }
    let month = match parts[0].to_ascii_lowercase().get(..3) {
        Some("jan") => 1, Some("feb") => 2, Some("mar") => 3, Some("apr") => 4, Some("may") => 5, Some("jun") => 6,
        Some("jul") => 7, Some("aug") => 8, Some("sep") => 9, Some("oct") => 10, Some("nov") => 11, Some("dec") => 12,
        _ => return raw.trim().to_string(),
    };
    let (Ok(day), Ok(year)) = (parts[1].trim_end_matches(',').parse::<u32>(), parts[2].parse::<u32>()) else {
        return raw.trim().to_string();
    };
    format!("{year:04}-{month:02}-{day:02}")
}

/// "118,432" → 118432.
fn number(raw: &str) -> Option<u64> {
    let digits: String = raw.chars().filter(|c| *c != ',' && !c.is_whitespace()).collect();
    if digits.is_empty() { None } else { digits.parse().ok() }
}

// ---------------------------------------------------------------------------
// Page kinds and session
// ---------------------------------------------------------------------------

/// The landing page a new session gets in place of any page: "You must be
/// 18 or older to enter this site", with an Enter link back to the page
/// asked for.
pub fn is_age_page(html: &str) -> bool {
    html.contains("frontPage_link") && html.contains("enterAgree=1")
}

/// The signed-in account, from any page's header ("Welcome, {name}
/// (Logout)"). None when the page was served signed out. The username is
/// the account's key at the site.
pub fn signed_in_user(html: &str) -> Option<SessionIdentity> {
    let doc = Html::parse_document(html);
    let welcome = doc.select(&sel("#headerWelcome")).next()?;
    welcome.select(&sel("a[href='/site/logout']")).next()?;
    let username = welcome.select(&sel("a[href]")).find_map(|a| {
        let name = attr(&a, "href")?.strip_prefix("/user/")?.strip_suffix("/profile")?;
        (!name.is_empty() && !name.contains('/')).then(|| name.to_string())
    })?;
    Some(SessionIdentity { external_id: username.clone(), username })
}

/// The username lookup's answer: a JSON list of names, or `null` when
/// nothing matches.
pub fn parse_usernames(body: &str) -> Result<Vec<String>, crate::error::AppError> {
    serde_json::from_str::<Option<Vec<String>>>(body.trim())
        .map(|names| names.unwrap_or_default().into_iter().filter(|n| !n.is_empty()).collect())
        .map_err(|_| crate::error::AppError::ParseError("Hentai Foundry's username lookup did not answer with a list of names".to_string()))
}

/// The token every form on the page carries; a POST must send it back.
pub fn csrf_token(html: &str) -> Option<String> {
    let doc = Html::parse_document(html);
    let token = doc.select(&sel("input[name='YII_CSRF_TOKEN']")).next().and_then(|i| attr(&i, "value").map(str::to_string));
    token
}

// ---------------------------------------------------------------------------
// Story rows
// ---------------------------------------------------------------------------

/// `/stories/user/{user}/{id}/{slug}…` → (user, id, slug, rest after the slug).
pub(super) fn story_path(path: &str) -> Option<(&str, &str, &str, &str)> {
    let rest = path.strip_prefix("/stories/user/")?;
    let mut parts = rest.splitn(4, '/');
    let (user, id) = (parts.next()?, parts.next()?);
    if user.is_empty() || id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) { return None }
    let slug = parts.next().unwrap_or("");
    Some((user, id, slug, parts.next().unwrap_or("")))
}

/// The value written after a `span.label` in the row's figures column:
/// the loose text up to the next element.
fn value_after(label: &ElementRef) -> String {
    let mut out = String::new();
    for node in label.next_siblings() {
        if let Some(t) = node.value().as_text() { out.push_str(t); }
        else if !out.trim().is_empty() { break }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The row's blurb: the loose text of the description cell before its
/// "Read this story" block, line breaks kept.
fn blurb(cell: &ElementRef) -> String {
    let mut out = String::new();
    for node in cell.children() {
        if let Some(t) = node.value().as_text() {
            out.push_str(&t.split_whitespace().collect::<Vec<_>>().join(" "));
        } else if let Some(el) = ElementRef::wrap(node) {
            match el.value().name() {
                "br" => out.push('\n'),
                "div" => break,
                _ => out.push_str(&text(&el)),
            }
        }
    }
    let lines: Vec<&str> = out.lines().map(str::trim).collect();
    let mut kept: Vec<&str> = Vec::new();
    for line in lines {
        if line.is_empty() && kept.last().is_none_or(|l| l.is_empty()) { continue }
        kept.push(line);
    }
    kept.join("\n").trim().to_string()
}

/// The site's short names for its content marks, by the symbol each
/// carries in a row (the filter form's own labels).
const MARKS: &[(&str, &str, bool)] = &[
    // (symbol, name, graded 1–3)
    ("N", "Nudity", true), ("V", "Violence", true), ("L", "Profanity", true), ("R", "Racism", true),
    ("Sx", "Sexual Content", true), ("Sp", "Spoilers", true),
    ("♂♂", "Yaoi", false), ("♀♀", "Yuri", false), ("T", "Teen", false), ("G", "Guro", false),
    ("F", "Furry", false), ("B", "Beast", false), ("♂", "Male", false), ("♀", "Female", false),
    ("Tg", "Futa", false), ("!?", "Other", false), ("💩", "Scat", false), ("I", "Incest", false),
    ("Nc", "Rape", false), ("♂!", "Male Only", false), ("♀!", "Female Only", false),
];

/// One content mark of a row: its name and, for a graded one, its level.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Mark {
    name: String,
    level: Option<u8>,
}

fn marks_of(row: &ElementRef) -> Vec<Mark> {
    row.select(&sel(".ratings_box span.rating")).filter_map(|span| {
        let symbol = text(&span);
        let level = attr(&span, "class").and_then(|c| c.split_whitespace()
            .find_map(|w| w.strip_prefix("lvl").and_then(|n| n.parse::<u8>().ok())));
        match MARKS.iter().find(|(s, _, _)| *s == symbol) {
            Some((_, name, graded)) => Some(Mark { name: name.to_string(), level: if *graded { level } else { None } }),
            // A mark the table does not know keeps the site's own words.
            None => attr(&span, "title").map(|t| Mark { name: t.to_string(), level: None }),
        }
    }).collect()
}

fn rating_of(marks: &[Mark]) -> Rating {
    let level = |name: &str| marks.iter().find(|m| m.name == name).and_then(|m| m.level).unwrap_or(0);
    match level("Sexual Content") {
        3 => Rating::Explicit,
        2 => Rating::Mature,
        1 => Rating::Teen,
        _ if level("Violence") >= 3 || level("Nudity") >= 3 => Rating::Mature,
        _ => Rating::General,
    }
}

fn mark_tag(mark: &Mark) -> String {
    match mark.level {
        Some(1) => format!("Mild {}", mark.name),
        Some(2) => format!("Moderate {}", mark.name),
        Some(3) => format!("Explicit {}", mark.name),
        _ => mark.name.clone(),
    }
}

/// Category roots whose children are the works a story is based on.
const FANDOM_ROOTS: &[&str] = &["Anime & Manga", "Games", "Cartoons"];

fn parse_row(row: &ElementRef) -> Option<ListedWork> {
    let link = row.select(&sel(".titlebar a[href]"))
        .find(|a| attr(a, "href").is_some_and(|h| story_path(h).is_some()))?;
    let href = attr(&link, "href")?;
    let (user, id, slug, _) = story_path(href)?;
    let title = text(&link);
    if title.is_empty() { return None }
    let url = super::HentaiFoundrySource::story_url(user, id, slug);

    let author_link = row.select(&sel(".col1 a[href]")).next();
    let author_name = author_link.as_ref().map(text).filter(|n| !n.is_empty()).unwrap_or_else(|| user.to_string());
    let avatar = row.select(&sel(".col1 img[src]")).next().and_then(|i| attr(&i, "src").map(absolute));
    let author = AO3User {
        source: SOURCE_ID.to_string(), id: user.to_string(), username: author_name.clone(),
        profile_url: Some(super::HentaiFoundrySource::profile_url(user)), avatar_url: avatar,
    };

    let mut figures: Vec<(String, String)> = Vec::new();
    for label in row.select(&sel(".col2 span.label, .col3 span.label")) {
        let name = text(&label).trim_end_matches([':', '.']).to_ascii_lowercase();
        // Dates and status sit in the next `span.indent`; the figures are
        // loose text after their label.
        let boxed = label.next_siblings().filter_map(ElementRef::wrap)
            .find(|e| e.value().name() == "span")
            .filter(|e| e.value().has_class("indent", scraper::CaseSensitivity::AsciiCaseInsensitive))
            .map(|e| text(&e));
        let value = match boxed { Some(v) => v, None => value_after(&label) };
        if !name.is_empty() && !value.is_empty() { figures.push((name, value)); }
    }
    let figure = |name: &str| figures.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str());
    let count = |name: &str| figure(name).and_then(number);

    let status = figure("status").unwrap_or("").to_string();
    let complete = status.eq_ignore_ascii_case("Complete");
    let chapter_count = count("chapters").unwrap_or(0) as u32;

    let crumbs: Vec<String> = row.select(&sel(".categoryBreadcrumbs a")).map(|a| text(&a)).filter(|c| !c.is_empty()).collect();
    let marks = marks_of(row);
    let (fandoms, category_tags): (Vec<String>, Vec<String>) = match crumbs.split_first() {
        Some((root, rest)) if root == "Original" => (vec!["Original Work".to_string()], rest.to_vec()),
        Some((root, rest)) if FANDOM_ROOTS.contains(&root.as_str()) => match rest.split_first() {
            Some((fandom, deeper)) => (vec![fandom.clone()], deeper.to_vec()),
            None => (Vec::new(), Vec::new()),
        },
        Some((_, rest)) => (Vec::new(), rest.to_vec()),
        None => (Vec::new(), Vec::new()),
    };
    let mut tags = category_tags;
    for tag in marks.iter().map(mark_tag) {
        if !tags.contains(&tag) { tags.push(tag); }
    }

    let summary = WorkSummary {
        id: 0,
        source: SOURCE_ID.to_string(),
        external_id: id.to_string(),
        url,
        title,
        authors: vec![author_name],
        author_ids: Vec::new(),
        fandoms,
        rating: rating_of(&marks),
        warnings: Vec::new(),
        categories: Vec::new(),
        relationships: Vec::new(),
        characters: Vec::new(),
        tags,
        summary: row.select(&sel(".storyDescript")).next().map(|c| blurb(&c)).unwrap_or_default(),
        word_count: count("words"),
        chapter_count,
        total_chapters: if complete { Some(chapter_count) } else { None },
        kudos: None,
        hits: None,
        bookmarks: None,
        comments: count("comments").map(|n| n as u32),
        date_published: figure("submitted").map(normalize_date).unwrap_or_default(),
        date_updated: figure("updated").map(normalize_date).unwrap_or_default(),
        language: "English".to_string(),
        complete,
        status: status.clone(),
        series: Vec::new(),
        fetched_at: String::new(),
    };
    let mut stats = Vec::new();
    if let Some(n) = count("views") { stats.push(SourceStat::num("views", "Views", n as f64, 1)); }
    if let Some(n) = count("faves") { stats.push(SourceStat::num("favorites", "Faves", n as f64, 2)); }
    // The site's "Rating" is a vote score (thumbs up less thumbs down),
    // not a grade, and can be negative.
    if let Some(n) = figure("rating").and_then(|v| v.replace(',', "").parse::<f64>().ok()) {
        stats.push(SourceStat::num("votes", "Votes", n, 3));
    }
    if !status.is_empty() {
        stats.push(SourceStat { key: "status".into(), label: "Status".into(), num: None, text: Some(status), order: 4 });
    }
    if let Some(size) = figure("size") {
        stats.push(SourceStat { key: "size".into(), label: "Size".into(), num: None, text: Some(size.to_string()), order: 5 });
    }
    Some(ListedWork { summary, stats, authors: vec![author] })
}

/// Any page that lists stories: search results, an author's stories, a
/// category. "Displaying 1-25 of 57 results." gives the total; the pager
/// (`ul.yiiPager`) the page count, in either of the site's two page
/// forms (`…/page/3`, `…?page=3`).
pub fn parse_listing(html: &str) -> ListingPage {
    let doc = Html::parse_document(html);
    let works: Vec<ListedWork> = doc.select(&sel("div.storyRow")).filter_map(|row| parse_row(&row)).collect();
    let total_works = doc.select(&sel(".galleryHeader .summary, div.summary")).next().and_then(|s| {
        let t = text(&s);
        let after = t.split(" of ").nth(1)?;
        number(after.split_whitespace().next()?).map(|n| n as u32)
    });
    let page_of = |href: &str| -> Option<u32> {
        let tail = href.split("/page/").nth(1)
            .or_else(|| href.split("page=").nth(1))?;
        tail.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().ok()
    };
    let total_pages = doc.select(&sel("ul.yiiPager li a[href]"))
        .filter_map(|a| attr(&a, "href").and_then(page_of))
        .max().unwrap_or(1).max(1);
    let has_next = doc.select(&sel("ul.yiiPager li.next")).next()
        .is_some_and(|li| !li.value().has_class("hidden", scraper::CaseSensitivity::AsciiCaseInsensitive));
    ListingPage { works, has_next, total_pages, total_works }
}

// ---------------------------------------------------------------------------
// Story and chapter pages
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChapterEntry {
    /// The site's chapter id.
    pub id: u64,
    /// 1-based position in the list (the site's own labels start at 0 or
    /// 1 as the author chose).
    pub number: u32,
    pub title: String,
    pub updated: String,
}

#[derive(Debug, Clone)]
pub struct StoryPage {
    pub work: ListedWork,
    pub chapters: Vec<ChapterEntry>,
}

/// A story's own page: its row, then the "Chapters" box — one link per
/// chapter with its dates and figures.
pub fn parse_story_page(html: &str, external_id: &str) -> Result<StoryPage, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let work = doc.select(&sel("div.storyRow")).find_map(|row| parse_row(&row))
        .filter(|w| w.summary.external_id == external_id)
        .ok_or_else(|| crate::error::AppError::ParseError(format!("Hentai Foundry page is not story {external_id}")))?;
    let mut chapters = Vec::new();
    for p in doc.select(&sel("section.box .boxbody p")) {
        let Some(link) = p.select(&sel("a[href]")).next() else { continue };
        let Some((_, id, _, rest)) = attr(&link, "href").and_then(story_path) else { continue };
        if id != external_id { continue }
        let Some(chapter_id) = rest.split('/').next().and_then(|c| c.parse::<u64>().ok()) else { continue };
        let details = p.select(&sel("small")).next().map(|s| text(&s)).unwrap_or_default();
        let updated = details.split("Updated:").nth(1)
            .map(|t| t.split(['•', '\u{2022}']).next().unwrap_or("").split("Word count").next().unwrap_or("").trim().to_string())
            .map(|d| normalize_date(&d)).unwrap_or_default();
        chapters.push(ChapterEntry { id: chapter_id, number: chapters.len() as u32 + 1, title: text(&link), updated });
    }
    Ok(StoryPage { work, chapters })
}

pub fn stub_chapter(entry: &ChapterEntry) -> Chapter {
    Chapter {
        id: Some(entry.id),
        title: Some(entry.title.clone()),
        number: entry.number,
        content: Vec::new(),
        notes_before: None,
        notes_after: None,
    }
}

#[derive(Debug, Clone)]
pub struct ChapterPage {
    pub title: String,
    pub content: Vec<ContentBlock>,
}

/// The site stores a chapter as text with line breaks: a blank line
/// between paragraphs (often holding a lone non-breaking space), a single
/// break inside one. That becomes paragraphs here, so the reader spaces
/// it like any other chapter.
fn paragraphs(html: &str) -> String {
    fn is_break(s: &str) -> bool {
        s.as_bytes().get(..3).is_some_and(|b| b.eq_ignore_ascii_case(b"<br"))
    }
    fn blank(piece: &str) -> bool {
        piece.replace("&nbsp;", " ").trim().is_empty()
    }
    let mut out = String::new();
    let mut current = String::new();
    let flush = |current: &mut String, out: &mut String| {
        let body = current.trim();
        if !body.is_empty() { out.push_str("<p>"); out.push_str(body); out.push_str("</p>"); }
        current.clear();
    };
    let mut rest = html;
    let mut breaks = 0;
    while !rest.is_empty() {
        if is_break(rest) {
            let end = rest.find('>').map(|i| i + 1).unwrap_or(rest.len());
            breaks += 1;
            rest = &rest[end..];
            continue;
        }
        // Up to the next break ('<' is one byte, so every index is a char boundary).
        let next = rest.match_indices('<').map(|(i, _)| i).find(|i| is_break(&rest[*i..])).unwrap_or(rest.len());
        let piece = &rest[..next];
        if !blank(piece) {
            if breaks >= 2 { flush(&mut current, &mut out); }
            else if breaks == 1 && !current.trim().is_empty() { current.push_str("<br>"); }
            breaks = 0;
            current.push_str(piece);
        }
        rest = &rest[next..];
    }
    flush(&mut current, &mut out);
    out
}

/// A chapter page: the text is the body of `section#viewChapter`.
pub fn parse_chapter_page(html: &str) -> Result<ChapterPage, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let section = doc.select(&sel("section#viewChapter")).next()
        .ok_or_else(|| crate::error::AppError::ParseError("Hentai Foundry chapter page has no chapter".to_string()))?;
    let title = section.select(&sel(".boxtitle")).next().map(|t| text(&t)).unwrap_or_default();
    let body = section.select(&sel(".boxbody")).next().map(|b| b.inner_html()).unwrap_or_default();
    Ok(ChapterPage { title, content: html_to_blocks(&paragraphs(&body), BASE_URL) })
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

/// A user's profile page: picture, the free-text profile, and the story
/// count its "Stories (N)" tab states.
pub fn parse_profile_page(html: &str, username: &str) -> Result<SourceUserProfile, crate::error::AppError> {
    let doc = Html::parse_document(html);
    let info = doc.select(&sel("#MemberInfoBox")).next()
        .ok_or_else(|| crate::error::AppError::ParseError("Hentai Foundry profile page has no member info".to_string()))?;
    let mut properties: Vec<(String, String)> = vec![("profile_url".into(), super::HentaiFoundrySource::profile_url(username))];
    if let Some(src) = info.select(&sel("img[src]")).next().and_then(|i| attr(&i, "src").map(absolute)) {
        properties.push(("avatar".into(), src));
    }
    let about_html = info.select(&sel("#profileText")).next().map(|d| d.inner_html()).unwrap_or_default();
    let about = html_to_blocks(&paragraphs(&about_html), BASE_URL);
    if !about.is_empty() {
        if let Ok(json) = serde_json::to_string(&about) { properties.push(("about".into(), json)); }
    }
    let stories = doc.select(&sel("a[href]")).find_map(|a| {
        if !attr(&a, "href")?.starts_with("/stories/user/") { return None }
        let label = text(&a);
        let n = label.strip_prefix("Stories (")?.strip_suffix(')')?;
        number(n)
    });
    if let Some(n) = stories { properties.push(("stories".into(), n.to_string())); }
    Ok(SourceUserProfile { source: SOURCE_ID.to_string(), source_id: username.to_string(), username: username.to_string(), properties })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::InlineContent;

    const LISTING: &str = include_str!("../../../tests/fixtures/hentaifoundry_listing.html");
    const STORY: &str = include_str!("../../../tests/fixtures/hentaifoundry_story.html");
    const CHAPTER: &str = include_str!("../../../tests/fixtures/hentaifoundry_chapter.html");
    const PROFILE: &str = include_str!("../../../tests/fixtures/hentaifoundry_profile.html");
    const AGE: &str = include_str!("../../../tests/fixtures/hentaifoundry_age.html");

    fn stat(w: &ListedWork, key: &str) -> Option<f64> {
        w.stats.iter().find(|s| s.key == key).and_then(|s| s.num)
    }

    #[test]
    fn dates_and_numbers() {
        assert_eq!(normalize_date("March 3, 2021"), "2021-03-03");
        assert_eq!(normalize_date("November 19, 2026"), "2026-11-19");
        assert_eq!(normalize_date("someday"), "someday");
        assert_eq!(number("118,432"), Some(118_432));
        assert_eq!(number(""), None);
    }

    #[test]
    fn a_listing_row_carries_the_whole_record() {
        let page = parse_listing(LISTING);
        assert_eq!(page.works.len(), 2);
        assert_eq!(page.total_works, Some(57));
        assert_eq!(page.total_pages, 3);
        assert!(page.has_next);

        let w = &page.works[0];
        let s = &w.summary;
        assert_eq!((s.source.as_str(), s.external_id.as_str()), (SOURCE_ID, "40112"));
        assert_eq!(s.url, "https://www.hentai-foundry.com/stories/user/Marrowmere/40112/The-Glass-Orchard");
        assert_eq!(s.title, "The Glass Orchard");
        assert_eq!(s.authors, vec!["Marrowmere"]);
        assert_eq!((s.date_published.as_str(), s.date_updated.as_str()), ("2021-03-03", "2021-04-18"));
        assert!(s.complete);
        assert_eq!(s.status, "Complete");
        assert_eq!((s.chapter_count, s.total_chapters), (3, Some(3)));
        assert_eq!(s.word_count, Some(7850));
        assert_eq!(s.comments, Some(2));
        assert_eq!(s.summary, "A gardener inherits an orchard whose fruit remembers.\n\nSecond line of the blurb & more.");
        assert_eq!(s.fandoms, vec!["Original Work"]);
        assert_eq!(s.rating, Rating::Explicit);
        assert_eq!(s.tags, vec!["Fantasy (Witches, Elves...)", "Explicit Nudity", "Moderate Violence",
                                "Explicit Sexual Content", "Yuri", "Female"]);
        assert_eq!(stat(w, "views"), Some(1204.0));
        assert_eq!(stat(w, "favorites"), Some(31.0));
        assert_eq!(stat(w, "votes"), Some(12.0));
        assert_eq!(w.stats.iter().find(|s| s.key == "size").and_then(|s| s.text.as_deref()), Some("41k"));
        let a = &w.authors[0];
        assert_eq!((a.id.as_str(), a.username.as_str()), ("Marrowmere", "Marrowmere"));
        assert_eq!(a.profile_url.as_deref(), Some("https://www.hentai-foundry.com/user/Marrowmere/profile"));
        assert_eq!(a.avatar_url.as_deref(), Some("https://avatars.hentai-foundry.com/900001.png"));

        // An unfinished story under a fandom root.
        let s = &page.works[1].summary;
        assert!(!s.complete);
        assert_eq!(s.status, "Incomplete");
        assert_eq!((s.chapter_count, s.total_chapters), (1, None));
        assert_eq!(s.fandoms, vec!["Harbor Quest"]);
        assert_eq!(s.rating, Rating::Mature);
        assert_eq!(s.tags, vec!["Mild Profanity", "Moderate Sexual Content"]);
        assert_eq!(s.word_count, Some(1902));
    }

    #[test]
    fn a_page_without_a_pager_is_one_page() {
        let page = parse_listing(STORY);
        assert_eq!((page.total_pages, page.has_next, page.total_works), (1, false, None));
        assert_eq!(page.works.len(), 1);
    }

    #[test]
    fn the_story_page_lists_its_chapters_in_order() {
        let page = parse_story_page(STORY, "40112").unwrap();
        assert_eq!(page.work.summary.title, "The Glass Orchard");
        assert_eq!(page.chapters.len(), 3);
        assert_eq!(page.chapters[0], ChapterEntry {
            id: 88001, number: 1, title: "Chapter 0 - Inheritance".to_string(), updated: "2021-03-03".to_string(),
        });
        assert_eq!((page.chapters[1].id, page.chapters[1].number), (88019, 2));
        assert_eq!(page.chapters[1].updated, "2021-03-21");
        assert_eq!(page.chapters[2].title, "Chapter 2 - What the Fruit Kept");
        let stub = stub_chapter(&page.chapters[2]);
        assert_eq!((stub.id, stub.number, stub.content.len()), (Some(88140), 3, 0));
        assert!(parse_story_page(STORY, "999").is_err(), "another story's page is not this story");
    }

    #[test]
    fn a_chapter_becomes_paragraphs() {
        let page = parse_chapter_page(CHAPTER).unwrap();
        assert_eq!(page.title, "Chapter 1 - First Harvest");
        assert_eq!(page.content.len(), 3, "{:?}", page.content);
        let ContentBlock::Paragraph { text } = &page.content[1] else { panic!("a paragraph") };
        assert!(text.iter().any(|i| matches!(i, InlineContent::LineBreak)), "a single break stays inside its paragraph");
        let ContentBlock::Paragraph { text } = &page.content[0] else { panic!("a paragraph") };
        assert!(text.iter().any(|i| matches!(i, InlineContent::Italic { .. })));
        assert!(parse_chapter_page(STORY).is_err());
    }

    #[test]
    fn paragraphs_split_on_blank_lines_only() {
        assert_eq!(paragraphs("one<br />\n<br />\ntwo<br>three<BR/><br><br>four"),
                   "<p>one</p><p>two<br>three</p><p>four</p>");
        assert_eq!(paragraphs("<br><br>"), "");
        assert_eq!(paragraphs("one<br>\n&nbsp;<br>\ntwo<br />\n\u{a0}<br />three"), "<p>one</p><p>two</p><p>three</p>",
                   "the site's blank lines hold a non-breaking space");
        assert_eq!(paragraphs("plain"), "<p>plain</p>");
    }

    #[test]
    fn the_header_names_the_signed_in_account() {
        let who = signed_in_user(STORY).unwrap();
        assert_eq!((who.external_id.as_str(), who.username.as_str()), ("Lanternfen", "Lanternfen"));
        assert!(signed_in_user(AGE).is_none());
        assert!(signed_in_user("<div id='headerWelcome'><a href='/site/login'>Login</a></div>").is_none());
        assert_eq!(csrf_token(STORY).as_deref(), Some("dG9rZW4tZm9yLXRlc3RzLW9ubHk="));
    }

    #[test]
    fn the_age_page_is_told_from_a_real_page() {
        assert!(is_age_page(AGE));
        assert!(!is_age_page(STORY));
    }

    #[test]
    fn a_profile_has_picture_text_and_story_count() {
        let p = parse_profile_page(PROFILE, "Marrowmere").unwrap();
        assert_eq!(p.username, "Marrowmere");
        assert_eq!(p.property("profile_url"), Some("https://www.hentai-foundry.com/user/Marrowmere/profile"));
        assert_eq!(p.property("avatar"), Some("https://profiles.hentai-foundry.com/900001.png"));
        assert_eq!(p.property("stories"), Some("12"));
        let about: Vec<ContentBlock> = serde_json::from_str(p.property("about").unwrap()).unwrap();
        assert_eq!(about.len(), 2);
        assert!(parse_profile_page(STORY, "x").is_err());
    }

    #[test]
    fn story_paths() {
        assert_eq!(story_path("/stories/user/A/12/Some-Slug"), Some(("A", "12", "Some-Slug", "")));
        assert_eq!(story_path("/stories/user/A/12/S/99/Chapter-1/T"), Some(("A", "12", "S", "99/Chapter-1/T")));
        assert_eq!(story_path("/stories/user/A"), None);
        assert_eq!(story_path("/stories/user/A/page/2"), None);
        assert_eq!(story_path("/pictures/user/A/12/S"), None);
    }

    #[test]
    fn username_lookup_answers() {
        assert_eq!(parse_usernames(r#"["marrow","marrowmere","marrow-2"]"#).unwrap(), ["marrow", "marrowmere", "marrow-2"]);
        assert!(parse_usernames("null").unwrap().is_empty());
        assert!(parse_usernames("<html><body id=\"siteEntry\"></body></html>").is_err());
    }
}
