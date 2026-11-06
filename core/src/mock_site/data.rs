//! The synthetic archive's catalog: authors, works, series, collections,
//! commenters, and the prose pools that chapters and comments are built
//! from. Everything here is invented — no real AO3 users, works, or text.
//! Ids sit far above anything AO3 has issued so a mock row in a library
//! can never collide with a real one.

pub struct Author {
    pub user: &'static str,
    /// A pseud distinct from the username → bylines render "pseud (user)".
    pub pseud: Option<&'static str>,
    pub numeric_id: u64,
    pub joined: &'static str,
    pub bio: &'static str,
}

pub struct Work {
    pub id: u64,
    pub title: &'static str,
    pub author: usize,
    pub fandoms: &'static [&'static str],
    pub rating: &'static str,
    pub warnings: &'static [&'static str],
    pub categories: &'static [&'static str],
    pub relationships: &'static [&'static str],
    pub characters: &'static [&'static str],
    pub tags: &'static [&'static str],
    pub summary: &'static str,
    pub published: &'static str,
    pub updated: &'static str,
    pub chapters: u32,
    /// None = "?" (open-ended WIP).
    pub total: Option<u32>,
    pub kudos: u32,
    pub hits: u64,
    pub bookmarks: u32,
    /// Chapter index (1-based) that carries an inline image, if any.
    pub image_chapter: Option<u32>,
}

pub struct Series {
    pub id: u64,
    pub title: &'static str,
    pub summary: &'static str,
    /// Work indexes in part order.
    pub works: &'static [usize],
}

pub struct Collection {
    pub name: &'static str,
    pub title: &'static str,
    pub owners: &'static [usize],
    pub summary: &'static str,
    pub kind: &'static str,
    pub active_since: &'static str,
    pub tags: &'static [&'static str],
    pub works: &'static [usize],
}

pub const AUTHORS: &[Author] = &[
    Author { user: "Marrow_and_Moss", pseud: None, numeric_id: 91000001, joined: "2019-04-02",
             bio: "Writes slow tides and slower confessions. Comments are read twice and answered once." },
    Author { user: "quietcartographer", pseud: Some("inkandwaterline"), numeric_id: 91000002, joined: "2017-11-19",
             bio: "Maps of places that do not exist, drawn to scale." },
    Author { user: "LanternfishPress", pseud: None, numeric_id: 91000003, joined: "2021-02-08",
             bio: "Deep-water fiction. Bring your own light." },
    Author { user: "TallowAndTide", pseud: None, numeric_id: 91000004, joined: "2020-08-30",
             bio: "" },
];

pub const READERS: &[&str] = &["driftwoodreader", "pennyfarthing_", "hexmaps", "saltglass", "the_eighth_bell"];

pub const WORKS: &[Work] = &[
    Work { id: 9100001, title: "The Clockwork Tide", author: 0,
           fandoms: &["Saltmarsh Chronicles"], rating: "Teen And Up Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["F/M"],
           relationships: &["Ilse Varren/Tomas Quill"], characters: &["Ilse Varren", "Tomas Quill", "The Harbourmaster"],
           tags: &["Slow Burn", "Lighthouses", "Found Family", "Canon-Typical Weather"],
           summary: "The tide at Saltmarsh runs on gears, and someone has stopped winding it.",
           published: "2025-01-12", updated: "2025-06-30", chapters: 12, total: Some(12),
           kudos: 1842, hits: 40211, bookmarks: 311, image_chapter: None },
    Work { id: 9100002, title: "Salt in the Lamplight", author: 0,
           fandoms: &["Saltmarsh Chronicles"], rating: "Mature",
           warnings: &["Creator Chose Not To Use Archive Warnings"], categories: &["F/M"],
           relationships: &["Ilse Varren/Tomas Quill"], characters: &["Ilse Varren", "Tomas Quill"],
           tags: &["Post-Canon", "Hurt/Comfort", "Winter"],
           summary: "After the tide was mended. Before anyone slept.",
           published: "2025-08-03", updated: "2026-10-21", chapters: 7, total: None,
           kudos: 603, hits: 11870, bookmarks: 98, image_chapter: None },
    Work { id: 9100003, title: "A Grammar of Lighthouses", author: 1,
           fandoms: &["The Hollow Orrery (Original Work)"], rating: "General Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen"],
           relationships: &[], characters: &["The Keeper", "The Apprentice"],
           tags: &["Epistolary", "One Shot", "Worldbuilding"],
           summary: "Twelve letters on the correct conjugation of light.",
           published: "2024-03-14", updated: "2024-03-14", chapters: 1, total: Some(1),
           kudos: 417, hits: 6021, bookmarks: 74, image_chapter: None },
    Work { id: 9100004, title: "Nine Bridges, No Rivers", author: 1,
           fandoms: &["Ninefold Bridge"], rating: "Explicit",
           warnings: &["Graphic Depictions Of Violence"], categories: &["M/M"],
           relationships: &["Aurel Penhallow/Cassian Reed"], characters: &["Aurel Penhallow", "Cassian Reed", "Magistrate Oduya"],
           tags: &["Enemies to Lovers", "Political Intrigue", "Angst with a Happy Ending", "Slow Burn"],
           summary: "Nine bridges span a city with no water. Aurel intends to burn every one of them.",
           published: "2023-09-01", updated: "2025-02-11", chapters: 24, total: Some(24),
           kudos: 5120, hits: 128944, bookmarks: 1205, image_chapter: None },
    Work { id: 9100005, title: "The Orrery Keeper's Apprentice", author: 2,
           fandoms: &["The Hollow Orrery (Original Work)"], rating: "Teen And Up Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen", "F/F"],
           relationships: &["The Apprentice/Wren Ashby"], characters: &["The Apprentice", "Wren Ashby", "The Keeper"],
           tags: &["Coming of Age", "Clockwork", "Mentorship"],
           summary: "An apprentice is given the smallest planet and told not to drop it.",
           published: "2024-06-22", updated: "2024-07-19", chapters: 3, total: Some(3),
           kudos: 288, hits: 4310, bookmarks: 41, image_chapter: None },
    Work { id: 9100006, title: "Letters Never Posted", author: 2,
           fandoms: &["Saltmarsh Chronicles"], rating: "General Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen"],
           relationships: &[], characters: &["The Harbourmaster", "Ilse Varren"],
           tags: &["Epistolary", "Grief/Mourning", "Lists"],
           summary: "Five letters the Harbourmaster wrote and kept in a drawer.",
           published: "2025-03-02", updated: "2025-03-29", chapters: 5, total: Some(5),
           kudos: 150, hits: 2208, bookmarks: 19, image_chapter: None },
    Work { id: 9100007, title: "Wintering", author: 3,
           fandoms: &["Ninefold Bridge"], rating: "Mature",
           warnings: &["No Archive Warnings Apply"], categories: &["Other"],
           relationships: &["Magistrate Oduya & Cassian Reed"], characters: &["Magistrate Oduya", "Cassian Reed"],
           tags: &["Character Study", "Snow", "Introspection"],
           summary: "The Magistrate closes the ninth bridge for the season and does not go home.",
           published: "2025-12-01", updated: "2025-12-01", chapters: 1, total: Some(1),
           kudos: 96, hits: 1407, bookmarks: 12, image_chapter: None },
    Work { id: 9100008, title: "Smallcraft Advisory", author: 3,
           fandoms: &["Saltmarsh Chronicles"], rating: "Teen And Up Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen"],
           relationships: &[], characters: &["Tomas Quill", "Original Characters"],
           tags: &["Boats", "Humor", "Work In Progress"],
           summary: "Tomas buys a boat. The boat has opinions.",
           published: "2026-09-14", updated: "2026-10-28", chapters: 2, total: Some(10),
           kudos: 44, hits: 612, bookmarks: 6, image_chapter: None },
    Work { id: 9100009, title: "What the Cartographer Owed", author: 1,
           fandoms: &["Ninefold Bridge", "The Hollow Orrery (Original Work)"], rating: "Teen And Up Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen"],
           relationships: &[], characters: &["Aurel Penhallow", "The Keeper"],
           tags: &["Crossover", "Debts", "Maps"],
           summary: "A map is a promise about a place. This one was broken on purpose.",
           published: "2025-05-05", updated: "2025-05-05", chapters: 1, total: Some(1),
           kudos: 210, hits: 3390, bookmarks: 27, image_chapter: None },
    Work { id: 9100010, title: "The Long Table", author: 0,
           fandoms: &["Saltmarsh Chronicles"], rating: "Not Rated",
           warnings: &["Creator Chose Not To Use Archive Warnings"], categories: &["Gen"],
           relationships: &[], characters: &["Ilse Varren", "Tomas Quill", "The Harbourmaster", "Original Characters"],
           tags: &["Feast", "Ensemble", "Embedded Images"],
           summary: "Every chair at the long table is taken, and one of them should not be.",
           published: "2025-11-20", updated: "2025-12-18", chapters: 4, total: Some(4),
           kudos: 377, hits: 5100, bookmarks: 58, image_chapter: Some(2) },
    Work { id: 9100011, title: "Fieldnotes from the Hollow", author: 2,
           fandoms: &["The Hollow Orrery (Original Work)"], rating: "Explicit",
           warnings: &["No Archive Warnings Apply"], categories: &["F/F"],
           relationships: &["Wren Ashby/The Apprentice"], characters: &["Wren Ashby", "The Apprentice"],
           tags: &["Established Relationship", "Field Research", "Domestic"],
           summary: "Sixteen entries. The orrery is fine. Everything else is a work in progress.",
           published: "2024-10-10", updated: "2025-04-01", chapters: 16, total: Some(16),
           kudos: 931, hits: 20040, bookmarks: 144, image_chapter: None },
    Work { id: 9100012, title: "Low Water", author: 3,
           fandoms: &["Saltmarsh Chronicles"], rating: "General Audiences",
           warnings: &["No Archive Warnings Apply"], categories: &["Gen"],
           relationships: &[], characters: &["The Harbourmaster"],
           tags: &["Drabble", "Quiet"],
           summary: "One hundred words at the lowest tide of the year.",
           published: "2026-01-02", updated: "2026-01-02", chapters: 1, total: Some(1),
           kudos: 71, hits: 980, bookmarks: 9, image_chapter: None },
];

pub const SERIES: &[Series] = &[
    Series { id: 9200001, title: "The Saltmarsh Cycle",
             summary: "The tide, the town, and the people who keep both running.",
             works: &[0, 1, 11] },
    Series { id: 9200002, title: "Bridgework",
             summary: "Nine bridges and the orrery that charts them.",
             works: &[3, 4] },
];

pub const COLLECTIONS: &[Collection] = &[
    Collection { name: "hollow_orrery_exchange", title: "The Hollow Orrery Exchange", owners: &[2, 1],
                 summary: "Gift works traded between keepers of imaginary planets.",
                 kind: "(Closed, Moderated, Revealed, Gift Exchange Challenge)",
                 active_since: "2024-05-01", tags: &["The Hollow Orrery (Original Work)"],
                 works: &[4, 10, 2] },
    Collection { name: "smallcraft_drabbles", title: "Smallcraft Drabbles", owners: &[3],
                 summary: "Short pieces about small boats and smaller harbours.",
                 kind: "(Open, Unmoderated)",
                 active_since: "2026-01-01", tags: &["Saltmarsh Chronicles", "Drabble"],
                 works: &[7, 11] },
];

/// Chapter titles, cycled by chapter number.
pub const CHAPTER_TITLES: &[&str] = &[
    "The Winding Key", "Low Tide", "A Letter Under the Door", "Gears and Salt",
    "The Harbourmaster's Ledger", "What the Lamp Saw", "High Water", "The Ninth Hour",
    "An Unkept Promise", "Ballast", "The Long Way Round", "Slack Tide",
    "Fog Signals", "The Second Key", "Mooring", "Landfall",
    "Spring Tide", "The Chart Room", "Driftwood", "Halyard",
    "The Quiet Bell", "Soundings", "Last Light", "The Tide Returns",
];

/// Original prose, drawn deterministically by chapter. Plain text; the
/// renderer adds inline markup.
pub const PROSE: &[&str] = &[
    "The harbour woke before the town did. By the time the first shutters opened on Quay Street the gulls had already argued the morning into shape, and the tide, which should have been turning, was not.",
    "Ilse counted the gears twice. The great wheel had forty-one teeth, as it always had, and the escapement ticked with the patience of something that had never once been late. It was the winding that was wrong. Somebody had stopped.",
    "\"You will want to see this,\" said the Harbourmaster, in the voice he used for drownings and taxes. He did not look up from the ledger. He never did, which was how you knew it was serious.",
    "Tomas kept his hands in his pockets the way other men kept them on a rail. It was not that he distrusted the sea. It was that the sea had, on three separate occasions, been proven right.",
    "There is a grammar to lighthouses that the keepers never write down. A long flash is a statement. Two short flashes are a question. Darkness is not a sentence; darkness is the page.",
    "The apprentice held the smallest planet in both hands. It was warm, which nobody had mentioned, and it hummed, which nobody had mentioned either, and it was very slightly heavier than it looked.",
    "Aurel had burned two bridges by midwinter and regretted neither. The third he stood on for an hour in the sleet, trying to decide whether it counted as a bridge at all, given that there was nothing beneath it but the idea of a river.",
    "Cassian wrote to the Magistrate every week and received no answer. He had come to think of the letters as a kind of weather, something that happened whether or not anyone was watching.",
    "The feast had been laid for thirty. Thirty-one came. The Harbourmaster noticed, and said nothing, and moved his own chair to the end of the table where the draught was worst.",
    "Snow fell on the ninth bridge all afternoon. Oduya watched it settle and thought about the difference between closing a thing and ending it, and decided the difference was mostly paperwork.",
    "Wren labelled the jars in a hand so small it looked like a secret. \"Field notes,\" she said, when asked. \"The field is the kitchen. The notes are the jam.\"",
    "The boat was called Opinion. This had seemed funny in the chandlery. It seemed less funny at four in the morning when the Opinion had drifted, unbidden, toward the one rock in the bay that everyone had warned him about.",
    "At the lowest tide of the year you can walk to the old beacon without wetting your boots, provided you do not stop to think about it. Thinking is how the water catches up.",
    "The Keeper had a rule about questions: ask them once, and ask them properly, and then live with the answer long enough to learn whether it was the one you wanted.",
    "\"I did not stop the tide,\" Ilse said. \"I found it stopped. There is a difference, and I will explain it to you as many times as you need, but only if you put the kettle on first.\"",
    "The chart room smelled of lamp oil and consequence. Every map on the wall was accurate; that was the trouble. Nobody draws a true map of a place they intend to go back to.",
];

/// Comment bodies, drawn by seed.
pub const COMMENT_TEXT: &[&str] = &[
    "I read this twice in one sitting and the second time was better. The ledger scene is going to live in my head.",
    "The Harbourmaster moving his own chair. I am not okay.",
    "This is such a careful, kind piece of writing. Thank you for posting it.",
    "Screaming about the last line. Is there going to be more?",
    "\"Darkness is the page\" has no business being that good.",
    "Found this through the series page and now I have to read everything else you've written. No regrets.",
    "The boat being called Opinion is the single funniest thing I have read this month.",
    "I love how patient the pacing is. Nothing is rushed and everything lands.",
    "Reread for the third time. Still crying at the kettle line.",
    "This chapter rearranged something in me and I would like it put back, please. (Kidding. Mostly.)",
];

pub const REPLY_TEXT: &[&str] = &[
    "Thank you! The chair was the first image I had for the whole thing.",
    "There is going to be more. It is just going to take me a while.",
    "This made my week. Thank you for reading so closely.",
    "The kettle line nearly got cut. Glad it stayed.",
];

/// Small deterministic generator so the same page renders identically
/// on every request (the app's caching and diffing depend on that).
pub struct Lcg(u64);

impl Lcg {
    pub fn new(seed: u64) -> Self { Lcg(seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)) }
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    pub fn below(&mut self, n: u64) -> u64 { if n == 0 { 0 } else { self.next() % n } }
}

pub fn author_index(user: &str) -> Option<usize> {
    AUTHORS.iter().position(|a| a.user.eq_ignore_ascii_case(user))
}

pub fn work_index(id: u64) -> Option<usize> {
    WORKS.iter().position(|w| w.id == id)
}

pub fn series_index(id: u64) -> Option<usize> {
    SERIES.iter().position(|s| s.id == id)
}

pub fn collection_index(name: &str) -> Option<usize> {
    COLLECTIONS.iter().position(|c| c.name == name)
}

/// Chapter ids encode (work index, chapter number) so a chapter URL maps
/// back to its work without a lookup table.
pub fn chapter_id(work_idx: usize, chapter: u32) -> u64 {
    95_000_000 + (work_idx as u64) * 100 + chapter as u64
}

pub fn chapter_from_id(id: u64) -> Option<(usize, u32)> {
    let rest = id.checked_sub(95_000_000)?;
    let (idx, n) = ((rest / 100) as usize, (rest % 100) as u32);
    if idx < WORKS.len() && n >= 1 && n <= WORKS[idx].chapters { Some((idx, n)) } else { None }
}

/// Byline as AO3 renders it: "pseud (user)" when the pseud differs.
pub fn byline(a: &Author) -> String {
    match a.pseud {
        Some(p) if p != a.user => format!("{p} ({})", a.user),
        _ => a.user.to_string(),
    }
}

pub fn pseud_of(a: &Author) -> &'static str {
    a.pseud.unwrap_or(a.user)
}

/// Series memberships of a work: (series index, 1-based part).
pub fn memberships(work_idx: usize) -> Vec<(usize, u32)> {
    SERIES.iter().enumerate().filter_map(|(si, s)| {
        s.works.iter().position(|&w| w == work_idx).map(|p| (si, p as u32 + 1))
    }).collect()
}

/// A chapter's paragraphs — plain text, deterministic per (work, chapter).
pub fn chapter_paragraphs(work_idx: usize, chapter: u32) -> Vec<&'static str> {
    let w = &WORKS[work_idx];
    let mut rng = Lcg::new(w.id * 1000 + chapter as u64);
    // Drabbles stay short; serials run 6–11 paragraphs.
    let count = if w.tags.contains(&"Drabble") { 1 } else { 6 + rng.below(6) as usize };
    let start = rng.below(PROSE.len() as u64) as usize;
    (0..count).map(|i| PROSE[(start + i * 3) % PROSE.len()]).collect()
}

/// Approximate word count across all chapters, as the stats block shows.
pub fn word_count(work_idx: usize) -> u64 {
    (1..=WORKS[work_idx].chapters)
        .flat_map(|n| chapter_paragraphs(work_idx, n))
        .map(|p| p.split_whitespace().count() as u64)
        .sum()
}

pub fn chapter_title(work_idx: usize, chapter: u32) -> &'static str {
    CHAPTER_TITLES[((WORKS[work_idx].id as usize) + chapter as usize) % CHAPTER_TITLES.len()]
}
