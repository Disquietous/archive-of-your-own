//! Sources over the bridge (multi-source plan Phase 3): what each source
//! offers, as shapes and vocabulary, and the one entry point that turns
//! any link a source recognises into a library work.

use super::*;
use crate::source::search::{FieldOption, SearchQuery, SearchSchema};
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

#[uniffi::export]
impl AO3App {
    /// A source's search form (design/source-search-plan.md): static
    /// configuration, no I/O. `language_candidates` are the device
    /// language's codes (compacted tag, alpha-2, alpha-3) so a language
    /// field pre-selects the device language when the source offers it.
    pub fn search_schema(&self, source_id: String, language_candidates: Vec<String>) -> Option<SearchSchema> {
        let mut schema = self.sources.by_id(&source_id)?.search_schema()?;
        schema.apply_language_candidates(&language_candidates);
        Some(schema)
    }

    /// One page of a source's search results, cached like every listing.
    /// `op_id`: request-tracking standard.
    pub async fn search_source(&self, query: SearchQuery, page: u32, op_id: Option<u64>) -> Result<UPagedWorks, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime_for(op_id, move |client, storage| async move {
            let Some(source) = registry.by_id(&query.source) else {
                return Err(AO3Error::NotFound { message: format!("no source {}", query.source) });
            };
            check_reachable(&source)?;
            let listing = super::with_recovery_as(
                client, storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Fetch { label: "search".to_string() }, RetrySafety::Idempotent,
                move |_client| {
                    let (source, query) = (source.clone(), query.clone());
                    async move { source.search(&query, page).await.map_err(AO3Error::from) }
                }).await?;
            let s = storage.lock().await;
            save_listing_page(&s, &listing)
        }).await
    }

    /// Remote suggestions for an open-text field of a source's form; the
    /// explicit lookup control calls this, never a keystroke.
    pub async fn search_autocomplete(&self, source_id: String, key: String, prefix: String) -> Result<Vec<FieldOption>, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime(move |_client, _storage| async move {
            let Some(source) = registry.by_id(&source_id) else {
                return Err(AO3Error::NotFound { message: format!("no source {source_id}") });
            };
            check_reachable(&source)?;
            let Some(schema) = source.search_schema() else {
                return Err(AO3Error::NotFound { message: format!("{source_id} has no search") });
            };
            let kind = match schema.field(&key).map(|f| &f.kind) {
                Some(crate::source::search::FieldKind::Text { autocomplete: Some(kind) }) => kind.clone(),
                _ => return Err(AO3Error::NotFound { message: format!("field {key} offers no suggestions") }),
            };
            source.autocomplete(&kind, &prefix).await.map_err(AO3Error::from)
        }).await
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UResolvedLink {
    pub source: String,
    pub external_id: String,
    pub url: String,
}
