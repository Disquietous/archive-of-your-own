use rusqlite::params;

use crate::error::AppError;
use crate::models::{Chapter, ContentBlock, LocalSearchCriteria, Rating, SeriesMembership, Warning,
                    WorkSummary};

use super::consts::*;
use super::{map_json, map_sql, rating_to_str, str_to_rating, Storage};

impl Storage {
    // -------------------------------------------------------------------
    // Works
    // -------------------------------------------------------------------

    /// The works table's scalar columns, in `work_from_row` order. The tag
    /// vectors (fandoms, characters, relationships, freeforms) are not
    /// columns — they hydrate from the work_tags join via attach_work_tags.
    pub(super) const WORK_COLS: [&'static str; 20] = [
        "id", "title", "authors_json", "rating", "warnings_json",
        "categories_json", "summary", COL_WORD_COUNT, "chapter_count",
        "total_chapters", COL_KUDOS, COL_HITS, COL_BOOKMARKS, COL_COMMENTS,
        "date_published", "date_updated", "language", "complete",
        "series_json", "fetched_at",
    ];

    /// The SELECT list for `work_from_row`, with an optional table prefix
    /// ("w.") for joined queries.
    pub(super) fn work_select(prefix: &str) -> String {
        Self::WORK_COLS
            .iter()
            .map(|c| format!("{prefix}{c}"))
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// Upsert a work summary plus its author-index rows, atomically (a
    /// savepoint, so it also composes inside callers' batch transactions).
    pub fn save_work(&self, work: &WorkSummary) -> Result<(), AppError> {
        self.with_savepoint(Savepoint::SaveWork, || self.save_work_inner(work))
    }

    fn save_work_inner(&self, work: &WorkSummary) -> Result<(), AppError> {
        // Upsert, NOT INSERT OR REPLACE: replace re-creates the row, wiping
        // columns the blurb doesn't carry (gone_from_ao3).
        self.conn
            .execute(
                "INSERT INTO works (
                    id, title, authors_json, rating,
                    warnings_json, categories_json, summary, word_count,
                    chapter_count, total_chapters, kudos, hits,
                    bookmarks, comments, date_published, date_updated, language, complete,
                    fetched_at, warnings_mask, categories_mask, fandom_count
                ) VALUES (
                    ?1, ?2, ?3, ?4,
                    ?5, ?6, ?7, ?8,
                    ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16, ?17, ?18,
                    ?19, ?20, ?21, ?22
                )
                ON CONFLICT(id) DO UPDATE SET
                    title = ?2, authors_json = ?3, rating = ?4,
                    warnings_json = ?5, categories_json = ?6, summary = ?7, word_count = ?8,
                    chapter_count = ?9, total_chapters = ?10, kudos = ?11, hits = ?12,
                    bookmarks = ?13, comments = ?14, date_published = ?15, date_updated = ?16,
                    language = ?17, complete = ?18, fetched_at = ?19,
                    warnings_mask = ?20, categories_mask = ?21, fandom_count = ?22",
                params![
                    work.id as i64,
                    work.title,
                    serde_json::to_string(&work.authors).map_err(map_json)?,
                    rating_to_str(&work.rating),
                    serde_json::to_string(&work.warnings).map_err(map_json)?,
                    serde_json::to_string(&work.categories).map_err(map_json)?,
                    work.summary,
                    work.word_count as i64,
                    work.chapter_count as i64,
                    work.total_chapters.map(|c| c as i64),
                    work.kudos as i64,
                    work.hits as i64,
                    work.bookmarks as i64,
                    work.comments as i64,
                    work.date_published,
                    work.date_updated,
                    work.language,
                    work.complete as i32,
                    crate::timefmt::now_utc_datetime(),
                    super::works_search::warnings_mask(&work.warnings),
                    super::works_search::categories_mask(&work.categories),
                    work.fandoms.len() as i64,
                ],
            )
            .map_err(map_sql)?;
        self.replace_work_authors(work.id, &work.authors)?;
        self.replace_work_tag_rows(work.id, &work.fandoms, &work.characters,
                                   &work.relationships, &work.tags)?;
        // Seeing a work's details anywhere feeds the autocomplete tag cache.
        let _ = self.harvest_work_tags(work);
        Ok(())
    }

    // -------------------------------------------------------------------
    // Normalized tags (tags + work_tags/collection_tags join tables)
    // -------------------------------------------------------------------

    /// (Re)fill the in-memory tag cache from the tags table — run once at
    /// open, after migrations (which write tags with inline SQL, not through
    /// the cache-coherent paths below). Anything that deletes tags rows
    /// directly must call this again: a stale cached id would break the
    /// join-table foreign keys.
    pub(super) fn load_tag_cache(&self) -> Result<(), AppError> {
        let mut stmt = self.conn
            .prepare("SELECT id, name, tag_type FROM tags")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
            })
            .map_err(map_sql)?;
        let mut cache = self.tag_cache.borrow_mut();
        cache.clear();
        for row in rows {
            let (id, name, tag_type) = row.map_err(map_sql)?;
            cache.insert(name, (id, !tag_type.is_empty()));
        }
        Ok(())
    }

    /// The tags-table id for a name, inserting the row if new. Tag identity
    /// is the name alone — AO3 tag names are globally unique across every
    /// tag type (hence the "- Freeform" suffixes), so the same tag is one
    /// row wherever it appears: on works, on collections, anywhere.
    /// `tag_type` fills in an existing row's type only when it hasn't been
    /// learned yet ("" = unknown, e.g. from a collection profile).
    /// Answered from the in-memory cache: a known tag with a known type
    /// costs no SQL.
    pub(super) fn tag_row_id(&self, name: &str, tag_type: &str) -> Result<i64, AppError> {
        let cached = self.tag_cache.borrow().get(name).copied();
        if let Some((id, type_known)) = cached {
            if type_known || tag_type.is_empty() {
                return Ok(id);
            }
            // Rare: an unknown-typed row (e.g. from a collection profile)
            // learning its real type from a work listing.
            self.conn
                .prepare_cached("UPDATE tags SET tag_type = ?2 WHERE id = ?1 AND tag_type = ''")
                .map_err(map_sql)?
                .execute(params![id, tag_type])
                .map_err(map_sql)?;
            self.tag_cache.borrow_mut().insert(name.to_string(), (id, true));
            return Ok(id);
        }
        self.conn
            .prepare_cached(
                "INSERT INTO tags (name, tag_type) VALUES (?1, ?2)
                 ON CONFLICT(name) DO UPDATE SET tag_type = excluded.tag_type
                     WHERE tags.tag_type = '' AND excluded.tag_type <> ''")
            .map_err(map_sql)?
            .execute(params![name, tag_type])
            .map_err(map_sql)?;
        let id: i64 = self.conn
            .prepare_cached("SELECT id FROM tags WHERE name = ?1")
            .map_err(map_sql)?
            .query_row(params![name], |r| r.get(0))
            .map_err(map_sql)?;
        self.tag_cache.borrow_mut().insert(name.to_string(), (id, !tag_type.is_empty()));
        Ok(id)
    }

    /// Rewrite a work's join rows. `tag_type` records how this work uses
    /// the tag (which blurb list it came from); `position` runs across the
    /// four lists in AO3's blurb order so reads reproduce the original
    /// ordering.
    fn replace_work_tag_rows(&self, work_id: u64, fandoms: &[String], characters: &[String],
                             relationships: &[String], freeforms: &[String])
        -> Result<(), AppError>
    {
        self.conn
            .execute("DELETE FROM work_tags WHERE work_id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        let mut stmt = self.conn
            .prepare_cached("INSERT OR IGNORE INTO work_tags (work_id, tag_id, tag_type, position)
                             VALUES (?1, ?2, ?3, ?4)")
            .map_err(map_sql)?;
        let mut position = 0i64;
        for (list, tag_type) in [(fandoms, TAG_TYPE_FANDOM), (characters, TAG_TYPE_CHARACTER),
                                 (relationships, TAG_TYPE_RELATIONSHIP), (freeforms, TAG_TYPE_FREEFORM)] {
            for name in list {
                let tag_id = self.tag_row_id(name, tag_type)?;
                stmt.execute(params![work_id as i64, tag_id, tag_type, position])
                    .map_err(map_sql)?;
                position += 1;
            }
        }
        Ok(())
    }

    /// Hydrate the tag vectors on loaded rows from the join tables — the
    /// works SELECTs only carry scalar columns. Batched in id chunks (one
    /// query per chunk, not per work): per-statement overhead dominates
    /// this path, so N works must not mean N round trips.
    pub(super) fn attach_work_tags(&self, works: &mut [WorkSummary]) -> Result<(), AppError> {
        if works.is_empty() {
            return Ok(());
        }
        let slot_by_id: std::collections::HashMap<i64, usize> = works
            .iter()
            .enumerate()
            .map(|(i, w)| (w.id as i64, i))
            .collect();
        let ids: Vec<i64> = works.iter().map(|w| w.id as i64).collect();
        for chunk in ids.chunks(SQL_IN_CHUNK) {
            let sql = format!(
                "SELECT wt.work_id, t.name, wt.tag_type FROM work_tags wt
                 JOIN tags t ON t.id = wt.tag_id
                 WHERE wt.work_id IN ({})
                 ORDER BY wt.work_id, wt.position",
                sql_placeholders(chunk.len())
            );
            let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(chunk.iter()), |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
                })
                .map_err(map_sql)?;
            for row in rows {
                let (work_id, name, tag_type) = row.map_err(map_sql)?;
                let Some(&slot) = slot_by_id.get(&work_id) else { continue };
                let work = &mut works[slot];
                match tag_type.as_str() {
                    TAG_TYPE_FANDOM => work.fandoms.push(name),
                    TAG_TYPE_CHARACTER => work.characters.push(name),
                    TAG_TYPE_RELATIONSHIP => work.relationships.push(name),
                    _ => work.tags.push(name),
                }
            }
        }
        Ok(())
    }

    /// Seed work_tags join rows from the pre-v8 JSON list columns, adding
    /// any tag names the known_tags harvest never saw. Version-frozen
    /// against the v8 table shapes (inline SQL, no live helpers) so future
    /// migrations can't silently change what this step replays. Runs inside
    /// the v8 step, while the JSON columns still exist.
    pub(super) fn backfill_work_tags_v8(&self) -> Result<(), AppError> {
        let rows: Vec<(i64, String, String, String, String)> = {
            let mut stmt = self.conn
                .prepare("SELECT id, fandoms_json, characters_json,
                                 relationships_json, tags_json FROM works")
                .map_err(map_sql)?;
            let mapped = stmt
                .query_map([], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })
                .map_err(map_sql)?;
            mapped.collect::<Result<Vec<_>, _>>().map_err(map_sql)?
        };
        let parse = |s: &str| serde_json::from_str::<Vec<String>>(s).unwrap_or_default();
        let mut insert_tag = self.conn
            .prepare("INSERT INTO tags (name, tag_type) VALUES (?1, ?2)
                      ON CONFLICT(name) DO UPDATE SET tag_type = excluded.tag_type
                          WHERE tags.tag_type = ''")
            .map_err(map_sql)?;
        let mut select_tag = self.conn
            .prepare("SELECT id FROM tags WHERE name = ?1")
            .map_err(map_sql)?;
        let mut insert_link = self.conn
            .prepare("INSERT OR IGNORE INTO work_tags (work_id, tag_id, tag_type, position)
                      VALUES (?1, ?2, ?3, ?4)")
            .map_err(map_sql)?;
        for (id, fandoms, characters, relationships, freeforms) in rows {
            let mut position = 0i64;
            for (list, tag_type) in [(parse(&fandoms), "fandom"), (parse(&characters), "character"),
                                     (parse(&relationships), "relationship"),
                                     (parse(&freeforms), "freeform")] {
                for name in &list {
                    insert_tag.execute(params![name, tag_type]).map_err(map_sql)?;
                    let tag_id: i64 = select_tag
                        .query_row(params![name], |r| r.get(0))
                        .map_err(map_sql)?;
                    insert_link.execute(params![id, tag_id, tag_type, position]).map_err(map_sql)?;
                    position += 1;
                }
            }
        }
        Ok(())
    }

    /// Rewrite the author-index rows for one work.
    fn replace_work_authors(&self, work_id: u64, authors: &[String]) -> Result<(), AppError> {
        self.conn
            .execute("DELETE FROM work_authors WHERE work_id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        let mut stmt = self
            .conn
            .prepare_cached("INSERT OR IGNORE INTO work_authors (work_id, author) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        for author in authors {
            stmt.execute(params![work_id as i64, author]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// Seed the author index from every already-cached work (v2 migration).
    pub(super) fn backfill_work_authors(&self) -> Result<(), AppError> {
        let rows: Vec<(i64, String)> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id, authors_json FROM works")
                .map_err(map_sql)?;
            let mapped = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(map_sql)?;
            mapped.collect::<Result<Vec<_>, _>>().map_err(map_sql)?
        };
        let mut stmt = self
            .conn
            .prepare("INSERT OR IGNORE INTO work_authors (work_id, author) VALUES (?1, ?2)")
            .map_err(map_sql)?;
        for (id, json) in rows {
            for author in serde_json::from_str::<Vec<String>>(&json).unwrap_or_default() {
                stmt.execute(params![id, author]).map_err(map_sql)?;
            }
        }
        Ok(())
    }

    /// Persist series memberships for a work. Separate from `save_work`
    /// because listing blurbs never carry series data and their upserts
    /// must not clobber it; only full work-page fetches call this. Always
    /// writes — the work page is authoritative, so an empty slice clears.
    pub fn set_work_series(&self, work_id: u64, series: &[SeriesMembership]) -> Result<(), AppError> {
        self.conn
            .execute(
                "UPDATE works SET series_json = ?2 WHERE id = ?1",
                params![
                    work_id as i64,
                    serde_json::to_string(series).map_err(map_json)?
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// An avatar URL already harvested for this username (from cached
    /// comments/inbox data) — saves the profile-page request entirely.
    pub fn get_known_avatar_url(&self, username: &str) -> Result<Option<String>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT avatar_url FROM ao3_users
             WHERE username = ?1 COLLATE NOCASE AND avatar_url != ''
             ORDER BY updated_at DESC LIMIT 1"
        ).map_err(map_sql)?;
        let mut rows = stmt.query_map(params![username], |row| row.get::<_, String>(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(url)) => Ok(Some(url)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Image cache (avatars etc. — fetched once, then served locally)
    // -------------------------------------------------------------------

    pub fn save_cached_image(&self, key: &str, data: &[u8]) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO image_cache (key, data) VALUES (?1, ?2)",
            params![key, data],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn delete_cached_image(&self, key: &str) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM image_cache WHERE key = ?1", params![key])
            .map_err(map_sql)?;
        Ok(())
    }

    pub fn get_cached_image(&self, key: &str) -> Result<Option<Vec<u8>>, AppError> {
        let mut stmt = self.conn
            .prepare("SELECT data FROM image_cache WHERE key = ?1")
            .map_err(map_sql)?;
        let mut rows = stmt.query_map(params![key], |row| row.get::<_, Vec<u8>>(0)).map_err(map_sql)?;
        match rows.next() {
            Some(Ok(data)) => Ok(Some(data)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Tag rows (autocomplete ranking — harvested from every viewed work)
    // -------------------------------------------------------------------

    /// Bump the ranking columns of every tag on a work for autocomplete.
    /// Idempotent: new tags insert, known tags bump use count and freshness.
    pub fn harvest_work_tags(&self, work: &WorkSummary) -> Result<(), AppError> {
        let mut tags: Vec<(&str, &str)> = Vec::new();
        for f in &work.fandoms { tags.push((f, TAG_TYPE_FANDOM)); }
        for c in &work.characters { tags.push((c, TAG_TYPE_CHARACTER)); }
        for r in &work.relationships { tags.push((r, TAG_TYPE_RELATIONSHIP)); }
        for t in &work.tags { tags.push((t, TAG_TYPE_FREEFORM)); }
        for a in &work.authors { tags.push((a, TAG_TYPE_CREATOR)); }
        self.upsert_tags(&tags)
    }

    pub fn upsert_tags(&self, tags: &[(&str, &str)]) -> Result<(), AppError> {
        // The in-memory cache answers for names the library already knows
        // (with their type) — re-sighting a tag costs no SQL, not even a
        // savepoint. Only genuinely new names and the rare type upgrade
        // reach the database.
        let pending: Vec<(&str, &str)> = tags.iter()
            .map(|(name, tag_type)| (name.trim(), *tag_type))
            .filter(|(name, tag_type)| {
                !name.is_empty()
                    && match self.tag_cache.borrow().get(*name) {
                        Some(&(_, type_known)) => !type_known && !tag_type.is_empty(),
                        None => true,
                    }
            })
            .collect();
        if pending.is_empty() {
            return Ok(());
        }
        self.with_savepoint(Savepoint::UpsertTags, || {
            for (name, tag_type) in &pending {
                self.tag_row_id(name, tag_type)?;
            }
            Ok(())
        })
    }

    /// Record names confirmed by AO3's autocomplete as canonical. A
    /// per-type endpoint's answer is authoritative for the type, too; the
    /// any-type "tag" endpoint confirms the name without teaching a type,
    /// so it never touches one already learned.
    pub fn mark_tags_canonical(&self, tag_type: &str, names: &[String]) -> Result<(), AppError> {
        if names.is_empty() {
            return Ok(());
        }
        let learned_type = if tag_type == "tag" { "" } else { tag_type };
        self.with_savepoint(Savepoint::CanonicalTags, || {
            let mut stmt = self.conn.prepare_cached(
                "INSERT INTO tags (name, tag_type, canonical) VALUES (?1, ?2, 1)
                 ON CONFLICT(name) DO UPDATE SET
                     canonical = 1,
                     last_seen = datetime('now'),
                     tag_type = CASE WHEN excluded.tag_type <> '' THEN excluded.tag_type
                                     ELSE tags.tag_type END"
            ).map_err(map_sql)?;
            for name in names {
                let trimmed = name.trim();
                if trimmed.is_empty() { continue; }
                stmt.execute(params![trimmed, learned_type]).map_err(map_sql)?;
            }
            Ok(())
        })
    }

    /// Escape LIKE metacharacters so a search term is matched literally
    /// (queries pair this with `ESCAPE '\'`).
    pub(super) fn escape_like(term: &str) -> String {
        term.trim()
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    }

    /// Map the search functions' `limit` to SQL: 0 means no limit, which
    /// SQLite spells as a negative LIMIT.
    pub(super) fn sql_limit(limit: u32) -> i64 {
        if limit == 0 { -1 } else { limit as i64 }
    }

    /// Local autocomplete: substring match, alphabetical.
    pub fn search_tags(&self, tag_type: &str, term: &str, limit: u32) -> Result<Vec<String>, AppError> {
        let escaped = Self::escape_like(term);
        if escaped.is_empty() {
            return Ok(Vec::new());
        }
        let contains = like_contains(&escaped);
        let mut stmt = self.conn.prepare(
            "SELECT name FROM tags
             WHERE tag_type = ?1 AND name LIKE ?2 ESCAPE '\\'
             ORDER BY name COLLATE NOCASE
             LIMIT ?3"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![tag_type, contains, limit], |row| {
            row.get::<_, String>(0)
        }).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Library-scope tag search: like `search_tags` but across every
    /// tag type. Returns (name, tag_type) so rows can say what kind of tag
    /// each hit is.
    pub fn search_tags_all(&self, term: &str, limit: u32) -> Result<Vec<(String, String)>, AppError> {
        let limit = Self::sql_limit(limit);
        let escaped = Self::escape_like(term);
        if escaped.is_empty() {
            return Ok(Vec::new());
        }
        let contains = like_contains(&escaped);
        let mut stmt = self.conn.prepare(
            "SELECT name, tag_type FROM tags
             WHERE name LIKE ?1 ESCAPE '\\'
             ORDER BY name COLLATE NOCASE
             LIMIT ?2"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![contains, limit], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).map_err(map_sql)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Library-scope work search: case-insensitive substring across the
    /// title, creators, fandoms, tags, and summary of every cached work.
    /// Title matches rank first, then most recently updated.
    pub fn search_local_works(&self, term: &str, limit: u32) -> Result<Vec<WorkSummary>, AppError> {
        let limit = Self::sql_limit(limit);
        let escaped = Self::escape_like(term);
        if escaped.is_empty() {
            // An empty query means "my whole library", not "nothing" — the
            // search form's default state runs it with no criteria.
            let mut stmt = self.conn.prepare(&format!(
                "SELECT {} FROM works
                 ORDER BY date_updated DESC
                 LIMIT ?1", Self::work_select(""))
            ).map_err(map_sql)?;
            let rows = stmt.query_map(params![limit], |row| {
                Ok(Self::work_from_row(row))
            }).map_err(map_sql)?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row.map_err(map_sql)?.map_err(map_sql)?);
            }
            self.attach_work_tags(&mut out)?;
            return Ok(out);
        }
        let contains = like_contains(&escaped);
        let title_prefix = like_prefix(&escaped);
        // Tag names live in the join tables now — one EXISTS covers what
        // the four dropped JSON columns used to.
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {} FROM works
             WHERE title LIKE ?1 ESCAPE '\\'
                OR authors_json LIKE ?1 ESCAPE '\\'
                OR summary LIKE ?1 ESCAPE '\\'
                OR EXISTS (SELECT 1 FROM work_tags wt
                           JOIN tags t ON t.id = wt.tag_id
                           WHERE wt.work_id = works.id
                             AND t.name LIKE ?1 ESCAPE '\\')
             ORDER BY (title LIKE ?2 ESCAPE '\\') DESC, date_updated DESC
             LIMIT ?3", Self::work_select(""))
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![contains, title_prefix, limit], |row| {
            Ok(Self::work_from_row(row))
        }).map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        self.attach_work_tags(&mut out)?;
        Ok(out)
    }

    /// Library-scope search with the full works-search form: every AO3
    /// criterion evaluated against the cached works. Blank criteria match
    /// everything, so the default form returns the whole library.
    /// `limit` of 0 means no limit.
    pub fn search_local_works_filtered(&self, c: &LocalSearchCriteria, limit: u32)
        -> Result<Vec<WorkSummary>, AppError>
    {
        let mut works: Vec<WorkSummary> = self.get_all_works()?
            .into_iter()
            .filter(|w| Self::work_matches(c, w))
            .collect();
        Self::sort_filtered(&mut works, &c.sort_column, &c.sort_direction);
        if limit > 0 {
            works.truncate(limit as usize);
        }
        Ok(works)
    }

    fn work_matches(c: &LocalSearchCriteria, w: &WorkSummary) -> bool {
        // Free-text query: substring across everything searchable, like the
        // term-only search.
        let q = c.query.trim();
        if !q.is_empty() {
            let hit = Self::contains_ci(&w.title, q)
                || Self::any_ci(&w.authors, q)
                || Self::any_ci(&w.fandoms, q)
                || Self::any_ci(&w.relationships, q)
                || Self::any_ci(&w.characters, q)
                || Self::any_ci(&w.tags, q)
                || Self::contains_ci(&w.summary, q);
            if !hit { return false; }
        }
        let title = c.title.trim();
        if !title.is_empty() && !Self::contains_ci(&w.title, title) { return false; }

        // Comma-separated name fields AND together, matching AO3.
        if !Self::names_match(&c.creators, &w.authors) { return false; }
        if !Self::names_match(&c.fandom_names, &w.fandoms) { return false; }
        if !Self::names_match(&c.character_names, &w.characters) { return false; }
        if !Self::names_match(&c.relationship_names, &w.relationships) { return false; }
        if !Self::names_match(&c.freeform_names, &w.tags) { return false; }

        // Rating labels OR (a work has one rating); warnings and categories
        // AND, matching AO3's checkbox semantics.
        if !c.ratings.is_empty()
            && !c.ratings.iter().any(|l| Rating::from_ao3_tag(l) == w.rating) { return false; }
        if !c.warnings.iter().all(|l| w.warnings.contains(&Warning::from_ao3_tag(l))) { return false; }
        if !c.categories.iter()
            .all(|l| w.categories.iter().any(|s| s.eq_ignore_ascii_case(l))) { return false; }

        match c.complete.as_str() {
            "T" if !w.complete => return false,
            "F" if w.complete => return false,
            _ => {}
        }
        // AO3 counts a work as a crossover when it's tagged with more than
        // one fandom.
        match c.crossover.as_str() {
            "T" if w.fandoms.len() <= 1 => return false,
            "F" if w.fandoms.len() > 1 => return false,
            _ => {}
        }
        if c.single_chapter && w.chapter_count != 1 { return false; }

        let language = c.language.trim();
        if !language.is_empty() && !w.language.eq_ignore_ascii_case(language) { return false; }

        Self::range_matches(&c.word_count, w.word_count)
            && Self::range_matches(&c.hits, w.hits)
            && Self::range_matches(&c.kudos_count, w.kudos as u64)
            && Self::range_matches(&c.comments_count, w.comments as u64)
            && Self::range_matches(&c.bookmarks_count, w.bookmarks as u64)
            && Self::revised_matches(&c.revised_at, &w.date_updated)
    }

    pub(super) fn contains_ci(hay: &str, needle: &str) -> bool {
        hay.to_lowercase().contains(&needle.to_lowercase())
    }

    pub(super) fn any_ci(list: &[String], needle: &str) -> bool {
        list.iter().any(|s| Self::contains_ci(s, needle))
    }

    /// Comma-separated names: every entry must match a stored name
    /// (case-insensitive substring, so exact autocomplete picks and partial
    /// typing both work). Blank matches everything.
    pub(super) fn names_match(field: &str, stored: &[String]) -> bool {
        field.split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .all(|name| Self::any_ci(stored, name))
    }

    /// AO3 numeric range syntax: "500", ">500", "<500", ">=500", "<=500",
    /// "100-5000". Blank or unparseable expressions don't filter.
    pub(super) fn range_matches(expr: &str, value: u64) -> bool {
        let expr: String = expr.chars().filter(|c| *c != ',' && !c.is_whitespace()).collect();
        if expr.is_empty() { return true; }
        let parsed = |s: &str| s.parse::<u64>().ok();
        if let Some(n) = expr.strip_prefix(">=").and_then(parsed) { return value >= n; }
        if let Some(n) = expr.strip_prefix("<=").and_then(parsed) { return value <= n; }
        if let Some(n) = expr.strip_prefix('>').and_then(parsed) { return value > n; }
        if let Some(n) = expr.strip_prefix('<').and_then(parsed) { return value < n; }
        if let Some((lo, hi)) = expr.split_once('-') {
            if let (Some(lo), Some(hi)) = (parsed(lo), parsed(hi)) {
                return value >= lo && value <= hi;
            }
        }
        match parsed(&expr) {
            Some(n) => value == n,
            None => true,
        }
    }

    /// AO3 "Date Updated" syntax: an ISO date or prefix ("2024", "2024-01",
    /// "2024-01-15"), or a relative "< 2 weeks ago" / "> 3 months ago".
    /// For relative expressions "<" means less time ago (more recent) and
    /// ">" longer ago, matching AO3; for absolute dates they mean plain
    /// before/after. Blank or unparseable expressions don't filter.
    pub(super) fn revised_matches(expr: &str, date_updated: &str) -> bool {
        let expr = expr.trim();
        if expr.is_empty() { return true; }
        if date_updated.is_empty() { return false; }
        let (op, rest) = match expr.as_bytes()[0] {
            b'<' => ('<', expr[1..].trim_start_matches('=').trim()),
            b'>' => ('>', expr[1..].trim_start_matches('=').trim()),
            _ => ('=', expr),
        };
        if let Some(cutoff) = Self::relative_date(rest) {
            let cutoff = cutoff.format("%Y-%m-%d").to_string();
            return match op {
                '<' => *date_updated >= *cutoff,
                '>' => *date_updated < *cutoff,
                _ => *date_updated == *cutoff,
            };
        }
        // ISO dates compare lexicographically, prefixes included
        // ("2025-06-01" < "2026" holds).
        match op {
            '<' => *date_updated < *rest,
            '>' => *date_updated > *rest && !date_updated.starts_with(rest),
            _ => date_updated.starts_with(rest),
        }
    }

    /// "2 weeks ago"-style expressions to a calendar date. Months and years
    /// use calendar arithmetic via 30/365-day approximations — fine for a
    /// library filter.
    pub(super) fn relative_date(s: &str) -> Option<chrono::NaiveDate> {
        let s = s.trim().to_lowercase();
        let rest = s.strip_suffix("ago")?.trim();
        let mut parts = rest.split_whitespace();
        let n: i64 = parts.next()?.parse().ok()?;
        let unit = parts.next()?;
        let days = match unit.trim_end_matches('s') {
            "day" => n,
            "week" => n * 7,
            "month" => n * 30,
            "year" => n * 365,
            _ => return None,
        };
        Some(chrono::Local::now().date_naive() - chrono::Duration::days(days))
    }

    /// AO3's sort columns applied locally. "_score" (Best Match) has no
    /// local meaning; it and unknown columns fall back to Date Updated.
    /// Direction defaults the way AO3 does: ascending for title, descending
    /// for everything else.
    fn sort_filtered(works: &mut [WorkSummary], column: &str, direction: &str) {
        let column = column.trim();
        works.sort_by(|a, b| match column {
            SORT_KEY_TITLE => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
            SORT_KEY_CREATED_AT => a.date_published.cmp(&b.date_published),
            SORT_KEY_WORD_COUNT => a.word_count.cmp(&b.word_count),
            SORT_KEY_HITS => a.hits.cmp(&b.hits),
            SORT_KEY_KUDOS => a.kudos.cmp(&b.kudos),
            SORT_KEY_COMMENTS => a.comments.cmp(&b.comments),
            SORT_KEY_BOOKMARKS => a.bookmarks.cmp(&b.bookmarks),
            _ => a.date_updated.cmp(&b.date_updated),
        });
        let ascending = match direction.trim() {
            SORT_ASC => true,
            SORT_DESC => false,
            _ => column == SORT_KEY_TITLE,
        };
        if !ascending {
            works.reverse();
        }
    }

    /// One-time seed of the tags table from works cached before it existed.
    /// (The state key keeps its historical name so already-seeded databases
    /// don't re-run it.)
    pub(super) fn backfill_tags(&self) -> Result<(), AppError> {
        if self.get_state(STATE_KNOWN_TAGS_BACKFILLED)?.is_some() {
            return Ok(());
        }
        for work in self.get_all_works()? {
            let _ = self.harvest_work_tags(&work);
        }
        self.set_state(STATE_KNOWN_TAGS_BACKFILLED, "1")
    }

    /// Retrieve a single work by its AO3 id, or `None` if not stored.
    pub fn get_work(&self, work_id: u64) -> Result<Option<WorkSummary>, AppError> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {} FROM works WHERE id = ?1", Self::work_select("")))
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(params![work_id as i64], |row| {
                Ok(Self::work_from_row(row))
            })
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(inner)) => {
                let mut works = [inner.map_err(map_sql)?];
                self.attach_work_tags(&mut works)?;
                let [work] = works;
                Ok(Some(work))
            }
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    /// The stored works for `ids`, preserving the ids' order; ids without a
    /// cached row are skipped. Batched — never one query per id.
    pub fn get_works_by_ids(&self, ids: &[u64]) -> Result<Vec<WorkSummary>, AppError> {
        self.get_works_by_ids_ordered(ids)
    }

    /// Return every stored work (unordered).
    pub fn get_all_works(&self) -> Result<Vec<WorkSummary>, AppError> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {} FROM works", Self::work_select("")))
            .map_err(map_sql)?;

        let rows = stmt
            .query_map([], |row| Ok(Self::work_from_row(row)))
            .map_err(map_sql)?;

        let mut works = Vec::new();
        for row in rows {
            works.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        self.attach_work_tags(&mut works)?;
        Ok(works)
    }

    /// Return works whose `authors_json` contains the given username.
    pub fn get_works_by_author(&self, username: &str) -> Result<Vec<WorkSummary>, AppError> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {} FROM works w JOIN work_authors a ON a.work_id = w.id
                 WHERE a.author = ?1
                 ORDER BY w.date_updated DESC", Self::work_select("w.")))
            .map_err(map_sql)?;

        let rows = stmt
            .query_map(params![username], |row| Ok(Self::work_from_row(row)))
            .map_err(map_sql)?;

        let mut works = Vec::new();
        for row in rows {
            works.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        self.attach_work_tags(&mut works)?;
        Ok(works)
    }

    /// Delete a work (and its chapters, progress, bookmark, and history;
    /// work_tags and collection_works rows cascade via their foreign keys).
    pub fn delete_work(&self, work_id: u64) -> Result<(), AppError> {
        let id = work_id as i64;
        self.conn
            .execute("DELETE FROM chapters WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM bookmarks WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM history WHERE work_id = ?1", params![id])
            .map_err(map_sql)?;
        self.conn
            .execute("DELETE FROM works WHERE id = ?1", params![id])
            .map_err(map_sql)?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Chapters
    // -------------------------------------------------------------------

    /// Insert or replace a chapter for the given work.
    pub fn save_chapter(&self, work_id: u64, chapter: &Chapter) -> Result<(), AppError> {
        let content_json = serde_json::to_string(&chapter.content).map_err(map_json)?;
        self.conn
            .execute(
                "INSERT OR REPLACE INTO chapters
                    (work_id, number, chapter_id, title, content_json,
                     notes_before, notes_after)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    work_id as i64,
                    chapter.number as i64,
                    chapter.id.map(|id| id as i64),
                    chapter.title,
                    content_json,
                    chapter.notes_before,
                    chapter.notes_after,
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// All chapters for a work, ordered by chapter number.
    pub fn get_chapters(&self, work_id: u64) -> Result<Vec<Chapter>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT chapter_id, title, number, content_json,
                        notes_before, notes_after
                 FROM chapters WHERE work_id = ?1 ORDER BY number ASC",
            )
            .map_err(map_sql)?;

        let rows = stmt
            .query_map(params![work_id as i64], |row| {
                Ok(Self::chapter_from_row(row))
            })
            .map_err(map_sql)?;

        let mut chapters = Vec::new();
        for row in rows {
            chapters.push(row.map_err(map_sql)?.map_err(map_sql)?);
        }
        Ok(chapters)
    }

    /// A single chapter by work id and chapter number.
    pub fn get_chapter(
        &self,
        work_id: u64,
        chapter_number: u32,
    ) -> Result<Option<Chapter>, AppError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT chapter_id, title, number, content_json,
                        notes_before, notes_after
                 FROM chapters WHERE work_id = ?1 AND number = ?2",
            )
            .map_err(map_sql)?;

        let mut rows = stmt
            .query_map(
                params![work_id as i64, chapter_number as i64],
                |row| Ok(Self::chapter_from_row(row)),
            )
            .map_err(map_sql)?;

        match rows.next() {
            Some(Ok(inner)) => Ok(Some(inner.map_err(map_sql)?)),
            Some(Err(e)) => Err(map_sql(e)),
            None => Ok(None),
        }
    }

    // -------------------------------------------------------------------
    // Downloads (intentional user downloads)
    // -------------------------------------------------------------------

    pub fn mark_downloaded(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO downloads (work_id) VALUES (?1)",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn unmark_downloaded(&self, work_id: u64) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM downloads WHERE work_id = ?1",
            params![work_id as i64],
        ).map_err(map_sql)?;
        Ok(())
    }

    pub fn is_downloaded(&self, work_id: u64) -> Result<bool, AppError> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM downloads WHERE work_id = ?1",
            params![work_id as i64],
            |row| row.get(0),
        ).map_err(map_sql)?;
        Ok(count > 0)
    }

    pub fn get_downloaded_ids(&self) -> Result<Vec<u64>, AppError> {
        let mut stmt = self.conn.prepare("SELECT work_id FROM downloads").map_err(map_sql)?;
        let rows = stmt.query_map([], |row| {
            let id: i64 = row.get(0)?;
            Ok(id as u64)
        }).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }

    // -------------------------------------------------------------------
    // Cleanup — purge chapters for works that aren't downloaded or currently reading
    // -------------------------------------------------------------------

    pub fn purge_non_retained_chapters(&self) -> Result<(), AppError> {
        self.conn.execute(
            "DELETE FROM chapters WHERE work_id NOT IN (SELECT work_id FROM downloads)
                                    AND work_id NOT IN (SELECT id FROM works WHERE last_chapter_read > 0)",
            [],
        ).map_err(map_sql)?;
        Ok(())
    }

    /// Map a row from the `WORK_COLS` SELECT into a `WorkSummary`. The tag
    /// vectors come back empty — callers hydrate them with attach_work_tags.
    pub(super) fn work_from_row(row: &rusqlite::Row<'_>) -> Result<WorkSummary, rusqlite::Error> {
        let id: i64 = row.get(0)?;
        let title: String = row.get(1)?;
        let authors_json: String = row.get(2)?;
        let rating_str: String = row.get(3)?;
        let warnings_json: String = row.get(4)?;
        let categories_json: String = row.get(5)?;
        let summary: String = row.get(6)?;
        let word_count: i64 = row.get(7)?;
        let chapter_count: i64 = row.get(8)?;
        let total_chapters: Option<i64> = row.get(9)?;
        let kudos: i64 = row.get(10)?;
        let hits: i64 = row.get(11)?;
        let bookmarks: i64 = row.get(12)?;
        let comments: i64 = row.get(13)?;
        let date_published: String = row.get(14)?;
        let date_updated: String = row.get(15)?;
        let language: String = row.get(16)?;
        let complete: i32 = row.get(17)?;
        let series_json: String = row.get(18)?;
        let fetched_at: String = row.get(19)?;

        // Deserialize JSON columns — use unwrap_or_default so a corrupted
        // row doesn't crash the whole query; the caller can still surface the
        // remaining intact fields.
        let authors: Vec<String> =
            serde_json::from_str(&authors_json).unwrap_or_default();
        let warnings: Vec<Warning> =
            serde_json::from_str(&warnings_json).unwrap_or_default();
        let categories: Vec<String> =
            serde_json::from_str(&categories_json).unwrap_or_default();
        let series: Vec<SeriesMembership> =
            serde_json::from_str(&series_json).unwrap_or_default();

        Ok(WorkSummary {
            id: id as u64,
            title,
            authors,
            fandoms: Vec::new(),
            rating: str_to_rating(&rating_str),
            warnings,
            categories,
            relationships: Vec::new(),
            characters: Vec::new(),
            tags: Vec::new(),
            summary,
            word_count: word_count as u64,
            chapter_count: chapter_count as u32,
            total_chapters: total_chapters.map(|c| c as u32),
            kudos: kudos as u32,
            hits: hits as u64,
            bookmarks: bookmarks as u32,
            comments: comments as u32,
            date_published,
            date_updated,
            language,
            complete: complete != 0,
            series,
            fetched_at,
        })
    }

    /// Map a row from the `chapters` SELECT into a `Chapter`.
    fn chapter_from_row(row: &rusqlite::Row<'_>) -> Result<Chapter, rusqlite::Error> {
        let chapter_id: Option<i64> = row.get(0)?;
        let title: Option<String> = row.get(1)?;
        let number: i64 = row.get(2)?;
        let content_json: String = row.get(3)?;
        let notes_before: Option<String> = row.get(4)?;
        let notes_after: Option<String> = row.get(5)?;

        let content: Vec<ContentBlock> =
            serde_json::from_str(&content_json).unwrap_or_default();

        Ok(Chapter {
            id: chapter_id.map(|i| i as u64),
            title,
            number: number as u32,
            content,
            notes_before,
            notes_after,
        })
    }
}
