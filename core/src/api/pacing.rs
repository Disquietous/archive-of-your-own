//! Pacing for successive downloads — a whole work fetched chapter by
//! chapter, or a list of works downloaded one after another.
//!
//! Every pause is a whole number of seconds drawn from 1..=10, and no
//! two consecutive pauses are the same length: a fixed cadence is what a
//! scripted crawl looks like, and a run of identical waits reads the
//! same way. The state is process-wide, so the rule holds across works
//! in a bulk download, not just within one.

use std::sync::Mutex;
use std::time::Duration;

/// Shortest pause, in seconds.
pub const DOWNLOAD_GAP_MIN_SECS: u64 = 1;
/// Longest pause, in seconds.
pub const DOWNLOAD_GAP_MAX_SECS: u64 = 10;

/// Picks each pause: uniform over the range, excluding the previous pick.
pub struct DownloadPacer {
    last: Option<u64>,
}

impl DownloadPacer {
    pub const fn new() -> Self {
        Self { last: None }
    }

    /// The next pause in seconds, never equal to the one before it.
    pub fn next_secs(&mut self) -> u64 {
        self.next_with(|n| fastrand::u64(0..n))
    }

    /// `pick(n)` returns an index in `0..n`. Excluding the previous value
    /// shrinks the draw by one and skips over it, so every other value in
    /// the range stays equally likely.
    fn next_with(&mut self, pick: impl FnOnce(u64) -> u64) -> u64 {
        let span = DOWNLOAD_GAP_MAX_SECS - DOWNLOAD_GAP_MIN_SECS + 1;
        let secs = match self.last {
            None => DOWNLOAD_GAP_MIN_SECS + pick(span),
            Some(last) => {
                let mut v = DOWNLOAD_GAP_MIN_SECS + pick(span - 1);
                if v >= last {
                    v += 1;
                }
                v
            }
        };
        self.last = Some(secs);
        secs
    }
}

static DOWNLOAD_PACER: Mutex<DownloadPacer> = Mutex::new(DownloadPacer::new());

/// The next pause for a successive download, from the shared pacer.
pub fn next_download_gap() -> Duration {
    let secs = DOWNLOAD_PACER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .next_secs();
    Duration::from_secs(secs)
}

/// Wait out the next pause before the following request of a successive
/// download.
pub async fn download_gap() {
    let gap = next_download_gap();
    log_debug!("pacing", "Download gap: waiting {}s before the next request", gap.as_secs());
    tokio::time::sleep(gap).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_in_range_and_never_repeats_consecutively() {
        let mut pacer = DownloadPacer::new();
        let mut prev = None;
        for _ in 0..5_000 {
            let v = pacer.next_secs();
            assert!((DOWNLOAD_GAP_MIN_SECS..=DOWNLOAD_GAP_MAX_SECS).contains(&v), "{v} out of range");
            assert_ne!(Some(v), prev, "repeated {v} twice in a row");
            prev = Some(v);
        }
    }

    #[test]
    fn every_other_value_is_reachable_after_each_value() {
        // With `last` fixed, the nine draw indices map onto exactly the
        // nine other seconds — none skipped, none doubled.
        for last in DOWNLOAD_GAP_MIN_SECS..=DOWNLOAD_GAP_MAX_SECS {
            let mut seen = Vec::new();
            for index in 0..(DOWNLOAD_GAP_MAX_SECS - DOWNLOAD_GAP_MIN_SECS) {
                let mut pacer = DownloadPacer { last: Some(last) };
                seen.push(pacer.next_with(|_| index));
            }
            seen.sort_unstable();
            let expected: Vec<u64> = (DOWNLOAD_GAP_MIN_SECS..=DOWNLOAD_GAP_MAX_SECS).filter(|v| *v != last).collect();
            assert_eq!(seen, expected, "after {last}");
        }
    }

    #[test]
    fn first_pick_covers_the_whole_range() {
        let mut seen: Vec<u64> = (0..(DOWNLOAD_GAP_MAX_SECS - DOWNLOAD_GAP_MIN_SECS + 1))
            .map(|index| DownloadPacer::new().next_with(|_| index))
            .collect();
        seen.sort_unstable();
        let expected: Vec<u64> = (DOWNLOAD_GAP_MIN_SECS..=DOWNLOAD_GAP_MAX_SECS).collect();
        assert_eq!(seen, expected);
    }

    #[test]
    fn shared_pacer_keeps_the_rule_across_callers() {
        let mut prev = None;
        for _ in 0..1_000 {
            let v = next_download_gap().as_secs();
            assert!((DOWNLOAD_GAP_MIN_SECS..=DOWNLOAD_GAP_MAX_SECS).contains(&v));
            assert_ne!(Some(v), prev);
            prev = Some(v);
        }
    }
}
