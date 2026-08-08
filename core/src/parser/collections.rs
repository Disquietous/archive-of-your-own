use scraper::{Html, ElementRef};

use crate::error::AppError;
use crate::models::CollectionSummary;

use super::{sel, text, parse_number};
use super::listings::verify_empty_listing;

// ---------------------------------------------------------------------------
// Collections index parser (/collections)
// ---------------------------------------------------------------------------

/// Parse one page of the collections index. Blurbs are
/// `li.collection.blurb` (rendered as class="collection picture blurb
/// group") inside `ul.collection.picture.index.group`. Fails closed like
/// parse_work_listings: zero blurbs are only trusted when the page still
/// carries the index container or an empty-state notice.
pub fn parse_collections_page(html: &str) -> Result<Vec<CollectionSummary>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.collection.blurb");
    let mut collections = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        match parse_single_collection_blurb(&blurb) {
            Ok(c) => collections.push(c),
            Err(_) => continue,
        }
    }

    if collections.is_empty() {
        verify_empty_listing(&doc, "collections listing")?;
    }
    Ok(collections)
}

fn parse_single_collection_blurb(blurb: &ElementRef) -> Result<CollectionSummary, AppError> {
    let (name, title) = extract_collection_name_title(blurb)?;
    let maintainers = extract_collection_maintainers(blurb);
    let summary = extract_collection_summary(blurb);
    let (is_open, is_moderated, is_anonymous, collection_type) = extract_collection_type(blurb);
    let work_count = extract_collection_stat(blurb, "dd.works");
    let bookmarked_count = extract_collection_stat(blurb, "dd.bookmarks");

    Ok(CollectionSummary {
        name,
        title,
        summary,
        is_open,
        is_moderated,
        is_anonymous,
        work_count,
        bookmarked_count,
        maintainers,
        collection_type,
    })
}

/// The heading link carries both the display title (link text) and the URL
/// slug (href "/collections/{name}"). The parenthesized `span.name` repeats
/// the slug — used as a fallback when the href is missing or malformed.
fn extract_collection_name_title(blurb: &ElementRef) -> Result<(String, String), AppError> {
    let link_sel = sel("h4.heading a[href^='/collections/']");
    let link = blurb
        .select(&link_sel)
        .next()
        .ok_or_else(|| AppError::ElementNotFound("collection heading link".to_string()))?;
    let title = text(&link);

    let mut name = link
        .value()
        .attr("href")
        .and_then(|href| href.strip_prefix("/collections/"))
        .map(|rest| {
            rest.split(['/', '?'])
                .next()
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();

    if name.is_empty() {
        // "(slug)" display next to the title.
        let name_sel = sel("h4.heading span.name");
        name = blurb
            .select(&name_sel)
            .next()
            .map(|el| text(&el).trim_matches(['(', ')']).to_string())
            .unwrap_or_default();
    }

    if name.is_empty() {
        return Err(AppError::ElementNotFound("collection name".to_string()));
    }
    Ok((name, title))
}

fn extract_collection_maintainers(blurb: &ElementRef) -> Vec<String> {
    let s = sel("h4.heading a.owner");
    blurb.select(&s).map(|el| text(&el)).collect()
}

fn extract_collection_summary(blurb: &ElementRef) -> String {
    let block_sel = sel("blockquote.userstuff.summary");
    let Some(block) = blurb.select(&block_sel).next() else {
        return String::new();
    };
    // Join paragraphs so multi-paragraph summaries keep their breaks.
    let p_sel = sel("p");
    let paragraphs: Vec<String> = block
        .select(&p_sel)
        .map(|el| text(&el))
        .filter(|t| !t.is_empty())
        .collect();
    if paragraphs.is_empty() {
        text(&block)
    } else {
        paragraphs.join("\n")
    }
}

/// The `p.type` line is a parenthesized comma-separated list:
/// "(Open, Moderated, Unrevealed, Anonymous, Gift Exchange Challenge)".
/// Open/Closed and Moderated/Unmoderated always appear; Unrevealed,
/// Anonymous, and a challenge type only when they apply. Returns
/// (is_open, is_moderated, is_anonymous, collection_type).
fn extract_collection_type(blurb: &ElementRef) -> (bool, bool, bool, String) {
    let s = sel("p.type");
    let raw = blurb.select(&s).next().map(|el| text(&el)).unwrap_or_default();

    let mut is_open = false;
    let mut is_moderated = false;
    let mut is_anonymous = false;
    let mut extra: Vec<String> = Vec::new();

    for token in raw.trim().trim_start_matches('(').trim_end_matches(')').split(',') {
        let token = token.trim();
        match token {
            "" | "Closed" | "Unmoderated" | "Unrevealed" => {}
            "Open" => is_open = true,
            "Moderated" => is_moderated = true,
            "Anonymous" => is_anonymous = true,
            other => extra.push(other.to_string()),
        }
    }
    (is_open, is_moderated, is_anonymous, extra.join(", "))
}

fn extract_collection_stat(blurb: &ElementRef, selector: &str) -> u32 {
    let s = sel(selector);
    blurb
        .select(&s)
        .next()
        .map(|el| parse_number(&text(&el)) as u32)
        .unwrap_or(0)
}
