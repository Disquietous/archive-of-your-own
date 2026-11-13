use super::*;
use crate::models::{
    AO3User, BookmarkTarget, Chapter, ContentBlock, ExternalRef, FollowTarget, InlineContent,
    LocalSearchCriteria, Rating, SeriesMembership, Warning, WorkSummary, SOURCE_AO3, SourceUserProfile};

/// A synthetic AO3 work with AO3 number `n`. Its `id` is 0 — the row id is
/// what `save_work` returns. A fresh database allocates row ids 1, 2, 3…
/// in save order, which tests that save `sample_work(1)`, `(2)`, … in
/// that order rely on; everything else uses the returned id.
fn sample_work(n: u64) -> WorkSummary {
    WorkSummary {
        id: 0,
        source: SOURCE_AO3.to_string(),
        external_id: n.to_string(),
        url: format!("https://archiveofourown.org/works/{n}"),
        title: format!("Test Work {n}"),
        authors: vec!["Author1".into(), "Author2".into()],
        fandoms: vec!["Fandom A".into()],
        rating: Rating::Teen,
        warnings: vec![Warning::None],
        categories: vec!["F/M".into()],
        relationships: vec!["A/B".into()],
        characters: vec!["Character A".into()],
        tags: vec!["Fluff".into(), "Angst".into()],
        summary: "A test summary".into(),
        word_count: Some(12_345),
        chapter_count: 3,
        total_chapters: Some(10),
        kudos: Some(42),
        hits: Some(1000),
        bookmarks: Some(5),
        comments: Some(8),
        date_published: "2024-11-02".into(),
        date_updated: "2025-01-15".into(),
        language: "English".into(),
        complete: false,
        series: vec![],
        fetched_at: String::new(),
        author_ids: Vec::new(),
    }
}

fn sample_chapter(number: u32) -> Chapter {
    Chapter {
        id: Some(900 + number as u64),
        title: Some(format!("Chapter {number}")),
        number,
        content: vec![
            ContentBlock::Heading {
                level: 1,
                text: format!("Chapter {number} Title"),
            },
            ContentBlock::Paragraph {
                text: vec![InlineContent::Text {
                    value: "Hello world.".into(),
                }],
            },
        ],
        notes_before: Some("Start notes".into()),
        notes_after: None,
    }
}

fn open_test_db() -> Storage {
    Storage::open_in_memory("test-passphrase").expect("open in-memory db")
}

fn ao3_work_ref(n: u64) -> ExternalRef {
    ExternalRef::ao3(n.to_string(), format!("https://archiveofourown.org/works/{n}"))
}

fn ao3_series_ref(n: u64) -> ExternalRef {
    ExternalRef::ao3(n.to_string(), format!("https://archiveofourown.org/series/{n}"))
}

fn sample_series(n: u64, name: &str) -> crate::models::SeriesSummary {
    crate::models::SeriesSummary {
        id: 0, source: SOURCE_AO3.to_string(), external_id: n.to_string(),
        url: format!("https://archiveofourown.org/series/{n}"), name: name.into(),
        ..Default::default()
    }
}

/// An author follow target, creating the users row when needed.
fn author(db: &Storage, name: &str) -> FollowTarget {
    db.ensure_follow_target("author", name).unwrap().expect("author target")
}

/// A fandom follow target, creating the tag when needed.
fn fandom(db: &Storage, name: &str) -> FollowTarget {
    db.ensure_follow_target("fandom", name).unwrap().expect("fandom target")
}

/// An account row for `username`, created if needed.
fn account(db: &Storage, username: &str) -> i64 {
    db.create_account(username, "cookie").unwrap()
}


/// People are rows keyed by (source, source id); a display name shared
/// across sources never merges them. Works link to their authors' rows,
/// so the same name on an AO3 work and a ScribbleHub story opens two
/// different people.
#[test]
fn test_users_are_source_keyed_not_name_keyed() {
    let db = open_test_db();
    // An AO3 byline row and a ScribbleHub author with the same name.
    let ao3_ids = db.record_author_bylines(&["quill_and_tide".to_string()]).unwrap();
    let sh = AO3User { source: "scribblehub".into(), id: "51230".into(), username: "quill_and_tide".into(),
        profile_url: Some("https://www.scribblehub.com/profile/51230/quill_and_tide/".into()), avatar_url: None };
    let sh_id = db.record_user(&sh).unwrap();
    assert_ne!(ao3_ids[0], sh_id);
    assert_eq!(db.get_user(sh_id).unwrap().source, "scribblehub");
    assert_eq!(db.get_user(ao3_ids[0]).unwrap().source, "ao3");
    assert_eq!(db.get_user_by_key("scribblehub", "51230").map(|u| u.id), Some(sh_id));
    assert_eq!(db.ao3_user_row_id("Quill_And_Tide"), Some(ao3_ids[0]), "AO3 names resolve within AO3, NOCASE");

    // An AO3 work links through its bylines on save; a ScribbleHub work is
    // linked by the caller once its authors are recorded.
    let ao3_work = sample_work(1);
    let w1 = db.save_work(&WorkSummary { authors: vec!["quill_and_tide".into()], ..ao3_work }).unwrap();
    let mut sh_work = sample_work(700_412);
    sh_work.source = "scribblehub".into();
    sh_work.url = "https://www.scribblehub.com/series/700412/the-lighthouse-ledger/".into();
    sh_work.authors = vec!["quill_and_tide".into()];
    let w2 = db.save_work(&sh_work).unwrap();
    assert!(db.work_author_ids(w2).is_empty(), "no name-based linking for a second source");
    db.link_work_authors(w2, &[sh_id]).unwrap();
    assert_eq!(db.work_author_ids(w1), vec![ao3_ids[0]]);
    assert_eq!(db.work_author_ids(w2), vec![sh_id]);
    // The summary the bridge hands out carries the same links.
    assert_eq!(db.get_work(w1).unwrap().unwrap().author_ids, vec![ao3_ids[0]]);
    assert_eq!(db.get_work(w2).unwrap().unwrap().author_ids, vec![sh_id]);
    assert_eq!(db.get_works_by_user(sh_id).unwrap().iter().map(|w| w.id).collect::<Vec<_>>(), vec![w2]);
    assert_eq!(db.get_works_by_user(ao3_ids[0]).unwrap().iter().map(|w| w.id).collect::<Vec<_>>(), vec![w1]);

    // A profile lands on the sourced row under the source's own names;
    // the same value again does not touch updated_at.
    let profile = SourceUserProfile {
        source: "scribblehub".into(), source_id: "51230".into(), username: "quill_and_tide".into(),
        properties: vec![("followers".into(), "48".into()), ("series".into(), "3".into())],
    };
    assert_eq!(db.upsert_user_profile(&profile).unwrap(), sh_id);
    let got = db.get_user(sh_id).unwrap();
    assert_eq!(got.property("followers"), Some("48"));
    assert_eq!(got.field(crate::user_fields::UserField::Works), Some("3"));
    assert!(got.property(crate::user_fields::PROFILE_FETCHED_AT).is_some());
    let stamp = got.properties.iter().find(|p| p.name == "followers").unwrap().updated_at.clone();
    db.set_user_properties(sh_id, &[("followers".into(), "48".into())]).unwrap();
    assert_eq!(db.get_user(sh_id).unwrap().properties.iter().find(|p| p.name == "followers").unwrap().updated_at, stamp);
    let rows: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM user_source_properties p JOIN users u ON u.id = p.user_id WHERE u.source = 'scribblehub'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(rows, 4, "profile_url, followers, series, profile_fetched_at");
    // Every property has its registry row under entity 'user'.
    let unfiled: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM user_source_properties p LEFT JOIN fields f ON f.id = p.field_id
         WHERE f.id IS NULL OR f.entity <> 'user'", [], |r| r.get(0)).unwrap();
    assert_eq!(unfiled, 0);
}

#[test]
fn test_tags_harvested_on_save_work() {
    let db = open_test_db();
    db.save_work(&sample_work(42)).unwrap();

    // sample_work carries authors Author1/Author2 — harvested as creators.
    let creators = db.search_tags("creator", "Author", 10).unwrap();
    assert!(creators.contains(&"Author1".to_string()));
    assert!(creators.contains(&"Author2".to_string()));
    // Wrong type finds nothing.
    assert!(db.search_tags("fandom", "Author", 10).unwrap().is_empty());
}

#[test]
fn test_tags_ranking() {
    let db = open_test_db();
    // Repeat sightings and canonical status must not affect ordering —
    // autocomplete is plain alphabetical.
    for _ in 0..3 { db.upsert_tags(&[("Steve Harrington", "character")]).unwrap(); }
    db.upsert_tags(&[("Ever Steve", "character")]).unwrap();
    db.mark_tags_canonical("character", &["Steve Rogers".to_string()]).unwrap();

    let results = db.search_tags("character", "steve", 10).unwrap();
    assert_eq!(results, vec!["Ever Steve", "Steve Harrington", "Steve Rogers"]);

    // LIKE metacharacters are escaped, not wildcards.
    assert!(db.search_tags("character", "%", 10).unwrap().is_empty());
}

#[test]
fn test_tags_canonical_upsert_preserves_uses() {
    let db = open_test_db();
    for _ in 0..5 { db.upsert_tags(&[("Fluff", "freeform")]).unwrap(); }
    db.mark_tags_canonical("freeform", &["Fluff".to_string()]).unwrap();
    let results = db.search_tags("freeform", "Fluff", 10).unwrap();
    assert_eq!(results, vec!["Fluff".to_string()]);

    // The any-type "tag" endpoint confirms canonicity without clobbering a
    // learned type, and leaves a brand-new name's type unknown.
    db.mark_tags_canonical("tag", &["Fluff".to_string(), "Brand New".to_string()]).unwrap();
    assert_eq!(db.search_tags("freeform", "Fluff", 10).unwrap(),
               vec!["Fluff".to_string()]);
    let new_type: String = db.conn.query_row(
        "SELECT tag_type FROM tags WHERE name = 'Brand New'", [], |r| r.get(0)).unwrap();
    assert_eq!(new_type, "");
    // A later per-type confirm fills the unknown type in.
    db.mark_tags_canonical("fandom", &["Brand New".to_string()]).unwrap();
    assert_eq!(db.search_tags("fandom", "Brand New", 10).unwrap(),
               vec!["Brand New".to_string()]);
}

#[test]
fn test_save_and_load_work() {
    let db = open_test_db();
    let work = sample_work(42);

    let id = db.save_work(&work).expect("save_work");
    assert_eq!(db.resolve_work(SOURCE_AO3, "42"), Some(id));
    // A re-save keys on (source, external_id): same row, same id.
    assert_eq!(db.save_work(&work).unwrap(), id);

    // Retrieve by row id
    let loaded = db.get_work(id).expect("get_work").expect("should exist");
    assert_eq!(loaded.id, id);
    assert_eq!(loaded.source, SOURCE_AO3);
    assert_eq!(loaded.external_id, "42");
    assert_eq!(loaded.url, work.url);
    assert_eq!(loaded.title, work.title);
    assert_eq!(loaded.authors, work.authors);
    assert_eq!(loaded.fandoms, work.fandoms);
    assert_eq!(loaded.rating, work.rating);
    assert_eq!(loaded.warnings, work.warnings);
    assert_eq!(loaded.categories, work.categories);
    assert_eq!(loaded.relationships, work.relationships);
    assert_eq!(loaded.characters, work.characters);
    assert_eq!(loaded.tags, work.tags);
    assert_eq!(loaded.summary, work.summary);
    assert_eq!(loaded.word_count, work.word_count);
    assert_eq!(loaded.chapter_count, work.chapter_count);
    assert_eq!(loaded.total_chapters, work.total_chapters);
    assert_eq!(loaded.kudos, work.kudos);
    assert_eq!(loaded.hits, work.hits);
    assert_eq!(loaded.bookmarks, work.bookmarks);
    assert_eq!(loaded.comments, work.comments);
    assert_eq!(loaded.date_updated, work.date_updated);
    assert_eq!(loaded.language, work.language);
    assert_eq!(loaded.complete, work.complete);

    // get_all_works
    let work2 = sample_work(99);
    db.save_work(&work2).expect("save second work");
    let all = db.get_all_works().expect("get_all_works");
    assert_eq!(all.len(), 2);

    // Missing work
    assert!(db.get_work(9999).expect("get missing").is_none());

    // Delete cascades
    db.save_chapter(id, &sample_chapter(1)).unwrap();
    db.save_progress(id, 1, 250).unwrap();
    db.add_bookmark(id).unwrap();
    db.add_to_history(id).unwrap();

    db.delete_work(id).expect("delete_work");
    assert!(db.get_work(id).expect("after delete").is_none());
    assert!(db.resolve_work(SOURCE_AO3, "42").is_none());
    assert!(db.get_chapters(id).expect("chapters after delete").is_empty());
    assert!(db.get_progress(id).expect("progress after delete").is_none());
    assert!(!db.is_bookmarked(id).expect("bookmark after delete"));
    assert!(db.get_history().expect("history after delete").is_empty());
}

#[test]
fn test_chapters() {
    let db = open_test_db();
    let work = sample_work(1);
    db.save_work(&work).unwrap();

    let ch1 = sample_chapter(1);
    let ch2 = sample_chapter(2);
    db.save_chapter(1, &ch1).unwrap();
    db.save_chapter(1, &ch2).unwrap();

    let chapters = db.get_chapters(1).unwrap();
    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[0].number, 1);
    assert_eq!(chapters[1].number, 2);
    assert_eq!(chapters[0].content.len(), 2); // Heading + Paragraph

    // Single chapter lookup
    let single = db.get_chapter(1, 2).unwrap().unwrap();
    assert_eq!(single.number, 2);
    assert_eq!(single.title.as_deref(), Some("Chapter 2"));

    // Missing chapter
    assert!(db.get_chapter(1, 99).unwrap().is_none());

    // Overwrite existing chapter
    let mut ch1_updated = sample_chapter(1);
    ch1_updated.title = Some("Updated Title".into());
    db.save_chapter(1, &ch1_updated).unwrap();
    let reloaded = db.get_chapter(1, 1).unwrap().unwrap();
    assert_eq!(reloaded.title.as_deref(), Some("Updated Title"));
}

#[test]
fn test_bookmarks() {
    let db = open_test_db();

    assert!(!db.is_bookmarked(1).unwrap());
    assert!(db.get_bookmarks().unwrap().is_empty());

    // A bookmark needs its target row (trigger-enforced).
    assert!(db.add_bookmark(1).is_err());
    db.save_work(&sample_work(1)).unwrap();
    db.save_work(&sample_work(2)).unwrap();
    db.add_bookmark(1).unwrap();
    assert!(db.is_bookmarked(1).unwrap());

    db.add_bookmark(2).unwrap();
    let bm = db.get_bookmarks().unwrap();
    assert_eq!(bm.len(), 2);

    db.remove_bookmark(1).unwrap();
    assert!(!db.is_bookmarked(1).unwrap());
    assert_eq!(db.get_bookmarks().unwrap().len(), 1);
}

#[test]
fn test_search_local_bookmarks_filtered() {
    let db = open_test_db();
    // Work 1: sample defaults — English, 12,345 words, tags Fluff/Angst,
    // updated 2025-01-15. Work 2: German long-fic variant.
    db.save_work(&sample_work(1)).unwrap();
    let mut b = sample_work(2);
    b.title = "Another Story".into();
    b.tags = vec!["Slow Burn".into()];
    b.word_count = Some(100_000);
    b.language = "Deutsch".into();
    b.date_updated = "2026-08-01".into();
    db.save_work(&b).unwrap();

    // Own bookmark on work 1 (rec, own tag); a fetched listing's bookmark
    // by another user on work 2.
    db.update_bookmark_details(1, "great fic", "Comfort Read", "", false, true).unwrap();
    db.cache_fetched_bookmark("OtherUser", 2, 999, "note from a friend", "Favorite", false).unwrap();
    // A bookmark of a work that was never cached has no referent — the
    // target-exists trigger rejects it.
    assert!(db.cache_fetched_bookmark("OtherUser", 3, 1000, "work not cached", "", false).is_err());

    let ids = |c: &crate::models::BookmarkSearchCriteria| -> Vec<u64> {
        db.search_local_bookmarks_filtered(c, 0).unwrap().iter().map(|h| h.target.id()).collect()
    };
    type C = crate::models::BookmarkSearchCriteria;

    // Blank criteria: every cached bookmark with a cached work.
    let mut all = ids(&C::default());
    all.sort();
    assert_eq!(all, vec![1, 2]);

    // Work-side criteria.
    let c = C { bookmarkable_query: "Another".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = C { other_tag_names: "Fluff".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    let c = C { word_count: ">50000".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    // Library language matching is by display name, case-insensitive.
    let c = C { language_id: "english".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);

    // Bookmark-side criteria.
    let c = C { rec: true, ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    let c = C { bookmark_notes: "friend".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = C { bookmarker: "OtherUser".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let mut c = C { other_bookmark_tag_names: "Comfort Read".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    c.other_bookmark_tag_names = "Favorite".into();
    assert_eq!(ids(&c), vec![2]);

    // Hits carry the bookmark's own fields alongside the work blurb.
    let c = C { bookmarker: "OtherUser".into(), ..Default::default() };
    let hit = &db.search_local_bookmarks_filtered(&c, 0).unwrap()[0];
    assert_eq!(hit.bookmarker, "otheruser");
    assert_eq!(hit.note, "note from a friend");
    assert_eq!(hit.tags, vec!["Favorite".to_string()]);
    assert!(!hit.rec);
    assert_eq!(hit.work.as_ref().unwrap().title, "Another Story");

    // A series bookmark: cached with its series row, matched by the type
    // filter and by name/author queries; work-tag and language filters
    // exclude it (series carry neither).
    let c = C { bookmarkable_type: "Series".into(), ..Default::default() };
    assert!(ids(&c).is_empty());
    let saga = db.save_series(&crate::models::SeriesSummary {
        authors: vec!["SagaWriter".into()], summary: "Epic.".into(), word_count: 250_000,
        work_count: 4, complete: false, date_updated: "2026-07-01".into(),
        ..sample_series(77, "A Long Saga")
    }).unwrap();
    assert_eq!(db.resolve_series(SOURCE_AO3, "77"), Some(saga));
    db.cache_fetched_bookmark_for("OtherUser", BookmarkTarget::Series(saga), 1001,
                                  "saga note", "", true).unwrap();
    assert_eq!(ids(&c), vec![saga]);
    let hit = &db.search_local_bookmarks_filtered(&c, 0).unwrap()[0];
    assert!(hit.work.is_none());
    assert_eq!(hit.series.as_ref().unwrap().name, "A Long Saga");
    let c = C { bookmarkable_query: "SagaWriter".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![saga]);
    let c = C { other_tag_names: "Fluff".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    let c = C { language_id: "english".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    let c = C { bookmarkable_type: "Work".into(), ..Default::default() };
    let mut w = ids(&c); w.sort();
    assert_eq!(w, vec![1, 2]);
    // External-work bookmarks are never cached.
    let c = C { bookmarkable_type: "External Work".into(), ..Default::default() };
    assert!(ids(&c).is_empty());
    db.delete_series(saga).unwrap();
    assert!(db.resolve_series(SOURCE_AO3, "77").is_none());

    // Sort by word count, AO3-style descending.
    let c = C { sort_column: "word_count".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2, 1]);
}

#[test]
fn test_reading_progress() {
    let db = open_test_db();

    assert!(db.get_progress(1).unwrap().is_none());

    // Position lives on the works row — a work never opened has none.
    db.save_work(&sample_work(1)).unwrap();
    assert!(db.get_progress(1).unwrap().is_none());

    db.save_progress(1, 3, 750).unwrap();
    let (ch, pos) = db.get_progress(1).unwrap().unwrap();
    assert_eq!(ch, 3);
    assert_eq!(pos, 750);

    // Overwrite
    db.save_progress(1, 4, 10).unwrap();
    let (ch2, pos2) = db.get_progress(1).unwrap().unwrap();
    assert_eq!(ch2, 4);
    assert_eq!(pos2, 10);

    // Clearing resets both columns; the work stays cached.
    db.delete_progress(1).unwrap();
    assert!(db.get_progress(1).unwrap().is_none());
    assert!(db.get_work(1).unwrap().is_some());
    assert!(db.get_all_progress().unwrap().is_empty());
}

#[test]
fn test_history() {
    let db = open_test_db();
    assert!(db.get_history().unwrap().is_empty());

    // History references work rows.
    assert!(db.add_to_history(10).is_err());
    let a = db.save_work(&sample_work(10)).unwrap();
    let b = db.save_work(&sample_work(20)).unwrap();
    db.add_to_history(a).unwrap();
    db.add_to_history(b).unwrap();
    db.add_to_history(a).unwrap(); // duplicate — allowed

    let hist = db.get_history().unwrap();
    assert_eq!(hist.len(), 3);
    // Most recent first
    assert_eq!(hist[0].0, a);
    assert_eq!(hist[1].0, b);
    assert_eq!(hist[2].0, a);

    db.clear_history().unwrap();
    assert!(db.get_history().unwrap().is_empty());
}

#[test]
fn test_subscriptions_persistence() {
    let db = open_test_db();
    let me = account(&db, "Me");
    let other = account(&db, "Other");
    // The same username signs in again: same row.
    assert_eq!(account(&db, "me"), me);

    assert!(db.get_subscriptions(me).unwrap().is_empty());
    // Subscriptions belong to an account row.
    assert!(db.add_subscription(999, "work", "1", "W", None).is_err());

    let subs = vec![
        ("author".into(), "coolwriter".into(), "CoolWriter".into(), Some("111".into())),
        ("work".into(), "12345".into(), "My Fic".into(), None),
    ];
    db.save_subscriptions(me, &subs).unwrap();
    let loaded = db.get_subscriptions(me).unwrap();
    assert_eq!(loaded.len(), 2);
    assert_eq!(db.get_subscription_ao3_id(me, "author", "coolwriter").unwrap().as_deref(), Some("111"));
    // Target ids match case-insensitively.
    assert_eq!(db.get_subscription_ao3_id(me, "author", "CoolWriter").unwrap().as_deref(), Some("111"));
    assert_eq!(db.get_subscription_ao3_id(me, "work", "12345").unwrap(), None);
    assert!(db.has_subscription(me, "work", "12345").unwrap());
    assert!(!db.has_subscription(me, "work", "99999").unwrap());

    // Single add/remove.
    db.add_subscription(me, "work", "555", "Another Fic", Some("222")).unwrap();
    assert_eq!(db.get_subscription_ao3_id(me, "work", "555").unwrap().as_deref(), Some("222"));
    db.remove_subscription(me, "work", "555").unwrap();
    assert!(!db.has_subscription(me, "work", "555").unwrap());

    // Lists are per account: another account's rows are invisible, and
    // replacing one account's list leaves the other's alone.
    db.save_subscriptions(other, &[("work".into(), "1".into(), "Theirs".into(), None)]).unwrap();
    assert!(!db.has_subscription(me, "work", "1").unwrap());
    let subs2 = vec![("series".into(), "99".into(), "Big Series".into(), None)];
    db.save_subscriptions(me, &subs2).unwrap();
    assert_eq!(db.get_subscriptions(me).unwrap().len(), 1);
    assert_eq!(db.get_subscriptions(other).unwrap().len(), 1);
    // Removing an account takes its subscriptions with it.
    db.delete_account(other).unwrap();
    let n: i64 = db.conn.query_row("SELECT COUNT(*) FROM subscriptions", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 1);
}

#[test]
fn test_accounts_are_active_per_source() {
    let db = open_test_db();
    let ao3 = account(&db, "Alice");
    db.set_active_account(ao3).unwrap();
    db.add_subscription(ao3, "work", "1", "W", None).unwrap();

    // A sign-in at another source: its own active account, its own login
    // cookie, and AO3's account and its subscriptions untouched.
    let cookies = "wordpress_logged_in_abc=token; wordpress_sec_abc=s";
    let first = db.create_account_at("scribblehub", "70412", "quillfeather", cookies).unwrap();
    db.set_active_account(first).unwrap();
    assert!(db.has_subscription(ao3, "work", "1").unwrap());
    assert_eq!(db.get_active_account().unwrap().map(|a| a.id), Some(ao3));
    assert_eq!(db.get_active_account_at("scribblehub").unwrap().map(|a| a.id), Some(first));
    assert!(db.signed_in_at("scribblehub"));
    assert_eq!(db.get_active_accounts().unwrap().len(), 2);

    // The same account signing in again reuses its row, by its key.
    assert_eq!(db.create_account_at("scribblehub", "70412", "quill", cookies).unwrap(), first);
    assert_eq!(db.get_account(first).unwrap().unwrap().username, "quill");

    // A second account there takes over as active; AO3 still untouched.
    let second = db.create_account_at("scribblehub", "70413", "inkwell", "").unwrap();
    db.set_active_account(second).unwrap();
    assert_eq!(db.get_active_account_at("scribblehub").unwrap().map(|a| a.id), Some(second));
    assert!(!db.get_account(second).unwrap().unwrap().logged_in(), "no login cookie stored");
    assert!(db.has_subscription(ao3, "work", "1").unwrap());

    // An AO3 cookie name proves nothing at another source, and back.
    let wrong = db.create_account_at("scribblehub", "70414", "x", "remember_user_token=t").unwrap();
    assert!(!db.get_account(wrong).unwrap().unwrap().logged_in());

    // Signing the other source out leaves AO3's subscriptions alone.
    db.clear_account_cookies(first).unwrap();
    db.delete_account(second).unwrap();
    assert!(db.has_subscription(ao3, "work", "1").unwrap());
}

#[test]
fn test_subscriptions_cleared_on_account_transitions() {
    let db = open_test_db();
    let a = account(&db, "Alice");
    let b = account(&db, "Bob");
    db.set_active_account(a).unwrap();
    let active = db.subscription_account().unwrap();
    assert_eq!((active.id, active.username.as_str(), active.external_id.as_str()), (a, "Alice", "alice"));
    db.add_subscription(a, "work", "1", "W", None).unwrap();

    // Re-activating the same account keeps the data.
    db.set_active_account(a).unwrap();
    assert!(db.has_subscription(a, "work", "1").unwrap());

    // Switching accounts empties every subscription row. Active is per
    // source: exactly one AO3 account is active.
    db.set_active_account(b).unwrap();
    assert_eq!(db.get_subscriptions(a).unwrap().len(), 0);
    assert_eq!(db.subscription_account().map(|x| x.id), Some(b));
    let actives: i64 = db.conn.query_row("SELECT COUNT(*) FROM accounts WHERE is_active = 1", [], |r| r.get(0)).unwrap();
    assert_eq!(actives, 1);

    // Signing the active account out empties them; signing out another
    // account doesn't.
    db.add_subscription(b, "work", "2", "W", None).unwrap();
    db.clear_account_cookies(a).unwrap();
    assert!(db.has_subscription(b, "work", "2").unwrap());
    db.clear_account_cookies(b).unwrap();
    assert!(!db.has_subscription(b, "work", "2").unwrap());

    // Removing the active account empties them; with no active account
    // there is no subscription account.
    db.add_subscription(b, "work", "3", "W", None).unwrap();
    db.delete_account(b).unwrap();
    assert!(db.get_account(b).unwrap().is_none());
    db.delete_account(a).unwrap();
    assert!(db.subscription_account().is_none());
    assert!(db.get_all_accounts().unwrap().is_empty());
}

#[test]
fn test_unfollowed_subscriptions() {
    let db = open_test_db();
    let me = account(&db, "me");
    let other = account(&db, "other");
    db.save_subscriptions(me, &[
        ("author".into(), "Writer".into(), "Writer".into(), None),
        ("work".into(), "10".into(), "Followed Fic".into(), None),
        ("series".into(), "20".into(), "A Series".into(), None),
    ]).unwrap();
    db.save_subscriptions(other, &[("work".into(), "30".into(), "Theirs".into(), None)]).unwrap();
    // A followed work the library never fetched is a stub row.
    let w10 = db.ensure_work_stub(&ao3_work_ref(10), "Followed Fic").unwrap();
    assert!(db.is_work_stub(w10));
    db.add_follow(FollowTarget::Work(w10), "Followed Fic").unwrap();
    // Matched case-insensitively.
    db.add_follow(author(&db, "writer"), "writer").unwrap();
    // A follow without a subscription is normal and never listed.
    let w40 = db.ensure_work_stub(&ao3_work_ref(40), "Just Followed").unwrap();
    db.add_follow(FollowTarget::Work(w40), "Just Followed").unwrap();

    let missing = db.get_unfollowed_subscriptions(me).unwrap();
    assert_eq!(missing.len(), 1);
    assert_eq!((missing[0].0.as_str(), missing[0].1.as_str()), ("series", "20"));
}

#[test]
fn test_has_ao3_user_with_username() {
    let db = open_test_db();

    assert!(!db.has_ao3_user_with_username("astolat").unwrap());

    db.record_user(&AO3User::ao3("astolat", "astolat",
        Some("https://archiveofourown.org/users/astolat".into()), None)).unwrap();

    assert!(db.has_ao3_user_with_username("astolat").unwrap());
    // Username match is case-insensitive
    assert!(db.has_ao3_user_with_username("Astolat").unwrap());
    assert!(!db.has_ao3_user_with_username("someone_else").unwrap());
}

#[test]
fn test_user_profile_round_trip() {
    use crate::user_fields::{UserField as F, AO3_MUTE_RECORD, AO3_BLOCK_RECORD, PROFILE_FETCHED_AT};
    let db = open_test_db();

    assert!(db.get_ao3_user_record("writer").is_none());

    let bio = vec![ContentBlock::Paragraph { text: vec![InlineContent::Text { value: "Hello.".into() }] }];
    let profile = SourceUserProfile {
        source: crate::models::SOURCE_AO3.to_string(), source_id: "Writer".into(), username: "Writer".into(),
        properties: vec![
            ("numeric_id".into(), "424242".into()),
            ("avatar_url".into(), "https://example.org/icon.png".into()),
            ("pseuds".into(), serde_json::to_string(&["Writer", "AltPseud"]).unwrap()),
            ("joined".into(), "2015-01-02".into()),
            ("location".into(), "The Library".into()),
            ("bio".into(), serde_json::to_string(&bio).unwrap()),
            ("works".into(), "12".into()), ("series".into(), "3".into()), ("bookmarks".into(), "40".into()),
            ("collections".into(), "1".into()), ("gifts".into(), "2".into()),
            ("muted".into(), "1".into()), (AO3_MUTE_RECORD.into(), "88".into()),
        ],
    };
    let id = db.upsert_user_profile(&profile).unwrap();

    // Case-insensitive lookup within AO3; the pseud resolves to the account.
    let got = db.get_ao3_user_record("writer").expect("cached profile");
    assert_eq!(got.id, id);
    assert_eq!(got.username, "Writer");
    assert_eq!(got.field(F::NumericId), Some("424242"));
    assert_eq!(got.field(F::Joined), Some("2015-01-02"));
    assert_eq!(got.field(F::Location), Some("The Library"));
    assert_eq!(got.field(F::Works), Some("12"));
    assert_eq!(got.field(F::Gifts), Some("2"));
    assert!(got.field(F::Muted).is_some());
    assert_eq!(got.property(AO3_MUTE_RECORD), Some("88"));
    assert!(got.property(PROFILE_FETCHED_AT).is_some());
    assert_eq!(got.field(F::ProfileUrl), Some("https://archiveofourown.org/users/Writer"));
    assert_eq!(db.get_ao3_user_record("AltPseud").map(|u| u.id), Some(id));
    let parsed: Vec<ContentBlock> = serde_json::from_str(got.field(F::Info).unwrap()).unwrap();
    assert_eq!(parsed.len(), 1);

    // Block/mute state updates stick, and clear cleanly.
    db.set_user_block_state("Writer", true, Some("55")).unwrap();
    let got = db.get_ao3_user_record("Writer").unwrap();
    assert!(got.field(F::Blocked).is_some());
    assert_eq!(got.property(AO3_BLOCK_RECORD), Some("55"));
    db.set_user_mute_state("Writer", false, None).unwrap();
    let got = db.get_ao3_user_record("Writer").unwrap();
    assert!(got.field(F::Muted).is_none());
    assert!(got.property(AO3_MUTE_RECORD).is_none());

    // Block state for a never-seen user creates the row, but no profile
    // fetch is faked.
    db.set_user_block_state("stranger", true, None).unwrap();
    let stranger = db.get_ao3_user_record("stranger").unwrap();
    assert!(stranger.property(PROFILE_FETCHED_AT).is_none());
    assert!(db.has_ao3_user_with_username("stranger").unwrap());
}

#[test]
fn test_follow_check_state() {
    let db = open_test_db();
    // Nothing known yet: no target at all. Writes need a target row, which
    // ensure_follow_target makes for authors — but a target is not a follow.
    assert!(db.follow_target("author", "u").is_none());
    let u = author(&db, "u");
    assert!(db.get_follow_baseline(u).unwrap().is_none());
    assert_eq!(db.get_follow_census_meta(u).unwrap(), (None, None, None));
    db.set_follow_last_checked(u, "2026-08-11 01:00:00").unwrap();
    assert!(!db.is_followed(u).unwrap());

    assert!(db.add_follow(author(&db, "U"), "U").unwrap());
    assert_eq!(author(&db, "U"), u, "NOCASE key: one users row");
    assert!(!db.add_follow(u, "u").unwrap(), "already followed");
    assert!(db.get_follow_baseline(u).unwrap().is_none(), "never checked = first run");

    // Each column updates independently.
    db.set_follow_baseline(u, "2025-06-01").unwrap();
    db.set_follow_total_works(u, 42).unwrap();
    db.set_follow_last_census(u, "2026-01-01 00:00:00").unwrap();
    db.set_follow_census_state(u, Some("{\"next_page\":3}")).unwrap();
    db.set_follow_last_checked(u, "2026-08-11 02:00:00").unwrap();
    assert_eq!(db.get_follow_baseline(u).unwrap().as_deref(), Some("2025-06-01"));
    let (total, last, state) = db.get_follow_census_meta(u).unwrap();
    assert_eq!(total, Some(42));
    assert_eq!(last.as_deref(), Some("2026-01-01 00:00:00"));
    assert_eq!(state.as_deref(), Some("{\"next_page\":3}"));
    assert_eq!(db.get_follow_last_checked(u).unwrap().as_deref(), Some("2026-08-11 02:00:00"));
    db.set_follow_census_state(u, None).unwrap();
    assert!(db.get_follow_census_meta(u).unwrap().2.is_none());

    // Unfollowing takes the check state with it.
    assert!(db.remove_follow(u).unwrap());
    assert!(db.get_follow_last_checked(u).unwrap().is_none());
    assert!(db.add_follow(u, "u").unwrap());
    assert!(db.get_follow_baseline(u).unwrap().is_none());

    // A follow needs its target row: the trigger rejects an unknown work.
    assert!(db.add_follow(FollowTarget::Work(9999), "ghost").is_err());
}

#[test]
fn test_follow_not_found_status() {
    let db = open_test_db();
    let gone = author(&db, "Gone");
    let w7 = db.ensure_work_stub(&ao3_work_ref(7), "Kept").unwrap();
    let kept = FollowTarget::Work(w7);
    assert!(db.add_follow(gone, "Gone").unwrap());
    assert!(db.add_follow(kept, "Kept").unwrap());
    assert_eq!(db.get_follow_status(gone).unwrap(), 0);

    // Consecutive 404s count up; a successful fetch resets the streak.
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), 1);
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), 2);
    db.reset_follow_status(gone).unwrap();
    assert_eq!(db.get_follow_status(gone).unwrap(), 0);

    // Reaching the limit excludes it from checks; the follow stays.
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), 1);
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), 2);
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), -1);
    assert_eq!(db.record_follow_not_found(gone, 3).unwrap(), -1, "excluded stays excluded");
    assert!(db.is_followed(gone).unwrap());
    let targets: Vec<FollowTarget> = db.get_check_targets().unwrap().into_iter().map(|t| t.target).collect();
    assert_eq!(targets, vec![kept]);
    let row = &db.get_follows(Some("author")).unwrap()[0];
    assert_eq!(row.status, -1);
    let FollowTarget::Author(gone_row) = gone else { panic!("author target") };
    assert_eq!((row.target, row.bridge_id.as_str()), (gone, gone_row.to_string().as_str()));

    // Limit 0 = never exclude.
    for n in 1..=10 {
        assert_eq!(db.record_follow_not_found(kept, 0).unwrap(), n);
    }
}

#[test]
fn test_check_targets_and_crawl_stamps() {
    let db = open_test_db();
    db.add_follow(fandom(&db, "Some Fandom"), "Some Fandom").unwrap();
    let w10 = db.ensure_work_stub(&ao3_work_ref(10), "beta Work").unwrap();
    db.add_follow(FollowTarget::Work(w10), "beta Work").unwrap();
    let zed = author(&db, "zed");
    db.add_follow(zed, "zed").unwrap();
    let s5 = db.ensure_series(&ao3_series_ref(5), "Alpha Series").unwrap();
    db.add_follow(FollowTarget::Series(s5), "Alpha Series").unwrap();
    // Fandoms are followed but never checked; sorted by name, ignoring case.
    let targets: Vec<String> = db.get_check_targets().unwrap().into_iter().map(|t| t.name).collect();
    assert_eq!(targets, vec!["Alpha Series", "beta Work", "zed"]);
    // Bridge ids: row ids for works, series and authors (the users row),
    // the tag name for fandoms.
    let bridge: Vec<(String, String)> = db.get_follows(None).unwrap().into_iter()
        .map(|f| (f.target.kind().to_string(), f.bridge_id)).collect();
    assert_eq!(bridge, vec![
        ("fandom".to_string(), "Some Fandom".to_string()),
        ("work".to_string(), w10.to_string()),
        ("author".to_string(), db.ao3_user_row_id("zed").unwrap().to_string()),
        ("series".to_string(), s5.to_string()),
    ]);
    for (kind, id) in &bridge {
        assert!(db.follow_target(kind, id).is_some(), "{kind} {id} resolves back");
    }

    assert!(db.get_works_crawled_at(zed).unwrap().is_none());
    // Case variants of the username name the same users row.
    db.set_works_crawled_at(author(&db, "Zed"), "2026-01-01 00:00:00").unwrap();
    db.set_works_crawled_at(zed, "2026-02-01 00:00:00").unwrap();
    assert_eq!(db.get_works_crawled_at(author(&db, "ZED")).unwrap().as_deref(), Some("2026-02-01 00:00:00"));
    assert_eq!(db.follow_target("author", "ZED"), Some(zed));
}

#[test]
fn test_collections_cache_and_library_search() {
    let db = open_test_db();
    let c = crate::models::CollectionSummary {
        source: SOURCE_AO3.to_string(),
        url: "https://archiveofourown.org/collections/test_fest".into(),
        name: "test_fest".into(),
        title: "Test Fest 2026".into(),
        summary: "A synthetic collection".into(),
        is_open: true,
        is_moderated: false,
        is_anonymous: false,
        work_count: 12,
        bookmarked_count: 3,
        maintainers: vec!["mod_one".into()],
        tags: Vec::new(),
        collection_type: "Prompt Meme Challenge".into(),
    };
    db.save_collections(std::slice::from_ref(&c)).unwrap();

    // Substring hit on title; full round trip including maintainers.
    let hits = db.search_collections("fest", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0], c);
    // Maintainer names are searchable too.
    assert_eq!(db.search_collections("mod_one", 10).unwrap().len(), 1);

    // Re-saving the same slug updates instead of duplicating.
    let mut updated = c.clone();
    updated.work_count = 20;
    db.save_collections(std::slice::from_ref(&updated)).unwrap();
    let hits = db.search_collections("fest", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].work_count, 20);

    // LIKE metacharacters are literal.
    assert!(db.search_collections("%", 10).unwrap().is_empty());
}

#[test]
fn test_library_scoped_searches() {
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap();

    // Works: title, tag, and summary substrings all hit; misses miss.
    assert_eq!(db.search_local_works("Test Work", 10).unwrap().len(), 1);
    assert_eq!(db.search_local_works("Fluff", 10).unwrap().len(), 1);
    assert_eq!(db.search_local_works("test summary", 10).unwrap().len(), 1);
    assert!(db.search_local_works("nonexistent", 10).unwrap().is_empty());
    // A blank query is the search form's default state and means the whole
    // library; 0 is the no-limit sentinel.
    assert_eq!(db.search_local_works("  ", 0).unwrap().len(), 1);
    assert_eq!(db.search_local_works("", 0).unwrap().len(), 1);

    // Tags across every type, with the type reported.
    let hits = db.search_tags_all("fluff", 10).unwrap();
    assert!(hits.iter().any(|(n, t)| n == "Fluff" && t == "freeform"), "hits = {hits:?}");
    let creators = db.search_tags_all("Author1", 10).unwrap();
    assert!(creators.iter().any(|(_, t)| t == "creator"));

    // Users come from the harvested ao3_users rows.
    db.record_user(&crate::models::AO3User::ao3("someuser", "someuser", None, None)).unwrap();
    assert_eq!(db.search_ao3_usernames("some", 10).unwrap(), vec!["someuser".to_string()]);
    assert!(db.search_ao3_usernames("other", 10).unwrap().is_empty());
}

#[test]
fn test_collection_profile_tags_and_works() {
    let db = open_test_db();
    // Blurb lands first with counts; the profile brings tags but no counts.
    let blurb = crate::models::CollectionSummary {
        source: SOURCE_AO3.to_string(),
        url: "https://archiveofourown.org/collections/test_fest".into(),
        name: "test_fest".into(),
        title: "Test Fest".into(),
        summary: "From the blurb".into(),
        is_open: true,
        is_moderated: false,
        is_anonymous: false,
        work_count: 42,
        bookmarked_count: 7,
        maintainers: vec!["mod_one".into()],
        tags: vec!["Blurb Tag".into()],
        collection_type: String::new(),
    };
    db.save_collections(std::slice::from_ref(&blurb)).unwrap();
    assert!(!db.collection_profile_cached("test_fest").unwrap());
    // Blurb tags are cached immediately — no profile fetch required.
    assert_eq!(db.get_collection("test_fest").unwrap().unwrap().tags,
               vec!["Blurb Tag".to_string()]);
    // A tagless re-save (e.g. a differently rendered listing) must not
    // wipe the tags already learned.
    let mut tagless = blurb.clone();
    tagless.tags.clear();
    db.save_collections(std::slice::from_ref(&tagless)).unwrap();
    assert_eq!(db.get_collection("test_fest").unwrap().unwrap().tags,
               vec!["Blurb Tag".to_string()]);

    let mut profile = blurb.clone();
    profile.work_count = 0;
    profile.bookmarked_count = 0;
    profile.summary = String::new();
    profile.tags = vec!["Fandom A".into(), "Brand New Tag".into()];
    // "Fandom A" is already in tags via a saved work — tags are universal,
    // so the collection references the very same row.
    db.save_work(&sample_work(1)).unwrap();
    db.save_collection_profile(&profile).unwrap();

    assert!(db.collection_profile_cached("test_fest").unwrap());
    let cached = db.get_collection("test_fest").unwrap().unwrap();
    assert_eq!(cached.tags, vec!["Fandom A".to_string(), "Brand New Tag".to_string()]);
    // Profile zeroes kept the blurb's counts and summary.
    assert_eq!(cached.work_count, 42);
    assert_eq!(cached.summary, "From the blurb");
    let tag_rows: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM tags WHERE name = 'Fandom A'", [], |r| r.get(0)).unwrap();
    assert_eq!(tag_rows, 1, "one universal tags row per name");

    // Deleting the tags row cascades the relationship out of every join
    // table that references it. Raw deletion is a test-only bypass of the
    // TagCache write path (app code has no tags-delete path), so the map
    // must be resynced or later saves would reuse the dead id.
    db.conn.execute("DELETE FROM tags WHERE name = 'Fandom A'", []).unwrap();
    db.tag_cache.load(&db.conn).unwrap();
    let cached = db.get_collection("test_fest").unwrap().unwrap();
    assert_eq!(cached.tags, vec!["Brand New Tag".to_string()]);
    assert_eq!(db.get_work(1).unwrap().unwrap().fandoms, Vec::<String>::new());

    // Works seen in the collection accumulate across saves.
    db.save_work(&sample_work(2)).unwrap();
    db.add_collection_works("test_fest", &[1]).unwrap();
    db.add_collection_works("test_fest", &[1, 2]).unwrap();
    assert_eq!(db.get_collection_work_ids("test_fest").unwrap(), vec![1, 2]);
    // The library-mode works view: full summaries, listing order.
    let works = db.get_collection_works("test_fest").unwrap();
    assert_eq!(works.iter().map(|w| w.id).collect::<Vec<_>>(), vec![1, 2]);
    assert_eq!(works[1].title, "Test Work 2");
    // Deleting a work cascades its work_tags and collection_works rows.
    db.delete_work(1).unwrap();
    assert_eq!(db.get_collection_work_ids("test_fest").unwrap(), vec![2]);
    let orphans: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM work_tags WHERE work_id = 1", [], |r| r.get(0)).unwrap();
    assert_eq!(orphans, 0);

    // Deleting a collection cascades its tag and work links; the tags and
    // works themselves stay.
    db.conn.execute("DELETE FROM collections WHERE external_id = 'test_fest'", []).unwrap();
    let (ct, cw): (u32, u32) = db.conn.query_row(
        "SELECT (SELECT COUNT(*) FROM collection_tags), (SELECT COUNT(*) FROM collection_works)",
        [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((ct, cw), (0, 0));
    assert!(db.get_work(2).unwrap().is_some());
}

#[test]
fn test_collection_bookmark_caching() {
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap();
    db.save_work(&sample_work(2)).unwrap();

    // Signed in as "Reader": a fetched AO3 bookmark with their byline is
    // their record (linked to the account row); everyone else's is keyed
    // to its own username, outside the active account's scope. A fetched
    // record never sets the app's own bookmark flag (Area 7.3).
    let reader = account(&db, "Reader");
    db.set_active_account(reader).unwrap();

    let mine = db.cache_fetched_bookmark_for("reader", BookmarkTarget::Work(1), 111,
                                             "seen in a collection", "", false).unwrap().unwrap();
    db.cache_fetched_bookmark("SomeoneElse", 2, 222, "not mine", "", false).unwrap();
    // A byline-less blurb can't be attributed — nothing cached.
    assert_eq!(db.cache_fetched_bookmark_for("", BookmarkTarget::Work(2), 333, "", "", false).unwrap(), None);

    assert!(db.get_bookmarks().unwrap().is_empty(), "a fetched record is not an app flag");
    let own = db.get_user_bookmarks("Reader").unwrap();
    assert_eq!(own.iter().map(|h| (h.id, h.target)).collect::<Vec<_>>(), vec![(mine, BookmarkTarget::Work(1))]);
    let linked: Option<i64> = db.conn.query_row(
        "SELECT account_id FROM ao3_bookmarks WHERE id = ?1", [mine], |r| r.get(0)).unwrap();
    assert_eq!(linked, Some(reader), "the signed-in user's record links to their account row");

    // The record is the active account's AO3 bookmark whether or not the
    // work carries the app flag, and flagging it changes nothing there.
    assert!(db.get_bookmarks().unwrap().is_empty());
    assert_eq!(db.get_bookmark_full(1).unwrap().unwrap().2, Some(111));
    db.add_bookmark(1).unwrap();
    assert_eq!(db.get_bookmarks().unwrap(), vec![1]);
    let (note, sync, ao3_id) = db.get_bookmark_full(1).unwrap().unwrap();
    assert_eq!((note.as_str(), sync, ao3_id), ("seen in a collection", true, Some(111)));

    // A locally edited note survives re-fetch; only the AO3 id refreshes.
    db.update_bookmark_note(1, "my edited note").unwrap();
    db.cache_fetched_bookmark("Reader", 1, 444, "stale listing note", "", false).unwrap();
    let (note, _, ao3_id) = db.get_bookmark_full(1).unwrap().unwrap();
    assert_eq!((note.as_str(), ao3_id), ("my edited note", Some(444)));

    // The other user's record is keyed by their username, with no account.
    let (foreign, unlinked): (u32, u32) = db.conn.query_row(
        "SELECT COUNT(*), COUNT(*) - COUNT(account_id) FROM ao3_bookmarks WHERE owner = 'someoneelse'",
        [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((foreign, unlinked), (1, 1));

    // Collection↔bookmark joins (by record row id) accumulate across
    // pages and replay in listing order, independent of the works joins.
    let theirs: i64 = db.conn.query_row(
        "SELECT id FROM ao3_bookmarks WHERE owner = 'someoneelse' AND target_id = 2",
        [], |r| r.get(0)).unwrap();
    db.add_collection_bookmarks("test_fest", &[mine]).unwrap();
    db.add_collection_bookmarks("test_fest", &[mine, theirs]).unwrap();
    let hits = db.get_collection_bookmarks("test_fest").unwrap();
    assert_eq!(hits.iter().map(|h| h.id).collect::<Vec<_>>(), vec![mine, theirs]);
    assert_eq!(hits[1].work.as_ref().unwrap().id, 2);
    assert_eq!(hits[1].bookmarker, "someoneelse");
    assert!(db.get_collection_work_ids("test_fest").unwrap().is_empty());

    // Deleting a work cascades its bookmarks (trigger) and their links (FK).
    db.delete_work(1).unwrap();
    let hits = db.get_collection_bookmarks("test_fest").unwrap();
    assert_eq!(hits.iter().map(|h| h.id).collect::<Vec<_>>(), vec![theirs]);
    let rows: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM collection_bookmarks", [], |r| r.get(0)).unwrap();
    assert_eq!(rows, 1);
    // Removing a record drops its link too.
    db.conn.execute("DELETE FROM ao3_bookmarks WHERE id = ?1", [theirs]).unwrap();
    db.resync_caches();
    assert!(db.get_collection_bookmarks("test_fest").unwrap().is_empty());
    // Signing in as that user later claims their cached records.
    db.cache_fetched_bookmark("SomeoneElse", 2, 555, "", "", false).unwrap();
    let them = account(&db, "someoneelse");
    let claimed: Option<i64> = db.conn.query_row(
        "SELECT account_id FROM ao3_bookmarks WHERE owner = 'someoneelse'", [], |r| r.get(0)).unwrap();
    assert_eq!(claimed, Some(them));
}

#[test]
fn test_search_collections_filtered() {
    let db = open_test_db();
    let base = crate::models::CollectionSummary {
        source: SOURCE_AO3.to_string(),
        url: String::new(),
        name: String::new(),
        title: String::new(),
        summary: String::new(),
        is_open: true,
        is_moderated: false,
        is_anonymous: false,
        work_count: 0,
        bookmarked_count: 0,
        maintainers: Vec::new(),
        tags: Vec::new(),
        collection_type: String::new(),
    };
    let mut exchange = base.clone();
    exchange.name = "winter_exchange".into();
    exchange.title = "Winter Exchange".into();
    exchange.is_open = false;
    exchange.is_moderated = true;
    exchange.work_count = 50;
    exchange.bookmarked_count = 5;
    exchange.collection_type = "Gift Exchange Challenge".into();
    let mut meme = base.clone();
    meme.name = "prompt_pile".into();
    meme.title = "Prompt Pile".into();
    meme.work_count = 10;
    meme.bookmarked_count = 30;
    meme.collection_type = "Prompt Meme Challenge".into();
    let mut plain = base.clone();
    plain.name = "just_fics".into();
    plain.title = "Just Fics".into();
    plain.work_count = 25;
    db.save_collections(&[exchange, meme, plain]).unwrap();

    // Teach tag types via a work (fandoms), then attach profile tags.
    let mut w = sample_work(1);
    w.fandoms = vec!["Fandom A".into(), "Fandom B".into()];
    db.save_work(&w).unwrap();
    // The profile carries the same flags the blurb did (the real parser
    // reads them off the page), plus the tag links only it has.
    let mut profile = base.clone();
    profile.name = "winter_exchange".into();
    profile.title = "Winter Exchange".into();
    profile.is_open = false;
    profile.is_moderated = true;
    profile.collection_type = "Gift Exchange Challenge".into();
    profile.tags = vec!["Fandom A".into(), "Fandom B".into()];
    db.save_collection_profile(&profile).unwrap();

    let all = db.search_collections_filtered(&Default::default(), 0).unwrap();
    assert_eq!(all.len(), 3, "blank criteria = whole cache");

    let mut c = crate::models::CollectionSearchCriteria { title: "winter".into(), ..Default::default() };
    let hits = db.search_collections_filtered(&c, 0).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].name, "winter_exchange");
    // Slug text matches too.
    c.title = "prompt_pile".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap().len(), 1);

    // Tag filter: profile-cached tags, exact name, case-insensitive; every
    // listed tag must be present.
    c = Default::default();
    c.tag = "fandom a, Fandom B".into();
    let hits = db.search_collections_filtered(&c, 0).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].name, "winter_exchange");
    c.tag = "Fandom A, Missing".into();
    assert!(db.search_collections_filtered(&c, 0).unwrap().is_empty());

    // Multifandom: >1 fandom-typed tag.
    c = Default::default();
    c.multifandom = "true".into();
    let hits = db.search_collections_filtered(&c, 0).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].name, "winter_exchange");
    c.multifandom = "false".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap().len(), 2);

    // Closed / moderated tri-states.
    c = Default::default();
    c.closed = "true".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap()[0].name, "winter_exchange");
    c.closed = "false".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap().len(), 2);
    c = Default::default();
    c.moderated = "true".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap().len(), 1);

    // Challenge type, including "no challenge".
    c = Default::default();
    c.challenge_type = "GiftExchange".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap()[0].name, "winter_exchange");
    c.challenge_type = "PromptMeme".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap()[0].name, "prompt_pile");
    c.challenge_type = "no_challenge".into();
    assert_eq!(db.search_collections_filtered(&c, 0).unwrap()[0].name, "just_fics");

    // Sorts: works count desc, bookmarked asc, title asc.
    c = Default::default();
    c.sort_column = "works_count".into();
    let names: Vec<_> = db.search_collections_filtered(&c, 0).unwrap()
        .into_iter().map(|x| x.name).collect();
    assert_eq!(names, vec!["winter_exchange", "just_fics", "prompt_pile"]);
    c.sort_column = "bookmarked_items_count".into();
    c.sort_direction = "asc".into();
    let names: Vec<_> = db.search_collections_filtered(&c, 0).unwrap()
        .into_iter().map(|x| x.name).collect();
    assert_eq!(names, vec!["just_fics", "winter_exchange", "prompt_pile"]);
    c.sort_column = "title.keyword".into();
    let names: Vec<_> = db.search_collections_filtered(&c, 0).unwrap()
        .into_iter().map(|x| x.name).collect();
    assert_eq!(names, vec!["just_fics", "prompt_pile", "winter_exchange"]);

    // Limit caps the result set (0 = everything).
    assert_eq!(db.search_collections_filtered(&Default::default(), 2).unwrap().len(), 2);
}

#[test]
fn test_filtered_library_search() {
    let db = open_test_db();
    // Work 1: sample defaults — Fandom A, Teen, Warning::None, F/M, tags
    // Fluff/Angst, 12,345 words, 3 chapters, incomplete, English,
    // updated 2025-01-15, kudos 42.
    db.save_work(&sample_work(1)).unwrap();
    let mut b = sample_work(2);
    b.title = "Another Story".into();
    b.fandoms = vec!["Fandom B".into(), "Fandom C".into()];
    b.rating = Rating::Explicit;
    b.warnings = vec![Warning::Violence];
    b.categories = vec!["M/M".into()];
    b.tags = vec!["Slow Burn".into()];
    b.word_count = Some(100_000);
    b.chapter_count = 1;
    b.complete = true;
    b.language = "Deutsch".into();
    b.date_updated = "2026-08-01".into();
    b.kudos = Some(500);
    db.save_work(&b).unwrap();

    let ids = |c: &LocalSearchCriteria| -> Vec<u64> {
        db.search_local_works_filtered(c, 0).unwrap().iter().map(|w| w.id).collect()
    };

    // Empty criteria: whole library, newest-updated first.
    assert_eq!(ids(&LocalSearchCriteria::default()), vec![2, 1]);

    // Freeform tag present on one work / on none.
    let mut c = LocalSearchCriteria { freeform_names: "Fluff".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    c.freeform_names = "Coffee Shops".into();
    assert!(ids(&c).is_empty());

    // Fandom name, and crossover flags.
    let c = LocalSearchCriteria { fandom_names: "Fandom B".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria { crossover: "T".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    c.crossover = "F".into();
    assert_eq!(ids(&c), vec![1]);

    // Rating / warning / category labels as AO3's form spells them.
    let c = LocalSearchCriteria { ratings: vec!["Explicit".into()], ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = LocalSearchCriteria { warnings: vec!["Graphic Depictions Of Violence".into()], ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = LocalSearchCriteria { categories: vec!["F/M".into()], ..Default::default() };
    assert_eq!(ids(&c), vec![1]);

    // Completion, single chapter, language.
    let c = LocalSearchCriteria { complete: "T".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = LocalSearchCriteria { single_chapter: true, ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = LocalSearchCriteria { language: "deutsch".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);

    // Numeric ranges: >N and lo-hi.
    let c = LocalSearchCriteria { word_count: ">50,000".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);
    let c = LocalSearchCriteria { kudos_count: "10-100".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);

    // Date updated: prefix, absolute after, and a relative window wide
    // enough to stay deterministic.
    let mut c = LocalSearchCriteria { revised_at: "2025".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1]);
    c.revised_at = "> 2025".into();
    assert_eq!(ids(&c), vec![2]);
    c.revised_at = "< 100 years ago".into();
    assert_eq!(ids(&c), vec![2, 1]);

    // Sorting: kudos ascending, title ascending by AO3's default direction.
    let c = LocalSearchCriteria { sort_column: "kudos_count".into(), sort_direction: "asc".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![1, 2]);
    let c = LocalSearchCriteria { sort_column: "title_to_sort_on".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2, 1]); // "Another…" before "Test…"

    // Creators substring hits both (shared author), title narrows to one.
    let c = LocalSearchCriteria { creators: "Author1".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2, 1]);
    let c = LocalSearchCriteria { title: "another".into(), ..Default::default() };
    assert_eq!(ids(&c), vec![2]);

    // Limit still applies when requested.
    assert_eq!(db.search_local_works_filtered(&LocalSearchCriteria::default(), 1).unwrap().len(), 1);
}

#[test]
fn test_save_search_upsert() {
    let db = open_test_db();

    db.save_search("My Search", "{\"a\":1}").unwrap();
    let saved = db.get_saved_searches().unwrap();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].1, "My Search");
    assert_eq!(saved[0].2, "{\"a\":1}");

    // Same name, different case: overwrites instead of duplicating.
    db.save_search("my search", "{\"a\":2}").unwrap();
    let saved = db.get_saved_searches().unwrap();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].1, "my search");
    assert_eq!(saved[0].2, "{\"a\":2}");
}

#[test]
fn test_gone_from_ao3_flag() {
    let db = open_test_db();
    let a = db.save_work(&sample_work(7001)).unwrap();
    let b = db.save_work(&sample_work(7002)).unwrap();

    assert!(db.get_gone_work_ids().unwrap().is_empty());

    db.set_works_gone(&[a], true).unwrap();
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![a]);

    // save_work on a gone work must not resurrect it implicitly…
    db.save_work(&sample_work(7001)).unwrap();
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![a]);

    // …only an explicit clear (census reappearance) does.
    db.set_works_gone(&[a, b], false).unwrap();
    assert!(db.get_gone_work_ids().unwrap().is_empty());
}

#[test]
fn test_finished_flag() {
    let db = open_test_db();
    let a = db.save_work(&sample_work(7101)).unwrap();
    let b = db.save_work(&sample_work(7102)).unwrap();

    // Never set automatically.
    assert!(db.get_finished_work_ids().unwrap().is_empty());
    db.save_progress(a, 3, 10).unwrap();
    assert!(db.get_finished_work_ids().unwrap().is_empty());

    db.set_works_finished(&[a], true).unwrap();
    assert_eq!(db.get_finished_work_ids().unwrap(), vec![a]);

    // A re-save (listing refresh) keeps the flag.
    db.save_work(&sample_work(7101)).unwrap();
    assert_eq!(db.get_finished_work_ids().unwrap(), vec![a]);

    db.set_works_finished(&[a, b], true).unwrap();
    let mut ids = db.get_finished_work_ids().unwrap();
    ids.sort();
    assert_eq!(ids, vec![a, b]);

    db.set_works_finished(&[a, b], false).unwrap();
    assert!(db.get_finished_work_ids().unwrap().is_empty());
}

#[test]
fn test_work_series_roundtrip() {
    let db = open_test_db();
    let w = sample_work(7101);
    let wid = db.save_work(&w).unwrap();

    // As parsed: series named by AO3 number, no row ids yet.
    let parsed = vec![
        SeriesMembership {
            series_id: 0,
            series_external_id: "9000001".into(),
            name: "Alpha Test Series".into(),
            part: 2,
            prev_work_external_id: Some("7100".into()),
            next_work_external_id: Some("7102".into()),
        },
        SeriesMembership {
            series_id: 0,
            series_external_id: "9000002".into(),
            name: "Beta Test Series".into(),
            part: 1,
            prev_work_external_id: None,
            next_work_external_id: None,
        },
    ];
    db.set_work_series(wid, &parsed).unwrap();
    // Saving resolved each series to a row (a name-only stub) and stored
    // the row id on the membership.
    let alpha = db.resolve_series(SOURCE_AO3, "9000001").expect("series stub");
    let beta = db.resolve_series(SOURCE_AO3, "9000002").expect("series stub");
    assert_eq!(db.get_series(alpha).unwrap().unwrap().name, "Alpha Test Series");
    let series: Vec<SeriesMembership> = parsed.iter().cloned().zip([alpha, beta])
        .map(|(m, id)| SeriesMembership { series_id: id, ..m }).collect();
    let got = db.get_work(wid).unwrap().unwrap();
    assert_eq!(got.series, series);

    // A blurb-shaped save_work (empty series) must not wipe it.
    db.save_work(&w).unwrap();
    let got = db.get_work(wid).unwrap().unwrap();
    assert_eq!(got.series, series);

    // Series membership is derived from series_json, by series row.
    let subs = db.get_subscription_works(FollowTarget::Series(alpha)).unwrap();
    assert_eq!(subs.len(), 1);
    assert_eq!(subs[0].series, series);
    assert_eq!(db.get_subscription_member_ids(FollowTarget::Series(beta)).unwrap(), vec![wid]);
    assert!(db.get_subscription_member_ids(FollowTarget::Series(9_000_009)).unwrap().is_empty());

    // A blurb-shaped save carrying series (no prev/next) keeps the
    // work-page links for the same series and drops memberships the
    // blurb no longer lists.
    let mut blurb = sample_work(7101);
    blurb.series = vec![SeriesMembership {
        series_id: 0, series_external_id: "9000001".into(), name: "Alpha Test Series".into(), part: 3,
        prev_work_external_id: None, next_work_external_id: None,
    }];
    db.save_work(&blurb).unwrap();
    let got = db.get_work(wid).unwrap().unwrap();
    assert_eq!(got.series.len(), 1);
    assert_eq!(got.series[0].series_id, alpha);
    assert_eq!(got.series[0].part, 3);
    assert_eq!(got.series[0].prev_work_external_id.as_deref(), Some("7100"));
    assert_eq!(got.series[0].next_work_external_id.as_deref(), Some("7102"));
    assert!(db.get_subscription_member_ids(FollowTarget::Series(beta)).unwrap().is_empty());
    db.set_work_series(wid, &series).unwrap();

    // Explicit empty write clears (work removed from series on AO3).
    db.set_work_series(wid, &[]).unwrap();
    assert!(db.get_work(wid).unwrap().unwrap().series.is_empty());
}

#[test]
fn test_detail_viewed_at() {
    let db = open_test_db();
    let w = sample_work(7201);
    let id = db.save_work(&w).unwrap();
    assert!(db.get_detail_viewed_work_ids().unwrap().is_empty());

    db.mark_work_detail_viewed(id, "1750000000").unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![id]);

    // First view wins — a later mark keeps the original timestamp.
    db.mark_work_detail_viewed(id, "1760000000").unwrap();
    let at: String = db.conn.query_row(
        "SELECT detail_viewed_at FROM works WHERE id = ?1", [id as i64], |r| r.get(0)).unwrap();
    assert_eq!(at, "1750000000");

    // Blurb-shaped save_work must not wipe it.
    db.save_work(&w).unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![id]);

    // Marking a work with no row is a silent no-op.
    db.mark_work_detail_viewed(9999, "1750000000").unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![id]);
}

#[test]
fn test_last_read_dt() {
    let db = open_test_db();
    let w = sample_work(7301);
    let id = db.save_work(&w).unwrap();
    assert!(db.get_work_last_read_times().unwrap().is_empty());

    db.mark_work_read(id).unwrap();
    let times = db.get_work_last_read_times().unwrap();
    assert_eq!(times.len(), 1);
    assert_eq!(times[0].0, id);
    assert!(!times[0].1.is_empty());

    // Blurb-shaped save_work must not wipe it.
    db.save_work(&w).unwrap();
    assert_eq!(db.get_work_last_read_times().unwrap().len(), 1);

    // Marking a work with no row is a silent no-op.
    db.mark_work_read(9999).unwrap();
    assert_eq!(db.get_work_last_read_times().unwrap().len(), 1);
}

#[test]
fn test_subscription_member_ids() {
    let db = open_test_db();
    // Author membership comes from bylines (pseud form included), however
    // the work was cached; the explicit table is only for other kinds.
    let mut a = sample_work(1); a.authors = vec!["alice".into()];
    let mut b = sample_work(2); b.authors = vec!["Nom (alice)".into()];
    let mut c = sample_work(3); c.authors = vec!["bob".into()];
    for w in [&a, &b, &c] { db.save_work(w).unwrap(); }
    // Bylines created the users rows; any name form resolves to them.
    let alice = db.follow_target("author", "Alice").expect("users row from bylines");
    let bob = db.follow_target("author", "bob").unwrap();
    let mut ids = db.get_subscription_member_ids(alice).unwrap();
    ids.sort();
    assert_eq!(ids, vec![1, 2]);
    assert_eq!(db.get_subscription_member_ids(bob).unwrap(), vec![3]);
    assert!(db.get_subscription_member_ids(fandom(&db, "alice")).unwrap().is_empty());

    // A user's cached AO3 bookmarks (any target) come from the records.
    db.cache_fetched_bookmark("Alice", 3, 501, "", "", false).unwrap();
    let mine = db.get_user_bookmarks("alice").unwrap();
    assert_eq!(mine.iter().map(|h| h.target.id()).collect::<Vec<_>>(), vec![3]);
    // Neither an app flag nor a record that never reached AO3 (no AO3 id)
    // is one of the user's public AO3 bookmarks — but the account's own
    // list shows the unsent record beside the one on AO3.
    let acct = account(&db, "Alice");
    db.set_active_account(acct).unwrap();
    db.add_bookmark(1).unwrap();
    db.update_bookmark_note(2, "not sent yet").unwrap();
    let mine = db.get_user_bookmarks("alice").unwrap();
    assert_eq!(mine.iter().map(|h| h.target.id()).collect::<Vec<_>>(), vec![3]);
    let mut own: Vec<u64> = db.get_own_ao3_bookmarks().unwrap().iter().map(|h| h.target.id()).collect();
    own.sort();
    assert_eq!(own, vec![2, 3]);
    assert!(db.get_user_bookmarks("nobody").unwrap().is_empty());
}

#[test]
fn test_check_queue_persistence() {
    let db = open_test_db();

    assert!(db.get_check_queue().unwrap().is_none());

    db.set_check_queue(r#"[{"sub_type":"author","sub_id":"a","name":"A"}]"#).unwrap();
    assert!(db.get_check_queue().unwrap().is_some());

    db.clear_check_queue().unwrap();
    assert_eq!(db.get_check_queue().unwrap().as_deref(), Some("[]"));
}

#[test]
fn test_notifications() {
    let db = open_test_db();

    // Initially empty
    assert_eq!(db.get_unread_count().unwrap(), 0);
    assert!(db.get_notifications().unwrap().is_empty());

    // Add notifications
    let id1 = db.add_notification("new_work", 100, "author1", "Work Title", "New work posted").unwrap();
    let id2 = db.add_notification("new_chapter", 200, "author2", "Another Work", "Chapter 5 added").unwrap();
    assert!(id1 > 0);
    assert!(id2 > 0);
    assert_ne!(id1, id2);

    // Check counts
    assert_eq!(db.get_unread_count().unwrap(), 2);

    // Get all notifications
    let notifs = db.get_notifications().unwrap();
    assert_eq!(notifs.len(), 2);

    // Find the new_chapter notification (order may vary when created_at is identical)
    let n2 = notifs.iter().find(|n| n.0 == id2).unwrap();
    assert_eq!(n2.1, "new_chapter");
    assert_eq!(n2.2, 200);
    assert_eq!(n2.3, "author2");
    assert_eq!(n2.4, "Another Work");
    assert_eq!(n2.5, "Chapter 5 added");
    assert!(!n2.7); // not read

    // Mark one as read
    db.mark_notification_read(id1).unwrap();
    assert_eq!(db.get_unread_count().unwrap(), 1);
    let notifs = db.get_notifications().unwrap();
    let n1 = notifs.iter().find(|n| n.0 == id1).unwrap();
    assert!(n1.7); // read

    // Mark all as read
    db.mark_all_read().unwrap();
    assert_eq!(db.get_unread_count().unwrap(), 0);

    // Clear read notifications
    db.clear_read_notifications().unwrap();
    assert!(db.get_notifications().unwrap().is_empty());
}

#[test]
fn test_custom_themes() {
    let db = open_test_db();

    // Initially empty
    let themes = db.get_all_themes().unwrap();
    assert!(themes.is_empty());

    // Save a theme
    db.save_theme("theme-1", "My Theme", r#"{"bgColor":"FFF"}"#).unwrap();
    let themes = db.get_all_themes().unwrap();
    assert_eq!(themes.len(), 1);
    assert_eq!(themes[0].0, "theme-1");
    assert_eq!(themes[0].1, "My Theme");
    assert_eq!(themes[0].2, r#"{"bgColor":"FFF"}"#);

    // Save another theme
    db.save_theme("theme-2", "Dark Theme", r#"{"bgColor":"000"}"#).unwrap();
    let themes = db.get_all_themes().unwrap();
    assert_eq!(themes.len(), 2);

    // Update existing theme (INSERT OR REPLACE)
    db.save_theme("theme-1", "My Theme Updated", r#"{"bgColor":"EEE"}"#).unwrap();
    let themes = db.get_all_themes().unwrap();
    assert_eq!(themes.len(), 2);
    let t1 = themes.iter().find(|t| t.0 == "theme-1").unwrap();
    assert_eq!(t1.1, "My Theme Updated");
    assert_eq!(t1.2, r#"{"bgColor":"EEE"}"#);

    // Delete a theme
    db.delete_theme("theme-1").unwrap();
    let themes = db.get_all_themes().unwrap();
    assert_eq!(themes.len(), 1);
    assert_eq!(themes[0].0, "theme-2");

    // Delete non-existent theme (no error)
    db.delete_theme("nonexistent").unwrap();
}

#[test]
fn test_last_check_time() {
    let db = open_test_db();

    // Initially none
    assert!(db.get_last_check_time().unwrap().is_none());

    // Set it
    db.set_last_check_time("2025-06-01T12:00:00Z").unwrap();
    assert_eq!(
        db.get_last_check_time().unwrap().as_deref(),
        Some("2025-06-01T12:00:00Z")
    );

    // Update it
    db.set_last_check_time("2025-06-02T14:00:00Z").unwrap();
    assert_eq!(
        db.get_last_check_time().unwrap().as_deref(),
        Some("2025-06-02T14:00:00Z")
    );
}

#[test]
fn test_follows() {
    let db = Storage::open_in_memory("test-passphrase").unwrap();
    let fa = fandom(&db, "Fandom A");
    db.add_follow(fa, "Fandom A").unwrap();
    db.add_follow(fandom(&db, "Fandom B"), "Fandom B").unwrap();
    // A byline keys on the account username.
    db.add_follow(author(&db, "Pen (writer_one)"), "Pen (writer_one)").unwrap();
    // Duplicates are ignored; kinds are independent.
    assert!(!db.add_follow(fa, "Fandom A").unwrap());
    let fandoms: Vec<String> = db.get_follows(Some("fandom")).unwrap().into_iter().map(|f| f.bridge_id).collect();
    assert_eq!(fandoms, vec!["Fandom A", "Fandom B"]);
    let writer = &db.get_follows(Some("author")).unwrap()[0];
    let writer_row = db.ao3_user_row_id("writer_one").unwrap().to_string();
    assert_eq!((writer.bridge_id.as_str(), writer.name.as_str()), (writer_row.as_str(), "Pen (writer_one)"));
    // The bridge id is the users row; an AO3 name still resolves the target.
    assert_eq!(db.follow_target("author", &writer_row), db.follow_target("author", "writer_one"));
    assert_eq!(db.get_follows(None).unwrap().len(), 3);
    assert!(db.remove_follow(fa).unwrap());
    assert!(!db.remove_follow(fa).unwrap());
    assert_eq!(db.get_follows(Some("fandom")).unwrap().len(), 1);
}

#[test]
fn test_migration_v20_to_v21_follows() {
    let path = std::env::temp_dir().join(format!("ao3_v21_test_{}.db", std::process::id()));
    let path_str = path.to_string_lossy().to_string();
    let _ = std::fs::remove_file(&path);
    drop(Storage::open(&path_str, "").unwrap());

    // Rewind the fresh library to the v20 shape, with v20-era data.
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "DROP TABLE follows; DROP TABLE crawl_stamps; DROP TABLE subscriptions;
             CREATE TABLE subscriptions (sub_type TEXT NOT NULL, sub_id TEXT NOT NULL,
                 name TEXT NOT NULL, ao3_id TEXT, PRIMARY KEY (sub_type, sub_id));
             CREATE TABLE subscription_snapshots (sub_type TEXT NOT NULL, sub_id TEXT NOT NULL,
                 date_updated TEXT NOT NULL, total_works INTEGER, last_census_at TEXT,
                 census_state TEXT, works_crawled_at TEXT, last_checked_at TEXT,
                 PRIMARY KEY (sub_type, sub_id));
             CREATE TABLE followed_items (kind TEXT NOT NULL, name TEXT NOT NULL,
                 PRIMARY KEY (kind, name));
             INSERT INTO followed_items VALUES
                 ('fandom', 'Fandom A'), ('author', 'Pen (Writer_One)'), ('author', 'bare_user');
             INSERT INTO subscriptions VALUES
                 ('author', 'writer_one', 'writer_one', '11'),
                 ('work', '100', 'Subscribed Fic', '12'),
                 ('series', '200', 'Subscribed Series', NULL);
             -- Case-colliding author rows: the more recently checked wins.
             INSERT INTO subscription_snapshots VALUES
                 ('author', 'writer_one', '2024-05-01', 40, '2024-05-01 00:00:00', NULL,
                  '2024-04-01 00:00:00', '2026-01-02 00:00:00'),
                 ('author', 'Writer_One', '2023-01-01', 1, NULL, NULL, NULL, '2025-01-01 00:00:00'),
                 ('work', '100', '', NULL, NULL, NULL, NULL, NULL),
                 ('author', 'orphan', '2020-01-01', NULL, NULL, NULL, '2020-02-02 00:00:00', NULL);
             INSERT OR REPLACE INTO app_state VALUES ('subscription_check_queue',
                 '[{\"sub_type\":\"work\",\"sub_id\":\"100\",\"name\":\"x\"}]');
             PRAGMA user_version = 20;"
        ).unwrap();
    }

    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);

    // Device follows first, in order, then every subscription not already
    // followed (the byline follow already covers writer_one). v26 keyed
    // them by row: the followed work and series became stubs under their
    // AO3 numbers, so the bridge ids are those numbers.
    let follows: Vec<(String, String, String)> = db.get_follows(None).unwrap().into_iter()
        .map(|f| (f.target.kind().to_string(), f.bridge_id, f.name)).collect();
    let writer_row = db.ao3_user_row_id("writer_one").unwrap().to_string();
    let bare_row = db.ao3_user_row_id("bare_user").unwrap().to_string();
    assert_eq!(follows, vec![
        ("fandom".to_string(), "Fandom A".to_string(), "Fandom A".to_string()),
        ("author".to_string(), writer_row, "Pen (Writer_One)".to_string()),
        ("author".to_string(), bare_row, "bare_user".to_string()),
        ("work".to_string(), "100".to_string(), "Subscribed Fic".to_string()),
        ("series".to_string(), "200".to_string(), "Subscribed Series".to_string()),
    ]);
    assert!(db.is_work_stub(100));
    assert_eq!(db.resolve_series(SOURCE_AO3, "200"), Some(200));
    let writer = db.follow_target("author", "writer_one").expect("users row");
    let work100 = db.follow_target("work", "100").unwrap();
    let series200 = db.follow_target("series", "200").unwrap();

    // Check state moved onto the follow rows.
    assert_eq!(db.get_follow_baseline(writer).unwrap().as_deref(), Some("2024-05-01"));
    assert_eq!(db.get_follow_last_checked(writer).unwrap().as_deref(), Some("2026-01-02 00:00:00"));
    assert_eq!(db.get_follow_census_meta(writer).unwrap().0, Some(40));
    assert!(db.get_follow_baseline(work100).unwrap().is_none(), "empty baseline = first run");
    assert!(db.get_follow_last_checked(series200).unwrap().is_none());

    // Crawl stamps survive, even for targets nobody follows.
    assert_eq!(db.get_works_crawled_at(writer).unwrap().as_deref(), Some("2024-04-01 00:00:00"));
    let orphan = db.follow_target("author", "orphan").expect("stamped author has a users row");
    assert_eq!(db.get_works_crawled_at(orphan).unwrap().as_deref(), Some("2020-02-02 00:00:00"));

    // Old tables gone; subscriptions are account-scoped and start empty;
    // the old-key queue is cleared.
    for table in ["followed_items", "subscription_snapshots"] {
        let n: u32 = db.conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = ?1", [table], |r| r.get(0)).unwrap();
        assert_eq!(n, 0, "{table} dropped");
    }
    let n: u32 = db.conn.query_row("SELECT COUNT(*) FROM subscriptions", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 0);
    assert_eq!(db.get_check_queue().unwrap().as_deref(), Some("[]"));

    drop(db);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn test_schema_version_fetched_at_and_author_index() {
    let db = open_test_db();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    db.save_work(&sample_work(1)).unwrap();
    // save_work stamps fetched_at with the DB-wide datetime encoding.
    let w = db.get_work(1).unwrap().unwrap();
    assert_eq!(w.fetched_at.len(), 19, "fetched_at = {:?}", w.fetched_at);
    assert!(crate::timefmt::datetime_to_epoch(&w.fetched_at).is_some());
    // The author index answers get_works_by_author.
    assert_eq!(db.get_works_by_author("Author1").unwrap().len(), 1);
    assert_eq!(db.get_works_by_author("Author2").unwrap().len(), 1);
    assert!(db.get_works_by_author("Nobody").unwrap().is_empty());
}

#[test]
fn test_get_works_by_author_includes_pseud_bylines() {
    let db = open_test_db();
    let mut plain = sample_work(1);
    plain.authors = vec!["writer".into()];
    let mut pseud = sample_work(2);
    pseud.authors = vec!["PenName (writer)".into()];
    let mut other = sample_work(3);
    other.authors = vec!["writer_two".into()];
    for w in [&plain, &pseud, &other] { db.save_work(w).unwrap(); }
    // An author's list is everything under their account, pseud or not —
    // what AO3 shows on /users/writer/works.
    let ids: Vec<u64> = db.get_works_by_author("writer").unwrap().iter().map(|w| w.id).collect();
    assert_eq!(ids.len(), 2);
    assert!(ids.contains(&1) && ids.contains(&2));
    // Asking by a byline resolves to the account too.
    assert_eq!(db.get_works_by_author("PenName (writer)").unwrap().len(), 2);
    // save_work taught the users cache the pseud, so the bare pseud
    // resolves to the account too.
    assert_eq!(db.get_works_by_author("PenName").unwrap().len(), 2);
    assert!(db.get_ao3_user_record("writer").unwrap().property(crate::user_fields::PROFILE_FETCHED_AT).is_none());
    assert_eq!(db.get_ao3_user("PenName").unwrap().map(|u| u.username), Some("writer".to_string()));
    assert_eq!(db.get_works_by_author("writer_two").unwrap().len(), 1);
}

#[test]
fn test_migration_v1_to_v2() {
    let path = std::env::temp_dir().join(format!("ao3_migration_test_{}.db", std::process::id()));
    let path_str = path.to_string_lossy().to_string();
    let _ = std::fs::remove_file(&path);

    // Hand-build a v1 (pre-versioning-baseline) database: no fetched_at, no
    // work_authors, an orphaned _old table, and epoch-seconds timestamps.
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE works (
                id INTEGER PRIMARY KEY, title TEXT NOT NULL,
                authors_json TEXT NOT NULL, fandoms_json TEXT NOT NULL,
                rating TEXT NOT NULL, warnings_json TEXT NOT NULL,
                categories_json TEXT NOT NULL, relationships_json TEXT NOT NULL,
                characters_json TEXT NOT NULL, tags_json TEXT NOT NULL,
                summary TEXT NOT NULL, word_count INTEGER NOT NULL,
                chapter_count INTEGER NOT NULL, total_chapters INTEGER,
                kudos INTEGER NOT NULL, hits INTEGER NOT NULL,
                bookmarks INTEGER NOT NULL, comments INTEGER NOT NULL,
                date_published TEXT NOT NULL DEFAULT '', date_updated TEXT NOT NULL,
                language TEXT NOT NULL, complete INTEGER NOT NULL,
                series_json TEXT NOT NULL DEFAULT '[]',
                detail_viewed_at TEXT NOT NULL DEFAULT '',
                last_read_dt TEXT NOT NULL DEFAULT '',
                gone_from_ao3 INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE subscription_snapshots (
                sub_type TEXT NOT NULL, sub_id TEXT NOT NULL,
                date_updated TEXT NOT NULL, total_works INTEGER,
                last_census_at TEXT, census_state TEXT, works_crawled_at TEXT,
                PRIMARY KEY (sub_type, sub_id)
            );
            CREATE TABLE subscription_snapshots_old (sub_type TEXT);
            CREATE TABLE bookmarks (
                account_id TEXT NOT NULL DEFAULT '',
                work_id    INTEGER NOT NULL,
                note       TEXT DEFAULT '',
                sync_to_ao3 INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                ao3_bookmark_id INTEGER,
                tag_string TEXT NOT NULL DEFAULT '',
                collection_names TEXT NOT NULL DEFAULT '',
                private INTEGER NOT NULL DEFAULT 1,
                rec INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (account_id, work_id)
            );
            CREATE TABLE ao3_users (
                id          TEXT PRIMARY KEY,
                username    TEXT NOT NULL,
                profile_url TEXT NOT NULL DEFAULT '',
                avatar_url  TEXT NOT NULL DEFAULT '',
                updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
                numeric_id TEXT NOT NULL DEFAULT '',
                joined TEXT NOT NULL DEFAULT '',
                location TEXT NOT NULL DEFAULT '',
                birthday TEXT NOT NULL DEFAULT '',
                pseuds_json TEXT NOT NULL DEFAULT '[]',
                bio_json TEXT NOT NULL DEFAULT '[]',
                works_count INTEGER NOT NULL DEFAULT 0,
                series_count INTEGER NOT NULL DEFAULT 0,
                bookmarks_count INTEGER NOT NULL DEFAULT 0,
                collections_count INTEGER NOT NULL DEFAULT 0,
                gifts_count INTEGER NOT NULL DEFAULT 0,
                is_blocked INTEGER NOT NULL DEFAULT 0,
                block_ao3_id TEXT NOT NULL DEFAULT '',
                is_muted INTEGER NOT NULL DEFAULT 0,
                mute_ao3_id TEXT NOT NULL DEFAULT '',
                profile_fetched_at TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE comments (
                id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL DEFAULT 0,
                chapter_id INTEGER NOT NULL DEFAULT 0, parent_id INTEGER NOT NULL DEFAULT 0,
                author_id TEXT NOT NULL, posted_at TEXT NOT NULL DEFAULT '',
                content_json TEXT NOT NULL DEFAULT '[]',
                cached_at TEXT NOT NULL DEFAULT (datetime('now')),
                FOREIGN KEY (author_id) REFERENCES ao3_users(id)
            );
            INSERT INTO ao3_users (id, username, profile_url, avatar_url, updated_at,
                                   profile_fetched_at, pseuds_json, numeric_id)
             VALUES ('writer_one', 'writer_one', 'https://archiveofourown.org/users/writer_one',
                     '', '2024-01-01 00:00:00', '2024-01-01 00:00:00', '[\"writer_one\"]', '11'),
                    ('PenOne', 'PenOne (writer_one)',
                     'https://archiveofourown.org/users/writer_one/pseuds/PenOne',
                     'http://a/pen.png', '2024-02-01 00:00:00', '', '[]', ''),
                    ('guest:abc', 'A Guest (Guest)', '', '', '2024-01-01 00:00:00', '', '[]', '');
            INSERT INTO comments (id, work_id, author_id, content_json)
             VALUES (1, 7, 'PenOne', '[]'), (2, 7, 'guest:abc', '[]');
            CREATE TABLE accounts (
                id          TEXT PRIMARY KEY,
                username    TEXT NOT NULL,
                password    TEXT NOT NULL DEFAULT '',
                cookies     TEXT NOT NULL DEFAULT '',
                is_active   INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL DEFAULT (datetime('now'))
            );
            INSERT INTO accounts (id, username, is_active)
             VALUES ('account-writer_one', 'Writer_One', 1);
            INSERT INTO bookmarks (account_id, work_id, note)
             VALUES ('account-writer_one', 7, 'prefixed era'), ('', 7, 'signed-out era');
            CREATE TABLE saved_searches (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT NOT NULL,
                params_json TEXT NOT NULL,
                created_at  TEXT NOT NULL DEFAULT (datetime('now'))
            );
            INSERT INTO saved_searches (name, params_json)
             VALUES ('Fluff', '{\"a\":1}'), ('fluff', '{\"a\":2}'), ('Angst', '{}');
            INSERT INTO works (id, title, authors_json, fandoms_json, rating,
                warnings_json, categories_json, relationships_json, characters_json,
                tags_json, summary, word_count, chapter_count, total_chapters,
                kudos, hits, bookmarks, comments, date_updated, language, complete,
                detail_viewed_at)
             VALUES (7, 'Legacy Work', '[\"writer_one\",\"writer_two\"]', '[\"F\"]',
                'General', '[]', '[]', '[]', '[]', '[]', 's', 10, 1, 1,
                0, 0, 0, 0, '2024-01-01', 'en', 1, '1722556800');
            INSERT INTO subscription_snapshots
                (sub_type, sub_id, date_updated, last_census_at, works_crawled_at)
             VALUES ('author', 'writer_one', '2024-01-01', '1722556800', '1722556800');
            INSERT INTO app_state VALUES ('last_subscription_check', '1722556800');
            PRAGMA user_version = 1;",
        )
        .unwrap();
    }

    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    // v3: case-insensitive duplicates collapsed to the newest, and the
    // unique index exists — so the ON CONFLICT upsert actually works on a
    // migrated (not fresh-baseline) database.
    let saved = db.get_saved_searches().unwrap();
    let names: Vec<&str> = saved.iter().map(|(_, n, _)| n.as_str()).collect();
    assert_eq!(saved.len(), 2, "names = {names:?}");
    assert!(names.contains(&"fluff") && names.contains(&"Angst"), "names = {names:?}");
    db.save_search("FLUFF", "{\"a\":3}").unwrap();
    let saved = db.get_saved_searches().unwrap();
    assert_eq!(saved.len(), 2);
    let fluff = saved.iter().find(|(_, n, _)| n == "FLUFF").expect("upserted row");
    assert_eq!(fluff.2, "{\"a\":3}");
    // Author index backfilled from authors_json.
    assert_eq!(db.get_works_by_author("writer_two").unwrap().len(), 1);
    // v12: the pseud-keyed row folded into the account row — pseud learned,
    // avatar kept, comment re-pointed with the posting pseud preserved.
    // v31 adds a row for writer_two, the byline the author links needed.
    let non_guest: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM users WHERE source_id NOT LIKE 'guest:%'", [], |r| r.get(0)).unwrap();
    assert_eq!(non_guest, 2);
    assert!(!db.work_author_ids(db.get_works_by_author("writer_two").unwrap()[0].id).is_empty());
    let folded = db.get_ao3_user_record("writer_one").expect("profile row kept");
    assert!(folded.property(crate::user_fields::PROFILE_FETCHED_AT).is_some());
    assert_eq!(folded.field(crate::user_fields::UserField::NumericId), Some("11"));
    assert_eq!(folded.field(crate::user_fields::UserField::AvatarUrl), Some("http://a/pen.png"));
    let pseuds: Vec<String> = serde_json::from_str(folded.field(crate::user_fields::UserField::Pseuds).unwrap()).unwrap();
    assert_eq!(pseuds, vec!["writer_one".to_string(), "PenOne".to_string()]);
    assert_eq!(db.get_ao3_user("PenOne").unwrap().map(|u| u.id), Some("writer_one".to_string()));
    let comments = db.get_comments(7, 0).unwrap();
    let by_pen = comments.iter().find(|c| c.id == 1).unwrap();
    assert_eq!(by_pen.author.id, "writer_one");
    assert_eq!(by_pen.author.username, "PenOne (writer_one)");
    assert_eq!(by_pen.author.avatar_url.as_deref(), Some("http://a/pen.png"));
    let by_guest = comments.iter().find(|c| c.id == 2).unwrap();
    assert_eq!(by_guest.author.username, "A Guest (Guest)");
    // v8: tags backfilled into the join tables from the JSON columns
    // (which are gone), and reads hydrate from work_tags.
    let legacy = db.get_work(7).unwrap().unwrap();
    assert_eq!(legacy.fandoms, vec!["F"]);
    let json_cols: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('works')
         WHERE name IN ('fandoms_json','relationships_json','characters_json','tags_json')",
        [], |r| r.get(0)).unwrap();
    assert_eq!(json_cols, 0);
    // Epoch strings converted to the one datetime encoding.
    let writer = db.follow_target("author", "writer_one").unwrap();
    assert_eq!(db.get_works_crawled_at(writer).unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    assert_eq!(db.get_last_check_time().unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    // Orphaned table dropped.
    let old_count: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'subscription_snapshots_old'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(old_count, 0);
    // v10 stripped the 'account-' prefix; v26 keys the account by row with
    // the lowercased username as its external id. The active account
    // still sees exactly its own rows: its old bookmark became the app
    // flag plus an AO3 record (it carried a note); the signed-out era row
    // became a record with no owner.
    let active = db.get_active_account().unwrap().unwrap();
    assert_eq!((active.external_id.as_str(), active.username.as_str()), ("writer_one", "Writer_One"));
    assert_eq!(db.get_bookmarks().unwrap(), vec![7]);
    assert_eq!(db.get_bookmark_full(7).unwrap().unwrap().0, "prefixed era");
    let sentinel_note: String = db.conn.query_row(
        "SELECT note FROM ao3_bookmarks WHERE owner = '' AND kind = 'work' AND target_id = 7",
        [], |r| r.get(0)).unwrap();
    assert_eq!(sentinel_note, "signed-out era");
    // v21: the unfollowed snapshot row is gone; nothing is followed.
    assert!(db.get_follows(None).unwrap().is_empty());
    // Reopening runs zero migrations and stays at the current version.
    drop(db);
    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    let _ = std::fs::remove_file(&path);
}

/// A hand-authored v25 library — every pre-v26 shape with representative
/// synthetic rows — opened by this build: the whole-schema rebuild runs
/// once, after filing a snapshot under Backups/.
#[test]
fn test_migration_v25_to_v26() {
    let dir = std::env::temp_dir().join(format!("ao3_v26_test_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("library.db");
    let path_str = path.to_string_lossy().to_string();
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE works (
                id INTEGER PRIMARY KEY, title TEXT NOT NULL, authors_json TEXT NOT NULL,
                rating TEXT NOT NULL, warnings_json TEXT NOT NULL, categories_json TEXT NOT NULL,
                summary TEXT NOT NULL, word_count INTEGER NOT NULL, chapter_count INTEGER NOT NULL,
                total_chapters INTEGER, kudos INTEGER NOT NULL, hits INTEGER NOT NULL,
                bookmarks INTEGER NOT NULL, comments INTEGER NOT NULL,
                date_published TEXT NOT NULL DEFAULT '', date_updated TEXT NOT NULL,
                language TEXT NOT NULL, complete INTEGER NOT NULL,
                series_json TEXT NOT NULL DEFAULT '[]', detail_viewed_at TEXT NOT NULL DEFAULT '',
                last_read_dt TEXT NOT NULL DEFAULT '', gone_from_ao3 INTEGER NOT NULL DEFAULT 0,
                fetched_at TEXT NOT NULL DEFAULT '', last_chapter_read INTEGER NOT NULL DEFAULT 0,
                last_chapter_read_pos INTEGER NOT NULL DEFAULT 0,
                warnings_mask INTEGER NOT NULL DEFAULT 0, categories_mask INTEGER NOT NULL DEFAULT 0,
                fandom_count INTEGER NOT NULL DEFAULT 0, finished INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE chapters (work_id INTEGER NOT NULL, number INTEGER NOT NULL, chapter_id INTEGER,
                title TEXT, content_json TEXT NOT NULL, notes_before TEXT, notes_after TEXT,
                comments_fetched_at INTEGER, PRIMARY KEY (work_id, number));
            CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
                tag_type TEXT NOT NULL DEFAULT '', uses INTEGER NOT NULL DEFAULT 1,
                canonical INTEGER NOT NULL DEFAULT 0, last_seen TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE work_tags (work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                tag_type TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (work_id, tag_id));
            CREATE TABLE work_authors (work_id INTEGER NOT NULL, author TEXT NOT NULL,
                PRIMARY KEY (author, work_id));
            CREATE TABLE collections (name TEXT PRIMARY KEY, title TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '', is_open INTEGER NOT NULL DEFAULT 0,
                is_moderated INTEGER NOT NULL DEFAULT 0, is_anonymous INTEGER NOT NULL DEFAULT 0,
                work_count INTEGER NOT NULL DEFAULT 0, bookmarked_count INTEGER NOT NULL DEFAULT 0,
                maintainers_json TEXT NOT NULL DEFAULT '[]', collection_type TEXT NOT NULL DEFAULT '',
                fetched_at TEXT NOT NULL DEFAULT '', profile_fetched_at TEXT NOT NULL DEFAULT '');
            CREATE TABLE collection_tags (collection_name TEXT NOT NULL, tag_id INTEGER NOT NULL,
                position INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (collection_name, tag_id));
            CREATE TABLE collection_works (collection_name TEXT NOT NULL, work_id INTEGER NOT NULL,
                PRIMARY KEY (collection_name, work_id));
            CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
                authors_json TEXT NOT NULL DEFAULT '[]', summary TEXT NOT NULL DEFAULT '',
                word_count INTEGER NOT NULL DEFAULT 0, work_count INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 0, date_updated TEXT NOT NULL DEFAULT '',
                fetched_at TEXT NOT NULL DEFAULT '');
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL DEFAULT '[none]', bookmark_type TEXT NOT NULL,
                target_id INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '',
                tag_string TEXT NOT NULL DEFAULT '', collection_names TEXT NOT NULL DEFAULT '',
                private INTEGER NOT NULL DEFAULT 1, rec INTEGER NOT NULL DEFAULT 0,
                sync_to_ao3 INTEGER NOT NULL DEFAULT 0, ao3_bookmark_id INTEGER,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE (account_id, bookmark_type, target_id));
            CREATE TABLE collection_bookmarks (collection_name TEXT NOT NULL, bookmark_id INTEGER NOT NULL,
                PRIMARY KEY (collection_name, bookmark_id));
            CREATE TABLE accounts (id TEXT PRIMARY KEY, username TEXT NOT NULL,
                password TEXT NOT NULL DEFAULT '', cookies TEXT NOT NULL DEFAULT '',
                is_active INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE ao3_users (id TEXT PRIMARY KEY, username TEXT NOT NULL,
                profile_url TEXT NOT NULL DEFAULT '', avatar_url TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL DEFAULT (datetime('now')), numeric_id TEXT NOT NULL DEFAULT '',
                joined TEXT NOT NULL DEFAULT '', location TEXT NOT NULL DEFAULT '',
                birthday TEXT NOT NULL DEFAULT '', pseuds_json TEXT NOT NULL DEFAULT '[]',
                bio_json TEXT NOT NULL DEFAULT '[]', works_count INTEGER NOT NULL DEFAULT 0,
                series_count INTEGER NOT NULL DEFAULT 0, bookmarks_count INTEGER NOT NULL DEFAULT 0,
                collections_count INTEGER NOT NULL DEFAULT 0, gifts_count INTEGER NOT NULL DEFAULT 0,
                is_blocked INTEGER NOT NULL DEFAULT 0, block_ao3_id TEXT NOT NULL DEFAULT '',
                is_muted INTEGER NOT NULL DEFAULT 0, mute_ao3_id TEXT NOT NULL DEFAULT '',
                profile_fetched_at TEXT NOT NULL DEFAULT '');
            CREATE TABLE comments (id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL DEFAULT 0,
                chapter_id INTEGER NOT NULL DEFAULT 0, parent_id INTEGER NOT NULL DEFAULT 0,
                author_id TEXT NOT NULL, posted_at TEXT NOT NULL DEFAULT '',
                content_json TEXT NOT NULL DEFAULT '[]', cached_at TEXT NOT NULL DEFAULT (datetime('now')),
                author_pseud TEXT NOT NULL DEFAULT '', chapter_label TEXT NOT NULL DEFAULT '',
                notice TEXT NOT NULL DEFAULT '', more_replies INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE inbox_messages (comment_id INTEGER PRIMARY KEY, author TEXT NOT NULL,
                author_url TEXT NOT NULL DEFAULT '', avatar_url TEXT NOT NULL DEFAULT '',
                work_reference TEXT NOT NULL, work_url TEXT NOT NULL DEFAULT '', posted_at TEXT NOT NULL,
                is_unread INTEGER NOT NULL DEFAULT 1, content_json TEXT NOT NULL DEFAULT '[]',
                fetched_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE follows (kind TEXT NOT NULL, target_id TEXT NOT NULL COLLATE NOCASE,
                name TEXT NOT NULL, added_at TEXT NOT NULL DEFAULT (datetime('now')), date_updated TEXT,
                last_checked_at TEXT, total_works INTEGER, last_census_at TEXT, census_state TEXT,
                status INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (kind, target_id));
            CREATE TABLE crawl_stamps (kind TEXT NOT NULL, target_id TEXT NOT NULL COLLATE NOCASE,
                crawled_at TEXT NOT NULL, PRIMARY KEY (kind, target_id));
            CREATE TABLE subscriptions (account TEXT NOT NULL COLLATE NOCASE, sub_type TEXT NOT NULL,
                sub_id TEXT NOT NULL COLLATE NOCASE, name TEXT NOT NULL, ao3_id TEXT,
                PRIMARY KEY (account, sub_type, sub_id));
            CREATE TABLE comment_drafts (account_id TEXT NOT NULL COLLATE NOCASE, work_id INTEGER NOT NULL,
                chapter_id INTEGER NOT NULL DEFAULT 0, parent_comment_id INTEGER NOT NULL DEFAULT 0,
                body TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (account_id, work_id, chapter_id));
            CREATE TABLE downloads (work_id INTEGER PRIMARY KEY, created_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE history (work_id INTEGER NOT NULL, accessed_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE kudos_given (work_id INTEGER PRIMARY KEY);
            CREATE TABLE reading_lists (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE reading_list_items (list_id INTEGER NOT NULL, work_id INTEGER NOT NULL,
                added_at TEXT NOT NULL DEFAULT (datetime('now')), sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (list_id, work_id));
            CREATE TABLE subscription_new_works (work_id INTEGER PRIMARY KEY,
                added_at TEXT NOT NULL DEFAULT (datetime('now')), seen_at TEXT NOT NULL DEFAULT '');
            CREATE TABLE notifications (id INTEGER PRIMARY KEY AUTOINCREMENT, notif_type TEXT NOT NULL,
                work_id INTEGER NOT NULL, author TEXT NOT NULL, title TEXT NOT NULL, message TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')), read INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE request_log (id INTEGER PRIMARY KEY AUTOINCREMENT, started_ms INTEGER NOT NULL,
                method TEXT NOT NULL, url TEXT NOT NULL, status INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
                req_bytes INTEGER NOT NULL, resp_bytes INTEGER NOT NULL, error TEXT, payload TEXT, transport TEXT);
            CREATE TABLE image_cache (key TEXT PRIMARY KEY, data BLOB NOT NULL,
                fetched_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE saved_searches (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
                params_json TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE UNIQUE INDEX idx_saved_searches_name_nocase ON saved_searches(name COLLATE NOCASE);
            CREATE TABLE route_timeouts (route_key TEXT PRIMARY KEY, timeout_secs INTEGER NOT NULL);
            CREATE TABLE custom_themes (id TEXT PRIMARY KEY, name TEXT NOT NULL, theme_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now')));
            CREATE TABLE session_cache (cache_key TEXT PRIMARY KEY, data_json TEXT NOT NULL, session_id TEXT NOT NULL);
            CREATE TABLE debug_log (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL DEFAULT (datetime('now')),
                level TEXT NOT NULL, tag TEXT NOT NULL, message TEXT NOT NULL);
            INSERT INTO app_state VALUES ('known_tags_backfilled', '1');

            -- Two spellings of one account: the legacy duplicate folds into the active row.
            INSERT INTO accounts (id, username, cookies, is_active, created_at) VALUES
                ('reader', 'Reader', 'remember_user_token=x', 1, '2026-01-02 00:00:00'),
                ('migrated-Reader', 'Reader', '', 0, '2026-01-01 00:00:00');
            INSERT INTO ao3_users (id, username, profile_url, pseuds_json) VALUES
                ('writer_one', 'writer_one', 'https://archiveofourown.org/users/writer_one', '[\"Pen\"]'),
                ('guest:abc', 'A Guest (Guest)', '', '[]');
            INSERT INTO works (id, title, authors_json, rating, warnings_json, categories_json, summary,
                word_count, chapter_count, total_chapters, kudos, hits, bookmarks, comments, date_updated,
                language, complete, series_json, fetched_at, last_chapter_read) VALUES
                (1000, 'Work One', '[\"writer_one\"]', 'Teen', '[]', '[]', 's', 10, 1, 1, 5, 50, 1, 2,
                 '2025-01-01', 'English', 1,
                 '[{\"series_id\":501,\"name\":\"S\",\"part\":2,\"prev_work_id\":null,\"next_work_id\":2000}]',
                 '2026-01-01 00:00:00', 1),
                (2000, 'Work Two', '[\"Pen (writer_one)\"]', 'General', '[]', '[]', 's', 20, 2, 2, 0, 0, 0, 0,
                 '2025-02-02', 'English', 1, '[]', '2026-01-01 00:00:00', 0),
                (3000, 'Work Three', '[\"someone_else\"]', 'Mature', '[]', '[]', 's', 30, 3, 3, 1, 1, 1, 1,
                 '2025-03-03', 'English', 0, '[]', '2026-01-01 00:00:00', 0);
            INSERT INTO tags (id, name, tag_type) VALUES (1, 'Fandom A', 'fandom'), (2, 'Fluff', 'freeform');
            INSERT INTO work_tags VALUES (1000, 1, 'fandom', 0), (1000, 2, 'freeform', 1);
            -- An orphan a real library carries from a deletion made while
            -- enforcement was off.
            PRAGMA foreign_keys = OFF;
            INSERT INTO work_tags VALUES (7777, 1, 'fandom', 0);
            PRAGMA foreign_keys = ON;
            INSERT INTO work_authors VALUES (1000, 'writer_one'), (2000, 'Pen (writer_one)'), (3000, 'someone_else');
            INSERT INTO series (id, name) VALUES (501, 'S');
            INSERT INTO chapters (work_id, number, chapter_id, content_json) VALUES
                (1000, 1, 90001, '[]'), (4000, 1, 90002, '[]');
            INSERT INTO collections (name, title, work_count) VALUES ('fest', 'The Fest', 2);
            INSERT INTO collection_tags VALUES ('fest', 1, 0);
            INSERT INTO collection_works VALUES ('fest', 1000), ('fest', 2000);
            INSERT INTO bookmarks (id, account_id, bookmark_type, target_id, note, sync_to_ao3, ao3_bookmark_id, private) VALUES
                (1, 'reader', 'work', 1000, '', 0, NULL, 1),
                (2, '[none]', 'work', 2000, 'signed out', 0, NULL, 1),
                (3, 'reader', 'work', 3000, 'synced', 1, 77001, 0),
                (4, 'someoneelse', 'work', 3000, 'theirs', 1, 77002, 0),
                (5, 'reader', 'series', 501, '', 0, NULL, 1);
            INSERT INTO collection_bookmarks VALUES ('fest', 3), ('fest', 4);
            INSERT INTO comments (id, work_id, chapter_id, parent_id, author_id, content_json) VALUES
                (10, 1000, 90001, 0, 'writer_one', '[]'),
                (11, 1000, 90001, 10, 'guest:abc', '[]'),
                (12, 1000, 90001, 999, 'writer_one', '[]'),
                (13, 4000, 0, 0, 'writer_one', '[]');
            INSERT INTO inbox_messages (comment_id, author, work_reference, posted_at) VALUES (555, 'ann', 'Work One', 'now');
            INSERT INTO follows (kind, target_id, name, date_updated, status) VALUES
                ('author', 'writer_one', 'Pen (writer_one)', '2025-01-01', 0),
                ('work', '1000', 'Work One', NULL, 0),
                ('work', '8000', 'Followed Elsewhere', '2024-01-01', 2),
                ('series', '502', 'Unknown Series', NULL, 0),
                ('fandom', 'Fandom A', 'Fandom A', NULL, 0);
            INSERT INTO crawl_stamps VALUES ('author', 'writer_one', '2025-05-05 00:00:00'), ('series', '501', '2025-06-06 00:00:00');
            INSERT INTO subscriptions VALUES ('Reader', 'author', 'writer_one', 'writer_one', '11'), ('Reader', 'work', '1000', 'Work One', NULL);
            INSERT INTO comment_drafts VALUES ('Reader', 1000, 0, 10, 'draft text', '2026-02-02 00:00:00');
            INSERT INTO downloads (work_id) VALUES (1000), (4000);
            INSERT INTO history (work_id, accessed_at) VALUES (1000, '2026-01-03 00:00:00'), (4000, '2026-01-04 00:00:00');
            INSERT INTO kudos_given VALUES (2000);
            INSERT INTO reading_lists (id, name) VALUES (1, 'Later');
            INSERT INTO reading_list_items (list_id, work_id) VALUES (1, 1000), (1, 4000);
            INSERT INTO subscription_new_works (work_id) VALUES (2000), (4000);
            INSERT INTO notifications (notif_type, work_id, author, title, message) VALUES ('inbox_comment', 555, 'ann', 'Work One', 'm');
            INSERT INTO request_log (started_ms, method, url, status, duration_ms, req_bytes, resp_bytes) VALUES (1, 'GET', 'https://x', 200, 1, 1, 1);
            PRAGMA user_version = 25;",
        ).unwrap();
    }

    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    // v27 rode along: the work_id indexes on the join tables.
    for idx in ["idx_work_authors_work", "idx_history_work", "idx_reading_list_items_work"] {
        let n: u32 = db.conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1", [idx], |r| r.get(0)).unwrap();
        assert_eq!(n, 1, "{idx} missing after migration");
    }

    // The snapshot was filed under Backups/ beside the library.
    let backups: Vec<String> = std::fs::read_dir(dir.join("Backups")).unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
    assert!(backups.iter().any(|n| n.ends_with(".db")), "backups = {backups:?}");
    assert!(backups.iter().any(|n| n.ends_with(".json")), "backups = {backups:?}");
    // v26 and v31 each snapshot the library before rebuilding; the v26
    // one is the pre-v26 library.
    let versions: Vec<u32> = backups.iter().filter(|n| n.ends_with(".db")).map(|snapshot| {
        let snap = rusqlite::Connection::open(dir.join("Backups").join(snapshot)).unwrap();
        library_file::user_version(&snap).unwrap()
    }).collect();
    assert!(versions.contains(&25), "a snapshot is the pre-v26 library: {versions:?}");
    assert!(versions.contains(&30), "a snapshot is the pre-v31 library: {versions:?}");
    let violations: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r.get(0)).unwrap();
    assert_eq!(violations, 0);

    // Works keep their AO3 numbers as row ids and gain their identity.
    let w1 = db.get_work(1000).unwrap().expect("work 1000");
    assert_eq!((w1.source.as_str(), w1.external_id.as_str(), w1.url.as_str()),
               ("ao3", "1000", "https://archiveofourown.org/works/1000"));
    assert_eq!((w1.word_count, w1.kudos), (Some(10), Some(5)));
    assert_eq!(w1.fandoms, vec!["Fandom A".to_string()]);
    assert_eq!(db.resolve_work(SOURCE_AO3, "3000"), Some(3000));
    // series_json was rewritten: the series row id (its AO3 number) and
    // external ids for the adjacent works.
    assert_eq!(w1.series.len(), 1);
    assert_eq!((w1.series[0].series_id, w1.series[0].series_external_id.as_str(), w1.series[0].part),
               (501, "501", 2));
    assert_eq!(w1.series[0].next_work_external_id.as_deref(), Some("2000"));
    assert!(w1.series[0].prev_work_external_id.is_none());
    assert_eq!(db.get_series(501).unwrap().unwrap().external_id, "501");

    // Follows resolve to rows of every kind; the followed-but-missing
    // work and series became stubs under their AO3 numbers.
    assert!(db.is_work_stub(8000));
    assert!(db.get_work(8000).unwrap().is_none());
    assert!(!db.get_all_works().unwrap().iter().any(|w| w.id == 8000));
    assert_eq!(db.resolve_work(SOURCE_AO3, "8000"), Some(8000));
    // An orphaned work_tags row (its work deleted while enforcement was
    // off) is purged rather than failing the final foreign-key check.
    let orphan_tags: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM work_tags WHERE work_id = 7777", [], |r| r.get(0)).unwrap();
    assert_eq!(orphan_tags, 0);
    assert_eq!(db.get_series(502).unwrap().unwrap().name, "Unknown Series");
    let follows: Vec<(String, String, String)> = db.get_follows(None).unwrap().into_iter()
        .map(|f| (f.target.kind().to_string(), f.bridge_id, f.name)).collect();
    let writer_row = db.ao3_user_row_id("writer_one").unwrap().to_string();
    assert_eq!(follows, vec![
        ("author".into(), writer_row, "Pen (writer_one)".into()),
        ("work".into(), "1000".into(), "Work One".into()),
        ("work".into(), "8000".into(), "Followed Elsewhere".into()),
        ("series".into(), "502".into(), "Unknown Series".into()),
        ("fandom".into(), "Fandom A".into(), "Fandom A".into()),
    ]);
    let writer = db.follow_target("author", "writer_one").unwrap();
    assert_eq!(db.get_follow_baseline(writer).unwrap().as_deref(), Some("2025-01-01"));
    assert_eq!(db.get_follow_status(FollowTarget::Work(8000)).unwrap(), 2);
    assert_eq!(db.get_works_crawled_at(writer).unwrap().as_deref(), Some("2025-05-05 00:00:00"));
    assert_eq!(db.get_works_crawled_at(FollowTarget::Series(501)).unwrap().as_deref(), Some("2025-06-06 00:00:00"));
    assert_eq!(db.get_check_targets().unwrap().len(), 4, "author + 2 works + series; the fandom is never checked");

    // Accounts folded to one row, the active one, with the lowercased
    // username as its external id; account-scoped data points at it.
    let accounts = db.get_all_accounts().unwrap();
    assert_eq!(accounts.len(), 1);
    let reader = &accounts[0];
    assert!(reader.is_active && reader.logged_in());
    assert_eq!((reader.external_id.as_str(), reader.username.as_str()), ("reader", "Reader"));
    let subs = db.get_subscriptions(reader.id).unwrap();
    assert_eq!(subs.len(), 2);
    assert_eq!(db.get_subscription_ao3_id(reader.id, "author", "writer_one").unwrap().as_deref(), Some("11"));
    assert_eq!(db.get_comment_draft(1000, 0).unwrap().map(|d| (d.parent_comment_id, d.body)),
               Some((10, "draft text".to_string())));

    // Comments: parent chains survive as row references; the reply whose
    // parent was never cached is dropped (it would otherwise show as a
    // root), as is the comment whose work is gone.
    let comments = db.get_comments(1000, 0).unwrap();
    let ids: Vec<u64> = comments.iter().map(|c| c.id).collect();
    assert_eq!(ids, vec![10]);
    assert_eq!(comments[0].replies.iter().map(|c| c.id).collect::<Vec<_>>(), vec![11]);
    assert_eq!(comments[0].replies[0].author.username, "A Guest (Guest)");
    assert_eq!(db.comment_context(11).unwrap(), Some((1000, 90001, 10)));
    let total: i64 = db.conn.query_row("SELECT COUNT(*) FROM comments", [], |r| r.get(0)).unwrap();
    assert_eq!(total, 2);
    assert!(db.has_inbox_message(555).unwrap());

    // Dependents that borrowed a missing work number are gone; the rest
    // keep their rows.
    assert_eq!(db.get_chapters(1000).unwrap().len(), 1);
    assert!(db.get_chapters(4000).unwrap().is_empty());
    assert_eq!(db.get_downloaded_ids().unwrap(), vec![1000]);
    assert_eq!(db.get_history().unwrap().len(), 1);
    assert_eq!(db.get_kudos_given().unwrap(), vec![2000]);
    assert_eq!(db.get_reading_list_items(1).unwrap(), vec![1000]);
    assert_eq!(db.get_new_work_ids().unwrap(), vec![2000]);
    assert_eq!(db.get_notifications().unwrap()[0].2, 555);
    let source: String = db.conn.query_row("SELECT source FROM request_log", [], |r| r.get(0)).unwrap();
    assert_eq!(source, "ao3");

    // Collections keyed by row; their joins moved with them.
    let fest = db.get_collection("fest").unwrap().unwrap();
    assert_eq!((fest.title.as_str(), fest.url.as_str()), ("The Fest", "https://archiveofourown.org/collections/fest"));
    assert_eq!(fest.tags, vec!["Fandom A".to_string()]);
    assert_eq!(db.get_collection_work_ids("fest").unwrap(), vec![1000, 2000]);

    // The bookmarks split: a plain local bookmark is a flag only; the
    // signed-out note is a record with no owner; the synced one is both;
    // the other user's is a record with no account; the series flag too.
    let mut flagged = db.get_bookmark_targets().unwrap();
    flagged.sort_by_key(|t| (t.kind(), t.id()));
    assert_eq!(flagged, vec![BookmarkTarget::Series(501), BookmarkTarget::Work(1000), BookmarkTarget::Work(3000)]);
    assert!(db.get_bookmark_details(1000).unwrap().is_none());
    assert_eq!(db.get_bookmark_full(3000).unwrap().unwrap(), ("synced".to_string(), true, Some(77001)));
    let records: Vec<(String, Option<i64>, i64, Option<i64>)> = {
        let mut stmt = db.conn.prepare(
            "SELECT owner, account_id, target_id, ao3_bookmark_id FROM ao3_bookmarks ORDER BY id").unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap()
            .collect::<Result<_, _>>().unwrap()
    };
    assert_eq!(records, vec![
        ("".to_string(), None, 2000, None),
        ("reader".to_string(), Some(reader.id), 3000, Some(77001)),
        ("someoneelse".to_string(), None, 3000, Some(77002)),
    ]);
    let hits = db.get_collection_bookmarks("fest").unwrap();
    assert_eq!(hits.iter().map(|h| h.bookmarker.as_str()).collect::<Vec<_>>(), vec!["reader", "someoneelse"]);
    assert_eq!(db.get_user_bookmarks("SomeoneElse").unwrap().len(), 1);

    // Reopening runs zero migrations.
    drop(db);
    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    assert_eq!(db.get_all_works().unwrap().len(), 3);
    drop(db);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn test_downgrade_guard() {
    let path = std::env::temp_dir().join(format!("ao3_downgrade_test_{}.db", std::process::id()));
    let path_str = path.to_string_lossy().to_string();
    let _ = std::fs::remove_file(&path);
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.pragma_update(None, "user_version", 99).unwrap();
    }
    let result = Storage::open(&path_str, "");
    assert!(result.is_err(), "a newer-versioned DB must refuse to open");
    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// SQL search parity: search_library_work_ids against the work_matches /
// sort_filtered oracle. The fixture library is hand-authored synthetic data
// exercising every filterable field; sort keys are unique per work so
// orderings are deterministic on both paths.
// ---------------------------------------------------------------------------

fn parity_library() -> Vec<WorkSummary> {
    let mut w1 = sample_work(1); // the sample defaults, see sample_work
    w1.date_published = "2024-11-02".into();

    let mut w2 = sample_work(2);
    w2.title = "Another Story".into();
    w2.fandoms = vec!["Fandom B".into(), "Fandom C".into()];
    w2.rating = Rating::Explicit;
    w2.warnings = vec![Warning::Violence];
    w2.categories = vec!["M/M".into()];
    w2.relationships = vec!["C/D".into()];
    w2.characters = vec!["Character C".into()];
    w2.tags = vec!["Slow Burn".into()];
    w2.summary = "A long slow burn".into();
    w2.word_count = Some(100_000);
    w2.chapter_count = 1;
    w2.complete = true;
    w2.language = "Deutsch".into();
    w2.date_published = "2019-01-01".into();
    w2.date_updated = "2026-08-01".into();
    w2.kudos = Some(500); w2.hits = Some(5000); w2.bookmarks = Some(50); w2.comments = Some(20);

    // Never-updated, unrated, no fandoms/categories/tags: the empty edges.
    let mut w3 = sample_work(3);
    w3.title = "Blank Slate".into();
    w3.authors = vec!["Anon".into()];
    w3.fandoms = vec![];
    w3.rating = Rating::NotRated;
    w3.warnings = vec![Warning::CreatorChoseNotToWarn];
    w3.categories = vec![];
    w3.relationships = vec![];
    w3.characters = vec![];
    w3.tags = vec![];
    w3.summary = String::new();
    w3.word_count = Some(0);
    w3.chapter_count = 2;
    w3.date_published = String::new();
    w3.date_updated = String::new();
    w3.kudos = Some(3); w3.hits = Some(10); w3.bookmarks = Some(0); w3.comments = Some(0);

    // Unicode everywhere ao3_lower must fold beyond ASCII.
    let mut w4 = sample_work(4);
    w4.title = "Höhle Ünïcode".into();
    w4.authors = vec!["Ökonom".into()];
    w4.fandoms = vec!["Café Fandom".into()];
    w4.rating = Rating::Teen;
    w4.warnings = vec![Warning::CreatorChoseNotToWarn];
    w4.categories = vec!["F/F".into()];
    w4.relationships = vec!["Åsa/Öther".into()];
    w4.characters = vec!["Åsa".into()];
    w4.tags = vec!["Café au Lait".into()];
    w4.summary = "Kaffee und Kuchen".into();
    w4.word_count = Some(4200);
    w4.chapter_count = 2;
    w4.language = "Français".into();
    w4.date_published = "2021-04-04".into();
    w4.date_updated = "2024-02-02".into();
    w4.kudos = Some(15); w4.hits = Some(250); w4.bookmarks = Some(3); w4.comments = Some(2);

    // Multiple warnings and categories — the AND semantics.
    let mut w5 = sample_work(5);
    w5.title = "Gen Multi Tale".into();
    w5.warnings = vec![Warning::None, Warning::CharacterDeath];
    w5.categories = vec!["Gen".into(), "Multi".into()];
    w5.rating = Rating::General;
    w5.chapter_count = 4;
    w5.complete = true;
    w5.word_count = Some(56_000);
    w5.date_published = "2022-05-05".into();
    w5.date_updated = "2025-06-30".into();
    w5.kudos = Some(99); w5.hits = Some(340); w5.bookmarks = Some(9); w5.comments = Some(5);

    let mut w6 = sample_work(6);
    w6.title = "Dark Fic".into();
    w6.fandoms = vec!["Fandom D".into()];
    w6.rating = Rating::Mature;
    w6.warnings = vec![Warning::Underage, Warning::Noncon];
    w6.categories = vec!["Other".into()];
    w6.tags = vec!["Dead Dove: Do Not Eat".into()];
    w6.word_count = Some(8000);
    w6.chapter_count = 7;
    w6.date_published = "2018-06-06".into();
    w6.date_updated = "2022-12-12".into();
    w6.kudos = Some(200); w6.hits = Some(700); w6.bookmarks = Some(14); w6.comments = Some(11);

    // The big-number extremes.
    let mut w7 = sample_work(7);
    w7.title = "Epic Saga".into();
    w7.authors = vec!["Author1".into()];
    w7.fandoms = vec!["Fandom B".into()];
    w7.rating = Rating::Explicit;
    w7.warnings = vec![Warning::Violence, Warning::CharacterDeath];
    w7.categories = vec!["M/M".into(), "Multi".into()];
    w7.word_count = Some(250_000);
    w7.chapter_count = 100;
    w7.complete = true;
    w7.date_published = "2025-07-07".into();
    w7.date_updated = "2026-01-01".into();
    w7.kudos = Some(20_000); w7.hits = Some(999_999); w7.bookmarks = Some(8000); w7.comments = Some(3000);

    let mut w8 = sample_work(8);
    w8.title = "Tiny Drabble".into();
    w8.authors = vec!["Writer (Pseud)".into()];
    w8.rating = Rating::General;
    w8.categories = vec!["Gen".into()];
    w8.word_count = Some(930);
    w8.chapter_count = 1;
    w8.complete = true;
    w8.date_published = "2017-08-08".into();
    w8.date_updated = "2021-07-07".into();
    w8.kudos = Some(64); w8.hits = Some(88); w8.bookmarks = Some(21); w8.comments = Some(9);

    let mut w9 = sample_work(9);
    w9.title = "Comma, The Title".into();
    w9.authors = vec!["Zeta".into()];
    w9.warnings = vec![];
    w9.categories = vec![];
    w9.tags = vec![];
    w9.word_count = Some(777);
    w9.chapter_count = 1;
    w9.complete = true;
    w9.date_published = "2020-05-05".into();
    w9.date_updated = "2020-06-06".into();
    w9.kudos = Some(7); w9.hits = Some(70); w9.bookmarks = Some(1); w9.comments = Some(4);

    // A category label outside AO3's fixed vocabulary (mask fallback path).
    let mut w10 = sample_work(10);
    w10.title = "Weird Category".into();
    w10.rating = Rating::Mature;
    w10.categories = vec!["Weird".into()];
    w10.word_count = Some(66_666);
    w10.chapter_count = 5;
    w10.date_published = "2016-10-10".into();
    w10.date_updated = "2023-03-03".into();
    w10.kudos = Some(150); w10.hits = Some(410); w10.bookmarks = Some(33); w10.comments = Some(13);

    vec![w1, w2, w3, w4, w5, w6, w7, w8, w9, w10]
}

fn assert_search_parity(db: &Storage, c: &LocalSearchCriteria) {
    let oracle: Vec<u64> = db
        .search_local_works_filtered(c, 0)
        .unwrap()
        .iter()
        .map(|w| w.id)
        .collect();
    let sql = db.search_library_work_ids(c).unwrap();
    assert_eq!(sql, oracle, "SQL vs oracle diverged for criteria: {c:?}");
}

#[test]
fn test_search_fully_downloaded() {
    let db = open_test_db();
    // (id, total_chapters, chapter rows stored)
    for (id, total, stored) in [
        (1, Some(3), 3), // complete download
        (2, Some(3), 2), // missing a chapter
        (3, None, 2),    // "?" total never qualifies
        (4, Some(1), 1), // one-shot, downloaded
        (5, Some(2), 0), // metadata only
    ] {
        let mut w = sample_work(id);
        w.total_chapters = total;
        db.save_work(&w).unwrap();
        for n in 1..=stored {
            db.save_chapter(id, &sample_chapter(n)).unwrap();
        }
    }
    // The fixtures share sort keys, so compare as sets: the oracle's order
    // among ties is arbitrary.
    let sorted = |mut v: Vec<u64>| { v.sort(); v };
    let oracle = |c: &LocalSearchCriteria| sorted(
        db.search_local_works_filtered(c, 0).unwrap().iter().map(|w| w.id).collect());
    let c = LocalSearchCriteria { fully_downloaded: true, ..Default::default() };
    assert_eq!(sorted(db.search_library_work_ids(&c).unwrap()), vec![1, 4]);
    assert_eq!(oracle(&c), vec![1, 4]);
    let c = LocalSearchCriteria { fully_downloaded: true, title: "Work 4".into(), ..Default::default() };
    assert_eq!(db.search_library_work_ids(&c).unwrap(), vec![4]);
    assert_eq!(oracle(&c), vec![4]);
}

#[test]
fn test_sql_search_parity_matrix() {
    let db = open_test_db();
    for w in parity_library() {
        db.save_work(&w).unwrap();
    }

    let mut cases: Vec<LocalSearchCriteria> = Vec::new();
    let mut push = |f: &dyn Fn(&mut LocalSearchCriteria)| {
        let mut c = LocalSearchCriteria::default();
        f(&mut c);
        cases.push(c);
    };

    // Blank form — the whole library.
    push(&|_| {});

    // Free-text query across every searchable field, including Unicode
    // case folding and a no-hit probe.
    for q in ["fluff", "another", "author1", "slow burn", "HÖHLE", "café",
              "pseud", "kuchen", "zzz-nothing"] {
        push(&move |c| c.query = q.into());
    }

    // Title, ASCII and Unicode case-insensitive.
    for t in ["story", "STORY", "höhle", "The Title", "missing title"] {
        push(&move |c| c.title = t.into());
    }

    // Creators: single, AND pair, substring, unicode, miss.
    for a in ["author1", "Author1, Author2", "uthor", "ökonom", "nobody"] {
        push(&move |c| c.creators = a.into());
    }

    // Tag-name fields: exact, substring-multi, comma-AND, unicode, miss.
    for f in ["Fandom A", "fandom", "Fandom B, Fandom C", "café", "nope"] {
        push(&move |c| c.fandom_names = f.into());
    }
    for ch in ["Character A", "åsa", "no one"] {
        push(&move |c| c.character_names = ch.into());
    }
    for r in ["A/B", "åsa/öther", "x/y"] {
        push(&move |c| c.relationship_names = r.into());
    }
    for t in ["Fluff", "fluff, angst", "dead dove", "café au lait", "unknown tag"] {
        push(&move |c| c.freeform_names = t.into());
    }

    // Ratings OR, including a garbage label (maps to NotRated).
    push(&|c| c.ratings = vec!["Teen And Up Audiences".into()]);
    push(&|c| c.ratings = vec!["Explicit".into(), "Mature".into()]);
    push(&|c| c.ratings = vec!["Bizarre".into()]);

    // Warnings AND.
    push(&|c| c.warnings = vec!["No Archive Warnings Apply".into()]);
    push(&|c| c.warnings = vec!["Major Character Death".into(),
                                "No Archive Warnings Apply".into()]);
    push(&|c| c.warnings = vec!["Rape/Non-Con".into()]);
    push(&|c| c.warnings = vec!["Underage".into(), "Rape/Non-Con".into()]);
    push(&|c| c.warnings = vec!["Creator Chose Not To Use Archive Warnings".into()]);

    // Categories AND, case-folded, plus the outside-vocab fallback.
    push(&|c| c.categories = vec!["Gen".into()]);
    push(&|c| c.categories = vec!["gen".into(), "MULTI".into()]);
    push(&|c| c.categories = vec!["F/M".into()]);
    push(&|c| c.categories = vec!["Weird".into()]);
    push(&|c| c.categories = vec!["weird".into()]);
    push(&|c| c.categories = vec!["F/M".into(), "Weird".into()]);

    // Tri-states and flags.
    for v in ["T", "F"] {
        push(&move |c| c.complete = v.into());
        push(&move |c| c.crossover = v.into());
    }
    push(&|c| c.single_chapter = true);

    // Language equality, ASCII-ci with non-ASCII bytes exact.
    for l in ["english", "Deutsch", "français", "FRANÇAIS", "Klingon"] {
        push(&move |c| c.language = l.into());
    }

    // Numeric ranges: every operator, separators, garbage, overflow.
    for wc in [">50000", "<10000", ">=12345", "<=12345", "12345", "1,000 - 150,000",
               "garbage", ">garbage", "100-abc", "99999999999999999999999"] {
        push(&move |c| c.word_count = wc.into());
    }
    push(&|c| c.hits = ">500".into());
    push(&|c| c.kudos_count = "10-100".into());
    push(&|c| c.comments_count = "<=9".into());
    push(&|c| c.bookmarks_count = ">= 14".into());

    // Date updated: prefixes, absolute befores/afters, relatives, garbage.
    for d in ["2025", "2025-01", "> 2025", "< 2025", "<= 2026-01-01", "2026-08-01",
              "< 1 week ago", "> 1 week ago", "< 100 years ago", "> 100 years ago",
              "garbage date"] {
        push(&move |c| c.revised_at = d.into());
    }

    // Compound: several fields at once.
    push(&|c| {
        c.query = "a".into();
        c.ratings = vec!["Explicit".into()];
        c.complete = "T".into();
        c.word_count = ">50000".into();
    });
    push(&|c| {
        c.fandom_names = "Fandom A".into();
        c.warnings = vec!["No Archive Warnings Apply".into()];
        c.categories = vec!["Gen".into()];
        c.single_chapter = true;
    });

    for c in &cases {
        assert_search_parity(&db, c);
    }
}

#[test]
fn test_sql_search_sort_parity() {
    let db = open_test_db();
    for w in parity_library() {
        db.save_work(&w).unwrap();
    }
    // Every sort column (plus unknown/_score fallbacks) in every direction
    // (including the per-column default). All sort keys in the fixture are
    // unique, so both paths must produce identical orderings.
    for column in ["title_to_sort_on", "created_at", "word_count", "hits",
                   "kudos_count", "comments_count", "bookmarks_count",
                   "revised_at", "_score", ""] {
        for direction in ["", "asc", "desc"] {
            let c = LocalSearchCriteria { sort_column: column.into(), sort_direction: direction.into(), ..Default::default() };
            assert_search_parity(&db, &c);
        }
    }
}

#[test]
fn test_get_works_by_ids_ordered() {
    let db = open_test_db();
    for w in parity_library() {
        db.save_work(&w).unwrap();
    }
    // Order preserved, unknown ids skipped, tags hydrated.
    let works = db.get_works_by_ids_ordered(&[5, 999, 2, 8]).unwrap();
    let ids: Vec<u64> = works.iter().map(|w| w.id).collect();
    assert_eq!(ids, vec![5, 2, 8]);
    assert_eq!(works[1].tags, vec!["Slow Burn".to_string()]);
    assert!(db.get_works_by_ids_ordered(&[]).unwrap().is_empty());
}

#[test]
fn test_search_masks_backfill_v11() {
    // A pre-v11 database (masks absent) must arrive at v11 with masks and
    // fandom_count matching what save_work would now write.
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap();
    // Simulate pre-v11 rows: zero the derived columns behind save_work's back.
    db.conn
        .execute_batch(
            "UPDATE works SET warnings_mask = 0, categories_mask = 0, fandom_count = 0",
        )
        .unwrap();
    db.conn
        .execute_batch(
            "UPDATE works SET fandom_count =
                 (SELECT COUNT(*) FROM work_tags wt
                   WHERE wt.work_id = works.id AND wt.tag_type = 'fandom')",
        )
        .unwrap();
    db.backfill_search_masks_v11().unwrap();
    let (wm, cm, fc): (i64, i64, i64) = db
        .conn
        .query_row(
            "SELECT warnings_mask, categories_mask, fandom_count FROM works WHERE id = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(wm, 1 << 0); // Warning::None
    assert_eq!(cm, 1 << 1); // F/M
    assert_eq!(fc, 1); // Fandom A
}

// ===========================================================================
// Cache invariants — the tags/works tables are written only through their
// in-memory caches, and rollbacks can never leave the caches ahead of the
// database.
// ===========================================================================

/// Structural guardrail: post-open writes to the cache-owned tables (tags,
/// works, work_tags, work_authors) may only live in tag_cache.rs /
/// works_cache.rs. Migrations and version-frozen backfills are exempt —
/// they run before the caches load — and are pinned here line by line, so
/// any new stray writer fails this test instead of drifting in silently.
/// (tests.rs itself is excluded: test-only bypasses are deliberate.)
#[test]
fn cache_owned_tables_have_no_stray_writers() {
    let sources = [
        ("mod.rs", include_str!("mod.rs")),
        ("works.rs", include_str!("works.rs")),
        ("works_search.rs", include_str!("works_search.rs")),
        ("library.rs", include_str!("library.rs")),
        ("subscriptions.rs", include_str!("subscriptions.rs")),
        ("accounts.rs", include_str!("accounts.rs")),
        ("consts.rs", include_str!("consts.rs")),
        ("library_file.rs", include_str!("library_file.rs")),
        ("drafts.rs", include_str!("drafts.rs")),
        ("fields.rs", include_str!("fields.rs")),
        // schema_v26.rs is a version-frozen migration, exempt as a whole
        // like the migration steps in mod.rs.
    ];
    let write_markers = [
        "INSERT INTO tags", "INSERT OR IGNORE INTO tags", "INSERT OR REPLACE INTO tags",
        "UPDATE tags", "DELETE FROM tags",
        "INSERT INTO works", "INSERT OR IGNORE INTO works", "INSERT OR REPLACE INTO works",
        "UPDATE works", "DELETE FROM works",
        "INTO work_tags", "UPDATE work_tags", "DELETE FROM work_tags",
        "INTO work_authors", "UPDATE work_authors", "DELETE FROM work_authors",
        "INTO app_state", "UPDATE app_state", "DELETE FROM app_state",
        "INTO bookmarks", "UPDATE bookmarks", "UPDATE OR IGNORE bookmarks",
        "DELETE FROM bookmarks",
        "INTO collections", "UPDATE collections", "DELETE FROM collections",
        "INTO collection_tags", "DELETE FROM collection_tags",
        "INTO collection_works", "DELETE FROM collection_works",
        "INTO collection_bookmarks", "DELETE FROM collection_bookmarks",
        "INTO users", "UPDATE users", "DELETE FROM users",
        "INTO user_source_properties", "UPDATE user_source_properties", "DELETE FROM user_source_properties",
        "INTO series", "UPDATE series", "DELETE FROM series",
        "INTO app_bookmarks", "UPDATE app_bookmarks", "DELETE FROM app_bookmarks",
        "INTO ao3_bookmarks", "UPDATE ao3_bookmarks", "DELETE FROM ao3_bookmarks",
        "INTO fields", "UPDATE fields", "DELETE FROM fields",
    ];
    // (file, line fragment) pairs for the migration-frozen exemptions.
    let allowed: &[(&str, &str)] = &[
        ("mod.rs", "UPDATE works SET detail_viewed_at ="),          // v2 timestamp re-encode
        ("mod.rs", "INSERT INTO tags (name, tag_type, uses, canonical, last_seen)"), // v8 known_tags merge
        ("mod.rs", "UPDATE works SET last_chapter_read = COALESCE("), // v7 progress backfill
        ("mod.rs", "UPDATE works SET fandom_count ="),               // v11 backfill
        ("mod.rs", "UPDATE works SET last_read_dt = COALESCE("),     // v1 baseline backfill
        ("works.rs", "INSERT INTO tags (name, tag_type) VALUES"),    // backfill_work_tags_v8
        ("works.rs", "INSERT OR IGNORE INTO work_tags"),             // backfill_work_tags_v8
        ("works.rs", "INSERT OR IGNORE INTO work_authors"),          // backfill_work_authors (v2)
        ("works_search.rs", "UPDATE works SET warnings_mask"),       // backfill_search_masks_v11
        ("mod.rs", "UPDATE app_state SET value = datetime("),        // v2 timestamp re-encode
        ("mod.rs", "INSERT OR REPLACE INTO app_state (key, value) VALUES ('avatar_cache_reset_1', '1')"), // v1 baseline
        ("mod.rs", "UPDATE OR IGNORE bookmarks SET account_id = substr(account_id"), // v10 account-id rekey
        ("mod.rs", "DELETE FROM bookmarks WHERE account_id LIKE"),   // v10 account-id rekey
        ("mod.rs", "UPDATE bookmarks SET account_id = '[none]'"),    // v10 logged-out sentinel
        ("mod.rs", "INSERT INTO bookmarks_v15"),                      // v15 rebuild
        ("mod.rs", "DELETE FROM bookmarks WHERE bookmark_type = 'work' AND target_id = OLD.id;"), // v15 cascade trigger
        ("mod.rs", "DELETE FROM bookmarks WHERE bookmark_type = 'series' AND target_id = OLD.id;"), // v15 cascade trigger
        ("mod.rs", "INSERT INTO ao3_users (id, username, profile_url, avatar_url, updated_at, numeric_id, joined,"), // v12 account fold
        ("mod.rs", "DELETE FROM ao3_users WHERE id = ?1 AND id <> ?2 /* v12 fold */"), // v12 account fold
        ("mod.rs", "UPDATE app_state SET value = '[]' WHERE key = 'subscription_check_queue';"), // v21 queue reset (runs before caches load)
        ("mod.rs", "INSERT INTO users_v31 (id, source, source_id, username, created_at, updated_at)"), // v31 rebuild
        ("mod.rs", "INSERT INTO user_source_properties (user_id, field_id, property_name, property_value, created_at, updated_at)"), // v31 rebuild
        ("mod.rs", "INSERT INTO users (source, source_id, username, created_at, updated_at) VALUES ('ao3', ?1, ?1, ?2, ?2)"), // v31 author linking
        ("mod.rs", "INSERT INTO fields_v31 (id, source, entity, key, label, value_type, display_order)"), // v31 rebuild
        ("mod.rs", "INSERT OR IGNORE INTO fields (source, entity, key, label, value_type, display_order)"), // v31 registry seed
        ("mod.rs", "SELECT DISTINCT source, 'user', ?1, ?2, ?3, 0 FROM users WHERE source <> 'ao3'"), // v31 registry seed
        ("mod.rs", "DELETE FROM follows WHERE kind = 'author' AND target_id = OLD.id;"), // v31 cascade trigger
        ("mod.rs", "DELETE FROM crawl_stamps WHERE kind = 'author' AND target_id = OLD.id;"), // v31 cascade trigger
        ("mod.rs", "UPDATE users SET source_id = ?1, updated_at = ?2 WHERE id = ?3 /* v32 rekey */"), // v32 guest fold
        ("mod.rs", "INSERT OR IGNORE INTO work_authors (work_id, user_id, position, created_at, updated_at)"), // v32 guest fold
        ("mod.rs", "DELETE FROM work_authors WHERE user_id = {guest};"), // v32 guest fold
        ("mod.rs", "INSERT OR IGNORE INTO series_authors (series_id, user_id, position, created_at, updated_at)"), // v32 guest fold
        ("mod.rs", "DELETE FROM series_authors WHERE user_id = {guest};"), // v32 guest fold
        ("mod.rs", "DELETE FROM user_source_properties WHERE user_id = {guest} /* v32 fold */;"), // v32 guest fold
        ("mod.rs", "DELETE FROM users WHERE id = {guest} /* v32 fold */;"), // v32 guest fold
        ("users_cache.rs", "INSERT INTO users (source, source_id, username, created_at, updated_at)"), // the cache's own write
        ("users_cache.rs", "INSERT INTO user_source_properties"), // the cache's own write
        ("users_cache.rs", "DELETE FROM user_source_properties WHERE user_id = ?1 AND property_name = ?2"), // the cache's own write
    ];
    for (file, src) in sources {
        for (lineno, line) in src.lines().enumerate() {
            for marker in &write_markers {
                if line.contains(marker) {
                    let exempt = allowed
                        .iter()
                        .any(|(f, fragment)| *f == file && line.contains(fragment));
                    assert!(
                        exempt,
                        "stray write to a cache-owned table in {file}:{} — \
                         route it through TagCache/WorksCache (or pin it in the \
                         exemption list if it is migration-frozen): {}",
                        lineno + 1,
                        line.trim()
                    );
                }
            }
        }
    }
}

#[test]
fn tag_indexes_share_one_entity() {
    let db = open_test_db();
    let resolved = db.tag_cache.resolve(&db.conn, "Shared Entity", "fandom").unwrap();
    let by_id = db.tag_cache.get(resolved.id).unwrap();
    let by_name = db.tag_cache.get_by_name("Shared Entity").unwrap();
    // Both indexes hand back the same allocation — one copy, two pointers.
    assert!(std::sync::Arc::ptr_eq(&by_id, &by_name));
    assert!(std::sync::Arc::ptr_eq(&resolved, &by_id));
    assert_eq!(by_name.tag_type, "fandom");
}

#[test]
fn savepoint_rollback_resyncs_caches() {
    let db = open_test_db();
    let result: Result<(), AppError> = db.with_savepoint(Savepoint::UpsertTags, || {
        db.tag_cache.resolve(&db.conn, "Rolled Back Tag", "fandom")?;
        assert!(db.tag_cache.get_by_name("Rolled Back Tag").is_some());
        Err(AppError::StorageError("forced rollback".into()))
    });
    assert!(result.is_err());
    // The insert rolled back; the cache must not keep the dead entity.
    assert!(db.tag_cache.get_by_name("Rolled Back Tag").is_none());
    let rows: i64 = db.conn
        .query_row("SELECT COUNT(*) FROM tags WHERE name = 'Rolled Back Tag'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0);
}

#[test]
fn tx_drop_without_commit_resyncs_caches() {
    let db = open_test_db();
    let tx = db.begin_tx().unwrap();
    let id = db.save_work(&sample_work(4242)).unwrap();
    assert!(db.get_work(id).unwrap().is_some());
    drop(tx); // rollback — the guard resyncs both caches
    assert!(db.get_work(id).unwrap().is_none());
    assert!(db.resolve_work(SOURCE_AO3, "4242").is_none());
    let rows: i64 = db.conn
        .query_row("SELECT COUNT(*) FROM works WHERE id = ?1", [id as i64], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0);
}

/// Every write-through mutation must leave the cached entity and the
/// database row agreeing.
#[test]
fn works_cache_matches_rows_after_each_mutation() {
    let db = open_test_db();
    let id = db.save_work(&sample_work(9)).unwrap();

    db.save_progress(id, 3, 120).unwrap();
    db.mark_work_read(id).unwrap();
    db.mark_work_detail_viewed(id, "2026-08-21 00:00:00").unwrap();
    db.set_works_gone(&[id], true).unwrap();
    let s5 = db.ensure_series(&ao3_series_ref(5), "S").unwrap();
    let series = vec![SeriesMembership {
        series_id: s5, series_external_id: "5".into(), name: "S".into(), part: 1,
        prev_work_external_id: None, next_work_external_id: None,
    }];
    db.set_work_series(id, &series).unwrap();

    let (ch, pos, last_read, viewed, gone, series_json): (i64, i64, String, String, i64, String) =
        db.conn.query_row(
            "SELECT last_chapter_read, last_chapter_read_pos, last_read_dt,
                    detail_viewed_at, gone_from_ao3, series_json
             FROM works WHERE id = ?1",
            [id as i64], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
        ).unwrap();

    assert_eq!(db.get_progress(id).unwrap(), Some((ch as u32, pos as u32)));
    assert_eq!(db.get_work_last_read_times().unwrap(), vec![(id, last_read)]);
    assert_eq!(viewed, "2026-08-21 00:00:00");
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![id]);
    assert_eq!(gone, 1);
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![id]);
    let hydrated = db.get_work(id).unwrap().unwrap();
    assert_eq!(hydrated.series, series);
    assert_eq!(serde_json::to_string(&hydrated.series).unwrap(), series_json);

    // A listing re-save (blurbs carry no series or library state) must
    // preserve all of it, in the row and the entity alike.
    db.save_work(&sample_work(9)).unwrap();
    let again = db.get_work(id).unwrap().unwrap();
    assert_eq!(again.series, series);
    assert_eq!(db.get_progress(id).unwrap(), Some((3, 120)));
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![id]);

    // Deletion drops the entity with the row.
    db.delete_work(id).unwrap();
    assert!(db.get_work(id).unwrap().is_none());
    assert!(db.get_gone_work_ids().unwrap().is_empty());
}

#[test]
fn state_cache_write_through_and_rollback() {
    let db = open_test_db();
    // Round trip without SQL on the read side.
    assert_eq!(db.get_state("cache_test_key").unwrap(), None);
    db.set_state("cache_test_key", "v1").unwrap();
    assert_eq!(db.get_state("cache_test_key").unwrap(), Some("v1".into()));
    let row: String = db.conn
        .query_row("SELECT value FROM app_state WHERE key = 'cache_test_key'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(row, "v1");

    // A dropped transaction rolls the write back out of map and table alike.
    let tx = db.begin_tx().unwrap();
    db.set_state("cache_test_key", "v2").unwrap();
    assert_eq!(db.get_state("cache_test_key").unwrap(), Some("v2".into()));
    drop(tx);
    assert_eq!(db.get_state("cache_test_key").unwrap(), Some("v1".into()));
}

#[test]
fn bookmarks_cache_matches_rows() {
    let db = open_test_db();
    let id = db.save_work(&sample_work(11)).unwrap();
    // A plain flag is no AO3 record.
    db.add_bookmark(id).unwrap();
    assert!(db.is_bookmarked(id).unwrap());
    let records: i64 = db.conn.query_row("SELECT COUNT(*) FROM ao3_bookmarks", [], |r| r.get(0)).unwrap();
    assert_eq!(records, 0);
    assert!(db.get_bookmark_details(id).unwrap().is_none());
    // Details create the record.
    db.update_bookmark_details(id, "note2", "tag a, tag b", "coll", false, true).unwrap();
    db.set_ao3_bookmark_id(id, 999).unwrap();

    let (note, tags, colls, private, rec, sync, ao3): (String, String, String, i64, i64, i64, Option<i64>) =
        db.conn.query_row(
            "SELECT note, tag_string, collection_names, private, rec, sync_to_ao3, ao3_bookmark_id
             FROM ao3_bookmarks WHERE kind = 'work' AND target_id = ?1",
            [id as i64], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        ).unwrap();
    assert_eq!(
        db.get_bookmark_details(id).unwrap().unwrap(),
        (note, tags, colls, private != 0, rec != 0, sync != 0, ao3.map(|v| v as u64))
    );
    assert_eq!(ao3, Some(999));

    // Flag and record are independent: flagging again leaves the record
    // as it was, and un-flagging keeps it.
    db.add_bookmark(id).unwrap();
    let d = db.get_bookmark_details(id).unwrap().unwrap();
    assert_eq!(d, ("note2".into(), "tag a, tag b".into(), "coll".into(), false, true, true, Some(999)));
    db.remove_bookmark(id).unwrap();
    assert!(!db.is_bookmarked(id).unwrap());
    assert_eq!(db.get_bookmark_details(id).unwrap().unwrap().6, Some(999));
    db.add_bookmark(id).unwrap();

    // Rollback pulls both removals back out of the maps.
    let tx = db.begin_tx().unwrap();
    db.remove_bookmark(id).unwrap();
    db.remove_ao3_bookmark_for(BookmarkTarget::Work(id)).unwrap();
    assert!(!db.is_bookmarked(id).unwrap());
    assert!(db.get_bookmark_details(id).unwrap().is_none());
    drop(tx);
    assert!(db.is_bookmarked(id).unwrap());
    assert_eq!(db.get_bookmark_details(id).unwrap().unwrap().5, true);

    // Removing the record leaves the flag.
    db.remove_ao3_bookmark_for(BookmarkTarget::Work(id)).unwrap();
    assert!(db.is_bookmarked(id).unwrap());
    assert!(db.get_bookmark_details(id).unwrap().is_none());
    db.update_bookmark_note(id, "again").unwrap();

    // delete_work drops every account's flag and record of the work.
    db.delete_work(id).unwrap();
    assert!(!db.is_bookmarked(id).unwrap());
    let records: i64 = db.conn.query_row("SELECT COUNT(*) FROM ao3_bookmarks", [], |r| r.get(0)).unwrap();
    assert_eq!(records, 0);
}

#[test]
fn collections_cache_links_and_purge() {
    let db = open_test_db();
    let w21 = db.save_work(&sample_work(21)).unwrap();
    let w22 = db.save_work(&sample_work(22)).unwrap();

    // Deep-link listing before any blurb: stub + links accumulate, deduped.
    db.add_collection_works("fest", &[w21, w22]).unwrap();
    db.add_collection_works("fest", &[w21]).unwrap();
    // A collection bookmark link needs a real AO3 bookmark record (FK).
    assert!(db.add_collection_bookmarks("fest", &[w22 as i64]).is_err());
    let bm = db.cache_fetched_bookmark_for("someone", BookmarkTarget::Work(w22), 5, "", "", false)
        .unwrap().unwrap();
    db.add_collection_bookmarks("fest", &[bm]).unwrap();
    assert_eq!(db.get_collection_bookmarks("fest").unwrap().len(), 1);
    assert_eq!(db.get_collection_work_ids("fest").unwrap(), vec![w21, w22]);
    assert_eq!(db.get_collection("fest").unwrap().unwrap().title, "fest");
    assert!(!db.collection_profile_cached("fest").unwrap());

    // Row parity after the profile save path.
    let mut c = db.get_collection("fest").unwrap().unwrap();
    c.title = "The Fest".into();
    c.tags = vec!["Fandom A".into(), "Extra Tag".into()];
    db.save_collection_profile(&c).unwrap();
    assert!(db.collection_profile_cached("fest").unwrap());
    assert_eq!(db.get_collection_tags("fest").unwrap(),
               vec!["Fandom A".to_string(), "Extra Tag".to_string()]);
    let (title, stamped): (String, String) = db.conn.query_row(
        "SELECT title, profile_fetched_at FROM collections WHERE external_id = 'fest'",
        [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!(title, "The Fest");
    assert!(!stamped.is_empty());

    // Deleting a work mirrors the FK cascade out of the link lists.
    db.delete_work(w21).unwrap();
    assert_eq!(db.get_collection_work_ids("fest").unwrap(), vec![w22]);
    let rows: i64 = db.conn.query_row(
        "SELECT COUNT(*) FROM collection_works cw JOIN collections c ON c.id = cw.collection_id
         WHERE c.external_id = 'fest'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(rows, 1);
}

#[test]
fn users_cache_profile_round_trip_no_sql_reads() {
    use crate::user_fields::{UserField as F, PROFILE_FETCHED_AT};
    let db = open_test_db();
    db.record_user(&AO3User::ao3("reader_x", "Reader_X", None, Some("http://a/av.png".into()))).unwrap();
    // NOCASE lookups and avatar reuse, from the map.
    assert!(db.has_ao3_user_with_username("reader_x").unwrap());
    assert_eq!(db.get_known_avatar_url("READER_X").unwrap(), Some("http://a/av.png".into()));
    assert_eq!(db.search_ao3_usernames("read", 10).unwrap(), vec!["Reader_X".to_string()]);

    // A blank incoming avatar never wipes the harvested one.
    db.record_user(&AO3User::ao3("reader_x", "Reader_X", Some("http://a/u".into()), None)).unwrap();
    assert_eq!(db.get_known_avatar_url("reader_x").unwrap(), Some("http://a/av.png".into()));

    assert!(db.get_ao3_user_record("Reader_X").unwrap().property(PROFILE_FETCHED_AT).is_none());
    let profile = SourceUserProfile {
        source: crate::models::SOURCE_AO3.to_string(), source_id: "Reader_X".into(), username: "Reader_X".into(),
        properties: vec![
            ("numeric_id".into(), "42".into()), ("avatar_url".into(), "http://a/av.png".into()),
            ("pseuds".into(), r#"["RX"]"#.into()), ("joined".into(), "2020-01-01".into()),
            ("location".into(), "Nowhere".into()), ("works".into(), "3".into()), ("series".into(), "1".into()),
            ("bookmarks".into(), "7".into()), ("gifts".into(), "2".into()),
        ],
    };
    let id = db.upsert_user_profile(&profile).unwrap();
    let got = db.get_ao3_user_record("reader_x").unwrap();
    assert_eq!(got.field(F::NumericId), Some("42"));
    assert_eq!(got.field(F::Works), Some("3"));
    assert_eq!(got.field(F::Pseuds), Some(r#"["RX"]"#));
    let fetched = got.property(PROFILE_FETCHED_AT).unwrap().to_string();
    let row_fetched: String = db.conn.query_row(
        "SELECT property_value FROM user_source_properties WHERE user_id = ?1 AND property_name = 'profile_fetched_at'",
        [id], |r| r.get(0)).unwrap();
    assert_eq!(fetched, row_fetched);

    db.set_user_block_state("READER_X", true, Some("b1")).unwrap();
    assert!(db.get_ao3_user_record("reader_x").unwrap().field(F::Blocked).is_some());
    let blocked: String = db.conn.query_row(
        "SELECT property_value FROM user_source_properties WHERE user_id = ?1 AND property_name = 'blocked'",
        [id], |r| r.get(0)).unwrap();
    assert_eq!(blocked, "1");
}

// ===========================================================================
// Users cache — one row per AO3 account, pseuds learned from sightings
// ===========================================================================

#[test]
fn users_cache_learns_pseuds_from_sightings_and_keys_by_account() {
    use crate::user_fields::UserField as F;
    let db = open_test_db();
    let pseuds_of = |name: &str| -> String {
        db.get_ao3_user_record(name).unwrap().field(F::Pseuds).unwrap_or("[]").to_string()
    };
    // A comment author posting from a pseud: the row is the account, the
    // pseud is recorded on it, and every name form resolves to it.
    db.record_user(&AO3User::ao3("ambirch", "AshWrecksEverything (ambirch)",
        Some("https://archiveofourown.org/users/ambirch/pseuds/AshWrecksEverything".into()), None)).unwrap();
    let rows: i64 = db.conn.query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0)).unwrap();
    assert_eq!(rows, 1);
    for name in ["ambirch", "AMBIRCH", "AshWrecksEverything", "AshWrecksEverything (ambirch)"] {
        let u = db.get_ao3_user(name).unwrap().unwrap_or_else(|| panic!("{name} resolves"));
        assert_eq!(u.id, "ambirch");
        assert_eq!(u.username, "ambirch");
        assert!(db.has_ao3_user_with_username(name).unwrap());
    }
    assert_eq!(pseuds_of("ambirch"), r#"["AshWrecksEverything"]"#);

    // A work byline teaches a second pseud; a repeat sighting is a no-op.
    let mut w = sample_work(1);
    w.authors = vec!["OtherPen (ambirch)".into(), "someone_else".into()];
    db.save_work(&w).unwrap();
    db.save_work(&w).unwrap();
    assert_eq!(pseuds_of("ambirch"), r#"["AshWrecksEverything","OtherPen"]"#);
    assert!(db.has_ao3_user_with_username("someone_else").unwrap());
    assert_eq!(db.get_works_by_author("OtherPen").unwrap().len(), 1);
    let ambirch = db.ao3_user_row_id("ambirch").unwrap();
    let other = db.ao3_user_row_id("someone_else").unwrap();
    assert_eq!(db.work_author_ids(1), vec![ambirch, other], "linked in byline order");

    // The profile page's pseud list merges with sightings — nothing lost.
    let profile = SourceUserProfile {
        source: crate::models::SOURCE_AO3.to_string(), source_id: "ambirch".into(), username: "ambirch".into(),
        properties: vec![
            ("numeric_id".into(), "7".into()),
            ("pseuds".into(), r#"["ambirch","AshWrecksEverything"]"#.into()),
            ("works".into(), "17".into()),
        ],
    };
    db.upsert_user_profile(&profile).unwrap();
    let got = db.get_ao3_user_record("OtherPen").expect("pseud resolves to the profile");
    assert_eq!(got.username, "ambirch");
    assert_eq!(got.field(F::Pseuds), Some(r#"["ambirch","AshWrecksEverything","OtherPen"]"#));
    assert_eq!(got.field(F::Works), Some("17"));

    // Search matches pseuds and returns the account.
    assert_eq!(db.search_ao3_usernames("ashwrecks", 10).unwrap(), vec!["ambirch".to_string()]);

    // A pseud never shadows a real account of the same name.
    db.record_user(&AO3User::ao3("OtherPen", "OtherPen", None, None)).unwrap();
    assert_eq!(db.get_ao3_user("OtherPen").unwrap().unwrap().id, "OtherPen");
    assert_eq!(db.get_ao3_user("OtherPen (ambirch)").unwrap().unwrap().id, "ambirch");
}

#[test]
fn users_cache_matches_rows_after_each_mutation() {
    let db = open_test_db();
    let check = |name: &str| {
        let e = db.get_ao3_user_record(name).expect("cached");
        let (source_id, username, updated): (String, String, String) = db.conn.query_row(
            "SELECT source_id, username, updated_at FROM users WHERE id = ?1", [e.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        assert_eq!(e.source_id, source_id);
        assert_eq!(e.username, username);
        assert_eq!(e.updated_at, updated);
        let mut stmt = db.conn.prepare(
            "SELECT property_name, property_value, updated_at FROM user_source_properties WHERE user_id = ?1 ORDER BY property_name").unwrap();
        let rows: Vec<(String, String, String)> = stmt.query_map([e.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap()
            .map(Result::unwrap).collect();
        let cached: Vec<(String, String, String)> = e.properties.iter()
            .map(|p| (p.name.clone(), p.value.clone(), p.updated_at.clone())).collect();
        assert_eq!(cached, rows, "{name}: cache and table agree");
    };
    db.record_user(&AO3User::ao3("w", "Pen (w)", None, Some("http://a/w.png".into()))).unwrap();
    check("w");
    db.record_author_bylines(&["Quill (w)".into()]).unwrap();
    check("Quill");
    db.set_user_block_state("Pen (w)", true, Some("b9")).unwrap();
    check("w");
    db.set_user_mute_state("w", true, None).unwrap();
    check("w");
    let profile = SourceUserProfile {
        source: crate::models::SOURCE_AO3.to_string(), source_id: "w".into(), username: "w".into(),
        properties: vec![("pseuds".into(), r#"["w"]"#.into()), ("works".into(), "1".into()),
                         ("blocked".into(), "1".into()), (crate::user_fields::AO3_BLOCK_RECORD.into(), "b9".into()),
                         ("muted".into(), "1".into())],
    };
    db.upsert_user_profile(&profile).unwrap();
    check("Pen");
    // Guests keep their synthetic id and display name.
    db.record_user(&AO3User::ao3("guest:abc", "A Guest (Guest)", None, None)).unwrap();
    let g = db.get_ao3_user_record("guest:abc").unwrap();
    assert_eq!(g.username, "A Guest (Guest)");
    assert!(g.field(crate::user_fields::UserField::Pseuds).is_none());
    check("guest:abc");
    // One row per account: the whole table is the two identities above.
    let rows: i64 = db.conn.query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0)).unwrap();
    assert_eq!(rows, 2);
}

#[test]
fn test_save_comment_in_place_keeps_thread_context() {
    use crate::models::Comment;
    let db = open_test_db();
    let user = |name: &str| AO3User::ao3(name, name, None, None);
    let comment = |id: u64, who: &str, replies: Vec<Comment>| Comment {
        id, author: user(who), posted_at: "1 Jan 2026".into(),
        content: vec![ContentBlock::Paragraph { text: vec![InlineContent::Text { value: format!("c{id}") }] }],
        replies, chapter_label: None, chapter_id: None, notice: None, more_replies: 0, rating: None,
    };
    // Comments cache under a work row (a stub is enough).
    assert!(db.save_comment(7, 70, &comment(10, "ann", vec![])).is_err());
    let w7 = db.ensure_work_stub(&ao3_work_ref(7), "").unwrap();
    assert_eq!(w7, 1);
    // A fetched thread: root 10 by ann, reply 11 by bob, cached under
    // work 7 / chapter 70.
    db.save_comment(w7, 70, &comment(10, "ann", vec![comment(11, "bob", vec![])])).unwrap();
    assert_eq!(db.comment_context(11).unwrap(), Some((w7, 70, 10)));
    // Rows reference their parent by row id; the API never shows it.
    let parent_row: Option<i64> = db.conn.query_row(
        "SELECT parent_id FROM comments WHERE external_id = '11'", [], |r| r.get(0)).unwrap();
    let root_row: i64 = db.conn.query_row(
        "SELECT id FROM comments WHERE external_id = '10'", [], |r| r.get(0)).unwrap();
    assert_eq!(parent_row, Some(root_row));

    // The reply's parent as parsed from AO3's post-reply page: no thread
    // context of its own, one new reply (12) beneath it.
    let parsed_parent = comment(11, "bob", vec![comment(12, "ann", vec![])]);
    assert!(db.save_comment_in_place(&parsed_parent).unwrap());
    assert_eq!(db.comment_context(12).unwrap(), Some((w7, 70, 11)));
    assert_eq!(db.comment_context(11).unwrap(), Some((w7, 70, 10)), "parent keeps its context");

    // The whole thread is reachable from the new reply.
    let root = db.get_comment_thread(12).unwrap().expect("thread");
    assert_eq!(root.id, 10);
    assert_eq!(root.replies[0].id, 11);
    assert_eq!(root.replies[0].replies[0].id, 12);

    // A parent that was never cached can't be placed.
    assert!(!db.save_comment_in_place(&comment(99, "zed", vec![])).unwrap());
    assert!(db.get_comment_thread(99).unwrap().is_none());

    // Deleting the work takes its comments with it (FK cascade).
    db.delete_work(w7).unwrap();
    let left: i64 = db.conn.query_row("SELECT COUNT(*) FROM comments", [], |r| r.get(0)).unwrap();
    assert_eq!(left, 0);
}

// ===========================================================================
// Whole-file operations (storage/library_file.rs)
// ===========================================================================

fn temp_db_path(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!("ao3_{tag}_{}.db", std::process::id()));
    library_file::remove_file_set(&p);
    p
}

#[test]
fn export_copy_is_a_complete_rekeyed_library_with_embedded_stamps() {
    let src_path = temp_db_path("export_src");
    let copy_path = temp_db_path("export_copy");
    let db = Storage::open(src_path.to_str().unwrap(), "local-key").unwrap();
    db.save_work(&sample_work(1)).unwrap();
    db.set_state("pref:theme", "dusk").unwrap();

    let size = db.export_copy(&copy_path, "cloud-key", &[("cloud:generation", "7"), ("cloud:device_name", "Mac")]).unwrap();
    assert!(size > 0);
    // Source keeps working and still enforces foreign keys.
    assert!(db.get_work(1).unwrap().is_some());
    let fk: i64 = db.conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
    assert_eq!(fk, 1);

    // Wrong key is rejected; right key sees the same library plus stamps.
    assert!(library_file::open_closed(&copy_path, "local-key").is_err());
    let conn = library_file::open_closed(&copy_path, "cloud-key").unwrap();
    assert_eq!(library_file::user_version(&conn).unwrap(), Storage::SCHEMA_VERSION);
    let embedded = library_file::read_embedded(&conn).unwrap();
    assert_eq!(embedded.get("cloud:generation").map(String::as_str), Some("7"));
    assert_eq!(embedded.get("cloud:device_name").map(String::as_str), Some("Mac"));
    drop(conn);
    let copy = Storage::open(copy_path.to_str().unwrap(), "cloud-key").unwrap();
    assert_eq!(copy.get_work(1).unwrap().unwrap().title, sample_work(1).title);
    assert_eq!(copy.get_state("pref:theme").unwrap().as_deref(), Some("dusk"));

    drop(copy);
    drop(db);
    library_file::remove_file_set(&src_path);
    library_file::remove_file_set(&copy_path);
}

#[test]
fn replace_with_swaps_file_backs_up_old_and_rebuilds_caches() {
    let live_path = temp_db_path("replace_live");
    let incoming_path = temp_db_path("replace_incoming");
    let backup_path = std::env::temp_dir().join(format!("ao3_replace_backup_{}/old.db", std::process::id()));
    let _ = std::fs::remove_dir_all(backup_path.parent().unwrap());

    let mut live = Storage::open(live_path.to_str().unwrap(), "k").unwrap();
    live.save_work(&sample_work(1)).unwrap();
    live.set_state("who", "old").unwrap();

    {
        let other = Storage::open(incoming_path.to_str().unwrap(), "other-key").unwrap();
        other.save_work(&sample_work(2)).unwrap();
        other.save_work(&sample_work(3)).unwrap();
        other.set_state("who", "new").unwrap();
    }
    library_file::rekey_file(&incoming_path, "other-key", "k").unwrap();

    live.replace_with(&incoming_path, &backup_path).unwrap();
    // Live store now serves the replacement, caches included (row ids
    // are per file; identity is the external id).
    assert!(live.resolve_work(SOURCE_AO3, "1").is_none());
    assert!(live.resolve_work(SOURCE_AO3, "2").is_some());
    assert_eq!(live.get_state("who").unwrap().as_deref(), Some("new"));
    assert_eq!(live.get_all_works().unwrap().len(), 2);
    assert!(!incoming_path.exists());
    // The old library is intact in the backup, under the same key.
    let old = Storage::open(backup_path.to_str().unwrap(), "k").unwrap();
    assert!(old.resolve_work(SOURCE_AO3, "1").is_some());
    assert_eq!(old.get_state("who").unwrap().as_deref(), Some("old"));
    // Writes after the swap land in the new file.
    let nine = live.save_work(&sample_work(9)).unwrap();
    drop(live);
    let reopened = Storage::open(live_path.to_str().unwrap(), "k").unwrap();
    assert!(reopened.get_work(nine).unwrap().is_some());

    drop(old);
    drop(reopened);
    library_file::remove_file_set(&live_path);
    let _ = std::fs::remove_dir_all(backup_path.parent().unwrap());
}

#[test]
fn replace_with_unopenable_file_restores_the_original() {
    let live_path = temp_db_path("replace_bad_live");
    let incoming_path = temp_db_path("replace_bad_incoming");
    let backup_path = std::env::temp_dir().join(format!("ao3_replace_bad_backup_{}/old.db", std::process::id()));
    let _ = std::fs::remove_dir_all(backup_path.parent().unwrap());

    let mut live = Storage::open(live_path.to_str().unwrap(), "k").unwrap();
    live.save_work(&sample_work(1)).unwrap();
    // Keyed differently: the reopen under "k" must fail.
    Storage::open(incoming_path.to_str().unwrap(), "wrong").unwrap();

    assert!(live.replace_with(&incoming_path, &backup_path).is_err());
    assert!(live.get_work(1).unwrap().is_some(), "original library is back in service");
    assert!(!backup_path.exists(), "no backup left behind for a swap that didn't happen");

    drop(live);
    library_file::remove_file_set(&live_path);
    library_file::remove_file_set(&incoming_path);
    let _ = std::fs::remove_dir_all(backup_path.parent().unwrap());
}

#[test]
fn reading_lists_work_on_a_fresh_database() {
    let db = Storage::open_in_memory("k").unwrap();
    db.save_work(&sample_work(1)).unwrap();
    db.save_work(&sample_work(2)).unwrap();
    let id = db.create_reading_list("Later").unwrap();
    db.add_to_reading_list(id, 1).unwrap();
    db.add_to_reading_list(id, 2).unwrap();
    assert_eq!(db.get_reading_list_items(id).unwrap(), vec![1, 2]);
    assert_eq!(db.get_reading_lists_for_work(2).unwrap(), vec![id]);
    let lists = db.get_reading_lists().unwrap();
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].1, "Later");
    assert_eq!(lists[0].2, 2);
    db.remove_from_reading_list(id, 1).unwrap();
    assert_eq!(db.get_reading_list_items(id).unwrap(), vec![2]);
    db.delete_reading_list(id).unwrap();
    assert!(db.get_reading_lists().unwrap().is_empty());
}

/// A dev database stamped v17 before the column drop landed still carried
/// the abandoned sync columns; v18 drops them so both shapes converge.
#[test]
fn reading_lists_work_on_a_database_that_drifted_at_v17() {
    let path = temp_db_path("rl_drift");
    {
        let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
        db.conn
            .execute_batch(
                "ALTER TABLE reading_lists ADD COLUMN sync_id TEXT NOT NULL DEFAULT '';
                 ALTER TABLE reading_list_items ADD COLUMN list_sync_id TEXT NOT NULL DEFAULT '';
                 PRAGMA user_version = 17;",
            )
            .unwrap();
    }
    let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    assert!(!db.column_exists("reading_lists", "sync_id").unwrap());
    assert!(!db.column_exists("reading_list_items", "list_sync_id").unwrap());
    db.save_work(&sample_work(1)).unwrap();
    let id = db.create_reading_list("Drifted").unwrap();
    db.add_to_reading_list(id, 1).unwrap();
    assert_eq!(db.get_reading_list_items(id).unwrap(), vec![1]);
    drop(db);
    library_file::remove_file_set(&path);
}

#[test]
fn abandoned_sync_bookkeeping_is_dropped_on_migrate() {
    let path = temp_db_path("drop_sync");
    {
        let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
        // Simulate the unreleased v16 bookkeeping on a database stamped v16.
        db.conn
            .execute_batch(
                "CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 CREATE TABLE sync_log (tbl TEXT, key TEXT, ts INTEGER, origin TEXT, deleted INTEGER, PRIMARY KEY (tbl, key));
                 ALTER TABLE reading_lists ADD COLUMN sync_id TEXT NOT NULL DEFAULT '';
                 CREATE TRIGGER sync_works_ai AFTER INSERT ON works BEGIN
                     INSERT OR REPLACE INTO sync_log VALUES ('w', NEW.id, 0, '', 0);
                 END;
                 PRAGMA user_version = 16;",
            )
            .unwrap();
    }
    let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    let leftovers: i64 = db
        .conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE name IN ('sync_meta', 'sync_log', 'sync_works_ai')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(leftovers, 0);
    assert!(!db.column_exists("reading_lists", "sync_id").unwrap());
    db.save_work(&sample_work(1)).unwrap();
    drop(db);
    library_file::remove_file_set(&path);
}

#[test]
fn chapter_image_rows_rekey_by_url_on_migrate() {
    let path = temp_db_path("image_keys");
    {
        let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
        db.save_cached_image("chimg:https://host/a.png", b"abs").unwrap();
        db.save_cached_image("chimg:/images/b.png", b"rel").unwrap();
        // Already under the URL key: that copy wins over the chimg duplicate.
        db.save_cached_image("img:https://host/c.png", b"new").unwrap();
        db.save_cached_image("chimg:https://host/c.png", b"old").unwrap();
        db.save_cached_image("avatar:someone", b"av").unwrap();
        db.conn.execute_batch("PRAGMA user_version = 24;").unwrap();
    }
    let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    assert_eq!(db.get_cached_image("img:https://host/a.png").unwrap(), Some(b"abs".to_vec()));
    assert_eq!(db.get_cached_image("img:https://archiveofourown.org/images/b.png").unwrap(),
               Some(b"rel".to_vec()));
    assert_eq!(db.get_cached_image("img:https://host/c.png").unwrap(), Some(b"new".to_vec()));
    assert_eq!(db.get_cached_image("avatar:someone").unwrap(), Some(b"av".to_vec()));
    let leftovers: i64 = db.conn
        .query_row("SELECT count(*) FROM image_cache WHERE key LIKE 'chimg:%'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(leftovers, 0);
    drop(db);
    library_file::remove_file_set(&path);
}

#[test]
fn rejected_key_is_wrong_passphrase_not_storage_error() {
    let path = temp_db_path("wrong_key");
    let path_str = path.to_string_lossy().to_string();
    {
        let db = Storage::open(&path_str, "right").unwrap();
        assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    }
    match Storage::open(&path_str, "wrong") {
        Err(AppError::WrongPassphrase) => {}
        Err(other) => panic!("expected WrongPassphrase, got {other}"),
        Ok(_) => panic!("wrong key opened the database"),
    }
    // The right key still opens it — the probe read has no side effects.
    Storage::open(&path_str, "right").unwrap();
    library_file::remove_file_set(&path);
}

#[test]
fn request_log_transport_column_round_trips() {
    let db = Storage::open_in_memory("").unwrap();
    assert!(db.column_exists("request_log", "transport").unwrap());
    assert!(db.column_exists("request_log", "source").unwrap());
    let rows = vec![
        (1_u64, "GET".to_string(), "https://x/a".to_string(), 200_u16, 5_u64, 1_u64, 2_u64, None, None,
         Some("circ=Circ 1.1 exit=abcd1234 guard=ef567890 connect=200ms first_tx=+0ms first_rx=+230ms".to_string()),
         "ao3".to_string()),
        (2_u64, "GET".to_string(), "https://x/b".to_string(), 0_u16, 5_u64, 1_u64, 0_u64, Some("timeout".to_string()), None, None,
         "ao3".to_string()),
    ];
    db.insert_request_logs(&rows, None).unwrap();
    let got = db.get_request_logs(10).unwrap();
    assert_eq!(got.len(), 2);
    // Newest first.
    assert_eq!(got[0].10, None);
    assert_eq!(got[1].10.as_deref(), Some("circ=Circ 1.1 exit=abcd1234 guard=ef567890 connect=200ms first_tx=+0ms first_rx=+230ms"));
    assert_eq!(got[0].11, "ao3");
}

#[test]
fn test_comment_drafts_per_composer_and_account() {
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap();
    // Signed out: nothing is stored.
    db.save_comment_draft(1, 0, 0, "hello").unwrap();
    assert!(db.get_comment_draft(1, 0).unwrap().is_none());

    let a = account(&db, "Alice");
    let b = account(&db, "Bob");
    db.set_active_account(a).unwrap();
    db.save_comment_draft(1, 0, 0, "whole work").unwrap();
    db.save_comment_draft(1, 11, 500, "reply draft").unwrap();
    // One row per composer: re-aiming the reply replaces it.
    db.save_comment_draft(1, 11, 0, "now top-level").unwrap();
    let d = db.get_comment_draft(1, 11).unwrap().unwrap();
    assert_eq!((d.parent_comment_id, d.body.as_str()), (0, "now top-level"));
    assert_eq!(db.get_comment_draft(1, 0).unwrap().unwrap().body, "whole work");

    // Another account never sees Alice's drafts.
    db.set_active_account(b).unwrap();
    assert!(db.get_comment_draft(1, 0).unwrap().is_none());
    db.set_active_account(a).unwrap();

    // A blank body deletes; clear deletes.
    db.save_comment_draft(1, 0, 0, "   ").unwrap();
    assert!(db.get_comment_draft(1, 0).unwrap().is_none());
    db.clear_comment_draft(1, 11).unwrap();
    assert!(db.get_comment_draft(1, 11).unwrap().is_none());
}

#[test]
fn test_comment_extras_round_trip_through_cache() {
    use crate::models::Comment;
    let db = open_test_db();
    let c = Comment {
        id: 42,
        author: AO3User::ao3("ann", "ann", None, None),
        posted_at: "1 Jan 2026".into(),
        content: vec![],
        replies: vec![],
        chapter_label: Some("on Chapter 2".into()),
        chapter_id: None,
        notice: Some("(Previous comment deleted.)".into()),
        more_replies: 3,
        rating: None,
    };
    let w = db.save_work(&sample_work(9)).unwrap();
    db.save_comment(w, 0, &c).unwrap();
    let back = &db.get_comments(w, 0).unwrap()[0];
    assert_eq!(back.chapter_label.as_deref(), Some("on Chapter 2"));
    assert_eq!(back.notice.as_deref(), Some("(Previous comment deleted.)"));
    assert_eq!(back.more_replies, 3);
}

#[test]
fn test_comment_fetch_stamps_live_on_chapters() {
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap(); // 3 chapters posted
    db.save_chapter(1, &sample_chapter(1)).unwrap();

    // Nothing fetched yet.
    assert_eq!(db.comments_fetched_at(1, 901).unwrap(), None);
    assert_eq!(db.comments_fetched_at(1, 0).unwrap(), None);

    // One chapter's list: only that chapter; the whole work isn't complete.
    db.mark_comments_fetched(1, 901, 1).unwrap();
    assert!(db.comments_fetched_at(1, 901).unwrap().is_some());
    assert_eq!(db.comments_fetched_at(1, 0).unwrap(), None);

    // The whole-work list stamps every posted chapter — stubs for the two
    // never fetched — and the work counts as fetched.
    db.mark_comments_fetched(1, 0, 0).unwrap();
    let chapters = db.get_chapters(1).unwrap();
    assert_eq!(chapters.len(), 3);
    assert!(chapters[1].content.is_empty() && chapters[2].content.is_empty());
    assert!(db.comments_fetched_at(1, 0).unwrap().is_some());

    // Fetching a stub's text fills it in and keeps the stamp (and id).
    db.save_chapter(1, &sample_chapter(2)).unwrap();
    assert!(db.comments_fetched_at(1, 902).unwrap().is_some());
    assert_eq!(db.get_chapter(1, 2).unwrap().unwrap().content.len(), 2);

    // A chapter stamp for a chapter with no row places a stub at its number.
    db.save_work(&WorkSummary { chapter_count: 4, ..sample_work(1) }).unwrap();
    db.mark_comments_fetched(1, 904, 4).unwrap();
    assert!(db.comments_fetched_at(1, 904).unwrap().is_some());

    // Purging a work that's neither downloaded nor being read: stamped
    // rows become stubs, unstamped rows go.
    let w2 = db.save_work(&sample_work(2)).unwrap();
    db.save_chapter(w2, &sample_chapter(1)).unwrap();
    db.purge_non_retained_chapters().unwrap();
    assert!(db.get_chapters(w2).unwrap().is_empty());
    let kept = db.get_chapters(1).unwrap();
    assert_eq!(kept.len(), 4);
    assert!(kept.iter().all(|c| c.content.is_empty()));
    assert_eq!(kept[0].title.as_deref(), Some("Chapter 1"));
    assert!(db.comments_fetched_at(1, 0).unwrap().is_some());
}

#[test]
fn test_whole_work_comments_land_on_their_chapter() {
    use crate::models::Comment;
    let db = open_test_db();
    let comment = |id: u64, chapter_id: Option<u64>, replies: Vec<Comment>| Comment {
        id,
        author: AO3User::ao3("ann", "ann", None, None),
        posted_at: "1 Jan 2026".into(),
        content: vec![ContentBlock::Paragraph { text: vec![InlineContent::Text { value: format!("c{id}") }] }],
        replies, chapter_label: chapter_id.map(|_| "on Chapter 2".into()), chapter_id,
        notice: None, more_replies: 0, rating: None,
    };
    db.save_work(&sample_work(1)).unwrap();
    // From the whole-work list: the root names chapter 902; its reply
    // doesn't, and sits on the thread's chapter.
    db.save_comment(1, 0, &comment(10, Some(902), vec![comment(11, None, vec![])])).unwrap();
    let in_chapter = db.get_comments(1, 902).unwrap();
    assert_eq!(in_chapter.len(), 1);
    assert_eq!(in_chapter[0].replies.len(), 1);
    assert_eq!(db.get_comments(1, 0).unwrap().len(), 1);

    // Re-saved by a page that doesn't name the chapter: the known id stays.
    db.save_comment(1, 0, &comment(10, None, vec![])).unwrap();
    assert_eq!(db.comment_context(10).unwrap(), Some((1, 902, 0)));
}

#[test]
fn test_sync_mark_counts_writes_not_reads() {
    let mut db = open_test_db();
    assert!(!db.changed_since_sync_mark(), "opening and migrating isn't an edit");
    db.get_chapters(1).unwrap();
    db.get_state("anything").unwrap();
    assert!(!db.changed_since_sync_mark(), "reads don't count");
    db.set_state("k", "v").unwrap();
    assert!(db.changed_since_sync_mark());
    db.set_sync_mark();
    assert!(!db.changed_since_sync_mark());
}

/// Manual: migrate a *copy* of a real library and report the outcome.
/// Never run by the suite (ignored). Point `AO3_MIGRATE_DB` at a library
/// file (a checkpointed snapshot under Backups/ is ideal) and
/// `AO3_MIGRATE_KEY` at its passphrase; the file is copied to a temp path
/// first, so the source is never touched.
///
///   AO3_MIGRATE_DB=… AO3_MIGRATE_KEY=… ./scripts/test-rust.sh migrate_real_library_copy -- --ignored --nocapture
#[test]
#[ignore]
fn migrate_real_library_copy() {
    let src = std::env::var("AO3_MIGRATE_DB").expect("AO3_MIGRATE_DB");
    let key = std::env::var("AO3_MIGRATE_KEY").expect("AO3_MIGRATE_KEY");
    let dir = std::env::temp_dir().join(format!("ao3_migrate_copy_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let dest = dir.join("library.db");
    std::fs::copy(&src, &dest).unwrap();
    let started = std::time::Instant::now();
    match Storage::open(&dest.to_string_lossy(), &key) {
        Ok(db) => {
            println!("MIGRATION OK in {:.1?}: schema v{}", started.elapsed(), db.schema_version().unwrap());
            println!("works {}  follows {}  app_bookmarks {}  ao3_bookmarks {}  comments {}",
                db.get_all_works().unwrap().len(),
                db.get_follows(None).unwrap().len(),
                db.conn.query_row("SELECT COUNT(*) FROM app_bookmarks", [], |r| r.get::<_, i64>(0)).unwrap(),
                db.conn.query_row("SELECT COUNT(*) FROM ao3_bookmarks", [], |r| r.get::<_, i64>(0)).unwrap(),
                db.conn.query_row("SELECT COUNT(*) FROM comments", [], |r| r.get::<_, i64>(0)).unwrap());
        }
        Err(e) => {
            println!("MIGRATION FAILED after {:.1?}: {e}", started.elapsed());
            panic!("migration failed");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn chapter_char_len_is_stored_and_backfilled() {
    let db = Storage::open_in_memory("").unwrap();
    let id = db.save_work(&sample_work(7)).unwrap();
    let chapter = sample_chapter(1);
    db.save_chapter(id, &chapter).unwrap();
    let expected = library::content_char_len(&chapter.content);
    assert!(expected > 0);
    assert_eq!(db.chapter_char_len(id, 1), expected);
    // A row from before v28 has no length; the first read measures and stores it.
    db.conn.execute("UPDATE chapters SET char_len = NULL WHERE work_id = ?1", [id as i64]).unwrap();
    assert_eq!(db.chapter_char_len(id, 1), expected);
    let stored: Option<i64> = db.conn
        .query_row("SELECT char_len FROM chapters WHERE work_id = ?1 AND number = 1", [id as i64], |r| r.get(0))
        .unwrap();
    assert_eq!(stored, Some(expected as i64));
    assert_eq!(db.chapter_char_len(id, 2), 0);
    assert_eq!(db.get_chapter_titles(id).unwrap(), vec!["Chapter 1".to_string()]);
}

/// A work from a rated source lands with its stats in the registry and
/// its reviews filed under its own source, stars intact (Area 12).
#[test]
fn extra_predicates_filter_stats_tags_and_dates() {
    use crate::models::ExtraPredicate;
    let db = open_test_db();
    let mut a = sample_work(41);
    a.source = "rated".to_string();
    a.url = "https://rated.mock/story/41".to_string();
    a.fandoms = vec!["Dragons".into()];
    a.date_updated = "2025-03-01".into();
    let mut b = sample_work(42);
    b.source = "rated".to_string();
    b.url = "https://rated.mock/story/42".to_string();
    b.fandoms = vec!["Knights".into(), "Dragons".into()];
    b.date_updated = "2025-06-15".into();
    let c = sample_work(43); // AO3, no stats
    let (ra, rb, rc) = (db.save_work(&a).unwrap(), db.save_work(&b).unwrap(), db.save_work(&c).unwrap());
    let fav = db.ensure_field("rated", "favorites", "Favorites", "num", 1).unwrap();
    db.set_work_stats(ra, &[WorkStat { field_id: fav, num_value: Some(10.0), text_value: None }]).unwrap();
    db.set_work_stats(rb, &[WorkStat { field_id: fav, num_value: Some(500.0), text_value: None }]).unwrap();

    let run = |extra: Vec<ExtraPredicate>| {
        let crit = LocalSearchCriteria { extra, sort_column: "title_to_sort_on".into(), sort_direction: "asc".into(), ..Default::default() };
        db.search_library_work_ids(&crit).unwrap()
    };
    assert_eq!(run(vec![]), vec![ra, rb, rc], "blank criteria match everything");
    assert_eq!(run(vec![ExtraPredicate::StatRange { source: "rated".into(), key: "favorites".into(), min: Some(100.0), max: None }]), vec![rb]);
    assert_eq!(run(vec![ExtraPredicate::StatRange { source: "rated".into(), key: "favorites".into(), min: None, max: Some(100.0) }]), vec![ra]);
    assert!(run(vec![ExtraPredicate::StatRange { source: "rated".into(), key: "nope".into(), min: None, max: None }]).is_empty(), "unknown field matches nothing");
    assert_eq!(run(vec![ExtraPredicate::TagSet { tag_type: "fandom".into(), include: vec!["dragons".into()], exclude: vec![], all: true }]), vec![ra, rb]);
    assert_eq!(run(vec![ExtraPredicate::TagSet { tag_type: "fandom".into(), include: vec!["Dragons".into(), "Knights".into()], exclude: vec![], all: true }]), vec![rb]);
    assert_eq!(run(vec![ExtraPredicate::TagSet { tag_type: "fandom".into(), include: vec!["Dragons".into(), "Knights".into()], exclude: vec![], all: false }]), vec![ra, rb]);
    assert_eq!(run(vec![ExtraPredicate::TagSet { tag_type: "fandom".into(), include: vec![], exclude: vec!["Knights".into()], all: true }]), vec![ra, rc]);
    assert_eq!(run(vec![ExtraPredicate::DateBetween { column: "revised_at".into(), from: Some("2025-02-01".into()), to: Some("2025-04-01".into()) }]), vec![ra]);
    assert_eq!(run(vec![ExtraPredicate::DateBetween { column: "bogus".into(), from: Some("2025-02-01".into()), to: None }]), vec![ra, rb, rc], "unknown date column is dropped, not interpolated");
    assert_eq!(db.library_languages().unwrap(), vec!["English".to_string()]);
}

#[test]
fn rated_source_work_keeps_stats_and_review_stars() {
    use crate::models::Comment;
    let db = open_test_db();
    let mut work = sample_work(31);
    work.source = "mockrated".to_string();
    work.url = "https://rated.mock/story/31".to_string();
    work.kudos = None;
    let row = db.save_work(&work).unwrap();

    let rating = db.ensure_field("mockrated", "rating", "Rating", "num", 1).unwrap();
    let count = db.ensure_field("mockrated", "rating_count", "Ratings", "num", 2).unwrap();
    db.set_work_stats(row, &[
        WorkStat { field_id: rating, num_value: Some(4.6), text_value: None },
        WorkStat { field_id: count, num_value: Some(312.0), text_value: None },
    ]).unwrap();
    let stats = db.get_work_stats(row).unwrap();
    assert_eq!(stats.len(), 2);
    assert_eq!(db.get_field(rating).unwrap().label, "Rating");
    assert_eq!(stats.iter().find(|s| s.field_id == rating).unwrap().num_value, Some(4.6));

    let review = Comment {
        id: 90_310_001,
        author: AO3User { source: "scribblehub".into(), id: "guest:driftwoodreader".into(), username: "driftwoodreader".into(),
                          profile_url: None, avatar_url: None },
        posted_at: "2026-10-02".into(),
        content: vec![ContentBlock::Paragraph { text: vec![InlineContent::Text { value: "Read it in one sitting.".into() }] }],
        replies: vec![], chapter_label: None, chapter_id: None, notice: None, more_replies: 0,
        rating: Some(5),
    };
    db.save_comment(row, 0, &review).unwrap();
    let back = db.get_comments(row, 0).unwrap();
    assert_eq!(back.len(), 1);
    assert_eq!(back[0].rating, Some(5));
    let source: String = db.conn.query_row(
        "SELECT source FROM comments WHERE external_id = '90310001'", [], |r| r.get(0)).unwrap();
    assert_eq!(source, "mockrated", "a review is filed under its work's source, never AO3");
}

/// v32: a second-source commenter minted as `guest:<source>:<id>` folds
/// into the real `(source, id)` row when one exists, and is rekeyed when
/// none does; comments, authorship and follows move with it.
#[test]
fn v32_folds_profile_keyed_guest_rows() {
    let db = open_test_db();
    let now = "2026-11-08 00:00:00";
    let mut w = sample_work(1);
    w.source = "scribblehub".to_string();
    let work_id = db.save_work(&w).unwrap();
    db.conn.execute_batch(&format!(
        "INSERT INTO users (id, source, source_id, username, created_at, updated_at) VALUES
            (901, 'scribblehub', '169109', 'Astrolust', '{now}', '{now}'),
            (902, 'scribblehub', 'guest:scribblehub:169109', 'Astrolust', '{now}', '{now}'),
            (903, 'scribblehub', 'guest:scribblehub:777', 'lonely', '{now}', '{now}'),
            (904, 'scribblehub', 'guest:scribblehub:anon', 'anon', '{now}', '{now}');
         INSERT INTO work_authors (work_id, user_id, position) VALUES ({work_id}, 901, 0), ({work_id}, 902, 0);
         INSERT INTO comments (source, external_id, work_id, chapter_id, author_id, posted_at, content_json)
             VALUES ('scribblehub', 'c1', {work_id}, 0, '902', '', '[]'), ('scribblehub', 'c2', {work_id}, 0, '903', '', '[]');
         INSERT INTO follows (kind, target_id, name, added_at) VALUES ('author', 902, 'Astrolust', '{now}');"
    )).unwrap();
    db.migrate_v32_merge_guest_rows().unwrap();
    db.users_cache.load(&db.conn).unwrap();

    assert!(db.get_user(902).is_none(), "the guest twin is folded away");
    assert_eq!(db.get_user_by_key("scribblehub", "169109").map(|u| u.id), Some(901));
    assert_eq!(db.get_user(903).unwrap().source_id, "777", "a guest with no twin is rekeyed");
    assert_eq!(db.get_user(904).unwrap().source_id, "guest:scribblehub:anon", "a true guest is untouched");
    let authors: Vec<i64> = {
        let mut st = db.conn.prepare("SELECT author_id FROM comments ORDER BY external_id").unwrap();
        st.query_map([], |r| r.get(0)).unwrap().collect::<Result<_, _>>().unwrap()
    };
    assert_eq!(authors, vec![901, 903]);
    let wa: i64 = db.conn.query_row("SELECT count(*) FROM work_authors WHERE work_id = ?1", [work_id as i64], |r| r.get(0)).unwrap();
    assert_eq!(wa, 1, "one authorship row, on the real user");
    let follow: i64 = db.conn.query_row("SELECT target_id FROM follows WHERE kind = 'author'", [], |r| r.get(0)).unwrap();
    assert_eq!(follow, 901);
}

#[test]
fn imported_local_work_is_kept_whole() {
    let db = open_test_db();
    let mut book = sample_work(0);
    book.source = "local".into();
    book.external_id = "urn:uuid:local-book".into();
    book.url = String::new();
    book.kudos = None;
    book.hits = None;
    let id = db.save_work(&book).unwrap();
    for n in 1..=3 { db.save_chapter(id, &sample_chapter(n)).unwrap(); }
    let fetched = db.save_work(&sample_work(77)).unwrap();
    db.save_chapter(fetched, &sample_chapter(1)).unwrap();

    // Saving the same book again lands on the same row; a shorter edition
    // leaves no stale tail.
    assert_eq!(db.save_work(&book).unwrap(), id);
    db.delete_chapters_after(id, 2).unwrap();
    assert_eq!(db.get_chapters(id).unwrap().len(), 2);

    // Neither downloaded nor being read: a fetched work's text is purged,
    // an imported work's is not — there is nowhere to fetch it again.
    db.purge_non_retained_chapters().unwrap();
    assert!(db.get_chapters(fetched).unwrap().iter().all(|c| c.content.is_empty()));
    let kept = db.get_chapters(id).unwrap();
    assert_eq!(kept.len(), 2);
    assert!(kept.iter().all(|c| !c.content.is_empty()));

    let saved = db.get_work(id).unwrap().unwrap();
    assert_eq!((saved.source.as_str(), saved.url.as_str()), ("local", ""));
    assert_eq!((saved.kudos, saved.hits), (None, None));
}

#[test]
fn v34_puts_scribblehub_status_values_back_in_range() {
    let path = temp_db_path("sh_status");
    let stat = |db: &Storage, work: u64, field: i64| -> Option<String> {
        db.get_work_stats(work).unwrap().into_iter().find(|s| s.field_id == field).and_then(|s| s.text_value)
    };
    let (ids, status, other_source, views);
    {
        let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
        status = db.ensure_field("scribblehub", "status", "Status", "text", 6).unwrap();
        views = db.ensure_field("scribblehub", "views", "Views", "num", 3).unwrap();
        other_source = db.ensure_field("mockrated", "status", "Status", "text", 6).unwrap();
        let values = [
            "Ongoing - Updated Nov 9, 2026", "Hiatus - Updated Nov 8, 2026", "Completed", "ongoing",
            "  COMPLETED ", "Ongoing", "Something else entirely",
        ];
        ids = values.iter().enumerate().map(|(i, value)| {
            let mut w = sample_work(0);
            w.source = "scribblehub".into();
            w.external_id = format!("90{i}");
            let id = db.save_work(&w).unwrap();
            db.set_work_stats(id, &[
                WorkStat { field_id: status, num_value: None, text_value: Some(value.to_string()) },
                WorkStat { field_id: views, num_value: Some(12.0), text_value: None },
            ]).unwrap();
            id
        }).collect::<Vec<_>>();
        // Another source's field of the same key is not this migration's.
        let mut w = sample_work(0);
        w.source = "mockrated".into();
        w.external_id = "1".into();
        let other = db.save_work(&w).unwrap();
        db.set_work_stats(other, &[
            WorkStat { field_id: other_source, num_value: None, text_value: Some("Ongoing - whatever".into()) },
        ]).unwrap();
        db.conn.execute_batch("PRAGMA user_version = 33;").unwrap();
    }
    let db = Storage::open(path.to_str().unwrap(), "k").unwrap();
    assert_eq!(db.schema_version().unwrap(), Storage::SCHEMA_VERSION);
    let after: Vec<Option<String>> = ids.iter().map(|id| stat(&db, *id, status)).collect();
    let s = |v: &str| Some(v.to_string());
    assert_eq!(after, vec![s("Ongoing"), s("Hiatus"), s("Completed"), s("Ongoing"), s("Completed"), s("Ongoing"), None]);
    // The work's other stats, and other sources, are untouched.
    for id in &ids {
        assert_eq!(db.get_work_stats(*id).unwrap().iter().find(|s| s.field_id == views).and_then(|s| s.num_value), Some(12.0));
    }
    let mockrated = db.resolve_work("mockrated", "1").unwrap();
    assert_eq!(stat(&db, mockrated, other_source), s("Ongoing - whatever"));
    drop(db);
    library_file::remove_file_set(&path);
}
