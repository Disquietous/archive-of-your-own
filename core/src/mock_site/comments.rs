//! Generated comment threads. Every chapter of every work has a
//! deterministic set of threads (ids encode work, chapter, and slot so a
//! `/comments/{id}` URL maps straight back), and the viewer's posted
//! comments are merged in from the session state.

use super::data::*;
use super::render::RenderComment;
use super::state::MockState;

const BASE: u64 = 93_000_000;

/// Slot layout per (work, chapter): top-level k in 0..TOPS, replies at
/// k*10 + r + 1 (r in 0..9).
pub fn comment_id(work_idx: usize, chapter: u32, slot: u64) -> u64 {
    BASE + (work_idx as u64) * 100_000 + (chapter as u64) * 1_000 + slot
}

pub fn locate(id: u64) -> Option<(usize, u32, u64)> {
    let rest = id.checked_sub(BASE)?;
    let (work_idx, rest) = ((rest / 100_000) as usize, rest % 100_000);
    let (chapter, slot) = ((rest / 1_000) as u32, rest % 1_000);
    if work_idx >= WORKS.len() || !visible(work_idx) || chapter == 0 || chapter > work(work_idx).chapters { return None; }
    Some((work_idx, chapter, slot))
}

fn top_count(work_idx: usize, chapter: u32) -> u64 {
    let mut rng = Lcg::new(WORKS[work_idx].id * 31 + chapter as u64);
    1 + rng.below(4)
}

/// Date within the work's posting window, deterministic per slot.
fn date_for(work_idx: usize, chapter: u32, slot: u64) -> String {
    let w = &work(work_idx);
    let mut rng = Lcg::new(w.id + chapter as u64 * 97 + slot * 7);
    let year: u32 = w.updated[..4].parse().unwrap_or(2025);
    let month = 1 + rng.below(12) as u32;
    let day = 1 + rng.below(28) as u32;
    format!("{year}-{month:02}-{day:02}")
}

fn chapter_ref(work_idx: usize, chapter: u32) -> (u64, u64, u32) {
    (WORKS[work_idx].id, chapter_id(work_idx, chapter), chapter)
}

/// The generated threads for one chapter. `with_chapter` adds the
/// "on Chapter N" byline span (whole-work views carry it, chapter views
/// do not).
pub fn chapter_threads(work_idx: usize, chapter: u32, with_chapter: bool, state: &MockState) -> Vec<RenderComment> {
    let author = &AUTHORS[WORKS[work_idx].author];
    let chapter_tag = if with_chapter { Some(chapter_ref(work_idx, chapter)) } else { None };
    let mut threads = Vec::new();
    for k in 0..top_count(work_idx, chapter) {
        let mut rng = Lcg::new(WORKS[work_idx].id * 1_000 + chapter as u64 * 10 + k);
        let top_id = comment_id(work_idx, chapter, k * 10);
        let (user, guest) = if rng.below(5) == 0 {
            (None, format!("Visitor {}", 1 + rng.below(40)))
        } else {
            (Some(READERS[rng.below(READERS.len() as u64) as usize].to_string()), String::new())
        };
        let mut replies = Vec::new();
        if rng.below(2) == 0 {
            // The author replies; sometimes the reader replies back.
            let reply_id = comment_id(work_idx, chapter, k * 10 + 1);
            let mut thread = RenderComment {
                id: reply_id, user: Some(author.user.to_string()), guest: String::new(),
                date: date_for(work_idx, chapter, k * 10 + 1),
                text: REPLY_TEXT[rng.below(REPLY_TEXT.len() as u64) as usize].to_string(),
                chapter: chapter_tag, parent: Some(top_id), replies: Vec::new(),
            };
            if rng.below(3) == 0 {
                thread.replies.push(RenderComment {
                    id: comment_id(work_idx, chapter, k * 10 + 2), user: user.clone(), guest: guest.clone(),
                    date: date_for(work_idx, chapter, k * 10 + 2),
                    text: "Thank you for replying! I'll be here for the next one.".to_string(),
                    chapter: chapter_tag, parent: Some(reply_id), replies: Vec::new(),
                });
            }
            replies.push(thread);
        }
        threads.push(RenderComment {
            id: top_id, user, guest, date: date_for(work_idx, chapter, k * 10),
            text: COMMENT_TEXT[rng.below(COMMENT_TEXT.len() as u64) as usize].to_string(),
            chapter: chapter_tag, parent: None, replies,
        });
    }
    merge_posted(&mut threads, work_idx, chapter, with_chapter, state);
    threads
}

/// Attach the viewer's posted comments for one chapter (0 = whole-work
/// posts): new top-level comments at the end, replies under their parent
/// wherever it sits in the tree. A reply belongs to the chapter its
/// parent is in, so each chapter's pass only attaches what it owns.
fn merge_posted(threads: &mut Vec<RenderComment>, work_idx: usize, chapter: u32, with_chapter: bool, state: &MockState) {
    let Some(viewer) = &state.viewer else { return };
    for p in state.comments.iter().filter(|p| p.work_idx == work_idx) {
        let tag = if with_chapter && p.chapter > 0 { Some(chapter_ref(work_idx, p.chapter)) } else { None };
        let rc = super::render::posted_to_render(p, viewer, tag);
        match p.parent {
            Some(parent) if chapter_of(parent, state) == Some(chapter) => { attach(threads, parent, rc); }
            None if p.chapter == chapter => threads.push(rc),
            _ => {}
        }
    }
}

/// Which chapter a comment (generated or posted) lives in; 0 for a
/// whole-work post.
fn chapter_of(id: u64, state: &MockState) -> Option<u32> {
    locate(id).map(|(_, c, _)| c)
        .or_else(|| state.comments.iter().find(|p| p.id == id).map(|p| p.chapter))
}

fn attach(threads: &mut [RenderComment], parent: u64, reply: RenderComment) -> bool {
    for t in threads.iter_mut() {
        if t.id == parent { t.replies.push(reply); return true; }
        if attach(&mut t.replies, parent, reply.clone()) { return true; }
    }
    false
}

/// Every chapter's threads, in chapter order, with "on Chapter N" spans —
/// the whole-work comments endpoint.
pub fn work_threads(work_idx: usize, state: &MockState) -> Vec<RenderComment> {
    let mut all: Vec<RenderComment> = (1..=work(work_idx).chapters)
        .flat_map(|c| chapter_threads(work_idx, c, true, state))
        .collect();
    // Whole-work (chapter 0) posts have no chapter to merge under.
    merge_posted(&mut all, work_idx, 0, true, state);
    all
}

/// The subtree rooted at one comment, for /comments/{id}.
pub fn subtree(id: u64, state: &MockState) -> Option<(usize, RenderComment)> {
    let (work_idx, chapter) = locate(id).map(|(w, c, _)| (w, c))
        .or_else(|| state.comments.iter().find(|p| p.id == id).map(|p| (p.work_idx, p.chapter)))?;
    let threads = if chapter == 0 { work_threads(work_idx, state) } else { chapter_threads(work_idx, chapter, true, state) };
    fn find(threads: &[RenderComment], id: u64) -> Option<RenderComment> {
        for t in threads {
            if t.id == id { return Some(t.clone()); }
            if let Some(f) = find(&t.replies, id) { return Some(f); }
        }
        None
    }
    find(&threads, id).map(|c| (work_idx, c))
}

/// The comment count shown in the stats block: every generated node.
pub fn comment_total(work_idx: usize) -> u64 {
    fn count(threads: &[RenderComment]) -> u64 {
        threads.iter().map(|t| 1 + count(&t.replies)).sum()
    }
    let empty = MockState::default();
    (1..=work(work_idx).chapters).map(|c| count(&chapter_threads(work_idx, c, false, &empty))).sum()
}

/// The work and chapter a posted comment lands on, from its endpoint.
/// `/works/{w}/comments` → (w, 0); `/chapters/{c}/comments` → that
/// chapter; `/comments/{id}/comments` → the parent's chapter.
pub fn target_of_post(path: &[&str], state: &MockState) -> Option<(usize, u32, Option<u64>)> {
    match path {
        ["works", w, "comments"] => Some((work_index(w.parse().ok()?)?, 0, None)),
        ["chapters", c, "comments"] => { let (wi, n) = chapter_from_id(c.parse().ok()?)?; Some((wi, n, None)) }
        ["works", _, "chapters", c, "comments"] => { let (wi, n) = chapter_from_id(c.parse().ok()?)?; Some((wi, n, None)) }
        ["comments", id, "comments"] => {
            let id: u64 = id.parse().ok()?;
            if let Some((wi, ch, _)) = locate(id) { return Some((wi, ch, Some(id))); }
            let p = state.comments.iter().find(|p| p.id == id)?;
            Some((p.work_idx, p.chapter, Some(id)))
        }
        _ => None,
    }
}
