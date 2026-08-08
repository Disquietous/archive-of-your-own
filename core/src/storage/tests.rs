use super::*;
use crate::models::{
    AO3User, Chapter, ContentBlock, InlineContent, Rating, SeriesMembership, UserProfile,
    Warning, WorkSummary,
};

fn sample_work(id: u64) -> WorkSummary {
    WorkSummary {
        id,
        title: format!("Test Work {id}"),
        authors: vec!["Author1".into(), "Author2".into()],
        fandoms: vec!["Fandom A".into()],
        rating: Rating::Teen,
        warnings: vec![Warning::None],
        categories: vec!["F/M".into()],
        relationships: vec!["A/B".into()],
        characters: vec!["Character A".into()],
        tags: vec!["Fluff".into(), "Angst".into()],
        summary: "A test summary".into(),
        word_count: 12_345,
        chapter_count: 3,
        total_chapters: Some(10),
        kudos: 42,
        hits: 1000,
        bookmarks: 5,
        comments: 8,
        date_published: "2024-11-02".into(),
        date_updated: "2025-01-15".into(),
        language: "English".into(),
        complete: false,
        series: vec![],
        fetched_at: String::new(),
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

#[test]
fn test_known_tags_harvested_on_save_work() {
    let db = open_test_db();
    db.save_work(&sample_work(42)).unwrap();

    // sample_work carries authors Author1/Author2 — harvested as creators.
    let creators = db.search_known_tags("creator", "Author", 10).unwrap();
    assert!(creators.contains(&"Author1".to_string()));
    assert!(creators.contains(&"Author2".to_string()));
    // Wrong type finds nothing.
    assert!(db.search_known_tags("fandom", "Author", 10).unwrap().is_empty());
}

#[test]
fn test_known_tags_ranking() {
    let db = open_test_db();
    // "Steve" seen 3 times, "Ever Steve" once, canonical "Steve Rogers".
    for _ in 0..3 { db.upsert_known_tags(&[("Steve Harrington", "character")]).unwrap(); }
    db.upsert_known_tags(&[("Ever Steve", "character")]).unwrap();
    db.mark_tags_canonical("character", &["Steve Rogers".to_string()]).unwrap();

    let results = db.search_known_tags("character", "steve", 10).unwrap();
    // Starts-with beats substring; canonical beats use-count within starts-with.
    assert_eq!(results[0], "Steve Rogers");
    assert_eq!(results[1], "Steve Harrington");
    assert_eq!(results[2], "Ever Steve");

    // LIKE metacharacters are escaped, not wildcards.
    assert!(db.search_known_tags("character", "%", 10).unwrap().is_empty());
}

#[test]
fn test_known_tags_canonical_upsert_preserves_uses() {
    let db = open_test_db();
    for _ in 0..5 { db.upsert_known_tags(&[("Fluff", "freeform")]).unwrap(); }
    db.mark_tags_canonical("freeform", &["Fluff".to_string()]).unwrap();
    let results = db.search_known_tags("freeform", "Fluff", 10).unwrap();
    assert_eq!(results, vec!["Fluff".to_string()]);
}

#[test]
fn test_save_and_load_work() {
    let db = open_test_db();
    let work = sample_work(42);

    db.save_work(&work).expect("save_work");

    // Retrieve by id
    let loaded = db.get_work(42).expect("get_work").expect("should exist");
    assert_eq!(loaded.id, work.id);
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
    db.save_chapter(42, &sample_chapter(1)).unwrap();
    db.save_progress(42, 1, 0.5).unwrap();
    db.add_bookmark(42, None, false).unwrap();
    db.add_to_history(42).unwrap();

    db.delete_work(42).expect("delete_work");
    assert!(db.get_work(42).expect("after delete").is_none());
    assert!(db.get_chapters(42).expect("chapters after delete").is_empty());
    assert!(db.get_progress(42).expect("progress after delete").is_none());
    assert!(!db.is_bookmarked(42).expect("bookmark after delete"));
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

    db.add_bookmark(1, Some("great fic"), false).unwrap();
    assert!(db.is_bookmarked(1).unwrap());

    db.add_bookmark(2, None, false).unwrap();
    let bm = db.get_bookmarks().unwrap();
    assert_eq!(bm.len(), 2);

    db.remove_bookmark(1).unwrap();
    assert!(!db.is_bookmarked(1).unwrap());
    assert_eq!(db.get_bookmarks().unwrap().len(), 1);
}

#[test]
fn test_reading_progress() {
    let db = open_test_db();

    assert!(db.get_progress(1).unwrap().is_none());

    db.save_progress(1, 3, 0.75).unwrap();
    let (ch, pos) = db.get_progress(1).unwrap().unwrap();
    assert_eq!(ch, 3);
    assert!((pos - 0.75).abs() < f64::EPSILON);

    // Overwrite
    db.save_progress(1, 4, 0.1).unwrap();
    let (ch2, pos2) = db.get_progress(1).unwrap().unwrap();
    assert_eq!(ch2, 4);
    assert!((pos2 - 0.1).abs() < f64::EPSILON);
}

#[test]
fn test_history() {
    let db = open_test_db();
    assert!(db.get_history().unwrap().is_empty());

    db.add_to_history(10).unwrap();
    db.add_to_history(20).unwrap();
    db.add_to_history(10).unwrap(); // duplicate — allowed

    let hist = db.get_history().unwrap();
    assert_eq!(hist.len(), 3);
    // Most recent first
    assert_eq!(hist[0].0, 10);
    assert_eq!(hist[1].0, 20);
    assert_eq!(hist[2].0, 10);

    db.clear_history().unwrap();
    assert!(db.get_history().unwrap().is_empty());
}

#[test]
fn test_subscriptions_persistence() {
    let db = open_test_db();

    assert!(db.get_subscriptions().unwrap().is_empty());

    let subs = vec![
        ("author".into(), "coolwriter".into(), "CoolWriter".into(), Some("111".into())),
        ("work".into(), "12345".into(), "My Fic".into(), None),
    ];
    db.save_subscriptions(&subs).unwrap();
    let loaded = db.get_subscriptions().unwrap();
    assert_eq!(loaded.len(), 2);
    assert_eq!(db.get_subscription_ao3_id("author", "coolwriter").unwrap().as_deref(), Some("111"));
    assert_eq!(db.get_subscription_ao3_id("work", "12345").unwrap(), None);
    assert!(db.has_subscription("work", "12345").unwrap());
    assert!(!db.has_subscription("work", "99999").unwrap());

    // Single add/remove (work subscribe toggle path)
    db.add_subscription("work", "555", "Another Fic", Some("222")).unwrap();
    assert_eq!(db.get_subscription_ao3_id("work", "555").unwrap().as_deref(), Some("222"));
    db.remove_subscription("work", "555").unwrap();
    assert!(!db.has_subscription("work", "555").unwrap());

    // Replacing clears the old set
    let subs2 = vec![("series".into(), "99".into(), "Big Series".into(), None)];
    db.save_subscriptions(&subs2).unwrap();
    assert_eq!(db.get_subscriptions().unwrap().len(), 1);
}

#[test]
fn test_has_ao3_user_with_username() {
    let db = open_test_db();

    assert!(!db.has_ao3_user_with_username("astolat").unwrap());

    db.upsert_ao3_user(&AO3User {
        id: "astolat".into(),
        username: "astolat".into(),
        profile_url: Some("https://archiveofourown.org/users/astolat".into()),
        avatar_url: None,
    }).unwrap();

    assert!(db.has_ao3_user_with_username("astolat").unwrap());
    // Username match is case-insensitive
    assert!(db.has_ao3_user_with_username("Astolat").unwrap());
    assert!(!db.has_ao3_user_with_username("someone_else").unwrap());
}

#[test]
fn test_user_profile_round_trip() {
    let db = open_test_db();

    assert!(db.get_user_profile("writer").unwrap().is_none());

    let profile = UserProfile {
        username: "Writer".into(),
        numeric_id: Some("424242".into()),
        avatar_url: Some("https://example.org/icon.png".into()),
        pseuds: vec!["Writer".into(), "AltPseud".into()],
        joined: "2015-01-02".into(),
        location: "The Library".into(),
        birthday: String::new(),
        bio: vec![ContentBlock::Paragraph {
            text: vec![InlineContent::Text { value: "Hello.".into() }],
        }],
        works_count: 12,
        series_count: 3,
        bookmarks_count: 40,
        collections_count: 1,
        gifts_count: 2,
        viewer_signed_in: true,
        subscribed: true, // network-side state; not persisted here
        subscription_ao3_id: Some("999".into()),
        blocked: false,
        block_ao3_id: None,
        muted: true,
        mute_ao3_id: Some("88".into()),
        fetched_at: String::new(),
    };
    db.upsert_user_profile(&profile).unwrap();

    // Case-insensitive lookup; subscription state joins from the
    // subscriptions table, not the profile columns.
    let got = db.get_user_profile("writer").unwrap().expect("cached profile");
    assert_eq!(got.username, "Writer");
    assert_eq!(got.numeric_id.as_deref(), Some("424242"));
    assert_eq!(got.pseuds, vec!["Writer".to_string(), "AltPseud".to_string()]);
    assert_eq!(got.joined, "2015-01-02");
    assert_eq!(got.location, "The Library");
    assert_eq!(got.bio.len(), 1);
    assert_eq!(got.works_count, 12);
    assert_eq!(got.gifts_count, 2);
    assert!(!got.subscribed);
    assert!(got.muted);
    assert_eq!(got.mute_ao3_id.as_deref(), Some("88"));
    assert!(!got.fetched_at.is_empty());

    db.add_subscription("author", "Writer", "Writer", Some("777")).unwrap();
    let got = db.get_user_profile("Writer").unwrap().unwrap();
    assert!(got.subscribed);
    assert_eq!(got.subscription_ao3_id.as_deref(), Some("777"));

    // Block/mute state updates stick, and clear cleanly.
    db.set_user_block_state("Writer", true, Some("55")).unwrap();
    let got = db.get_user_profile("Writer").unwrap().unwrap();
    assert!(got.blocked);
    assert_eq!(got.block_ao3_id.as_deref(), Some("55"));
    db.set_user_mute_state("Writer", false, None).unwrap();
    let got = db.get_user_profile("Writer").unwrap().unwrap();
    assert!(!got.muted);
    assert!(got.mute_ao3_id.is_none());

    // Block state for a never-seen user creates the row, but no
    // profile fetch is faked — get_user_profile stays None.
    db.set_user_block_state("stranger", true, None).unwrap();
    assert!(db.get_user_profile("stranger").unwrap().is_none());
    assert!(db.has_ao3_user_with_username("stranger").unwrap());
}

#[test]
fn test_subscription_snapshots() {
    let db = open_test_db();

    // Initially empty
    assert!(db.get_subscription_snapshot("author", "testuser").unwrap().is_none());

    // Save a snapshot
    db.save_subscription_snapshot("author", "testuser", "2025-01-15").unwrap();
    assert_eq!(
        db.get_subscription_snapshot("author", "testuser").unwrap().as_deref(),
        Some("2025-01-15")
    );

    // Update replaces
    db.save_subscription_snapshot("author", "testuser", "2025-03-01").unwrap();
    assert_eq!(
        db.get_subscription_snapshot("author", "testuser").unwrap().as_deref(),
        Some("2025-03-01")
    );

    // Different sub is separate
    assert!(db.get_subscription_snapshot("work", "100").unwrap().is_none());
}

#[test]
fn test_snapshot_census_meta() {
    let db = open_test_db();

    // Unknown sub: all None.
    assert_eq!(db.get_snapshot_census_meta("author", "u").unwrap(), (None, None, None));

    // Census fields survive a snapshot date update (upsert, not replace).
    db.set_snapshot_total_works("author", "u", 42).unwrap();
    db.set_snapshot_last_census("author", "u", "1700000000").unwrap();
    db.set_snapshot_census_state("author", "u", Some("{\"next_page\":3}")).unwrap();
    db.save_subscription_snapshot("author", "u", "2025-06-01").unwrap();
    let (total, last, state) = db.get_snapshot_census_meta("author", "u").unwrap();
    assert_eq!(total, Some(42));
    assert_eq!(last.as_deref(), Some("1700000000"));
    assert_eq!(state.as_deref(), Some("{\"next_page\":3}"));
    assert_eq!(db.get_subscription_snapshot("author", "u").unwrap().as_deref(), Some("2025-06-01"));

    // Clearing the census state leaves the rest.
    db.set_snapshot_census_state("author", "u", None).unwrap();
    let (total, last, state) = db.get_snapshot_census_meta("author", "u").unwrap();
    assert_eq!(total, Some(42));
    assert!(last.is_some());
    assert!(state.is_none());
}

#[test]
fn test_gone_from_ao3_flag() {
    let db = open_test_db();
    let mut w = sample_work(7001);
    db.save_work(&w).unwrap();
    w.id = 7002;
    db.save_work(&w).unwrap();

    assert!(db.get_gone_work_ids().unwrap().is_empty());

    db.set_works_gone(&[7001], true).unwrap();
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![7001]);

    // save_work on a gone work must not resurrect it implicitly…
    w.id = 7001;
    db.save_work(&w).unwrap();
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![7001]);

    // …only an explicit clear (census reappearance) does.
    db.set_works_gone(&[7001, 7002], false).unwrap();
    assert!(db.get_gone_work_ids().unwrap().is_empty());
}

#[test]
fn test_work_series_roundtrip() {
    let db = open_test_db();
    let w = sample_work(7101);
    db.save_work(&w).unwrap();

    let series = vec![
        SeriesMembership {
            series_id: 9000001,
            name: "Alpha Test Series".into(),
            part: 2,
            prev_work_id: Some(7100),
            next_work_id: Some(7102),
        },
        SeriesMembership {
            series_id: 9000002,
            name: "Beta Test Series".into(),
            part: 1,
            prev_work_id: None,
            next_work_id: None,
        },
    ];
    db.set_work_series(7101, &series).unwrap();
    let got = db.get_work(7101).unwrap().unwrap();
    assert_eq!(got.series, series);

    // A blurb-shaped save_work (empty series) must not wipe it.
    db.save_work(&w).unwrap();
    let got = db.get_work(7101).unwrap().unwrap();
    assert_eq!(got.series, series);

    // The subscription-works path (which swallows row errors) must
    // still deserialize rows with the series column intact.
    db.add_subscription_works("series", "9000001", &[7101]).unwrap();
    let subs = db.get_subscription_works("series", "9000001").unwrap();
    assert_eq!(subs.len(), 1);
    assert_eq!(subs[0].series, series);

    // Explicit empty write clears (work removed from series on AO3).
    db.set_work_series(7101, &[]).unwrap();
    assert!(db.get_work(7101).unwrap().unwrap().series.is_empty());
}

#[test]
fn test_detail_viewed_at() {
    let db = open_test_db();
    let w = sample_work(7201);
    db.save_work(&w).unwrap();
    assert!(db.get_detail_viewed_work_ids().unwrap().is_empty());

    db.mark_work_detail_viewed(7201, "1750000000").unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![7201]);

    // First view wins — a later mark keeps the original timestamp.
    db.mark_work_detail_viewed(7201, "1760000000").unwrap();
    let at: String = db.conn.query_row(
        "SELECT detail_viewed_at FROM works WHERE id = 7201", [], |r| r.get(0)).unwrap();
    assert_eq!(at, "1750000000");

    // Blurb-shaped save_work must not wipe it.
    db.save_work(&w).unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![7201]);

    // Marking a work with no row is a silent no-op.
    db.mark_work_detail_viewed(9999, "1750000000").unwrap();
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![7201]);
}

#[test]
fn test_last_read_dt() {
    let db = open_test_db();
    let w = sample_work(7301);
    db.save_work(&w).unwrap();
    assert!(db.get_work_last_read_times().unwrap().is_empty());

    db.mark_work_read(7301).unwrap();
    let times = db.get_work_last_read_times().unwrap();
    assert_eq!(times.len(), 1);
    assert_eq!(times[0].0, 7301);
    assert!(!times[0].1.is_empty());

    // Blurb-shaped save_work must not wipe it.
    db.save_work(&w).unwrap();
    assert_eq!(db.get_work_last_read_times().unwrap().len(), 1);

    // Marking a work with no row is a silent no-op.
    db.mark_work_read(9999).unwrap();
    assert_eq!(db.get_work_last_read_times().unwrap().len(), 1);
}

#[test]
fn test_subscription_work_ids() {
    let db = open_test_db();
    db.add_subscription_works("author", "u", &[1, 2, 3]).unwrap();
    db.add_subscription_works("author", "u", &[3, 4]).unwrap();
    let mut ids = db.get_subscription_work_ids("author", "u").unwrap();
    ids.sort();
    assert_eq!(ids, vec![1, 2, 3, 4]);
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
fn test_followed_items() {
    let db = Storage::open_in_memory("test-passphrase").unwrap();
    db.add_followed("fandom", "Fandom A").unwrap();
    db.add_followed("fandom", "Fandom B").unwrap();
    db.add_followed("author", "writer_one").unwrap();
    // Duplicates are ignored; kinds are independent.
    db.add_followed("fandom", "Fandom A").unwrap();
    assert_eq!(db.get_followed("fandom").unwrap(), vec!["Fandom A", "Fandom B"]);
    assert_eq!(db.get_followed("author").unwrap(), vec!["writer_one"]);
    db.remove_followed("fandom", "Fandom A").unwrap();
    assert_eq!(db.get_followed("fandom").unwrap(), vec!["Fandom B"]);
}

#[test]
fn test_schema_version_fetched_at_and_author_index() {
    let db = open_test_db();
    assert_eq!(db.schema_version().unwrap(), 2);
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
    assert_eq!(db.schema_version().unwrap(), 2);
    // Author index backfilled from authors_json.
    assert_eq!(db.get_works_by_author("writer_two").unwrap().len(), 1);
    // Epoch strings converted to the one datetime encoding.
    assert_eq!(db.get_works_crawled_at("author", "writer_one").unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    assert_eq!(db.get_last_check_time().unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    // Orphaned table dropped.
    let old_count: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'subscription_snapshots_old'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(old_count, 0);
    // Reopening runs zero migrations and stays at the current version.
    drop(db);
    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), 2);
    let _ = std::fs::remove_file(&path);
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
