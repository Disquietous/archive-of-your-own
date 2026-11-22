//! Readers for Literotica's JSON answers. The site describes a story the
//! same way everywhere — search results, an author's list, a series'
//! parts, the story itself — so one reader serves them all. Every field
//! is read leniently: a missing or oddly typed one is left out, not an
//! error. Test data is hand-authored on the site's field names with
//! invented stories and authors.

use std::collections::HashSet;

use serde_json::Value;

use crate::error::AppError;
use crate::models::{AO3User, Chapter, Comment, CommentsPage, ContentBlock, Rating, SourceUserProfile, WorkSummary};
use crate::parser::html_to_blocks;
use crate::source::{ListedWork, ListingPage, SessionIdentity, SourceStat};

use super::{LiteroticaSource, NAME, SOURCE_ID};

/// The site's languages by its own ids.
const LANGUAGES: &[(u64, &str)] = &[
    (1, "English"), (2, "Spanish"), (3, "German"), (4, "French"), (5, "Dutch"), (6, "Italian"), (7, "Romanian"),
    (8, "Portuguese"), (9, "Afrikaans"), (10, "Bengali"), (11, "Chinese"), (12, "Danish"), (13, "Esperanto"),
    (14, "Finnish"), (15, "Japanese"), (16, "Norwegian"), (17, "Polish"), (18, "Russian"), (19, "Serbian"),
    (20, "Swedish"), (21, "Turkish"), (22, "Urdu"), (23, "Malayalam"), (24, "Hindi"), (25, "Marathi"), (26, "Tamil"),
    (27, "Telugu"), (28, "Arabic"), (29, "Magahi"), (30, "Soninke"), (31, "Hausa"), (32, "Tagalog"), (33, "Madurese"),
    (34, "Greek"), (35, "Javanese"), (37, "Pular"), (38, "Nynorsk"), (39, "Sinhala"), (40, "Waray"), (41, "Bhojpuri"),
    (42, "Gujarati"), (43, "Tiv"), (44, "Iloko"), (45, "Sundanese"), (46, "Hungarian"), (47, "Albanian"),
    (49, "Buginese"), (50, "Kapampangan"), (52, "Sardinian"), (53, "Croatian"), (54, "Persian"), (55, "Bosnian"),
    (56, "Balkan Romani"), (57, "Bulgarian"), (58, "Catalan"), (59, "Ukrainian"), (60, "Kannada"), (62, "Punjabi"),
    (63, "Indonesian"), (64, "Czech"), (65, "Swahili"), (66, "Haitian Creole"), (67, "Vietnamese"), (68, "Somali"),
    (69, "Hebrew"), (70, "Yiddish"), (71, "Korean"), (72, "Nepali"), (73, "Latin"), (74, "Slovenian"), (75, "Odia"),
    (76, "Scottish Gaelic"),
];

/// The category the site files stories without sexual content under.
const NON_EROTIC: u64 = 35;

/// The picture the site shows for an account that has none.
const DEFAULT_PICTURE: &str = "da_default";

/// How many of a series' tags its work carries: the most used across its
/// parts.
const SERIES_TAGS: usize = 30;

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

fn decimal(v: &Value, key: &str) -> Option<f64> {
    let x = v.get(key)?;
    x.as_f64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))
}

fn json(body: &str, what: &str) -> Result<Value, AppError> {
    let v: Value = serde_json::from_str(body.trim())
        .map_err(|_| AppError::ParseError(format!("{NAME}'s {what} did not answer with JSON")))?;
    if v.get("success").and_then(Value::as_bool) == Some(false) {
        let said = message(body).unwrap_or_else(|| "no reason given".to_string());
        return Err(AppError::ParseError(format!("{NAME} refused the {what}: {said}")));
    }
    Ok(v)
}

/// What the site says went wrong, when an answer carries a message.
pub fn message(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    let said = text(&v, "message");
    (!said.is_empty()).then(|| said.to_string())
}

/// "07/25/2006" and "2022-11-20T13:39:49Z" → "2006-07-25" / "2022-11-20".
/// Anything else comes back trimmed.
pub(super) fn normalize_date(raw: &str) -> String {
    let raw = raw.trim();
    let digits = |s: &str, len: usize| s.len() == len && s.bytes().all(|b| b.is_ascii_digit());
    let slashed: Vec<&str> = raw.split('/').collect();
    if let [month, day, year] = slashed.as_slice() {
        if digits(month, 2) && digits(day, 2) && digits(year, 4) { return format!("{year}-{month}-{day}") }
    }
    if let Some(day) = raw.get(..10) {
        let parts: Vec<&str> = day.split('-').collect();
        if let [year, month, date] = parts.as_slice() {
            if digits(year, 4) && digits(month, 2) && digits(date, 2) { return day.to_string() }
        }
    }
    raw.to_string()
}

fn language_name(id: Option<u64>) -> String {
    id.and_then(|id| LANGUAGES.iter().find(|(l, _)| *l == id)).map(|(_, name)| name.to_string()).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// Whether a piece of story text opens with markup that is already a
/// block of its own (a centred paragraph, a list).
fn opens_with_block(piece: &str) -> bool {
    const BLOCKS: &[&str] = &["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "hr", "center", "pre", "table"];
    let Some(rest) = piece.strip_prefix('<') else { return false };
    let name: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric()).collect::<String>().to_ascii_lowercase();
    BLOCKS.contains(&name.as_str())
}

/// The site stores a story as text: a blank line between paragraphs, a
/// single break inside one, and a little markup of the author's own
/// (emphasis, links, centred lines). That becomes paragraphs here.
fn paragraphs(raw: &str) -> String {
    let raw = raw.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = String::new();
    let mut current: Vec<&str> = Vec::new();
    let flush = |current: &mut Vec<&str>, out: &mut String| {
        if current.is_empty() { return }
        let piece = current.join("\n");
        if opens_with_block(&piece) { out.push_str(&piece); }
        else { out.push_str("<p>"); out.push_str(&piece.replace('\n', "<br>")); out.push_str("</p>"); }
        current.clear();
    };
    for line in raw.split('\n') {
        let line = line.trim();
        if line.is_empty() { flush(&mut current, &mut out); } else { current.push(line); }
    }
    flush(&mut current, &mut out);
    out
}

/// Story or profile text as the reader's content tree. `page_url` is the
/// page the text is shown on at the site, for its relative links.
pub fn blocks(raw: &str, page_url: &str) -> Vec<ContentBlock> {
    html_to_blocks(&paragraphs(raw), page_url)
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

/// A user as a story, a series or the member search names them, with the
/// site's number for them (which its story lists are asked for by).
fn user_of(v: &Value) -> Option<(AO3User, Option<u64>)> {
    let username = text(v, "username");
    if username.is_empty() { return None }
    let picture = text(v, "userpic");
    let user = AO3User {
        source: SOURCE_ID.to_string(),
        id: username.to_string(),
        username: username.to_string(),
        profile_url: Some(LiteroticaSource::profile_url(username)),
        avatar_url: (!picture.is_empty() && !picture.contains(DEFAULT_PICTURE)).then(|| picture.to_string()),
    };
    Some((user, number(v, "userid")))
}

/// A story's author: the `author` record when it is one, else the bare
/// name beside it.
fn author_of(story: &Value) -> Option<(AO3User, Option<u64>)> {
    if let Some(found) = story.get("author").filter(|a| a.is_object()).and_then(user_of) { return Some(found) }
    let name = text(story, "authorname");
    if name.is_empty() { return None }
    Some((AO3User {
        source: SOURCE_ID.to_string(), id: name.to_string(), username: name.to_string(),
        profile_url: Some(LiteroticaSource::profile_url(name)), avatar_url: None,
    }, story.get("author").and_then(Value::as_u64)))
}

/// A page of the member search: each user with the site's number for
/// them.
pub fn parse_members(body: &str) -> Result<Vec<(AO3User, Option<u64>)>, AppError> {
    let v = json(body, "member search")?;
    Ok(v.get("data").and_then(Value::as_array).map(|list| list.iter().filter_map(user_of).collect()).unwrap_or_default())
}

/// A user's record: the profile and the site's number for them.
pub fn parse_profile(body: &str) -> Result<(SourceUserProfile, Option<u64>), AppError> {
    let v = json(body, "profile")?;
    let user = v.get("user").filter(|u| u.is_object())
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s profile answer names no user")))?;
    let (seen, id) = user_of(user)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s profile answer names no user")))?;
    let profile_url = LiteroticaSource::profile_url(&seen.username);
    let mut properties: Vec<(String, String)> = vec![("profile_url".into(), profile_url.clone())];
    if let Some(picture) = seen.avatar_url { properties.push(("avatar".into(), picture)); }
    let about = [text(user, "biography"), text(user, "bio")].into_iter().find(|t| !t.is_empty()).unwrap_or("");
    let about = blocks(about, &profile_url);
    if !about.is_empty() {
        if let Ok(json) = serde_json::to_string(&about) { properties.push(("about".into(), json)); }
    }
    let location = text(user, "location");
    if !location.is_empty() { properties.push(("location".into(), location.to_string())); }
    // The site answers 1970 for a join date it does not hold.
    let joined = normalize_date(text(user, "joindate"));
    if !joined.is_empty() && !joined.starts_with("1970") { properties.push(("joined".into(), joined)); }
    for (key, name) in [("stories_count", "stories"), ("series_count", "series"),
                        ("followers_count", "followers"), ("followings_count", "following")] {
        if let Some(n) = number(user, key) { properties.push((name.into(), n.to_string())); }
    }
    Ok((SourceUserProfile { source: SOURCE_ID.to_string(), source_id: seen.username.clone(), username: seen.username, properties }, id))
}

// ---------------------------------------------------------------------------
// Stories and series as works
// ---------------------------------------------------------------------------

/// A story's own tags: its category first, then what the author added.
fn tags_of(story: &Value) -> Vec<String> {
    let mut tags: Vec<String> = Vec::new();
    if let Some(category) = number(story, "category").and_then(super::search::category_name) {
        tags.push(category.to_string());
    }
    for tag in story.get("tags").and_then(Value::as_array).into_iter().flatten() {
        if number(tag, "is_banned").unwrap_or(0) != 0 { continue }
        let name = text(tag, "tag");
        if !name.is_empty() && !tags.iter().any(|t| t.eq_ignore_ascii_case(name)) { tags.push(name.to_string()); }
    }
    tags
}

fn rating_of(story: &Value) -> Rating {
    if number(story, "category") == Some(NON_EROTIC) { Rating::NotRated } else { Rating::Explicit }
}

/// The series a story is a part of, when it is one: the record the site
/// attaches (an empty list for a story on its own).
fn series_of(story: &Value) -> Option<&Value> {
    let series = story.get("series")?;
    let series = if series.is_array() { series.get(0)? } else { series };
    series_id(series).map(|_| series)
}

fn series_id(series: &Value) -> Option<u64> {
    series.get("meta").and_then(|m| number(m, "id")).or_else(|| number(series, "id"))
}

fn blank_summary(external_id: String, url: String, title: String) -> WorkSummary {
    WorkSummary {
        id: 0,
        source: SOURCE_ID.to_string(),
        external_id,
        url,
        title,
        authors: Vec::new(),
        author_ids: Vec::new(),
        fandoms: Vec::new(),
        rating: Rating::Explicit,
        warnings: Vec::new(),
        categories: Vec::new(),
        relationships: Vec::new(),
        characters: Vec::new(),
        tags: Vec::new(),
        summary: String::new(),
        word_count: None,
        chapter_count: 0,
        total_chapters: None,
        kudos: None,
        hits: None,
        bookmarks: None,
        comments: None,
        date_published: String::new(),
        date_updated: String::new(),
        language: String::new(),
        complete: false,
        status: String::new(),
        series: Vec::new(),
        fetched_at: String::new(),
    }
}

/// A story on its own, as a work of one chapter.
fn story_work(story: &Value) -> Option<ListedWork> {
    let (slug, title) = (text(story, "url"), text(story, "title"));
    if slug.is_empty() || title.is_empty() { return None }
    let author = author_of(story).map(|(user, _)| user);
    let published = normalize_date(text(story, "date_approve"));
    let mut summary = blank_summary(slug.to_string(), LiteroticaSource::story_url(slug), title.to_string());
    summary.authors = author.iter().map(|a| a.username.clone()).collect();
    summary.rating = rating_of(story);
    summary.tags = tags_of(story);
    summary.summary = text(story, "description").to_string();
    summary.word_count = number(story, "words_count");
    summary.chapter_count = 1;
    summary.total_chapters = Some(1);
    summary.comments = number(story, "comment_count").map(|n| n as u32);
    summary.date_published = published.clone();
    summary.date_updated = published;
    summary.language = language_name(number(story, "language"));
    summary.complete = true;
    let mut stats = Vec::new();
    let votes = number(story, "rate_count").unwrap_or(0);
    if let Some(average) = decimal(story, "rate_all").filter(|a| *a > 0.0 && votes > 0) {
        stats.push(SourceStat::num(crate::source::STAT_SITE_RATING, "Rating", average, 1));
        stats.push(SourceStat::num("rating_count", "Ratings", votes as f64, 2));
    }
    if let Some(n) = number(story, "view_count") { stats.push(SourceStat::num("views", "Views", n as f64, 3)); }
    if let Some(n) = number(story, "favorite_count") { stats.push(SourceStat::num("favorites", "Favorites", n as f64, 4)); }
    Some(ListedWork { summary, stats, authors: author.into_iter().collect() })
}

/// A series as a listing shows it: named on one of its parts. The part
/// lends its author and tags; its own figures are not the series'.
fn series_blurb(story: &Value, series: &Value) -> Option<ListedWork> {
    let id = series_id(series)?;
    let meta = series.get("meta").unwrap_or(series);
    let title = text(meta, "title");
    if title.is_empty() { return None }
    let author = author_of(story).map(|(user, _)| user);
    let parts = meta.get("order").and_then(Value::as_array).map(Vec::len)
        .or_else(|| series.get("items").and_then(Value::as_array).map(Vec::len))
        .unwrap_or(0);
    let mut summary = blank_summary(LiteroticaSource::series_key(id), LiteroticaSource::series_url(id), title.to_string());
    summary.authors = author.iter().map(|a| a.username.clone()).collect();
    summary.rating = rating_of(story);
    summary.tags = tags_of(story);
    summary.summary = text(story, "description").to_string();
    summary.chapter_count = parts as u32;
    summary.date_published = normalize_date(text(meta, "created_at"));
    summary.date_updated = normalize_date(text(meta, "updated_at"));
    summary.language = language_name(number(story, "language"));
    Some(ListedWork { summary, stats: Vec::new(), authors: author.into_iter().collect() })
}

/// One listed story as the work it belongs to: its series when it is a
/// part of one, else itself.
fn listed(story: &Value) -> Option<ListedWork> {
    match series_of(story) {
        Some(series) => series_blurb(story, series),
        None => story_work(story),
    }
}

/// The users a listing names, with the site's numbers for them.
pub fn listed_users(body: &str) -> Vec<(String, u64)> {
    let Ok(v) = serde_json::from_str::<Value>(body.trim()) else { return Vec::new() };
    v.get("data").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|story| author_of(story).and_then(|(user, id)| id.map(|id| (user.username, id))))
        .collect()
}

/// A page of stories — search results (`meta.total`, `meta.pageSize`) or
/// an author's list (`last_page`). Parts of one series are listed once,
/// as the series. `page` is the page that was asked for. The site counts
/// stories, not works, so only a search states its total.
pub fn parse_listing(body: &str, page: u32, counted: bool) -> Result<ListingPage, AppError> {
    let v = json(body, "story list")?;
    let stories = v.get("data").and_then(Value::as_array)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story list has no stories")))?;
    let mut seen = HashSet::new();
    let works: Vec<ListedWork> = stories.iter()
        .filter(|s| matches!(text(s, "type"), "" | "story"))
        .filter_map(listed)
        .filter(|w| seen.insert(w.summary.external_id.clone()))
        .collect();
    let (total_pages, total) = match v.get("meta") {
        Some(meta) => {
            let total = number(meta, "total").unwrap_or(0);
            let size = number(meta, "pageSize").unwrap_or(50).max(1);
            (total.div_ceil(size).max(1) as u32, Some(total as u32))
        }
        None => (number(&v, "last_page").unwrap_or(1).max(1) as u32, number(&v, "total").map(|n| n as u32)),
    };
    Ok(ListingPage { works, has_next: page.max(1) < total_pages, total_pages, total_works: if counted { total } else { None } })
}

/// One page of a story's text, with the story's record.
#[derive(Debug, Clone)]
pub struct StoryPage {
    /// The site's number for the story.
    pub id: u64,
    pub slug: String,
    pub title: String,
    /// The story as a work of its own.
    pub work: ListedWork,
    /// The series the story is a part of.
    pub series: Option<u64>,
    /// This page's text, as the site stores it.
    pub text: String,
    /// How many pages the site splits the story into.
    pub pages: u32,
}

pub fn parse_story(body: &str) -> Result<StoryPage, AppError> {
    let v = json(body, "story")?;
    let story = v.get("submission").filter(|s| s.is_object())
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story answer has no story")))?;
    let work = story_work(story)
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story answer has no title or address")))?;
    let id = number(story, "id")
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s story answer has no id")))?;
    Ok(StoryPage {
        id,
        slug: work.summary.external_id.clone(),
        title: work.summary.title.clone(),
        series: series_of(story).and_then(series_id),
        text: v.get("pageText").and_then(Value::as_str).unwrap_or("").to_string(),
        pages: v.get("meta").and_then(|m| number(m, "pages_count")).unwrap_or(1).max(1) as u32,
        work,
    })
}

#[derive(Debug, Clone)]
pub struct SeriesPage {
    pub work: ListedWork,
    /// One chapter per part, in the series' order, without text.
    pub chapters: Vec<Chapter>,
    /// Each part's number with its address name.
    pub stories: Vec<(u64, String)>,
}

/// "in_progress" → "In progress".
fn state_words(state: &str) -> String {
    let words = state.replace('_', " ");
    let mut letters = words.chars();
    match letters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + letters.as_str(),
        None => String::new(),
    }
}

/// A series as one work: its own record, and its parts as chapters.
pub fn parse_series(record: &str, parts: &str) -> Result<SeriesPage, AppError> {
    let v = json(record, "series")?;
    let series = v.get("data").filter(|d| d.is_object())
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s series answer has no series")))?;
    let (id, title) = (number(series, "id"), text(series, "title"));
    let Some(id) = id.filter(|_| !title.is_empty()) else {
        return Err(AppError::ParseError(format!("{NAME}'s series answer has no id or title")));
    };
    let listed = json(parts, "series parts")?;
    let stories: Vec<&Value> = listed.as_array()
        .or_else(|| listed.get("data").and_then(Value::as_array))
        .ok_or_else(|| AppError::ParseError(format!("{NAME}'s series answer has no parts")))?
        .iter().filter(|s| number(s, "id").is_some() && !text(s, "title").is_empty()).collect();

    let author = series.get("user").and_then(user_of).map(|(user, _)| user)
        .or_else(|| stories.first().and_then(|s| author_of(s)).map(|(user, _)| user));
    // Categories in the order the parts use them, then the tags most
    // parts carry.
    let mut tags: Vec<String> = Vec::new();
    let mut counted: Vec<(String, usize)> = Vec::new();
    for story in &stories {
        let mut own = tags_of(story).into_iter();
        if number(story, "category").and_then(super::search::category_name).is_some() {
            if let Some(category) = own.next() {
                if !tags.contains(&category) { tags.push(category); }
            }
        }
        for tag in own {
            match counted.iter_mut().find(|(t, _)| t.eq_ignore_ascii_case(&tag)) {
                Some((_, n)) => *n += 1,
                None => counted.push((tag, 1)),
            }
        }
    }
    counted.sort_by(|a, b| b.1.cmp(&a.1));
    for (tag, _) in counted.into_iter().take(SERIES_TAGS) {
        if !tags.iter().any(|t| t.eq_ignore_ascii_case(&tag)) { tags.push(tag); }
    }

    let state = text(series, "state");
    let complete = matches!(state, "completed" | "complete" | "finished");
    let (description, introduction) = (text(series, "description"), text(series, "introduction"));
    let words: u64 = stories.iter().filter_map(|s| number(s, "words_count")).sum();
    let mut summary = blank_summary(LiteroticaSource::series_key(id), LiteroticaSource::series_url(id), title.to_string());
    summary.authors = author.iter().map(|a| a.username.clone()).collect();
    summary.rating = if !stories.is_empty() && stories.iter().all(|s| rating_of(s) == Rating::NotRated) { Rating::NotRated }
                     else { Rating::Explicit };
    summary.tags = tags;
    summary.summary = match (description.is_empty(), introduction.is_empty()) {
        (false, false) if description != introduction => format!("{description}\n\n{introduction}"),
        (true, _) => introduction.to_string(),
        _ => description.to_string(),
    };
    summary.word_count = (words > 0).then_some(words);
    summary.chapter_count = stories.len() as u32;
    summary.total_chapters = complete.then_some(stories.len() as u32);
    summary.comments = number(series, "comments_count").map(|n| n as u32);
    summary.date_published = normalize_date(text(series, "created_at"));
    summary.date_updated = normalize_date(text(series, "modified_at"));
    summary.language = language_name(number(series, "language"));
    summary.complete = complete;
    summary.status = state_words(state);
    let mut stats = Vec::new();
    if let Some(n) = number(series, "view_count") { stats.push(SourceStat::num("views", "Views", n as f64, 3)); }
    if let Some(n) = number(series, "favorites_count") { stats.push(SourceStat::num("favorites", "Favorites", n as f64, 4)); }
    if !summary.status.is_empty() {
        stats.push(SourceStat { key: "status".into(), label: "Status".into(), num: None, text: Some(summary.status.clone()), order: 6 });
    }
    let chapters = stories.iter().enumerate().map(|(i, story)| Chapter {
        id: number(story, "id"),
        title: Some(text(story, "title").to_string()),
        number: i as u32 + 1,
        content: Vec::new(),
        notes_before: None,
        notes_after: None,
    }).collect();
    let named = stories.iter()
        .filter_map(|s| Some((number(s, "id")?, text(s, "url").to_string())).filter(|(_, slug)| !slug.is_empty()))
        .collect();
    Ok(SeriesPage { work: ListedWork { summary, stats, authors: author.into_iter().collect() }, chapters, stories: named })
}

// ---------------------------------------------------------------------------
// The account: who is signed in, and how long the sign-in's token lasts
// ---------------------------------------------------------------------------

/// The first record in `v`, at any depth, that names a user.
fn named_user(v: &Value) -> Option<&Value> {
    match v {
        Value::Object(fields) => {
            if !text(v, "username").is_empty() { return Some(v) }
            fields.values().find_map(named_user)
        }
        Value::Array(items) => items.iter().find_map(named_user),
        _ => None,
    }
}

/// Who the site's session answer says is signed in, with the site's
/// number for them. None when it names no one.
pub fn parse_session(body: &str) -> Option<(SessionIdentity, Option<u64>)> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    let user = named_user(&v)?;
    let username = text(user, "username").to_string();
    Some((SessionIdentity { external_id: username.clone(), username }, number(user, "userid").or_else(|| number(user, "id"))))
}

/// A sign-in token's own statement (its middle part, base64url JSON).
fn token_claims(token: &str) -> Option<Value> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let part = token.split('.').nth(1)?;
    let (mut bytes, mut held, mut bits) = (Vec::with_capacity(part.len()), 0u32, 0u32);
    for c in part.bytes().filter(|c| *c != b'=') {
        // The site may hand the token out in either base64 alphabet.
        let c = match c { b'+' => b'-', b'/' => b'_', other => other };
        let value = ALPHABET.iter().position(|a| *a == c)? as u32;
        held = (held << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((held >> bits) as u8);
            held &= (1 << bits) - 1;
        }
    }
    serde_json::from_slice(&bytes).ok()
}

/// When a sign-in token stops being accepted (seconds since 1970), when
/// it says.
pub fn token_expiry(token: &str) -> Option<u64> {
    number(&token_claims(token)?, "exp")
}

/// Who a sign-in token says it was issued to, when it names them.
pub fn token_identity(token: &str) -> Option<(SessionIdentity, Option<u64>)> {
    let claims = token_claims(token)?;
    let user = named_user(&claims)?;
    let username = text(user, "username").to_string();
    Some((SessionIdentity { external_id: username.clone(), username }, number(user, "userid").or_else(|| number(user, "id"))))
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

/// A date the site gives as seconds since 1970 → "2026-03-09".
fn day_of(seconds: u64) -> String {
    chrono::DateTime::from_timestamp(seconds as i64, 0).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn comment_of(v: &Value, story_url: &str, chapter: Option<u64>) -> Option<Comment> {
    let id = number(v, "id")?;
    let author = v.get("author").filter(|a| a.is_object()).and_then(user_of).map(|(user, _)| user)
        .unwrap_or_else(|| AO3User {
            source: SOURCE_ID.to_string(), id: String::new(), username: "Anonymous".to_string(),
            profile_url: None, avatar_url: None,
        });
    // A comment's own heading, when it has one, opens it.
    let (title, body) = (text(v, "title"), text(v, "text"));
    let mut content = Vec::new();
    if !title.is_empty() {
        content.push(ContentBlock::Paragraph {
            text: vec![crate::models::InlineContent::Bold { content: vec![crate::models::InlineContent::Text { value: title.to_string() }] }],
        });
    }
    content.extend(blocks(body, story_url));
    Some(Comment {
        id,
        author,
        posted_at: number(v, "date").map(day_of).unwrap_or_default(),
        content,
        replies: Vec::new(),
        chapter_label: None,
        chapter_id: chapter,
        notice: None,
        more_replies: 0,
        rating: None,
    })
}

/// One page of a story's comments, newest first as the site lists them.
/// `chapter` is the story's number when it is a part of a series.
pub fn parse_comments(body: &str, page: u32, story_url: &str, chapter: Option<u64>) -> Result<CommentsPage, AppError> {
    let v = json(body, "comments")?;
    let comments = v.get("data").and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|c| comment_of(c, story_url, chapter)).collect())
        .unwrap_or_default();
    let meta = v.get("meta");
    Ok(CommentsPage {
        comments,
        current_page: meta.and_then(|m| number(m, "current_page")).map(|n| n as u32).unwrap_or(page).max(1),
        total_pages: meta.and_then(|m| number(m, "last_page")).map(|n| n as u32).unwrap_or(1).max(1),
    })
}

/// The number the site gave a comment it just accepted.
pub fn posted_comment_id(body: &str) -> Option<u64> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    v.get("comment").and_then(|c| number(c, "id")).or_else(|| number(&v, "id"))
}

/// What the site says in a refusal: its JSON message, or the plain text
/// it answered with.
pub fn refusal(body: &str) -> Option<String> {
    if let Some(said) = message(body) { return Some(said) }
    let plain = body.trim();
    (!plain.is_empty() && plain.len() <= 200 && !plain.starts_with(['<', '{', '['])).then(|| plain.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::InlineContent;

    const HIT_ALONE: &str = r#"{
        "author": {"userid": 4410, "username": "Saltwick", "userpic": "https://uploads.example/4410_default.jpg", "stories_count": 3},
        "authorname": "Saltwick", "category": 38, "category_info": {"type": "story", "pageUrl": "science-fiction-fantasy"},
        "comment_count": 4, "date_approve": "03/09/2024", "description": "A keeper counts the tides.",
        "favorite_count": 12, "id": 900117, "language": 1, "rate_all": 4.52, "rate_count": 31,
        "tags": [{"id": 1, "tag": "lighthouse", "is_banned": 0}, {"id": 2, "tag": "hidden", "is_banned": 1}, {"id": 3, "tag": "sea", "is_banned": 0}],
        "title": "The Tide Ledger", "type": "story", "url": "the-tide-ledger", "view_count": 2210, "series": [], "words_count": 5120
    }"#;

    fn part(id: u64, n: u32) -> String {
        format!(r#"{{
            "author": {{"userid": 5120, "username": "Marrowmere", "userpic": "https://speedy.example/imagesv2/da_default.jpg"}},
            "authorname": "Marrowmere", "category": 15, "comment_count": 2, "date_approve": "01/0{n}/2025",
            "description": "Part {n} of the orchard.", "favorite_count": 5, "id": {id}, "language": 1,
            "rate_all": 4.1, "rate_count": 9, "tags": [{{"id": 9, "tag": "orchard", "is_banned": 0}}, {{"id": 10, "tag": "part {n}", "is_banned": 0}}],
            "title": "The Glass Orchard Pt. 0{n}", "type": "story", "url": "the-glass-orchard-pt-0{n}", "view_count": 800, "words_count": 3000,
            "series": {{"meta": {{"id": 77001, "title": "The Glass Orchard", "url": "", "created_at": "01/01/2025", "updated_at": "01/02/2025", "order": [800201, 800202]}},
                        "items": [{{"id": 800201, "title": "The Glass Orchard Pt. 01", "url": "the-glass-orchard-pt-01"}},
                                  {{"id": 800202, "title": "The Glass Orchard Pt. 02", "url": "the-glass-orchard-pt-02"}}]}}
        }}"#)
    }

    #[test]
    fn dates() {
        assert_eq!(normalize_date("07/25/2006"), "2006-07-25");
        assert_eq!(normalize_date("2022-11-20T13:39:49Z"), "2022-11-20");
        assert_eq!(normalize_date(" 18 Years Ago "), "18 Years Ago");
        assert_eq!(normalize_date(""), "");
    }

    #[test]
    fn a_search_page_lists_stories_and_each_series_once() {
        let body = format!(r#"{{"data": [{HIT_ALONE}, {}, {}], "meta": {{"pageSize": 50, "total": 120}}}}"#, part(800201, 1), part(800202, 2));
        let page = parse_listing(&body, 1, true).unwrap();
        assert_eq!((page.works.len(), page.total_pages, page.has_next, page.total_works), (2, 3, true, Some(120)));

        let alone = &page.works[0];
        assert_eq!(alone.summary.external_id, "the-tide-ledger");
        assert_eq!(alone.summary.url, "https://www.literotica.com/s/the-tide-ledger");
        assert_eq!(alone.summary.authors, vec!["Saltwick"]);
        assert_eq!(alone.summary.tags, vec!["Sci-Fi & Fantasy", "lighthouse", "sea"]);
        assert_eq!((alone.summary.word_count, alone.summary.chapter_count, alone.summary.total_chapters), (Some(5120), 1, Some(1)));
        assert_eq!((alone.summary.date_published.as_str(), alone.summary.language.as_str(), alone.summary.complete), ("2024-03-09", "English", true));
        assert_eq!((alone.summary.comments, &alone.summary.rating), (Some(4), &Rating::Explicit));
        let stat = |key: &str| alone.stats.iter().find(|s| s.key == key).and_then(|s| s.num);
        assert_eq!((stat("rating"), stat("rating_count"), stat("views"), stat("favorites")), (Some(4.52), Some(31.0), Some(2210.0), Some(12.0)));
        assert_eq!(alone.authors[0].id, "Saltwick");
        assert_eq!(alone.authors[0].profile_url.as_deref(), Some("https://www.literotica.com/authors/Saltwick"));
        assert!(alone.authors[0].avatar_url.is_some());

        let series = &page.works[1];
        assert_eq!(series.summary.external_id, "se:77001");
        assert_eq!(series.summary.url, "https://www.literotica.com/series/se/77001");
        assert_eq!((series.summary.title.as_str(), series.summary.chapter_count, series.summary.total_chapters), ("The Glass Orchard", 2, None));
        assert_eq!((series.summary.date_published.as_str(), series.summary.date_updated.as_str()), ("2025-01-01", "2025-01-02"));
        assert!(series.summary.word_count.is_none() && series.stats.is_empty(), "a part's figures are not the series'");
        assert!(series.authors[0].avatar_url.is_none(), "the site's placeholder picture is no avatar");
        assert_eq!(listed_users(&body), vec![("Saltwick".to_string(), 4410), ("Marrowmere".to_string(), 5120), ("Marrowmere".to_string(), 5120)]);
    }

    #[test]
    fn an_authors_list_pages_by_last_page_and_states_no_total() {
        let body = format!(r#"{{"current_page": 2, "last_page": 2, "total": 51, "per_page": 50, "data": [{HIT_ALONE}]}}"#);
        let page = parse_listing(&body, 2, false).unwrap();
        assert_eq!((page.works.len(), page.total_pages, page.has_next, page.total_works), (1, 2, false, None));
        let empty = parse_listing(r#"{"data": [], "meta": {"pageSize": 50, "total": 0}}"#, 1, true).unwrap();
        assert_eq!((empty.works.len(), empty.total_pages, empty.has_next, empty.total_works), (0, 1, false, Some(0)));
    }

    #[test]
    fn refusals_and_non_json_are_errors() {
        let refused = parse_listing(r#"{"success": false, "message": "The selected sort is invalid."}"#, 1, true);
        assert!(matches!(refused, Err(AppError::ParseError(m)) if m.contains("The selected sort is invalid.")));
        assert!(parse_listing("<html>Just a moment...</html>", 1, true).is_err());
        assert!(parse_story(r#"{"meta": {"pages_count": 1}}"#).is_err());
        assert_eq!(message(r#"{"success": false, "message": "User not found"}"#).as_deref(), Some("User not found"));
        assert_eq!(message("not json"), None);
    }

    #[test]
    fn a_story_page_carries_its_text_and_page_count() {
        let body = format!(r#"{{"meta": {{"pages_count": 3}}, "submission": {HIT_ALONE}, "pageText": "One.\r\n\r\nTwo."}}"#);
        let page = parse_story(&body).unwrap();
        assert_eq!((page.id, page.slug.as_str(), page.title.as_str(), page.pages, page.series), (900117, "the-tide-ledger", "The Tide Ledger", 3, None));
        assert_eq!(page.text, "One.\r\n\r\nTwo.");
        let in_series = format!(r#"{{"meta": {{}}, "submission": {}, "pageText": ""}}"#, part(800202, 2));
        let page = parse_story(&in_series).unwrap();
        assert_eq!((page.series, page.pages), (Some(77001), 1));
    }

    #[test]
    fn story_text_becomes_paragraphs() {
        let raw = "First line.\r\nSame paragraph, <em>stressed</em>.\r\n\r\n\r\n<p align=\"center\"><strong>* * *</strong></p>\r\n\r\nSee <a href=\"/s/another-story\">this</a>.";
        assert_eq!(paragraphs(raw), "<p>First line.<br>Same paragraph, <em>stressed</em>.</p><p align=\"center\"><strong>* * *</strong></p><p>See <a href=\"/s/another-story\">this</a>.</p>");
        let out = blocks(raw, "https://www.literotica.com/s/the-tide-ledger");
        assert_eq!(out.len(), 3);
        let ContentBlock::Paragraph { text, .. } = &out[0] else { panic!("a paragraph") };
        assert!(text.iter().any(|i| matches!(i, InlineContent::LineBreak)));
        assert!(text.iter().any(|i| matches!(i, InlineContent::Italic { .. })));
        let ContentBlock::Paragraph { text, .. } = &out[2] else { panic!("a paragraph") };
        assert!(text.iter().any(|i| matches!(i, InlineContent::Link { href, .. } if href == "https://www.literotica.com/s/another-story")));
        assert!(blocks("  \r\n\r\n ", "https://www.literotica.com/").is_empty());
    }

    #[test]
    fn a_series_is_one_work_with_its_parts_as_chapters() {
        let record = r#"{"success": true, "data": {"id": 77001, "user_id": 5120, "title": "The Glass Orchard", "language": 1,
            "state": "in_progress", "description": "An orchard of glass.", "introduction": "Two gardeners tend it.",
            "created_at": "2025-01-01T08:00:00Z", "modified_at": "2025-01-02T09:30:00Z",
            "view_count": 4100, "comments_count": 17, "favorites_count": 33, "work_count": 2,
            "user": {"userid": 5120, "username": "Marrowmere", "userpic": "https://uploads.example/5120_default.jpg"}}}"#;
        let parts = format!("[{}, {}]", part(800201, 1), part(800202, 2));
        let page = parse_series(record, &parts).unwrap();
        let s = &page.work.summary;
        assert_eq!((s.external_id.as_str(), s.title.as_str(), s.url.as_str()), ("se:77001", "The Glass Orchard", "https://www.literotica.com/series/se/77001"));
        assert_eq!(s.summary, "An orchard of glass.\n\nTwo gardeners tend it.");
        assert_eq!((s.word_count, s.chapter_count, s.total_chapters, s.complete, s.status.as_str()), (Some(6000), 2, None, false, "In progress"));
        assert_eq!((s.date_published.as_str(), s.date_updated.as_str(), s.comments), ("2025-01-01", "2025-01-02", Some(17)));
        assert_eq!(s.tags, vec!["Romance", "orchard", "part 1", "part 2"]);
        assert_eq!(s.authors, vec!["Marrowmere"]);
        assert!(page.work.stats.iter().all(|st| st.key != "rating"), "a series has no rating of its own");
        assert_eq!(page.chapters.iter().map(|c| (c.id, c.number, c.title.as_deref())).collect::<Vec<_>>(), vec![
            (Some(800201), 1, Some("The Glass Orchard Pt. 01")), (Some(800202), 2, Some("The Glass Orchard Pt. 02")),
        ]);
        assert!(page.chapters.iter().all(|c| c.content.is_empty()));
        assert!(parse_series(r#"{"success": false, "message": "Not Found"}"#, "[]").is_err());
    }

    #[test]
    fn a_page_of_comments() {
        let body = r#"{"meta": {"current_page": 2, "last_page": 7, "total": 33, "per_page": 5}, "data": [
            {"id": 9100412, "date": 1773014400, "rate": 0, "type": 0, "title": "", "text": "Kept me up.\n\nWorth it.",
             "author": {"userid": 6031, "username": "Fennholt", "userpic": "https://uploads.example/6031.jpg"}},
            {"id": 9100398, "date": 1772928000, "title": "A thought", "text": "More, please.", "author": null},
            {"date": 1772928000, "text": "no id"}
        ]}"#;
        let page = parse_comments(body, 2, "https://www.literotica.com/s/the-tide-ledger", Some(900117)).unwrap();
        assert_eq!((page.current_page, page.total_pages, page.comments.len()), (2, 7, 2));
        let first = &page.comments[0];
        assert_eq!((first.id, first.author.username.as_str(), first.posted_at.as_str(), first.chapter_id),
                   (9100412, "Fennholt", "2026-03-09", Some(900117)));
        assert_eq!(first.content.len(), 2);
        let second = &page.comments[1];
        assert_eq!((second.author.username.as_str(), second.author.profile_url.is_none()), ("Anonymous", true));
        assert!(matches!(&second.content[0], ContentBlock::Paragraph { text } if matches!(&text[0], InlineContent::Bold { .. })));
        let empty = parse_comments(r#"{"data": []}"#, 1, "", None).unwrap();
        assert_eq!((empty.comments.len(), empty.current_page, empty.total_pages), (0, 1, 1));
        assert_eq!(posted_comment_id(r#"{"comment": {"id": 9100500}, "date": 1773014400}"#), Some(9100500));
        assert_eq!(posted_comment_id("OK"), None);
    }

    #[test]
    fn the_session_and_the_token_name_the_reader() {
        let (who, id) = parse_session(r#"{"user": {"userid": 7044, "username": "Quillmoor", "userpic": ""}, "settings": {}}"#).unwrap();
        assert_eq!((who.external_id.as_str(), who.username.as_str(), id), ("Quillmoor", "Quillmoor", Some(7044)));
        assert!(parse_session(r#"{"settings": {"theme": "dark"}}"#).is_none());
        assert!(parse_session("Unauthorized.").is_none());
        // {"exp":4102444800,"user":{"id":7044,"username":"Quillmoor"}}
        let token = "eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDAsInVzZXIiOnsiaWQiOjcwNDQsInVzZXJuYW1lIjoiUXVpbGxtb29yIn19.sig";
        assert_eq!(token_expiry(token), Some(4_102_444_800));
        let (who, id) = token_identity(token).unwrap();
        assert_eq!((who.username.as_str(), id), ("Quillmoor", Some(7044)));
        assert_eq!(token_expiry("not-a-token"), None);
        assert_eq!(token_expiry("a.!!!.c"), None);
    }

    #[test]
    fn refusals_are_read_as_the_site_words_them() {
        assert_eq!(refusal(r#"{"success": false, "message": "voting is closed"}"#).as_deref(), Some("voting is closed"));
        assert_eq!(refusal("Your password or username are invalid").as_deref(), Some("Your password or username are invalid"));
        assert_eq!(refusal("<html><body>error</body></html>"), None);
        assert_eq!(refusal("  "), None);
    }

    #[test]
    fn profiles_and_member_search() {
        let body = r#"{"success": true, "user": {"userid": 5120, "username": "Marrowmere", "userpic": "https://uploads.example/5120_default.jpg",
            "bio": "", "biography": "I write about orchards.\n\nAnd glass.", "location": "Nowhere", "joindate": "01/01/1970",
            "stories_count": 14, "series_count": 2, "followers_count": 120, "followings_count": 3}}"#;
        let (profile, id) = parse_profile(body).unwrap();
        assert_eq!((profile.source_id.as_str(), profile.username.as_str(), id), ("Marrowmere", "Marrowmere", Some(5120)));
        assert_eq!(profile.property("profile_url"), Some("https://www.literotica.com/authors/Marrowmere"));
        assert_eq!((profile.property("stories"), profile.property("series"), profile.property("followers"), profile.property("following")),
                   (Some("14"), Some("2"), Some("120"), Some("3")));
        assert_eq!((profile.property("location"), profile.property("joined")), (Some("Nowhere"), None));
        let about: Vec<ContentBlock> = serde_json::from_str(profile.property("about").unwrap()).unwrap();
        assert_eq!(about.len(), 2);
        assert!(parse_profile(r#"{"success": false, "message": "User not found"}"#).is_err());

        let members = parse_members(r#"{"data": [{"userid": 5120, "username": "Marrowmere", "userpic": ""}, {"userid": 9, "username": ""}],
                                        "meta": {"pageSize": 50, "total": 2}}"#).unwrap();
        assert_eq!(members.len(), 1);
        assert_eq!((members[0].0.id.as_str(), members[0].1), ("Marrowmere", Some(5120)));
    }
}
