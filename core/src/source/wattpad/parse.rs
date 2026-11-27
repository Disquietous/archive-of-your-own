//! Readers for Wattpad's JSON answers and its part text. The site
//! describes a story the same way in a search, an author's list and the
//! story's own record, differing only in which fields were asked for, so
//! one reader serves them all. Every field is read leniently: a missing
//! or oddly typed one is left out, not an error. Test data is
//! hand-authored on the site's field names with invented stories and
//! users.

use serde_json::Value;

use crate::error::AppError;
use crate::models::{AO3User, Chapter, Comment, ContentBlock, InlineContent, Rating, SourceUserProfile, WorkSummary};
use crate::parser::html_to_blocks;
use crate::source::{ListedWork, ListingPage, SourceStat, STAT_CHARACTERS};

use super::{WattpadSource, NAME, SOURCE_ID};

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).map(str::trim).unwrap_or("")
}

fn number(v: &Value, key: &str) -> Option<u64> {
    let x = v.get(key)?;
    x.as_u64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn json(body: &str, what: &str) -> Result<Value, AppError> {
    serde_json::from_str(body.trim())
        .map_err(|_| AppError::ParseError(format!("{NAME}'s {what} did not answer with JSON")))
}

/// What the site says went wrong, when an answer carries a message.
pub fn message(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    let said = text(&v, "message");
    (!said.is_empty()).then(|| said.to_string())
}

/// "2020-01-26T23:23:05Z" and "2026-11-12 15:53:59" → the day. Anything
/// else comes back trimmed.
fn day(raw: &str) -> String {
    let raw = raw.trim();
    match raw.get(..10) {
        Some(day) if day.bytes().enumerate().all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() }) => day.to_string(),
        _ => raw.to_string(),
    }
}

/// Plain text (a description, a comment) as paragraphs: a blank line
/// parts them, a single break stays inside one.
pub fn plain_blocks(raw: &str) -> Vec<ContentBlock> {
    let raw = raw.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = Vec::new();
    let mut current: Vec<InlineContent> = Vec::new();
    for line in raw.split('\n').map(str::trim).chain(std::iter::once("")) {
        if line.is_empty() {
            if !current.is_empty() { out.push(ContentBlock::Paragraph { text: std::mem::take(&mut current) }); }
            continue;
        }
        if !current.is_empty() { current.push(InlineContent::LineBreak); }
        current.push(InlineContent::Text { value: line.to_string() });
    }
    out
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

/// The site's stock pictures for an account that has set none.
fn own_picture(url: &str) -> bool {
    !url.is_empty() && !url.contains("/useravatar/default") && !url.contains("avatar_default")
}

fn user(username: &str, picture: &str) -> AO3User {
    AO3User {
        source: SOURCE_ID.to_string(),
        id: username.to_string(),
        username: username.to_string(),
        profile_url: Some(WattpadSource::profile_url(username)),
        avatar_url: own_picture(picture).then(|| picture.to_string()),
    }
}

/// A user as a story or a comment names them: under `username` where the
/// record has one, else `name` (which those records use for the same).
fn user_of(v: &Value) -> Option<AO3User> {
    let username = [text(v, "username"), text(v, "name")].into_iter().find(|n| !n.is_empty())?;
    Some(user(username, text(v, "avatar")))
}

/// The user search's answer: a bare list of users.
pub fn parse_users(body: &str) -> Result<Vec<AO3User>, AppError> {
    let v = json(body, "user search")?;
    let list = v.as_array().or_else(|| v.get("users").and_then(Value::as_array));
    Ok(list.into_iter().flatten()
        .filter_map(|u| { let name = text(u, "username"); (!name.is_empty()).then(|| user(name, text(u, "avatar"))) })
        .collect())
}

pub fn parse_profile(body: &str) -> Result<SourceUserProfile, AppError> {
    let v = json(body, "profile")?;
    let username = text(&v, "username");
    if username.is_empty() {
        return Err(AppError::ParseError(format!("{NAME}'s profile answer names no user")));
    }
    let profile_url = WattpadSource::profile_url(username);
    let mut properties: Vec<(String, String)> = vec![("profile_url".into(), profile_url)];
    let picture = text(&v, "avatar");
    if own_picture(picture) { properties.push(("avatar".into(), picture.to_string())); }
    // The name the user shows beside their username opens the description.
    let mut about = Vec::new();
    let shown = text(&v, "name");
    if !shown.is_empty() && shown != username {
        about.push(ContentBlock::Paragraph { text: vec![InlineContent::Bold { content: vec![InlineContent::Text { value: shown.to_string() }] }] });
    }
    about.extend(plain_blocks(text(&v, "description")));
    if !about.is_empty() {
        if let Ok(json) = serde_json::to_string(&about) { properties.push(("about".into(), json)); }
    }
    let location = text(&v, "location");
    if !location.is_empty() { properties.push(("location".into(), location.to_string())); }
    let joined = day(text(&v, "createDate"));
    if !joined.is_empty() { properties.push(("joined".into(), joined)); }
    for (key, name) in [("numStoriesPublished", "stories"), ("numFollowers", "followers"), ("numFollowing", "following")] {
        if let Some(n) = number(&v, key) { properties.push((name.into(), n.to_string())); }
    }
    Ok(SourceUserProfile { source: SOURCE_ID.to_string(), source_id: username.to_string(), username: username.to_string(), properties })
}

/// The account the site says is signed in.
pub fn parse_current_user(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    let name = text(&v, "username");
    (!name.is_empty()).then(|| name.to_string())
}

/// Whether the account's content setting lets mature stories be listed:
/// the setting's flag, wherever the answer carries it.
pub fn includes_mature(body: &str) -> Option<bool> {
    fn find(v: &Value) -> Option<bool> {
        match v {
            Value::Object(fields) => fields.get("includeMature").and_then(Value::as_bool)
                .or_else(|| fields.values().find_map(find)),
            Value::Array(items) => items.iter().find_map(find),
            _ => None,
        }
    }
    find(&serde_json::from_str(body.trim()).ok()?)
}

// ---------------------------------------------------------------------------
// Stories as works
// ---------------------------------------------------------------------------

/// One story as a work. A listing and the story's own record differ in
/// what they were asked for; whatever is absent stays unknown. The word
/// count is the parts' own, so only a record that lists its parts has it.
fn story_work(story: &Value) -> Option<ListedWork> {
    let (id, title) = (number(story, "id")?, text(story, "title"));
    if title.is_empty() { return None }
    let author = story.get("user").and_then(user_of);
    let address = text(story, "url");
    let parts = published_parts(story);
    let listed_parts = story.get("parts").is_some_and(Value::is_array);
    let count = if listed_parts { parts.len() as u32 } else { number(story, "numParts").unwrap_or(0) as u32 };
    let complete = flag(story, "completed");
    let published = day(text(story, "createDate"));
    let last_part = story.get("lastPublishedPart").map(|p| day(text(p, "createDate"))).unwrap_or_default();
    let updated = [last_part, day(text(story, "modifyDate")), published.clone()].into_iter().find(|d| !d.is_empty()).unwrap_or_default();
    let words: u64 = parts.iter().filter_map(|p| number(p, "wordCount")).sum();
    let summary = WorkSummary {
        id: 0,
        source: SOURCE_ID.to_string(),
        external_id: id.to_string(),
        url: if address.is_empty() { WattpadSource::story_url(id) } else { address.to_string() },
        title: title.to_string(),
        authors: author.iter().map(|a| a.username.clone()).collect(),
        author_ids: Vec::new(),
        fandoms: Vec::new(),
        // The site grades a story mature or not, nothing finer.
        rating: if flag(story, "mature") { Rating::Mature } else { Rating::NotRated },
        warnings: Vec::new(),
        categories: Vec::new(),
        relationships: Vec::new(),
        characters: Vec::new(),
        tags: story.get("tags").and_then(Value::as_array).into_iter().flatten()
            .filter_map(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).collect(),
        summary: text(story, "description").to_string(),
        word_count: (listed_parts && words > 0).then_some(words),
        chapter_count: count,
        total_chapters: complete.then_some(count),
        kudos: number(story, "voteCount").map(|n| n as u32),
        hits: number(story, "readCount"),
        bookmarks: None,
        comments: number(story, "commentCount").map(|n| n as u32),
        date_published: if published.is_empty() { updated.clone() } else { published },
        date_updated: updated,
        language: story.get("language").map(|l| text(l, "name").to_string()).unwrap_or_default(),
        complete,
        status: if complete { "Complete" } else { "Ongoing" }.to_string(),
        series: Vec::new(),
        fetched_at: String::new(),
    };
    let mut stats = Vec::new();
    if let Some(length) = number(story, "length") {
        stats.push(SourceStat::num(STAT_CHARACTERS, "Characters", length as f64, 1));
    }
    if flag(story, "isPaywalled") {
        stats.push(SourceStat { key: "paid".into(), label: "Paid".into(), num: None, text: Some("Paid story".into()), order: 2 });
    }
    Some(ListedWork { summary, stats, authors: author.into_iter().collect() })
}

/// The parts a reader sees: the record's, less any marked a draft.
fn published_parts(story: &Value) -> Vec<&Value> {
    story.get("parts").and_then(Value::as_array).into_iter().flatten()
        .filter(|p| number(p, "id").is_some() && !flag(p, "draft")).collect()
}

/// A page of stories: search results or an author's list. `offset` and
/// `size` are what was asked for.
pub fn parse_listing(body: &str, offset: u32, size: u32) -> Result<ListingPage, AppError> {
    let v = json(body, "story list")?;
    let stories = v.get("stories").and_then(Value::as_array)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story list has no stories")))?;
    let works: Vec<ListedWork> = stories.iter().filter_map(story_work).collect();
    let total = number(&v, "total");
    let seen = offset as u64 + stories.len() as u64;
    let has_next = !stories.is_empty() && match total {
        Some(total) => seen < total,
        None => !text(&v, "nextUrl").is_empty(),
    };
    let size = size.max(1) as u64;
    let total_pages = match total {
        Some(total) => total.div_ceil(size).max(1) as u32,
        None => (offset as u64 / size + 1 + has_next as u64) as u32,
    };
    Ok(ListingPage { works, has_next, total_pages, total_works: total.map(|n| n.min(u32::MAX as u64) as u32) })
}

/// A story's own record: the work and its parts as chapters, without
/// text.
pub fn parse_story(body: &str) -> Result<(ListedWork, Vec<Chapter>), AppError> {
    let v = json(body, "story")?;
    let work = story_work(&v)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story answer has no id or title")))?;
    let chapters = published_parts(&v).into_iter().enumerate().map(|(i, part)| Chapter {
        id: number(part, "id"),
        title: Some(text(part, "title").to_string()).filter(|t| !t.is_empty()),
        number: i as u32 + 1,
        content: Vec::new(),
        notes_before: None,
        notes_after: None,
    }).collect();
    Ok((work, chapters))
}

/// The story a part belongs to, from the part's own record.
pub fn part_story(body: &str) -> Option<u64> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    v.get("group").and_then(|g| number(g, "id")).or_else(|| number(&v, "groupId"))
}

/// A part's text as the reader's content tree. The site spaces its
/// paragraphs with breaks at their start or end (bare, or inside the
/// markup that opens or closes the paragraph); those are dropped, and
/// a paragraph left with nothing is too. Many parts also hold several
/// paragraphs in one, set apart by a blank line (two or more breaks in
/// a row): each becomes a paragraph of its own, so every paragraph is
/// spaced alike. A single break between two lines is the author's and
/// stays.
pub fn part_blocks(html: &str, part_url: &str) -> Vec<ContentBlock> {
    let mut out = Vec::new();
    for block in html_to_blocks(html.trim(), part_url) {
        let ContentBlock::Paragraph { text } = block else {
            out.push(block);
            continue;
        };
        for mut text in split_at_blank_lines(text) {
            trim_blank_edge(&mut text, true);
            trim_blank_edge(&mut text, false);
            if !text.is_empty() { out.push(ContentBlock::Paragraph { text }); }
        }
    }
    out
}

/// A paragraph's content cut wherever two or more breaks stand in a row
/// (blank text between them does not part them); the breaks themselves
/// are left out.
fn split_at_blank_lines(text: Vec<InlineContent>) -> Vec<Vec<InlineContent>> {
    let is_break = |i: &InlineContent| matches!(i, InlineContent::LineBreak);
    let is_blank = |i: &InlineContent| matches!(i, InlineContent::Text { value } if value.trim().is_empty());
    let mut parts = vec![Vec::new()];
    let mut at = 0;
    while at < text.len() {
        if is_break(&text[at]) {
            let run = text[at..].iter().take_while(|i| is_break(i) || is_blank(i)).count();
            if text[at..at + run].iter().filter(|i| is_break(i)).count() >= 2 {
                parts.push(Vec::new());
                at += run;
                continue;
            }
        }
        parts.last_mut().expect("never empty").push(text[at].clone());
        at += 1;
    }
    parts
}

/// Drop the breaks and blank text at one end of a line of inline
/// content, reaching into the markup that sits at that end.
fn trim_blank_edge(inlines: &mut Vec<InlineContent>, front: bool) {
    loop {
        let at = if front { 0 } else { inlines.len().saturating_sub(1) };
        let emptied = match inlines.get_mut(at) {
            None => return,
            Some(InlineContent::LineBreak) => true,
            Some(InlineContent::Text { value }) => value.trim().is_empty(),
            Some(InlineContent::Bold { content } | InlineContent::Italic { content }
                 | InlineContent::Link { content, .. } | InlineContent::Strikethrough { content }
                 | InlineContent::Superscript { content }) => {
                trim_blank_edge(content, front);
                content.is_empty()
            }
        };
        if !emptied { return; }
        inlines.remove(at);
    }
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

/// One comment as the site keys it, with the number it goes by here.
#[derive(Debug, Clone)]
pub struct ListedComment {
    pub comment: Comment,
    /// The site's own key for the comment (its replies are asked for by
    /// it).
    pub key: String,
    pub replies: u32,
    /// The comment's page on the site.
    pub link: String,
}

/// One answer of the comments feed.
#[derive(Debug, Clone, Default)]
pub struct CommentsAnswer {
    /// The part's own comments (or, for a replies answer, the replies).
    pub comments: Vec<ListedComment>,
    /// Where the feed goes on from; None at its end.
    pub after: Option<String>,
}

/// The number a comment goes by here, from the site's key
/// (`…_{seconds}_{mark}`): when it was written and the start of its
/// mark.
pub fn comment_number(key: &str) -> Option<u64> {
    let mut pieces = key.rsplit('_');
    let mark = pieces.next()?;
    let seconds: u64 = pieces.next()?.parse().ok()?;
    let mark = u32::from_str_radix(mark.get(..8).unwrap_or(mark), 16).ok()?;
    Some(((seconds & 0xFFFF_FFFF) << 32) | mark as u64)
}

fn comment_of(v: &Value, chapter: u64) -> Option<ListedComment> {
    let key = v.get("commentId").map(|c| text(c, "resourceId")).filter(|k| !k.is_empty())?;
    let id = comment_number(key)?;
    let status = text(v, "status");
    if !status.is_empty() && status != "public" { return None }
    let author = v.get("user").and_then(user_of).unwrap_or_else(|| AO3User {
        source: SOURCE_ID.to_string(), id: String::new(), username: "Anonymous".to_string(), profile_url: None, avatar_url: None,
    });
    let replies = number(v, "replyCount").unwrap_or(0) as u32;
    Some(ListedComment {
        comment: Comment {
            id,
            author,
            posted_at: day(text(v, "created")),
            content: plain_blocks(text(v, "text")),
            replies: Vec::new(),
            chapter_label: None,
            chapter_id: Some(chapter),
            notice: None,
            more_replies: 0,
            rating: None,
        },
        key: key.to_string(),
        replies,
        link: text(v, "deeplink").to_string(),
    })
}

/// One answer of a part's comments feed. The feed mixes the part's own
/// comments with the ones readers leave on single paragraphs; only the
/// part's own are kept (`inline` false). A replies answer keeps every
/// row (`inline` true): its rows belong to the comment asked about.
pub fn parse_comments(body: &str, chapter: u64, inline: bool) -> Result<CommentsAnswer, AppError> {
    let v = json(body, "comments")?;
    let rows = v.get("comments").and_then(Value::as_array)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s comments answer has no comments")))?;
    let comments = rows.iter()
        .filter(|row| inline || row.get("resource").map(|r| text(r, "namespace")) != Some("paragraphs"))
        .filter_map(|row| comment_of(row, chapter))
        .collect();
    let after = v.get("pagination").and_then(|p| p.get("after")).map(|a| text(a, "resourceId"))
        .filter(|k| !k.is_empty()).map(str::to_string);
    Ok(CommentsAnswer { comments, after })
}

#[cfg(test)]
mod tests {
    use super::*;

    const PARTS: &str = r#"[
        {"id": 700101, "title": "The Lamp Room", "draft": false, "wordCount": 1200, "length": 6100, "createDate": "2025-02-01T10:00:00Z"},
        {"id": 700102, "title": "Low Water", "draft": false, "wordCount": 800, "length": 4000, "createDate": "2025-02-08T10:00:00Z"},
        {"id": 700103, "title": "Unfinished", "draft": true, "wordCount": 50, "length": 200}
    ]"#;

    fn story(extra: &str) -> String {
        format!(r#"{{"id": "55001", "title": "The Tide Ledger", "description": "A keeper counts the tides.\n\nNobody asks why.",
            "url": "https://www.wattpad.com/story/55001-the-tide-ledger", "cover": "https://img.example/cover/55001.jpg",
            "user": {{"name": "saltwick", "username": "saltwick", "avatar": "https://img.example/useravatar/saltwick.128.1.jpg"}},
            "completed": false, "mature": true, "tags": ["lighthouse", " sea ", ""], "language": {{"id": 1, "name": "English"}},
            "createDate": "2025-02-01T09:58:00Z", "modifyDate": "2025-02-09T08:00:00Z",
            "lastPublishedPart": {{"id": 700102, "createDate": "2025-02-08 10:00:00"}},
            "numParts": 2, "length": 10100, "voteCount": 31, "readCount": 2210, "commentCount": 4,
            "isPaywalled": false, "paidModel": ""{extra}}}"#)
    }

    #[test]
    fn a_story_record_is_a_work_with_its_parts_as_chapters() {
        let (work, chapters) = parse_story(&story(&format!(r#", "parts": {PARTS}"#))).unwrap();
        let s = &work.summary;
        assert_eq!((s.external_id.as_str(), s.title.as_str(), s.url.as_str()),
                   ("55001", "The Tide Ledger", "https://www.wattpad.com/story/55001-the-tide-ledger"));
        assert_eq!((s.authors.clone(), &s.rating, s.language.as_str()), (vec!["saltwick".to_string()], &Rating::Mature, "English"));
        assert_eq!(s.tags, vec!["lighthouse", "sea"]);
        assert_eq!((s.word_count, s.chapter_count, s.total_chapters, s.complete, s.status.as_str()), (Some(2000), 2, None, false, "Ongoing"));
        assert_eq!((s.kudos, s.hits, s.comments), (Some(31), Some(2210), Some(4)));
        assert_eq!((s.date_published.as_str(), s.date_updated.as_str()), ("2025-02-01", "2025-02-08"));
        assert_eq!(work.stats.iter().find(|st| st.key == "characters").and_then(|st| st.num), Some(10100.0));
        assert!(work.stats.iter().all(|st| st.key != "paid"));
        assert_eq!(work.authors[0].profile_url.as_deref(), Some("https://www.wattpad.com/user/saltwick"));
        assert_eq!(chapters.iter().map(|c| (c.id, c.number, c.title.as_deref())).collect::<Vec<_>>(),
                   vec![(Some(700101), 1, Some("The Lamp Room")), (Some(700102), 2, Some("Low Water"))], "a draft is no chapter");
        assert!(chapters.iter().all(|c| c.content.is_empty()));
        assert!(parse_story(r#"{"error_code": 1017, "message": "Story not found"}"#).is_err());
        assert!(parse_story("<html>").is_err());
    }

    #[test]
    fn a_listing_states_characters_but_no_word_count() {
        let body = format!(r#"{{"total": 31, "stories": [{}, {{"id": "55002", "title": "Paid One", "completed": true, "numParts": 9,
            "isPaywalled": true, "user": {{"name": "marrowmere"}}}}, {{"title": "no id"}}],
            "tags": [{{"id": "sea", "name": "sea", "count": 4}}], "nextUrl": "https://www.wattpad.com/v4/search/stories?offset=15"}}"#, story(""));
        let page = parse_listing(&body, 0, 15).unwrap();
        assert_eq!((page.works.len(), page.has_next, page.total_pages, page.total_works), (2, true, 3, Some(31)));
        let first = &page.works[0];
        assert_eq!((first.summary.word_count, first.summary.chapter_count), (None, 2));
        assert_eq!(first.stats.iter().find(|st| st.key == "characters").and_then(|st| st.num), Some(10100.0));
        let paid = &page.works[1];
        assert_eq!((paid.summary.url.as_str(), paid.summary.total_chapters, &paid.summary.rating),
                   ("https://www.wattpad.com/story/55002", Some(9), &Rating::NotRated));
        assert!(paid.stats.iter().any(|st| st.key == "paid") && paid.stats.iter().all(|st| st.key != "characters"));
        assert_eq!(paid.authors[0].id, "marrowmere");

        let last = parse_listing(r#"{"stories": [{"id": 1, "title": "x"}], "total": 31}"#, 30, 15).unwrap();
        assert_eq!((last.has_next, last.total_pages), (false, 3));
        let uncounted = parse_listing(r#"{"stories": [{"id": 1, "title": "x"}], "nextUrl": "https://next"}"#, 15, 15).unwrap();
        assert_eq!((uncounted.has_next, uncounted.total_pages, uncounted.total_works), (true, 3, None));
        let empty = parse_listing(r#"{"stories": [], "total": 0}"#, 0, 15).unwrap();
        assert_eq!((empty.works.len(), empty.has_next, empty.total_pages), (0, false, 1));
        assert!(parse_listing(r#"{"message": "nope"}"#, 0, 15).is_err());
    }

    #[test]
    fn part_text_becomes_paragraphs_without_the_sites_spacing_breaks() {
        let html = "<p data-p-id=\"a1\">First line.<br>Same paragraph.<br><br></p>\n<p data-p-id=\"a2\"><b>Bold</b> and <i>stressed</i>.<br></p>\n\
                    <p data-p-id=\"a3\"><br></p>\n<p data-p-id=\"a4\" data-media-type=\"image\"><img src=\"https://img.example/1.jpg\" alt=\"\"></p>";
        let out = part_blocks(html, "https://www.wattpad.com/700101-the-lamp-room");
        let ContentBlock::Paragraph { text } = &out[0] else { panic!("a paragraph") };
        assert_eq!(text.iter().filter(|i| matches!(i, InlineContent::LineBreak)).count(), 1);
        let ContentBlock::Paragraph { text } = &out[1] else { panic!("a paragraph") };
        assert!(text.iter().any(|i| matches!(i, InlineContent::Bold { .. })) && !text.iter().any(|i| matches!(i, InlineContent::LineBreak)));
        assert!(out.iter().any(|b| matches!(b, ContentBlock::Image { src, .. } if src == "https://img.example/1.jpg")));
        assert!(out.iter().all(|b| !matches!(b, ContentBlock::Paragraph { text } if text.is_empty())));
        assert!(part_blocks("  ", "https://www.wattpad.com/1").is_empty());
    }

    #[test]
    fn spacing_breaks_go_from_the_ends_of_a_paragraph_and_blank_lines_part_it() {
        let text = |value: &str| InlineContent::Text { value: value.to_string() };
        let html = "<p><br>Opens with a break.</p>\n<p><br> <br>Two, with a space.<br> </p>\n\
                    <p><i><br>Stressed.<br></i><br></p>\n<p><b><br></b>&nbsp;<br></p>\n\
                    <p>One line.<br>Its second line.<br><br>Another, after a gap.<br /></p>\n\
                    <p>Three<br> <br>in<br>&nbsp;<br><br>one.</p>";
        let out = part_blocks(html, "https://www.wattpad.com/700101-the-lamp-room");
        assert_eq!(out, vec![
            ContentBlock::Paragraph { text: vec![text("Opens with a break.")] },
            ContentBlock::Paragraph { text: vec![text("Two, with a space.")] },
            ContentBlock::Paragraph { text: vec![InlineContent::Italic { content: vec![text("Stressed.")] }] },
            ContentBlock::Paragraph { text: vec![text("One line."), InlineContent::LineBreak, text("Its second line.")] },
            ContentBlock::Paragraph { text: vec![text("Another, after a gap.")] },
            ContentBlock::Paragraph { text: vec![text("Three")] },
            ContentBlock::Paragraph { text: vec![text("in")] },
            ContentBlock::Paragraph { text: vec![text("one.")] },
        ]);
    }

    #[test]
    fn only_a_parts_own_comments_are_kept() {
        let body = r#"{"pagination": {"after": {"namespace": "comments", "resourceId": "700101_ab12_1700000300_0a0b0c0d0e"}}, "comments": [
            {"resource": {"namespace": "paragraphs", "resourceId": "700101_ab12"}, "user": {"name": "fennholt"},
             "commentId": {"namespace": "comments", "resourceId": "700101_ab12_1700000300_0a0b0c0d0e"}, "text": "inline", "created": "2023-11-14T22:18:20Z", "status": "public", "replyCount": 0},
            {"resource": {"namespace": "parts", "resourceId": "700101"}, "user": {"name": "quillmoor", "avatar": "https://a.example/useravatar/quillmoor.256.1.jpg"},
             "commentId": {"namespace": "comments", "resourceId": "700101__1700000000_e66e44bf51"}, "text": "Kept me up.\n\nWorth it.",
             "created": "2023-11-14T22:13:20Z", "status": "public", "replyCount": 2, "deeplink": "https://www.wattpad.com/700101/comment/700101__1700000000_e66e44bf51"},
            {"resource": {"namespace": "parts", "resourceId": "700101"}, "user": {"name": "gone"},
             "commentId": {"namespace": "comments", "resourceId": "700101__1700000100_aaaaaaaaaa"}, "text": "x", "status": "deleted"},
            {"resource": {"namespace": "parts", "resourceId": "700101"}, "text": "no key"}
        ]}"#;
        let answer = parse_comments(body, 700101, false).unwrap();
        assert_eq!(answer.after.as_deref(), Some("700101_ab12_1700000300_0a0b0c0d0e"));
        assert_eq!(answer.comments.len(), 1);
        let kept = &answer.comments[0];
        assert_eq!((kept.key.as_str(), kept.replies, kept.link.as_str()),
                   ("700101__1700000000_e66e44bf51", 2, "https://www.wattpad.com/700101/comment/700101__1700000000_e66e44bf51"));
        assert_eq!(kept.comment.id, (1_700_000_000u64 << 32) | 0xe66e_44bf);
        assert_eq!((kept.comment.author.username.as_str(), kept.comment.posted_at.as_str(), kept.comment.chapter_id),
                   ("quillmoor", "2023-11-14", Some(700101)));
        assert_eq!(kept.comment.content.len(), 2);
        // A replies answer keeps every row; the feed's end has no cursor.
        let replies = parse_comments(body, 700101, true).unwrap();
        assert_eq!(replies.comments.len(), 2);
        let end = parse_comments(r#"{"pagination": {}, "comments": []}"#, 700101, false).unwrap();
        assert!(end.comments.is_empty() && end.after.is_none());
        assert!(parse_comments(r#"{"message": "nope"}"#, 1, false).is_err());
        assert_eq!(comment_number("1_2_x_ff"), None);
        assert_eq!(comment_number("700101__1700000000_e6"), Some((1_700_000_000u64 << 32) | 0xe6));
    }

    #[test]
    fn profiles_users_and_the_account() {
        let body = r#"{"username": "saltwick", "name": "Salt Wick", "avatar": "https://img.example/useravatar/saltwick.128.1.jpg",
            "description": "I count tides.\nDaily.", "createDate": "2020-01-05T03:54:03Z", "location": "Nowhere", "verified": false,
            "votesReceived": 991, "numStoriesPublished": 2, "numFollowing": 0, "numFollowers": 65}"#;
        let profile = parse_profile(body).unwrap();
        assert_eq!((profile.source_id.as_str(), profile.username.as_str()), ("saltwick", "saltwick"));
        assert_eq!(profile.property("profile_url"), Some("https://www.wattpad.com/user/saltwick"));
        assert_eq!((profile.property("stories"), profile.property("followers"), profile.property("following")),
                   (Some("2"), Some("65"), Some("0")));
        assert_eq!((profile.property("location"), profile.property("joined")), (Some("Nowhere"), Some("2020-01-05")));
        let about: Vec<ContentBlock> = serde_json::from_str(profile.property("about").unwrap()).unwrap();
        assert_eq!(about.len(), 2, "the shown name, then the description");
        assert!(parse_profile(r#"{"error_code": 1014, "message": "User not found"}"#).is_err());

        let users = parse_users(r#"[{"username": "saltwick", "name": "", "avatar": "https://img.example/useravatar/default_1.png"}, {"username": ""}]"#).unwrap();
        assert_eq!(users.len(), 1);
        assert_eq!((users[0].id.as_str(), users[0].avatar_url.is_none()), ("saltwick", true));

        assert_eq!(parse_current_user(r#"{"username": "quillmoor"}"#).as_deref(), Some("quillmoor"));
        assert_eq!(parse_current_user(r#"{"error_type": "PermissionDenied", "message": "User not logged in"}"#), None);
        assert_eq!(includes_mature(r#"{"contentSettings": {"includeMature": true}}"#), Some(true));
        assert_eq!(includes_mature(r#"{"includeMature": false}"#), Some(false));
        assert_eq!(includes_mature(r#"{"other": 1}"#), None);
        assert_eq!(message(r#"{"error_code": 1017, "message": "Story not found"}"#).as_deref(), Some("Story not found"));
        assert_eq!(part_story(r#"{"id": 700101, "group": {"id": "55001"}}"#), Some(55001));
        assert_eq!(part_story(r#"{"id": 700101}"#), None);
    }

    #[test]
    fn days() {
        assert_eq!(day("2020-01-26T23:23:05Z"), "2020-01-26");
        assert_eq!(day("2026-11-12 15:53:59"), "2026-11-12");
        assert_eq!(day(" soon "), "soon");
        assert_eq!(day(""), "");
    }
}
