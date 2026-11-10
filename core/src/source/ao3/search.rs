//! AO3's works search as static configuration: the fields of
//! `/works/search`, their option ids and the `work_search[...]` encoding.
//! Transcribed from the archive's form (option ids are the archive's own
//! tag ids and have been stable for years); a form change ships as a new
//! `VERSION`.

use crate::source::search::{opt, FieldOption, SearchField, SearchQuery, SearchSchema, SearchSection, SortSpec};
use crate::source::search::fmt_num;

pub const VERSION: u32 = 1;

/// AO3 language ids: a mix of ISO 639-1/2/3 codes and specials ("ptBR").
/// Regenerate from a saved form with `scripts/gen-ao3-languages.py`.
#[path = "languages.rs"]
mod languages;

pub fn schema() -> SearchSchema {
    let any_field = SearchField::text("query", "Any Field")
        .hint("Search all fields")
        .bound(crate::source::search::LibraryBinding::FullText);
    let language_options: Vec<FieldOption> = languages::LANGUAGES.iter().map(|(id, name)| opt(id, name)).collect();

    SearchSchema {
        source: crate::models::SOURCE_AO3.to_string(),
        version: VERSION,
        primary: "query".to_string(),
        sections: vec![
            SearchSection::new("info", "Work Info", vec![
                any_field,
                SearchField::text("title", "Title").column("title"),
                SearchField::text("author", "Author/Artist").bound(crate::source::search::LibraryBinding::Author),
                SearchField::text("revised_at", "Date Updated")
                    .hint("e.g. > 2 weeks ago, 2023-01-01, < 1 year ago")
                    .column("revised_at"),
                SearchField::choice("complete", "Completion Status", vec![
                    opt("T", "Complete works only"),
                    opt("F", "Works in progress only"),
                ], Some("All works")).column("complete"),
                SearchField::choice("crossover", "Crossovers", vec![
                    opt("F", "Exclude crossovers"),
                    opt("T", "Show only crossovers"),
                ], Some("Include crossovers")),
                SearchField::toggle("single_chapter", "Single Chapter").column("chapter_count"),
                SearchField::count_range("word_count", "Word Count").column("word_count"),
                SearchField::choice("language", "Language", language_options, Some("Any")).column("language"),
            ]),
            SearchSection::new("tags", "Work Tags", vec![
                SearchField::tag_text("fandom", "Fandoms", "fandom").tag("fandom"),
                SearchField::checkboxes("rating", "Rating", vec![
                    opt("9", "Not Rated"),
                    opt("10", "General Audiences"),
                    opt("11", "Teen And Up Audiences"),
                    opt("12", "Mature"),
                    opt("13", "Explicit"),
                ]).tag("rating"),
                SearchField::checkboxes("warnings", "Archive Warnings", vec![
                    opt("14", "Creator Chose Not To Use Archive Warnings"),
                    opt("17", "Graphic Depictions Of Violence"),
                    opt("18", "Major Character Death"),
                    opt("16", "No Archive Warnings Apply"),
                    opt("19", "Rape/Non-Con"),
                    opt("20", "Underage Sex"),
                ]).tag("warning"),
                SearchField::checkboxes("categories", "Categories", vec![
                    opt("116", "F/F"),
                    opt("22", "F/M"),
                    opt("21", "Gen"),
                    opt("23", "M/M"),
                    opt("2246", "Multi"),
                    opt("24", "Other"),
                ]).tag("category"),
                SearchField::tag_text("character", "Characters", "character").tag("character"),
                SearchField::tag_text("relationship", "Relationships", "relationship").tag("relationship"),
                SearchField::tag_text("freeform", "Additional Tags", "freeform").tag("freeform"),
            ]),
            SearchSection::new("stats", "Work Stats", vec![
                SearchField::count_range("hits", "Hits").column("hits"),
                SearchField::count_range("kudos", "Kudos").column("kudos"),
                SearchField::count_range("comments", "Comments").column("comments"),
                SearchField::count_range("bookmarks", "Bookmarks").column("bookmarks"),
            ]),
        ],
        sort: Some(SortSpec {
            columns: vec![
                opt("_score", "Best Match"),
                opt("authors_to_sort_on", "Creator"),
                opt("title_to_sort_on", "Title"),
                opt("created_at", "Date Posted"),
                opt("revised_at", "Date Updated"),
                opt("word_count", "Word Count"),
                opt("hits", "Hits"),
                opt("kudos_count", "Kudos"),
                opt("comments_count", "Comments"),
                opt("bookmarks_count", "Bookmarks"),
            ],
            directions: vec![opt("desc", "Descending"), opt("asc", "Ascending")],
            default_column: "_score".to_string(),
            default_direction: "desc".to_string(),
        }),
    }
}

/// Field key → the archive's parameter name, and the kind of encoding.
const TEXT: &[(&str, &str)] = &[
    ("query", "work_search[query]"),
    ("title", "work_search[title]"),
    ("author", "work_search[creators]"),
    ("revised_at", "work_search[revised_at]"),
    ("complete", "work_search[complete]"),
    ("crossover", "work_search[crossover]"),
    ("language", "work_search[language_id]"),
    ("fandom", "work_search[fandom_names]"),
    ("character", "work_search[character_names]"),
    ("relationship", "work_search[relationship_names]"),
    ("freeform", "work_search[freeform_names]"),
];
const RANGES: &[(&str, &str)] = &[
    ("word_count", "work_search[word_count]"),
    ("hits", "work_search[hits]"),
    ("kudos", "work_search[kudos_count]"),
    ("comments", "work_search[comments_count]"),
    ("bookmarks", "work_search[bookmarks_count]"),
];
const SETS: &[(&str, &str)] = &[
    ("rating", "work_search[rating_ids][]"),
    ("warnings", "work_search[archive_warning_ids][]"),
    ("categories", "work_search[category_ids][]"),
];

/// AO3 range syntax: `a-b`, `>a`, `<b` (the open forms are exclusive on
/// the archive; one count of slack on a search bound).
fn fmt_range(min: Option<f64>, max: Option<f64>) -> Option<String> {
    match (min, max) {
        (Some(a), Some(b)) => Some(format!("{}-{}", fmt_num(a), fmt_num(b))),
        (Some(a), None) => Some(format!(">{}", fmt_num(a))),
        (None, Some(b)) => Some(format!("<{}", fmt_num(b))),
        (None, None) => None,
    }
}

/// The `work_search[...]` pairs for a query; repeated keys for checkbox
/// sets. Empty values are left out, so an empty query is an empty list.
pub fn encode(q: &SearchQuery) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    for (key, param) in TEXT {
        if let Some(v) = q.text(key) {
            pairs.push((param.to_string(), v.to_string()));
        }
    }
    if q.flag("single_chapter") {
        pairs.push(("work_search[single_chapter]".to_string(), "1".to_string()));
    }
    for (key, param) in RANGES {
        if let Some(text) = q.range(key).and_then(|(a, b)| fmt_range(a, b)) {
            pairs.push((param.to_string(), text));
        }
    }
    for (key, param) in SETS {
        if let Some((include, _, _)) = q.set(key) {
            for v in include {
                pairs.push((param.to_string(), v.clone()));
            }
        }
    }
    if let Some(column) = q.sort_column.as_deref().filter(|c| !c.is_empty()) {
        pairs.push(("work_search[sort_column]".to_string(), column.to_string()));
    }
    if let Some(direction) = q.sort_direction.as_deref().filter(|d| !d.is_empty()) {
        pairs.push(("work_search[sort_direction]".to_string(), direction.to_string()));
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::search::FieldValue;

    #[test]
    fn schema_is_well_formed() {
        let s = schema();
        s.validate().unwrap();
        assert!(s.field("language").is_some_and(|f| matches!(&f.kind, crate::source::search::FieldKind::Choice { options, .. } if options.iter().any(|o| o.value == "en"))));
        // Every field the encoder knows exists in the schema, and vice versa
        // for the fields the archive takes.
        for (key, _) in TEXT.iter().chain(RANGES).chain(SETS) {
            assert!(s.field(key).is_some(), "encoder key {key} missing from schema");
        }
    }

    #[test]
    fn encodes_the_archive_parameters() {
        let q = SearchQuery::new("ao3", VERSION)
            .with("query", FieldValue::Text { value: " dragons ".into() })
            .with("title", FieldValue::Text { value: "".into() })
            .with("word_count", FieldValue::Range { min: Some(1000.0), max: Some(5000.0) })
            .with("kudos", FieldValue::Range { min: Some(100.0), max: None })
            .with("hits", FieldValue::Range { min: None, max: Some(50.0) })
            .with("single_chapter", FieldValue::Bool { value: true })
            .with("complete", FieldValue::Choice { value: "T".into() })
            .with("language", FieldValue::Choice { value: "en".into() })
            .with("rating", FieldValue::Set { include: vec!["12".into(), "13".into()], exclude: vec![], mode: None })
            .with("categories", FieldValue::Set { include: vec![], exclude: vec![], mode: None })
            .sorted("kudos_count", "desc");
        let pairs = encode(&q);
        let expect = |k: &str, v: &str| assert!(pairs.contains(&(k.to_string(), v.to_string())), "missing {k}={v} in {pairs:?}");
        expect("work_search[query]", "dragons");
        expect("work_search[word_count]", "1000-5000");
        expect("work_search[kudos_count]", ">100");
        expect("work_search[hits]", "<50");
        expect("work_search[single_chapter]", "1");
        expect("work_search[complete]", "T");
        expect("work_search[language_id]", "en");
        expect("work_search[rating_ids][]", "12");
        expect("work_search[rating_ids][]", "13");
        expect("work_search[sort_column]", "kudos_count");
        expect("work_search[sort_direction]", "desc");
        assert!(!pairs.iter().any(|(k, _)| k == "work_search[title]"), "blank text omitted");
        assert!(!pairs.iter().any(|(k, _)| k == "work_search[category_ids][]"), "empty set omitted");
        assert_eq!(pairs.len(), 11);
        assert!(encode(&SearchQuery::new("ao3", VERSION)).is_empty());
    }
}
