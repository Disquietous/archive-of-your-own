use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;
use crate::models::{AO3User, UserProfile};

use super::{map_json, map_sql};

/// One cached row of the ao3_users table — every AO3 user the app has seen
/// (from works, comments, kudos, profiles), plus profile-page data once a
/// profile fetch has recorded it (`profile_fetched_at` non-empty).
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
            pseuds: serde_json::from_str(&self.pseuds_json).unwrap_or_default(),
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

/// Two views of one entity set: by row id, and by ASCII-lowercased username
/// (SQLite's NOCASE) — a username can map to several rows (different id
/// forms from different sources), so the name index holds a bucket.
#[derive(Default)]
struct Indexes {
    by_id: HashMap<String, Arc<UserEntity>>,
    by_username: HashMap<String, Vec<Arc<UserEntity>>>,
}

impl Indexes {
    fn insert(&mut self, entity: UserEntity) {
        let entity = Arc::new(entity);
        let username_key = entity.username.to_ascii_lowercase();
        if let Some(old) = self.by_id.insert(entity.id.clone(), Arc::clone(&entity)) {
            // Re-keying: drop the old entity from its (possibly different)
            // username bucket before adding the new one.
            let old_key = old.username.to_ascii_lowercase();
            if let Some(bucket) = self.by_username.get_mut(&old_key) {
                bucket.retain(|e| e.id != old.id);
                if bucket.is_empty() {
                    self.by_username.remove(&old_key);
                }
            }
        }
        self.by_username.entry(username_key).or_default().push(entity);
    }
}

/// The ao3_users table's in-memory mirror and single write authority —
/// same contract as the other storage caches.
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
        inner.by_id.clear();
        inner.by_username.clear();
        for row in rows {
            inner.insert(row.map_err(map_sql)?);
        }
        Ok(())
    }

    pub(super) fn get(&self, id: &str) -> Option<Arc<UserEntity>> {
        self.inner.borrow().by_id.get(id).cloned()
    }

    /// Rows for a username (SQLite-NOCASE = ASCII-case-insensitive),
    /// most recently updated first.
    pub(super) fn by_username(&self, username: &str) -> Vec<Arc<UserEntity>> {
        let mut rows = self
            .inner
            .borrow()
            .by_username
            .get(&username.to_ascii_lowercase())
            .cloned()
            .unwrap_or_default();
        rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then_with(|| a.id.cmp(&b.id)));
        rows
    }

    pub(super) fn has_username(&self, username: &str) -> bool {
        self.inner
            .borrow()
            .by_username
            .contains_key(&username.to_ascii_lowercase())
    }

    /// An avatar URL already harvested for a username (from any of its
    /// rows), freshest first.
    pub(super) fn known_avatar_url(&self, username: &str) -> Option<String> {
        self.by_username(username)
            .into_iter()
            .find(|e| !e.avatar_url.is_empty())
            .map(|e| e.avatar_url.clone())
    }

    /// Username substring search (ASCII-ci, like the SQL LIKE it replaces):
    /// prefix matches rank first, then username NOCASE; distinct names.
    pub(super) fn search_usernames(&self, term: &str, limit: usize) -> Vec<String> {
        let needle = term.trim().to_ascii_lowercase();
        if needle.is_empty() {
            return Vec::new();
        }
        let inner = self.inner.borrow();
        let mut names: Vec<&str> = inner
            .by_username
            .values()
            .filter_map(|bucket| bucket.first())
            .filter(|e| e.username.to_ascii_lowercase().contains(&needle))
            .map(|e| e.username.as_str())
            .collect();
        names.sort_by(|a, b| {
            let a_pre = a.to_ascii_lowercase().starts_with(&needle);
            let b_pre = b.to_ascii_lowercase().starts_with(&needle);
            b_pre.cmp(&a_pre)
                .then_with(|| a.to_ascii_lowercase().cmp(&b.to_ascii_lowercase()))
                .then_with(|| a.cmp(b))
        });
        let mut out: Vec<String> = names.into_iter().map(String::from).collect();
        out.truncate(limit);
        out
    }

    fn update_rows_for_username(&self, username: &str, mutate: impl Fn(&mut UserEntity)) {
        let rows = self.by_username(username);
        let mut inner = self.inner.borrow_mut();
        for row in rows {
            let mut e = (*row).clone();
            mutate(&mut e);
            inner.insert(e);
        }
    }

    // -------------------------------------------------------------------
    // Write-through mutations
    // -------------------------------------------------------------------

    /// Upsert a user row by id. A blank incoming avatar never wipes a
    /// harvested one.
    pub(super) fn upsert(&self, conn: &Connection, user: &AO3User, now: &str)
        -> Result<(), AppError>
    {
        conn.prepare_cached(
                "INSERT INTO ao3_users (id, username, profile_url, avatar_url, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                    username = excluded.username,
                    profile_url = excluded.profile_url,
                    avatar_url = CASE WHEN excluded.avatar_url = '' THEN ao3_users.avatar_url ELSE excluded.avatar_url END,
                    updated_at = ?5")
            .map_err(map_sql)?
            .execute(params![
                user.id,
                user.username,
                user.profile_url.as_deref().unwrap_or(""),
                user.avatar_url.as_deref().unwrap_or(""),
                now,
            ])
            .map_err(map_sql)?;
        let old = self.get(&user.id);
        let incoming_avatar = user.avatar_url.as_deref().unwrap_or("");
        let entity = UserEntity {
            id: user.id.clone(),
            username: user.username.clone(),
            profile_url: user.profile_url.clone().unwrap_or_default(),
            avatar_url: if incoming_avatar.is_empty() {
                old.as_ref().map(|o| o.avatar_url.clone()).unwrap_or_default()
            } else {
                incoming_avatar.to_string()
            },
            updated_at: now.to_string(),
            ..old.as_ref().map(|o| (**o).clone()).unwrap_or_else(|| UserEntity {
                id: String::new(), username: String::new(), profile_url: String::new(),
                avatar_url: String::new(), updated_at: String::new(),
                numeric_id: String::new(), joined: String::new(), location: String::new(),
                birthday: String::new(), pseuds_json: "[]".into(), bio_json: "[]".into(),
                works_count: 0, series_count: 0, bookmarks_count: 0,
                collections_count: 0, gifts_count: 0,
                is_blocked: false, block_ao3_id: String::new(),
                is_muted: false, mute_ao3_id: String::new(),
                profile_fetched_at: String::new(),
            })
        };
        self.inner.borrow_mut().insert(entity);
        Ok(())
    }

    /// Persist a fetched profile onto every row for the username (matching
    /// the NOCASE UPDATE it backs). An empty incoming numeric_id keeps the
    /// stored one.
    pub(super) fn update_profile(&self, conn: &Connection, p: &UserProfile, now: &str)
        -> Result<(), AppError>
    {
        let pseuds_json = serde_json::to_string(&p.pseuds).map_err(map_json)?;
        let bio_json = serde_json::to_string(&p.bio).map_err(map_json)?;
        conn.execute(
                "UPDATE ao3_users SET
                    numeric_id = CASE WHEN ?2 = '' THEN numeric_id ELSE ?2 END,
                    joined = ?3, location = ?4, birthday = ?5,
                    pseuds_json = ?6, bio_json = ?7,
                    works_count = ?8, series_count = ?9, bookmarks_count = ?10,
                    collections_count = ?11, gifts_count = ?12,
                    is_blocked = ?13, block_ao3_id = ?14,
                    is_muted = ?15, mute_ao3_id = ?16,
                    profile_fetched_at = ?17,
                    updated_at = ?17
                 WHERE username = ?1 COLLATE NOCASE",
                params![
                    p.username,
                    p.numeric_id.as_deref().unwrap_or(""),
                    p.joined, p.location, p.birthday,
                    pseuds_json, bio_json,
                    p.works_count, p.series_count, p.bookmarks_count,
                    p.collections_count, p.gifts_count,
                    p.blocked as i64, p.block_ao3_id.as_deref().unwrap_or(""),
                    p.muted as i64, p.mute_ao3_id.as_deref().unwrap_or(""),
                    now,
                ],
            )
            .map_err(map_sql)?;
        let numeric_id = p.numeric_id.clone().unwrap_or_default();
        self.update_rows_for_username(&p.username, |e| {
            if !numeric_id.is_empty() {
                e.numeric_id = numeric_id.clone();
            }
            e.joined = p.joined.clone();
            e.location = p.location.clone();
            e.birthday = p.birthday.clone();
            e.pseuds_json = pseuds_json.clone();
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
            e.updated_at = now.to_string();
        });
        Ok(())
    }

    /// Record block state (mirrors an AO3-side change) on every row for the
    /// username.
    pub(super) fn set_block_state(&self, conn: &Connection, username: &str, blocked: bool,
                                  ao3_id: &str, now: &str) -> Result<(), AppError> {
        conn.execute(
                "UPDATE ao3_users SET is_blocked = ?2, block_ao3_id = ?3, updated_at = ?4
                 WHERE username = ?1 COLLATE NOCASE",
                params![username, blocked as i64, ao3_id, now],
            )
            .map_err(map_sql)?;
        self.update_rows_for_username(username, |e| {
            e.is_blocked = blocked;
            e.block_ao3_id = ao3_id.to_string();
            e.updated_at = now.to_string();
        });
        Ok(())
    }

    /// Record mute state (mirrors an AO3-side change) on every row for the
    /// username.
    pub(super) fn set_mute_state(&self, conn: &Connection, username: &str, muted: bool,
                                 ao3_id: &str, now: &str) -> Result<(), AppError> {
        conn.execute(
                "UPDATE ao3_users SET is_muted = ?2, mute_ao3_id = ?3, updated_at = ?4
                 WHERE username = ?1 COLLATE NOCASE",
                params![username, muted as i64, ao3_id, now],
            )
            .map_err(map_sql)?;
        self.update_rows_for_username(username, |e| {
            e.is_muted = muted;
            e.mute_ao3_id = ao3_id.to_string();
            e.updated_at = now.to_string();
        });
        Ok(())
    }
}
