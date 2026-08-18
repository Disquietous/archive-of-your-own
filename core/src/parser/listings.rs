use scraper::{Html, ElementRef};

use crate::error::AppError;
use crate::models::*;

use super::{sel, text, parse_number, normalize_ao3_date};

// ---------------------------------------------------------------------------
// Work listing parser (search results / tag pages)
// ---------------------------------------------------------------------------

pub fn parse_work_listings(html: &str) -> Result<Vec<WorkSummary>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.work.blurb");
    let mut works = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        match parse_single_blurb(&blurb) {
            Ok(w) => works.push(w),
            Err(_) => continue,
        }
    }

    if works.is_empty() {
        verify_empty_listing(&doc, "work listing")?;
    }
    Ok(works)
}

/// Schema canary for listing pages: an empty result is only trustworthy if
/// the page still looks like an AO3 listing. AO3 always renders the `#main`
/// region, and a listing with zero items either keeps the (empty) index
/// list or shows a "no works/results" notice. Anything else means the
/// markup our selectors match has changed — fail closed so callers can't
/// mistake a parser break for "0 works" (the What's-New census would
/// otherwise flag every known work as gone).
pub(super) fn verify_empty_listing(doc: &Html, what: &str) -> Result<(), AppError> {
    let main = doc.select(&sel("#main")).next().ok_or_else(|| AppError::ParseError(
        format!("{what}: #main region missing — not an AO3 page")))?;
    if doc.select(&sel("#main ol.index.group, #main ul.index.group")).next().is_some() {
        return Ok(());
    }
    let main_text = text(&main).to_lowercase();
    for marker in ["no results", "no works", "no bookmarks", "no collections",
                   "0 works", "0 bookmarks", "0 collections"] {
        if main_text.contains(marker) {
            return Ok(());
        }
    }
    Err(AppError::ParseError(format!(
        "{what}: no blurbs, no index container, no empty-state notice — AO3 markup may have changed")))
}

fn parse_single_blurb(blurb: &ElementRef) -> Result<WorkSummary, AppError> {
    let id = extract_work_id(blurb)?;
    let title = extract_blurb_title(blurb);
    let authors = extract_blurb_authors(blurb);
    let fandoms = extract_tag_list(blurb, "h5.fandoms a.tag");
    let (rating, warnings, categories, complete) = extract_required_tags(blurb);
    let relationships = extract_tag_class_list(blurb, "relationships");
    let characters = extract_tag_class_list(blurb, "characters");
    let tags = extract_tag_class_list(blurb, "freeforms");
    let summary = extract_blurb_summary(blurb);
    let date_updated = extract_blurb_date(blurb);
    let language = extract_stat_text(blurb, "dd.language");
    let (word_count, chapter_count, total_chapters, kudos, hits, bookmarks, comments) =
        extract_blurb_stats(blurb);

    Ok(WorkSummary {
        id,
        title,
        authors,
        fandoms,
        rating,
        warnings,
        categories,
        relationships,
        characters,
        tags,
        summary,
        word_count,
        chapter_count,
        total_chapters,
        kudos,
        hits,
        bookmarks,
        comments,
        // List blurbs carry a single date (the last-updated date); AO3 only
        // exposes the publish date on the work page itself.
        date_published: String::new(),
        date_updated,
        language,
        complete,
        // Listing blurbs do carry series markup (ul.series) but blurb series
        // parsing is out of scope; only the work page populates this.
        series: Vec::new(),
        fetched_at: String::new(),
    })
}

fn extract_work_id(blurb: &ElementRef) -> Result<u64, AppError> {
    // Try id="work_NNNNN"
    if let Some(id_attr) = blurb.value().id() {
        if let Some(id_str) = id_attr.strip_prefix("work_") {
            if let Ok(id) = id_str.parse::<u64>() {
                return Ok(id);
            }
        }
    }

    // Try class="... work-NNNNN ..." (bookmark blurbs)
    if let Some(classes) = blurb.value().attr("class") {
        for cls in classes.split_whitespace() {
            if let Some(id_str) = cls.strip_prefix("work-") {
                if let Ok(id) = id_str.parse::<u64>() {
                    return Ok(id);
                }
            }
        }
    }

    // Try from the title link href
    if let Some(link) = title_link(blurb) {
        if let Some(id_str) = link.value().attr("href")
            .and_then(|href| href.split("/works/").nth(1))
            .and_then(|s| s.split('/').next())
            .and_then(|s| s.split('?').next()) {
            if let Ok(id) = id_str.parse::<u64>() {
                return Ok(id);
            }
        }
    }

    Err(AppError::ElementNotFound("work id".to_string()))
}

/// The blurb heading's work link. Plain listings link "/works/{id}", but
/// collection listings nest it — "/collections/{name}/works/{id}" — so
/// match on the path segment, not the prefix. The author links beside it
/// point at /users/, so they can't false-match.
fn title_link<'a>(blurb: &'a ElementRef) -> Option<ElementRef<'a>> {
    let link_sel = sel("h4.heading a[href*='/works/']");
    blurb.select(&link_sel).next()
}

fn extract_blurb_title(blurb: &ElementRef) -> String {
    title_link(blurb).map(|el| text(&el)).unwrap_or_default()
}

fn extract_blurb_authors(blurb: &ElementRef) -> Vec<String> {
    let sel = sel("h4.heading a[rel='author']");
    blurb.select(&sel).map(|el| text(&el)).collect()
}

fn extract_tag_list(blurb: &ElementRef, selector: &str) -> Vec<String> {
    let s = sel(selector);
    blurb.select(&s).map(|el| text(&el)).collect()
}

fn extract_tag_class_list(blurb: &ElementRef, class: &str) -> Vec<String> {
    let selector_str = format!("ul.tags li.{} a.tag", class);
    let s = sel(&selector_str);
    blurb.select(&s).map(|el| text(&el)).collect()
}

fn extract_required_tags(blurb: &ElementRef) -> (Rating, Vec<Warning>, Vec<String>, bool) {
    let s = sel("ul.required-tags span");
    let spans: Vec<String> = blurb.select(&s).map(|el| {
        el.value().attr("class").unwrap_or("").to_string()
    }).collect();

    let mut rating = Rating::NotRated;
    let mut warnings = Vec::new();
    let mut categories = Vec::new();
    let mut complete = false;

    for class in &spans {
        if class.contains("rating-") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("rating-"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            rating = Rating::from_ao3_tag(title);
        }
        if class.contains("warning") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("warning"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            warnings.push(Warning::from_ao3_tag(title));
        }
        if class.contains("category-") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("category-"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            if !title.is_empty() {
                categories.push(title.to_string());
            }
        }
        if class.contains("complete-yes") || class.contains("iswip") {
            complete = class.contains("complete-yes");
        }
    }

    if warnings.is_empty() {
        warnings.push(Warning::None);
    }

    (rating, warnings, categories, complete)
}

fn extract_blurb_summary(blurb: &ElementRef) -> String {
    let s = sel("blockquote.userstuff.summary");
    blurb.select(&s).next().map(|el| {
        el.text().collect::<Vec<_>>().join("").trim().to_string()
    }).unwrap_or_default()
}

fn extract_blurb_date(blurb: &ElementRef) -> String {
    let s = sel("p.datetime");
    let raw = blurb.select(&s).next().map(|el| text(&el)).unwrap_or_default();
    normalize_ao3_date(&raw)
}

fn extract_stat_text(blurb: &ElementRef, selector: &str) -> String {
    let s = sel(selector);
    blurb.select(&s).next().map(|el| text(&el)).unwrap_or_default()
}

fn extract_blurb_stats(blurb: &ElementRef) -> (u64, u32, Option<u32>, u32, u64, u32, u32) {
    let words = parse_number(&extract_stat_text(blurb, "dd.words"));
    let chapters_str = extract_stat_text(blurb, "dd.chapters");
    let (chapter_count, total_chapters) = parse_chapters(&chapters_str);
    let kudos = parse_number(&extract_stat_text(blurb, "dd.kudos")) as u32;
    let hits = parse_number(&extract_stat_text(blurb, "dd.hits"));
    let bookmarks = parse_number(&extract_stat_text(blurb, "dd.bookmarks")) as u32;
    let comments = parse_number(&extract_stat_text(blurb, "dd.comments")) as u32;

    (words, chapter_count, total_chapters, kudos, hits, bookmarks, comments)
}

pub(super) fn parse_chapters(s: &str) -> (u32, Option<u32>) {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() == 2 {
        let current = parts[0].trim().parse().unwrap_or(0);
        let total = if parts[1].trim() == "?" {
            None
        } else {
            parts[1].trim().parse().ok()
        };
        (current, total)
    } else {
        (1, Some(1))
    }
}

// ---------------------------------------------------------------------------
// Bookmark listing parser (/users/{username}/bookmarks and
// /collections/{name}/bookmarks — the same li.bookmark.blurb markup, each
// wrapping a standard work blurb plus the bookmarker's own module. Series
// and external-work bookmarks carry no /works/ link or work-N class and are
// skipped. "Mystery Work" blurbs — works still hidden in an unrevealed
// challenge collection — have no work link either, but their id survives in
// the li's work-N class, so they parse into a listing with a synthetic
// display stub; see `BookmarkListing::mystery`.)
// ---------------------------------------------------------------------------

pub fn parse_bookmark_listings(html: &str) -> Result<Vec<BookmarkListing>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.bookmark.blurb");
    let mut bookmarks = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        match parse_single_bookmark_blurb(&blurb) {
            Ok(bl) => bookmarks.push(bl),
            Err(_) => continue,
        }
    }

    if bookmarks.is_empty() {
        verify_empty_listing(&doc, "bookmark listing")?;
    }
    Ok(bookmarks)
}

fn parse_single_bookmark_blurb(blurb: &ElementRef) -> Result<BookmarkListing, AppError> {
    // Extract ao3_bookmark_id from the element's id attribute: "bookmark_12345"
    let ao3_bookmark_id = blurb
        .value()
        .id()
        .and_then(|id| id.strip_prefix("bookmark_"))
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or_else(|| AppError::ElementNotFound("bookmark id".to_string()))?;

    // A "Mystery Work" blurb: the bookmarked work sits in an unrevealed
    // challenge collection, so AO3 renders a placeholder header with no
    // work link, author, or stats — just "Part of <collection>" and a
    // reveal notice in the summary slot.
    let mystery_sel = sel("div.mystery");
    let mystery = blurb.select(&mystery_sel).next().is_some();

    // Extract work_id from the heading link. Mystery blurbs have no link —
    // their id survives only in the li's work-N class (which series and
    // external bookmarks lack, so those still fail out here and get
    // skipped).
    let work_link_sel = sel("h4.heading a[href*='/works/']");
    let work_id = blurb
        .select(&work_link_sel)
        .next()
        .and_then(|a| a.value().attr("href"))
        .and_then(|href| {
            href.split("/works/")
                .nth(1)
                .and_then(|s| s.split('/').next())
                .and_then(|s| s.split('?').next())
                .and_then(|s| s.parse::<u64>().ok())
        })
        .or_else(|| if mystery { extract_work_id(blurb).ok() } else { None })
        .ok_or_else(|| AppError::ElementNotFound("work id in bookmark".to_string()))?;

    // Extract bookmarker's notes (not the work summary)
    let note_sel = sel("blockquote.userstuff.notes p");
    let note = blurb
        .select(&note_sel)
        .map(|el| text(&el))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    // The bookmarker's own module carries a "Bookmarked by" byline naming
    // the user the bookmark belongs to, plus the bookmark's date, the
    // bookmarker's own tags, and the Rec symbol — all scoped under
    // div.user so the work blurb's tags/datetime aren't picked up.
    let byline_sel = sel("div.user h5.byline a[href*='/users/']");
    let bookmarker = blurb
        .select(&byline_sel)
        .next()
        .map(|a| text(&a).trim().to_string())
        .unwrap_or_default();

    let tags_sel = sel("div.user ul.tags a.tag");
    let tags: Vec<String> = blurb
        .select(&tags_sel)
        .map(|a| text(&a).trim().to_string())
        .filter(|t| !t.is_empty())
        .collect();

    // The Rec symbol lives in the blurb's top status block (the "bookmark
    // icons" p.status, a sibling of the work blurb — never inside it, so no
    // work markup can false-match). Some renderings also place it in the
    // user module; accept both.
    let rec_sel = sel("p.status .rec, div.user .rec");
    let rec = blurb.select(&rec_sel).next().is_some();

    let date_sel = sel("div.user p.datetime");
    let date_bookmarked = blurb
        .select(&date_sel)
        .next()
        .map(|el| text(&el).trim().to_string())
        .unwrap_or_default();

    // The collection the mystery work will be revealed from:
    // "Part of <a href=/collections/{name}>{title}</a>" in the placeholder
    // header.
    let (mystery_collection_name, mystery_collection_title) = if mystery {
        let coll_sel = sel("div.mystery h5.heading a[href*='/collections/']");
        blurb.select(&coll_sel).next().map(|a| {
            let name = a.value().attr("href")
                .and_then(|href| href.split("/collections/").nth(1))
                .map(|s| s.split(['/', '?']).next().unwrap_or("").to_string())
                .unwrap_or_default();
            (name, text(&a).trim().to_string())
        }).unwrap_or_default()
    } else {
        Default::default()
    };

    // The work blurb data. A mystery blurb has none — synthesize a display
    // stub carrying the only things AO3 shows: the placeholder title and
    // the reveal notice. Callers must never cache it (see the field docs).
    let work_summary = if mystery {
        Some(WorkSummary {
            id: work_id,
            title: "Mystery Work".to_string(),
            summary: extract_blurb_summary(blurb),
            rating: Rating::NotRated,
            authors: Vec::new(),
            fandoms: Vec::new(),
            warnings: Vec::new(),
            categories: Vec::new(),
            relationships: Vec::new(),
            characters: Vec::new(),
            tags: Vec::new(),
            word_count: 0,
            chapter_count: 0,
            total_chapters: None,
            kudos: 0,
            hits: 0,
            bookmarks: 0,
            comments: 0,
            date_published: String::new(),
            date_updated: String::new(),
            language: String::new(),
            complete: false,
            series: Vec::new(),
            fetched_at: String::new(),
        })
    } else {
        parse_single_blurb(blurb).ok()
    };

    Ok(BookmarkListing {
        work_id,
        ao3_bookmark_id,
        note,
        bookmarker,
        tags,
        rec,
        date_bookmarked,
        mystery,
        mystery_collection_name,
        mystery_collection_title,
        work_summary,
    })
}
