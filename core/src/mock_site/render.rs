//! AO3-shaped HTML for the synthetic archive. Every template mirrors the
//! markup the parser selectors in `crate::parser` expect (the same shapes
//! the fixtures under core/tests/fixtures use), so the real parsers run
//! unchanged over mock pages.

use super::data::*;
use super::state::{MockState, PostedComment};

pub const CSRF_TOKEN: &str = "MOCK-CSRF-TOKEN-0000000000000000000000000000";
pub const FORM_TOKEN: &str = "MOCK-FORM-TOKEN-00000000000000000000000000000";
pub const USER_ICON: &str = "/images/skins/iconsets/default/icon_user.png";

pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// AO3's tag-path encoding (see client::helpers::ao3_tag_encode).
pub fn tag_path(tag: &str) -> String {
    tag.replace('/', "*s*").replace('&', "*a*").replace('.', "*d*").replace(' ', "%20")
}

fn tag_link(tag: &str) -> String {
    format!("<a class=\"tag\" href=\"/tags/{}/works\">{}</a>", tag_path(tag), esc(tag))
}

fn commas(tags: &[&str]) -> String {
    tags.iter().map(|t| format!("<li>{}</li>", tag_link(t))).collect::<Vec<_>>().join("")
}

pub fn with_commas(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 { out.push(','); }
        out.push(c);
    }
    out
}

/// "2025-06-30" → "30 Jun 2025" (blurb date format).
pub fn blurb_date(iso: &str) -> String {
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let parts: Vec<&str> = iso.split('-').collect();
    if parts.len() != 3 { return iso.to_string(); }
    let m: usize = parts[1].parse().unwrap_or(1);
    format!("{} {} {}", parts[2], MONTHS[(m.max(1) - 1) % 12], parts[0])
}

fn rating_class(r: &str) -> &'static str {
    match r {
        "General Audiences" => "rating-general-audience",
        "Teen And Up Audiences" => "rating-teen",
        "Mature" => "rating-mature",
        "Explicit" => "rating-explicit",
        _ => "rating-notrated",
    }
}

fn warning_class(w: &str) -> &'static str {
    match w {
        "No Archive Warnings Apply" => "warning-no",
        "Creator Chose Not To Use Archive Warnings" => "warning-choosenotto",
        _ => "warning-yes",
    }
}

fn category_class(c: &str) -> &'static str {
    match c {
        "Gen" => "category-gen", "F/M" => "category-het", "M/M" => "category-slash",
        "F/F" => "category-femslash", "Multi" => "category-multi", _ => "category-other",
    }
}

fn author_link(a: &Author) -> String {
    format!("<a rel=\"author\" href=\"/users/{}/pseuds/{}\">{}</a>", a.user, pseud_of(a), esc(&byline(a)))
}

fn chapters_stat(w: &Work) -> String {
    match w.total { Some(t) => format!("{}/{}", w.chapters, t), None => format!("{}/?", w.chapters) }
}

// ---------------------------------------------------------------------------
// Page chrome
// ---------------------------------------------------------------------------

/// A full document: csrf meta, the signed-in greeting when there is a
/// viewer, and `#main` wrapping `body`.
pub fn page(title: &str, main_class: &str, body: &str, state: &MockState) -> String {
    let greeting = match &state.viewer {
        Some(v) => format!(r#"<header id="header" class="region"><nav id="greeting" aria-label="User"><ul class="user navigation actions"><li class="dropdown"><a href="/users/{v}">Hi, {v}!</a></li><li><a rel="nofollow" data-method="delete" href="/users/logout">Log Out</a></li></ul></nav></header>"#),
        None => r#"<header id="header" class="region"><nav id="login" aria-label="Log in"><a href="/users/login">Log In</a></nav></header>"#.to_string(),
    };
    let body_class = if state.viewer.is_some() { "logged-in" } else { "logged-out" };
    format!(
        "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"/><title>{} [Mock Archive]</title>\
         <meta name=\"csrf-param\" content=\"authenticity_token\"/><meta name=\"csrf-token\" content=\"{CSRF_TOKEN}\"/></head>\
         <body class=\"{body_class}\"><div id=\"outer\" class=\"wrapper\">{greeting}<div id=\"inner\" class=\"wrapper\">\
         <div id=\"main\" class=\"{main_class}\" role=\"main\">{}</div></div></div></body></html>",
        esc(title), body)
}

pub fn pagination(base: &str, page: u32, total: u32) -> String {
    if total <= 1 { return String::new(); }
    let sep = if base.contains('?') { "&" } else { "?" };
    let mut out = String::from("<ol class=\"pagination actions\" role=\"navigation\">");
    if page > 1 {
        out.push_str(&format!("<li class=\"previous\" title=\"previous\"><a rel=\"prev\" href=\"{base}{sep}page={}\">← Previous</a></li>", page - 1));
    } else {
        out.push_str("<li class=\"previous\" title=\"previous\"><span class=\"disabled\">← Previous</span></li>");
    }
    for p in 1..=total {
        if p == page {
            out.push_str(&format!("<li><span class=\"current\">{p}</span></li>"));
        } else {
            out.push_str(&format!("<li><a href=\"{base}{sep}page={p}\">{p}</a></li>"));
        }
    }
    if page < total {
        out.push_str(&format!("<li class=\"next\" title=\"next\"><a rel=\"next\" href=\"{base}{sep}page={}\">Next →</a></li>", page + 1));
    } else {
        out.push_str("<li class=\"next\" title=\"next\"><span class=\"disabled\">Next →</span></li>");
    }
    out.push_str("</ol>");
    out
}

// ---------------------------------------------------------------------------
// Work blurbs and listings
// ---------------------------------------------------------------------------

/// One `li.work.blurb`. `href_prefix` nests the title link under a
/// collection path when non-empty.
pub fn blurb(idx: usize, href_prefix: &str) -> String {
    let w = &WORKS[idx];
    let a = &AUTHORS[w.author];
    let complete = w.total.is_some_and(|t| w.chapters >= t);
    let fandoms = w.fandoms.iter().map(|f| tag_link(f)).collect::<Vec<_>>().join("\n");
    let mut tags = String::new();
    for r in w.relationships { tags.push_str(&format!("<li class=\"relationships\">{}</li>", tag_link(r))); }
    for c in w.characters { tags.push_str(&format!("<li class=\"characters\">{}</li>", tag_link(c))); }
    for t in w.tags { tags.push_str(&format!("<li class=\"freeforms\">{}</li>", tag_link(t))); }
    let warning = w.warnings.first().copied().unwrap_or("No Archive Warnings Apply");
    let category = w.categories.first().copied().unwrap_or("Gen");
    format!(r#"
<li id="work_{id}" class="work blurb group" role="article">
  <div class="header module">
    <h4 class="heading">
      <a href="{href_prefix}/works/{id}">{title}</a>
      by
      {author}
    </h4>
    <h5 class="fandoms heading"><span class="landmark">Fandoms:</span> {fandoms}</h5>
    <ul class="required-tags">
      <li><a class="help symbol question modal"><span class="{rating_class} rating" title="{rating}"><span class="text">{rating}</span></span></a></li>
      <li><a class="help symbol question modal"><span class="{warning_class} warnings" title="{warning}"><span class="text">{warning}</span></span></a></li>
      <li><a class="help symbol question modal"><span class="{category_class} category" title="{category}"><span class="text">{category}</span></span></a></li>
      <li><a class="help symbol question modal"><span class="{complete_class} iswip" title="{complete_title}"><span class="text">{complete_title}</span></span></a></li>
    </ul>
    <p class="datetime">{date}</p>
  </div>
  <h6 class="landmark heading">Tags</h6>
  <ul class="tags commas">{tags}</ul>
  <h6 class="landmark heading">Summary</h6>
  <blockquote class="userstuff summary"><p>{summary}</p></blockquote>
  <dl class="stats">
    <dt class="language">Language:</dt><dd class="language" lang="en">English</dd>
    <dt class="words">Words:</dt><dd class="words">{words}</dd>
    <dt class="chapters">Chapters:</dt><dd class="chapters">{chapters}</dd>
    <dt class="comments">Comments:</dt><dd class="comments"><a href="/works/{id}?show_comments=true">{comments}</a></dd>
    <dt class="kudos">Kudos:</dt><dd class="kudos"><a href="/works/{id}#kudos">{kudos}</a></dd>
    <dt class="bookmarks">Bookmarks:</dt><dd class="bookmarks"><a href="/works/{id}/bookmarks">{bookmarks}</a></dd>
    <dt class="hits">Hits:</dt><dd class="hits">{hits}</dd>
  </dl>
</li>"#,
        id = w.id, title = esc(w.title), author = author_link(a),
        rating = esc(w.rating), rating_class = rating_class(w.rating),
        warning = esc(warning), warning_class = warning_class(warning),
        category = esc(category), category_class = category_class(category),
        complete_class = if complete { "complete-yes" } else { "complete-no" },
        complete_title = if complete { "Complete Work" } else { "Work in Progress" },
        date = blurb_date(w.updated), summary = esc(w.summary),
        words = with_commas(word_count(idx)), chapters = chapters_stat(w),
        comments = super::comments::comment_total(idx), kudos = with_commas(w.kudos as u64),
        bookmarks = w.bookmarks, hits = with_commas(w.hits))
}

pub const PAGE_SIZE: usize = 5;

/// One page of blurbs plus pagination. `heading` is the page's h2/h3 html.
pub fn listing(heading: &str, works: &[usize], page: u32, base: &str, href_prefix: &str) -> String {
    let total_pages = ((works.len() + PAGE_SIZE - 1) / PAGE_SIZE).max(1) as u32;
    let page = page.max(1);
    let start = ((page - 1) as usize) * PAGE_SIZE;
    let slice = if start < works.len() { &works[start..(start + PAGE_SIZE).min(works.len())] } else { &[] };
    let items = slice.iter().map(|&i| blurb(i, href_prefix)).collect::<String>();
    let pager = pagination(base, page, total_pages);
    format!("{heading}\n{pager}\n<ol class=\"work index group\">{items}</ol>\n{pager}")
}

/// "1 - 5 of 12 Works …" / "3 Works …" heading as AO3 words it.
pub fn range_heading(count: usize, page: u32, suffix: &str) -> String {
    if count > PAGE_SIZE {
        let start = ((page.max(1) - 1) as usize) * PAGE_SIZE + 1;
        let end = (start + PAGE_SIZE - 1).min(count);
        format!("<h2 class=\"heading\">{start} - {end} of {count} Works {suffix}</h2>")
    } else {
        format!("<h2 class=\"heading\">{count} Works {suffix}</h2>")
    }
}

// ---------------------------------------------------------------------------
// Work page
// ---------------------------------------------------------------------------

/// Chapter body paragraphs with inline markup sprinkled in deterministically.
pub fn chapter_body(idx: usize, chapter: u32) -> String {
    let w = &WORKS[idx];
    let mut rng = Lcg::new(w.id * 7 + chapter as u64 * 13);
    let mut out = String::new();
    for (i, p) in chapter_paragraphs(idx, chapter).iter().enumerate() {
        let mut text = esc(p);
        match rng.below(9) {
            0 => { // emphasise the first clause
                if let Some(pos) = text.find(',') { text = format!("<em>{}</em>{}", &text[..pos], &text[pos..]); }
            }
            1 => { if let Some(pos) = text.find('.') { text = format!("<strong>{}</strong>{}", &text[..pos + 1], &text[pos + 1..]); } }
            2 => { text = format!("{text} <a href=\"/works/{}\">(see the companion piece)</a>", WORKS[(idx + 1) % WORKS.len()].id); }
            _ => {}
        }
        out.push_str(&format!("<p>{text}</p>\n"));
        if i == 2 && rng.below(3) == 0 {
            out.push_str("<blockquote><p>A note pinned to the chart room door, in a hand nobody recognised.</p></blockquote>\n");
        }
        if i == 4 && rng.below(4) == 0 {
            out.push_str("<hr/>\n<ul><li>the winding key</li><li>the ledger</li><li>the second key, which nobody mentions</li></ul>\n");
        }
        if i == 1 && w.image_chapter == Some(chapter) {
            out.push_str(&format!("<p><img src=\"/images/mock/long-table-{}.png\" alt=\"The long table, set for thirty\"/></p>\n", w.id));
        }
    }
    out
}

fn series_dd(idx: usize) -> String {
    let m = memberships(idx);
    if m.is_empty() { return String::new(); }
    let spans = m.iter().map(|&(si, part)| {
        let s = &SERIES[si];
        let pos = (part - 1) as usize;
        let mut span = format!("<span class=\"series\"><span class=\"position\">Part {part} of <a href=\"/series/{}\">{}</a></span>", s.id, esc(s.title));
        if pos > 0 {
            span.push_str(&format!("<span class=\"divider\">, </span><a class=\"previous\" href=\"/works/{}\">&#171; Previous Work</a>", WORKS[s.works[pos - 1]].id));
        }
        if pos + 1 < s.works.len() {
            span.push_str(&format!("<span class=\"divider\">, </span><a class=\"next\" href=\"/works/{}\">Next Work &#187;</a>", WORKS[s.works[pos + 1]].id));
        }
        span.push_str("</span>");
        span
    }).collect::<String>();
    format!("<dt class=\"series\">Series:</dt><dd class=\"series\">{spans}</dd>")
}

/// The subscribe/unsubscribe form for a target, in whichever state the
/// viewer has it. Empty when signed out (AO3 shows no form then).
pub fn subscription_form(state: &MockState, kind: &str, target: &str) -> String {
    let Some(viewer) = &state.viewer else { return String::new() };
    match state.subscription(kind, target) {
        Some(sid) => format!(r#"<form class="ajax-create-destroy" id="edit_subscription_{sid}" data-create-value="Subscribe" data-destroy-value="Unsubscribe" action="/users/{viewer}/subscriptions/{sid}" accept-charset="UTF-8" method="post"><input type="hidden" name="_method" value="delete"/><input type="hidden" name="authenticity_token" value="{FORM_TOKEN}"/><input type="submit" name="commit" value="Unsubscribe"/></form>"#),
        None => format!(r#"<form class="ajax-create-destroy" id="new_subscription" data-create-value="Subscribe" data-destroy-value="Unsubscribe" action="/users/{viewer}/subscriptions" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{FORM_TOKEN}"/><input type="hidden" name="subscription[subscribable_id]" value="{target}"/><input type="hidden" name="subscription[subscribable_type]" value="{kind}"/><input type="submit" name="commit" value="Subscribe"/></form>"#),
    }
}

/// The work page. `full` renders every chapter (?view_full_work=true);
/// otherwise just `chapter` (1 by default), as AO3 does.
pub fn work_page(idx: usize, full: bool, chapter: u32, state: &MockState, comments_html: &str) -> String {
    let w = &WORKS[idx];
    let a = &AUTHORS[w.author];
    let complete = w.total.is_some_and(|t| w.chapters >= t);
    let status_row = if complete && w.chapters > 1 {
        format!("<dt class=\"status\">Completed:</dt><dd class=\"status\">{}</dd>", w.updated)
    } else if w.chapters > 1 {
        format!("<dt class=\"status\">Updated:</dt><dd class=\"status\">{}</dd>", w.updated)
    } else { String::new() };
    let meta = format!(r#"
<dl class="work meta group">
  <dt class="rating tags">Rating:</dt><dd class="rating tags"><ul class="commas">{rating}</ul></dd>
  <dt class="warning tags">Archive Warning:</dt><dd class="warning tags"><ul class="commas">{warnings}</ul></dd>
  <dt class="category tags">Category:</dt><dd class="category tags"><ul class="commas">{categories}</ul></dd>
  <dt class="fandom tags">Fandom:</dt><dd class="fandom tags"><ul class="commas">{fandoms}</ul></dd>
  <dt class="relationship tags">Relationship:</dt><dd class="relationship tags"><ul class="commas">{relationships}</ul></dd>
  <dt class="character tags">Characters:</dt><dd class="character tags"><ul class="commas">{characters}</ul></dd>
  <dt class="freeform tags">Additional Tags:</dt><dd class="freeform tags"><ul class="commas">{tags}</ul></dd>
  <dt class="language">Language:</dt><dd class="language" lang="en">English</dd>
  {series}
  <dt class="stats">Stats:</dt>
  <dd class="stats"><dl class="stats">
    <dt class="published">Published:</dt><dd class="published">{published}</dd>
    {status_row}
    <dt class="words">Words:</dt><dd class="words">{words}</dd>
    <dt class="chapters">Chapters:</dt><dd class="chapters">{chapters}</dd>
    <dt class="comments">Comments:</dt><dd class="comments">{comments}</dd>
    <dt class="kudos">Kudos:</dt><dd class="kudos"><a href="/works/{id}#kudos">{kudos}</a></dd>
    <dt class="bookmarks">Bookmarks:</dt><dd class="bookmarks"><a href="/works/{id}/bookmarks">{bookmarks}</a></dd>
    <dt class="hits">Hits:</dt><dd class="hits">{hits}</dd>
  </dl></dd>
</dl>"#,
        rating = commas(&[w.rating]), warnings = commas(w.warnings), categories = commas(w.categories),
        fandoms = commas(w.fandoms), relationships = commas(w.relationships), characters = commas(w.characters),
        tags = commas(w.tags), series = series_dd(idx), published = w.published, status_row = status_row,
        words = with_commas(word_count(idx)), chapters = chapters_stat(w),
        comments = super::comments::comment_total(idx), id = w.id,
        kudos = with_commas(w.kudos as u64 + if state.kudos.contains(&w.id) { 1 } else { 0 }),
        bookmarks = w.bookmarks, hits = with_commas(w.hits));

    let one_chapter = |n: u32| -> String {
        let notes_before = if n == 1 {
            "<div id=\"notes\" class=\"notes module\" role=\"complementary\"><h3 class=\"heading\">Notes:</h3><blockquote class=\"userstuff\"><p>Thank you for reading. Comments are answered, slowly.</p></blockquote></div>"
        } else { "" };
        let notes_after = if Some(n) == w.total && n == w.chapters {
            "<div class=\"end notes module\" role=\"complementary\"><h3 class=\"heading\">Notes:</h3><blockquote class=\"userstuff\"><p>That is the end. The tide keeps going.</p></blockquote></div>"
        } else { "" };
        format!(r#"
<div id="chapter-{n}" class="chapter">
  <div class="chapter preface group" role="complementary">
    <h3 class="title"><a href="/works/{id}/chapters/{cid}">Chapter {n}</a>: {title}</h3>
    {notes_before}
  </div>
  <div class="userstuff module" role="article">
    <h3 class="landmark heading" id="work">Chapter Text</h3>
    {body}
  </div>
  {notes_after}
</div>"#, id = w.id, cid = chapter_id(idx, n), title = esc(chapter_title(idx, n)), body = chapter_body(idx, n))
    };

    let chapters_html = if w.chapters == 1 {
        format!("<div id=\"chapters\" role=\"article\" class=\"userstuff module\"><h3 class=\"landmark heading\" id=\"work\">Work Text:</h3>{}</div>",
                chapter_body(idx, 1))
    } else if full {
        format!("<div id=\"chapters\">{}</div>", (1..=w.chapters).map(one_chapter).collect::<String>())
    } else {
        format!("<div id=\"chapters\">{}</div>", one_chapter(chapter.clamp(1, w.chapters)))
    };

    // Kudos list: a few readers, plus the viewer once they have left kudos.
    let mut names: Vec<String> = READERS.iter().take(3 + (idx % 3)).map(|s| s.to_string()).collect();
    if state.kudos.contains(&w.id) {
        if let Some(v) = &state.viewer { names.insert(0, v.clone()); }
    }
    let kudos_links = names.iter().map(|n| format!("<a href=\"/users/{n}\">{n}</a>")).collect::<Vec<_>>().join(", ");
    let comment_form = match &state.viewer {
        Some(_) => format!(r#"<form class="new_comment" id="comment_for_{id}" action="/works/{id}/comments" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{FORM_TOKEN}"/><input type="hidden" name="comment[pseud_id]" value="{pseud}"/><textarea id="comment_content_for_{id}" name="comment[comment_content]"></textarea><input type="submit" name="commit" value="Comment"/></form>"#,
                           id = w.id, pseud = state.viewer_pseud_id()),
        None => format!(r#"<form class="new_comment" action="/works/{id}/comments" method="post"><textarea id="comment_content_for_{id}" name="comment[comment_content]"></textarea></form>"#, id = w.id),
    };
    let body = format!(r#"
<div class="wrapper">
  {meta}
  <ul class="work navigation actions" role="navigation"><li>{sub_form}</li></ul>
  <div id="workskin">
    <div class="preface group">
      <h2 class="title heading">{title}</h2>
      <h3 class="byline heading">{author}</h3>
      <div class="summary module" role="complementary"><h3 class="heading">Summary:</h3><blockquote class="userstuff"><p>{summary}</p></blockquote></div>
    </div>
    {chapters}
  </div>
  <div id="feedback" class="feedback">
    <div id="kudos"><p class="kudos">{kudos_links} left kudos on this work!</p></div>
    <div id="comments_placeholder">{comments_html}</div>
    {comment_form}
  </div>
</div>"#,
        meta = meta, sub_form = subscription_form(state, "Work", &w.id.to_string()),
        title = esc(w.title), author = author_link(a), summary = esc(w.summary),
        chapters = chapters_html, kudos_links = kudos_links, comment_form = comment_form);
    page(&format!("{} - {} - {}", w.title, byline(a), w.fandoms[0]), "works-show region", &body, state)
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct RenderComment {
    pub id: u64,
    pub user: Option<String>,
    pub guest: String,
    pub date: String,
    pub text: String,
    pub chapter: Option<(u64, u64, u32)>,
    pub parent: Option<u64>,
    pub replies: Vec<RenderComment>,
}

fn comment_li(c: &RenderComment) -> String {
    let byline = match &c.user {
        Some(u) => format!("<a href=\"/users/{u}/pseuds/{u}\" rel=\"nofollow\">{u}</a>", u = esc(u)),
        None => format!("{} <span class=\"role\">(Guest)</span>", esc(&c.guest)),
    };
    let parent_span = match c.chapter {
        Some((work, cid, n)) => format!(" <span class=\"parent\">on <a href=\"/works/{work}/chapters/{cid}\">Chapter {n}</a></span>"),
        None => String::new(),
    };
    let parent_actions = match c.parent {
        Some(p) => format!("<li><a href=\"/comments/{p}#comment_{p}\">Parent Comment</a></li><li><a href=\"/comments/{p}#comments\">Parent Thread</a></li>"),
        None => String::new(),
    };
    let replies = if c.replies.is_empty() { String::new() } else {
        format!("<ol class=\"thread\">{}</ol>", c.replies.iter().map(comment_li).collect::<String>())
    };
    let paragraphs = c.text.lines().filter(|l| !l.trim().is_empty())
        .map(|l| format!("<p>{}</p>", esc(l))).collect::<String>();
    format!(r#"
<li class="comment group" id="comment_{id}" role="article">
  <div class="comment">
    <div class="icon"><img alt="" class="icon" src="{USER_ICON}"/></div>
    <h4 class="heading byline">{byline}{parent_span}</h4>
    <span class="posted datetime"><span class="date">{date}</span></span>
    <blockquote class="userstuff">{paragraphs}</blockquote>
    <ul class="actions" role="menu">{parent_actions}<li><a href="/comments/{id}/comments#comments">Reply</a></li></ul>
  </div>
  {replies}
</li>"#, id = c.id, date = c.date)
}

/// An `ol.thread` of top-level comments with pagination. `base` is the
/// pagination URL (without `page`).
pub fn comments_fragment(comments: &[RenderComment], page: u32, total_pages: u32, base: &str) -> String {
    let items = comments.iter().map(comment_li).collect::<String>();
    format!("<ol class=\"thread\">{items}</ol>\n{}", pagination(base, page, total_pages))
}

pub fn posted_to_render(p: &PostedComment, viewer: &str, chapter: Option<(u64, u64, u32)>) -> RenderComment {
    RenderComment {
        id: p.id, user: Some(viewer.to_string()), guest: String::new(),
        date: p.date.clone(), text: p.text.clone(), chapter, parent: p.parent, replies: Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

fn moderation_links(state: &MockState, target: &str) -> String {
    let Some(me) = &state.viewer else { return String::new() };
    let block = match state.moderation("blocked", target) {
        Some(rid) => format!("<li><a href=\"/users/{me}/blocked/users/{rid}/confirm_unblock\">Unblock</a></li>"),
        None => format!("<li><a href=\"/users/{me}/blocked/users/confirm_block?blocked_id={target}\">Block</a></li>"),
    };
    let mute = match state.moderation("muted", target) {
        Some(rid) => format!("<li><a href=\"/users/{me}/muted/users/{rid}/confirm_unmute\">Unmute</a></li>"),
        None => format!("<li><a href=\"/users/{me}/muted/users/confirm_mute?muted_id={target}\">Mute</a></li>"),
    };
    block + &mute
}

/// /users/{name}/profile. Catalog authors get their works and bio; any
/// other name (the viewer, a reader) gets an empty profile.
pub fn user_profile(user: &str, state: &MockState) -> String {
    let author = author_index(user).map(|i| &AUTHORS[i]);
    let name = author.map(|a| a.user).unwrap_or(user);
    let numeric = author.map(|a| a.numeric_id).unwrap_or_else(|| 92_000_000 + (user.len() as u64 * 7919) % 100_000);
    let works = author_index(user).map(|ai| WORKS.iter().filter(|w| w.author == ai).count()).unwrap_or(0);
    let series = author_index(user).map(|ai| SERIES.iter().filter(|s| s.works.iter().any(|&w| WORKS[w].author == ai)).count()).unwrap_or(0);
    let bookmarks = state.bookmarks_of(user).len();
    let pseuds = match author {
        Some(a) => { let mut v = vec![a.user]; if let Some(p) = a.pseud { v.push(p); } v }
        None => vec![name],
    };
    let pseud_links = pseuds.iter().map(|p| format!("<a href=\"/users/{name}/pseuds/{p}\">{p}</a>")).collect::<Vec<_>>().join(", ");
    let joined = author.map(|a| a.joined).unwrap_or("2022-06-01");
    let bio = author.map(|a| a.bio).filter(|b| !b.is_empty())
        .map(|b| format!("<div class=\"bio module\"><h3 class=\"heading\">Bio:</h3><blockquote class=\"userstuff\"><p>{}</p></blockquote></div>", esc(b)))
        .unwrap_or_default();
    let body = format!(r#"
<div id="dashboard" class="region" role="navigation region">
  <ul class="navigation actions">
    <li><a href="/users/{name}/works">Works ({works})</a></li>
    <li><a href="/users/{name}/series">Series ({series})</a></li>
    <li><a href="/users/{name}/bookmarks">Bookmarks ({bookmarks})</a></li>
    <li><a href="/users/{name}/collections">Collections ({collections})</a></li>
    <li><a href="/users/{name}/gifts">Gifts (0)</a></li>
  </ul>
</div>
<div class="user home profile">
  <div class="primary header module">
    <h2 class="heading">{name}</h2>
    <p class="icon"><a href="/users/{name}"><img alt="" class="icon" src="{USER_ICON}"/></a></p>
    <ul class="navigation actions" role="navigation"><li>{sub_form}</li>{moderation}</ul>
  </div>
  <div class="wrapper">
    <dl class="meta">
      <dt class="pseuds">My pseuds:</dt><dd class="pseuds">{pseud_links}</dd>
      <dt>I joined on:</dt><dd>{joined}</dd>
      <dt>My user ID is:</dt><dd>{numeric}</dd>
    </dl>
  </div>
  {bio}
</div>"#,
        collections = COLLECTIONS.iter().filter(|c| c.owners.iter().any(|&o| AUTHORS[o].user == name)).count(),
        sub_form = subscription_form(state, "User", &numeric.to_string()),
        moderation = moderation_links(state, name));
    // The dashboard sidebar sits outside #main on AO3; the parser only
    // needs `#dashboard a[href]`, so keep it inside the page body.
    page(&format!("{name} - Profile"), "profile-show dashboard region", &body, state)
}

/// /users/{me}/subscriptions — one `dl.subscription` per record.
pub fn subscriptions_page(state: &MockState) -> String {
    let me = state.viewer.clone().unwrap_or_default();
    let rows = state.subs.iter().map(|s| {
        let link = match s.kind.as_str() {
            "Work" => work_index(s.target.parse().unwrap_or(0))
                .map(|i| format!("<a href=\"/works/{}\">{}</a>", WORKS[i].id, esc(WORKS[i].title)))
                .unwrap_or_else(|| format!("<a href=\"/works/{}\">Work {}</a>", s.target, s.target)),
            "Series" => series_index(s.target.parse().unwrap_or(0))
                .map(|i| format!("<a href=\"/series/{}\">{}</a>", SERIES[i].id, esc(SERIES[i].title)))
                .unwrap_or_else(|| format!("<a href=\"/series/{}\">Series {}</a>", s.target, s.target)),
            _ => {
                let user = AUTHORS.iter().find(|a| a.numeric_id.to_string() == s.target)
                    .map(|a| a.user.to_string()).unwrap_or_else(|| s.target.clone());
                format!("<a href=\"/users/{user}\">{user}</a>")
            }
        };
        format!(r#"<dl class="subscription"><dt>{link}</dt><dd><form action="/users/{me}/subscriptions/{sid}" method="post"><input type="hidden" name="_method" value="delete"/><input type="hidden" name="authenticity_token" value="{FORM_TOKEN}"/><input type="submit" value="Unsubscribe"/></form></dd></dl>"#, sid = s.id)
    }).collect::<String>();
    let body = format!("<h2 class=\"heading\">{}'s Subscriptions</h2><div class=\"subscription index group\">{rows}</div>", me);
    page("Subscriptions", "subscriptions-index region", &body, state)
}

/// /users/{me}/inbox — a few comments addressed to the viewer.
pub fn inbox_page(state: &MockState) -> String {
    let items: Vec<(u64, &str, usize, u32, &str, &str, bool)> = vec![
        (super::comments::comment_id(0, 1, 0), READERS[0], 0, 1, "2026-10-30", COMMENT_TEXT[0], true),
        (super::comments::comment_id(3, 2, 1), READERS[2], 3, 2, "2026-10-28", COMMENT_TEXT[7], true),
        (super::comments::comment_id(9, 1, 0), READERS[4], 9, 1, "2026-10-21", COMMENT_TEXT[2], false),
    ];
    let unread = items.iter().filter(|i| i.6).count();
    let lis = items.iter().map(|(id, user, widx, ch, date, text, is_unread)| {
        let w = &WORKS[*widx];
        format!(r#"<li class="comment group{unread}" id="feedback_comment_{id}" role="article">
  <div class="icon"><img alt="" class="icon" src="{USER_ICON}"/></div>
  <h4 class="heading byline"><a href="/users/{user}/pseuds/{user}">{user}</a> on <a href="/works/{wid}/chapters/{cid}">{title}</a></h4>
  <span class="posted datetime"><span class="date">{date}</span></span>
  <blockquote class="userstuff"><p>{text}</p></blockquote>
  <ul class="actions"><li><a href="/comments/{id}">Reply</a></li></ul>
</li>"#, unread = if *is_unread { " unread" } else { "" }, wid = w.id, cid = chapter_id(*widx, *ch),
            title = esc(w.title), text = esc(text))
    }).collect::<String>();
    let body = format!("<h2 class=\"heading\">My Inbox ({} comments, {unread} unread)</h2><ol class=\"comment index group\">{lis}</ol>", items.len());
    page("Inbox", "inbox-index region", &body, state)
}

/// /users/{me}/blocked/users and /users/{me}/muted/users.
pub fn moderation_index(state: &MockState, kind: &str) -> String {
    let me = state.viewer.clone().unwrap_or_default();
    let (list, tail, verb) = if kind == "blocked" { (&state.blocked, "confirm_unblock", "Unblock") } else { (&state.muted, "confirm_unmute", "Unmute") };
    let lis = list.iter().map(|(user, rid)| format!(
        "<li><a href=\"/users/{user}\">{user}</a> <a href=\"/users/{me}/{kind}/users/{rid}/{tail}\">{verb}</a></li>"
    )).collect::<String>();
    let body = format!("<h2 class=\"heading\">{} Users</h2><ul class=\"index group\">{lis}</ul>",
                       if kind == "blocked" { "Blocked" } else { "Muted" });
    page("Moderation", "users-index region", &body, state)
}

/// /users/login — the form `login()` would scrape a token from.
pub fn login_page(state: &MockState) -> String {
    let body = format!(r#"<form id="new_user" action="/users/login" method="post"><input type="hidden" name="authenticity_token" value="{FORM_TOKEN}"/><input name="user[login]"/><input name="user[password]" type="password"/><input type="submit" name="commit" value="Log In"/></form>"#);
    page("Log In", "sessions-new region", &body, state)
}

pub fn home_page(state: &MockState) -> String {
    page("Mock Archive", "home region", "<h2 class=\"heading\">A synthetic archive for testing this app while the real one is away.</h2>", state)
}

// ---------------------------------------------------------------------------
// Bookmarks
// ---------------------------------------------------------------------------

pub struct RenderBookmark {
    pub id: u64,
    pub work_idx: Option<usize>,
    pub series_idx: Option<usize>,
    pub bookmarker: String,
    pub date: String,
    pub tags: Vec<String>,
    pub note: String,
    pub rec: bool,
}

fn bookmark_li(b: &RenderBookmark) -> String {
    let header = match (b.work_idx, b.series_idx) {
        (Some(wi), _) => {
            // The work blurb's own body, with the bookmark's li wrapper instead.
            let full = blurb(wi, "");
            let inner = full.trim().trim_start_matches(|c| c != '>').trim_start_matches('>');
            inner.trim_end_matches("</li>").to_string()
        }
        (None, Some(si)) => {
            let s = &SERIES[si];
            let a = &AUTHORS[WORKS[s.works[0]].author];
            format!("<div class=\"header module\"><h4 class=\"heading\"><a href=\"/series/{}\">{}</a> by {}</h4><p class=\"datetime\">{}</p></div>",
                    s.id, esc(s.title), author_link(a), blurb_date(WORKS[s.works[0]].updated))
        }
        (None, None) => String::new(),
    };
    let tags = if b.tags.is_empty() { String::new() } else {
        format!("<h6 class=\"landmark heading\">Bookmark Tags:</h6><ul class=\"meta tags commas\">{}</ul>",
                b.tags.iter().map(|t| format!("<li><a class=\"tag\" href=\"/tags/{}/bookmarks\">{}</a></li>", tag_path(t), esc(t))).collect::<String>())
    };
    let rec = if b.rec { format!("<p class=\"status\"><a class=\"rec\" href=\"/bookmarks/{}\"><span class=\"text\">Rec</span></a></p>", b.id) } else { String::new() };
    let note = if b.note.is_empty() { String::new() } else {
        format!("<blockquote class=\"userstuff notes\">{}</blockquote>",
                b.note.lines().filter(|l| !l.trim().is_empty()).map(|l| format!("<p>{}</p>", esc(l))).collect::<String>())
    };
    format!(r#"
<li id="bookmark_{id}" class="bookmark blurb group" role="article">
  {header}
  <div class="own user module group">
    <h5 class="byline heading">Bookmarked by <a href="/users/{user}/pseuds/{user}">{user}</a></h5>
    <p class="datetime">{date}</p>
    {tags}
    {rec}
    {note}
  </div>
</li>"#, id = b.id, user = esc(&b.bookmarker), date = blurb_date(&b.date))
}

pub fn bookmarks_listing(heading: &str, items: &[RenderBookmark], page: u32, base: &str) -> String {
    let total_pages = ((items.len() + PAGE_SIZE - 1) / PAGE_SIZE).max(1) as u32;
    let page = page.max(1);
    let start = ((page - 1) as usize) * PAGE_SIZE;
    let slice = if start < items.len() { &items[start..(start + PAGE_SIZE).min(items.len())] } else { &[] };
    let lis = slice.iter().map(bookmark_li).collect::<String>();
    let pager = pagination(base, page, total_pages);
    format!("{heading}\n{pager}\n<ol class=\"bookmark index group\">{lis}</ol>\n{pager}")
}

/// /bookmarks/{id} — the page AO3 shows for one bookmark (the delete
/// POST scrapes its token here).
pub fn bookmark_page(b: &RenderBookmark, state: &MockState) -> String {
    let body = format!("<ol class=\"bookmark index group\">{}</ol><form action=\"/bookmarks/{}\" method=\"post\"><input type=\"hidden\" name=\"authenticity_token\" value=\"{FORM_TOKEN}\"/></form>",
                       bookmark_li(b), b.id);
    page("Bookmark", "bookmarks-show region", &body, state)
}

// ---------------------------------------------------------------------------
// Series and collections
// ---------------------------------------------------------------------------

pub fn series_page(si: usize, page_no: u32, state: &MockState) -> String {
    let s = &SERIES[si];
    let words: u64 = s.works.iter().map(|&w| word_count(w)).sum();
    let complete = s.works.iter().all(|&w| WORKS[w].total.is_some_and(|t| WORKS[w].chapters >= t));
    let creators = {
        let mut seen: Vec<usize> = Vec::new();
        for &w in s.works { if !seen.contains(&WORKS[w].author) { seen.push(WORKS[w].author); } }
        seen.iter().map(|&a| author_link(&AUTHORS[a])).collect::<Vec<_>>().join(", ")
    };
    let body = format!(r#"
<h2 class="heading">{title}</h2>
<div class="wrapper">
  <dl class="series meta group">
    <dt>Creator:</dt><dd>{creators}</dd>
    <dt>Series Begun:</dt><dd>{begun}</dd>
    <dt>Series Updated:</dt><dd>{updated}</dd>
    <dt>Description:</dt><dd><blockquote class="userstuff"><p>{summary}</p></blockquote></dd>
    <dt class="stats">Stats:</dt><dd class="stats"><dl class="stats">
      <dt class="words">Words:</dt><dd class="words">{words}</dd>
      <dt class="works">Works:</dt><dd class="works">{count}</dd>
      <dt class="status">Complete:</dt><dd class="status">{complete}</dd>
    </dl></dd>
  </dl>
</div>
<ul class="navigation actions" role="navigation"><li>{sub_form}</li></ul>
{listing}"#,
        title = esc(s.title), begun = WORKS[s.works[0]].published,
        updated = s.works.iter().map(|&w| WORKS[w].updated).max().unwrap_or(""),
        summary = esc(s.summary), words = with_commas(words), count = s.works.len(),
        complete = if complete { "Yes" } else { "No" },
        sub_form = subscription_form(state, "Series", &s.id.to_string()),
        listing = listing("", s.works, page_no, &format!("/series/{}", s.id), ""));
    page(s.title, "series-show region", &body, state)
}

fn collection_blurb(ci: usize) -> String {
    let c = &COLLECTIONS[ci];
    let owners = c.owners.iter().map(|&o| format!("<a class=\"owner\" href=\"/users/{u}\">{u}</a>", u = AUTHORS[o].user)).collect::<Vec<_>>().join(", ");
    let tags = c.tags.iter().map(|t| tag_link(t)).collect::<Vec<_>>().join(" ");
    format!(r#"
<li class="collection picture blurb group" role="article">
  <div class="header module group">
    <h4 class="heading"><a href="/collections/{name}">{title}</a> <span class="name">({name})</span> by {owners}</h4>
    <div class="icon"><img alt="" class="icon" src="/images/skins/iconsets/default/icon_collection.png" width="100" height="100"/></div>
    <p class="datetime">{date}</p>
    <h5 class="tags heading"><span class="landmark">Collection Tags:</span> {tags}</h5>
  </div>
  <h6 class="landmark heading">Summary</h6>
  <blockquote class="userstuff summary"><p>{summary}</p></blockquote>
  <p class="type">{kind}</p>
  <dl class="stats">
    <dt class="works">Works:</dt><dd class="works"><a href="/collections/{name}/works">{works}</a></dd>
    <dt class="bookmarks">Bookmarked Items:</dt><dd class="bookmarks"><a href="/collections/{name}/bookmarks">{bookmarks}</a></dd>
  </dl>
</li>"#, name = c.name, title = esc(c.title), date = blurb_date(c.active_since), summary = esc(c.summary),
        kind = c.kind, works = c.works.len(), bookmarks = 1)
}

pub fn collections_index(indexes: &[usize], heading: &str, state: &MockState) -> String {
    let lis = indexes.iter().map(|&i| collection_blurb(i)).collect::<String>();
    let body = format!("<h2 class=\"heading\">{heading}</h2><ul class=\"collection picture index group\">{lis}</ul>");
    page("Collections", "collections-index filtered region", &body, state)
}

pub fn collection_works(ci: usize, page_no: u32, state: &MockState) -> String {
    let c = &COLLECTIONS[ci];
    let heading = format!("<h2 class=\"heading\">{} Works in {}</h2>", c.works.len(), esc(c.title));
    let body = listing(&heading, c.works, page_no, &format!("/collections/{}/works", c.name), &format!("/collections/{}", c.name));
    page(c.title, "works-index region", &body, state)
}

pub fn collection_profile(ci: usize, state: &MockState) -> String {
    let c = &COLLECTIONS[ci];
    let maintainers = c.owners.iter().enumerate().map(|(i, &o)| {
        let cls = if i == 0 { " class=\"owner\"" } else { "" };
        format!("<li{cls}><a href=\"/users/{u}\">{u}</a></li>", u = AUTHORS[o].user)
    }).collect::<String>();
    let tags = c.tags.iter().map(|t| format!("<li>{}</li>", tag_link(t))).collect::<String>();
    let body = format!(r#"
<div class="collection home profile">
  <div class="primary header module">
    <h2 class="heading"><a href="/collections/{name}">{title}</a></h2>
    <blockquote class="userstuff"><p>{summary}</p></blockquote>
    <p class="type">{kind}</p>
  </div>
  <h3 class="heading">About <span class="title">{title}</span> <span class="name">({name})</span></h3>
  <div class="wrapper"><dl class="meta group">
    <dt>Active since:</dt><dd>{since}</dd>
    <dt>Collection tags:</dt><dd><ul class="tags commas">{tags}</ul></dd>
    <dt class="maintainers">Maintainers:</dt><dd class="maintainers"><ul class="commas">{maintainers}</ul></dd>
  </dl></div>
</div>"#, name = c.name, title = esc(c.title), summary = esc(c.summary), kind = c.kind, since = c.active_since);
    page(c.title, "collection_profile-show dashboard region", &body, state)
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

/// A small flat-colour PNG (stored deflate, no compression library) so
/// image fetches return real, decodable bytes.
pub fn png(width: u32, height: u32, rgb: [u8; 3]) -> Vec<u8> {
    fn crc32(data: &[u8]) -> u32 {
        let mut crc = 0xFFFF_FFFFu32;
        for &b in data {
            crc ^= b as u32;
            for _ in 0..8 { crc = if crc & 1 != 0 { 0xEDB8_8320 ^ (crc >> 1) } else { crc >> 1 }; }
        }
        !crc
    }
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        let mut body = kind.to_vec();
        body.extend_from_slice(data);
        out.extend_from_slice(&body);
        out.extend_from_slice(&crc32(&body).to_be_bytes());
    }
    // Raw scanlines: filter byte 0 + RGB pixels.
    let mut raw = Vec::with_capacity((height * (1 + width * 3)) as usize);
    for y in 0..height {
        raw.push(0);
        for x in 0..width {
            // A soft diagonal band so the image is visibly "an image".
            let band = ((x + y) / 12) % 2 == 0;
            let px = if band { rgb } else { [rgb[0].saturating_sub(24), rgb[1].saturating_sub(24), rgb[2].saturating_sub(24)] };
            raw.extend_from_slice(&px);
        }
    }
    // zlib stream of stored (uncompressed) deflate blocks.
    let mut z = vec![0x78, 0x01];
    let mut pos = 0;
    while pos < raw.len() {
        let n = (raw.len() - pos).min(65535);
        let last = pos + n == raw.len();
        z.push(if last { 1 } else { 0 });
        z.extend_from_slice(&(n as u16).to_le_bytes());
        z.extend_from_slice(&(!(n as u16)).to_le_bytes());
        z.extend_from_slice(&raw[pos..pos + n]);
        pos += n;
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in &raw { a = (a + byte as u32) % 65521; b = (b + a) % 65521; }
    z.extend_from_slice(&((b << 16) | a).to_be_bytes());

    let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}
