use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{join_author_byline, split_author_byline, AO3User, UserProfile};

use super::{map_json, map_sql};

/// Prefix of the synthetic ids given to guest (logged-out) commenters —
/// they have no AO3 account, so they never carry pseuds or a profile.
pub(super) const GUEST_ID_PREFIX: &str = "guest:";

/// One AO3 account as the app knows it — the single ao3_users row for
/// that account. `id` is the account key: the AO3 username for registered
/// users (or `guest:<hash>` for guest commenters). A pseud is a detail of
/// the account, never its own row: every pseud seen attached to the
/// account lives in `pseuds_json`, and the cache indexes the row under
/// each of them.
#[derive(Clone, Debug)]
pub(super) struct UserEntity {
    pub id: String,
    pub username: String,
    pub profile_url: String,
    pub avatar_url: String,
    pub updated_at: String,
    pub numeric_id: String,
    pub joined: String,
    pub location: String,
    pub birthday: String,
    pub pseuds_json: String,
    pub bio_json: String,
    pub works_count: i64,
    pub series_count: i64,
    pub bookmarks_count: i64,
    pub collections_count: i64,
    pub gifts_count: i64,
    pub is_blocked: bool,
    pub block_ao3_id: String,
    pub is_muted: bool,
    pub mute_ao3_id: String,
    pub profile_fetched_at: String,
}

impl UserEntity {
    fn blank(id: &str, username: &str) -> UserEntity {
        UserEntity {
            id: id.to_string(), username: username.to_string(),
            profile_url: String::new(), avatar_url: String::new(), updated_at: String::new(),
            numeric_id: String::new(), joined: String::new(), location: String::new(),
            birthday: String::new(), pseuds_json: "[]".into(), bio_json: "[]".into(),
            works_count: 0, series_count: 0, bookmarks_count: 0,
            collections_count: 0, gifts_count: 0,
            is_blocked: false, block_ao3_id: String::new(),
            is_muted: false, mute_ao3_id: String::new(),
            profile_fetched_at: String::new(),
        }
    }

    pub(super) fn is_guest(&self) -> bool {
        self.id.starts_with(GUEST_ID_PREFIX)
    }

    pub(super) fn pseuds(&self) -> Vec<String> {
        serde_json::from_str(&self.pseuds_json).unwrap_or_default()
    }

    /// Add a pseud to the list (ASCII-case-insensitive dedupe). Returns
    /// whether the list changed.
    fn add_pseud(&mut self, pseud: &str) -> bool {
        let pseud = pseud.trim();
        if pseud.is_empty() {
            return false;
        }
        let mut list = self.pseuds();
        if list.iter().any(|p| p.eq_ignore_ascii_case(pseud)) {
            return false;
        }
        list.push(pseud.to_string());
        self.pseuds_json = serde_json::to_string(&list).unwrap_or_else(|_| "[]".into());
        true
    }

    pub(super) fn to_ao3_user(&self) -> AO3User {
        let opt = |s: &str| if s.is_empty() { None } else { Some(s.to_string()) };
        AO3User {
            id: self.id.clone(),
            username: self.username.clone(),
            profile_url: opt(&self.profile_url),
            avatar_url: opt(&self.avatar_url),
        }
    }

    /// The row as a `UserProfile` (subscription state is joined in by the
    /// caller — it lives in the subscriptions table, not here).
    pub(super) fn to_profile(&self) -> UserProfile {
        let opt = |s: &str| if s.is_empty() { None } else { Some(s.to_string()) };
        UserProfile {
            username: self.username.clone(),
            numeric_id: opt(&self.numeric_id),
            avatar_url: opt(&self.avatar_url),
            pseuds: self.pseuds(),
            joined: self.joined.clone(),
            location: self.location.clone(),
            birthday: self.birthday.clone(),
            bio: serde_json::from_str(&self.bio_json).unwrap_or_default(),
            works_count: self.works_count as u32,
            series_count: self.series_count as u32,
            bookmarks_count: self.bookmarks_count as u32,
            collections_count: self.collections_count as u32,
            gifts_count: self.gifts_count as u32,
            blocked: self.is_blocked,
            block_ao3_id: opt(&self.block_ao3_id),
            muted: self.is_muted,
            mute_ao3_id: opt(&self.mute_ao3_id),
            viewer_signed_in: false,
            subscribed: false,
            subscription_ao3_id: None,
            fetched_at: self.profile_fetched_at.clone(),
        }
    }
}

fn key_of(name: &str) -> String {
    name.trim().to_ascii_lowercase()
}

/// Two views of one entity set: by account key (ASCII-lowercased, SQLite's
/// NOCASE), and by each recorded pseud → account key. Lookups try the
/// account key first, so a pseud that happens to equal some other real
/// username never shadows that user.
#[derive(Default)]
struct Indexes {
    by_key: HashMap<String, Arc<UserEntity>>,
    by_pseud: HashMap<String, String>,
}

impl Indexes {
    fn insert(&mut self, entity: UserEntity) -> Arc<UserEntity> {
        let entity = Arc::new(entity);
        let key = key_of(&entity.id);
        if let Some(old) = self.by_key.insert(key.clone(), Arc::clone(&entity)) {
            for p in old.pseuds() {
                if self.by_pseud.get(&key_of(&p)) == Some(&key) {
                    self.by_pseud.remove(&key_of(&p));
                }
            }
        }
        for p in entity.pseuds() {
            self.by_pseud.insert(key_of(&p), key.clone());
        }
        entity
    }

    /// Resolve any name form — account username, "Pseud (account)" byline,
    /// bare pseud, or guest id — to its account entity.
    fn resolve(&self, name: &str) -> Option<Arc<UserEntity>> {
        let (account, _) = split_author_byline(name);
        let key = key_of(&account);
        if let Some(e) = self.by_key.get(&key) {
            return Some(Arc::clone(e));
        }
        self.by_pseud.get(&key).and_then(|k| self.by_key.get(k)).cloned()
    }
}

/// The ao3_users table's in-memory mirror and single write authority —
/// same contract as the other storage caches. Every read of author /
/// AO3-user data is answered here, keyed by account username or by any
/// of the account's pseuds; every write mutates the cache and then
/// writes the row through.
///
/// Exceptions to the invariant, both safe by ordering:
/// - schema migrations (version-frozen inline SQL) run before `load`
/// - `Storage::with_savepoint` / `TxGuard` reload after a rollback
#[derive(Default)]
pub(super) struct UsersCache {
    inner: RefCell<Indexes>,
}

impl UsersCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare(
                "SELECT id, username, profile_url, avatar_url, updated_at,
                        numeric_id, joined, location, birthday, pseuds_json, bio_json,
                        works_count, series_count, bookmarks_count, collections_count,
                        gifts_count, is_blocked, block_ao3_id, is_muted, mute_ao3_id,
                        profile_fetched_at
                 FROM ao3_users",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(UserEntity {
                    id: r.get(0)?,
                    username: r.get(1)?,
                    profile_url: r.get(2)?,
                    avatar_url: r.get(3)?,
                    updated_at: r.get(4)?,
                    numeric_id: r.get(5)?,
                    joined: r.get(6)?,
                    location: r.get(7)?,
                    birthday: r.get(8)?,
                    pseuds_json: r.get(9)?,
                    bio_json: r.get(10)?,
                    works_count: r.get(11)?,
                    series_count: r.get(12)?,
                    bookmarks_count: r.get(13)?,
                    collections_count: r.get(14)?,
                    gifts_count: r.get(15)?,
                    is_blocked: r.get::<_, i64>(16)? != 0,
                    block_ao3_id: r.get(17)?,
                    is_muted: r.get::<_, i64>(18)? != 0,
                    mute_ao3_id: r.get(19)?,
                    profile_fetched_at: r.get(20)?,
                })
            })
            .map_err(map_sql)?;
        let mut inner = self.inner.borrow_mut();
        inner.by_key.clear();
        inner.by_pseud.clear();
        for row in rows {
            inner.insert(row.map_err(map_sql)?);
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------

    /// The account entity for any name form: account username (NOCASE),
    /// "Pseud (account)" byline, a bare recorded pseud, or a guest id.
    pub(super) fn resolve(&self, name: &str) -> Option<Arc<UserEntity>> {
        self.inner.borrow().resolve(name)
    }

    pub(super) fn has_user(&self, name: &str) -> bool {
        self.resolve(name).is_some()
    }

    /// An avatar URL already harvested for the account.
    pub(super) fn known_avatar_url(&self, name: &str) -> Option<String> {
        self.resolve(name)
            .filter(|e| !e.avatar_url.is_empty())
            .map(|e| e.avatar_url.clone())
    }

    /// Username substring search (ASCII-ci, like the SQL LIKE it replaces)
    /// over account usernames and their pseuds; returns account usernames,
    /// prefix matches first, then NOCASE order. Guests are not AO3 users
    /// and never match.
    pub(super) fn search_usernames(&self, term: &str, limit: usize) -> Vec<String> {
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
            .filter(|e| !e.is_guest() && hit(e))
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

    /// Write the whole row: the cache entity is the truth, the table
    /// mirrors it. ON CONFLICT DO UPDATE (not OR REPLACE) so the comments
    /// foreign key into ao3_users(id) is never broken by a delete+insert.
    fn persist(conn: &Connection, e: &UserEntity) -> Result<(), AppError> {
        conn.prepare_cached(
                "INSERT INTO ao3_users (id, username, profile_url, avatar_url, updated_at,
                        numeric_id, joined, location, birthday, pseuds_json, bio_json,
                        works_count, series_count, bookmarks_count, collections_count,
                        gifts_count, is_blocked, block_ao3_id, is_muted, mute_ao3_id,
                        profile_fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                         ?16, ?17, ?18, ?19, ?20, ?21)
                 ON CONFLICT(id) DO UPDATE SET
                    username = excluded.username, profile_url = excluded.profile_url,
                    avatar_url = excluded.avatar_url, updated_at = excluded.updated_at,
                    numeric_id = excluded.numeric_id, joined = excluded.joined,
                    location = excluded.location, birthday = excluded.birthday,
                    pseuds_json = excluded.pseuds_json, bio_json = excluded.bio_json,
                    works_count = excluded.works_count, series_count = excluded.series_count,
                    bookmarks_count = excluded.bookmarks_count,
                    collections_count = excluded.collections_count,
                    gifts_count = excluded.gifts_count,
                    is_blocked = excluded.is_blocked, block_ao3_id = excluded.block_ao3_id,
                    is_muted = excluded.is_muted, mute_ao3_id = excluded.mute_ao3_id,
                    profile_fetched_at = excluded.profile_fetched_at")
            .map_err(map_sql)?
            .execute(params![
                e.id, e.username, e.profile_url, e.avatar_url, e.updated_at,
                e.numeric_id, e.joined, e.location, e.birthday, e.pseuds_json, e.bio_json,
                e.works_count, e.series_count, e.bookmarks_count, e.collections_count,
                e.gifts_count, e.is_blocked as i64, e.block_ao3_id,
                e.is_muted as i64, e.mute_ao3_id, e.profile_fetched_at,
            ])
            .map_err(map_sql)?;
        Ok(())
    }

    /// Mutate the account row keyed by `name`'s account (creating a blank
    /// one when the account has never been seen), then write it through.
    /// Keying is strict — the account name, or the account half of a
    /// "Pseud (account)" byline — never a pseud alias, so a sighting of a
    /// real account that shares a name with someone's pseud creates that
    /// account instead of mutating the other user. The byline's pseud is
    /// recorded as a side effect. Returns the stored entity.
    fn mutate(&self, conn: &Connection, name: &str, now: &str,
              f: impl FnOnce(&mut UserEntity)) -> Result<Arc<UserEntity>, AppError> {
        let (account, pseud) = split_author_byline(name);
        let existing = self.inner.borrow().by_key.get(&key_of(&account)).cloned();
        let mut e = match existing {
            Some(existing) => (*existing).clone(),
            None => {
                let mut e = UserEntity::blank(&account, &account);
                if !account.starts_with(GUEST_ID_PREFIX) {
                    e.profile_url = format!("{}/users/{account}", crate::client::BASE_URL);
                }
                e
            }
        };
        if let Some(p) = pseud.as_deref() {
            e.add_pseud(p);
        }
        f(&mut e);
        e.updated_at = now.to_string();
        Self::persist(conn, &e)?;
        Ok(self.inner.borrow_mut().insert(e))
    }

    /// Record a sighting of a user (comment author, profile-page header,
    /// harvested avatar). `user.username` is the byline as AO3 rendered
    /// it — "Pseud (account)" teaches the account a pseud it didn't have.
    /// Guests (`guest:` ids) are stored as-is under their display name. A
    /// blank incoming avatar never wipes a harvested one.
    pub(super) fn record(&self, conn: &Connection, user: &AO3User, now: &str)
        -> Result<Arc<UserEntity>, AppError>
    {
        if user.id.starts_with(GUEST_ID_PREFIX) {
            return self.mutate(conn, &user.id, now, |e| {
                e.username = user.username.clone();
                if let Some(url) = user.profile_url.as_deref().filter(|u| !u.is_empty()) {
                    e.profile_url = url.to_string();
                }
                if let Some(url) = user.avatar_url.as_deref().filter(|u| !u.is_empty()) {
                    e.avatar_url = url.to_string();
                }
            });
        }
        // Registered users key by account; the byline carries the pseud.
        // `id` is only a fallback for callers that never had a display name.
        let name = if user.username.trim().is_empty() { user.id.as_str() } else { user.username.as_str() };
        let (account, _) = split_author_byline(name);
        self.mutate(conn, name, now, |e| {
            // Adopt AO3's casing of the account name from the sighting.
            e.username = account.clone();
            if let Some(url) = user.profile_url.as_deref().filter(|u| !u.is_empty()) {
                e.profile_url = url.to_string();
            }
            if let Some(url) = user.avatar_url.as_deref().filter(|u| !u.is_empty()) {
                e.avatar_url = url.to_string();
            }
        })
    }

    /// Record an author byline seen on AO3 data (a work blurb, a bookmark,
    /// a series page): ensures the account row and learns the pseud.
    /// Cheap when nothing is new — one map lookup, no SQL.
    pub(super) fn record_byline(&self, conn: &Connection, byline: &str, now: &str)
        -> Result<(), AppError>
    {
        let (account, pseud) = split_author_byline(byline);
        if account.is_empty() {
            return Ok(());
        }
        if let Some(e) = self.resolve(byline) {
            let known = match pseud.as_deref() {
                Some(p) => e.pseuds().iter().any(|q| q.eq_ignore_ascii_case(p)),
                None => true,
            };
            if known {
                return Ok(());
            }
        }
        self.mutate(conn, byline, now, |_| {}).map(|_| ())
    }

    /// Persist a fetched profile onto the account row. The profile page's
    /// pseud list is merged with any pseuds learned from sightings (never
    /// dropped); an empty incoming numeric_id keeps the stored one.
    pub(super) fn update_profile(&self, conn: &Connection, p: &UserProfile, now: &str)
        -> Result<(), AppError>
    {
        let bio_json = serde_json::to_string(&p.bio).map_err(map_json)?;
        let numeric_id = p.numeric_id.clone().unwrap_or_default();
        let (account, _) = split_author_byline(&p.username);
        self.mutate(conn, &p.username, now, |e| {
            e.username = account.clone();
            if e.profile_url.is_empty() {
                e.profile_url = format!("{}/users/{account}", crate::client::BASE_URL);
            }
            if let Some(url) = p.avatar_url.as_deref().filter(|u| !u.is_empty()) {
                e.avatar_url = url.to_string();
            }
            if !numeric_id.is_empty() {
                e.numeric_id = numeric_id.clone();
            }
            e.joined = p.joined.clone();
            e.location = p.location.clone();
            e.birthday = p.birthday.clone();
            // Profile order first, then sightings the page didn't list.
            let mut merged: Vec<String> = Vec::new();
            for q in p.pseuds.iter().chain(e.pseuds().iter()) {
                if !q.trim().is_empty() && !merged.iter().any(|m| m.eq_ignore_ascii_case(q)) {
                    merged.push(q.clone());
                }
            }
            e.pseuds_json = serde_json::to_string(&merged).unwrap_or_else(|_| "[]".into());
            e.bio_json = bio_json.clone();
            e.works_count = p.works_count as i64;
            e.series_count = p.series_count as i64;
            e.bookmarks_count = p.bookmarks_count as i64;
            e.collections_count = p.collections_count as i64;
            e.gifts_count = p.gifts_count as i64;
            e.is_blocked = p.blocked;
            e.block_ao3_id = p.block_ao3_id.clone().unwrap_or_default();
            e.is_muted = p.muted;
            e.mute_ao3_id = p.mute_ao3_id.clone().unwrap_or_default();
            e.profile_fetched_at = now.to_string();
        }).map(|_| ())
    }

    /// The account id behind any name form the UI may hand us (account,
    /// byline, or a recorded pseud); the name itself when unknown.
    fn account_for(&self, name: &str) -> String {
        self.resolve(name).map(|e| e.id.clone()).unwrap_or_else(|| name.to_string())
    }

    /// Record block state (mirrors an AO3-side change) on the account row.
    pub(super) fn set_block_state(&self, conn: &Connection, name: &str, blocked: bool,
                                  ao3_id: &str, now: &str) -> Result<(), AppError> {
        self.mutate(conn, &self.account_for(name), now, |e| {
            e.is_blocked = blocked;
            e.block_ao3_id = ao3_id.to_string();
        }).map(|_| ())
    }

    /// Record mute state (mirrors an AO3-side change) on the account row.
    pub(super) fn set_mute_state(&self, conn: &Connection, name: &str, muted: bool,
                                 ao3_id: &str, now: &str) -> Result<(), AppError> {
        self.mutate(conn, &self.account_for(name), now, |e| {
            e.is_muted = muted;
            e.mute_ao3_id = ao3_id.to_string();
        }).map(|_| ())
    }
}

/// The byline to display for a comment posted from `pseud` of `account`.
pub(super) fn comment_byline(account: &str, pseud: &str) -> String {
    join_author_byline(account, if pseud.is_empty() { None } else { Some(pseud) })
}
