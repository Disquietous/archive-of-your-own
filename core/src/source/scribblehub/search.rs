//! ScribbleHub's Series Finder as static configuration: its fields, the
//! site's vocabulary tables and the query-string encoding its page script
//! (`sfinder.js`, `sf_genre_submit`) builds. Source markup:
//! design/scribblehub/series-search.txt; tables regenerate with
//! `scripts/gen-scribblehub-search-tables.py`.

use scraper::Html;

use crate::source::search::{fmt_num, opt, FieldOption, LibraryBinding, SearchField, SearchQuery, SearchSchema, SearchSection, SortSpec};

use super::parse::{attr, sel, text};
use super::search_tables::{CONTENT_WARNINGS, CONTESTS, GENRES, TAGS};
use super::{BASE_URL, SOURCE_ID};

pub const VERSION: u32 = 1;

fn options(table: &[(&str, &str)]) -> Vec<FieldOption> {
    table.iter().map(|(v, l)| opt(v, l)).collect()
}

fn and_or() -> Vec<FieldOption> {
    vec![opt("and", "AND"), opt("or", "OR")]
}

pub fn schema() -> SearchSchema {
    SearchSchema {
        source: SOURCE_ID.to_string(),
        version: VERSION,
        primary: "title".to_string(),
        sections: vec![
            SearchSection::new("finder", "Series Finder", vec![
                SearchField::text("title", "Title Contains").hint("Title contains…").column("title"),
                SearchField::include_exclude("genres", "Genre", options(GENRES), and_or(), "or").tag("freeform"),
                SearchField::include_exclude("content_warnings", "Content Warning", options(CONTENT_WARNINGS), and_or(), "and"),
                SearchField::choice("status", "Story Status", vec![
                    opt("completed", "Completed"),
                    opt("ongoing", "Ongoing"),
                    opt("hiatus", "Hiatus"),
                ], Some("All")).column("complete"),
            ]),
            SearchSection::new("advance", "Advance", vec![
                SearchField::count_range("chapters", "Chapters").column("chapter_count"),
                SearchField::count_range("releases_per_week", "Chapters per Week").stat("release_rate"),
                SearchField::count_range("favorites", "Favorites").stat("favorites"),
                SearchField::range("rating", "Ratings", Some(0.0), Some(5.0), 0.1).stat("rating"),
                SearchField::count_range("rating_count", "Number of Ratings").stat("rating_count"),
                SearchField::count_range("readers", "Readers").stat("readers"),
                SearchField::count_range("reviews", "Reviews").stat("reviews"),
                SearchField::date_range("last_update", "Last Update").column("revised_at"),
                SearchField::count_range("pages", "Pages"),
                SearchField::count_range("pageviews", "Pageviews").unit("thousands").stat("views"),
                SearchField::count_range("total_words", "Total Words").unit("thousands").column("word_count"),
                SearchField::tag_text("fandom", "Fandom", "fandom").hint("Type for suggestions").tag("fandom"),
                SearchField::include_exclude("tags", "Tags", options(TAGS), and_or(), "and"),
                SearchField::choice("contest", "Contest", options(CONTESTS), Some("Any")),
            ]).collapsed(),
        ],
        sort: Some(SortSpec {
            columns: vec![
                opt("chapters", "Chapters"),
                opt("frequency", "Chapters per Week"),
                opt("dateadded", "Date Added"),
                opt("favorites", "Favorites"),
                opt("lastchpdate", "Last Update"),
                opt("numofrate", "Number of Ratings"),
                opt("pages", "Pages"),
                opt("pageviews", "Pageviews"),
                opt("ratings", "Ratings"),
                opt("readers", "Readers"),
                opt("reviews", "Reviews"),
                opt("totalwords", "Total Words"),
            ],
            directions: vec![opt("desc", "Descending"), opt("asc", "Ascending")],
            default_column: "ratings".to_string(),
            default_direction: "desc".to_string(),
        }),
    }
}

/// (field key, min param, max param) for the numeric ranges, in the
/// script's order.
const RANGES: &[(&str, &str, &str)] = &[
    ("chapters", "mnc", "mxc"),
    ("favorites", "mnfv", "mxfv"),
    ("rating", "mnrt", "mxrt"),
    ("rating_count", "mnnrt", "mxnrt"),
    ("releases_per_week", "mnrpw", "mxrpw"),
    ("readers", "mnrr", "mxrr"),
    ("reviews", "mnrv", "mxrv"),
];
const LATE_RANGES: &[(&str, &str, &str)] = &[
    ("pageviews", "mnpv", "mxpv"),
    ("pages", "mnps", "mxps"),
    ("total_words", "mntw", "mxtw"),
];

fn push(parts: &mut Vec<String>, key: &str, value: &str) {
    parts.push(format!("{key}={}", urlencode(value)));
}

fn push_range(parts: &mut Vec<String>, q: &SearchQuery, key: &str, min_key: &str, max_key: &str) {
    if let Some((min, max)) = q.range(key) {
        if let Some(a) = min { push(parts, min_key, &fmt_num(a)); }
        if let Some(b) = max { push(parts, max_key, &fmt_num(b)); }
    }
}

/// ISO `yyyy-mm-dd` → the finder's datepicker text, `mm/dd/yyyy`.
/// Anything else passes through unchanged.
fn finder_date(iso: &str) -> String {
    let p: Vec<&str> = iso.split('-').collect();
    if p.len() == 3 && p[0].len() == 4 {
        format!("{}/{}/{}", p[1], p[2], p[0])
    } else {
        iso.to_string()
    }
}

fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b',' | b'/' => out.push(b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The finder URL for a query. `fandom_ids` are the ids the adapter
/// resolved for the fandom field's names (the site wants ids there).
pub fn finder_url(q: &SearchQuery, fandom_ids: &[String], page: u32) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(c) = q.text("contest") { push(&mut parts, "ctesi", c); }
    if !fandom_ids.is_empty() { push(&mut parts, "fdi", &fandom_ids.join(",")); }
    if let Some((inc, exc, mode)) = q.set("genres") {
        if !inc.is_empty() {
            push(&mut parts, "gi", &inc.join(","));
            push(&mut parts, "mgi", mode.unwrap_or("or"));
        }
        if !exc.is_empty() { push(&mut parts, "ge", &exc.join(",")); }
    }
    if let Some((inc, exc, mode)) = q.set("content_warnings") {
        if !inc.is_empty() {
            push(&mut parts, "cti", &inc.join(","));
            push(&mut parts, "mct", mode.unwrap_or("and"));
        }
        if let Some(t) = q.text("title") { push(&mut parts, "sh", t); }
        if !exc.is_empty() { push(&mut parts, "cte", &exc.join(",")); }
    } else if let Some(t) = q.text("title") {
        push(&mut parts, "sh", t);
    }
    if let Some((inc, exc, mode)) = q.set("tags") {
        if !inc.is_empty() {
            push(&mut parts, "tgi", &inc.join(","));
            push(&mut parts, "mtgi", mode.unwrap_or("and"));
        }
        if !exc.is_empty() { push(&mut parts, "tge", &exc.join(",")); }
    }
    for (key, lo, hi) in RANGES { push_range(&mut parts, q, key, lo, hi); }
    if let Some((from, to)) = q.date_range("last_update") {
        if let Some(d) = from { push(&mut parts, "mnlcd", &finder_date(d)); }
        if let Some(d) = to { push(&mut parts, "mxlcd", &finder_date(d)); }
    }
    for (key, lo, hi) in LATE_RANGES { push_range(&mut parts, q, key, lo, hi); }
    if let Some(status) = q.text("status").filter(|s| matches!(*s, "completed" | "ongoing" | "hiatus")) {
        push(&mut parts, "cp", status);
    }
    let sort = q.sort_column.as_deref().filter(|s| !s.is_empty()).unwrap_or("ratings");
    let order = q.sort_direction.as_deref().filter(|s| !s.is_empty()).unwrap_or("desc");
    push(&mut parts, "sort", sort);
    push(&mut parts, "order", order);
    if page > 1 { push(&mut parts, "pg", &page.to_string()); }
    format!("{BASE_URL}/series-finder/?sf=1&{}", parts.join("&"))
}

/// The fandom live-search reply (`wi_ajaxsearch_fandom`): `li` items
/// whose click handler carries the id and name. Value = id, label = name.
pub fn parse_fandom_suggestions(html: &str) -> Vec<FieldOption> {
    let doc = Html::parse_fragment(html);
    let mut out = Vec::new();
    for item in doc.select(&sel("li.search_li_results")) {
        let id = item.select(&sel("[fan_termid]")).next().and_then(|e| attr(&e, "fan_termid").map(str::to_string))
            .or_else(|| attr(&item, "onclick").and_then(|on| on.split('\'').nth(1).map(str::to_string)));
        let Some(id) = id.filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())) else { continue };
        let name = text(&item).split_whitespace().collect::<Vec<_>>().join(" ");
        if name.is_empty() { continue }
        out.push(opt(&id, &name));
    }
    out
}

/// Fields the library form takes from this source (stats and the fixed
/// vocabularies the library can evaluate).
pub fn is_library_bound(f: &SearchField) -> bool {
    f.library != LibraryBinding::None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::search::FieldValue;

    #[test]
    fn schema_is_well_formed() {
        let s = schema();
        s.validate().unwrap();
        assert!(s.sections[1].collapsed, "Advance starts folded like the site");
        assert!(matches!(&s.field("tags").unwrap().kind,
            crate::source::search::FieldKind::ChoiceSet { options, exclude: true, .. } if options.len() > 700));
        for (key, _, _) in RANGES.iter().chain(LATE_RANGES) {
            assert!(s.field(key).is_some(), "range key {key} missing from schema");
        }
        assert!(is_library_bound(s.field("favorites").unwrap()));
        assert!(!is_library_bound(s.field("contest").unwrap()));
    }

    #[test]
    fn encodes_the_finder_query_string() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("title", FieldValue::Text { value: "dragon lord".into() })
            .with("genres", FieldValue::Set { include: vec!["19".into(), "9".into()], exclude: vec!["915".into()], mode: Some("and".into()) })
            .with("content_warnings", FieldValue::Set { include: vec!["48".into()], exclude: vec![], mode: Some("and".into()) })
            .with("tags", FieldValue::Set { include: vec!["119".into()], exclude: vec!["120".into(), "121".into()], mode: Some("or".into()) })
            .with("chapters", FieldValue::Range { min: Some(5.0), max: None })
            .with("rating", FieldValue::Range { min: Some(4.5), max: Some(5.0) })
            .with("last_update", FieldValue::DateRange { from: Some("2026-01-31".into()), to: None })
            .with("total_words", FieldValue::Range { min: None, max: Some(200.0) })
            .with("status", FieldValue::Choice { value: "ongoing".into() })
            .with("contest", FieldValue::Choice { value: "4668".into() })
            .sorted("favorites", "asc");
        let url = finder_url(&q, &["961".into()], 2);
        assert_eq!(url, "https://www.scribblehub.com/series-finder/?sf=1\
&ctesi=4668&fdi=961&gi=19,9&mgi=and&ge=915&cti=48&mct=and&sh=dragon+lord\
&tgi=119&mtgi=or&tge=120,121&mnc=5&mnrt=4.5&mxrt=5&mnlcd=01/31/2026&mxtw=200\
&cp=ongoing&sort=favorites&order=asc&pg=2");
        let plain = finder_url(&SearchQuery::new(SOURCE_ID, VERSION), &[], 1);
        assert_eq!(plain, "https://www.scribblehub.com/series-finder/?sf=1&sort=ratings&order=desc");
        let all = SearchQuery::new(SOURCE_ID, VERSION).with("status", FieldValue::Choice { value: "all".into() });
        assert!(!finder_url(&all, &[], 1).contains("cp="), "'all' sends no status");
    }

    #[test]
    fn parses_fandom_suggestions() {
        let html = r#"<ul><li class="search_li_results" onclick="sf_add_fandom('26817','Harry Poter');"><span class="fd-link_search">
            <span class="search_hl" fan_termid="26817">Harry</span> Poter
            </span></li><li class="search_li_results" onclick="sf_add_fandom('961','Harry Potter');"><span class="fd-link_search">
            <span class="search_hl" fan_termid="961">Harry</span> Potter
            </span></li></ul>0"#;
        let got = parse_fandom_suggestions(html);
        assert_eq!(got, vec![opt("26817", "Harry Poter"), opt("961", "Harry Potter")]);
    }

    #[test]
    fn finder_results_parse_like_profile_series() {
        let html = include_str!("../../../tests/fixtures/scribblehub_finder.html");
        let page = super::super::parse::parse_finder_results(html);
        assert_eq!(page.total_pages, 3);
        assert_eq!(page.works.len(), 2);
        let first = &page.works[0];
        assert_eq!(first.summary.external_id, "2634631");
        assert_eq!(first.summary.title, "The Prince of Whispers");
        assert_eq!(first.summary.authors, vec!["Dragonspectre02"]);
        assert_eq!(first.summary.chapter_count, 12);
        assert_eq!(first.summary.word_count, Some(50_600));
        assert_eq!(first.summary.date_updated, "2026-11-06");
        assert!(first.summary.tags.contains(&"Fantasy".to_string()));
        assert_eq!(first.stats.iter().find(|s| s.key == "release_rate").and_then(|s| s.num), Some(3.0));
        assert_eq!(first.stats.iter().find(|s| s.key == "favorites").and_then(|s| s.num), Some(17.0));
        assert_eq!(first.authors[0].id, "288750");
        assert!(page.works[1].summary.complete);
    }
}
