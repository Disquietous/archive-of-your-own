//! Hentai Foundry's story search (`/search/stories`) as static
//! configuration: the fields of the site's own form and the query string
//! that form submits. Nothing here goes beyond what the form can send;
//! narrowing further happens in the app, on fetched works. The site has
//! no sort parameter — order is a setting saved in the reader's account,
//! which this app never changes — so the schema declares no sort and
//! results arrive in the account's order. Form source:
//! design/hentaifoundry/search.html.

use crate::source::search::{fmt_num, opt, FieldKind, FieldOption, FieldValue, LibraryBinding, SearchField, SearchQuery,
                            SearchSchema, SearchSection};

use super::{BASE_URL, SOURCE_ID};

pub const VERSION: u32 = 1;

/// The form's category list (`limit[cat][value]`). These are the form's
/// own values; a category page's URL numbers the same categories
/// differently, so neither is derived from the other.
const CATEGORIES: &[(&str, &str)] = &[
    ("5", "Original"), ("9", "Anal"), ("474", "Bestiality"), ("10", "Bondage"), ("11", "Bukkake"),
    ("75", "Comics"), ("12", "Crossdressing"), ("453", "Cumshot"), ("481", "Double Penetration"),
    ("13", "Fantasy (Witches, Elves...)"), ("137", "Fat People"), ("464", "Feet"), ("327", "Femdom"),
    ("472", "Frottage"), ("8", "Furries (Anthro)"), ("14", "Futanari (Dickgirls)"), ("71", "Gang Bang"),
    ("15", "Guro (Gore)"), ("16", "Historic Setting"), ("317", "Huge Breasts"), ("422", "Incest"),
    ("139", "Inflationism"), ("473", "Masturbation"), ("17", "Neko Shoujo & Kemonomimi"), ("68", "+ Oral"),
    ("163", "Pin-ups"), ("18", "Pregnant"), ("483", "Scat"), ("152", "Sci-fi (Aliens, Robots...)"),
    ("19", "Tentacles"), ("20", "Uniforms"), ("399", "Watersports"), ("491", "Wrestling"),
];

/// The graded content kinds (`limit[rating][rating_{name}]`): each takes a
/// direction (at most / at least) and a level 0–3, with the site's own
/// words for the levels.
const GRADED: &[(&str, &str, [&str; 4])] = &[
    ("nudity", "Nudity", ["None", "Mild Nudity", "Moderate Nudity", "Explicit Nudity"]),
    ("violence", "Violence", ["None", "Comic or Mild Violence", "Moderate Violence", "Explicit or Graphic Violence"]),
    ("profanity", "Profanity", ["None", "Mild Profanity", "Moderate Profanity", "Proliferous or Severe Profanity"]),
    ("racism", "Racism", ["None", "Mild Racist themes or content", "Racist themes or content", "Strong racist themes or content"]),
    ("sex", "Sexual content", ["None", "Mild suggestive content", "Moderate suggestive or sexual content", "Explicit or adult sexual content"]),
    ("spoilers", "Spoiler Warning", ["None", "Mild Spoiler Warning", "Moderate Spoiler Warning", "Major Spoiler Warning"]),
];

/// The yes/no content kinds: each is allowed (not sent as a limit),
/// blocked or required.
const FLAGS: &[(&str, &str)] = &[
    ("yaoi", "Yaoi"), ("yuri", "Yuri"), ("teen", "Teen"), ("guro", "Guro"), ("furry", "Furry"),
    ("beast", "Beast"), ("male", "Male"), ("female", "Female"), ("futa", "Futa"), ("other", "Other"),
    ("scat", "Scat"), ("incest", "Incest"), ("rape", "Rape"), ("solo_m", "Male only"), ("solo_f", "Female only"),
];

fn options(table: &[(&str, &str)]) -> Vec<FieldOption> {
    table.iter().map(|(v, l)| opt(v, l)).collect()
}

fn choice_value(value: &str) -> FieldValue {
    FieldValue::Choice { value: value.to_string() }
}

pub fn schema() -> SearchSchema {
    let mut levels = Vec::new();
    for (name, label, words) in GRADED {
        levels.push(SearchField::choice(&format!("{name}_limit"), label,
            vec![opt("<=", "At Most"), opt(">=", "At Least")], Some("Ignore")));
        levels.push(SearchField::choice(&format!("{name}_level"), &format!("{label} level"),
            words.iter().enumerate().map(|(i, w)| opt(&i.to_string(), w)).collect(), None)
            .default(choice_value("3")));
    }
    let mut flags = SearchField::text("flags", "Content");
    // Include = the site's "Require", exclude = its "Block"; an option in
    // neither is its "Allow". The form has no AND/OR mode.
    flags.kind = FieldKind::ChoiceSet { options: options(FLAGS), exclude: true, modes: Vec::new(), default_mode: None };
    SearchSchema {
        source: SOURCE_ID.to_string(),
        version: VERSION,
        primary: "query".to_string(),
        sections: vec![
            SearchSection::new("search", "Search Stories", vec![
                SearchField::text("query", "Search Query").bound(LibraryBinding::FullText),
                SearchField::choice("search_in", "Search in", vec![
                    opt("all", "All Fields"), opt("title", "Title"), opt("keywords", "Keywords"), opt("description", "Description"),
                ], None).default(choice_value("all")),
                SearchField::choice("length_compare", "Limit Length", vec![
                    opt(">", "More than"), opt("<", "Less than"), opt("=", "Exactly"),
                ], None).default(choice_value(">")),
                SearchField::number("length", "Length", Some(0.0), None, 1.0),
                SearchField::choice("length_unit", "Length in", vec![opt("words", "Words"), opt("KB", "KB")], None)
                    .default(choice_value("words")),
                SearchField::choice("status", "Completion Status", vec![opt("0", "Incomplete"), opt("1", "Complete")], Some("Any")),
                SearchField::choice("category", "Category", options(CATEGORIES), Some("Any")),
                SearchField::toggle("include_sub", "Include Subcategories"),
                SearchField::text("author", "Username").bound(LibraryBinding::Author),
            ]),
            SearchSection::new("rating", "Limit Rating", {
                let mut fields = levels;
                fields.push(flags);
                fields
            }).collapsed(),
        ],
        sort: None,
    }
}

fn encode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

fn push(parts: &mut Vec<String>, key: &str, value: &str) {
    parts.push(format!("{}={}", encode(key), encode(value)));
}

/// The address the site's form would load for `q`, page `page` (1-based).
/// A limit is sent only when its field has a value, each behind the
/// form's own "on" switch.
pub fn search_url(q: &SearchQuery, page: u32) -> String {
    let mut parts = Vec::new();
    push(&mut parts, "page", &page.max(1).to_string());
    push(&mut parts, "query", q.text("query").unwrap_or(""));
    push(&mut parts, "search_in", q.text("search_in").unwrap_or("all"));
    if let Some(length) = q.number("length") {
        push(&mut parts, "limit[length][on]", "1");
        push(&mut parts, "limit[length][compare]", q.text("length_compare").unwrap_or(">"));
        push(&mut parts, "limit[length][value]", &fmt_num(length));
        push(&mut parts, "limit[length][type]", q.text("length_unit").unwrap_or("words"));
    }
    if let Some(status) = q.text("status").filter(|s| matches!(*s, "0" | "1")) {
        push(&mut parts, "limit[status][on]", "1");
        push(&mut parts, "limit[status][value]", status);
    }
    if let Some(category) = q.text("category").filter(|c| CATEGORIES.iter().any(|(v, _)| v == c)) {
        push(&mut parts, "limit[cat][on]", "1");
        push(&mut parts, "limit[cat][value]", category);
        if q.flag("include_sub") { push(&mut parts, "limit[cat][includeSub]", "1"); }
    }
    if let Some(author) = q.text("author").filter(|a| !a.is_empty()) {
        push(&mut parts, "limit[user][on]", "1");
        push(&mut parts, "limit[user][username]", author);
    }
    let mut rating = Vec::new();
    for (name, _, _) in GRADED {
        let Some(limit) = q.text(&format!("{name}_limit")).filter(|l| matches!(*l, "<=" | ">=")) else { continue };
        let level = q.text(&format!("{name}_level")).filter(|l| matches!(*l, "0" | "1" | "2" | "3")).unwrap_or("3");
        push(&mut rating, &format!("limit[rating][rating_{name}][action]"), limit);
        push(&mut rating, &format!("limit[rating][rating_{name}][value]"), level);
    }
    if let Some((require, block, _)) = q.set("flags") {
        for (name, _) in FLAGS {
            let action = if require.iter().any(|v| v == name) { "1" }
                         else if block.iter().any(|v| v == name) { "0" }
                         else { continue };
            push(&mut rating, &format!("limit[rating][rating_{name}][action]"), action);
        }
    }
    if !rating.is_empty() {
        push(&mut parts, "limit[rating][on]", "1");
        parts.append(&mut rating);
    }
    push(&mut parts, "yt0", "Search");
    format!("{BASE_URL}/search/stories?{}", parts.join("&"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_is_well_formed() {
        let s = schema();
        s.validate().unwrap();
        assert!(s.sort.is_none(), "order is the account's own setting");
        assert!(s.sections[1].collapsed);
        assert!(matches!(&s.field("category").unwrap().kind, FieldKind::Choice { options, .. } if options.len() == 33));
        assert!(matches!(&s.field("flags").unwrap().kind, FieldKind::ChoiceSet { options, exclude: true, .. } if options.len() == 15));
        for (name, _, _) in GRADED {
            assert!(s.field(&format!("{name}_limit")).is_some() && s.field(&format!("{name}_level")).is_some());
        }
    }

    #[test]
    fn a_bare_query_sends_no_limits() {
        let q = SearchQuery::new(SOURCE_ID, VERSION).with("query", FieldValue::Text { value: "glass orchard".into() });
        assert_eq!(search_url(&q, 1),
                   "https://www.hentai-foundry.com/search/stories?page=1&query=glass+orchard&search_in=all&yt0=Search");
        // The compare and unit defaults ride along without a length and send nothing.
        let q = q.with("length_compare", choice_value(">")).with("length_unit", choice_value("words"))
            .with("sex_level", choice_value("3"));
        assert!(!search_url(&q, 1).contains("limit"));
    }

    #[test]
    fn encodes_the_forms_limits() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("query", FieldValue::Text { value: "tide".into() })
            .with("search_in", choice_value("title"))
            .with("length_compare", choice_value(">"))
            .with("length", FieldValue::Number { value: 75000.0 })
            .with("length_unit", choice_value("words"))
            .with("status", choice_value("1"))
            .with("category", choice_value("14"))
            .with("include_sub", FieldValue::Bool { value: true })
            .with("author", FieldValue::Text { value: "Saltwick".into() })
            .with("sex_limit", choice_value(">="))
            .with("sex_level", choice_value("2"))
            .with("violence_limit", choice_value("<="))
            .with("flags", FieldValue::Set { include: vec!["yuri".into()], exclude: vec!["guro".into(), "scat".into()], mode: None });
        assert_eq!(search_url(&q, 2), "https://www.hentai-foundry.com/search/stories?page=2&query=tide&search_in=title\
&limit%5Blength%5D%5Bon%5D=1&limit%5Blength%5D%5Bcompare%5D=%3E&limit%5Blength%5D%5Bvalue%5D=75000&limit%5Blength%5D%5Btype%5D=words\
&limit%5Bstatus%5D%5Bon%5D=1&limit%5Bstatus%5D%5Bvalue%5D=1\
&limit%5Bcat%5D%5Bon%5D=1&limit%5Bcat%5D%5Bvalue%5D=14&limit%5Bcat%5D%5BincludeSub%5D=1\
&limit%5Buser%5D%5Bon%5D=1&limit%5Buser%5D%5Busername%5D=Saltwick\
&limit%5Brating%5D%5Bon%5D=1\
&limit%5Brating%5D%5Brating_violence%5D%5Baction%5D=%3C%3D&limit%5Brating%5D%5Brating_violence%5D%5Bvalue%5D=3\
&limit%5Brating%5D%5Brating_sex%5D%5Baction%5D=%3E%3D&limit%5Brating%5D%5Brating_sex%5D%5Bvalue%5D=2\
&limit%5Brating%5D%5Brating_yuri%5D%5Baction%5D=1&limit%5Brating%5D%5Brating_guro%5D%5Baction%5D=0&limit%5Brating%5D%5Brating_scat%5D%5Baction%5D=0\
&yt0=Search");
    }

    #[test]
    fn values_outside_the_form_are_not_sent() {
        let q = SearchQuery::new(SOURCE_ID, VERSION)
            .with("status", choice_value("maybe"))
            .with("category", choice_value("99999"))
            .with("sex_limit", choice_value("!="));
        assert!(!search_url(&q, 1).contains("limit"));
    }
}
