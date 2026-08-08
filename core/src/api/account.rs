use super::*;

#[uniffi::export]
impl AO3App {
    // -- Local storage operations --

    pub fn change_db_password(&self, new_password: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        storage.change_passphrase(&new_password).map_err(AO3Error::from)
    }

    // -- AO3 Account --

    pub async fn login(&self, username: String, password: String) -> Result<bool, AO3Error> {
        self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;
            let result = c.login(&username, &password).await.map_err(AO3Error::from)?;
            if result {
                let cookies = c.get_session_cookies();
                let s = storage.lock().await;
                log_db("set_state", s.set_state("ao3_session_cookies", &cookies));
            }
            Ok(result)
        }).await
    }

    pub fn save_session_cookies(&self) -> Result<(), AO3Error> {
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        let storage = self.storage.blocking_lock();

        // Save to active account if one exists
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            if !cookies.contains("user_credentials") {
                if let Ok(Some((_, _, existing))) = storage.get_active_account() {
                    if existing.contains("user_credentials") {
                        log_info!("cookies", " Refusing to overwrite authenticated cookies with unauthenticated jar");
                        return Ok(());
                    }
                }
            }
            storage.update_account_cookies(&id, &cookies).map_err(AO3Error::from)?;
            return Ok(());
        }

        // Fallback to legacy app_state
        if !cookies.contains("user_credentials") {
            if let Ok(Some(existing)) = storage.get_state("ao3_session_cookies") {
                if existing.contains("user_credentials") {
                    log_info!("cookies", " Refusing to overwrite authenticated cookies with unauthenticated jar");
                    return Ok(());
                }
            }
        }
        storage.set_state("ao3_session_cookies", &cookies).map_err(AO3Error::from)
    }

    pub fn restore_session_cookies(&self) -> Result<bool, AO3Error> {
        let storage = self.storage.blocking_lock();

        // Try active account first
        if let Ok(Some((_, _, cookies))) = storage.get_active_account() {
            if !cookies.is_empty() {
                log_info!("cookies"," Restoring from account: {} chars, has user_credentials={}", cookies.len(), cookies.contains("user_credentials"));
                let client = self.client.blocking_read();
                client.set_session_cookies(&cookies);
                return Ok(true);
            }
        }

        // Fallback to legacy
        if let Some(cookies) = storage.get_state("ao3_session_cookies").map_err(AO3Error::from)? {
            if !cookies.is_empty() {
                log_info!("cookies"," Restoring from legacy: {} chars, has user_credentials={}", cookies.len(), cookies.contains("user_credentials"));
                let client = self.client.blocking_read();
                client.set_session_cookies(&cookies);
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn save_account(&self, username: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            storage.create_account(&id, &username, "").map_err(AO3Error::from)?;
            return Ok(());
        }
        let id = format!("account-{}", username.to_lowercase());
        let client = self.client.blocking_read();
        let cookies = client.get_session_cookies();
        storage.create_account(&id, &username, &cookies).map_err(AO3Error::from)?;
        storage.set_active_account(&id).map_err(AO3Error::from)
    }

    pub fn get_credentials(&self) -> Result<Option<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        if let Ok(Some((_, username, _))) = storage.get_active_account() {
            if !username.is_empty() {
                return Ok(Some(vec![username]));
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
        if let Ok(Some((id, _, _))) = storage.get_active_account() {
            storage.delete_account(&id).map_err(AO3Error::from)?;
            return Ok(());
        }
        storage.set_state("ao3_username", "").map_err(AO3Error::from)
    }

    // -- Account Management ---------------------------------------------------

    pub async fn add_account(&self, username: String, password: String) -> Result<String, AO3Error> {
        let u = username.clone();
        let p = password.clone();
        let result = self.run_on_runtime(move |client, storage| async move {
            let c = client.read().await;

            let previous_cookies = c.get_session_cookies();
            c.clear_cookies();

            let success = c.login(&u, &p).await.map_err(AO3Error::from)?;
            if !success {
                if !previous_cookies.is_empty() {
                    c.set_session_cookies(&previous_cookies);
                }
                return Err(AO3Error::Network { message: "Login failed".to_string() });
            }

            let new_cookies = c.get_session_cookies();
            let id = format!("account-{}", u.to_lowercase());
            let s = storage.lock().await;

            if let Ok(Some((prev_id, _, _))) = s.get_active_account() {
                if !previous_cookies.is_empty() {
                    log_db("update_account_cookies", s.update_account_cookies(&prev_id, &previous_cookies));
                }
            }

            s.create_account(&id, &u, &new_cookies).map_err(AO3Error::from)?;
            s.set_active_account(&id).map_err(AO3Error::from)?;
            Ok(id)
        }).await?;
        Ok(result)
    }

    pub async fn logout_account(&self) -> Result<(), AO3Error> {
        self.run_on_runtime(|client, storage| async move {
            let c = client.read().await;
            let _ = c.logout().await;
            drop(c);

            let s = storage.lock().await;
            if let Ok(Some((id, _, _))) = s.get_active_account() {
                s.clear_account_cookies(&id).map_err(AO3Error::from)?;
            }
            Ok(())
        }).await
    }

    pub async fn logout_specific_account(&self, account_id: String) -> Result<(), AO3Error> {
        let aid = account_id.clone();
        self.run_on_runtime(move |client, storage| async move {
            // Storage must not stay locked across the network logout — every
            // sync getter blocks on this mutex.
            let is_active = {
                let s = storage.lock().await;
                s.get_active_account()
                    .map(|a| a.map(|(id, _, _)| id == aid).unwrap_or(false))
                    .unwrap_or(false)
            };

            if is_active {
                let c = client.read().await;
                let _ = c.logout().await;
                drop(c);
            }

            let s = storage.lock().await;
            s.clear_account_cookies(&aid).map_err(AO3Error::from)?;
            Ok(())
        }).await
    }

    pub fn remove_account(&self, account_id: String) -> Result<(), AO3Error> {
        let storage = self.storage.blocking_lock();
        let was_active = storage.get_active_account()
            .map(|a| a.map(|(id, _, _)| id == account_id).unwrap_or(false))
            .unwrap_or(false);
        storage.delete_account(&account_id).map_err(AO3Error::from)?;
        if was_active {
            // Activate the first remaining account, if any
            if let Ok(accounts) = storage.get_all_accounts() {
                if let Some((first_id, _, _)) = accounts.first() {
                    log_db("set_active_account", storage.set_active_account(first_id));
                }
            }
        }
        Ok(())
    }

    pub fn get_accounts(&self) -> Result<Vec<Vec<String>>, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        let accounts = storage.get_all_accounts().map_err(AO3Error::from)?;
        Ok(accounts.into_iter().map(|(id, username, active)| {
            vec![id, username, if active { "1".to_string() } else { "0".to_string() }]
        }).collect())
    }

    pub fn switch_account(&self, account_id: String) -> Result<Vec<String>, AO3Error> {
        let storage = self.storage.blocking_lock();

        let client = self.client.blocking_read();
        let current_cookies = client.get_session_cookies();
        if let Ok(Some((current_id, _, _))) = storage.get_active_account() {
            if current_cookies.contains("user_credentials") || !current_cookies.is_empty() {
                log_db("update_account_cookies", storage.update_account_cookies(&current_id, &current_cookies));
            }
        }
        drop(client);

        storage.set_active_account(&account_id).map_err(AO3Error::from)?;

        if let Ok(Some((_, username, cookies))) = storage.get_active_account() {
            let client = self.client.blocking_read();
            client.clear_cookies();
            let has_session = !cookies.is_empty() && cookies.contains("user_credentials");
            if !cookies.is_empty() {
                client.set_session_cookies(&cookies);
            }
            log_info!("accounts", "Switched to account: {}", username);
            return Ok(vec![username, if has_session { "1" } else { "0" }.to_string()]);
        }
        Ok(vec![String::new(), "0".to_string()])
    }

    pub fn get_active_account_username(&self) -> Result<String, AO3Error> {
        let storage = self.storage.blocking_lock();
        log_db("migrate_legacy_credentials", storage.migrate_legacy_credentials());
        if let Ok(Some((_, username, _))) = storage.get_active_account() {
            return Ok(username);
        }
        Ok(String::new())
    }

    pub async fn post_form(&self, url: String, keys: Vec<String>, values: Vec<String>) -> Result<String, AO3Error> {
        let pairs: Vec<(String, String)> = keys.into_iter().zip(values.into_iter()).collect();
        self.run_on_runtime(move |client, _storage| async move {
            let c = client.read().await;
            c.post_form(&url, &pairs).await.map_err(AO3Error::from)
        }).await
    }
}
