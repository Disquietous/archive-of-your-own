//! Pacing for a run of requests made one after another — a whole work
//! fetched chapter by chapter, a list of works downloaded in turn, the
//! details of every work on a listing page. Any process that walks a site
//! request by request waits here between them, so they all share one
//! rhythm.
//!
//! Every pause is a whole number of seconds drawn from 1..=10, and no
//! two consecutive pauses are the same length: a fixed cadence is what a
//! scripted crawl looks like, and a run of identical waits reads the
//! same way. The state is process-wide, so the rule holds across every
//! caller, not just within one loop.

use std::sync::Mutex;
use std::time::Duration;

/// Shortest pause, in seconds.
pub const REQUEST_GAP_MIN_SECS: u64 = 1;
/// Longest pause, in seconds.
pub const REQUEST_GAP_MAX_SECS: u64 = 10;

/// Picks each pause: uniform over the range, excluding the previous pick.
pub struct RequestPacer {
    last: Option<u64>,
}

impl RequestPacer {
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
        let span = REQUEST_GAP_MAX_SECS - REQUEST_GAP_MIN_SECS + 1;
        let secs = match self.last {
            None => REQUEST_GAP_MIN_SECS + pick(span),
            Some(last) => {
                let mut v = REQUEST_GAP_MIN_SECS + pick(span - 1);
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

static REQUEST_PACER: Mutex<RequestPacer> = Mutex::new(RequestPacer::new());

/// The next pause between successive requests, from the shared pacer.
pub fn next_request_gap() -> Duration {
    let secs = REQUEST_PACER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .next_secs();
    Duration::from_secs(secs)
}

/// Wait out the next pause before the following request of a run.
pub async fn request_gap() {
    let gap = next_request_gap();
    log_debug!("pacing", "Request gap: waiting {}s before the next request", gap.as_secs());
    tokio::time::sleep(gap).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_in_range_and_never_repeats_consecutively() {
        let mut pacer = RequestPacer::new();
        let mut prev = None;
        for _ in 0..5_000 {
            let v = pacer.next_secs();
            assert!((REQUEST_GAP_MIN_SECS..=REQUEST_GAP_MAX_SECS).contains(&v), "{v} out of range");
            assert_ne!(Some(v), prev, "repeated {v} twice in a row");
            prev = Some(v);
        }
    }

    #[test]
    fn every_other_value_is_reachable_after_each_value() {
        // With `last` fixed, the nine draw indices map onto exactly the
        // nine other seconds — none skipped, none doubled.
        for last in REQUEST_GAP_MIN_SECS..=REQUEST_GAP_MAX_SECS {
            let mut seen = Vec::new();
            for index in 0..(REQUEST_GAP_MAX_SECS - REQUEST_GAP_MIN_SECS) {
                let mut pacer = RequestPacer { last: Some(last) };
                seen.push(pacer.next_with(|_| index));
            }
            seen.sort_unstable();
            let expected: Vec<u64> = (REQUEST_GAP_MIN_SECS..=REQUEST_GAP_MAX_SECS).filter(|v| *v != last).collect();
            assert_eq!(seen, expected, "after {last}");
        }
    }

    #[test]
    fn first_pick_covers_the_whole_range() {
        let mut seen: Vec<u64> = (0..(REQUEST_GAP_MAX_SECS - REQUEST_GAP_MIN_SECS + 1))
            .map(|index| RequestPacer::new().next_with(|_| index))
            .collect();
        seen.sort_unstable();
        let expected: Vec<u64> = (REQUEST_GAP_MIN_SECS..=REQUEST_GAP_MAX_SECS).collect();
        assert_eq!(seen, expected);
    }

    #[test]
    fn shared_pacer_keeps_the_rule_across_callers() {
        let mut prev = None;
        for _ in 0..1_000 {
            let v = next_request_gap().as_secs();
            assert!((REQUEST_GAP_MIN_SECS..=REQUEST_GAP_MAX_SECS).contains(&v));
            assert_ne!(Some(v), prev);
            prev = Some(v);
        }
    }
}
