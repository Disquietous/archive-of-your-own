use super::*;
use crate::models::{
    AO3User, Chapter, ContentBlock, InlineContent, LocalSearchCriteria, Rating, SeriesMembership,
    UserProfile, Warning, WorkSummary,
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
    db.save_progress(42, 1, 250).unwrap();
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
fn test_search_local_bookmarks_filtered() {
    let db = open_test_db();
    // Work 1: sample defaults — English, 12,345 words, tags Fluff/Angst,
    // updated 2025-01-15. Work 2: German long-fic variant.
    db.save_work(&sample_work(1)).unwrap();
    let mut b = sample_work(2);
    b.title = "Another Story".into();
    b.tags = vec!["Slow Burn".into()];
    b.word_count = 100_000;
    b.language = "Deutsch".into();
    b.date_updated = "2026-08-01".into();
    db.save_work(&b).unwrap();

    // Own bookmark on work 1 (rec, own tag); a fetched listing's bookmark
    // by another user on work 2; a fetched bookmark whose work was never
    // cached (must be skipped, not error).
    db.add_bookmark(1, Some("great fic"), false).unwrap();
    db.update_bookmark_details(1, "great fic", "Comfort Read", "", false, true).unwrap();
    db.cache_fetched_bookmark("OtherUser", 2, 999, "note from a friend", "Favorite", false).unwrap();
    db.cache_fetched_bookmark("OtherUser", 3, 1000, "work not cached", "", false).unwrap();

    let ids = |c: &crate::models::BookmarkSearchCriteria| -> Vec<u64> {
        db.search_local_bookmarks_filtered(c, 0).unwrap().iter().map(|h| h.work.id).collect()
    };
    type C = crate::models::BookmarkSearchCriteria;

    // Blank criteria: every cached bookmark with a cached work.
    let mut all = ids(&C::default());
    all.sort();
    assert_eq!(all, vec![1, 2]);

    // Work-side criteria.
    let mut c = C::default();
    c.bookmarkable_query = "Another".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = C::default();
    c.other_tag_names = "Fluff".into();
    assert_eq!(ids(&c), vec![1]);
    let mut c = C::default();
    c.word_count = ">50000".into();
    assert_eq!(ids(&c), vec![2]);
    // Library language matching is by display name, case-insensitive.
    let mut c = C::default();
    c.language_id = "english".into();
    assert_eq!(ids(&c), vec![1]);

    // Bookmark-side criteria.
    let mut c = C::default();
    c.rec = true;
    assert_eq!(ids(&c), vec![1]);
    let mut c = C::default();
    c.bookmark_notes = "friend".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = C::default();
    c.bookmarker = "OtherUser".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = C::default();
    c.other_bookmark_tag_names = "Comfort Read".into();
    assert_eq!(ids(&c), vec![1]);
    c.other_bookmark_tag_names = "Favorite".into();
    assert_eq!(ids(&c), vec![2]);

    // Hits carry the bookmark's own fields alongside the work blurb.
    let mut c = C::default();
    c.bookmarker = "OtherUser".into();
    let hit = &db.search_local_bookmarks_filtered(&c, 0).unwrap()[0];
    assert_eq!(hit.bookmarker, "otheruser");
    assert_eq!(hit.note, "note from a friend");
    assert_eq!(hit.tags, vec!["Favorite".to_string()]);
    assert!(!hit.rec);
    assert_eq!(hit.work.title, "Another Story");

    // Only work bookmarks are cached — a Series filter matches nothing.
    let mut c = C::default();
    c.bookmarkable_type = "Series".into();
    assert!(ids(&c).is_empty());

    // Sort by word count, AO3-style descending.
    let mut c = C::default();
    c.sort_column = "word_count".into();
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
fn test_snapshot_last_checked() {
    let db = open_test_db();

    // Unknown row: never checked.
    assert!(db.get_snapshot_last_checked("author", "u").unwrap().is_none());

    // Stamp creates the row if needed and survives a snapshot-date upsert.
    db.set_snapshot_last_checked("author", "u", "2026-08-11 01:00:00").unwrap();
    db.save_subscription_snapshot("author", "u", "2026-08-10").unwrap();
    assert_eq!(db.get_snapshot_last_checked("author", "u").unwrap().as_deref(),
               Some("2026-08-11 01:00:00"));

    // Restamping overwrites.
    db.set_snapshot_last_checked("author", "u", "2026-08-11 02:00:00").unwrap();
    assert_eq!(db.get_snapshot_last_checked("author", "u").unwrap().as_deref(),
               Some("2026-08-11 02:00:00"));
}

#[test]
fn test_collections_cache_and_library_search() {
    let db = open_test_db();
    let c = crate::models::CollectionSummary {
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
    db.upsert_ao3_user(&crate::models::AO3User {
        id: "someuser".into(), username: "someuser".into(),
        profile_url: None, avatar_url: None,
    }).unwrap();
    assert_eq!(db.search_ao3_usernames("some", 10).unwrap(), vec!["someuser".to_string()]);
    assert!(db.search_ao3_usernames("other", 10).unwrap().is_empty());
}

#[test]
fn test_collection_profile_tags_and_works() {
    let db = open_test_db();
    // Blurb lands first with counts; the profile brings tags but no counts.
    let blurb = crate::models::CollectionSummary {
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
    db.conn.execute("DELETE FROM collections WHERE name = 'test_fest'", []).unwrap();
    let (ct, cw): (u32, u32) = db.conn.query_row(
        "SELECT (SELECT COUNT(*) FROM collection_tags WHERE collection_name = 'test_fest'),
                (SELECT COUNT(*) FROM collection_works WHERE collection_name = 'test_fest')",
        [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((ct, cw), (0, 0));
    assert!(db.get_work(2).unwrap().is_some());
}

#[test]
fn test_collection_bookmark_caching() {
    let db = open_test_db();
    db.save_work(&sample_work(1)).unwrap();
    db.save_work(&sample_work(2)).unwrap();

    // Signed in as "Reader": a fetched bookmark with their byline is
    // theirs; everyone else's is keyed to its own username, outside the
    // active account's scope.
    db.create_account("reader", "Reader", "").unwrap();
    db.set_active_account("reader").unwrap();

    db.cache_fetched_bookmark("reader", 1, 111, "seen in a collection", "", false).unwrap();
    db.cache_fetched_bookmark("SomeoneElse", 2, 222, "not mine", "", false).unwrap();
    // A byline-less blurb can't be attributed — nothing cached.
    db.cache_fetched_bookmark("", 2, 333, "", "", false).unwrap();

    // The account-scoped Bookmarks view sees only the user's own row,
    // which arrived AO3-synced with its id recorded.
    assert_eq!(db.get_bookmarks().unwrap(), vec![1]);
    let (note, sync, ao3_id) = db.get_bookmark_full(1).unwrap().unwrap();
    assert_eq!((note.as_str(), sync, ao3_id), ("seen in a collection", true, Some(111)));

    // A locally edited note survives re-fetch; only the AO3 id refreshes.
    db.update_bookmark_note(1, "my edited note").unwrap();
    db.cache_fetched_bookmark("Reader", 1, 444, "stale listing note", "", false).unwrap();
    let (note, _, ao3_id) = db.get_bookmark_full(1).unwrap().unwrap();
    assert_eq!((note.as_str(), ao3_id), ("my edited note", Some(444)));

    // The other user's bookmark is keyed by their username.
    let foreign: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM bookmarks WHERE account_id = 'someoneelse'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(foreign, 1);

    // Collection↔bookmark joins accumulate across pages and replay in
    // listing order, independent of the works-listing joins.
    db.add_collection_bookmarks("test_fest", &[1]).unwrap();
    db.add_collection_bookmarks("test_fest", &[1, 2]).unwrap();
    let works = db.get_collection_bookmarks("test_fest").unwrap();
    assert_eq!(works.iter().map(|w| w.id).collect::<Vec<_>>(), vec![1, 2]);
    assert!(db.get_collection_work_ids("test_fest").unwrap().is_empty());

    // Deleting a work cascades its join row.
    db.delete_work(1).unwrap();
    let works = db.get_collection_bookmarks("test_fest").unwrap();
    assert_eq!(works.iter().map(|w| w.id).collect::<Vec<_>>(), vec![2]);
}

#[test]
fn test_search_collections_filtered() {
    let db = open_test_db();
    let base = crate::models::CollectionSummary {
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

    let mut c = crate::models::CollectionSearchCriteria::default();
    c.title = "winter".into();
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

    // Limit caps the result set (0 = everything, per sql_limit).
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
    b.word_count = 100_000;
    b.chapter_count = 1;
    b.complete = true;
    b.language = "Deutsch".into();
    b.date_updated = "2026-08-01".into();
    b.kudos = 500;
    db.save_work(&b).unwrap();

    let ids = |c: &LocalSearchCriteria| -> Vec<u64> {
        db.search_local_works_filtered(c, 0).unwrap().iter().map(|w| w.id).collect()
    };

    // Empty criteria: whole library, newest-updated first.
    assert_eq!(ids(&LocalSearchCriteria::default()), vec![2, 1]);

    // Freeform tag present on one work / on none.
    let mut c = LocalSearchCriteria::default();
    c.freeform_names = "Fluff".into();
    assert_eq!(ids(&c), vec![1]);
    c.freeform_names = "Coffee Shops".into();
    assert!(ids(&c).is_empty());

    // Fandom name, and crossover flags.
    let mut c = LocalSearchCriteria::default();
    c.fandom_names = "Fandom B".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.crossover = "T".into();
    assert_eq!(ids(&c), vec![2]);
    c.crossover = "F".into();
    assert_eq!(ids(&c), vec![1]);

    // Rating / warning / category labels as AO3's form spells them.
    let mut c = LocalSearchCriteria::default();
    c.ratings = vec!["Explicit".into()];
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.warnings = vec!["Graphic Depictions Of Violence".into()];
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.categories = vec!["F/M".into()];
    assert_eq!(ids(&c), vec![1]);

    // Completion, single chapter, language.
    let mut c = LocalSearchCriteria::default();
    c.complete = "T".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.single_chapter = true;
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.language = "deutsch".into();
    assert_eq!(ids(&c), vec![2]);

    // Numeric ranges: >N and lo-hi.
    let mut c = LocalSearchCriteria::default();
    c.word_count = ">50,000".into();
    assert_eq!(ids(&c), vec![2]);
    let mut c = LocalSearchCriteria::default();
    c.kudos_count = "10-100".into();
    assert_eq!(ids(&c), vec![1]);

    // Date updated: prefix, absolute after, and a relative window wide
    // enough to stay deterministic.
    let mut c = LocalSearchCriteria::default();
    c.revised_at = "2025".into();
    assert_eq!(ids(&c), vec![1]);
    c.revised_at = "> 2025".into();
    assert_eq!(ids(&c), vec![2]);
    c.revised_at = "< 100 years ago".into();
    assert_eq!(ids(&c), vec![2, 1]);

    // Sorting: kudos ascending, title ascending by AO3's default direction.
    let mut c = LocalSearchCriteria::default();
    c.sort_column = "kudos_count".into();
    c.sort_direction = "asc".into();
    assert_eq!(ids(&c), vec![1, 2]);
    let mut c = LocalSearchCriteria::default();
    c.sort_column = "title_to_sort_on".into();
    assert_eq!(ids(&c), vec![2, 1]); // "Another…" before "Test…"

    // Creators substring hits both (shared author), title narrows to one.
    let mut c = LocalSearchCriteria::default();
    c.creators = "Author1".into();
    assert_eq!(ids(&c), vec![2, 1]);
    let mut c = LocalSearchCriteria::default();
    c.title = "another".into();
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
    assert_eq!(db.schema_version().unwrap(), 11);
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
            CREATE TABLE bookmarks (
                account_id TEXT NOT NULL DEFAULT '',
                work_id    INTEGER NOT NULL,
                note       TEXT DEFAULT '',
                sync_to_ao3 INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (account_id, work_id)
            );
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
    assert_eq!(db.schema_version().unwrap(), 11);
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
    assert_eq!(db.get_works_crawled_at("author", "writer_one").unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    assert_eq!(db.get_last_check_time().unwrap().as_deref(),
               Some("2024-08-02 00:00:00"));
    // Orphaned table dropped.
    let old_count: u32 = db.conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'subscription_snapshots_old'",
        [], |r| r.get(0)).unwrap();
    assert_eq!(old_count, 0);
    // v10: account ids lose the 'account-' prefix (accounts and bookmark
    // scoping alike), and signed-out bookmarks move to the "[none]"
    // sentinel — the active account still sees exactly its own rows.
    let (id, username, _) = db.get_active_account().unwrap().unwrap();
    assert_eq!((id.as_str(), username.as_str()), ("writer_one", "Writer_One"));
    assert_eq!(db.get_bookmarks().unwrap(), vec![7]);
    let sentinel_note: String = db.conn.query_row(
        "SELECT note FROM bookmarks WHERE account_id = '[none]' AND work_id = 7",
        [], |r| r.get(0)).unwrap();
    assert_eq!(sentinel_note, "signed-out era");
    // v4: last_checked_at exists on the migrated table and starts NULL.
    assert!(db.get_snapshot_last_checked("author", "writer_one").unwrap().is_none());
    db.set_snapshot_last_checked("author", "writer_one", "2026-08-11 03:00:00").unwrap();
    assert_eq!(db.get_snapshot_last_checked("author", "writer_one").unwrap().as_deref(),
               Some("2026-08-11 03:00:00"));
    // Reopening runs zero migrations and stays at the current version.
    drop(db);
    let db = Storage::open(&path_str, "").unwrap();
    assert_eq!(db.schema_version().unwrap(), 11);
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
    w2.word_count = 100_000;
    w2.chapter_count = 1;
    w2.complete = true;
    w2.language = "Deutsch".into();
    w2.date_published = "2019-01-01".into();
    w2.date_updated = "2026-08-01".into();
    w2.kudos = 500; w2.hits = 5000; w2.bookmarks = 50; w2.comments = 20;

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
    w3.word_count = 0;
    w3.chapter_count = 2;
    w3.date_published = String::new();
    w3.date_updated = String::new();
    w3.kudos = 3; w3.hits = 10; w3.bookmarks = 0; w3.comments = 0;

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
    w4.word_count = 4200;
    w4.chapter_count = 2;
    w4.language = "Français".into();
    w4.date_published = "2021-04-04".into();
    w4.date_updated = "2024-02-02".into();
    w4.kudos = 15; w4.hits = 250; w4.bookmarks = 3; w4.comments = 2;

    // Multiple warnings and categories — the AND semantics.
    let mut w5 = sample_work(5);
    w5.title = "Gen Multi Tale".into();
    w5.warnings = vec![Warning::None, Warning::CharacterDeath];
    w5.categories = vec!["Gen".into(), "Multi".into()];
    w5.rating = Rating::General;
    w5.chapter_count = 4;
    w5.complete = true;
    w5.word_count = 56_000;
    w5.date_published = "2022-05-05".into();
    w5.date_updated = "2025-06-30".into();
    w5.kudos = 99; w5.hits = 340; w5.bookmarks = 9; w5.comments = 5;

    let mut w6 = sample_work(6);
    w6.title = "Dark Fic".into();
    w6.fandoms = vec!["Fandom D".into()];
    w6.rating = Rating::Mature;
    w6.warnings = vec![Warning::Underage, Warning::Noncon];
    w6.categories = vec!["Other".into()];
    w6.tags = vec!["Dead Dove: Do Not Eat".into()];
    w6.word_count = 8000;
    w6.chapter_count = 7;
    w6.date_published = "2018-06-06".into();
    w6.date_updated = "2022-12-12".into();
    w6.kudos = 200; w6.hits = 700; w6.bookmarks = 14; w6.comments = 11;

    // The big-number extremes.
    let mut w7 = sample_work(7);
    w7.title = "Epic Saga".into();
    w7.authors = vec!["Author1".into()];
    w7.fandoms = vec!["Fandom B".into()];
    w7.rating = Rating::Explicit;
    w7.warnings = vec![Warning::Violence, Warning::CharacterDeath];
    w7.categories = vec!["M/M".into(), "Multi".into()];
    w7.word_count = 250_000;
    w7.chapter_count = 100;
    w7.complete = true;
    w7.date_published = "2025-07-07".into();
    w7.date_updated = "2026-01-01".into();
    w7.kudos = 20_000; w7.hits = 999_999; w7.bookmarks = 8000; w7.comments = 3000;

    let mut w8 = sample_work(8);
    w8.title = "Tiny Drabble".into();
    w8.authors = vec!["Writer (Pseud)".into()];
    w8.rating = Rating::General;
    w8.categories = vec!["Gen".into()];
    w8.word_count = 930;
    w8.chapter_count = 1;
    w8.complete = true;
    w8.date_published = "2017-08-08".into();
    w8.date_updated = "2021-07-07".into();
    w8.kudos = 64; w8.hits = 88; w8.bookmarks = 21; w8.comments = 9;

    let mut w9 = sample_work(9);
    w9.title = "Comma, The Title".into();
    w9.authors = vec!["Zeta".into()];
    w9.warnings = vec![];
    w9.categories = vec![];
    w9.tags = vec![];
    w9.word_count = 777;
    w9.chapter_count = 1;
    w9.complete = true;
    w9.date_published = "2020-05-05".into();
    w9.date_updated = "2020-06-06".into();
    w9.kudos = 7; w9.hits = 70; w9.bookmarks = 1; w9.comments = 4;

    // A category label outside AO3's fixed vocabulary (mask fallback path).
    let mut w10 = sample_work(10);
    w10.title = "Weird Category".into();
    w10.rating = Rating::Mature;
    w10.categories = vec!["Weird".into()];
    w10.word_count = 66_666;
    w10.chapter_count = 5;
    w10.date_published = "2016-10-10".into();
    w10.date_updated = "2023-03-03".into();
    w10.kudos = 150; w10.hits = 410; w10.bookmarks = 33; w10.comments = 13;

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
            let mut c = LocalSearchCriteria::default();
            c.sort_column = column.into();
            c.sort_direction = direction.into();
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
    ];
    let write_markers = [
        "INSERT INTO tags", "INSERT OR IGNORE INTO tags", "INSERT OR REPLACE INTO tags",
        "UPDATE tags", "DELETE FROM tags",
        "INSERT INTO works", "INSERT OR IGNORE INTO works", "INSERT OR REPLACE INTO works",
        "UPDATE works", "DELETE FROM works",
        "INTO work_tags", "UPDATE work_tags", "DELETE FROM work_tags",
        "INTO work_authors", "UPDATE work_authors", "DELETE FROM work_authors",
        "INTO app_state", "UPDATE app_state", "DELETE FROM app_state",
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
    db.save_work(&sample_work(4242)).unwrap();
    assert!(db.get_work(4242).unwrap().is_some());
    drop(tx); // rollback — the guard resyncs both caches
    assert!(db.get_work(4242).unwrap().is_none());
    let rows: i64 = db.conn
        .query_row("SELECT COUNT(*) FROM works WHERE id = 4242", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0);
}

/// Every write-through mutation must leave the cached entity and the
/// database row agreeing.
#[test]
fn works_cache_matches_rows_after_each_mutation() {
    let db = open_test_db();
    db.save_work(&sample_work(9)).unwrap();

    db.save_progress(9, 3, 120).unwrap();
    db.mark_work_read(9).unwrap();
    db.mark_work_detail_viewed(9, "2026-08-21 00:00:00").unwrap();
    db.set_works_gone(&[9], true).unwrap();
    let series = vec![SeriesMembership {
        series_id: 5, name: "S".into(), part: 1,
        prev_work_id: None, next_work_id: None,
    }];
    db.set_work_series(9, &series).unwrap();

    let (ch, pos, last_read, viewed, gone, series_json): (i64, i64, String, String, i64, String) =
        db.conn.query_row(
            "SELECT last_chapter_read, last_chapter_read_pos, last_read_dt,
                    detail_viewed_at, gone_from_ao3, series_json
             FROM works WHERE id = 9",
            [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
        ).unwrap();

    assert_eq!(db.get_progress(9).unwrap(), Some((ch as u32, pos as u32)));
    assert_eq!(db.get_work_last_read_times().unwrap(), vec![(9, last_read)]);
    assert_eq!(viewed, "2026-08-21 00:00:00");
    assert_eq!(db.get_detail_viewed_work_ids().unwrap(), vec![9]);
    assert_eq!(gone, 1);
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![9]);
    let hydrated = db.get_work(9).unwrap().unwrap();
    assert_eq!(hydrated.series, series);
    assert_eq!(serde_json::to_string(&hydrated.series).unwrap(), series_json);

    // A listing re-save (blurbs carry no series or library state) must
    // preserve all of it, in the row and the entity alike.
    db.save_work(&sample_work(9)).unwrap();
    let again = db.get_work(9).unwrap().unwrap();
    assert_eq!(again.series, series);
    assert_eq!(db.get_progress(9).unwrap(), Some((3, 120)));
    assert_eq!(db.get_gone_work_ids().unwrap(), vec![9]);

    // Deletion drops the entity with the row.
    db.delete_work(9).unwrap();
    assert!(db.get_work(9).unwrap().is_none());
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
