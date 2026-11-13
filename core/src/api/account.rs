use super::*;
use crate::client::has_login_cookie;
use crate::models::SOURCE_AO3;
use crate::source::{session_origin, session_part, SignInShape};
use crate::storage::AccountRow;

/// One sign-in at one source, for the account screens.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UAccount {
    /// The row id as a string — the handle every account call takes.
    pub id: String,
    pub source: String,
    pub username: String,
    /// The active account of its source.
    pub is_active: bool,
    /// Its stored session still carries the source's login.
    pub logged_in: bool,
}

/// The accounts of one source that has sign-in, with how to add one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UAccountGroup {
    pub source: String,
    /// The source's display name.
    pub name: String,
    pub sign_in: SignInShape,
    pub accounts: Vec<UAccount>,
}

fn account_dto(a: &AccountRow) -> UAccount {
    UAccount { id: a.id.to_string(), source: a.source.clone(), username: a.username.clone(),
               is_active: a.is_active, logged_in: a.logged_in() }
}

// A source other than AO3 keeps only its session cookies on the account
// row (the site's human-check cookies are the clearance's, not the
// account's), so switching and signing out touch those cookies alone.
// AO3's row holds its whole jar, as it always has.

/// The jar's session at a non-AO3 source, as stored on its account row.
fn jar_session(client: &AO3Client, source: &str) -> String {
    session_origin(source).map(|o| session_part(source, &client.transport().cookies_for(o))).unwrap_or_default()
}

fn drop_jar_session(client: &AO3Client, source: &str) {
    if let Some(origin) = session_origin(source) {
        client.transport().expire_cookies(origin, |name| crate::source::is_session_cookie(source, name));
    }
}

/// Replace the jar's session at a non-AO3 source with `cookies`.
fn put_jar_session(client: &AO3Client, source: &str, cookies: &str) {
    drop_jar_session(client, source);
    if let (Some(origin), false) = (session_origin(source), cookies.is_empty()) {
        client.transport().set_cookies(origin, &session_part(source, cookies));
    }
}

/// Restore the active account's session of every source but AO3 into the
/// jar (AO3's is restored by its own path, whole).
pub(super) fn restore_other_sessions(client: &AO3Client, storage: &Storage) {
    for account in storage.get_active_accounts().unwrap_or_default() {
        if account.source != SOURCE_AO3 && !account.cookies.is_empty() {
            put_jar_session(client, &account.source, &account.cookies);
        }
    }
}

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    // -- Local storage operations --

    pub fn change_db_password(&self, new_password: String) -> Result<(), AO3Error> {
        let old = {
            let mut storage = self.storage.blocking_lock();
            let old = storage.passphrase().to_string();
            storage.change_passphrase(&new_password).map_err(AO3Error::from)?;
            old
        };
        // Backups are keyed like the library; keep them openable.
        self.rekey_backups(&old, &new_password);
        Ok(())
    }

    // -- AO3 Account --

    pub async fn login(&self, username: String, password: String) -> Result<bool, AO3Error> {
        let source = self.ao3_source()?;
        self.run_on_runtime(move |client, storage| async move {
            with_recovery(client, storage, OpKind::Login, RetrySafety::Idempotent,
                move |_client| {
                    let (source, username, password) = (source.clone(), username.clone(), password.clone());
                    async move { source.login(&username, &password).await.map_err(AO3Error::from) }
                }).await
        }).await
    }

    /// Persist the live jar to the active account row — the only place a
    /// session is stored. Without an active account there is nowhere to
    /// keep it (first login saves via `save_account`).
    pub fn save_session_cookies(&self) -> Result<(), AO3Error> {
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        let storage = self.storage.blocking_lock();

        // Save to active account if one exists
        if let Ok(Some(account)) = storage.get_active_account() {
            if !has_login_cookie(&cookies) && account.logged_in() {
                log_info!("cookies", " Refusing to overwrite authenticated cookies with unauthenticated jar");
                return Ok(());
            }
            storage.update_account_cookies(account.id, &cookies).map_err(AO3Error::from)?;
        }
        // Every other source: the same rule, on its session cookies.
        for account in storage.get_active_accounts().map_err(AO3Error::from)? {
            if account.source == SOURCE_AO3 { continue }
            let session = jar_session(&client, &account.source);
            if crate::source::session_logged_in(&account.source, &session) {
                storage.update_account_cookies(account.id, &session).map_err(AO3Error::from)?;
            }
        }
        Ok(())
    }

    pub fn restore_session_cookies(&self) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        let client = self.client.blocking_read();
        // Site clearances (passed human checks) ride along with the
        // session: both live in the jar the transport was just built with.
        crate::client::clearance::restore_all(&crate::client::clearance::load(&storage), &client);
        restore_other_sessions(&client, &storage);

        if let Ok(Some(account)) = storage.get_active_account() {
            if !account.cookies.is_empty() {
                log_info!("cookies"," Restoring from account: {} chars, logged in={}", account.cookies.len(), account.logged_in());
                client.set_session_cookies(&account.cookies);
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn save_account(&self, username: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        // Logging in as a username already on file reuses that row.
        let id = storage.create_account(&username, &cookies).map_err(AO3Error::from)?;
        storage.set_active_account(id).map_err(AO3Error::from)
    }

    pub fn get_credentials(&self) -> Result<Option<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some(account)) = storage.get_active_account() {
            if !account.username.is_empty() {
                return Ok(Some(vec![account.username]));
            }
        }
        // Fallback to legacy
        let u = storage.get_state("ao3_username").map_err(AO3Error::from)?;
        match u {
            Some(u) if !u.is_empty() => Ok(Some(vec![u])),
            _ => Ok(None),
        }
    }

    pub fn clear_credentials(&self) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some(account)) = storage.get_active_account() {
            storage.delete_account(account.id).map_err(AO3Error::from)?;
            return Ok(());
        }
        storage.set_state("ao3_username", "").map_err(AO3Error::from)
    }

    // -- Account Management ---------------------------------------------------

    pub async fn add_account(&self, username: String, password: String) -> Result<String, AO3Error> {
        let u = username.clone();
        let p = password.clone();
        let source = self.ao3_source()?;
        let result = self.run_on_runtime(move |client, storage| async move {
            let previous_cookies = client.read().await.get_session_cookies();
            client.read().await.clear_cookies();

            let (u_for_login, p_for_login) = (u.clone(), p.clone());
            let login_result = with_recovery(client.clone(), storage.clone(), OpKind::Login, RetrySafety::Idempotent,
                move |_client| {
                    let (source, u, p) = (source.clone(), u_for_login.clone(), p_for_login.clone());
                    async move { source.login(&u, &p).await.map_err(AO3Error::from) }
                }).await;
            let success = match login_result {
                Ok(success) => success,
                Err(e) => {
                    if !previous_cookies.is_empty() {
                        client.read().await.set_session_cookies(&previous_cookies);
                    }
                    return Err(e);
                }
            };
            if !success {
                if !previous_cookies.is_empty() {
                    client.read().await.set_session_cookies(&previous_cookies);
                }
                return Err(AO3Error::Network { message: "Login failed".to_string() });
            }

            let new_cookies = client.read().await.get_session_cookies();
            let s = storage.lock().await;

            if let Ok(Some(prev)) = s.get_active_account() {
                if !previous_cookies.is_empty() {
                    log_db("update_account_cookies", s.update_account_cookies(prev.id, &previous_cookies));
                }
            }

            let id = s.create_account(&u, &new_cookies).map_err(AO3Error::from)?;
            s.set_active_account(id).map_err(AO3Error::from)?;
            Ok(id.to_string())
        }).await?;
        Ok(result)
    }

    /// Log the active account out on this device. See `logout_specific_account`.
    pub async fn logout_account(&self) -> Result<(), AO3Error> {
        self.run_on_runtime(|client, storage| async move {
            let active = storage.lock().await.get_active_account().map_err(AO3Error::from)?;
            match active {
                Some(account) => sign_out_locally(&client, &storage, account.id).await,
                None => Ok(()),
            }
        }).await
    }

    /// Log an account out on this device: its session is dropped from
    /// storage (and from the live jar when it is the active account). The
    /// account itself stays. Never sends a request — the orphaned AO3
    /// session expires server-side on its own.
    /// `account_id` is the account's row id as a string (what
    /// `get_accounts` hands out).
    pub async fn logout_specific_account(&self, account_id: String) -> Result<(), AO3Error> {
        let id = parse_account_id(&account_id)?;
        self.run_on_runtime(move |client, storage| async move {
            sign_out_locally(&client, &storage, id).await
        }).await
    }

    pub fn remove_account(&self, account_id: String) -> Result<(), AO3Error> {
        let id = parse_account_id(&account_id)?;
        let storage = self.storage.blocking_lock();
        let Some(account) = storage.get_account(id).map_err(AO3Error::from)? else { return Ok(()) };
        storage.delete_account(id).map_err(AO3Error::from)?;
        if account.is_active {
            // The first remaining account of the same source takes over,
            // its session with it.
            let next = storage.get_all_accounts().unwrap_or_default().into_iter()
                .find(|a| a.source == account.source);
            if let Some(next) = &next {
                log_db("set_active_account", storage.set_active_account(next.id));
            }
            if account.source != SOURCE_AO3 {
                let client = self.client.blocking_read();
                put_jar_session(&client, &account.source, next.as_ref().map(|a| a.cookies.as_str()).unwrap_or(""));
            }
        }
        Ok(())
    }

    /// Every AO3 account as [row id, username, active, logged in] — the id
    /// is the handle every other account call takes. Other sources'
    /// accounts come through `account_groups`.
    pub fn get_accounts(&self) -> Result<Vec<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        let accounts = storage.get_all_accounts().map_err(AO3Error::from)?;
        let flag = |b: bool| if b { "1".to_string() } else { "0".to_string() };
        Ok(accounts.into_iter().filter(|a| a.source == SOURCE_AO3).map(|a| {
            vec![a.id.to_string(), a.username.clone(), flag(a.is_active), flag(a.logged_in())]
        }).collect())
    }

    pub fn switch_account(&self, account_id: String) -> Result<Vec<String>, AO3Error> {
        let id = parse_account_id(&account_id)?;
        let storage = self.storage.blocking_lock();

        if let Some(target) = storage.get_account(id).map_err(AO3Error::from)?.filter(|a| a.source != SOURCE_AO3) {
            let client = self.client.blocking_read();
            // The outgoing account keeps the session the jar holds now.
            if let Ok(Some(current)) = storage.get_active_account_at(&target.source) {
                let session = jar_session(&client, &target.source);
                if current.id != id && crate::source::session_logged_in(&target.source, &session) {
                    log_db("update_account_cookies", storage.update_account_cookies(current.id, &session));
                }
            }
            storage.set_active_account(id).map_err(AO3Error::from)?;
            put_jar_session(&client, &target.source, &target.cookies);
            log_info!("accounts", "Switched {} account to: {}", target.source, target.username);
            let has_session = if target.logged_in() { "1" } else { "0" };
            return Ok(vec![target.username, has_session.to_string()]);
        }

        let client = self.client.blocking_read();
        let current_cookies = client.get_session_cookies();
        if let Ok(Some(current)) = storage.get_active_account() {
            if !current_cookies.is_empty() {
                log_db("update_account_cookies", storage.update_account_cookies(current.id, &current_cookies));
            }
        }
        drop(client);

        storage.set_active_account(id).map_err(AO3Error::from)?;

        if let Ok(Some(account)) = storage.get_active_account() {
            let client = self.client.blocking_read();
            client.clear_cookies();
            let has_session = account.logged_in();
            if !account.cookies.is_empty() {
                client.set_session_cookies(&account.cookies);
            }
            log_info!("accounts", "Switched to account: {}", account.username);
            return Ok(vec![account.username, if has_session { "1" } else { "0" }.to_string()]);
        }
        Ok(vec![String::new(), "0".to_string()])
    }

    /// Every source that has sign-in, in registry order, with its
    /// accounts (oldest first) and how one is added.
    pub fn account_groups(&self) -> Vec<UAccountGroup> {
        let storage = self.storage.blocking_lock();
        let accounts = storage.get_all_accounts().unwrap_or_default();
        self.sources.all().iter().map(|s| s.capabilities())
            .filter(|caps| caps.sign_in != SignInShape::None)
            .map(|caps| UAccountGroup {
                source: caps.id.clone(),
                name: caps.name.clone(),
                sign_in: caps.sign_in,
                accounts: accounts.iter().filter(|a| a.source == caps.id).map(account_dto).collect(),
            })
            .collect()
    }

    /// Sign in at a source whose sign-in is the site's own page
    /// (`SignInShape::Site`): the platform shows the page, the user signs
    /// in, and the cookies that come back become the session. The site
    /// then says who that is (one request), and that account is created
    /// or refreshed and made the source's active one. The web view goes
    /// out on the system connection, so this is refused in Tor mode and
    /// whenever the privacy gate would refuse a direct request.
    pub async fn sign_in_at_site(&self, source: String) -> Result<UAccount, AO3Error> {
        use crate::client::{clearance, privacy};
        let Some(src) = self.sources.by_id(&source) else {
            return Err(AO3Error::NotFound { message: format!("unknown source {source}") });
        };
        let name = src.capabilities().name.clone();
        let (Some(page), Some(origin)) = (src.site_sign_in(), session_origin(&source)) else {
            return Err(AO3Error::Network { message: format!("{name} has no sign-in page") });
        };
        if crate::mock_site::enabled() {
            return Err(AO3Error::Network { message: format!("{name} is not served by the mock archive") });
        }
        if privacy::privacy_mode() == crate::client::PrivacyMode::Tor {
            return Err(AO3Error::Network {
                message: format!("Signing in to {name} happens on its own page, which Tor mode cannot show. Switch to My VPN in Settings › Privacy."),
            });
        }
        if let Err(reason) = privacy::gate(false) {
            crate::events::emit(crate::events::CoreEvent::NetworkRefused { id: None, reason });
            return Err(AO3Error::from(crate::error::AppError::NetworkDisabled));
        }
        self.run_on_runtime(move |client, storage| async move {
            let Some(capability) = super::capabilities::get() else {
                return Err(AO3Error::Network { message: "This device has no sign-in window".to_string() });
            };
            // No lock is held across the capability call (its rule).
            let earned = capability.sign_in_at_site(source.clone(), page.url.clone(), page.login_cookie_prefix.clone()).await
                .map_err(|e| AO3Error::Network { message: format!("{e}") })?;
            let all = earned.cookies.join("; ");
            let session = session_part(&source, &all);
            if !crate::source::session_logged_in(&source, &session) {
                return Err(AO3Error::Network { message: format!("{name} did not sign in") });
            }
            // What is not the session is the site's clearance: its human
            // check and the User-Agent both are bound to.
            let saved = clearance::SavedClearance {
                origin: origin.to_string(),
                clearance: crate::client::SiteClearance {
                    cookies: earned.cookies.iter()
                        .filter(|c| !crate::source::is_session_cookie(&source, c.split('=').next().unwrap_or("")))
                        .cloned().collect(),
                    user_agent: earned.user_agent.clone(),
                },
            };
            let previous = {
                let c = client.read().await;
                let s = storage.lock().await;
                // The account signed in until now keeps its session.
                let previous = jar_session(&c, &source);
                if let Ok(Some(current)) = s.get_active_account_at(&source) {
                    if crate::source::session_logged_in(&source, &previous) {
                        log_db("update_account_cookies", s.update_account_cookies(current.id, &previous));
                    }
                }
                clearance::save(&s, &source, &saved);
                clearance::apply(&c, &source, &saved);
                put_jar_session(&c, &source, &session);
                previous
            };
            let asked = src.clone();
            let who = with_recovery(client.clone(), storage.clone(), OpKind::Login, RetrySafety::Idempotent,
                move |_client| {
                    let asked = asked.clone();
                    async move { asked.whoami().await.map_err(AO3Error::from) }
                }).await;
            let who = match who {
                Ok(Some(who)) => who,
                other => {
                    // Not signed in after all: the jar goes back to what it held.
                    put_jar_session(&*client.read().await, &source, &previous);
                    return Err(other.err().unwrap_or(AO3Error::Network {
                        message: format!("{name} did not recognise the sign-in"),
                    }));
                }
            };
            let s = storage.lock().await;
            let id = s.create_account_at(&source, &who.external_id, &who.username, &session).map_err(AO3Error::from)?;
            s.set_active_account(id).map_err(AO3Error::from)?;
            log_info!("accounts", "Signed in at {source} as {}", who.username);
            s.get_account(id).map_err(AO3Error::from)?
                .map(|a| account_dto(&a))
                .ok_or(AO3Error::NotFound { message: "the account just saved is missing".to_string() })
        }).await
    }

    pub fn get_active_account_username(&self) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        if let Ok(Some(account)) = storage.get_active_account() {
            return Ok(account.username);
        }
        Ok(String::new())
    }

    pub async fn post_form(&self, url: String, keys: Vec<String>, values: Vec<String>) -> Result<String, AO3Error> {
        let pairs: Vec<(String, String)> = keys.into_iter().zip(values).collect();
        self.run_on_runtime(move |client, storage| async move {
            // Generic form POST of unknown semantics — treated as AtMostOnce,
            // same reasoning as post_comment/post_reply.
            with_recovery(client, storage, OpKind::Fetch { label: "post_form".to_string() }, RetrySafety::AtMostOnce,
                move |client| {
                    let (url, pairs) = (url.clone(), pairs.clone());
                    async move { client.read().await.post_form(&url, &pairs).await.map_err(AO3Error::from) }
                }).await
        }).await
    }
}

fn parse_account_id(account_id: &str) -> Result<i64, AO3Error> {
    account_id.trim().parse().map_err(|_| AO3Error::NotFound {
        message: format!("not an account id: {account_id}"),
    })
}

/// Drop an account's session on this device.
async fn sign_out_locally(
    client: &Arc<tokio::sync::RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    account_id: i64,
) -> Result<(), AO3Error> {
    let Some(account) = storage.lock().await.get_account(account_id).map_err(AO3Error::from)? else { return Ok(()) };
    if account.is_active {
        if account.source == SOURCE_AO3 {
            client.read().await.clear_auth_cookies();
        } else {
            drop_jar_session(&*client.read().await, &account.source);
        }
    }
    storage.lock().await.clear_account_cookies(account_id).map_err(AO3Error::from)
}

impl AO3App {
    /// AO3's adapter — its sign-in goes through it like every source's.
    fn ao3_source(&self) -> Result<Arc<dyn crate::source::Source>, AO3Error> {
        self.sources.by_id(SOURCE_AO3)
            .ok_or(AO3Error::NotFound { message: "the AO3 source is not registered".to_string() })
    }
}
