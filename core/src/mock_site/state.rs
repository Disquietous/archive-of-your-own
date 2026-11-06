//! What the viewer has done to the synthetic archive this session: login,
//! kudos, subscriptions, bookmarks, posted comments, blocks and mutes. A
//! POST changes the state; the next GET renders it — so the app's
//! confirm-then-apply flows see the archive agree with them. Process
//! memory only; cleared whenever the mock is switched off.

use std::collections::HashSet;

#[derive(Clone)]
pub struct Subscription {
    pub id: u64,
    /// "Work" | "Series" | "User"
    pub kind: String,
    /// The AO3 number (work/series) or numeric user id.
    pub target: String,
}

#[derive(Clone)]
pub struct Bookmark {
    pub id: u64,
    /// "Work" | "Series"
    pub kind: String,
    pub number: u64,
    pub note: String,
    pub tags: String,
    pub rec: bool,
    pub private: bool,
    pub date: String,
}

#[derive(Clone)]
pub struct PostedComment {
    pub id: u64,
    pub work_idx: usize,
    /// 0 = whole-work comment (no chapter).
    pub chapter: u32,
    pub parent: Option<u64>,
    pub text: String,
    pub date: String,
}

#[derive(Default)]
pub struct MockState {
    pub viewer: Option<String>,
    pub kudos: HashSet<u64>,
    pub subs: Vec<Subscription>,
    pub bookmarks: Vec<Bookmark>,
    pub comments: Vec<PostedComment>,
    pub blocked: Vec<(String, u64)>,
    pub muted: Vec<(String, u64)>,
    next_id: u64,
}

impl MockState {
    pub fn next_id(&mut self) -> u64 {
        if self.next_id == 0 { self.next_id = 99_000_000; }
        self.next_id += 1;
        self.next_id
    }

    pub fn today() -> String {
        crate::timefmt::now_utc_datetime().split(' ').next().unwrap_or("2026-01-01").to_string()
    }

    /// The viewer's pseud id, as the comment form carries it.
    pub fn viewer_pseud_id(&self) -> String {
        format!("{}", 93_000_000 + self.viewer.as_deref().map(|v| v.len() as u64 * 101).unwrap_or(0))
    }

    pub fn subscription(&self, kind: &str, target: &str) -> Option<u64> {
        self.subs.iter().find(|s| s.kind == kind && s.target == target).map(|s| s.id)
    }

    pub fn subscribe(&mut self, kind: &str, target: &str) -> u64 {
        if let Some(id) = self.subscription(kind, target) { return id; }
        let id = self.next_id();
        self.subs.push(Subscription { id, kind: kind.to_string(), target: target.to_string() });
        id
    }

    /// Remove by record id; returns the record so the page after can show
    /// the create form for the same target.
    pub fn unsubscribe(&mut self, id: u64) -> Option<Subscription> {
        let pos = self.subs.iter().position(|s| s.id == id)?;
        Some(self.subs.remove(pos))
    }

    pub fn moderation(&self, kind: &str, target: &str) -> Option<u64> {
        let list = if kind == "blocked" { &self.blocked } else { &self.muted };
        list.iter().find(|(u, _)| u.eq_ignore_ascii_case(target)).map(|(_, id)| *id)
    }

    pub fn set_moderation(&mut self, kind: &str, target: &str) -> u64 {
        if let Some(id) = self.moderation(kind, target) { return id; }
        let id = self.next_id();
        let list = if kind == "blocked" { &mut self.blocked } else { &mut self.muted };
        list.push((target.to_string(), id));
        id
    }

    pub fn clear_moderation(&mut self, kind: &str, record: u64) -> bool {
        let list = if kind == "blocked" { &mut self.blocked } else { &mut self.muted };
        let before = list.len();
        list.retain(|(_, id)| *id != record);
        list.len() != before
    }

    pub fn add_bookmark(&mut self, kind: &str, number: u64, note: &str, tags: &str, rec: bool, private: bool) -> u64 {
        let id = self.next_id();
        self.bookmarks.push(Bookmark {
            id, kind: kind.to_string(), number, note: note.to_string(), tags: tags.to_string(),
            rec, private, date: Self::today(),
        });
        id
    }

    pub fn remove_bookmark(&mut self, id: u64) -> bool {
        let before = self.bookmarks.len();
        self.bookmarks.retain(|b| b.id != id);
        self.bookmarks.len() != before
    }

    /// The viewer's bookmarks when `user` is the viewer; nobody else's
    /// live here (readers' canned bookmarks come from the catalog).
    pub fn bookmarks_of(&self, user: &str) -> Vec<Bookmark> {
        match &self.viewer {
            Some(v) if v.eq_ignore_ascii_case(user) => self.bookmarks.clone(),
            _ => Vec::new(),
        }
    }

    pub fn add_comment(&mut self, work_idx: usize, chapter: u32, parent: Option<u64>, text: &str) -> u64 {
        let id = self.next_id();
        self.comments.push(PostedComment {
            id, work_idx, chapter, parent, text: text.to_string(), date: Self::today(),
        });
        id
    }
}
