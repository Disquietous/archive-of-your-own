//! Wattpad's story search as static configuration: the filters beside
//! the site's results (length in parts, last updated, completed only)
//! and the request they send. The site has no sort to offer. Tags are
//! searched the site's own way: as `#tag` words in the query. The user
//! search takes a name and nothing else (`Source::search_users`).

use crate::source::search::{opt, FieldOption, FieldValue, LibraryBinding, SearchField, SearchQuery, SearchSchema,
                            SearchSection};

use super::SOURCE_ID;

pub const VERSION: u32 = 1;

/// How many stories the site lists to a page.
pub const PAGE_SIZE: u32 = 15;

/// The site's length filter: the label, then the fewest and the most
/// parts it sends (0 = no bound).
const LENGTHS: &[(&str, &str, u32, u32)] = &[
    ("any", "Any Length", 0, 0), ("1-10", "1 – 10 Parts", 1, 10), ("10-20", "10 – 20 Parts", 10, 20),
    ("20-50", "20 – 50 Parts", 20, 50), ("50+", "50 Parts or More", 50, 0),
];

/// The site's last-updated filter: the label, then the days it sends
/// (0 = any time).
const UPDATED: &[(&str, &str, u32)] = &[
    ("any", "Anytime", 0), ("1", "Today", 1), ("7", "This Week", 7), ("30", "This Month", 30), ("365", "This Year", 365),
];

fn choice_value(value: &str) -> FieldValue {
    FieldValue::Choice { value: value.to_string() }
}

pub fn schema() -> SearchSchema {
    let lengths: Vec<FieldOption> = LENGTHS.iter().map(|(v, l, _, _)| opt(v, l)).collect();
    let updated: Vec<FieldOption> = UPDATED.iter().map(|(v, l, _)| opt(v, l)).collect();
    SearchSchema {
        source: SOURCE_ID.to_string(),
        version: VERSION,
        primary: "query".to_string(),
        sections: vec![
            SearchSection::new("search", "Search for Stories", vec![
                SearchField::text("query", "Search for Stories").bound(LibraryBinding::FullText),
                SearchField::text("tags", "Tags").hint("tags, separated by spaces or commas").tag("freeform"),
                SearchField::choice("length", "Length", lengths, None).default(choice_value("any")),
                SearchField::choice("updated", "Last Updated", updated, None).default(choice_value("any")),
                SearchField::toggle("complete", "Only show completed stories"),
            ]),
        ],
        sort: None,
    }
}

/// The tags typed into the tags field, as the site's query words for
/// them (`#tag`).
fn tag_words(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\n', '\t']).map(|t| t.trim().trim_start_matches('#'))
        .filter(|t| !t.is_empty()).map(|t| format!("#{t}")).collect()
}

/// The request parameters the site's search page would send for `q`,
/// page `page` (1-based), after the fields it always sends. A filter
/// left at its default is not sent; nothing is sent without search words
/// or a tag — None then. `mature`: the account lets mature stories be
/// listed.
pub fn search_params(q: &SearchQuery, page: u32, mature: bool) -> Option<Vec<(String, String)>> {
    let mut words: Vec<String> = q.text("query").map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).into_iter().collect();
    words.extend(q.text("tags").map(tag_words).unwrap_or_default());
    if words.is_empty() { return None }
    let mut p: Vec<(String, String)> = vec![("query".into(), words.join(" "))];
    if mature { p.push(("mature".into(), "true".into())); }
    if let Some((_, _, least, most)) = q.text("length").and_then(|v| LENGTHS.iter().find(|(key, ..)| *key == v)) {
        if *least > 0 { p.push(("minParts".into(), least.to_string())); }
        if *most > 0 { p.push(("maxParts".into(), most.to_string())); }
    }
    if let Some((_, _, days)) = q.text("updated").and_then(|v| UPDATED.iter().find(|(key, ..)| *key == v)).filter(|(_, _, days)| *days > 0) {
        p.push(("updateYoungerThan".into(), days.to_string()));
    }
    if q.flag("complete") { p.push(("filter".into(), "complete".into())); }
    p.push(("limit".into(), PAGE_SIZE.to_string()));
    p.push(("offset".into(), ((page.max(1) - 1) * PAGE_SIZE).to_string()));
    Some(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::search::FieldKind;

    fn text(value: &str) -> FieldValue {
        FieldValue::Text { value: value.to_string() }
    }

    fn pairs(p: &[(String, String)]) -> Vec<(&str, &str)> {
        p.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
    }

    #[test]
    fn schema_is_well_formed() {
        let s = schema();
        s.validate().unwrap();
        assert!(s.sort.is_none(), "the site offers no sort");
        assert!(matches!(&s.field("length").unwrap().kind, FieldKind::Choice { options, .. } if options.len() == 5));
        assert!(matches!(&s.field("updated").unwrap().kind, FieldKind::Choice { options, .. } if options.len() == 5));
    }

    #[test]
    fn a_bare_query_sends_only_the_words_and_the_page() {
        let q = SearchQuery::new(SOURCE_ID, VERSION).with("query", text(" lighthouse keeper "))
            .with("length", choice_value("any")).with("updated", choice_value("any"));
        assert_eq!(pairs(&search_params(&q, 1, false).unwrap()), vec![("query", "lighthouse keeper"), ("limit", "15"), ("offset", "0")]);
        assert_eq!(pairs(&search_params(&q, 3, true).unwrap()),
                   vec![("query", "lighthouse keeper"), ("mature", "true"), ("limit", "15"), ("offset", "30")]);
        assert_eq!(search_params(&q, 0, false).unwrap().last().unwrap().1, "0");
    }

    #[test]
    fn nothing_is_sent_without_words_or_a_tag() {
        let q = SearchQuery::new(SOURCE_ID, VERSION).with("complete", FieldValue::Bool { value: true });
        assert!(search_params(&q, 1, false).is_none());
        assert!(search_params(&q.clone().with("query", text("  ")).with("tags", text(" , ")), 1, false).is_none());
        let tagged = q.with("tags", text("sea"));
        assert_eq!(search_params(&tagged, 1, false).unwrap()[0].1, "#sea");
    }

    #[test]
    fn encodes_the_filters() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("query", text("tide"))
            .with("tags", text("sea, #lighthouse  storm"))
            .with("length", choice_value("10-20"))
            .with("updated", choice_value("30"))
            .with("complete", FieldValue::Bool { value: true });
        assert_eq!(pairs(&search_params(&q, 2, false).unwrap()), vec![
            ("query", "tide #sea #lighthouse #storm"), ("minParts", "10"), ("maxParts", "20"),
            ("updateYoungerThan", "30"), ("filter", "complete"), ("limit", "15"), ("offset", "15"),
        ]);
        let long = SearchQuery::new(SOURCE_ID, VERSION).with("query", text("tide")).with("length", choice_value("50+"));
        assert_eq!(pairs(&search_params(&long, 1, false).unwrap()), vec![("query", "tide"), ("minParts", "50"), ("limit", "15"), ("offset", "0")]);
        let odd = SearchQuery::new(SOURCE_ID, VERSION).with("query", text("tide"))
            .with("length", choice_value("999")).with("updated", choice_value("never"));
        assert_eq!(pairs(&search_params(&odd, 1, false).unwrap()), vec![("query", "tide"), ("limit", "15"), ("offset", "0")]);
    }
}
