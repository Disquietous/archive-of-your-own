//! Literotica's story search as static configuration: the fields of the
//! site's own advanced form (the gear beside the search box) and the
//! request that form sends. Nothing here goes beyond what the form can
//! send. The site answers `/search/stories` with JSON; its parameters
//! travel as one JSON object. The member search takes a name and nothing
//! else here (`Source::search_users`).

use serde_json::{json, Map, Value};

use crate::source::search::{opt, FieldOption, FieldValue, LibraryBinding, SearchField, SearchQuery, SearchSchema,
                            SearchSection, SortSpec};

use super::SOURCE_ID;

pub const VERSION: u32 = 1;

/// The site's id for English, the language every search here is run in
/// (the site sends its current language with each search; its form has
/// no language field).
const ENGLISH: u64 = 1;

/// The form's story categories, by the site's id.
pub const CATEGORIES: &[(&str, &str)] = &[
    ("2", "Erotic Couplings"), ("3", "Reviews & Essays"), ("4", "Exhibitionist & Voyeur"), ("5", "Fetish"),
    ("6", "Gay Male"), ("7", "Group Sex"), ("8", "How To"), ("9", "Taboo/Incest"), ("10", "Interracial Love"),
    ("11", "Lesbian Sex"), ("12", "Loving Wives"), ("13", "Reluctance/NonConsent"), ("14", "NonHuman"),
    ("15", "Romance"), ("16", "Toys & Masturbation"), ("26", "Mature"), ("27", "Fan Fiction & Celebrities"),
    ("28", "Chain Stories"), ("29", "Mind Control"), ("31", "BDSM"), ("32", "Non-English"),
    ("33", "Novels and Novellas"), ("34", "Humor & Satire"), ("35", "Non-Erotic"), ("37", "Anal"),
    ("38", "Sci-Fi & Fantasy"), ("39", "Audio"), ("40", "First Time"), ("45", "Illustrated"),
    ("48", "Transgender"), ("51", "Erotic Horror"), ("53", "Letters & Transcripts"), ("58", "Crossdressing"),
];

const WHERE: &[(&str, &str)] = &[
    ("text", "Story Titles, Text"), ("desc", "Story Titles"), ("tags", "Story Tags"),
];

const PERIODS: &[(&str, &str)] = &[
    ("all", "Any Date"), ("1 week", "One Week"), ("1 month", "One Month"), ("3 month", "Three Months"),
    ("6 month", "Six Months"), ("1 year", "One Year"),
];

const SORTS: &[(&str, &str)] = &[
    ("relevancy", "Relevancy"), ("date", "Date"), ("vote", "Vote Score"), ("comments", "Number of Comments"),
];

fn options(table: &[(&str, &str)]) -> Vec<FieldOption> {
    table.iter().map(|(v, l)| opt(v, l)).collect()
}

fn choice_value(value: &str) -> FieldValue {
    FieldValue::Choice { value: value.to_string() }
}

/// A story category's name by the site's id.
pub fn category_name(id: u64) -> Option<&'static str> {
    let id = id.to_string();
    CATEGORIES.iter().find(|(v, _)| *v == id).map(|(_, name)| *name)
}

pub fn schema() -> SearchSchema {
    SearchSchema {
        source: SOURCE_ID.to_string(),
        version: VERSION,
        primary: "query".to_string(),
        sections: vec![
            SearchSection::new("search", "Search for Stories", vec![
                SearchField::text("query", "Search for Stories").bound(LibraryBinding::FullText),
                SearchField::choice("where", "Search only", options(WHERE), None).default(choice_value("text")),
                SearchField::choice("period", "Find stories from the last", options(PERIODS), None)
                    .default(choice_value("all")),
                SearchField::choice("time_direction", "Newer or older", vec![
                    opt("newer", "and Newer"), opt("before", "and Older"),
                ], None).default(choice_value("newer")),
                SearchField::text("author", "Search by author's name").bound(LibraryBinding::Author),
                SearchField::toggle("editors_choice", "Editor's choice"),
                SearchField::toggle("winner", "Contest winners"),
                SearchField::toggle("popular", "Most popular"),
                SearchField::checkboxes("categories", "Categories", options(CATEGORIES)).tag("freeform"),
            ]),
        ],
        sort: Some(SortSpec {
            columns: options(SORTS),
            directions: vec![opt("desc", "in Descending Order"), opt("asc", "in Ascending Order")],
            default_column: "relevancy".to_string(),
            default_direction: "desc".to_string(),
        }),
    }
}

/// The parameters the site's form would send for `q`, page `page`
/// (1-based). Like the form, a field left at its default is not sent,
/// and nothing is sent without search words — None then.
pub fn search_params(q: &SearchQuery, page: u32) -> Option<Value> {
    let text = q.text("query").map(str::trim).filter(|t| !t.is_empty())?;
    let mut p = Map::new();
    p.insert("q".into(), json!(text));
    p.insert("page".into(), json!(page.max(1)));
    p.insert("languages".into(), json!([ENGLISH]));
    if let Some(scope) = q.text("where").filter(|w| matches!(*w, "desc" | "tags")) {
        p.insert("where".into(), json!(scope));
    }
    if let Some(period) = q.text("period").filter(|v| *v != "all" && PERIODS.iter().any(|(p, _)| p == v)) {
        let older = q.text("time_direction") == Some("before");
        p.insert("period".into(), json!(if older { format!("before {period}") } else { period.to_string() }));
    }
    if let Some(column) = q.sort_column.as_deref().filter(|c| matches!(*c, "date" | "vote" | "comments")) {
        let ascending = q.sort_direction.as_deref() == Some("asc");
        p.insert("sort".into(), json!(if ascending { format!("{column} asc") } else { column.to_string() }));
    }
    if let Some(author) = q.text("author").map(str::trim).filter(|a| !a.is_empty()) {
        p.insert("author".into(), json!(author));
    }
    for (key, sent) in [("editors_choice", "editorsChoice"), ("winner", "winner"), ("popular", "popular")] {
        if q.flag(key) { p.insert(sent.into(), json!(true)); }
    }
    if let Some((picked, _, _)) = q.set("categories") {
        let ids: Vec<u64> = CATEGORIES.iter().filter(|(v, _)| picked.iter().any(|p| p == v))
            .filter_map(|(v, _)| v.parse().ok()).collect();
        if !ids.is_empty() { p.insert("categories".into(), json!(ids)); }
    }
    Some(Value::Object(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::search::FieldKind;

    fn text(value: &str) -> FieldValue {
        FieldValue::Text { value: value.to_string() }
    }

    #[test]
    fn schema_is_well_formed() {
        let s = schema();
        s.validate().unwrap();
        assert!(matches!(&s.field("categories").unwrap().kind, FieldKind::ChoiceSet { options, exclude: false, .. } if options.len() == 33));
        let sort = s.sort.unwrap();
        assert_eq!((sort.columns.len(), sort.default_column.as_str(), sort.default_direction.as_str()), (4, "relevancy", "desc"));
        assert_eq!(category_name(31), Some("BDSM"));
        assert_eq!(category_name(1), None);
    }

    #[test]
    fn a_bare_query_sends_only_the_words_page_and_language() {
        let q = SearchQuery::new(SOURCE_ID, VERSION).with("query", text(" lighthouse "))
            .with("where", choice_value("text")).with("period", choice_value("all"))
            .with("time_direction", choice_value("before")).sorted("relevancy", "asc");
        assert_eq!(search_params(&q, 1).unwrap(), json!({ "q": "lighthouse", "page": 1, "languages": [1] }));
        assert_eq!(search_params(&q, 0).unwrap()["page"], json!(1));
    }

    #[test]
    fn nothing_is_sent_without_search_words() {
        let q = SearchQuery::new(SOURCE_ID, VERSION).with("author", text("Saltwick"));
        assert!(search_params(&q, 1).is_none());
        assert!(search_params(&q.with("query", text("   ")), 1).is_none());
    }

    #[test]
    fn encodes_the_forms_fields() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("query", text("tide"))
            .with("where", choice_value("tags"))
            .with("period", choice_value("3 month"))
            .with("time_direction", choice_value("before"))
            .with("author", text("Saltwick"))
            .with("editors_choice", FieldValue::Bool { value: true })
            .with("winner", FieldValue::Bool { value: true })
            .with("popular", FieldValue::Bool { value: true })
            .with("categories", FieldValue::Set { include: vec!["38".into(), "15".into()], exclude: Vec::new(), mode: None })
            .sorted("vote", "asc");
        assert_eq!(search_params(&q, 3).unwrap(), json!({
            "q": "tide", "page": 3, "languages": [1], "where": "tags", "period": "before 3 month",
            "sort": "vote asc", "author": "Saltwick", "editorsChoice": true, "winner": true, "popular": true,
            "categories": [15, 38],
        }));
        let newer = SearchQuery::new(SOURCE_ID, VERSION).with("query", text("tide"))
            .with("period", choice_value("3 month")).with("time_direction", choice_value("newer")).sorted("date", "desc");
        let sent = search_params(&newer, 1).unwrap();
        assert_eq!((sent["period"].as_str(), sent["sort"].as_str()), (Some("3 month"), Some("date")));
    }

    #[test]
    fn values_outside_the_form_are_not_sent() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("query", text("tide"))
            .with("where", choice_value("everywhere"))
            .with("period", choice_value("2 decades"))
            .with("categories", FieldValue::Set { include: vec!["99999".into()], exclude: Vec::new(), mode: None })
            .sorted("length", "asc");
        assert_eq!(search_params(&q, 1).unwrap(), json!({ "q": "tide", "page": 1, "languages": [1] }));
    }
}
