//! The source-agnostic library search (storage/library_query.rs): what it
//! can search on, the values a field currently has, and running a query.
//! Nothing here touches the network. Imported files are never part of
//! it — the sources that only exist in the library are left out.

use super::*;
use crate::storage::library_query::{facts, LibraryFacts, LibraryField, LibraryFieldKind, LibraryFieldValue, LibraryQuery, LibrarySourceCount};

/// Whether text reads as a range the library search accepts (">1500",
/// "1500-10000", "<100000", "10k-100k", a bare amount).
#[uniffi::export]
pub fn library_range_is_valid(text: String) -> bool {
    crate::storage::library_query::parse_bounds(&text).is_some()
}

/// How long the facts worker lets the library settle after a change
/// before rebuilding: a run of saves (a download, a listing) becomes one
/// rebuild, not one per work.
const FACTS_SETTLE: std::time::Duration = std::time::Duration::from_secs(3);

fn build_facts(storage: &Storage) {
    match storage.library_facts() {
        Ok(facts) => crate::storage::library_query::set_facts(Some(facts)),
        Err(e) => { log_error!("library", "library facts rebuild failed: {e}"); }
    }
}

/// Spawn the worker that keeps the library facts current for one opened
/// database: build them once now, then again after each change to the
/// library, off to the side — no caller waits on a rebuild. The returned
/// handle aborts it; the owning `AO3App` does so when it drops.
pub(super) fn spawn_facts_worker(
    handle: &tokio::runtime::Handle,
    storage: std::sync::Weak<Mutex<Storage>>,
) -> tokio::task::AbortHandle {
    use crate::storage::library_query::FACTS_STALE;
    // A different database may have been open before this one.
    crate::storage::library_query::set_facts(None);
    handle.spawn(async move {
        loop {
            let Some(strong) = storage.upgrade() else { return };
            build_facts(&*strong.lock().await);
            drop(strong);
            FACTS_STALE.notified().await;
            tokio::time::sleep(FACTS_SETTLE).await;
        }
    }).abort_handle()
}

impl AO3App {
    fn library_only_sources(&self) -> Vec<String> {
        self.sources.all().iter().filter(|s| s.library_only()).map(|s| s.capabilities().id.clone()).collect()
    }

    /// The library facts as last built. Only the very first read after a
    /// library opens can find none; it builds them on the spot so a
    /// screen never shows an empty library by accident.
    fn library_facts(&self) -> Arc<LibraryFacts> {
        if let Some(facts) = facts() { return facts }
        build_facts(&self.storage.blocking_lock());
        facts().unwrap_or_default()
    }
}

#[uniffi::export]
impl AO3App {
    /// The searchable sources with works in the library, in the app's
    /// source order, each with its work count. Read from the library
    /// facts held in memory.
    pub fn library_query_sources(&self) -> Vec<LibrarySourceCount> {
        let facts = self.library_facts();
        self.sources.all().iter().filter(|s| !s.library_only()).filter_map(|s| {
            let caps = s.capabilities();
            let works = facts.sources.iter().find(|(source, _)| *source == caps.id).map(|(_, n)| *n)?;
            Some(LibrarySourceCount { source: caps.id.clone(), name: caps.name.clone(), works })
        }).collect()
    }

    /// Every language a library work is in, sorted.
    pub fn library_query_languages(&self) -> Vec<String> {
        self.library_facts().languages.clone()
    }

    /// What each source's works can be searched on beyond the shared
    /// fields, in the app's source order.
    pub fn library_query_fields(&self) -> Vec<LibraryField> {
        let facts = self.library_facts();
        self.sources.all().iter().filter(|s| !s.library_only()).flat_map(|s| {
            let id = &s.capabilities().id;
            facts.fields.iter().filter(|f| f.source == *id).cloned().collect::<Vec<_>>()
        }).collect()
    }

    /// The values a list field has in the library, most-used first;
    /// `filter` narrows to values containing it. A limit of None returns
    /// them all.
    pub fn library_field_values(&self, source: String, kind: LibraryFieldKind, key: String,
                                filter: String, limit: Option<u32>) -> Vec<LibraryFieldValue> {
        self.library_facts().field_values(&source, kind, &key, &filter, limit.unwrap_or(0))
    }

    /// Run a library query and hold its ordered ids under a handle, read
    /// with `get_library_search_page` and released with
    /// `drop_library_search` like any library search.
    pub fn run_library_query(&self, query: LibraryQuery) -> Result<ULibrarySearch, AO3Error> {
        let mut query = query;
        query.excluded_sources = self.library_only_sources();
        let ids = self.storage.blocking_lock().run_library_query(&query).map_err(AO3Error::from)?;
        let total = ids.len() as u64;
        let handle = self.library_searches.lock().unwrap_or_else(|e| e.into_inner()).insert(ids);
        Ok(ULibrarySearch { handle, total })
    }
}
