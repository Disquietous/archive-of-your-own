//! SQL-backed library works search.
//!
//! `LocalSearchCriteria` parses into a typed predicate IR, and one compiler
//! turns the IR into a single parameterized SELECT of matching work ids —
//! filter and sort run in SQLite instead of hydrating every cached work.
//! The in-memory filter it replaces (`work_matches`/`sort_filtered` in
//! works.rs) is the parity oracle: every predicate here must accept exactly
//! the works the oracle accepts, including its quirks (blank or unparseable
//! inputs don't filter; case-insensitivity is Rust `to_lowercase` for
//! substrings — hence the registered `ao3_lower` SQL function — and ASCII
//! folding for the equality matches that use `eq_ignore_ascii_case`).

use std::collections::HashMap;

use rusqlite::params;
use rusqlite::types::Value;

use crate::error::AppError;
use crate::models::{LocalSearchCriteria, Rating, Warning};

use super::{map_sql, rating_to_str, Storage};

// ---------------------------------------------------------------------------
// Bitmask vocabularies (works.warnings_mask / works.categories_mask)
// ---------------------------------------------------------------------------

/// Bit assignments are storage format (v11) — append-only, never renumber.
fn warning_bit(w: &Warning) -> i64 {
    match w {
        Warning::None => 1 << 0,
        Warning::CreatorChoseNotToWarn => 1 << 1,
        Warning::Violence => 1 << 2,
        Warning::CharacterDeath => 1 << 3,
        Warning::Underage => 1 << 4,
        Warning::Noncon => 1 << 5,
    }
}

pub(super) fn warnings_mask(warnings: &[Warning]) -> i64 {
    warnings.iter().fold(0, |m, w| m | warning_bit(w))
}

/// AO3's fixed category vocabulary. Labels compare ASCII-case-insensitively
/// (the oracle uses `eq_ignore_ascii_case`); anything else gets no bit and
/// falls back to a JSON-list equality predicate at query time.
const CATEGORIES: [&str; 6] = ["F/F", "F/M", "Gen", "M/M", "Multi", "Other"];

fn category_bit(label: &str) -> Option<i64> {
    CATEGORIES
        .iter()
        .position(|c| c.eq_ignore_ascii_case(label))
        .map(|i| 1 << i)
}

pub(super) fn categories_mask(categories: &[String]) -> i64 {
    categories.iter().fold(0, |m, c| m | category_bit(c).unwrap_or(0))
}

// ---------------------------------------------------------------------------
// Predicate IR
// ---------------------------------------------------------------------------

/// AO3's numeric range grammar, parsed. Mirrors `range_matches`.
#[derive(Debug, PartialEq)]
enum NumRange {
    Ge(u64),
    Le(u64),
    Gt(u64),
    Lt(u64),
    Eq(u64),
    Between(u64, u64),
}

/// A "Date Updated" comparison. Relative expressions ("< 2 weeks ago")
/// resolve to a calendar cutoff at parse time; for those, `<` means less
/// time ago (more recent) and `>` longer ago, matching AO3. Absolute dates
/// compare lexically, prefixes included.
#[derive(Debug, PartialEq)]
enum DateCmp {
    RelSince(String),
    RelBefore(String),
    RelOn(String),
    AbsBefore(String),
    AbsAfter(String),
    AbsPrefix(String),
}

/// One filter from the search form, typed. Semantics live here and in the
/// compiler — never string-built at call sites.
#[derive(Debug, PartialEq)]
enum Predicate {
    /// Free-text query: substring across title, summary, authors, and every
    /// tag name on the work.
    FreeText(String),
    TitleContains(String),
    /// One comma-separated Creators entry (entries AND together).
    CreatorContains(String),
    /// One comma-separated entry from a tag-name field: the work must have
    /// a `tag_type` join row whose tag name contains the text.
    TagNameContains { tag_type: &'static str, needle: String },
    /// Rating labels OR (a work has one rating), pre-mapped to the stored
    /// rating strings.
    RatingIn(Vec<&'static str>),
    /// Warning checkboxes AND: every bit must be present.
    WarningsAll(i64),
    /// Category checkboxes AND, fixed-vocab bits combined into one mask.
    CategoriesAll(i64),
    /// A category label outside the fixed vocab: exact ASCII-ci match
    /// against the stored JSON list, mirroring the oracle.
    CategoryEquals(String),
    Complete(bool),
    Crossover(bool),
    SingleChapter,
    /// ASCII-ci equality, pre-lowered.
    LanguageEquals(String),
    Number { column: &'static str, range: NumRange },
    Revised(DateCmp),
}

/// Parse the form into predicates. Blank fields produce none — the blank
/// form matches the whole library, like the oracle.
fn parse_criteria(c: &LocalSearchCriteria) -> Vec<Predicate> {
    let mut preds = Vec::new();

    let q = c.query.trim();
    if !q.is_empty() {
        preds.push(Predicate::FreeText(q.to_lowercase()));
    }
    let title = c.title.trim();
    if !title.is_empty() {
        preds.push(Predicate::TitleContains(title.to_lowercase()));
    }
    for name in split_names(&c.creators) {
        preds.push(Predicate::CreatorContains(name.to_lowercase()));
    }
    for (field, tag_type) in [
        (&c.fandom_names, "fandom"),
        (&c.character_names, "character"),
        (&c.relationship_names, "relationship"),
        (&c.freeform_names, "freeform"),
    ] {
        for name in split_names(field) {
            preds.push(Predicate::TagNameContains { tag_type, needle: name.to_lowercase() });
        }
    }

    if !c.ratings.is_empty() {
        preds.push(Predicate::RatingIn(
            c.ratings.iter().map(|l| rating_to_str(&Rating::from_ao3_tag(l))).collect(),
        ));
    }
    if !c.warnings.is_empty() {
        let mask = c.warnings.iter().fold(0, |m, l| m | warning_bit(&Warning::from_ao3_tag(l)));
        preds.push(Predicate::WarningsAll(mask));
    }
    let mut category_mask = 0i64;
    for label in &c.categories {
        match category_bit(label) {
            Some(bit) => category_mask |= bit,
            None => preds.push(Predicate::CategoryEquals(label.to_ascii_lowercase())),
        }
    }
    if category_mask != 0 {
        preds.push(Predicate::CategoriesAll(category_mask));
    }

    match c.complete.as_str() {
        "T" => preds.push(Predicate::Complete(true)),
        "F" => preds.push(Predicate::Complete(false)),
        _ => {}
    }
    match c.crossover.as_str() {
        "T" => preds.push(Predicate::Crossover(true)),
        "F" => preds.push(Predicate::Crossover(false)),
        _ => {}
    }
    if c.single_chapter {
        preds.push(Predicate::SingleChapter);
    }
    let language = c.language.trim();
    if !language.is_empty() {
        preds.push(Predicate::LanguageEquals(language.to_ascii_lowercase()));
    }

    for (expr, column) in [
        (&c.word_count, "word_count"),
        (&c.hits, "hits"),
        (&c.kudos_count, "kudos"),
        (&c.comments_count, "comments"),
        (&c.bookmarks_count, "bookmarks"),
    ] {
        if let Some(range) = parse_range(expr) {
            preds.push(Predicate::Number { column, range });
        }
    }
    if let Some(cmp) = parse_revised(&c.revised_at) {
        preds.push(Predicate::Revised(cmp));
    }
    preds
}

/// Comma-separated name fields: entries AND together; blanks drop out.
fn split_names(field: &str) -> impl Iterator<Item = &str> {
    field.split(',').map(str::trim).filter(|name| !name.is_empty())
}

/// The `range_matches` grammar as a parser: "500", ">500", "<500", ">=500",
/// "<=500", "100-5000". Blank or unparseable expressions return None — they
/// don't filter.
fn parse_range(expr: &str) -> Option<NumRange> {
    let expr: String = expr.chars().filter(|c| *c != ',' && !c.is_whitespace()).collect();
    if expr.is_empty() {
        return None;
    }
    let parsed = |s: &str| s.parse::<u64>().ok();
    if let Some(n) = expr.strip_prefix(">=").and_then(parsed) {
        return Some(NumRange::Ge(n));
    }
    if let Some(n) = expr.strip_prefix("<=").and_then(parsed) {
        return Some(NumRange::Le(n));
    }
    if let Some(n) = expr.strip_prefix('>').and_then(parsed) {
        return Some(NumRange::Gt(n));
    }
    if let Some(n) = expr.strip_prefix('<').and_then(parsed) {
        return Some(NumRange::Lt(n));
    }
    if let Some((lo, hi)) = expr.split_once('-') {
        if let (Some(lo), Some(hi)) = (parsed(lo), parsed(hi)) {
            return Some(NumRange::Between(lo, hi));
        }
    }
    parsed(&expr).map(NumRange::Eq)
}

/// `revised_matches` as a parser — same operator and relative-date handling.
fn parse_revised(expr: &str) -> Option<DateCmp> {
    let expr = expr.trim();
    if expr.is_empty() {
        return None;
    }
    let (op, rest) = match expr.as_bytes()[0] {
        b'<' => ('<', expr[1..].trim_start_matches('=').trim()),
        b'>' => ('>', expr[1..].trim_start_matches('=').trim()),
        _ => ('=', expr),
    };
    if let Some(cutoff) = Storage::relative_date(rest) {
        let cutoff = cutoff.format("%Y-%m-%d").to_string();
        return Some(match op {
            '<' => DateCmp::RelSince(cutoff),
            '>' => DateCmp::RelBefore(cutoff),
            _ => DateCmp::RelOn(cutoff),
        });
    }
    Some(match op {
        '<' => DateCmp::AbsBefore(rest.to_string()),
        '>' => DateCmp::AbsAfter(rest.to_string()),
        _ => DateCmp::AbsPrefix(rest.to_string()),
    })
}

// ---------------------------------------------------------------------------
// Compiler
// ---------------------------------------------------------------------------

/// Range bounds land in i64 columns; a garbage bound past i64::MAX clamps
/// (nothing stored is ever that large, so comparisons keep their meaning).
fn num(n: u64) -> Value {
    Value::Integer(i64::try_from(n).unwrap_or(i64::MAX))
}

impl Storage {
    /// Execute a library works search entirely in SQL: parse the criteria,
    /// compile one SELECT, and return the matching ids in sorted order.
    /// Result-set semantics are identical to `search_local_works_filtered`
    /// (the parity oracle), plus a deterministic id tiebreak on equal keys.
    pub fn search_library_work_ids(&self, c: &LocalSearchCriteria)
        -> Result<Vec<u64>, AppError>
    {
        let (sql, params) = self.compile_search(c)?;
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(params), |r| r.get::<_, i64>(0))
            .map_err(map_sql)?;
        let mut ids = Vec::new();
        for row in rows {
            ids.push(row.map_err(map_sql)? as u64);
        }
        Ok(ids)
    }

    fn compile_search(&self, c: &LocalSearchCriteria)
        -> Result<(String, Vec<Value>), AppError>
    {
        let mut fragments: Vec<String> = Vec::new();
        let mut params: Vec<Value> = Vec::new();
        for pred in parse_criteria(c) {
            self.compile_predicate(&pred, &mut fragments, &mut params)?;
        }
        let where_clause = if fragments.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", fragments.join("\n   AND "))
        };
        let sql = format!(
            "SELECT works.id FROM works{where_clause} ORDER BY {}",
            sort_sql(&c.sort_column, &c.sort_direction),
        );
        Ok((sql, params))
    }

    fn compile_predicate(
        &self,
        pred: &Predicate,
        fragments: &mut Vec<String>,
        params: &mut Vec<Value>,
    ) -> Result<(), AppError> {
        match pred {
            Predicate::FreeText(needle) => {
                // Tag names resolve to ids up front (one scan of the small
                // tags table) so the per-work check is an indexed EXISTS.
                let tag_ids = self.tag_ids_containing(needle)?;
                let tag_arm = if tag_ids.is_empty() {
                    String::new()
                } else {
                    format!(
                        "\n      OR EXISTS (SELECT 1 FROM work_tags wt
                                  WHERE wt.work_id = works.id AND wt.tag_id IN ({}))",
                        join_ids(&tag_ids)
                    )
                };
                fragments.push(format!(
                    "(instr(ao3_lower(works.title), ?) > 0
      OR instr(ao3_lower(works.summary), ?) > 0
      OR EXISTS (SELECT 1 FROM work_authors a
                  WHERE a.work_id = works.id AND instr(ao3_lower(a.author), ?) > 0){tag_arm})"
                ));
                for _ in 0..3 {
                    params.push(Value::Text(needle.clone()));
                }
            }
            Predicate::TitleContains(needle) => {
                fragments.push("instr(ao3_lower(works.title), ?) > 0".into());
                params.push(Value::Text(needle.clone()));
            }
            Predicate::CreatorContains(needle) => {
                fragments.push(
                    "EXISTS (SELECT 1 FROM work_authors a
                      WHERE a.work_id = works.id AND instr(ao3_lower(a.author), ?) > 0)"
                        .into(),
                );
                params.push(Value::Text(needle.clone()));
            }
            Predicate::TagNameContains { tag_type, needle } => {
                let tag_ids = self.tag_ids_containing(needle)?;
                if tag_ids.is_empty() {
                    // No tag anywhere contains the text, so no work can
                    // match — same as the oracle failing every work.
                    fragments.push("0".into());
                } else {
                    fragments.push(format!(
                        "EXISTS (SELECT 1 FROM work_tags wt
                          WHERE wt.work_id = works.id AND wt.tag_type = ?
                            AND wt.tag_id IN ({}))",
                        join_ids(&tag_ids)
                    ));
                    params.push(Value::Text((*tag_type).into()));
                }
            }
            Predicate::RatingIn(ratings) => {
                fragments.push(format!(
                    "works.rating IN ({})",
                    vec!["?"; ratings.len()].join(", ")
                ));
                for r in ratings {
                    params.push(Value::Text((*r).into()));
                }
            }
            Predicate::WarningsAll(mask) => {
                fragments.push("(works.warnings_mask & ?) = ?".into());
                params.push(Value::Integer(*mask));
                params.push(Value::Integer(*mask));
            }
            Predicate::CategoriesAll(mask) => {
                fragments.push("(works.categories_mask & ?) = ?".into());
                params.push(Value::Integer(*mask));
                params.push(Value::Integer(*mask));
            }
            Predicate::CategoryEquals(lowered) => {
                // SQLite's lower() is ASCII-only — exactly the oracle's
                // eq_ignore_ascii_case.
                fragments.push(
                    "EXISTS (SELECT 1 FROM json_each(works.categories_json)
                      WHERE lower(json_each.value) = ?)"
                        .into(),
                );
                params.push(Value::Text(lowered.clone()));
            }
            Predicate::Complete(want) => {
                fragments.push(if *want { "works.complete != 0" } else { "works.complete = 0" }.into());
            }
            Predicate::Crossover(want) => {
                fragments.push(if *want { "works.fandom_count > 1" } else { "works.fandom_count <= 1" }.into());
            }
            Predicate::SingleChapter => {
                fragments.push("works.chapter_count = 1".into());
            }
            Predicate::LanguageEquals(lowered) => {
                fragments.push("lower(works.language) = ?".into());
                params.push(Value::Text(lowered.clone()));
            }
            Predicate::Number { column, range } => {
                match range {
                    NumRange::Ge(n) => {
                        fragments.push(format!("works.{column} >= ?"));
                        params.push(num(*n));
                    }
                    NumRange::Le(n) => {
                        fragments.push(format!("works.{column} <= ?"));
                        params.push(num(*n));
                    }
                    NumRange::Gt(n) => {
                        fragments.push(format!("works.{column} > ?"));
                        params.push(num(*n));
                    }
                    NumRange::Lt(n) => {
                        fragments.push(format!("works.{column} < ?"));
                        params.push(num(*n));
                    }
                    NumRange::Eq(n) => {
                        fragments.push(format!("works.{column} = ?"));
                        params.push(num(*n));
                    }
                    NumRange::Between(lo, hi) => {
                        fragments.push(format!("works.{column} >= ? AND works.{column} <= ?"));
                        params.push(num(*lo));
                        params.push(num(*hi));
                    }
                }
            }
            Predicate::Revised(cmp) => {
                // The oracle rejects works with no date_updated whenever the
                // field filters at all; '' sorts before every real date, so
                // only the before-comparisons need the explicit guard.
                match cmp {
                    DateCmp::RelSince(cutoff) => {
                        fragments.push("works.date_updated >= ?".into());
                        params.push(Value::Text(cutoff.clone()));
                    }
                    DateCmp::RelBefore(cutoff) | DateCmp::AbsBefore(cutoff) => {
                        fragments.push("(works.date_updated <> '' AND works.date_updated < ?)".into());
                        params.push(Value::Text(cutoff.clone()));
                    }
                    DateCmp::RelOn(cutoff) => {
                        fragments.push("works.date_updated = ?".into());
                        params.push(Value::Text(cutoff.clone()));
                    }
                    DateCmp::AbsAfter(prefix) => {
                        fragments.push(
                            "(works.date_updated > ?
                              AND substr(works.date_updated, 1, length(?)) <> ?)"
                                .into(),
                        );
                        for _ in 0..3 {
                            params.push(Value::Text(prefix.clone()));
                        }
                    }
                    DateCmp::AbsPrefix(prefix) => {
                        fragments.push("substr(works.date_updated, 1, length(?)) = ?".into());
                        params.push(Value::Text(prefix.clone()));
                        params.push(Value::Text(prefix.clone()));
                    }
                }
            }
        }
        Ok(())
    }

    /// Ids of every tag whose name contains the (pre-lowered) needle —
    /// the substring semantics of the oracle's `any_ci` over tag names.
    fn tag_ids_containing(&self, needle_lower: &str) -> Result<Vec<i64>, AppError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id FROM tags WHERE instr(ao3_lower(name), ?1) > 0")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![needle_lower], |r| r.get::<_, i64>(0))
            .map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    /// Seed the v11 mask columns from the JSON columns every existing row
    /// already carries. Runs inside the v11 migration step.
    pub(super) fn backfill_search_masks_v11(&self) -> Result<(), AppError> {
        let rows: Vec<(i64, String, String)> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id, warnings_json, categories_json FROM works")
                .map_err(map_sql)?;
            let mapped = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(map_sql)?;
            mapped.collect::<Result<Vec<_>, _>>().map_err(map_sql)?
        };
        let mut update = self
            .conn
            .prepare("UPDATE works SET warnings_mask = ?2, categories_mask = ?3 WHERE id = ?1")
            .map_err(map_sql)?;
        for (id, warnings_json, categories_json) in rows {
            let warnings: Vec<Warning> = serde_json::from_str(&warnings_json).unwrap_or_default();
            let categories: Vec<String> = serde_json::from_str(&categories_json).unwrap_or_default();
            update
                .execute(params![id, warnings_mask(&warnings), categories_mask(&categories)])
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// Hydrate a slice of search-result ids into summaries, preserving the
    /// ids' order; ids without a cached row are skipped. Batched (chunked
    /// `WHERE id IN`) so a page costs one query plus tag attachment.
    pub fn get_works_by_ids_ordered(&self, ids: &[u64]) -> Result<Vec<crate::models::WorkSummary>, AppError> {
        let mut by_id: HashMap<u64, crate::models::WorkSummary> = HashMap::with_capacity(ids.len());
        for chunk in ids.chunks(500) {
            let sql = format!(
                "SELECT {} FROM works WHERE id IN ({})",
                Self::work_select(""),
                vec!["?"; chunk.len()].join(", ")
            );
            let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
            let rows = stmt
                .query_map(
                    rusqlite::params_from_iter(chunk.iter().map(|id| *id as i64)),
                    |row| Ok(Self::work_from_row(row)),
                )
                .map_err(map_sql)?;
            for row in rows {
                let work = row.map_err(map_sql)?.map_err(map_sql)?;
                by_id.insert(work.id, work);
            }
        }
        let mut out: Vec<crate::models::WorkSummary> =
            ids.iter().filter_map(|id| by_id.remove(id)).collect();
        self.attach_work_tags(&mut out)?;
        Ok(out)
    }
}

/// Port of `sort_filtered`: AO3's sort columns, unknown/"_score" falling
/// back to Date Updated, direction defaulting ascending only for title.
/// Ends with an id tiebreak so equal keys order deterministically (the
/// oracle leaves ties in arbitrary order).
fn sort_sql(column: &str, direction: &str) -> String {
    let column = column.trim();
    let key = match column {
        "title_to_sort_on" => "ao3_lower(works.title)",
        "created_at" => "works.date_published",
        "word_count" => "works.word_count",
        "hits" => "works.hits",
        "kudos_count" => "works.kudos",
        "comments_count" => "works.comments",
        "bookmarks_count" => "works.bookmarks",
        _ => "works.date_updated",
    };
    let ascending = match direction.trim() {
        "asc" => true,
        "desc" => false,
        _ => column == "title_to_sort_on",
    };
    format!("{key} {}, works.id ASC", if ascending { "ASC" } else { "DESC" })
}

fn join_ids(ids: &[i64]) -> String {
    ids.iter().map(|id| id.to_string()).collect::<Vec<_>>().join(", ")
}

// ===========================================================================
// Tests — parser and compiler in isolation (parity with the oracle is
// covered by the fixture tests in storage/tests.rs).
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_grammar() {
        assert_eq!(parse_range(""), None);
        assert_eq!(parse_range("   "), None);
        assert_eq!(parse_range("500"), Some(NumRange::Eq(500)));
        assert_eq!(parse_range("1,500"), Some(NumRange::Eq(1500)));
        assert_eq!(parse_range(">500"), Some(NumRange::Gt(500)));
        assert_eq!(parse_range("< 500"), Some(NumRange::Lt(500)));
        assert_eq!(parse_range(">=500"), Some(NumRange::Ge(500)));
        assert_eq!(parse_range("<=500"), Some(NumRange::Le(500)));
        assert_eq!(parse_range("100-5000"), Some(NumRange::Between(100, 5000)));
        // Garbage doesn't filter, mirroring range_matches.
        assert_eq!(parse_range("abc"), None);
        assert_eq!(parse_range(">abc"), None);
        assert_eq!(parse_range("100-abc"), None);
    }

    #[test]
    fn revised_grammar() {
        assert_eq!(parse_revised(""), None);
        assert_eq!(
            parse_revised("2024-01"),
            Some(DateCmp::AbsPrefix("2024-01".into()))
        );
        assert_eq!(
            parse_revised("< 2024"),
            Some(DateCmp::AbsBefore("2024".into()))
        );
        assert_eq!(
            parse_revised("> 2024"),
            Some(DateCmp::AbsAfter("2024".into()))
        );
        // Relative expressions resolve to a concrete cutoff date.
        match parse_revised("< 2 weeks ago") {
            Some(DateCmp::RelSince(d)) => assert_eq!(d.len(), 10),
            other => panic!("expected RelSince, got {other:?}"),
        }
        match parse_revised("> 3 months ago") {
            Some(DateCmp::RelBefore(d)) => assert_eq!(d.len(), 10),
            other => panic!("expected RelBefore, got {other:?}"),
        }
    }

    #[test]
    fn masks() {
        use crate::models::Warning::*;
        assert_eq!(warnings_mask(&[]), 0);
        assert_eq!(warnings_mask(&[None, Noncon]), (1 << 0) | (1 << 5));
        assert_eq!(categories_mask(&["F/F".into(), "gen".into()]), (1 << 0) | (1 << 2));
        assert_eq!(categories_mask(&["Weird".into()]), 0);
        assert_eq!(category_bit("m/m"), Some(1 << 3));
        assert_eq!(category_bit("nonsense"), Option::None);
    }

    #[test]
    fn blank_criteria_compile_to_no_predicates() {
        assert!(parse_criteria(&LocalSearchCriteria::default()).is_empty());
    }

    #[test]
    fn criteria_parse_shapes() {
        let c = LocalSearchCriteria {
            creators: "alice, , bob".into(),
            fandom_names: "Naruto".into(),
            ratings: vec!["Teen And Up Audiences".into()],
            warnings: vec!["No Archive Warnings Apply".into()],
            categories: vec!["Gen".into(), "Weird".into()],
            complete: "T".into(),
            crossover: "F".into(),
            single_chapter: true,
            language: "English".into(),
            word_count: ">1000".into(),
            ..Default::default()
        };
        let preds = parse_criteria(&c);
        assert!(preds.contains(&Predicate::CreatorContains("alice".into())));
        assert!(preds.contains(&Predicate::CreatorContains("bob".into())));
        assert!(preds.contains(&Predicate::TagNameContains {
            tag_type: "fandom",
            needle: "naruto".into()
        }));
        assert!(preds.contains(&Predicate::RatingIn(vec!["Teen"])));
        assert!(preds.contains(&Predicate::WarningsAll(1 << 0)));
        assert!(preds.contains(&Predicate::CategoriesAll(1 << 2)));
        assert!(preds.contains(&Predicate::CategoryEquals("weird".into())));
        assert!(preds.contains(&Predicate::Complete(true)));
        assert!(preds.contains(&Predicate::Crossover(false)));
        assert!(preds.contains(&Predicate::SingleChapter));
        assert!(preds.contains(&Predicate::LanguageEquals("english".into())));
        assert!(preds.contains(&Predicate::Number {
            column: "word_count",
            range: NumRange::Gt(1000)
        }));
    }

    #[test]
    fn sort_clause() {
        assert_eq!(sort_sql("", ""), "works.date_updated DESC, works.id ASC");
        assert_eq!(
            sort_sql("title_to_sort_on", ""),
            "ao3_lower(works.title) ASC, works.id ASC"
        );
        assert_eq!(
            sort_sql("kudos_count", "asc"),
            "works.kudos ASC, works.id ASC"
        );
        assert_eq!(sort_sql("_score", ""), "works.date_updated DESC, works.id ASC");
        assert_eq!(
            sort_sql("created_at", "desc"),
            "works.date_published DESC, works.id ASC"
        );
    }
}
