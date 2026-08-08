//! The database's single timestamp encoding: UTC "YYYY-MM-DD HH:MM:SS" —
//! the same text SQLite's `datetime('now')` column defaults produce, so
//! every stored timestamp is lexicographically sortable and directly
//! comparable with every other. No chrono dependency; the civil-date math
//! is Howard Hinnant's days-from-civil algorithm.

/// Now, as UTC "YYYY-MM-DD HH:MM:SS".
pub fn now_utc_datetime() -> String {
    epoch_to_datetime(epoch_now())
}

/// Now, as unix seconds.
pub fn epoch_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Unix seconds → UTC "YYYY-MM-DD HH:MM:SS".
pub fn epoch_to_datetime(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// UTC "YYYY-MM-DD HH:MM:SS" → unix seconds. Legacy pure-digit epoch
/// strings (pre-v2 rows, in-flight census state) parse too.
pub fn datetime_to_epoch(s: &str) -> Option<u64> {
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    if t.bytes().all(|b| b.is_ascii_digit()) {
        return t.parse().ok();
    }
    if t.len() < 19 {
        return None;
    }
    let num = |range: std::ops::Range<usize>| t.get(range)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se;
    u64::try_from(secs).ok()
}

/// Days since 1970-01-01 → (year, month, day), proleptic Gregorian.
fn civil_from_days(z: i64) -> (i64, u64, u64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (y + i64::from(m <= 2), m, d)
}

/// (year, month, day) → days since 1970-01-01, proleptic Gregorian.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = y - i64::from(m <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if m > 2 { m - 3 } else { m + 9 } as u64;
    let doy = (153 * mp + 2) / 5 + d as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i64 - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_values() {
        assert_eq!(epoch_to_datetime(0), "1970-01-01 00:00:00");
        assert_eq!(epoch_to_datetime(951_782_400), "2000-02-29 00:00:00");
        assert_eq!(epoch_to_datetime(1_722_556_800), "2024-08-02 00:00:00");
        assert_eq!(datetime_to_epoch("2024-08-02 00:00:00"), Some(1_722_556_800));
        assert_eq!(datetime_to_epoch("1970-01-01 00:00:00"), Some(0));
    }

    #[test]
    fn round_trip() {
        for secs in [1u64, 86_399, 86_400, 1_234_567_890, 1_754_351_999, 4_102_444_800] {
            assert_eq!(datetime_to_epoch(&epoch_to_datetime(secs)), Some(secs), "secs={secs}");
        }
    }

    #[test]
    fn legacy_and_garbage() {
        // Legacy epoch strings still parse.
        assert_eq!(datetime_to_epoch("1722556800"), Some(1_722_556_800));
        assert_eq!(datetime_to_epoch(""), None);
        assert_eq!(datetime_to_epoch("not a date"), None);
    }
}
