use super::*;

// ---------------------------------------------------------------------------
// Durable UI preferences. They live in the encrypted DB (not platform
// defaults) so they travel with the library and are shared across platforms.
// Follows moved to `follows.rs`.
// ---------------------------------------------------------------------------

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
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
}
