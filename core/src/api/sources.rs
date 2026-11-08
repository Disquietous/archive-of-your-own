//! Sources over the bridge (multi-source plan Phase 3): what each source
//! offers, as shapes and vocabulary, and the one entry point that turns
//! any link a source recognises into a library work.

use super::*;
use crate::source::{SourceCapabilities, SourceRegistry};

/// The app's sources, in display order. AO3 first, then ScribbleHub (on
/// the same transport); the rated mock answers only while the mock
/// archive is on.
pub(super) fn registry(client: Arc<tokio::sync::RwLock<AO3Client>>) -> SourceRegistry {
    SourceRegistry::new(vec![
        Arc::new(crate::source::ao3::AO3Source::new(client.clone())),
        Arc::new(crate::source::scribblehub::ScribbleHubSource::new(client)),
        Arc::new(crate::source::mock_rated::MockRatedSource::new()),
    ])
}

#[uniffi::export]
impl AO3App {
    /// Every source, with its shapes and vocabulary. Fetched once; the UI
    /// renders a work's affordances from its source's entry.
    pub fn list_sources(&self) -> Vec<SourceCapabilities> {
        self.sources.capabilities()
    }

    pub fn source_capabilities(&self, source_id: String) -> Option<SourceCapabilities> {
        self.sources.by_id(&source_id).map(|s| s.capabilities().clone())
    }

    /// Which source, if any, recognises a link, and the id it resolves to.
    pub fn resolve_link(&self, link: String) -> Option<UResolvedLink> {
        self.sources.resolve(&link).map(|(source, external)| UResolvedLink {
            source: source.id().to_string(),
            external_id: external.external_id,
            url: external.url,
        })
    }

    /// Bring a work into the library from any link a source recognises:
    /// its row is ensured (a stub until the fetch lands), then fetched and
    /// saved like any work. `op_id`: request-tracking standard.
    pub async fn import_work_from_link(&self, link: String, op_id: Option<u64>) -> Result<UWorkSummary, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime_for(op_id, move |client, storage| async move {
            let Some((source, external)) = registry.resolve(&link) else {
                return Err(AO3Error::NotFound { message: format!("No source recognises {link}") });
            };
            check_reachable(&source)?;
            let work_id = { let s = storage.lock().await; s.ensure_work_stub(&external, "").map_err(AO3Error::from)? };
            super::works::fetch_and_save_work(client, storage, registry, work_id, op_id).await
        }).await
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UResolvedLink {
    pub source: String,
    pub external_id: String,
    pub url: String,
}
