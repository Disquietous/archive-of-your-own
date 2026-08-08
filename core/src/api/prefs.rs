use super::*;

// ---------------------------------------------------------------------------
// Durable UI preferences + device-local follows. Both live in the encrypted
// DB (not platform defaults) so they travel with the library and are shared
// across platforms.
// ---------------------------------------------------------------------------

#[uniffi::export]
impl AO3App {
    /// Store a durable UI preference. Keys are namespaced with "pref:"
    /// internally so they can never collide with the core's own state keys.
    pub fn set_pref(&self, key: String, value: String) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.set_state(&format!("pref:{key}"), &value).map_err(AO3Error::from)
    }

    pub fn get_pref(&self, key: String) -> Result<Option<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_state(&format!("pref:{key}")).map_err(AO3Error::from)
    }

    /// Device-local follows (`kind` is "fandom" or "author"), in the order
    /// they were added. User library data — encrypted DB, not UserDefaults.
    pub fn get_followed(&self, kind: String) -> Result<Vec<String>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_followed(&kind).map_err(AO3Error::from)
    }

    pub fn add_followed(&self, kind: String, name: String) -> Result<(), AO3Error> {
        let name = name.trim();
        if name.is_empty() {
            return Ok(());
        }
        let s = self.storage.blocking_lock();
        s.add_followed(&kind, name).map_err(AO3Error::from)
    }

    pub fn remove_followed(&self, kind: String, name: String) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        s.remove_followed(&kind, &name).map_err(AO3Error::from)
    }
}
