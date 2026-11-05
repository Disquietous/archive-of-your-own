use super::*;
use crate::client::has_login_cookie;

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
        self.run_on_runtime(move |client, storage| async move {
            with_recovery(client, storage, OpKind::Login, RetrySafety::Idempotent,
                move |client| {
                    let (username, password) = (username.clone(), password.clone());
                    async move {
                        client.read().await.login(&username, &password).await.map_err(AO3Error::from)
                    }
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
        Ok(())
    }

    pub fn restore_session_cookies(&self) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());

        if let Ok(Some(account)) = storage.get_active_account() {
            if !account.cookies.is_empty() {
                log_info!("cookies"," Restoring from account: {} chars, logged in={}", account.cookies.len(), account.logged_in());
                let client = self.client.blocking_read();
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
        let result = self.run_on_runtime(move |client, storage| async move {
            let previous_cookies = client.read().await.get_session_cookies();
            client.read().await.clear_cookies();

            let (u_for_login, p_for_login) = (u.clone(), p.clone());
            let login_result = with_recovery(client.clone(), storage.clone(), OpKind::Login, RetrySafety::Idempotent,
                move |client| {
                    let (u, p) = (u_for_login.clone(), p_for_login.clone());
                    async move { client.read().await.login(&u, &p).await.map_err(AO3Error::from) }
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
        let was_active = storage.get_active_account()
            .map(|a| a.is_some_and(|a| a.id == id))
            .unwrap_or(false);
        storage.delete_account(id).map_err(AO3Error::from)?;
        if was_active {
            // Activate the first remaining account, if any
            if let Ok(accounts) = storage.get_all_accounts() {
                if let Some(first) = accounts.first() {
                    log_db("set_active_account", storage.set_active_account(first.id));
                }
            }
        }
        Ok(())
    }

    /// Every account as [row id, username, active, logged in] — the id is
    /// the handle every other account call takes.
    pub fn get_accounts(&self) -> Result<Vec<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        let accounts = storage.get_all_accounts().map_err(AO3Error::from)?;
        let flag = |b: bool| if b { "1".to_string() } else { "0".to_string() };
        Ok(accounts.into_iter().map(|a| {
            vec![a.id.to_string(), a.username.clone(), flag(a.is_active), flag(a.logged_in())]
        }).collect())
    }

    pub fn switch_account(&self, account_id: String) -> Result<Vec<String>, AO3Error> {
        let id = parse_account_id(&account_id)?;
        let storage = self.storage.blocking_lock();

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

/// Drop an account's AO3 session on this device.
async fn sign_out_locally(
    client: &Arc<tokio::sync::RwLock<AO3Client>>,
    storage: &Arc<Mutex<Storage>>,
    account_id: i64,
) -> Result<(), AO3Error> {
    let is_active = storage.lock().await.get_active_account()
        .map(|a| a.is_some_and(|a| a.id == account_id))
        .unwrap_or(false);
    if is_active {
        client.read().await.clear_auth_cookies();
    }
    storage.lock().await.clear_account_cookies(account_id).map_err(AO3Error::from)
}
