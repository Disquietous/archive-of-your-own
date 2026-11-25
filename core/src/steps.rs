//! The requests one content-queue item needs, under names a reader
//! understands ("Chapter 3: Title" › "Page 2 of 5"), for the queue
//! monitor's second panel.
//!
//! Code that fetches part of a work wraps the fetch in `run` and names
//! what it has learned is still to come with `plan`. Both do nothing
//! outside `recording` — the content queue's worker is the only caller
//! of that, so a reader's own fetch through the same code records
//! nothing. The worker downloads one work at a time, so one list is the
//! whole picture; it is cleared when a work starts and when it ends.

use std::sync::Mutex;

/// Where one step stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StepState {
    /// Known to be needed, not yet started.
    Pending,
    /// Its request is out (or being retried).
    Active,
    Done,
    Failed,
}

/// One step of the work in flight.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UContentQueueStep {
    /// The step's name from the outermost part in: ["Chapter 3: Title",
    /// "Page 2 of 5"]. The work itself is not part of it.
    pub parts: Vec<String>,
    pub state: StepState,
}

struct Steps {
    list: Vec<UContentQueueStep>,
    /// The steps being run, outermost first.
    active: Vec<Vec<String>>,
}

static STEPS: Mutex<Steps> = Mutex::new(Steps { list: Vec::new(), active: Vec::new() });

tokio::task_local! {
    static RECORDING: ();
}

fn steps() -> std::sync::MutexGuard<'static, Steps> {
    STEPS.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn recording_now() -> bool { RECORDING.try_with(|_| ()).is_ok() }

fn changed() {
    crate::events::emit(crate::events::CoreEvent::ContentQueueChanged);
}

impl Steps {
    /// The step's place in the list, added in order when it is new: after
    /// its parent's last step, or at the end.
    fn place(&mut self, parts: &[String]) -> usize {
        if let Some(at) = self.list.iter().position(|s| s.parts == parts) {
            return at;
        }
        let parent = &parts[..parts.len() - 1];
        let at = match self.list.iter().rposition(|s| s.parts.starts_with(parent)) {
            Some(last) if !parent.is_empty() => last + 1,
            _ => self.list.len(),
        };
        self.list.insert(at, UContentQueueStep { parts: parts.to_vec(), state: StepState::Pending });
        at
    }

    fn under_active(&self, label: &str) -> Vec<String> {
        let mut parts = self.active.last().cloned().unwrap_or_default();
        parts.push(label.to_string());
        parts
    }
}

/// Run `fut` with its steps recorded.
pub async fn recording<F: std::future::Future>(fut: F) -> F::Output {
    RECORDING.scope((), fut).await
}

/// Forget every step: a work is starting or has ended.
pub fn clear() {
    let mut s = steps();
    s.list.clear();
    s.active.clear();
}

/// The steps of the work in flight, in order.
pub fn snapshot() -> Vec<UContentQueueStep> {
    steps().list.clone()
}

/// Name steps now known to be coming, under the step being run.
pub fn plan<I: IntoIterator<Item = String>>(labels: I) {
    if !recording_now() { return }
    let mut s = steps();
    for label in labels {
        let parts = s.under_active(&label);
        s.place(&parts);
    }
    drop(s);
    changed();
}

/// Run one step: active while `fut` runs, then done or failed by its
/// result. Steps run inside it are listed under it.
pub async fn run<T, E, F>(label: &str, fut: F) -> Result<T, E>
where F: std::future::Future<Output = Result<T, E>> {
    if !recording_now() { return fut.await }
    let parts = {
        let mut s = steps();
        let parts = s.under_active(label);
        let at = s.place(&parts);
        s.list[at].state = StepState::Active;
        s.active.push(parts.clone());
        parts
    };
    changed();
    let result = fut.await;
    {
        let mut s = steps();
        s.active.retain(|p| p != &parts);
        if let Some(step) = s.list.iter_mut().find(|step| step.parts == parts) {
            step.state = if result.is_ok() { StepState::Done } else { StepState::Failed };
        }
    }
    changed();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names() -> Vec<(String, StepState)> {
        snapshot().into_iter().map(|s| (s.parts.join(" > "), s.state)).collect()
    }

    // One test: the list is process-wide.
    #[tokio::test]
    async fn steps_are_listed_as_they_become_known() {
        // Outside a recording nothing is kept.
        clear();
        let _ = run("Chapter 1", async { Ok::<_, ()>(()) }).await;
        assert!(snapshot().is_empty());

        recording(async {
            let _ = run("Chapter list", async { Ok::<_, ()>(()) }).await;
            plan(["Chapter 1".to_string(), "Chapter 2".to_string()]);
            let _ = run("Chapter 1", async {
                plan(["Page 2 of 2".to_string()]);
                assert_eq!(names(), vec![
                    ("Chapter list".to_string(), StepState::Done),
                    ("Chapter 1".to_string(), StepState::Active),
                    ("Chapter 1 > Page 2 of 2".to_string(), StepState::Pending),
                    ("Chapter 2".to_string(), StepState::Pending),
                ]);
                run("Page 2 of 2", async { Err::<(), _>(()) }).await
            }).await;
        }).await;
        assert_eq!(names(), vec![
            ("Chapter list".to_string(), StepState::Done),
            ("Chapter 1".to_string(), StepState::Failed),
            ("Chapter 1 > Page 2 of 2".to_string(), StepState::Failed),
            ("Chapter 2".to_string(), StepState::Pending),
        ]);
        clear();
        assert!(snapshot().is_empty());
    }
}
