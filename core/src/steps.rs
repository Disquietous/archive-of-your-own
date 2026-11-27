//! The requests one content-queue item needs, under names a reader
//! understands ("Chapter 3: Title" › "Page 2 of 5"), for the queue
//! monitor's second panel.
//!
//! Code that fetches part of a work wraps the fetch in `run` and names
//! what it has learned is still to come with `plan`. Both do nothing
//! outside `recording` — the content queue's worker is the only caller
//! of that, so a reader's own fetch through the same code records
//! nothing. The worker downloads one work of each source at a time, so
//! there is one list a source, kept under the source's id; a source's
//! list is cleared when its work starts and when it ends.

use std::collections::BTreeMap;
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

/// The list of each source with a work in flight, by source id.
static STEPS: Mutex<BTreeMap<String, Steps>> = Mutex::new(BTreeMap::new());

tokio::task_local! {
    /// The source whose list the running task records into.
    static RECORDING: String;
}

fn steps() -> std::sync::MutexGuard<'static, BTreeMap<String, Steps>> {
    STEPS.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The source the running task records for, when it records at all.
fn recording_for() -> Option<String> { RECORDING.try_with(|source| source.clone()).ok() }

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

/// Run `fut` with its steps recorded in `source`'s list.
pub async fn recording<F: std::future::Future>(source: &str, fut: F) -> F::Output {
    RECORDING.scope(source.to_string(), fut).await
}

/// Forget every step of `source`: its work is starting or has ended.
pub fn clear(source: &str) {
    steps().remove(source);
}

/// The steps of `source`'s work in flight, in order.
pub fn snapshot(source: &str) -> Vec<UContentQueueStep> {
    steps().get(source).map(|s| s.list.clone()).unwrap_or_default()
}

/// The steps of every work in flight, in order, by source id.
pub fn snapshot_all() -> std::collections::HashMap<String, Vec<UContentQueueStep>> {
    steps().iter().map(|(source, s)| (source.clone(), s.list.clone())).collect()
}

/// Name steps now known to be coming, under the step being run.
pub fn plan<I: IntoIterator<Item = String>>(labels: I) {
    let Some(source) = recording_for() else { return };
    let mut all = steps();
    let s = all.entry(source).or_insert_with(|| Steps { list: Vec::new(), active: Vec::new() });
    for label in labels {
        let parts = s.under_active(&label);
        s.place(&parts);
    }
    drop(all);
    changed();
}

/// Run one step: active while `fut` runs, then done or failed by its
/// result. Steps run inside it are listed under it.
pub async fn run<T, E, F>(label: &str, fut: F) -> Result<T, E>
where F: std::future::Future<Output = Result<T, E>> {
    let Some(source) = recording_for() else { return fut.await };
    let parts = {
        let mut all = steps();
        let s = all.entry(source.clone()).or_insert_with(|| Steps { list: Vec::new(), active: Vec::new() });
        let parts = s.under_active(label);
        let at = s.place(&parts);
        s.list[at].state = StepState::Active;
        s.active.push(parts.clone());
        parts
    };
    changed();
    let result = fut.await;
    // A list cleared meanwhile (its work ended) is not brought back.
    if let Some(s) = steps().get_mut(&source) {
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

    fn names(source: &str) -> Vec<(String, StepState)> {
        snapshot(source).into_iter().map(|s| (s.parts.join(" > "), s.state)).collect()
    }

    #[tokio::test]
    async fn steps_are_listed_as_they_become_known() {
        const SOURCE: &str = "steps-test-listed";
        // Outside a recording nothing is kept.
        clear(SOURCE);
        let _ = run("Chapter 1", async { Ok::<_, ()>(()) }).await;
        assert!(snapshot(SOURCE).is_empty());

        recording(SOURCE, async {
            let _ = run("Chapter list", async { Ok::<_, ()>(()) }).await;
            plan(["Chapter 1".to_string(), "Chapter 2".to_string()]);
            let _ = run("Chapter 1", async {
                plan(["Page 2 of 2".to_string()]);
                assert_eq!(names(SOURCE), vec![
                    ("Chapter list".to_string(), StepState::Done),
                    ("Chapter 1".to_string(), StepState::Active),
                    ("Chapter 1 > Page 2 of 2".to_string(), StepState::Pending),
                    ("Chapter 2".to_string(), StepState::Pending),
                ]);
                run("Page 2 of 2", async { Err::<(), _>(()) }).await
            }).await;
        }).await;
        assert_eq!(names(SOURCE), vec![
            ("Chapter list".to_string(), StepState::Done),
            ("Chapter 1".to_string(), StepState::Failed),
            ("Chapter 1 > Page 2 of 2".to_string(), StepState::Failed),
            ("Chapter 2".to_string(), StepState::Pending),
        ]);
        clear(SOURCE);
        assert!(snapshot(SOURCE).is_empty());
    }

    #[tokio::test]
    async fn each_source_keeps_its_own_list() {
        const A: &str = "steps-test-a";
        const B: &str = "steps-test-b";
        // Two works in flight at once, their steps interleaved.
        let a = recording(A, async {
            let _ = run("Chapter list", async {
                tokio::task::yield_now().await;
                Ok::<_, ()>(())
            }).await;
            plan(["Chapter 1".to_string()]);
        });
        let b = recording(B, async {
            let _ = run("Story", async {
                tokio::task::yield_now().await;
                Err::<(), _>(())
            }).await;
        });
        tokio::join!(a, b);
        assert_eq!(names(A), vec![
            ("Chapter list".to_string(), StepState::Done),
            ("Chapter 1".to_string(), StepState::Pending),
        ]);
        assert_eq!(names(B), vec![("Story".to_string(), StepState::Failed)]);
        let all = snapshot_all();
        assert_eq!(all.get(A).map(Vec::len), Some(2));
        assert_eq!(all.get(B).map(Vec::len), Some(1));

        // One source's work ending leaves the other's list alone.
        clear(A);
        assert!(snapshot(A).is_empty());
        assert_eq!(names(B).len(), 1);
        clear(B);
    }
}
