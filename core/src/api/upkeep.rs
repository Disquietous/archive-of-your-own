use super::*;
use std::time::Duration;

/// Background log upkeep: a periodic task on the app's runtime that trims
/// the debug and request logs to the user's settings. Every knob is a
/// pref (see `LogTrimSettings::read`), re-read each cycle so settings
/// changes apply without a restart. Deletes run in batches that release
/// the relevant lock between batches, so a large backlog never stalls
/// live work.
///
/// Each setting follows the age-OR-rows contract: age and row-count
/// limits are independently optional, and when both are set the age trim
/// runs first, then the row trim — old entries go even when the table is
/// under its row cap.

const BATCH: u32 = 1_000;
/// Settings poll cadence — also the delay before the first trim, so a
/// fresh launch cleans up within a minute.
const POLL: Duration = Duration::from_secs(60);

struct LogTrimSettings {
    interval: Duration,
    debug_max_age_min: Option<u64>,
    debug_max_rows: Option<u64>,
    request_max_age_min: Option<u64>,
    request_max_rows: Option<u64>,
}

fn read_pref(s: &Storage, key: &str) -> Option<String> {
    s.get_state(&format!("pref:{key}")).ok().flatten().filter(|v| !v.is_empty())
}

fn unit_minutes(unit: &str) -> u64 {
    match unit {
        "days" => 24 * 60,
        "hours" => 60,
        _ => 1, // "minutes"
    }
}

/// A value+unit pref pair ("{prefix}_value" / "{prefix}_unit") as
/// minutes. Unset, unparsable, or 0 = None (disabled).
fn read_value_unit_minutes(s: &Storage, prefix: &str) -> Option<u64> {
    let value: u64 = read_pref(s, &format!("{prefix}_value"))?.parse().ok()?;
    if value == 0 { return None; }
    let unit = read_pref(s, &format!("{prefix}_unit")).unwrap_or_else(|| "minutes".into());
    Some(value * unit_minutes(&unit))
}

/// A row-cap pref: unset falls back to `default`; explicit 0 = no limit.
fn read_row_cap(s: &Storage, key: &str, default: Option<u64>) -> Option<u64> {
    match read_pref(s, key) {
        Some(v) => v.parse::<u64>().ok().filter(|&n| n > 0),
        None => default,
    }
}

/// The request log keeps its long-standing 2000-row cap until the user
/// sets one (0 = unlimited). Also enforced at insert time — see
/// `request_log_row_cap`.
pub(super) fn request_log_row_cap(s: &Storage) -> Option<u64> {
    read_row_cap(s, "request_log_max_rows", Some(2000))
}

impl LogTrimSettings {
    fn read(s: &Storage) -> Self {
        LogTrimSettings {
            interval: Duration::from_secs(
                60 * read_value_unit_minutes(s, "log_trim_interval").unwrap_or(60).max(1)),
            debug_max_age_min: read_value_unit_minutes(s, "debug_log_max_age"),
            debug_max_rows: read_row_cap(s, "debug_log_max_rows", None),
            request_max_age_min: read_value_unit_minutes(s, "request_log_max_age"),
            request_max_rows: request_log_row_cap(s),
        }
    }
}

/// Spawn the upkeep loop. Holds only a `Weak` to the storage so a
/// lock/unlock swap (`with_transport_from`) can drop the old database —
/// and its SQLCipher key material — on schedule; the orphaned task exits
/// on its next poll when the upgrade fails.
pub(super) fn spawn_log_upkeep(handle: &tokio::runtime::Handle,
                               storage: std::sync::Weak<Mutex<Storage>>) {
    handle.spawn(async move {
        // MAX forces a trim on the first poll after launch; thereafter the
        // configured interval gates it.
        let mut since_trim = Duration::MAX;
        loop {
            tokio::time::sleep(POLL).await;
            let Some(storage) = storage.upgrade() else { return };
            since_trim = since_trim.saturating_add(POLL);
            let settings = { LogTrimSettings::read(&*storage.lock().await) };
            if since_trim >= settings.interval {
                run_trim(&storage, &settings).await;
                since_trim = Duration::ZERO;
            }
        }
    });
}

async fn run_trim(storage: &Arc<Mutex<Storage>>, settings: &LogTrimSettings) {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let mut request_deleted = 0usize;
    if let Some(minutes) = settings.request_max_age_min {
        let cutoff_ms = now_ms - (minutes as i64) * 60_000;
        loop {
            let n = { storage.lock().await.trim_request_logs_before(cutoff_ms, BATCH) }
                .unwrap_or(0);
            request_deleted += n;
            if n < BATCH as usize { break; }
        }
    }
    if let Some(max) = settings.request_max_rows {
        loop {
            let n = { storage.lock().await.trim_request_logs_over(max, BATCH) }
                .unwrap_or(0);
            request_deleted += n;
            if n < BATCH as usize { break; }
        }
    }

    let mut debug_deleted = 0usize;
    if let Some(minutes) = settings.debug_max_age_min {
        loop {
            let n = crate::trim_debug_log_before(minutes, BATCH);
            debug_deleted += n;
            if n < BATCH as usize { break; }
        }
    }
    if let Some(max) = settings.debug_max_rows {
        loop {
            let n = crate::trim_debug_log_over(max, BATCH);
            debug_deleted += n;
            if n < BATCH as usize { break; }
        }
    }

    if request_deleted > 0 || debug_deleted > 0 {
        crate::log_info!("upkeep", "log trim: removed {request_deleted} request row(s), {debug_deleted} debug row(s)");
    }
}
