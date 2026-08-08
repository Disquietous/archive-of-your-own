use scraper::{Html, ElementRef};

use crate::error::AppError;
use crate::models::*;

use super::{sel, text};
use super::forms::parse_work_subscription_form;
use super::work_page::parse_element_children;

/// The profile owner's icon URL from a profile page. Scoped to the page's
/// primary header — an unscoped `img.icon` matches the signed-in user's own
/// greeting icon in the site chrome first.
pub fn extract_user_icon_url(html: &str) -> Option<String> {
    let doc = Html::parse_document(html);
    for selector in ["div.primary.header p.icon img", "#main p.icon img", "#main img.icon"] {
        let s = sel(selector);
        if let Some(src) = doc.select(&s).next().and_then(|el| el.value().attr("src")) {
            if !src.is_empty() {
                return Some(src.to_string());
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Subscription page parser (/users/{username}/subscriptions)
// ---------------------------------------------------------------------------

pub fn parse_subscriptions_page(html: &str) -> Result<Vec<Subscription>, AppError> {
    let doc = Html::parse_document(html);
    let mut subs = Vec::new();
    let mut seen = std::collections::HashSet::new();

    let dt_sel = sel("dl.subscription dt");
    let link_sel = sel("a[href]");

    for dt in doc.select(&dt_sel) {
        let Some(link) = dt.select(&link_sel).next() else { continue };
        let href = link.value().attr("href").unwrap_or("");
        let display = text(&link);

        let entry = if let Some(rest) = href.strip_prefix("/users/") {
            let username = rest.split('/').next().unwrap_or("");
            if !username.is_empty() && !href.contains("/subscriptions") {
                Some(("author", username.to_string(),
                    if display.is_empty() { username.to_string() } else { display }))
            } else { None }
        } else if let Some(rest) = href.strip_prefix("/works/") {
            let id_str = rest.split('/').next().unwrap_or("");
            if id_str.parse::<u64>().is_ok() {
                Some(("work", id_str.to_string(),
                    if display.is_empty() { format!("Work {id_str}") } else { display }))
            } else { None }
        } else if let Some(rest) = href.strip_prefix("/series/") {
            let id_str = rest.split('/').next().unwrap_or("");
            if id_str.parse::<u64>().is_ok() {
                Some(("series", id_str.to_string(),
                    if display.is_empty() { format!("Series {id_str}") } else { display }))
            } else { None }
        } else { None };

        if let Some((sub_type, id, name)) = entry {
            let key = (sub_type.to_string(), id.clone());
            if seen.insert(key) {
                // AO3's subscription record id lives in the paired <dd>'s
                // unsubscribe form action (/users/X/subscriptions/{id}) —
                // harvest it so unsubscribing can POST directly later.
                let form_sel = sel("form[action]");
                let ao3_id = dt.next_siblings()
                    .filter_map(ElementRef::wrap)
                    .find(|el| el.value().name() == "dd")
                    .and_then(|dd| dd.select(&form_sel).next())
                    .and_then(|f| f.value().attr("action"))
                    .and_then(|a| a.rsplit('/').next())
                    .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()))
                    .map(str::to_string);
                subs.push(Subscription {
                    sub_type: sub_type.to_string(),
                    id,
                    name,
                    ao3_id,
                });
            }
        }
    }

    Ok(subs)
}

// ---------------------------------------------------------------------------
// User profile parser (/users/{username}/profile)
// ---------------------------------------------------------------------------

/// The trailing record id from a path like `/users/X/subscriptions/123` or
/// `/users/X/blocked/users/123/confirm_unblock` (id precedes `strip_tail`
/// when given). None unless the segment is purely numeric.
fn path_record_id(href: &str, strip_tail: &str) -> Option<String> {
    let path = href.split('?').next().unwrap_or(href);
    let path = path.strip_suffix(strip_tail).unwrap_or(path);
    path.trim_end_matches('/').rsplit('/').next()
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_string)
}

/// Parse a user's profile page: identity, pseuds, join date, sidebar
/// counts, bio, and — when signed in — live subscribe/block/mute state.
pub fn parse_user_profile(html: &str) -> Result<UserProfile, AppError> {
    let doc = Html::parse_document(html);

    let username = doc.select(&sel("div.primary.header h2.heading")).next()
        .map(|el| text(&el))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| AppError::ParseError("profile: no username heading".to_string()))?;

    // Meta rows (dt/dd pairs): pseuds, join date, numeric id, location, birthday.
    let mut pseuds = Vec::new();
    let mut joined = String::new();
    let mut numeric_id: Option<String> = None;
    let mut location = String::new();
    let mut birthday = String::new();
    if let Some(dl) = doc.select(&sel("#main dl.meta")).next() {
        for dt in dl.select(&sel("dt")) {
            let Some(dd) = dt.next_siblings().filter_map(ElementRef::wrap)
                .find(|el| el.value().name() == "dd") else { continue };
            let label = text(&dt).to_lowercase();
            if label.starts_with("my pseuds") {
                pseuds = dd.select(&sel("a")).map(|a| text(&a))
                    .filter(|s| !s.is_empty()).collect();
                if pseuds.is_empty() {
                    let t = text(&dd);
                    if !t.is_empty() { pseuds.push(t); }
                }
            } else if label.starts_with("i joined on") {
                joined = text(&dd);
            } else if label.starts_with("my user id") {
                let t = text(&dd);
                if !t.is_empty() && t.chars().all(|c| c.is_ascii_digit()) {
                    numeric_id = Some(t);
                }
            } else if label.starts_with("i live in") {
                location = text(&dd);
            } else if label.starts_with("my birthday") {
                birthday = text(&dd);
            }
        }
    }

    // Sidebar counts — "Works (2)", "Series (1)", ... keyed by the link's
    // last path segment so drafts/other links never match.
    let mut counts = std::collections::HashMap::new();
    for a in doc.select(&sel("#dashboard a[href]")) {
        let href = a.value().attr("href").unwrap_or("");
        let label = text(&a);
        let Some(open) = label.rfind('(') else { continue };
        let Some(close) = label[open..].find(')').map(|i| i + open) else { continue };
        let Ok(n) = label[open + 1..close].replace(',', "").trim().parse::<u32>() else { continue };
        let path = href.split('?').next().unwrap_or(href);
        let segment = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
        counts.insert(segment.to_string(), n);
    }
    let count = |key: &str| counts.get(key).copied().unwrap_or(0);

    // Bio (when present) as a ContentBlock tree — no HTML escapes the parser.
    let bio = doc.select(&sel("div.bio blockquote.userstuff")).next()
        .map(|el| parse_element_children(&el))
        .unwrap_or_default();

    // Live subscription state from the profile's subscribe form (absent when
    // logged out). The form's subscribable_id is the numeric user id.
    let mut viewer_signed_in = false;
    let mut subscribed = false;
    let mut subscription_ao3_id = None;
    if let Some(form) = parse_work_subscription_form(html) {
        viewer_signed_in = true;
        // A profile page's #new_subscription form is always the user-
        // subscription form; the destroy variant omits subscribable_type.
        subscribed = form.subscribed;
        if form.subscribed {
            subscription_ao3_id = path_record_id(&form.action, "");
        }
        if form.subscribable_type == "User"
            && !form.subscribable_id.is_empty()
            && form.subscribable_id.chars().all(|c| c.is_ascii_digit()) {
            numeric_id = Some(form.subscribable_id.clone());
        }
    }

    // Block/mute state from the subnav links. Unblock/unmute links carry the
    // record id needed for the destroy POST.
    let mut blocked = false;
    let mut block_ao3_id = None;
    let mut muted = false;
    let mut mute_ao3_id = None;
    for a in doc.select(&sel("#main a[href]")) {
        let href = a.value().attr("href").unwrap_or("");
        if href.contains("/blocked/users/") && href.contains("confirm_unblock") {
            blocked = true;
            block_ao3_id = path_record_id(href, "/confirm_unblock");
        } else if href.contains("/muted/users/") && href.contains("confirm_unmute") {
            muted = true;
            mute_ao3_id = path_record_id(href, "/confirm_unmute");
        }
    }

    Ok(UserProfile {
        username,
        numeric_id,
        avatar_url: extract_user_icon_url(html),
        pseuds,
        joined,
        location,
        birthday,
        bio,
        works_count: count("works"),
        series_count: count("series"),
        bookmarks_count: count("bookmarks"),
        collections_count: count("collections"),
        gifts_count: count("gifts"),
        viewer_signed_in,
        subscribed,
        subscription_ao3_id,
        blocked,
        block_ao3_id,
        muted,
        mute_ao3_id,
        fetched_at: String::new(),
    })
}

/// Parse a blocked- or muted-users index page (/users/{me}/blocked/users,
/// /users/{me}/muted/users) into (username, record id) pairs. The record id
/// comes from each row's confirm-undo link and drives the destroy POST.
/// `confirm_tail` is "confirm_unblock" or "confirm_unmute".
pub fn parse_moderation_list(html: &str, confirm_tail: &str) -> Vec<(String, Option<String>)> {
    let doc = Html::parse_document(html);
    let mut out: Vec<(String, Option<String>)> = Vec::new();
    for li in doc.select(&sel("#main li")) {
        let Some(undo_href) = li.select(&sel("a[href]"))
            .filter_map(|a| a.value().attr("href"))
            .find(|h| h.contains(confirm_tail)) else { continue };
        let record_id = path_record_id(undo_href, &format!("/{confirm_tail}"));
        let name = li.select(&sel("a[href^='/users/']")).filter_map(|a| {
            let rest = a.value().attr("href")?.strip_prefix("/users/")?;
            // Skip links into the viewer's own blocked/muted routes (the
            // undo link itself) — we want the target user's own link.
            if rest.contains("/blocked/") || rest.contains("/muted/") { return None; }
            let seg = rest.split(['/', '?']).next().unwrap_or("");
            if seg.is_empty() { None } else { Some(seg.to_string()) }
        }).next();
        if let Some(name) = name {
            if !out.iter().any(|(n, _)| n == &name) {
                out.push((name, record_id));
            }
        }
    }
    out
}
