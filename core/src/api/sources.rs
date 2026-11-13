//! Sources over the bridge (multi-source plan Phase 3): what each source
//! offers, as shapes and vocabulary, and the one entry point that turns
//! any link a source recognises into a library work.

use super::*;
use crate::source::search::{FieldOption, SearchQuery, SearchSchema};
use crate::source::{LinkTarget, SourceCapabilities, SourceRegistry, UserPane};

/// The app's sources, in display order. AO3 first, then ScribbleHub (on
/// the same transport); the rated mock answers only while the mock
/// archive is on; local files last (no site, nothing to fetch).
pub(super) fn registry(client: Arc<tokio::sync::RwLock<AO3Client>>) -> SourceRegistry {
    SourceRegistry::new(vec![
        Arc::new(crate::source::ao3::AO3Source::new(client.clone())),
        Arc::new(crate::source::scribblehub::ScribbleHubSource::new(client)),
        Arc::new(crate::source::mock_rated::MockRatedSource::new()),
        Arc::new(crate::source::local::LocalSource::new()),
    ])
}

/// Largest file `import_local_file` will read. A text-only book is a few
/// MB; an illustrated one a few tens.
const MAX_IMPORT_BYTES: u64 = 256 * 1024 * 1024;

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

    /// Whether a pasted, dropped or tapped string holds a link the app
    /// has a view for. Reads only the adapters' URL rules: no library, no
    /// network — cheap enough to ask while a drag is over a window.
    pub fn can_open_link(&self, link: String) -> bool {
        link_in(&self.sources, &link)
            .and_then(|l| self.sources.classify(&l))
            .is_some_and(|(_, target)| target != LinkTarget::Unsupported)
    }

    /// Where a link leads (Area 10): the adapters are asked in turn and
    /// the first that claims it names the destination, by row id. A work,
    /// series or user the library has never seen gets its row here (a stub
    /// until fetched), so the caller can open it like any other.
    /// `name_hint` names a never-seen series until its page is fetched.
    /// `link` may be a bare URL, one without a scheme, or text holding one.
    pub fn open_link(&self, link: String, name_hint: Option<String>) -> Result<ULinkDestination, AO3Error> {
        let s = self.storage.blocking_lock();
        destination(&self.sources, &s, &link, name_hint.as_deref())
    }

    /// The row id of another work at the same source as `work_id`, named
    /// by that source's own id — a series' previous/next link. A work the
    /// library has never seen gets a stub row.
    pub fn sibling_work(&self, work_id: u64, external_id: String) -> Result<u64, AO3Error> {
        let s = self.storage.blocking_lock();
        let sibling = s.work_ref(work_id)
            .and_then(|of| self.sources.by_id(&of.source))
            .and_then(|source| source.work_ref(&external_id));
        let Some(sibling) = sibling else {
            return Err(AO3Error::NotFound { message: format!("no work {external_id} beside work {work_id}") });
        };
        s.ensure_work_stub(&sibling, "").map_err(AO3Error::from)
    }

    /// The site page for one comment on a work, when its source gives
    /// comments their own pages.
    pub fn comment_url(&self, work_id: u64, comment_id: u64) -> Option<String> {
        let source = { let s = self.storage.blocking_lock(); s.work_ref(work_id)?.source };
        self.sources.by_id(&source)?.comment_url(comment_id)
    }

    /// A request URL as the request log and progress views show it: each
    /// source shortens its own (the archive's show as their path).
    pub fn display_url(&self, url: String) -> String {
        self.sources.all().iter().find_map(|s| s.display_url(&url)).unwrap_or(url)
    }

    /// The page the Tor-side challenge web view loads to earn the
    /// archive's clearance cookies.
    pub fn tor_challenge_url(&self) -> String {
        format!("{}/", crate::client::BASE_URL)
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
    /// Bring a book into the library from a file the user picked (Area
    /// 11.2): EPUB, one file. The text is read once and saved like any
    /// fetched work — whole, marked as an offline copy — and the file
    /// itself is neither kept nor changed. Importing the same book again
    /// replaces its record and chapters. No request is made.
    pub async fn import_local_file(&self, path: String) -> Result<UWorkSummary, AO3Error> {
        self.run_on_runtime(move |_client, storage| async move {
            let size = std::fs::metadata(&path)
                .map_err(|e| AO3Error::Storage { message: format!("Couldn’t open the file: {e}") })?
                .len();
            if size > MAX_IMPORT_BYTES {
                return Err(AO3Error::Parse { message: "The file is too large to import.".to_string() });
            }
            let bytes = std::fs::read(&path)
                .map_err(|e| AO3Error::Storage { message: format!("Couldn’t read the file: {e}") })?;
            let book = crate::source::local::read_epub(&bytes, &path).map_err(AO3Error::from)?;
            drop(bytes);

            let s = storage.lock().await;
            // Record, chapters and the offline mark land atomically.
            let tx = s.begin_tx().map_err(AO3Error::from)?;
            let id = s.save_work(&book.summary).map_err(AO3Error::from)?;
            for chapter in &book.chapters {
                s.save_chapter(id, chapter).map_err(AO3Error::from)?;
            }
            // A re-import of a shorter edition leaves no stale tail.
            s.delete_chapters_after(id, book.chapters.len() as u32).map_err(AO3Error::from)?;
            s.mark_downloaded(id).map_err(AO3Error::from)?;
            tx.commit().map_err(AO3Error::from)?;
            let mut summary = book.summary;
            summary.id = id;
            Ok(UWorkSummary::from(s.get_work(id).ok().flatten().unwrap_or(summary)))
        }).await
    }

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

/// Where a link leads, by row id. `Unsupported` is a known site's page
/// with no view here; `Unknown` is a link no source claims (the caller
/// opens it outside the app, or reports it).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ULinkDestination {
    /// `entire`: the link asked for the whole work on one page.
    Work { work_id: u64, entire: bool },
    /// The chapter by its source's own id; it resolves to a position
    /// against the work's saved chapters.
    Chapter { work_id: u64, chapter_external_id: String },
    /// `username` is set when a bare name is the user's key at the source.
    User { user_id: u64, username: Option<String>, pane: UserPane },
    Series { series_id: u64, name: String },
    Collection { name: String },
    Tag { name: String },
    Unsupported { message: String },
    Unknown { message: String },
}

/// `open_link` over a registry and an open library.
fn destination(sources: &SourceRegistry, s: &Storage, link: &str, name_hint: Option<&str>) -> Result<ULinkDestination, AO3Error> {
    let Some((source, target)) = link_in(sources, link).and_then(|l| sources.classify(&l)) else {
        return Ok(ULinkDestination::Unknown { message: "No supported site recognises that link.".to_string() });
    };
    let caps = source.capabilities();
    Ok(match target {
        LinkTarget::Work { work, entire } => ULinkDestination::Work {
            work_id: s.ensure_work_stub(&work, "").map_err(AO3Error::from)?,
            entire,
        },
        LinkTarget::Chapter { work, chapter_id } => ULinkDestination::Chapter {
            work_id: s.ensure_work_stub(&work, "").map_err(AO3Error::from)?,
            chapter_external_id: chapter_id,
        },
        LinkTarget::Series { series } => {
            let series_id = s.ensure_series(&series, name_hint.unwrap_or("")).map_err(AO3Error::from)?;
            let name = s.get_series(series_id).map_err(AO3Error::from)?.map(|r| r.name).unwrap_or_default();
            ULinkDestination::Series { series_id, name }
        }
        LinkTarget::User { user, pane } => {
            let row = if user.source == crate::models::SOURCE_AO3 {
                s.ensure_ao3_user_row(&user.external_id).map_err(AO3Error::from)?
            } else {
                Some(s.record_user(&crate::models::AO3User {
                    source: user.source.clone(), id: user.external_id.clone(), username: user.external_id.clone(),
                    profile_url: Some(user.url.clone()).filter(|u| !u.is_empty()), avatar_url: None,
                }).map_err(AO3Error::from)?)
            };
            match row {
                Some(id) => ULinkDestination::User {
                    user_id: id as u64,
                    username: caps.username_is_key.then(|| user.external_id.clone()),
                    pane,
                },
                None => unsupported(caps),
            }
        }
        LinkTarget::Collection { name } => ULinkDestination::Collection { name },
        LinkTarget::Tag { name } => ULinkDestination::Tag { name },
        LinkTarget::Unsupported => unsupported(caps),
    })
}

fn unsupported(caps: &SourceCapabilities) -> ULinkDestination {
    ULinkDestination::Unsupported { message: format!("This {} link isn’t supported yet.", caps.vocabulary.site_short) }
}

/// The link a string holds: the whole string when it has no whitespace,
/// else the first word in it that a source claims or that carries a
/// scheme (text shared around a URL).
fn link_in(sources: &SourceRegistry, raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() { return None }
    if !trimmed.contains(char::is_whitespace) { return Some(trimmed.to_string()) }
    trimmed.split_whitespace()
        .map(|word| word.trim_matches(|c: char| matches!(c, '<' | '>' | '(' | ')' | '[' | ']' | '"' | '\'' | ',' | '.' | '!')))
        .find(|word| word.contains("://") || sources.classify(word).is_some())
        .map(str::to_string)
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UResolvedLink {
    pub source: String,
    pub external_id: String,
    pub url: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn sources() -> SourceRegistry {
        // A direct client is a reqwest handle; nothing is sent here.
        registry(Arc::new(tokio::sync::RwLock::new(AO3Client::new_direct().await.unwrap())))
    }

    #[tokio::test]
    async fn links_resolve_to_rows_and_unknown_ones_are_told_apart() {
        let sources = sources().await;
        let s = Storage::open_in_memory("k").unwrap();
        let open = |link: &str| destination(&sources, &s, link, None).unwrap();

        let ULinkDestination::Work { work_id, entire: false } = open("https://archiveofourown.org/works/111") else {
            panic!("a work link is a work");
        };
        assert!(s.is_work_stub(work_id), "a never-seen work gets a stub row");
        // The same work again — by chapter, inside shared text, whole — is the same row.
        assert_eq!(open("Read this! https://archiveofourown.org/works/111/chapters/222 so good"),
                   ULinkDestination::Chapter { work_id, chapter_external_id: "222".to_string() });
        assert_eq!(open("archiveofourown.org/works/111?view_full_work=true"),
                   ULinkDestination::Work { work_id, entire: true });

        // Another source's story is a work too, on its own row.
        let ULinkDestination::Work { work_id: other, .. } = open("https://www.scribblehub.com/series/700412/a-story/") else {
            panic!("a second source's story link is a work");
        };
        assert_ne!(other, work_id);

        assert_eq!(open("https://archiveofourown.org/tags/Alpha*s*Beta/works"),
                   ULinkDestination::Tag { name: "Alpha/Beta".to_string() });
        assert_eq!(open("https://archiveofourown.org/collections/Some_Fest"),
                   ULinkDestination::Collection { name: "Some_Fest".to_string() });
        assert!(matches!(open("https://archiveofourown.org/users/sample_user/works"),
                         ULinkDestination::User { username: Some(ref n), pane: UserPane::Works, .. } if n == "sample_user"));
        assert!(matches!(open("https://www.scribblehub.com/profile/51230/quill/"),
                         ULinkDestination::User { username: None, pane: UserPane::Profile, .. }));

        assert_eq!(open("https://archiveofourown.org/works/111/comments"),
                   ULinkDestination::Unsupported { message: "This AO3 link isn’t supported yet.".to_string() });
        assert!(matches!(open("https://example.com/works/111"), ULinkDestination::Unknown { .. }));
        assert!(matches!(open("just some words"), ULinkDestination::Unknown { .. }));
        assert!(matches!(open(""), ULinkDestination::Unknown { .. }));
    }

    #[tokio::test]
    async fn a_never_seen_series_takes_the_hinted_name() {
        let sources = sources().await;
        let s = Storage::open_in_memory("k").unwrap();
        let first = destination(&sources, &s, "https://archiveofourown.org/series/333", Some("Tide Charts")).unwrap();
        let ULinkDestination::Series { series_id, name } = first else { panic!("a series link is a series") };
        assert_eq!(name, "Tide Charts");
        assert_eq!(destination(&sources, &s, "https://archiveofourown.org/series/333", None).unwrap(),
                   ULinkDestination::Series { series_id, name: "Tide Charts".to_string() });
    }
}
