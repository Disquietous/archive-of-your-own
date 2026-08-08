use scraper::{Html, Selector, ElementRef};

use crate::models::*;

use super::{sel, text, has_next_page};
use super::work_page::parse_element_children;

fn simple_hash(s: &str) -> u64 {
    let mut h: u64 = 5381;
    for b in s.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    h
}

/// AO3 renders comment timestamps as composite markup — separate spans for
/// day-of-week, date, month, year, time, and timezone. Assemble them into
/// one readable timestamp ("17 Jul 2026 03:12AM EDT"); when the pieces
/// aren't present, fall back to the container's whitespace-normalized text.
pub(super) fn parse_composite_datetime(el: &ElementRef) -> String {
    let piece = |selector: &str| {
        el.select(&sel(selector)).next().map(|e| text(&e)).filter(|t| !t.is_empty())
    };
    if let (Some(date), Some(month), Some(year)) =
        (piece("span.date"), piece("abbr.month"), piece("span.year")) {
        let mut out = format!("{date} {month} {year}");
        if let Some(time) = piece("span.time") {
            out.push(' ');
            out.push_str(&time);
        }
        if let Some(zone) = piece("abbr.timezone") {
            out.push(' ');
            out.push_str(&zone);
        }
        return out;
    }
    text(el).split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn parse_inbox(html: &str) -> InboxPage {
    let doc = Html::parse_document(html);

    // Extract unread count from heading: "My Inbox (16 comments, 3 unread)"
    let unread_count = doc.select(&sel("h2.heading")).next()
        .map(|h| {
            let t = text(&h);
            if let Some(pos) = t.find("unread") {
                let before = &t[..pos];
                before.rsplit(|c: char| !c.is_ascii_digit()).next()
                    .and_then(|s| s.trim().parse::<u32>().ok())
                    .unwrap_or(0)
            } else { 0 }
        })
        .unwrap_or(0);

    let mut items = Vec::new();
    let item_sel = sel("ol.comment.index li.comment");

    for li in doc.select(&item_sel) {
        let classes = li.value().attr("class").unwrap_or("");
        let is_unread = classes.contains("unread");

        // Comment ID from id="feedback_comment_XXXXXXX"
        let comment_id: u64 = li.value().attr("id").unwrap_or("")
            .trim_start_matches("feedback_comment_")
            .parse()
            .unwrap_or(0);
        if comment_id == 0 { continue; }

        // Author and work reference from h4.heading.byline
        let heading = li.select(&sel("h4.heading.byline")).next();
        let (author, author_url, work_reference, work_url) = if let Some(h) = heading {
            let links: Vec<ElementRef> = h.select(&sel("a")).collect();
            let author_name = links.first().map(|a| text(a)).unwrap_or_default();
            let author_href = links.first().and_then(|a| a.value().attr("href")).map(String::from);
            let work_ref = links.get(1).map(|a| text(a)).unwrap_or_default();
            let work_href = links.get(1).and_then(|a| a.value().attr("href")).map(String::from);
            (author_name, author_href, work_ref, work_href)
        } else {
            (String::new(), None, String::new(), None)
        };

        // Avatar
        let avatar_url = li.select(&sel("div.icon img")).next()
            .and_then(|img| img.value().attr("src"))
            .map(|s| {
                if s.starts_with('/') { format!("{}{s}", crate::client::BASE_URL) }
                else { s.to_string() }
            });

        // Date — composite spans assembled into one readable timestamp
        let posted_at = li.select(&sel("span.posted.datetime")).next()
            .map(|d| parse_composite_datetime(&d))
            .unwrap_or_default();

        // Content
        let content = li.select(&sel("blockquote.userstuff")).next()
            .map(|el| parse_element_children(&el))
            .unwrap_or_default();

        items.push(InboxItem {
            comment_id,
            author,
            author_url,
            avatar_url,
            work_reference,
            work_url,
            posted_at,
            is_unread,
            content,
        });
    }

    let has_next_page = has_next_page(html);

    InboxPage { items, unread_count, has_next_page }
}

pub fn parse_comments(html: &str) -> CommentsPage {
    let doc = Html::parse_document(html);
    let pagination_sel = sel("ol.pagination li");

    // Flat approach: find ALL li.comment elements, parse each, then build tree
    let comment_sel = sel("li.comment");
    let all_lis: Vec<ElementRef> = doc.select(&comment_sel).collect();
    log_debug!("comments", "Found {} li.comment elements in {} bytes", all_lis.len(), html.len());

    let mut flat: Vec<(Comment, Option<u64>)> = Vec::new();
    for li in &all_lis {
        if let Some((c, parent_id)) = parse_single_comment(li) {
            flat.push((c, parent_id));
        }
    }

    log_debug!("comments", "Parsed {} comments, building tree", flat.len());

    let comments = build_comment_tree(flat);

    // If document parsing found nothing, try fragment
    let comments = if comments.is_empty() {
        let frag = Html::parse_fragment(html);
        let frag_lis: Vec<ElementRef> = frag.select(&comment_sel).collect();
        let mut flat: Vec<(Comment, Option<u64>)> = Vec::new();
        for li in &frag_lis {
            if let Some((c, parent_id)) = parse_single_comment(li) {
                flat.push((c, parent_id));
            }
        }
        build_comment_tree(flat)
    } else {
        comments
    };

    let (current_page, total_pages) = parse_comment_pagination(&doc, &pagination_sel);

    CommentsPage { comments, current_page, total_pages }
}

fn build_comment_tree(flat: Vec<(Comment, Option<u64>)>) -> Vec<Comment> {
    use std::collections::HashMap;

    let ids: Vec<u64> = flat.iter().map(|(c, _)| c.id).collect();
    let mut comments_map: HashMap<u64, Comment> = HashMap::new();
    let mut parent_map: Vec<(u64, Option<u64>)> = Vec::new();

    for (c, parent_id) in flat {
        parent_map.push((c.id, parent_id));
        comments_map.insert(c.id, c);
    }

    // Process in reverse so children are ready before parents
    let mut children_map: HashMap<u64, Vec<Comment>> = HashMap::new();
    let mut top_level = Vec::new();

    for &(id, parent_id) in parent_map.iter().rev() {
        let mut comment = comments_map.remove(&id).unwrap();
        if let Some(children) = children_map.remove(&id) {
            comment.replies = children;
            comment.replies.reverse();
        }
        match parent_id {
            Some(pid) if ids.contains(&pid) => {
                children_map.entry(pid).or_default().push(comment);
            }
            _ => top_level.push(comment),
        }
    }

    top_level.reverse();
    top_level
}


/// Display name from a comment byline heading. Guest bylines have no
/// profile link — the name is a bare text node followed by a
/// "(Guest)" role span — and AO3 nests the posted datetime (and any
/// "on Chapter N" parent span) inside the same h4, so those subtrees
/// must be excluded from the name.
fn byline_display_name(h: &ElementRef) -> String {
    let mut raw = String::new();
    for child in h.children() {
        if let Some(el) = child.value().as_element() {
            let class = el.attr("class").unwrap_or("");
            if class.contains("posted") || class.contains("parent") {
                continue;
            }
        }
        if let Some(t) = child.value().as_text() {
            raw.push_str(t);
        } else if let Some(er) = ElementRef::wrap(child) {
            for t in er.text() {
                raw.push_str(t);
            }
        }
        raw.push(' ');
    }
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn parse_single_comment(li: &ElementRef) -> Option<(Comment, Option<u64>)> {
    let id_str = li.value().attr("id").unwrap_or("");
    let id: u64 = id_str.trim_start_matches("comment_").parse().unwrap_or(0);
    if id == 0 { return None; }

    let div_sel = sel("div.comment");
    let div = li.select(&div_sel).next()
        .or_else(|| Some(*li))?;

    // Avatar
    let avatar_url = div.select(&sel("img.icon")).next()
        .or_else(|| li.select(&sel("img.icon")).next())
        .or_else(|| div.select(&sel("img[src*='avatar']")).next())
        .and_then(|img| img.value().attr("src"))
        .map(|s| {
            if s.starts_with("//") { format!("https:{s}") }
            else if s.starts_with('/') { format!("{}{s}", crate::client::BASE_URL) }
            else { s.to_string() }
        });

    let heading = div.select(&sel("h4.byline")).next()
        .or_else(|| div.select(&sel("h4.heading")).next());

    let (username, profile_url) = if let Some(h) = heading {
        let link_sel = sel("a");
        if let Some(a) = h.select(&link_sel).next() {
            let name = text(&a);
            let href = a.value().attr("href").unwrap_or("").to_string();
            (name, if href.is_empty() { None } else { Some(href) })
        } else {
            (byline_display_name(&h), None)
        }
    } else {
        ("Anonymous".to_string(), None)
    };

    // Stable user ID: for registered users use the username from their profile path,
    // for guests use a hash of their display name
    let user_id = if let Some(ref url) = profile_url {
        url.rsplit('/').next().unwrap_or(&username).to_string()
    } else {
        format!("guest:{:x}", simple_hash(&username))
    };

    let author = AO3User {
        id: user_id,
        username,
        profile_url,
        avatar_url,
    };

    let posted_at = div.select(&sel("span.posted")).next()
        .map(|d| parse_composite_datetime(&d))
        .unwrap_or_default();

    let body_sel = sel("blockquote.userstuff");
    let content = if let Some(body) = div.select(&body_sel).next() {
        parse_element_children(&body)
    } else {
        Vec::new()
    };

    // Extract parent comment ID from this comment's own actions ul (direct child of div,
    // not from nested reply comments)
    let parent_comment_id = {
        let mut found: Option<u64> = None;
        for child in div.children() {
            if let Some(el) = child.value().as_element() {
                if el.name() == "ul" && el.attr("class").unwrap_or("").contains("actions") {
                    let ul_ref = ElementRef::wrap(child).unwrap();
                    for a in ul_ref.select(&sel("a")) {
                        let t = text(&a).to_lowercase();
                        if t.contains("parent comment") || t.contains("parent thread") {
                            if let Some(href) = a.value().attr("href") {
                                let path = href.split('#').next().unwrap_or(href);
                                if let Some(id) = path.rsplit('/').next().and_then(|s| s.parse::<u64>().ok()) {
                                    found = Some(id);
                                    break;
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }
        found
    };

    Some((Comment { id, author, posted_at, content, replies: Vec::new() }, parent_comment_id))
}

fn parse_comment_pagination(doc: &Html, pagination_sel: &Selector) -> (u32, u32) {
    let mut current: u32 = 1;
    let mut max_page: u32 = 1;

    for li in doc.select(pagination_sel) {
        let class = li.value().attr("class").unwrap_or("");
        if class.contains("previous") || class.contains("next") {
            continue;
        }
        if class.contains("current") {
            let num: u32 = text(&li).parse().unwrap_or(1);
            current = num;
            if num > max_page { max_page = num; }
        } else {
            let num: u32 = text(&li).parse().unwrap_or(0);
            if num > max_page { max_page = num; }
        }
    }

    (current, max_page)
}
