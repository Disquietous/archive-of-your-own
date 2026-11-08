//! People at a source — the `users` table and their source properties
//! (design/users-model-plan.md). Identity is the row id; names are for
//! display. AO3-only flows (follows, subscriptions, block, mute, name
//! search) resolve AO3 names within AO3, where account names are unique.

use rusqlite::params;

use crate::error::AppError;
use crate::models::{split_author_byline, AO3User, ExternalRef, SourceUserProfile};
use crate::user_fields::{self, UserField};

use super::users_cache::UserEntity;
use super::{map_sql, Storage};

/// One stored property, as the API reads it.
#[derive(Debug, Clone, PartialEq)]
pub struct UserProperty {
    pub name: String,
    pub value: String,
    pub updated_at: String,
}

/// A users row with every property, as the API reads it.
#[derive(Debug, Clone)]
pub struct UserRecord {
    pub id: i64,
    pub source: String,
    pub source_id: String,
    pub username: String,
    pub created_at: String,
    pub updated_at: String,
    pub properties: Vec<UserProperty>,
}

impl UserRecord {
    fn from_entity(e: &UserEntity) -> UserRecord {
        UserRecord {
            id: e.id, source: e.source.clone(), source_id: e.source_id.clone(), username: e.username.clone(),
            created_at: e.created_at.clone(), updated_at: e.updated_at.clone(),
            properties: e.props.iter()
                .map(|(n, p)| UserProperty { name: n.clone(), value: p.value.clone(), updated_at: p.updated_at.clone() })
                .collect(),
        }
    }

    pub fn property(&self, name: &str) -> Option<&str> {
        self.properties.iter().find(|p| p.name == name).map(|p| p.value.as_str()).filter(|v| !v.is_empty())
    }

    /// A global field's value through the source's mapping.
    pub fn field(&self, field: UserField) -> Option<&str> {
        user_fields::native_name(&self.source, field).and_then(|n| self.property(n))
    }

    pub fn external_ref(&self) -> ExternalRef {
        ExternalRef {
            source: self.source.clone(), external_id: self.source_id.clone(),
            url: self.field(UserField::ProfileUrl).unwrap_or("").to_string(),
        }
    }
}

impl Storage {
    fn now() -> String { crate::timefmt::now_utc_datetime() }

    // -------------------------------------------------------------------
    // Sightings
    // -------------------------------------------------------------------

    /// Record a sighting of a user (a comment author, a story's author, a
    /// profile header). Returns the users row id.
    pub fn record_user(&self, user: &AO3User) -> Result<i64, AppError> {
        let fields = |source: &str, name: &str| self.ensure_user_field(source, name);
        self.users_cache.record(&self.conn, user, &Self::now(), &fields).map(|e| e.id)
    }

    /// Record several sightings; ids in input order (a sighting with an
    /// empty key is skipped).
    pub fn record_users(&self, users: &[AO3User]) -> Result<Vec<i64>, AppError> {
        users.iter().filter(|u| !u.id.trim().is_empty()).map(|u| self.record_user(u)).collect()
    }

    /// Record AO3 author bylines seen on AO3 data (work blurbs, bookmarks,
    /// series pages): ensures each account row and learns any pseud.
    /// Returns the account row ids in byline order.
    pub fn record_author_bylines(&self, bylines: &[String]) -> Result<Vec<i64>, AppError> {
        let now = Self::now();
        let fields = |source: &str, name: &str| self.ensure_user_field(source, name);
        let mut ids = Vec::with_capacity(bylines.len());
        for b in bylines {
            if let Some(e) = self.users_cache.record_ao3_byline(&self.conn, b, &now, &fields)? {
                ids.push(e.id);
            }
        }
        Ok(ids)
    }

    // -------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------

    pub fn get_user(&self, id: i64) -> Option<UserRecord> {
        self.users_cache.get(id).map(|e| UserRecord::from_entity(&e))
    }

    pub fn get_user_by_key(&self, source: &str, source_id: &str) -> Option<UserRecord> {
        self.users_cache.get_sourced(source, source_id).map(|e| UserRecord::from_entity(&e))
    }

    /// Every users row (diagnostics and census-style passes).
    pub fn all_users(&self) -> Vec<UserRecord> {
        self.users_cache.all().iter().map(|e| UserRecord::from_entity(e)).collect()
    }

    /// The AO3 account for any AO3 name form (account username, byline,
    /// recorded pseud, guest id). AO3 names are unique within AO3.
    pub fn get_ao3_user_record(&self, name: &str) -> Option<UserRecord> {
        self.users_cache.resolve_ao3(name).map(|e| UserRecord::from_entity(&e))
    }

    /// The AO3 users row id for a name the library already knows.
    pub fn ao3_user_row_id(&self, name: &str) -> Option<i64> {
        self.users_cache.resolve_ao3(name).map(|e| e.id)
    }

    /// The AO3 users row id for any name form, creating the account row
    /// when never seen. Follows and crawl stamps point at this.
    pub fn ensure_ao3_user_row(&self, name: &str) -> Result<Option<i64>, AppError> {
        let fields = |source: &str, name: &str| self.ensure_user_field(source, name);
        Ok(self.users_cache.record_ao3_byline(&self.conn, name, &Self::now(), &fields)?.map(|e| e.id))
    }

    /// The display name behind a users row id.
    pub fn user_name_for_row(&self, id: i64) -> Option<String> {
        self.users_cache.get(id).map(|e| e.username.clone())
    }

    /// Whether the library knows an AO3 account by this name.
    pub fn has_ao3_user_with_username(&self, username: &str) -> Result<bool, AppError> {
        Ok(self.users_cache.resolve_ao3(username).is_some())
    }

    /// The AO3 account as a sighting (byline-compatible) for any AO3 name.
    pub fn get_ao3_user(&self, name: &str) -> Result<Option<AO3User>, AppError> {
        Ok(self.users_cache.resolve_ao3(name).map(|e| e.to_ao3_user()))
    }

    /// Library-scope AO3 user search over usernames and pseuds. Prefix
    /// matches rank first; `limit` of 0 means no limit.
    pub fn search_ao3_usernames(&self, term: &str, limit: u32) -> Result<Vec<String>, AppError> {
        let limit = if limit == 0 { usize::MAX } else { limit as usize };
        Ok(self.users_cache.search_ao3_usernames(term, limit))
    }

    /// An avatar URL already recorded for an AO3 name — saves the
    /// profile-page request entirely.
    pub fn get_known_avatar_url(&self, username: &str) -> Result<Option<String>, AppError> {
        Ok(self.users_cache.resolve_ao3(username)
            .and_then(|e| e.field(UserField::AvatarUrl).map(str::to_string)))
    }

    // -------------------------------------------------------------------
    // Properties and profiles
    // -------------------------------------------------------------------

    /// Set (or, with an empty value, remove) properties on a users row.
    pub fn set_user_properties(&self, id: i64, props: &[(String, String)]) -> Result<(), AppError> {
        let fields = |source: &str, name: &str| self.ensure_user_field(source, name);
        self.users_cache.set_props(&self.conn, id, props, &Self::now(), &fields)
    }

    /// Persist a fetched profile onto the user's row (created when never
    /// seen). Returns the row id.
    pub fn upsert_user_profile(&self, p: &SourceUserProfile) -> Result<i64, AppError> {
        let fields = |source: &str, name: &str| self.ensure_user_field(source, name);
        self.users_cache.update_profile(&self.conn, &p.source, &p.source_id, &p.username,
                                        &p.properties, &Self::now(), &fields).map(|e| e.id)
    }

    /// Record block state locally (mirrors an AO3-side change). Creates
    /// the account row when needed so state is never dropped.
    pub fn set_user_block_state(&self, username: &str, blocked: bool, ao3_id: Option<&str>) -> Result<(), AppError> {
        self.set_ao3_moderation(username, "blocked", user_fields::AO3_BLOCK_RECORD, blocked, ao3_id)
    }

    /// Record mute state locally (mirrors an AO3-side change).
    pub fn set_user_mute_state(&self, username: &str, muted: bool, ao3_id: Option<&str>) -> Result<(), AppError> {
        self.set_ao3_moderation(username, "muted", user_fields::AO3_MUTE_RECORD, muted, ao3_id)
    }

    fn set_ao3_moderation(&self, username: &str, flag: &str, record: &str, on: bool, ao3_id: Option<&str>)
        -> Result<(), AppError>
    {
        let account = split_author_byline(username).0;
        let Some(id) = self.ensure_ao3_user_row(&account)? else { return Ok(()) };
        self.set_user_properties(id, &[
            (flag.to_string(), if on { "1".to_string() } else { String::new() }),
            (record.to_string(), ao3_id.unwrap_or("").to_string()),
        ])
    }

    // -------------------------------------------------------------------
    // Authorship
    // -------------------------------------------------------------------

    /// Point a work at its authors' user rows, in byline order. Replaces
    /// the work's existing links; unchanged links keep their timestamps.
    pub fn link_work_authors(&self, work_id: u64, user_ids: &[i64]) -> Result<(), AppError> {
        self.link_authors("work_authors", "work_id", work_id as i64, user_ids)?;
        self.works_cache.set_author_ids(work_id, user_ids);
        Ok(())
    }

    pub fn link_series_authors(&self, series_id: u64, user_ids: &[i64]) -> Result<(), AppError> {
        self.link_authors("series_authors", "series_id", series_id as i64, user_ids)
    }

    fn link_authors(&self, table: &str, owner_col: &str, owner: i64, user_ids: &[i64]) -> Result<(), AppError> {
        let now = Self::now();
        let keep: Vec<String> = user_ids.iter().map(|id| id.to_string()).collect();
        let delete = if keep.is_empty() {
            format!("DELETE FROM {table} WHERE {owner_col} = ?1")
        } else {
            format!("DELETE FROM {table} WHERE {owner_col} = ?1 AND user_id NOT IN ({})", keep.join(","))
        };
        self.conn.execute(&delete, params![owner]).map_err(map_sql)?;
        let mut stmt = self.conn.prepare_cached(&format!(
            "INSERT INTO {table} ({owner_col}, user_id, position, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?4)
             ON CONFLICT({owner_col}, user_id) DO UPDATE SET
                position = excluded.position,
                updated_at = CASE WHEN {table}.position = excluded.position THEN {table}.updated_at ELSE excluded.updated_at END"
        )).map_err(map_sql)?;
        for (i, id) in user_ids.iter().enumerate() {
            stmt.execute(params![owner, id, i as i64, now]).map_err(map_sql)?;
        }
        Ok(())
    }

    /// A work's author user ids in byline position order.
    pub fn work_author_ids(&self, work_id: u64) -> Vec<i64> {
        self.author_ids("work_authors", "work_id", work_id as i64)
    }

    pub fn series_author_ids(&self, series_id: u64) -> Vec<i64> {
        self.author_ids("series_authors", "series_id", series_id as i64)
    }

    fn author_ids(&self, table: &str, owner_col: &str, owner: i64) -> Vec<i64> {
        let Ok(mut stmt) = self.conn.prepare_cached(&format!(
            "SELECT user_id FROM {table} WHERE {owner_col} = ?1 ORDER BY position, id")) else { return Vec::new() };
        stmt.query_map(params![owner], |r| r.get::<_, i64>(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    /// Row ids of the works linked to a user, newest update first.
    pub fn work_ids_by_user(&self, user_id: i64) -> Vec<u64> {
        let Ok(mut stmt) = self.conn.prepare_cached(
            "SELECT wa.work_id FROM work_authors wa JOIN works w ON w.id = wa.work_id
             WHERE wa.user_id = ?1 AND w.stub = 0 ORDER BY w.date_updated DESC") else { return Vec::new() };
        stmt.query_map(params![user_id], |r| r.get::<_, i64>(0))
            .map(|rows| rows.filter_map(Result::ok).map(|i| i as u64).collect())
            .unwrap_or_default()
    }

    /// Link an AO3 work's authors from its bylines (the account rows,
    /// created when never seen).
    pub(super) fn link_ao3_bylines(&self, work_id: u64, bylines: &[String]) -> Result<(), AppError> {
        let ids = self.record_author_bylines(bylines)?;
        self.link_work_authors(work_id, &ids)
    }
}
