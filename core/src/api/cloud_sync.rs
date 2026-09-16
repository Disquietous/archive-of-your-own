use super::*;

use std::path::{Path, PathBuf};

use crate::storage::library_file::{self, EMBED_PREFIX};

// ---------------------------------------------------------------------------
// Whole-file iCloud sync and local backups.
//
// The shared copy in iCloud is the entire encrypted library as one file,
// keyed with a sync key that travels through iCloud Keychain, plus a small
// JSON manifest beside it saying which device wrote it and when. The
// running app always works on its local database; the core decides, from
// the manifest, whether this device owns the cloud copy (keep it fresh on
// an interval) or another device wrote it (the user chooses: adopt it, or
// overwrite it with the local library). Every replacement — local file
// replaced by the cloud copy, cloud copy replaced by another device's
// library, a backup restored — first files away the database being
// destroyed under Backups/, and the user can restore or remove those.
//
// The platform layer (CloudLibrarySync.swift) is the transport only: it
// resolves the iCloud container, downloads and coordinates files, and
// hands paths in here. Identity and bookkeeping live in a plaintext
// sidecar next to the database (not inside it — adopting another device's
// file must not adopt its identity).
// ---------------------------------------------------------------------------

pub const MANIFEST_FORMAT: u32 = 1;
const SIDECAR_NAME: &str = "library-sync.json";
const BACKUPS_DIR: &str = "Backups";

/// The manifest published beside the cloud copy.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct UCloudManifest {
    pub format: u32,
    pub device_id: String,
    pub device_name: String,
    /// Unix ms.
    pub written_at: i64,
    /// Monotonic per lineage: every push is the highest generation this
    /// device has seen plus one.
    pub generation: i64,
    pub schema_version: u32,
    pub db_size: u64,
}

/// What the core makes of the cloud copy right now.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum UCloudVerdict {
    /// Nothing in iCloud yet — the next push claims it.
    NoCloudCopy,
    /// This device's lineage is current in iCloud. `needs_push` is true
    /// when the local library changed after the last push.
    Owned { needs_push: bool },
    /// Another device wrote the cloud copy since this device last pushed
    /// or adopted. `dismissed` means the user already chose "not now" for
    /// this exact generation.
    Foreign { device_name: String, written_at: i64, generation: i64, dismissed: bool },
    /// The cloud copy's schema is newer than this build can open.
    NeedsAppUpdate { schema_version: u32 },
    /// The manifest could not be parsed.
    Unreadable { message: String },
}

/// A copy ready for the transport to place in iCloud.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UCloudExport {
    pub manifest_json: String,
    pub generation: i64,
    pub db_size: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UCloudSyncStatus {
    pub device_id: String,
    pub enabled: bool,
    /// Unix ms of the last successful push, if any.
    pub last_push_at: Option<i64>,
    pub last_pushed_generation: i64,
}

/// One filed-away library under Backups/.
#[derive(Debug, Clone, uniffi::Record)]
pub struct UBackupInfo {
    pub id: String,
    /// Unix ms.
    pub created_at: i64,
    /// Why it was made, for display ("Before using the iCloud copy").
    pub reason: String,
    /// The device whose library this is, when it came from iCloud.
    pub source_device: String,
    pub size_bytes: u64,
}

// ---------------------------------------------------------------------------
// Sidecar state
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
struct SyncState {
    #[serde(default)]
    device_id: String,
    #[serde(default)]
    enabled: bool,
    /// Unix ms of the last push (or adoption, which counts as being
    /// current with the cloud copy).
    #[serde(default)]
    last_push_at: i64,
    /// Generation this device last pushed or adopted — the lineage mark.
    #[serde(default)]
    last_pushed_generation: i64,
    /// Highest generation seen in any manifest, so a push always outranks.
    #[serde(default)]
    known_cloud_generation: i64,
    /// Foreign generation the user declined to act on.
    #[serde(default)]
    dismissed_generation: i64,
}

#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
struct BackupMeta {
    #[serde(default)]
    created_at: i64,
    #[serde(default)]
    reason: String,
    #[serde(default)]
    source_device: String,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn storage_err(message: impl Into<String>) -> AO3Error {
    AO3Error::Storage { message: message.into() }
}

fn io_err(what: &str, e: std::io::Error) -> AO3Error {
    storage_err(format!("{what}: {e}"))
}

impl AO3App {
    fn sidecar_path(&self) -> PathBuf {
        Path::new(&self.state_dir).join(SIDECAR_NAME)
    }

    fn backups_dir(&self) -> PathBuf {
        Path::new(&self.state_dir).join(BACKUPS_DIR)
    }

    fn staging_path(&self, name: &str) -> PathBuf {
        Path::new(&self.state_dir).join(name)
    }

    /// Load the sidecar, minting a device id on first use.
    fn sync_state(&self, storage: &Storage) -> Result<SyncState, AO3Error> {
        let path = self.sidecar_path();
        let mut state: SyncState = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => SyncState::default(),
        };
        if state.device_id.is_empty() {
            state.device_id = storage.random_hex(16).map_err(AO3Error::from)?;
            self.write_sync_state(&state)?;
        }
        Ok(state)
    }

    fn write_sync_state(&self, state: &SyncState) -> Result<(), AO3Error> {
        let json = serde_json::to_vec_pretty(state).map_err(|e| storage_err(e.to_string()))?;
        let path = self.sidecar_path();
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, json).map_err(|e| io_err("write sync state", e))?;
        std::fs::rename(&tmp, &path).map_err(|e| io_err("commit sync state", e))
    }

    /// Verify a staged cloud copy opens with the sync key, is not from a
    /// newer app, and carries the generation the manifest promised (a
    /// mismatch means iCloud has not finished delivering the file that
    /// goes with the manifest we read). Returns the writer's device name.
    fn check_staged_copy(&self, staged: &Path, cloud_key: &str, expected_generation: i64) -> Result<String, AO3Error> {
        let conn = library_file::open_closed(staged, cloud_key).map_err(AO3Error::from)?;
        let version = library_file::user_version(&conn).map_err(AO3Error::from)?;
        if version > Storage::SCHEMA_VERSION {
            return Err(storage_err(format!(
                "the iCloud copy was written by a newer app (schema v{version}); update this app first"
            )));
        }
        let embedded = library_file::read_embedded(&conn).map_err(AO3Error::from)?;
        drop(conn);
        let generation: i64 = embedded
            .get(&format!("{EMBED_PREFIX}generation"))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        if generation != expected_generation {
            return Err(storage_err("the iCloud copy is still updating; try again in a moment"));
        }
        Ok(embedded
            .get(&format!("{EMBED_PREFIX}device_name"))
            .cloned()
            .unwrap_or_default())
    }

    fn new_backup_slot(&self, reason: &str, source_device: &str) -> Result<(String, PathBuf), AO3Error> {
        let dir = self.backups_dir();
        std::fs::create_dir_all(&dir).map_err(|e| io_err("create backups dir", e))?;
        let mut id = now_ms();
        while dir.join(format!("{id}.db")).exists() {
            id += 1;
        }
        let meta = BackupMeta { created_at: id, reason: reason.to_string(), source_device: source_device.to_string() };
        let json = serde_json::to_vec_pretty(&meta).map_err(|e| storage_err(e.to_string()))?;
        std::fs::write(dir.join(format!("{id}.json")), json).map_err(|e| io_err("write backup info", e))?;
        Ok((id.to_string(), dir.join(format!("{id}.db"))))
    }

    fn backup_info(&self, id: &str) -> Option<UBackupInfo> {
        let dir = self.backups_dir();
        let db = dir.join(format!("{id}.db"));
        let size = std::fs::metadata(&db).ok()?.len();
        let meta: BackupMeta = std::fs::read(dir.join(format!("{id}.json")))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Some(UBackupInfo {
            id: id.to_string(),
            created_at: if meta.created_at > 0 { meta.created_at } else { id.parse().unwrap_or(0) },
            reason: meta.reason,
            source_device: meta.source_device,
            size_bytes: size,
        })
    }

    /// Re-encrypt every backup from `old` to `new` so a library password
    /// change never strands them.
    pub(super) fn rekey_backups(&self, old: &str, new: &str) {
        for info in self.backups_list().unwrap_or_default() {
            let path = self.backups_dir().join(format!("{}.db", info.id));
            if let Err(e) = library_file::rekey_file(&path, old, new) {
                log_info!("backup", "could not rekey backup {}: {}", info.id, e);
            }
        }
    }
}

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`. The
// export and adopt calls hold the storage lock for the whole file copy;
// the transport calls them off the main thread.
#[uniffi::export]
impl AO3App {
    pub fn cloud_sync_status(&self) -> Result<UCloudSyncStatus, AO3Error> {
        let s = self.storage.blocking_lock();
        let state = self.sync_state(&s)?;
        Ok(UCloudSyncStatus {
            device_id: state.device_id,
            enabled: state.enabled,
            last_push_at: (state.last_push_at > 0).then_some(state.last_push_at),
            last_pushed_generation: state.last_pushed_generation,
        })
    }

    pub fn set_cloud_sync_enabled(&self, enabled: bool) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let mut state = self.sync_state(&s)?;
        state.enabled = enabled;
        self.write_sync_state(&state)
    }

    /// Judge the cloud copy from its manifest (`None` when iCloud holds
    /// nothing). Records the generation seen so a later push outranks it.
    pub fn cloud_sync_evaluate(&self, manifest_json: Option<String>) -> Result<UCloudVerdict, AO3Error> {
        let s = self.storage.blocking_lock();
        let mut state = self.sync_state(&s)?;
        let Some(json) = manifest_json else {
            return Ok(UCloudVerdict::NoCloudCopy);
        };
        let manifest: UCloudManifest = match serde_json::from_str(&json) {
            Ok(m) => m,
            Err(e) => return Ok(UCloudVerdict::Unreadable { message: e.to_string() }),
        };
        if manifest.generation > state.known_cloud_generation {
            state.known_cloud_generation = manifest.generation;
            self.write_sync_state(&state)?;
        }
        if manifest.generation == state.last_pushed_generation {
            let modified = s.last_modified_ms().unwrap_or(0);
            return Ok(UCloudVerdict::Owned { needs_push: modified > state.last_push_at });
        }
        if manifest.schema_version > Storage::SCHEMA_VERSION {
            return Ok(UCloudVerdict::NeedsAppUpdate { schema_version: manifest.schema_version });
        }
        Ok(UCloudVerdict::Foreign {
            device_name: manifest.device_name,
            written_at: manifest.written_at,
            generation: manifest.generation,
            dismissed: state.dismissed_generation == manifest.generation,
        })
    }

    /// Write the library copy the transport will place in iCloud to
    /// `staging_path`, keyed with `cloud_key`. Nothing is recorded as
    /// pushed until `cloud_sync_mark_pushed` — a failed upload must not
    /// claim ownership.
    pub fn cloud_sync_export(&self, staging_path: String, cloud_key: String, device_name: String) -> Result<UCloudExport, AO3Error> {
        let s = self.storage.blocking_lock();
        let state = self.sync_state(&s)?;
        let generation = state.known_cloud_generation.max(state.last_pushed_generation) + 1;
        let written_at = now_ms();
        let gen_s = generation.to_string();
        let at_s = written_at.to_string();
        let embed = [
            (format!("{EMBED_PREFIX}device_id"), state.device_id.clone()),
            (format!("{EMBED_PREFIX}device_name"), device_name.clone()),
            (format!("{EMBED_PREFIX}generation"), gen_s),
            (format!("{EMBED_PREFIX}written_at"), at_s),
        ];
        let embed_refs: Vec<(&str, &str)> = embed.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let db_size = s
            .export_copy(Path::new(&staging_path), &cloud_key, &embed_refs)
            .map_err(AO3Error::from)?;
        let manifest = UCloudManifest {
            format: MANIFEST_FORMAT,
            device_id: state.device_id,
            device_name,
            written_at,
            generation,
            schema_version: Storage::SCHEMA_VERSION,
            db_size,
        };
        let manifest_json = serde_json::to_string_pretty(&manifest).map_err(|e| storage_err(e.to_string()))?;
        log_info!("sync", "exported library copy gen {} ({} bytes)", generation, db_size);
        Ok(UCloudExport { manifest_json, generation, db_size })
    }

    /// The transport placed generation `generation` in iCloud.
    pub fn cloud_sync_mark_pushed(&self, generation: i64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let mut state = self.sync_state(&s)?;
        state.last_pushed_generation = generation;
        state.known_cloud_generation = state.known_cloud_generation.max(generation);
        state.last_push_at = now_ms();
        self.write_sync_state(&state)
    }

    /// The user chose "not now" for a foreign copy: stay quiet about this
    /// generation until iCloud changes again.
    pub fn cloud_sync_dismiss(&self, generation: i64) -> Result<(), AO3Error> {
        let s = self.storage.blocking_lock();
        let mut state = self.sync_state(&s)?;
        state.dismissed_generation = generation;
        self.write_sync_state(&state)
    }

    /// Replace this device's library with the staged cloud copy. The local
    /// library is filed under Backups first. On success this device is
    /// current with `expected_generation`, so its next local change pushes.
    pub fn cloud_sync_adopt(&self, staged_path: String, cloud_key: String, expected_generation: i64) -> Result<UBackupInfo, AO3Error> {
        let staged = PathBuf::from(&staged_path);
        let mut s = self.storage.blocking_lock();
        let mut state = self.sync_state(&s)?;
        let writer = self.check_staged_copy(&staged, &cloud_key, expected_generation)?;
        library_file::rekey_file(&staged, &cloud_key, s.passphrase()).map_err(AO3Error::from)?;
        let (id, backup_path) = self.new_backup_slot("Before using the iCloud copy", "")?;
        if let Err(e) = s.replace_with(&staged, &backup_path) {
            let _ = std::fs::remove_file(self.backups_dir().join(format!("{id}.json")));
            return Err(AO3Error::from(e));
        }
        self.library_searches.lock().unwrap_or_else(|e| e.into_inner()).clear();
        state.last_pushed_generation = expected_generation;
        state.known_cloud_generation = state.known_cloud_generation.max(expected_generation);
        state.last_push_at = now_ms();
        state.dismissed_generation = 0;
        self.write_sync_state(&state)?;
        log_info!("sync", "adopted iCloud copy gen {} from {}", expected_generation, writer);
        self.backup_info(&id).ok_or_else(|| storage_err("backup written but unreadable"))
    }

    /// The user chose to overwrite a foreign cloud copy with this library:
    /// file the copy being destroyed under Backups (re-keyed to this
    /// library's key) before the push that replaces it.
    pub fn cloud_sync_stash_foreign_copy(&self, staged_path: String, cloud_key: String, expected_generation: i64) -> Result<UBackupInfo, AO3Error> {
        let staged = PathBuf::from(&staged_path);
        let s = self.storage.blocking_lock();
        let writer = self.check_staged_copy(&staged, &cloud_key, expected_generation)?;
        library_file::rekey_file(&staged, &cloud_key, s.passphrase()).map_err(AO3Error::from)?;
        let (id, backup_path) = self.new_backup_slot("iCloud copy replaced by this device", &writer)?;
        if let Err(e) = std::fs::rename(&staged, &backup_path) {
            let _ = std::fs::remove_file(self.backups_dir().join(format!("{id}.json")));
            return Err(io_err("file iCloud copy under backups", e));
        }
        library_file::remove_file_set(&staged);
        self.backup_info(&id).ok_or_else(|| storage_err("backup written but unreadable"))
    }

    // -- Backups --

    /// Every backup on this device, newest first.
    pub fn backups_list(&self) -> Result<Vec<UBackupInfo>, AO3Error> {
        let dir = self.backups_dir();
        let Ok(entries) = std::fs::read_dir(&dir) else {
            return Ok(Vec::new());
        };
        let mut out: Vec<UBackupInfo> = entries
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                let id = name.strip_suffix(".db")?;
                self.backup_info(id)
            })
            .collect();
        out.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(out)
    }

    /// Replace the live library with backup `id` (the backup itself stays;
    /// the library being replaced is filed as a new backup first).
    pub fn backup_restore(&self, id: String) -> Result<UBackupInfo, AO3Error> {
        let source = self.backups_dir().join(format!("{id}.db"));
        let mut s = self.storage.blocking_lock();
        let conn = library_file::open_closed(&source, s.passphrase())
            .map_err(|_| storage_err("this backup was made under a different library password and can't be opened"))?;
        let version = library_file::user_version(&conn).map_err(AO3Error::from)?;
        drop(conn);
        if version > Storage::SCHEMA_VERSION {
            return Err(storage_err(format!("this backup was made by a newer app (schema v{version})")));
        }
        let incoming = self.staging_path("restore.incoming");
        library_file::remove_file_set(&incoming);
        std::fs::copy(&source, &incoming).map_err(|e| io_err("copy backup", e))?;
        let info = self.backup_info(&id).ok_or_else(|| storage_err("backup not found"))?;
        let (new_id, backup_path) = self.new_backup_slot("Before restoring a backup", "")?;
        if let Err(e) = s.replace_with(&incoming, &backup_path) {
            let _ = std::fs::remove_file(self.backups_dir().join(format!("{new_id}.json")));
            library_file::remove_file_set(&incoming);
            return Err(AO3Error::from(e));
        }
        self.library_searches.lock().unwrap_or_else(|e| e.into_inner()).clear();
        // A restored library is a new lineage as far as iCloud is
        // concerned: it must be pushed (or the cloud copy adopted)
        // deliberately, so drop the ownership mark.
        let mut state = self.sync_state(&s)?;
        state.last_pushed_generation = 0;
        state.last_push_at = 0;
        self.write_sync_state(&state)?;
        log_info!("backup", "restored backup {} ({})", info.id, info.reason);
        self.backup_info(&new_id).ok_or_else(|| storage_err("backup written but unreadable"))
    }

    pub fn backup_delete(&self, id: String) -> Result<(), AO3Error> {
        let dir = self.backups_dir();
        let db = dir.join(format!("{id}.db"));
        if !db.exists() {
            return Err(storage_err("backup not found"));
        }
        library_file::remove_file_set(&db);
        let _ = std::fs::remove_file(dir.join(format!("{id}.json")));
        Ok(())
    }
}
