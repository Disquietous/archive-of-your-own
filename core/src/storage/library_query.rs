//! The source-agnostic library search: a few fields every work has, plus
//! any number of conditions on things only one source records (a stat
//! from the fields registry, a stat column, a tag kind).
//!
//! Conditions group by their source. Within a source they all hold;
//! across sources any group may hold, so "ScribbleHub rated 3 or more,
//! AO3 with 10 kudos or more" finds both. With conditions and no sources
//! picked, only the sources that have a condition contribute; a picked
//! source with no condition of its own contributes all its works.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, LazyLock, RwLock};

use rusqlite::types::Value;

use crate::error::AppError;
use crate::models::Rating;

use super::consts::{sql_placeholders, TAG_TYPE_CHARACTER, TAG_TYPE_FANDOM, TAG_TYPE_FREEFORM, TAG_TYPE_RELATIONSHIP};
use super::works_search::{numeric_column, parse_revised, sort_sql, Predicate};
use super::{map_sql, rating_to_str, Storage};

/// What a condition is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LibraryFieldKind {
    /// A fields-registry stat, by key.
    Stat,
    /// A works stat column (kudos, hits, comments, bookmarks), by name.
    Column,
    /// A tag kind, by its type.
    Tag,
}

/// How a field is searched, decided from what the library holds for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryFieldInput {
    /// An amount: one typed range (">1500", "1500-10000", "<100000").
    Range,
    /// A short set of values to pick from.
    Choice,
    /// Many values to pick from, found by typing (tags).
    Search,
    /// Free text too varied to list: typed text the value must contain.
    Contains,
}

/// One thing a source's works can be searched on.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LibraryField {
    pub source: String,
    pub kind: LibraryFieldKind,
    pub key: String,
    pub label: String,
    pub input: LibraryFieldInput,
    /// A range field's smallest and largest amounts in the library, as
    /// they would be typed; empty otherwise.
    pub low: String,
    pub high: String,
}

/// One value a field currently has in the library, and on how many works.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LibraryFieldValue {
    pub value: String,
    pub works: u64,
}

/// A source with works in the library, and how many.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LibrarySourceCount {
    pub source: String,
    pub name: String,
    pub works: u64,
}

/// One condition on one source's works, filled in the way its field's
/// input asks: a range expression, any of `values`, or text the value
/// must contain. A condition with none of them (or a range that does
/// not read as one) is not yet filled in and takes no part.
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct LibraryCondition {
    pub source: String,
    pub kind: LibraryFieldKind,
    pub key: String,
    pub range: String,
    pub values: Vec<String>,
    pub contains: String,
}

impl Default for LibraryFieldKind {
    fn default() -> Self { LibraryFieldKind::Stat }
}

#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct LibraryQuery {
    /// Title, summary, authors and tag names.
    pub text: String,
    pub title: String,
    /// Comma-separated names; a work must match each.
    pub author: String,
    /// Tag names by kind, comma-separated; a work must carry a tag of
    /// that kind containing each entry.
    pub fandoms: String,
    pub characters: String,
    pub relationships: String,
    pub tags: String,
    /// Date expressions as the works search takes them: "< 2 weeks ago",
    /// "> 2024-01-01", "2024-06".
    pub updated: String,
    pub published: String,
    /// Every chapter of the work is stored.
    pub fully_downloaded: bool,
    /// Sources to search; empty = every source.
    pub sources: Vec<String>,
    /// Rating labels; any may match. Empty = any rating.
    pub ratings: Vec<String>,
    pub complete: Option<bool>,
    /// A range expression on the word count; blank = any length.
    pub words: String,
    pub language: String,
    pub conditions: Vec<LibraryCondition>,
    pub sort_column: String,
    pub sort_direction: String,
    /// Sources whose works are never searched (set by the core, not the
    /// form): imported files.
    pub excluded_sources: Vec<String>,
}

/// A text value as an amount: digits (commas allowed, a decimal point,
/// a sign) with an optional k / m multiplier — "41k", "1,200", "2.5m",
/// "310 kb". Anything else is not an amount.
pub fn quantity(text: &str) -> Option<f64> {
    let cleaned: String = text.trim().chars().filter(|c| *c != ',' && !c.is_whitespace()).collect::<String>().to_ascii_lowercase();
    let digits_end = cleaned.char_indices()
        .find(|(i, c)| !(c.is_ascii_digit() || *c == '.' || (*i == 0 && (*c == '-' || *c == '+'))))
        .map(|(i, _)| i).unwrap_or(cleaned.len());
    let (number, suffix) = cleaned.split_at(digits_end);
    let value: f64 = number.parse().ok()?;
    let scale = match suffix {
        "" => 1.0,
        "k" | "kb" => 1_000.0,
        "m" | "mb" => 1_000_000.0,
        _ => return None,
    };
    Some(value * scale)
}

/// One end of a range: the amount, and whether the amount itself counts.
type Bound = Option<(f64, bool)>;

/// A typed range: ">1500", ">=1500", "<100000", "<=100000",
/// "1500-10000" (both ends count), or a bare amount (exactly that).
/// Amounts read as `quantity` does, so "10k-100k" works. None when the
/// text is not a range.
pub fn parse_bounds(expr: &str) -> Option<(Bound, Bound)> {
    let expr = expr.trim();
    if expr.is_empty() { return None }
    for (op, strict, lower) in [(">=", false, true), ("<=", false, false), (">", true, true), ("<", true, false)] {
        if let Some(rest) = expr.strip_prefix(op) {
            let n = quantity(rest)?;
            return Some(if lower { (Some((n, !strict)), None) } else { (None, Some((n, !strict))) });
        }
    }
    // A dash after the first character separates two amounts; a leading
    // one is a sign.
    for (i, c) in expr.char_indices().skip(1) {
        if c == '-' || c == '–' {
            if let (Some(lo), Some(hi)) = (quantity(&expr[..i]), quantity(&expr[i + c.len_utf8()..])) {
                return Some((Some((lo.min(hi), true)), Some((lo.max(hi), true))));
            }
        }
    }
    quantity(expr).map(|n| (Some((n, true)), Some((n, true))))
}

/// An amount the way it would be typed: no decimals when whole.
fn amount(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { format!("{n:.2}") }
}

/// A text stat with at most this many distinct values is a pick list;
/// past it the values are too varied to list.
const CHOICE_LIMIT: i64 = 40;

/// What the library holds, summed up once and kept in memory for the
/// whole app: which sources have works, the languages in use, what each
/// source's works can be searched on, and the values of every field
/// that is picked from a list. Screens read this and never ask the
/// database for it. It is rebuilt off to the side after the library
/// changes (`mark_facts_stale`), so it may trail the library by a
/// moment; nothing waits on it.
#[derive(Debug, Clone, Default)]
pub struct LibraryFacts {
    /// Sources with (fetched) works, and how many.
    pub sources: Vec<(String, u64)>,
    /// Languages in use, sorted without regard to case.
    pub languages: Vec<String>,
    pub fields: Vec<LibraryField>,
    /// The values of each list field, most-used first.
    values: HashMap<(String, LibraryFieldKind, String), Vec<LibraryFieldValue>>,
}

impl LibraryFacts {
    /// A list field's values, most-used first, narrowed to those
    /// containing `filter`; `limit` 0 = all of them.
    pub fn field_values(&self, source: &str, kind: LibraryFieldKind, key: &str, filter: &str, limit: u32)
        -> Vec<LibraryFieldValue>
    {
        let Some(all) = self.values.get(&(source.to_string(), kind, key.to_string())) else { return Vec::new() };
        let needle = filter.trim().to_lowercase();
        let take = if limit == 0 { usize::MAX } else { limit as usize };
        all.iter()
            .filter(|v| needle.is_empty() || v.value.to_lowercase().contains(&needle))
            .take(take).cloned().collect()
    }
}

static FACTS: LazyLock<RwLock<Option<Arc<LibraryFacts>>>> = LazyLock::new(Default::default);

/// Wakes the worker that rebuilds the facts; one pending wake covers any
/// number of changes.
pub static FACTS_STALE: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// The facts as last built; None until the first build for this library.
pub fn facts() -> Option<Arc<LibraryFacts>> {
    FACTS.read().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn set_facts(facts: Option<LibraryFacts>) {
    *FACTS.write().unwrap_or_else(|e| e.into_inner()) = facts.map(Arc::new);
}

/// The library changed in a way the facts count: queue a rebuild. Costs
/// nothing to call and never waits.
pub fn mark_facts_stale() {
    FACTS_STALE.notify_one();
}

fn tag_label(tag_type: &str) -> String {
    match tag_type {
        "fandom" => "Fandom".to_string(),
        "character" => "Character".to_string(),
        "relationship" => "Relationship".to_string(),
        "freeform" => "Tag".to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect(),
                None => String::new(),
            }
        }
    }
}

/// The stat columns a field list may offer, with their labels.
const STAT_COLUMNS: [(&str, &str); 4] =
    [("kudos", "Kudos"), ("hits", "Hits"), ("comments", "Comments"), ("bookmarks", "Bookmarks")];

impl Storage {
    /// Run the query; matching work ids in sorted order.
    pub fn run_library_query(&self, q: &LibraryQuery) -> Result<Vec<u64>, AppError> {
        let (sql, params) = self.compile_library_query(q)?;
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

    /// One condition as SQL on `works`, or None when it is not filled in.
    fn compile_condition(&self, c: &LibraryCondition, fragments: &mut Vec<String>, params: &mut Vec<Value>)
        -> Result<bool, AppError>
    {
        let values: Vec<String> = c.values.iter().map(|v| v.trim().to_string()).filter(|v| !v.is_empty()).collect();
        let contains = c.contains.trim().to_lowercase();
        let bounds = parse_bounds(&c.range);
        // `expr OP ?` for each end of a range.
        let ranged = |expr: &str, (lo, hi): (Bound, Bound), params: &mut Vec<Value>| {
            let mut out = String::new();
            if let Some((n, inclusive)) = lo {
                out.push_str(&format!(" AND {expr} {} ?", if inclusive { ">=" } else { ">" }));
                params.push(Value::Real(n));
            }
            if let Some((n, inclusive)) = hi {
                out.push_str(&format!(" AND {expr} {} ?", if inclusive { "<=" } else { "<" }));
                params.push(Value::Real(n));
            }
            out
        };
        match c.kind {
            LibraryFieldKind::Column => {
                let (Some(column), Some(bounds)) = (numeric_column(&c.key), bounds) else { return Ok(false) };
                let tail = ranged(column, bounds, params);
                fragments.push(format!("({column} IS NOT NULL{tail})"));
            }
            LibraryFieldKind::Stat => {
                let field = self.field_id(&c.source, &c.key).and_then(|id| self.get_field(id));
                let Some(field) = field else {
                    if bounds.is_none() && values.is_empty() && contains.is_empty() { return Ok(false) }
                    fragments.push("0".into());
                    return Ok(true);
                };
                let textual = field.value_type == "text";
                if let Some(bounds) = bounds {
                    // A text stat holding amounts compares as amounts.
                    let expr = if textual { "ao3_quantity(ws.text_value)" } else { "ws.num_value" };
                    params.push(Value::Integer(field.id));
                    let tail = ranged(expr, bounds, params);
                    fragments.push(format!(
                        "EXISTS (SELECT 1 FROM work_stats ws
                          WHERE ws.work_id = works.id AND ws.field_id = ? AND {expr} IS NOT NULL{tail})"));
                } else if !values.is_empty() {
                    self.compile_predicate(&Predicate::StatTextIn { field_id: Some(field.id), values }, fragments, params)?;
                } else if !contains.is_empty() {
                    fragments.push(
                        "EXISTS (SELECT 1 FROM work_stats ws
                          WHERE ws.work_id = works.id AND ws.field_id = ?
                            AND instr(ao3_lower(ws.text_value), ?) > 0)".into());
                    params.push(Value::Integer(field.id));
                    params.push(Value::Text(contains));
                } else {
                    return Ok(false);
                }
            }
            LibraryFieldKind::Tag => {
                if values.is_empty() { return Ok(false) }
                self.compile_predicate(&Predicate::TagSet {
                    tag_type: c.key.clone(),
                    include: values.iter().map(|v| v.to_ascii_lowercase()).collect(),
                    exclude: Vec::new(),
                    all: false,
                }, fragments, params)?;
            }
        }
        Ok(true)
    }

    pub(super) fn compile_library_query(&self, q: &LibraryQuery) -> Result<(String, Vec<Value>), AppError> {
        let mut fragments: Vec<String> = vec!["works.stub = 0".into()];
        let mut params: Vec<Value> = Vec::new();

        if !q.excluded_sources.is_empty() {
            fragments.push(format!("works.source NOT IN ({})", sql_placeholders(q.excluded_sources.len())));
            params.extend(q.excluded_sources.iter().cloned().map(Value::Text));
        }

        // The fields every work has.
        let mut shared: Vec<Predicate> = Vec::new();
        let text = q.text.trim();
        if !text.is_empty() { shared.push(Predicate::FreeText(text.to_lowercase())); }
        let names = |field: &str| field.split(',').map(str::trim).filter(|n| !n.is_empty())
            .map(str::to_lowercase).collect::<Vec<_>>();
        let title = q.title.trim();
        if !title.is_empty() { shared.push(Predicate::TitleContains(title.to_lowercase())); }
        for name in names(&q.author) {
            shared.push(Predicate::CreatorContains(name));
        }
        for (field, tag_type) in [
            (&q.fandoms, TAG_TYPE_FANDOM), (&q.characters, TAG_TYPE_CHARACTER),
            (&q.relationships, TAG_TYPE_RELATIONSHIP), (&q.tags, TAG_TYPE_FREEFORM),
        ] {
            for needle in names(field) {
                shared.push(Predicate::TagNameContains { tag_type, needle });
            }
        }
        if q.fully_downloaded { shared.push(Predicate::FullyDownloaded); }
        if !q.ratings.is_empty() {
            shared.push(Predicate::RatingIn(q.ratings.iter().map(|l| rating_to_str(&Rating::from_ao3_tag(l))).collect()));
        }
        if let Some(complete) = q.complete { shared.push(Predicate::Complete(complete)); }
        let language = q.language.trim();
        if !language.is_empty() { shared.push(Predicate::LanguageEquals(language.to_ascii_lowercase())); }
        for pred in &shared {
            self.compile_predicate(pred, &mut fragments, &mut params)?;
        }
        if let Some(cmp) = parse_revised(&q.updated) {
            self.compile_predicate(&Predicate::Revised(cmp), &mut fragments, &mut params)?;
        }
        if let Some(cmp) = parse_revised(&q.published) {
            // The same comparison, read against the published date.
            let mut dated = Vec::new();
            self.compile_predicate(&Predicate::Revised(cmp), &mut dated, &mut params)?;
            fragments.extend(dated.into_iter().map(|f| f.replace("works.date_updated", "works.date_published")));
        }
        self.compile_condition(&LibraryCondition {
            kind: LibraryFieldKind::Column, key: "word_count".into(), range: q.words.clone(), ..Default::default()
        }, &mut fragments, &mut params)?;

        // Conditions, grouped by source in first-seen order; each group
        // is its source and that source's filled-in conditions.
        let mut groups: Vec<(String, Vec<String>, Vec<Value>)> = Vec::new();
        for c in &q.conditions {
            let (mut frags, mut vals) = (Vec::new(), Vec::new());
            if !self.compile_condition(c, &mut frags, &mut vals)? { continue }
            match groups.iter_mut().find(|(source, _, _)| *source == c.source) {
                Some((_, f, v)) => { f.extend(frags); v.extend(vals); }
                None => groups.push((c.source.clone(), frags, vals)),
            }
        }
        // A picked source with no condition contributes all its works.
        for source in &q.sources {
            if !groups.iter().any(|(s, _, _)| s == source) {
                groups.push((source.clone(), Vec::new(), Vec::new()));
            }
        }
        if !groups.is_empty() {
            let mut arms: Vec<String> = Vec::new();
            for (source, frags, vals) in groups {
                let mut arm: Vec<String> = vec!["works.source = ?".into()];
                params.push(Value::Text(source));
                arm.extend(frags);
                params.extend(vals);
                arms.push(format!("({})", arm.join(" AND ")));
            }
            fragments.push(format!("({})", arms.join("\n    OR ")));
        }

        let sql = format!(
            "SELECT works.id FROM works WHERE {} ORDER BY {}",
            fragments.join("\n   AND "),
            sort_sql(&q.sort_column, &q.sort_direction),
        );
        Ok((sql, params))
    }

    /// Build the library facts. Works, their tags and tag names come
    /// from the in-memory mirrors (no SQL); only the per-source stats,
    /// which have no mirror, are read from the database.
    ///
    /// How each field is searched comes from the data: amounts (declared
    /// numbers, and text that reads as amounts, like a size of "41k") are
    /// ranges; a text stat with a handful of values is a pick list; one
    /// too varied to list is matched by typed text; tags are found by
    /// typing unless a kind has only a few.
    pub fn library_facts(&self) -> Result<LibraryFacts, AppError> {
        let mut counts: BTreeMap<String, u64> = BTreeMap::new();
        let mut languages: BTreeSet<String> = BTreeSet::new();
        // Per source, the largest value of each stat column.
        let mut column_highs: BTreeMap<String, [u64; 4]> = BTreeMap::new();
        // Per (tag kind, source), how many works carry each tag.
        let mut tag_uses: BTreeMap<(String, String), HashMap<i64, u64>> = BTreeMap::new();
        for work in self.works_cache.all() {
            if work.stub { continue }
            let w = &work.summary;
            *counts.entry(w.source.clone()).or_default() += 1;
            if !w.language.is_empty() { languages.insert(w.language.clone()); }
            let highs = column_highs.entry(w.source.clone()).or_default();
            let held = [w.kudos.map(u64::from), w.hits.map(u64::from), w.comments.map(u64::from), w.bookmarks.map(u64::from)];
            for (slot, value) in highs.iter_mut().zip(held) {
                *slot = (*slot).max(value.unwrap_or(0));
            }
            for tag in &work.tags {
                if tag.tag_type == "creator" { continue }
                *tag_uses.entry((tag.tag_type.clone(), w.source.clone())).or_default()
                    .entry(tag.tag_id).or_default() += 1;
            }
        }

        let mut fields = Vec::new();
        let mut values = HashMap::new();
        for (source, highs) in &column_highs {
            for ((key, label), high) in STAT_COLUMNS.iter().zip(highs) {
                if *high == 0 { continue }
                fields.push(LibraryField {
                    source: source.clone(), kind: LibraryFieldKind::Column,
                    key: key.to_string(), label: label.to_string(), input: LibraryFieldInput::Range,
                    low: "0".to_string(), high: high.to_string(),
                });
            }
        }

        let mut stmt = self.conn
            .prepare("SELECT f.source, f.key, f.label, f.value_type,
                             MIN(ws.num_value), MAX(ws.num_value),
                             SUM(ws.text_value IS NOT NULL AND ws.text_value <> ''),
                             SUM(ao3_quantity(ws.text_value) IS NOT NULL),
                             COUNT(DISTINCT ws.text_value),
                             MIN(ao3_quantity(ws.text_value)), MAX(ao3_quantity(ws.text_value))
                        FROM fields f JOIN work_stats ws ON ws.field_id = f.id
                       WHERE f.entity = 'work'
                       GROUP BY f.id
                       ORDER BY f.display_order, f.id")
            .map_err(map_sql)?;
        let rows = stmt.query_map([], |r| {
            let numeric = r.get::<_, String>(3)? == "num";
            let (texts, amounts, distinct): (i64, i64, i64) =
                (r.get::<_, Option<i64>>(6)?.unwrap_or(0), r.get::<_, Option<i64>>(7)?.unwrap_or(0), r.get(8)?);
            // Nearly every value reading as an amount makes it one; the
            // odd stray value simply never matches a range.
            let as_amounts = !numeric && texts > 0 && amounts * 20 >= texts * 19;
            let span: (Option<f64>, Option<f64>) = if numeric { (r.get(4)?, r.get(5)?) }
                else if as_amounts { (r.get(9)?, r.get(10)?) } else { (None, None) };
            let input = if numeric || as_amounts { LibraryFieldInput::Range }
                else if distinct <= CHOICE_LIMIT { LibraryFieldInput::Choice }
                else { LibraryFieldInput::Contains };
            Ok((numeric, texts, LibraryField {
                source: r.get(0)?, kind: LibraryFieldKind::Stat, key: r.get(1)?, label: r.get(2)?, input,
                low: span.0.map(amount).unwrap_or_default(), high: span.1.map(amount).unwrap_or_default(),
            }))
        }).map_err(map_sql)?;
        let mut stat_fields = Vec::new();
        for row in rows {
            let (numeric, texts, field) = row.map_err(map_sql)?;
            // A text field no work has text for has nothing to search.
            if numeric || texts > 0 { stat_fields.push(field); }
        }
        drop(stmt);
        for field in stat_fields {
            if field.input == LibraryFieldInput::Choice {
                values.insert((field.source.clone(), field.kind, field.key.clone()),
                              self.stat_text_values(&field.source, &field.key)?);
            }
            fields.push(field);
        }

        for ((tag_type, source), uses) in tag_uses {
            let mut list: Vec<LibraryFieldValue> = uses.into_iter()
                .filter_map(|(id, works)| self.tag_cache.get(id).map(|t| LibraryFieldValue { value: t.name.to_string(), works }))
                .collect();
            list.sort_by(|a, b| b.works.cmp(&a.works).then_with(|| a.value.cmp(&b.value)));
            fields.push(LibraryField {
                source: source.clone(), kind: LibraryFieldKind::Tag, label: tag_label(&tag_type), key: tag_type.clone(),
                input: if list.len() as i64 <= CHOICE_LIMIT { LibraryFieldInput::Choice } else { LibraryFieldInput::Search },
                low: String::new(), high: String::new(),
            });
            values.insert((source, LibraryFieldKind::Tag, tag_type), list);
        }

        let mut languages: Vec<String> = languages.into_iter().collect();
        languages.sort_by_key(|l| l.to_lowercase());
        Ok(LibraryFacts { sources: counts.into_iter().collect(), languages, fields, values })
    }

    /// The distinct text values of one stat field, most-used first.
    fn stat_text_values(&self, source: &str, key: &str) -> Result<Vec<LibraryFieldValue>, AppError> {
        let Some(field_id) = self.field_id(source, key) else { return Ok(Vec::new()) };
        let mut stmt = self.conn.prepare(
            "SELECT ws.text_value, COUNT(*) FROM work_stats ws
               JOIN works w ON w.id = ws.work_id
              WHERE ws.field_id = ? AND w.stub = 0
                AND ws.text_value IS NOT NULL AND ws.text_value <> ''
              GROUP BY ws.text_value
              ORDER BY COUNT(*) DESC, ws.text_value").map_err(map_sql)?;
        let rows = stmt.query_map([field_id], |r| Ok(LibraryFieldValue {
            value: r.get(0)?, works: r.get::<_, i64>(1)? as u64,
        })).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }
}
