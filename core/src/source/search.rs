//! Source-specific search as configuration (design/source-search-plan.md).
//!
//! Each adapter declares a `SearchSchema`: its fields (key, label, kind,
//! value range, options) in sections, plus a sort spec. The schema is
//! static Rust compiled into the app — never fetched from the site; a site
//! form change ships as a configuration update with a version bump. The UI
//! renders any schema with one generic form per platform and sends back a
//! `SearchQuery` (field key → typed value). The adapter encodes its own
//! request; the library compiles the same query to SQL through each
//! field's `LibraryBinding`. No source names, no HTML field names and no
//! per-source form code exist outside the adapter.

/// A source's search form.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchSchema {
    /// The source id ("ao3", "scribblehub").
    pub source: String,
    /// Bumped with every planned configuration change. Saved queries carry
    /// the version they were made under.
    pub version: u32,
    /// Key of the Text field the title-bar query box binds to.
    pub primary: String,
    pub sections: Vec<SearchSection>,
    pub sort: Option<SortSpec>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchSection {
    pub key: String,
    pub label: String,
    /// Initial state of the group ("Advance" on ScribbleHub).
    pub collapsed: bool,
    pub fields: Vec<SearchField>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchField {
    /// Adapter-owned, stable, unique within the source; never an HTML name.
    pub key: String,
    pub label: String,
    /// Placeholder or help text.
    pub hint: String,
    pub kind: FieldKind,
    /// How the library evaluates this field offline.
    pub library: LibraryBinding,
    /// Pre-filled value, if any.
    pub default: Option<FieldValue>,
}

/// What control a field is. Size never makes a kind: a `ChoiceSet` of 3 or
/// 760 options is the same kind, and the renderer picks the control from
/// `options.len()`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FieldKind {
    /// Free text. With `autocomplete`, suggestions come from the local
    /// known-tags cache; a remote lookup runs only on an explicit user
    /// action (design/tag-autocomplete-plan.md).
    Text { autocomplete: Option<Autocomplete> },
    /// One number.
    Number { min: Option<f64>, max: Option<f64>, step: f64, unit: Option<String> },
    /// Two optional ends; the adapter formats them for its site.
    Range { min: Option<f64>, max: Option<f64>, step: f64, unit: Option<String> },
    /// ISO `yyyy-mm-dd`.
    Date,
    DateRange,
    /// One of a fixed list. `any_label` names the empty choice ("Any",
    /// "All works"); None means the field always has a value.
    Choice { options: Vec<FieldOption>, any_label: Option<String> },
    /// Many of a fixed list. `exclude` adds a per-option exclude state;
    /// `modes` (AND/OR) apply to the include set. Plain checkboxes are
    /// `exclude: false` with no modes.
    ChoiceSet { options: Vec<FieldOption>, exclude: bool, modes: Vec<FieldOption>, default_mode: Option<String> },
    Toggle,
    /// Sent with every query, never shown.
    Hidden { value: String },
}

/// What an open-text field suggests from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Autocomplete {
    /// A tag kind of the known-tags cache ("fandom", "character",
    /// "relationship", "freeform", "genre", …).
    Tag { kind: String },
    User,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FieldOption {
    pub value: String,
    pub label: String,
}

/// A field's value in a query. One shape per kind; `Set` serves
/// `ChoiceSet` with `exclude`/`mode` empty when the field offers neither.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FieldValue {
    Text { value: String },
    Number { value: f64 },
    Range { min: Option<f64>, max: Option<f64> },
    Date { value: String },
    DateRange { from: Option<String>, to: Option<String> },
    Choice { value: String },
    Bool { value: bool },
    Set { include: Vec<String>, exclude: Vec<String>, mode: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SortSpec {
    pub columns: Vec<FieldOption>,
    pub directions: Vec<FieldOption>,
    pub default_column: String,
    pub default_direction: String,
}

/// How the library compiles a field offline (step 2 of the plan).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryBinding {
    /// A works column (title, word_count, complete, revised_at, language…).
    Column { name: String },
    /// A fields-registry key in `work_stats`; a filter on it limits results
    /// to that source.
    Stat { key: String },
    /// A tag kind.
    Tag { kind: String },
    Author,
    /// Title + summary + authors (the primary query).
    FullText,
    /// Site-only; ignored offline.
    None,
}

/// What the form submits: only non-empty fields.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchQuery {
    pub source: String,
    pub schema_version: u32,
    pub values: Vec<QueryValue>,
    pub sort_column: Option<String>,
    pub sort_direction: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueryValue {
    pub key: String,
    pub value: FieldValue,
}

pub fn opt(value: &str, label: &str) -> FieldOption {
    FieldOption { value: value.to_string(), label: label.to_string() }
}

impl FieldValue {
    /// Whether the UI should omit this value from a query.
    pub fn is_empty(&self) -> bool {
        match self {
            FieldValue::Text { value } | FieldValue::Date { value } | FieldValue::Choice { value } => value.trim().is_empty(),
            FieldValue::Number { .. } => false,
            FieldValue::Range { min, max } => min.is_none() && max.is_none(),
            FieldValue::DateRange { from, to } => from.is_none() && to.is_none(),
            FieldValue::Bool { value } => !value,
            FieldValue::Set { include, exclude, .. } => include.is_empty() && exclude.is_empty(),
        }
    }
}

impl SearchQuery {
    pub fn new(source: &str, schema_version: u32) -> Self {
        SearchQuery { source: source.to_string(), schema_version, values: Vec::new(), sort_column: None, sort_direction: None }
    }

    pub fn with(mut self, key: &str, value: FieldValue) -> Self {
        self.values.push(QueryValue { key: key.to_string(), value });
        self
    }

    pub fn sorted(mut self, column: &str, direction: &str) -> Self {
        self.sort_column = Some(column.to_string());
        self.sort_direction = Some(direction.to_string());
        self
    }

    pub fn get(&self, key: &str) -> Option<&FieldValue> {
        self.values.iter().find(|v| v.key == key).map(|v| &v.value).filter(|v| !v.is_empty())
    }

    pub fn text(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            FieldValue::Text { value } | FieldValue::Choice { value } | FieldValue::Date { value } => Some(value.trim()),
            _ => None,
        }
    }

    pub fn number(&self, key: &str) -> Option<f64> {
        match self.get(key)? { FieldValue::Number { value } => Some(*value), _ => None }
    }

    pub fn range(&self, key: &str) -> Option<(Option<f64>, Option<f64>)> {
        match self.get(key)? { FieldValue::Range { min, max } => Some((*min, *max)), _ => None }
    }

    pub fn date_range(&self, key: &str) -> Option<(Option<&str>, Option<&str>)> {
        match self.get(key)? { FieldValue::DateRange { from, to } => Some((from.as_deref(), to.as_deref())), _ => None }
    }

    pub fn flag(&self, key: &str) -> bool {
        matches!(self.get(key), Some(FieldValue::Bool { value: true }))
    }

    /// (include, exclude, mode) of a ChoiceSet value.
    pub fn set(&self, key: &str) -> Option<(&[String], &[String], Option<&str>)> {
        match self.get(key)? {
            FieldValue::Set { include, exclude, mode } => Some((include, exclude, mode.as_deref())),
            _ => None,
        }
    }
}

/// Builders keep adapter declarations short.
impl SearchField {
    fn new(key: &str, label: &str, kind: FieldKind) -> Self {
        SearchField { key: key.to_string(), label: label.to_string(), hint: String::new(), kind, library: LibraryBinding::None, default: None }
    }

    pub fn text(key: &str, label: &str) -> Self {
        Self::new(key, label, FieldKind::Text { autocomplete: None })
    }

    pub fn tag_text(key: &str, label: &str, tag_kind: &str) -> Self {
        Self::new(key, label, FieldKind::Text { autocomplete: Some(Autocomplete::Tag { kind: tag_kind.to_string() }) })
    }

    pub fn number(key: &str, label: &str, min: Option<f64>, max: Option<f64>, step: f64) -> Self {
        Self::new(key, label, FieldKind::Number { min, max, step, unit: None })
    }

    /// Integer range from zero up.
    pub fn count_range(key: &str, label: &str) -> Self {
        Self::new(key, label, FieldKind::Range { min: Some(0.0), max: None, step: 1.0, unit: None })
    }

    pub fn range(key: &str, label: &str, min: Option<f64>, max: Option<f64>, step: f64) -> Self {
        Self::new(key, label, FieldKind::Range { min, max, step, unit: None })
    }

    pub fn date_range(key: &str, label: &str) -> Self {
        Self::new(key, label, FieldKind::DateRange)
    }

    pub fn choice(key: &str, label: &str, options: Vec<FieldOption>, any_label: Option<&str>) -> Self {
        Self::new(key, label, FieldKind::Choice { options, any_label: any_label.map(str::to_string) })
    }

    /// Plain checkboxes.
    pub fn checkboxes(key: &str, label: &str, options: Vec<FieldOption>) -> Self {
        Self::new(key, label, FieldKind::ChoiceSet { options, exclude: false, modes: Vec::new(), default_mode: None })
    }

    /// Include/exclude per option with an AND/OR mode.
    pub fn include_exclude(key: &str, label: &str, options: Vec<FieldOption>, modes: Vec<FieldOption>, default_mode: &str) -> Self {
        Self::new(key, label, FieldKind::ChoiceSet { options, exclude: true, modes, default_mode: Some(default_mode.to_string()) })
    }

    pub fn toggle(key: &str, label: &str) -> Self {
        Self::new(key, label, FieldKind::Toggle)
    }

    pub fn hint(mut self, hint: &str) -> Self {
        self.hint = hint.to_string();
        self
    }

    pub fn unit(mut self, unit: &str) -> Self {
        match &mut self.kind {
            FieldKind::Number { unit: u, .. } | FieldKind::Range { unit: u, .. } => *u = Some(unit.to_string()),
            _ => {}
        }
        self
    }

    pub fn column(mut self, name: &str) -> Self {
        self.library = LibraryBinding::Column { name: name.to_string() };
        self
    }

    pub fn stat(mut self, key: &str) -> Self {
        self.library = LibraryBinding::Stat { key: key.to_string() };
        self
    }

    pub fn tag(mut self, kind: &str) -> Self {
        self.library = LibraryBinding::Tag { kind: kind.to_string() };
        self
    }

    pub fn bound(mut self, binding: LibraryBinding) -> Self {
        self.library = binding;
        self
    }

    pub fn default(mut self, value: FieldValue) -> Self {
        self.default = Some(value);
        self
    }
}

impl SearchSection {
    pub fn new(key: &str, label: &str, fields: Vec<SearchField>) -> Self {
        SearchSection { key: key.to_string(), label: label.to_string(), collapsed: false, fields }
    }

    pub fn collapsed(mut self) -> Self {
        self.collapsed = true;
        self
    }
}

impl SearchSchema {
    pub fn fields(&self) -> impl Iterator<Item = &SearchField> {
        self.sections.iter().flat_map(|s| s.fields.iter())
    }

    pub fn field(&self, key: &str) -> Option<&SearchField> {
        self.fields().find(|f| f.key == key)
    }

    /// Configuration errors an adapter test pins to zero: duplicate keys,
    /// duplicate option values, a missing or non-text primary, a default
    /// mode or sort default outside its list.
    pub fn validate(&self) -> Result<(), String> {
        let mut keys = std::collections::HashSet::new();
        for s in &self.sections {
            if !keys.insert(format!("section:{}", s.key)) {
                return Err(format!("duplicate section key {}", s.key));
            }
        }
        keys.clear();
        for f in self.fields() {
            if !keys.insert(f.key.clone()) {
                return Err(format!("duplicate field key {}", f.key));
            }
            let options = match &f.kind {
                FieldKind::Choice { options, .. } => Some(options),
                FieldKind::ChoiceSet { options, modes, default_mode, .. } => {
                    if let Some(m) = default_mode {
                        if !modes.iter().any(|o| &o.value == m) {
                            return Err(format!("field {}: default mode {m} not in modes", f.key));
                        }
                    }
                    Some(options)
                }
                _ => None,
            };
            if let Some(options) = options {
                let mut seen = std::collections::HashSet::new();
                for o in options {
                    if !seen.insert(o.value.as_str()) {
                        return Err(format!("field {}: duplicate option value {}", f.key, o.value));
                    }
                }
            }
        }
        match self.field(&self.primary) {
            Some(SearchField { kind: FieldKind::Text { .. }, .. }) => {}
            Some(_) => return Err(format!("primary field {} is not Text", self.primary)),
            None => return Err(format!("primary field {} missing", self.primary)),
        }
        if let Some(sort) = &self.sort {
            if !sort.columns.iter().any(|o| o.value == sort.default_column) {
                return Err(format!("default sort column {} not offered", sort.default_column));
            }
            if !sort.directions.iter().any(|o| o.value == sort.default_direction) {
                return Err(format!("default sort direction {} not offered", sort.default_direction));
            }
        }
        Ok(())
    }

    /// Pre-select the device language on the field bound to the
    /// `language` column: the first candidate (a locale tag compacted,
    /// then its alpha-2 and alpha-3 codes, from the platform) the field
    /// offers. A source without such a field is unchanged.
    pub fn apply_language_candidates(&mut self, candidates: &[String]) {
        for f in self.sections.iter_mut().flat_map(|s| s.fields.iter_mut()) {
            if f.library != (LibraryBinding::Column { name: "language".to_string() }) { continue }
            if let FieldKind::Choice { options, .. } = &f.kind {
                if let Some(c) = candidates.iter().find(|c| options.iter().any(|o| &o.value == *c)) {
                    f.default = Some(FieldValue::Choice { value: c.clone() });
                }
            }
        }
    }
}

/// Format a number for a query string: integers without a fraction,
/// others trimmed of trailing zeros.
pub fn fmt_num(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        let s = format!("{n}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn schema(fields: Vec<SearchField>) -> SearchSchema {
        SearchSchema { source: "t".into(), version: 1, primary: "q".into(), sections: vec![SearchSection::new("main", "Main", fields)], sort: None }
    }

    #[test]
    fn validate_catches_configuration_mistakes() {
        assert!(schema(vec![SearchField::text("q", "Q")]).validate().is_ok());
        assert!(schema(vec![SearchField::text("q", "Q"), SearchField::text("q", "Again")]).validate().unwrap_err().contains("duplicate field key"));
        assert!(schema(vec![SearchField::toggle("q", "Q")]).validate().unwrap_err().contains("not Text"));
        assert!(schema(vec![SearchField::text("x", "X")]).validate().unwrap_err().contains("missing"));
        let dup = SearchField::choice("c", "C", vec![opt("1", "a"), opt("1", "b")], None);
        assert!(schema(vec![SearchField::text("q", "Q"), dup]).validate().unwrap_err().contains("duplicate option"));
        let bad_mode = SearchField::include_exclude("g", "G", vec![opt("1", "a")], vec![opt("and", "AND")], "or");
        assert!(schema(vec![SearchField::text("q", "Q"), bad_mode]).validate().unwrap_err().contains("default mode"));
    }

    #[test]
    fn empty_values_are_omitted_by_get() {
        let q = SearchQuery::new("t", 1)
            .with("a", FieldValue::Text { value: "  ".into() })
            .with("b", FieldValue::Range { min: None, max: None })
            .with("c", FieldValue::Set { include: vec![], exclude: vec![], mode: Some("or".into()) })
            .with("d", FieldValue::Bool { value: false })
            .with("e", FieldValue::Range { min: Some(3.0), max: None });
        assert!(q.get("a").is_none() && q.get("b").is_none() && q.get("c").is_none() && !q.flag("d"));
        assert_eq!(q.range("e"), Some((Some(3.0), None)));
    }

    #[test]
    fn language_default_picks_first_offered_candidate() {
        let mut s = schema(vec![
            SearchField::text("q", "Q"),
            SearchField::choice("language", "Language", vec![opt("en", "English"), opt("ptBR", "Português brasileiro")], Some("Any")).column("language"),
        ]);
        s.apply_language_candidates(&["ptBR".into(), "pt".into()]);
        assert_eq!(s.field("language").unwrap().default, Some(FieldValue::Choice { value: "ptBR".into() }));
        s.apply_language_candidates(&["xx".into()]);
        assert_eq!(s.field("language").unwrap().default, Some(FieldValue::Choice { value: "ptBR".into() }), "no match leaves the field as it was");
    }

    #[test]
    fn numbers_format_for_query_strings() {
        assert_eq!(fmt_num(1000.0), "1000");
        assert_eq!(fmt_num(4.5), "4.5");
        assert_eq!(fmt_num(0.1), "0.1");
    }
}
