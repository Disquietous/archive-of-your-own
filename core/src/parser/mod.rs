use scraper::{Html, Selector, ElementRef};

mod collections;
mod comments;
mod forms;
mod listings;
mod profile;
mod work_page;

pub use collections::*;
pub use comments::*;
pub use forms::*;
pub use listings::*;
pub use profile::*;
pub use work_page::*;

#[cfg(test)]
mod tests;

fn sel(s: &str) -> Selector {
    Selector::parse(s).unwrap()
}

fn text(el: &ElementRef) -> String {
    el.text().collect::<Vec<_>>().join("").trim().to_string()
}

fn parse_number(s: &str) -> u64 {
    s.replace(',', "").trim().parse().unwrap_or(0)
}

/// AO3 sometimes injects a dismissible site-wide announcement between the
/// page header and the content (`<div class="alert announcement group"
/// id="admin-banner">…</div>`). Its body is a `<div class="userstuff">`,
/// so it matches the same selectors as real page content — an unstripped
/// banner gets parsed as, e.g., chapter text. Every fetched page runs
/// through here before parsing so no parser ever sees the banner.
pub fn strip_admin_banner(mut html: String) -> String {
    while let Some(range) = admin_banner_range(&html) {
        html.replace_range(range, "");
    }
    html
}

/// Byte range of the banner's whole balanced `<div>` block, or None when no
/// banner is present (the overwhelmingly common case — one substring search).
fn admin_banner_range(html: &str) -> Option<std::ops::Range<usize>> {
    let id_pos = html.find("id=\"admin-banner\"")
        .or_else(|| html.find("id='admin-banner'"))?;
    // The <div opening tag this id belongs to. If a '>' intervenes the id
    // text wasn't inside a div's opening tag — bail rather than mangle.
    let start = html[..id_pos].rfind("<div")?;
    if html[start..id_pos].contains('>') {
        return None;
    }
    // Walk forward over nested <div>/</div> tags until the block closes.
    // Byte-wise so multi-byte characters never split an index.
    let bytes = html.as_bytes();
    let mut depth = 0usize;
    let mut i = start;
    while i < bytes.len() {
        if bytes[i..].starts_with(b"<div")
            && matches!(bytes.get(i + 4), Some(b' ' | b'>' | b'\t' | b'\n' | b'\r')) {
            depth += 1;
            i += 4;
        } else if bytes[i..].starts_with(b"</div>") {
            depth = depth.checked_sub(1)?;
            i += 6;
            if depth == 0 {
                return Some(start..i);
            }
        } else {
            i += 1;
        }
    }
    None
}

const AO3_DATE_FORMATS: &[&str] = &[
    "%d %b %Y",  // "15 Jul 2026" — blurb listings
    "%Y-%m-%d",  // "2026-07-15"  — work page stats
    "%b %d, %Y", // "Jul 15, 2026" — occasionally seen
];

pub fn normalize_ao3_date(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    for fmt in AO3_DATE_FORMATS {
        if let Ok(d) = chrono::NaiveDate::parse_from_str(raw, fmt) {
            return d.format("%Y-%m-%d").to_string();
        }
    }
    raw.to_string()
}

/// Total number of works a listing page claims to contain, independent of
/// pagination. Author works listings carry it in the page heading
/// ("1 - 20 of 123 Works by X", or "5 Works by X" when unpaginated);
/// series pages carry it in the stats block ("Works: 12"). None when no
/// count is present — callers must treat that as "unknown", never zero.
pub fn parse_listing_works_total(html: &str) -> Option<u32> {
    let doc = Html::parse_document(html);
    let heading = sel("h2.heading");
    for el in doc.select(&heading) {
        if let Some(n) = works_total_from_heading(&text(&el)) {
            return Some(n);
        }
    }
    let series_stat = sel("dd.works");
    for el in doc.select(&series_stat) {
        let t = text(&el).trim().replace(',', "");
        if let Ok(n) = t.parse::<u32>() {
            return Some(n);
        }
    }
    None
}

/// "1 - 20 of 123 Works by X" → 123; "5 Works by X" → 5. The token right
/// before "Works" is the total in both shapes.
fn works_total_from_heading(heading: &str) -> Option<u32> {
    let t = heading.replace(',', "").replace('\u{a0}', " ");
    let idx = t.find(" Works")?;
    t[..idx].split_whitespace().last()?.parse::<u32>().ok()
}

/// Total result count of a search/tag results page. Search results carry
/// "834 Found" in an h3 heading; tag works listings carry the
/// "1 - 20 of 834 Works in …" h2 shape. None when neither is present.
pub fn parse_results_total(html: &str) -> Option<u32> {
    let doc = Html::parse_document(html);
    let h3 = sel("h3.heading");
    for el in doc.select(&h3) {
        let t = text(&el).replace(',', "");
        let mut tokens = t.split_whitespace();
        if let (Some(n), Some(word)) = (tokens.next(), tokens.next()) {
            if word.eq_ignore_ascii_case("found") {
                if let Ok(count) = n.parse::<u32>() {
                    return Some(count);
                }
            }
        }
    }
    parse_listing_works_total(html)
}

/// Check whether the HTML page has a "next" pagination link.
pub fn has_next_page(html: &str) -> bool {
    let doc = Html::parse_document(html);
    let next_sel1 = sel("li.next a");
    let next_sel2 = sel("a[rel='next']");
    doc.select(&next_sel1).next().is_some() || doc.select(&next_sel2).next().is_some()
}

/// Total page count from the pagination bar — the highest numbered page link.
/// Returns 1 when the page has no pagination.
pub fn total_pages(html: &str) -> u32 {
    let doc = Html::parse_document(html);
    let s = sel("ol.pagination a");
    doc.select(&s)
        .filter_map(|a| text(&a).trim().parse::<u32>().ok())
        .max()
        .unwrap_or(1)
}
