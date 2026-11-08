use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{join_author_byline, split_author_byline, AO3User, SOURCE_AO3};
use crate::user_fields::{self, UserField};

use super::map_sql;

/// Prefix of the synthetic ids given to guest (logged-out) commenters —
/// they have no account at the source, so they never carry a profile.
pub(super) const GUEST_ID_PREFIX: &str = "guest:";

/// One stored property: the source's own name for it, its text value,
/// the registry row it was filed under, and when it was first and last
/// written (a write with the same value leaves `updated_at` alone).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct PropValue {
    pub field_id: i64,
    pub value: String,
    pub created_at: String,
    pub updated_at: String,
}

/// One person at one source — the single `users` row for them. `id` is
/// the row id; `source_id` is their key at the source (AO3 username,
/// `guest:<hash>`, ScribbleHub profile id). Everything else a source
/// says about them lives in `props`, under the source's own names
/// (`user_fields` maps those onto the app's vocabulary).
#[derive(Clone, Debug)]
pub(super) struct UserEntity {
    pub id: i64,
    pub source: String,
    pub source_id: String,
    pub username: String,
    pub created_at: String,
    pub updated_at: String,
    pub props: BTreeMap<String, PropValue>,
}

impl UserEntity {
    fn blank(source: &str, source_id: &str, username: &str, now: &str) -> UserEntity {
        UserEntity {
            id: 0, source: source.to_string(), source_id: source_id.to_string(),
            username: username.to_string(), created_at: now.to_string(), updated_at: now.to_string(),
            props: BTreeMap::new(),
        }
    }

    pub(super) fn is_guest(&self) -> bool {
        self.source_id.starts_with(GUEST_ID_PREFIX)
    }

    pub(super) fn prop(&self, name: &str) -> Option<&str> {
        self.props.get(name).map(|p| p.value.as_str()).filter(|v| !v.is_empty())
    }

    /// The value of a global field, through the source's mapping.
    pub(super) fn field(&self, field: UserField) -> Option<&str> {
        user_fields::native_name(&self.source, field).and_then(|n| self.prop(n))
    }

    /// AO3 pseuds (the `pseuds` property, a JSON array); empty elsewhere.
    pub(super) fn pseuds(&self) -> Vec<String> {
        self.field(UserField::Pseuds)
            .and_then(|j| serde_json::from_str(j).ok())
            .unwrap_or_default()
    }

    pub(super) fn to_ao3_user(&self) -> AO3User {
        AO3User {
            source: self.source.clone(),
            id: self.source_id.clone(),
            username: self.username.clone(),
            profile_url: self.field(UserField::ProfileUrl).map(str::to_string),
            avatar_url: self.field(UserField::AvatarUrl).map(str::to_string),
        }
    }
}

fn key_of(name: &str) -> String {
    name.trim().to_ascii_lowercase()
}

/// The index key of a (source, source id) pair. Case-insensitive on the
/// id, like the table's NOCASE collation.
fn account_key(source: &str, source_id: &str) -> String {
    format!("{}:{}", source, key_of(source_id))
}

/// Views of one entity set: by row id, by (source, source id), and — for
/// AO3 only, whose account names are unique within the source — by each
/// recorded pseud → account key. Lookups try the account key first, so a
/// pseud that happens to equal some other real username never shadows
/// that user. There is no cross-source name index: a display name is not
/// an identity.
#[derive(Default)]
struct Indexes {
    by_id: HashMap<i64, Arc<UserEntity>>,
    by_key: HashMap<String, Arc<UserEntity>>,
    ao3_by_pseud: HashMap<String, String>,
}

impl Indexes {
    fn insert(&mut self, entity: UserEntity) -> Arc<UserEntity> {
        let entity = Arc::new(entity);
        let key = account_key(&entity.source, &entity.source_id);
        if let Some(old) = self.by_key.insert(key.clone(), Arc::clone(&entity)) {
            for p in old.pseuds() {
                if self.ao3_by_pseud.get(&key_of(&p)) == Some(&key) {
                    self.ao3_by_pseud.remove(&key_of(&p));
                }
            }
        }
        self.by_id.insert(entity.id, Arc::clone(&entity));
        if entity.source == SOURCE_AO3 {
            for p in entity.pseuds() {
                self.ao3_by_pseud.insert(key_of(&p), key.clone());
            }
        }
        entity
    }

    fn get(&self, source: &str, source_id: &str) -> Option<Arc<UserEntity>> {
        self.by_key.get(&account_key(source, source_id)).cloned()
    }

    /// An AO3 account by any AO3 name form: account username, "Pseud
    /// (account)" byline, bare recorded pseud, or guest id.
    fn resolve_ao3(&self, name: &str) -> Option<Arc<UserEntity>> {
        let (account, _) = split_author_byline(name);
        if let Some(e) = self.get(SOURCE_AO3, &account) {
            return Some(e);
        }
        self.ao3_by_pseud.get(&key_of(&account)).and_then(|k| self.by_key.get(k)).cloned()
    }
}

/// The `users` + `user_source_properties` tables' in-memory mirror and
/// single write authority — same contract as the other storage caches.
/// Every read of user data is answered here, keyed by row id or by
/// (source, source id) (plus AO3 pseuds); every write mutates the cache
/// and then writes the rows through, stamping created_at/updated_at.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct UsersCache {
    inner: RefCell<Indexes>,
}

/// How the cache files a property under the registry: the caller (Storage)
/// owns the fields cache, so it lends the lookup.
pub(super) type FieldResolver<'a> = &'a dyn Fn(&str, &str) -> Result<i64, AppError>;

impl UsersCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut entities: HashMap<i64, UserEntity> = HashMap::new();
        {
            let mut stmt = conn
                .prepare("SELECT id, source, source_id, username, created_at, updated_at FROM users")
                .map_err(map_sql)?;
            let rows = stmt.query_map([], |r| Ok(UserEntity {
                id: r.get(0)?, source: r.get(1)?, source_id: r.get(2)?, username: r.get(3)?,
                created_at: r.get(4)?, updated_at: r.get(5)?, props: BTreeMap::new(),
            })).map_err(map_sql)?;
            for row in rows {
                let e = row.map_err(map_sql)?;
                entities.insert(e.id, e);
            }
        }
        {
            let mut stmt = conn
                .prepare("SELECT user_id, field_id, property_name, property_value, created_at, updated_at
                          FROM user_source_properties")
                .map_err(map_sql)?;
            let rows = stmt.query_map([], |r| Ok((
                r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?,
                r.get::<_, String>(3)?, r.get::<_, String>(4)?, r.get::<_, String>(5)?,
            ))).map_err(map_sql)?;
            for row in rows {
                let (user_id, field_id, name, value, created_at, updated_at) = row.map_err(map_sql)?;
                if let Some(e) = entities.get_mut(&user_id) {
                    e.props.insert(name, PropValue { field_id, value, created_at, updated_at });
                }
            }
        }
        let mut inner = self.inner.borrow_mut();
        inner.by_id.clear();
        inner.by_key.clear();
        inner.ao3_by_pseud.clear();
        for (_, e) in entities {
            inner.insert(e);
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------

    pub(super) fn get(&self, id: i64) -> Option<Arc<UserEntity>> {
        self.inner.borrow().by_id.get(&id).cloned()
    }

    pub(super) fn get_sourced(&self, source: &str, source_id: &str) -> Option<Arc<UserEntity>> {
        self.inner.borrow().get(source, source_id)
    }

    /// An AO3 account for any AO3 name form (account username NOCASE,
    /// "Pseud (account)" byline, bare recorded pseud, guest id).
    pub(super) fn resolve_ao3(&self, name: &str) -> Option<Arc<UserEntity>> {
        self.inner.borrow().resolve_ao3(name)
    }

    pub(super) fn all(&self) -> Vec<Arc<UserEntity>> {
        self.inner.borrow().by_id.values().cloned().collect()
    }

    /// AO3 username substring search (ASCII-ci) over account usernames and
    /// their pseuds; returns account usernames, prefix matches first, then
    /// NOCASE order. Guests never match.
    pub(super) fn search_ao3_usernames(&self, term: &str, limit: usize) -> Vec<String> {
        let needle = term.trim().to_ascii_lowercase();
        if needle.is_empty() {
            return Vec::new();
        }
        let inner = self.inner.borrow();
        let hit = |e: &UserEntity| {
            e.username.to_ascii_lowercase().contains(&needle)
                || e.pseuds().iter().any(|p| p.to_ascii_lowercase().contains(&needle))
        };
        let prefix = |e: &UserEntity| {
            e.username.to_ascii_lowercase().starts_with(&needle)
                || e.pseuds().iter().any(|p| p.to_ascii_lowercase().starts_with(&needle))
        };
        let mut hits: Vec<&Arc<UserEntity>> = inner
            .by_key
            .values()
            .filter(|e| e.source == SOURCE_AO3 && !e.is_guest() && hit(e))
            .collect();
        hits.sort_by(|a, b| {
            prefix(b).cmp(&prefix(a))
                .then_with(|| a.username.to_ascii_lowercase().cmp(&b.username.to_ascii_lowercase()))
                .then_with(|| a.username.cmp(&b.username))
        });
        let mut out: Vec<String> = hits.into_iter().map(|e| e.username.clone()).collect();
        out.truncate(limit);
        out
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Write the identity row: the cache entity is the truth, the table
    /// mirrors it. ON CONFLICT DO UPDATE (not OR REPLACE) so the foreign
    /// keys into users(id) are never broken by a delete+insert. Fills in
    /// `e.id` for a new row.
    fn persist_identity(conn: &Connection, e: &mut UserEntity) -> Result<(), AppError> {
        conn.prepare_cached(
                "INSERT INTO users (source, source_id, username, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(source, source_id) DO UPDATE SET
                    username = excluded.username, updated_at = excluded.updated_at")
            .map_err(map_sql)?
            .execute(params![e.source, e.source_id, e.username, e.created_at, e.updated_at])
            .map_err(map_sql)?;
        if e.id == 0 {
            e.id = conn.query_row(
                "SELECT id FROM users WHERE source = ?1 AND source_id = ?2",
                params![e.source, e.source_id], |r| r.get(0),
            ).map_err(map_sql)?;
        }
        Ok(())
    }

    fn persist_prop(conn: &Connection, user_id: i64, name: &str, p: &PropValue) -> Result<(), AppError> {
        conn.prepare_cached(
                "INSERT INTO user_source_properties
                    (user_id, field_id, property_name, property_value, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(user_id, field_id) DO UPDATE SET
                    property_name = excluded.property_name, property_value = excluded.property_value,
                    updated_at = excluded.updated_at")
            .map_err(map_sql)?
            .execute(params![user_id, p.field_id, name, p.value, p.created_at, p.updated_at])
            .map_err(map_sql)?;
        Ok(())
    }

    /// The row for (source, source id), created blank when never seen.
    /// `username` names a new row; an existing row adopts a non-empty
    /// `username` (the source's current rendering of the name).
    fn ensure(&self, conn: &Connection, source: &str, source_id: &str, username: &str, now: &str)
        -> Result<UserEntity, AppError>
    {
        let existing = self.inner.borrow().get(source, source_id);
        let mut e = match existing {
            Some(existing) => (*existing).clone(),
            None => UserEntity::blank(source, source_id, username, now),
        };
        let name = username.trim();
        if !name.is_empty() && e.username != name {
            e.username = name.to_string();
            e.updated_at = now.to_string();
        }
        if e.id == 0 || e.updated_at == now {
            Self::persist_identity(conn, &mut e)?;
        }
        Ok(e)
    }

    /// Set properties on an entity (in memory and in the table). A value
    /// equal to the stored one is not rewritten; an empty value removes
    /// the property. Returns whether anything changed.
    fn apply_props(&self, conn: &Connection, e: &mut UserEntity, props: &[(String, String)],
                   now: &str, fields: FieldResolver) -> Result<bool, AppError> {
        let mut changed = false;
        for (name, value) in props {
            let name = name.trim();
            if name.is_empty() { continue }
            if value.is_empty() {
                if e.props.remove(name).is_some() {
                    conn.execute(
                        "DELETE FROM user_source_properties WHERE user_id = ?1 AND property_name = ?2",
                        params![e.id, name],
                    ).map_err(map_sql)?;
                    changed = true;
                }
                continue;
            }
            match e.props.get_mut(name) {
                Some(p) if p.value == *value => {}
                Some(p) => {
                    p.value = value.clone();
                    p.updated_at = now.to_string();
                    let p = p.clone();
                    Self::persist_prop(conn, e.id, name, &p)?;
                    changed = true;
                }
                None => {
                    let field_id = fields(&e.source, name)?;
                    let p = PropValue { field_id, value: value.clone(), created_at: now.to_string(), updated_at: now.to_string() };
                    Self::persist_prop(conn, e.id, name, &p)?;
                    e.props.insert(name.to_string(), p);
                    changed = true;
                }
            }
        }
        Ok(changed)
    }

    /// Record a sighting of a user at a source (comment author, story
    /// author, profile header). For AO3, `user.username` may be a
    /// "Pseud (account)" byline: the account is the row, the pseud is
    /// learned. Profile and avatar URLs are kept when present; blank
    /// incoming values never wipe known ones.
    pub(super) fn record(&self, conn: &Connection, user: &AO3User, now: &str, fields: FieldResolver)
        -> Result<Arc<UserEntity>, AppError>
    {
        let (source_id, username, pseud) = if user.source == SOURCE_AO3 && !user.id.starts_with(GUEST_ID_PREFIX) {
            // Registered AO3 users key by account; the byline carries the
            // pseud. `id` is only a fallback for callers without a name.
            let name = if user.username.trim().is_empty() { user.id.as_str() } else { user.username.as_str() };
            let (account, pseud) = split_author_byline(name);
            (account.clone(), account, pseud)
        } else {
            (user.id.clone(), user.username.clone(), None)
        };
        let mut e = self.ensure(conn, &user.source, &source_id, &username, now)?;
        let mut props: Vec<(String, String)> = Vec::new();
        if let Some(url) = user.profile_url.as_deref().filter(|u| !u.is_empty()) {
            if let Some(n) = user_fields::native_name(&e.source, UserField::ProfileUrl) {
                props.push((n.to_string(), url.to_string()));
            }
        } else if e.source == SOURCE_AO3 && !e.is_guest() && e.field(UserField::ProfileUrl).is_none() {
            props.push(("profile_url".to_string(), crate::parser::ao3_user_url(&e.source_id)));
        }
        if let Some(url) = user.avatar_url.as_deref().filter(|u| !u.is_empty()) {
            if let Some(n) = user_fields::native_name(&e.source, UserField::AvatarUrl) {
                props.push((n.to_string(), url.to_string()));
            }
        }
        if let Some(p) = pseud.as_deref() {
            let mut list = e.pseuds();
            if !list.iter().any(|q| q.eq_ignore_ascii_case(p)) {
                list.push(p.to_string());
                props.push(("pseuds".to_string(), serde_json::to_string(&list).unwrap_or_else(|_| "[]".into())));
            }
        }
        self.apply_props(conn, &mut e, &props, now, fields)?;
        Ok(self.inner.borrow_mut().insert(e))
    }

    /// Record an AO3 author byline (a work blurb, a bookmark, a series
    /// page): ensures the account row and learns the pseud. Cheap when
    /// nothing is new — one map lookup, no SQL.
    pub(super) fn record_ao3_byline(&self, conn: &Connection, byline: &str, now: &str, fields: FieldResolver)
        -> Result<Option<Arc<UserEntity>>, AppError>
    {
        let (account, pseud) = split_author_byline(byline);
        if account.is_empty() {
            return Ok(None);
        }
        if let Some(e) = self.inner.borrow().get(SOURCE_AO3, &account) {
            let known = match pseud.as_deref() {
                Some(p) => e.pseuds().iter().any(|q| q.eq_ignore_ascii_case(p)),
                None => true,
            };
            if known {
                return Ok(Some(e));
            }
        }
        let sighting = AO3User::ao3(&account, byline, None, None);
        self.record(conn, &sighting, now, fields).map(Some)
    }

    /// Set properties on a user row by id.
    pub(super) fn set_props(&self, conn: &Connection, id: i64, props: &[(String, String)], now: &str,
                            fields: FieldResolver) -> Result<(), AppError> {
        let Some(existing) = self.get(id) else {
            return Err(AppError::StorageError(format!("no users row {id}")));
        };
        let mut e = (*existing).clone();
        if self.apply_props(conn, &mut e, props, now, fields)? {
            self.inner.borrow_mut().insert(e);
        }
        Ok(())
    }

    /// Persist a fetched profile: identity (the source's current name
    /// rendering) plus every property the page showed. AO3's pseud list
    /// is merged with pseuds learned from sightings, never dropped.
    pub(super) fn update_profile(&self, conn: &Connection, source: &str, source_id: &str, username: &str,
                                 properties: &[(String, String)], now: &str, fields: FieldResolver)
        -> Result<Arc<UserEntity>, AppError>
    {
        let mut e = self.ensure(conn, source, source_id, username, now)?;
        let mut props: Vec<(String, String)> = properties.to_vec();
        if source == SOURCE_AO3 {
            if let Some(i) = props.iter().position(|(n, _)| n == "pseuds") {
                let incoming: Vec<String> = serde_json::from_str(&props[i].1).unwrap_or_default();
                let mut merged: Vec<String> = Vec::new();
                for q in incoming.iter().chain(e.pseuds().iter()) {
                    if !q.trim().is_empty() && !merged.iter().any(|m| m.eq_ignore_ascii_case(q)) {
                        merged.push(q.clone());
                    }
                }
                props[i].1 = serde_json::to_string(&merged).unwrap_or_else(|_| "[]".into());
            }
            if e.field(UserField::ProfileUrl).is_none() && !props.iter().any(|(n, _)| n == "profile_url") {
                props.push(("profile_url".to_string(), crate::parser::ao3_user_url(&e.source_id)));
            }
        }
        props.push((user_fields::PROFILE_FETCHED_AT.to_string(), now.to_string()));
        self.apply_props(conn, &mut e, &props, now, fields)?;
        Ok(self.inner.borrow_mut().insert(e))
    }
}

/// The byline to display for a comment posted from `pseud` of `account`.
pub(super) fn comment_byline(account: &str, pseud: &str) -> String {
    join_author_byline(account, if pseud.is_empty() { None } else { Some(pseud) })
}
