#[cfg(test)]
mod tests {
    use crate::parser::*;
    use crate::models::*;
    use std::fs;

    #[test]
    fn test_parse_listing_works_total() {
        // Paginated author listing heading.
        let ranged = r#"<div id="main"><h2 class="heading">1 - 20 of 1,234 Works by someauthor</h2></div>"#;
        assert_eq!(parse_listing_works_total(ranged), Some(1234));
        // Unpaginated author listing heading.
        let single = r#"<div id="main"><h2 class="heading">5 Works by someauthor</h2></div>"#;
        assert_eq!(parse_listing_works_total(single), Some(5));
        // Series stats block.
        let series = r#"<dl class="series meta group"><dt>Works:</dt><dd class="works">12</dd></dl>"#;
        assert_eq!(parse_listing_works_total(series), Some(12));
        // No count anywhere — unknown, never zero.
        let none = r#"<div id="main"><h2 class="heading">Works</h2></div>"#;
        assert_eq!(parse_listing_works_total(none), None);
    }

    #[test]
    fn test_parse_chapter_images() {
        let html = r#"<div class="userstuff">
            <p>Before the art.</p>
            <p><img src="https://example.com/a.png" alt="fan art"></p>
            <blockquote><p><img src="//cdn.example.com/b.jpg"></p></blockquote>
            <p><img src="/system/images/c.gif" alt=""></p>
            <p><img src="data:image/png;base64,xyz"></p>
        </div>"#;
        let doc = Html::parse_document(html);
        let el = doc.select(&sel("div.userstuff")).next().unwrap();
        let blocks = parse_element_children(&el);
        fn walk<'a>(blocks: &'a [ContentBlock], out: &mut Vec<(&'a str, &'a str)>) {
            for b in blocks {
                match b {
                    ContentBlock::Image { src, alt } => out.push((src, alt)),
                    ContentBlock::Blockquote { blocks } => walk(blocks, out),
                    ContentBlock::List { items, .. } => items.iter().for_each(|i| walk(i, out)),
                    _ => {}
                }
            }
        }
        let mut images = Vec::new();
        walk(&blocks, &mut images);
        assert_eq!(images, vec![
            ("https://example.com/a.png", "fan art"),
            ("https://cdn.example.com/b.jpg", ""),
            ("https://archiveofourown.org/system/images/c.gif", ""),
        ], "absolute kept, protocol-relative and rooted resolved, data: dropped");
        // Round-trips through the stored JSON encoding.
        let json = serde_json::to_string(&blocks).unwrap();
        let back: Vec<ContentBlock> = serde_json::from_str(&json).unwrap();
        assert_eq!(blocks, back);
    }

    #[test]
    fn test_parse_results_total() {
        // Search results heading.
        let search = r#"<div id="main"><h3 class="heading">1,234 Found</h3></div>"#;
        assert_eq!(parse_results_total(search), Some(1234));
        // Real fixture carries "3 Found".
        let html = fs::read_to_string("tests/fixtures/search_results.html").unwrap();
        assert_eq!(parse_results_total(&html), Some(3));
        // Tag listing shape falls through to the works-heading parser.
        let tag = r#"<div id="main"><h2 class="heading">1 - 20 of 567 Works in Some Tag</h2></div>"#;
        assert_eq!(parse_results_total(tag), Some(567));
        // Nothing recognizable → unknown, never zero.
        assert_eq!(parse_results_total("<p>hi</p>"), None);
    }

    #[test]
    fn test_parse_search_results() {
        let html = fs::read_to_string("tests/fixtures/search_results.html")
            .expect("Failed to read search results fixture");
        let works = parse_work_listings(&html).expect("Failed to parse");
        assert!(!works.is_empty(), "Should parse at least one work");

        let first = &works[0];
        assert!(first.id > 0, "Work should have a valid ID");
        assert!(!first.title.is_empty(), "Work should have a title");
        assert!(!first.authors.is_empty(), "Work should have authors");
        assert!(!first.fandoms.is_empty(), "Work should have fandoms");
    }

    #[test]
    fn test_listing_fails_closed_on_unrecognized_markup() {
        // No #main at all — a maintenance page, Cloudflare interstitial, or
        // a markup change that renamed the region. Must error, not "0 works".
        assert!(parse_work_listings("<html><body><p>Down for maintenance</p></body></html>").is_err());
        assert!(parse_bookmark_listings("<html><body><p>Down for maintenance</p></body></html>").is_err());

        // #main present but neither blurbs, an index container, nor an
        // empty-state notice — the blurb selectors no longer match.
        let drifted = r#"<div id="main"><ol class="listing collection"><li class="item">renamed</li></ol></div>"#;
        assert!(parse_work_listings(drifted).is_err());
        assert!(parse_bookmark_listings(drifted).is_err());
    }

    #[test]
    fn test_listing_accepts_genuinely_empty_pages() {
        // Empty index list still present.
        let empty_index = r#"<div id="main"><ol class="work index group"></ol></div>"#;
        assert!(parse_work_listings(empty_index).unwrap().is_empty());

        // Zero-state notice without an index container.
        let no_results = r#"<div id="main"><p>No results found. You may want to edit your search to make it less specific.</p></div>"#;
        assert!(parse_work_listings(no_results).unwrap().is_empty());

        let no_bookmarks = r#"<div id="main"><div class="bookmark index"><p>You don't have any bookmarks yet. There are no bookmarks to display.</p></div></div>"#;
        assert!(parse_bookmark_listings(no_bookmarks).unwrap().is_empty());
    }

    #[test]
    fn test_parse_search_results_stats() {
        let html = fs::read_to_string("tests/fixtures/search_results.html")
            .expect("Failed to read search results fixture");
        let works = parse_work_listings(&html).expect("Failed to parse");
        let first = &works[0];

        assert!(first.word_count > 0 || first.chapter_count > 0,
            "Should parse some stats: words={}, chapters={}",
            first.word_count, first.chapter_count);
    }

    #[test]
    fn test_parse_work_page() {
        let html = fs::read_to_string("tests/fixtures/work_page.html")
            .expect("Failed to read work page fixture");
        let result = parse_work_page(&html);
        assert!(result.is_ok(), "Should parse work page: {:?}", result.err());
        let (summary, chapters) = result.unwrap();

        assert!(summary.id > 0, "Should have valid work ID");
        assert!(!summary.title.is_empty(), "Should have title");
        assert!(!chapters.is_empty(), "Should have at least one chapter");
        assert!(!chapters[0].content.is_empty(), "Chapter should have content blocks");
    }

    #[test]
    fn test_parse_work_page_series() {
        let html = fs::read_to_string("tests/fixtures/work_series.html")
            .expect("Failed to read series work page fixture");
        let (summary, _) = parse_work_page(&html).expect("Should parse series work page");

        assert_eq!(summary.series.len(), 2, "Should find both memberships");

        let alpha = &summary.series[0];
        assert_eq!(alpha.series_id, 9000001);
        assert_eq!(alpha.name, "Alpha Test Series");
        assert_eq!(alpha.part, 2);
        assert_eq!(alpha.prev_work_id, Some(2000010));
        assert_eq!(alpha.next_work_id, Some(2000012));

        let beta = &summary.series[1];
        assert_eq!(beta.series_id, 9000002);
        assert_eq!(beta.name, "Beta Test Series");
        assert_eq!(beta.part, 1);
        assert_eq!(beta.prev_work_id, None);
        assert_eq!(beta.next_work_id, Some(2000013));
    }

    #[test]
    fn test_parse_work_page_no_series() {
        let html = fs::read_to_string("tests/fixtures/work_page.html")
            .expect("Failed to read work page fixture");
        let (summary, _) = parse_work_page(&html).expect("Should parse work page");
        assert!(summary.series.is_empty(), "Work not in a series should have none");
    }

    #[test]
    fn test_extract_series_edge_cases() {
        // No prev/next links, comma-grouped part number.
        let html = r#"<dl class="work meta group"><dd class="series">
            <span class="series">
              <span class="position">Part 1,002 of <a href="/series/77">Long Haul</a></span>
            </span>
        </dd></dl>"#;
        let doc = Html::parse_document(html);
        let series = extract_work_page_series(&doc);
        assert_eq!(series.len(), 1);
        assert_eq!(series[0].series_id, 77);
        assert_eq!(series[0].part, 1002);
        assert_eq!(series[0].prev_work_id, None);
        assert_eq!(series[0].next_work_id, None);

        // No leading number → part 0, membership still captured.
        let html = r#"<dd class="series"><span class="series">
            <span class="position">A work in <a href="/series/88">Numberless</a></span>
        </span></dd>"#;
        let doc = Html::parse_document(html);
        let series = extract_work_page_series(&doc);
        assert_eq!(series.len(), 1);
        assert_eq!(series[0].part, 0);
        assert_eq!(series[0].name, "Numberless");

        // Series name starting with a digit: part comes from text before the
        // link, never from the name.
        let html = r#"<dd class="series"><span class="series">
            <span class="position">Part 3 of <a href="/series/99">2 Fast 2 Fictional</a></span>
        </span></dd>"#;
        let doc = Html::parse_document(html);
        let series = extract_work_page_series(&doc);
        assert_eq!(series[0].part, 3);
        assert_eq!(series[0].name, "2 Fast 2 Fictional");

        // span.series with no /series/ link is skipped, not an error.
        let html = r#"<dd class="series"><span class="series">
            <span class="position">Part 1 of a mystery</span>
        </span></dd>"#;
        let doc = Html::parse_document(html);
        assert!(extract_work_page_series(&doc).is_empty());
    }

    #[test]
    fn test_parse_kudos_usernames() {
        let html = r#"<div id="kudos"><p class="kudos">
            <a href="/users/MockReaderOne">MockReaderOne</a>,
            <a href="/users/MockReaderTwo/pseuds/AltPseud">AltPseud</a>,
            and <a href="/works/123?show_comments=true">12 more users</a>
            as well as 30 guests left kudos on this work!</p></div>"#;
        let names = parse_kudos_usernames(html);
        assert_eq!(names, vec!["MockReaderOne", "AltPseud"]);

        // No kudos section at all.
        assert!(parse_kudos_usernames("<div id='main'></div>").is_empty());
    }

    #[test]
    fn test_inline_whitespace_collapses() {
        // Authors' HTML often wraps source lines mid-paragraph; rendered
        // text must treat those newlines as ordinary spaces.
        let html = "<p>measured distance. Three\n            days of separate meals and\t\tavoided eye contact</p>";
        let doc = Html::parse_fragment(html);
        let p = doc.select(&sel("p")).next().unwrap();
        let inlines = parse_inline_content(&p);
        assert_eq!(inlines.len(), 1);
        let InlineContent::Text { value } = &inlines[0] else {
            panic!("expected text, got {:?}", inlines[0]);
        };
        assert_eq!(value, "measured distance. Three days of separate meals and avoided eye contact");

        // The space between a text node and an inline element survives.
        let html = "<p>word <b>bold</b>\nand more</p>";
        let doc = Html::parse_fragment(html);
        let p = doc.select(&sel("p")).next().unwrap();
        let inlines = parse_inline_content(&p);
        assert_eq!(inlines.len(), 3);
        assert!(matches!(&inlines[0], InlineContent::Text { value } if value == "word "));
        assert!(matches!(&inlines[2], InlineContent::Text { value } if value == " and more"));
    }

    #[test]
    fn test_parse_chapters_format() {
        assert_eq!(parse_chapters("1/1"), (1, Some(1)));
        assert_eq!(parse_chapters("3/12"), (3, Some(12)));
        assert_eq!(parse_chapters("1/?"), (1, None));
        assert_eq!(parse_chapters("24/30"), (24, Some(30)));
    }

    #[test]
    fn test_rating_from_tag() {
        assert_eq!(Rating::from_ao3_tag("General Audiences"), Rating::General);
        assert_eq!(Rating::from_ao3_tag("Teen And Up Audiences"), Rating::Teen);
        assert_eq!(Rating::from_ao3_tag("Mature"), Rating::Mature);
        assert_eq!(Rating::from_ao3_tag("Explicit"), Rating::Explicit);
        assert_eq!(Rating::from_ao3_tag("Not Rated"), Rating::NotRated);
    }

    #[test]
    fn test_inline_content_parsing() {
        let html = r#"<p>Hello <b>world</b> and <em>italic</em> text with a <a href="/tags/foo">link</a>.</p>"#;
        let doc = Html::parse_fragment(html);
        let p = doc.select(&sel("p")).next().unwrap();
        let inlines = parse_inline_content(&p);

        assert!(inlines.len() >= 5, "Should have multiple inline elements, got: {:?}", inlines);

        // Check bold
        let has_bold = inlines.iter().any(|i| matches!(i, InlineContent::Bold { .. }));
        assert!(has_bold, "Should have bold content");

        // Check italic
        let has_italic = inlines.iter().any(|i| matches!(i, InlineContent::Italic { .. }));
        assert!(has_italic, "Should have italic content");

        // Check link
        let has_link = inlines.iter().any(|i| matches!(i, InlineContent::Link { .. }));
        assert!(has_link, "Should have link content");
    }
}

#[cfg(test)]
mod subscription_tests {
    use crate::parser::*;

    #[test]
    fn test_parse_composite_datetime() {
        // AO3's real composite timestamp markup.
        let html = r#"<html><body><span class="posted datetime">
            <abbr class="day" title="Wednesday">Wed</abbr>
            <span class="date">17</span>
            <abbr class="month" title="July">Jul</abbr>
            <span class="year">2026</span>
            <span class="time">03:12AM</span>
            <abbr class="timezone" title="Eastern Time (US &amp; Canada)">EDT</abbr>
        </span></body></html>"#;
        let doc = Html::parse_document(html);
        let el = doc.select(&sel("span.posted")).next().unwrap();
        assert_eq!(parse_composite_datetime(&el), "17 Jul 2026 03:12AM EDT");

        // Plain-text container falls back to normalized text.
        let plain = Html::parse_document(
            r#"<html><body><span class="posted datetime">  2025-03-15  </span></body></html>"#);
        let el = plain.select(&sel("span.posted")).next().unwrap();
        assert_eq!(parse_composite_datetime(&el), "2025-03-15");
    }

    #[test]
    fn test_extract_user_icon_url_skips_chrome_icon() {
        // Logged-in chrome carries the signed-in user's own icon before the
        // profile owner's — the extractor must take the primary header's.
        let html = r#"
        <html><body>
        <ul class="menu"><li><a href="/users/me"><img class="icon" src="https://example.org/my-own-icon.png"/></a></li></ul>
        <div id="main" class="profile-show dashboard region">
          <div class="user home profile">
            <div class="primary header module">
              <h2 class="heading">astolat</h2>
              <p class="icon"><a href="/users/astolat"><img alt="" class="icon" src="https://example.org/astolat-icon.png"/></a></p>
            </div>
          </div>
        </div>
        </body></html>
        "#;
        assert_eq!(extract_user_icon_url(html).as_deref(), Some("https://example.org/astolat-icon.png"));
        assert_eq!(extract_user_icon_url("<html><body><p>none</p></body></html>"), None);
    }

    #[test]
    fn test_total_pages() {
        // Real AO3 pagy markup shape: numbered links, a gap, last number = total.
        let html = r#"
        <ol class="pagination actions pagy" role="navigation" aria-label="Pagination">
            <li class="previous"><span class="disabled">← Previous</span></li>
            <li><a role="link" aria-disabled="true" aria-current="page" class="current">1</a></li>
            <li><a href="/users/x/works?page=2">2</a></li>
            <li><a href="/users/x/works?page=3">3</a></li>
            <li><span class="gap">&hellip;</span></li>
            <li><a href="/users/x/works?page=27">27</a></li>
            <li class="next"><a href="/users/x/works?page=2">Next →</a></li>
        </ol>
        "#;
        assert_eq!(total_pages(html), 27);
        assert_eq!(total_pages("<html><body><p>no pagination</p></body></html>"), 1);
    }

    #[test]
    fn test_parse_work_subscription_form() {
        // Subscribed state — real markup from a work page: delete method,
        // subscription id in the action.
        let subscribed = r#"
        <html><body>
        <form class="ajax-create-destroy" id="new_subscription" data-create-value="Subscribe" data-destroy-value="Unsubscribe" action="/users/RestlessIntimacy/subscriptions/1551470436" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="TOKEN123" autocomplete="off">
          <input autocomplete="off" type="hidden" value="88969876" name="subscription[subscribable_id]" id="subscription_subscribable_id">
          <input autocomplete="off" type="hidden" value="Work" name="subscription[subscribable_type]" id="subscription_subscribable_type">
          <input type="submit" name="commit" value="Unsubscribe">
        <input name="_method" type="hidden" value="delete"></form>
        </body></html>
        "#;
        let form = parse_work_subscription_form(subscribed).expect("form parses");
        assert!(form.subscribed);
        assert_eq!(form.action, "/users/RestlessIntimacy/subscriptions/1551470436");
        assert_eq!(form.token, "TOKEN123");
        assert_eq!(form.subscribable_id, "88969876");
        assert_eq!(form.subscribable_type, "Work");

        // Unsubscribed state: create action, no _method input.
        let unsubscribed = r#"
        <html><body>
        <form class="ajax-create-destroy" id="new_subscription" action="/users/RestlessIntimacy/subscriptions" method="post"><input type="hidden" name="authenticity_token" value="TOKEN456">
          <input type="hidden" value="88969876" name="subscription[subscribable_id]">
          <input type="hidden" value="Work" name="subscription[subscribable_type]">
          <input type="submit" name="commit" value="Subscribe">
        </form>
        </body></html>
        "#;
        let form = parse_work_subscription_form(unsubscribed).expect("form parses");
        assert!(!form.subscribed);
        assert_eq!(form.action, "/users/RestlessIntimacy/subscriptions");

        // Logged out: no form at all.
        assert!(parse_work_subscription_form("<html><body><p>none</p></body></html>").is_none());
    }

    #[test]
    fn test_parse_subscriptions_page_authors() {
        let html = r#"
        <html><body>
        <dl class="subscription index group">
            <dt><a href="/users/coolwriter">coolwriter</a></dt>
            <dd><form action="/users/me/subscriptions/98765"><input type="submit" value="Unsubscribe" /></form></dd>
            <dt><a href="/users/another_author">another_author</a></dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
        </dl>
        </body></html>
        "#;
        let subs = parse_subscriptions_page(html).unwrap();
        assert_eq!(subs.len(), 2);
        assert_eq!(subs[0].ao3_id.as_deref(), Some("98765"));
        assert_eq!(subs[1].ao3_id, None);
        assert_eq!(subs[0].sub_type, "author");
        assert_eq!(subs[0].id, "coolwriter");
        assert_eq!(subs[0].name, "coolwriter");
        assert_eq!(subs[1].sub_type, "author");
        assert_eq!(subs[1].id, "another_author");
    }

    #[test]
    fn test_parse_subscriptions_page_works() {
        let html = r#"
        <html><body>
        <dl class="subscription index group">
            <dt><a href="/works/12345">My Great Fic</a> (Work)</dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
            <dt><a href="/works/67890">Another Fic</a> (Work)</dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
        </dl>
        </body></html>
        "#;
        let subs = parse_subscriptions_page(html).unwrap();
        assert_eq!(subs.len(), 2);
        assert_eq!(subs[0].sub_type, "work");
        assert_eq!(subs[0].id, "12345");
        assert_eq!(subs[0].name, "My Great Fic");
        assert_eq!(subs[1].sub_type, "work");
        assert_eq!(subs[1].id, "67890");
    }

    #[test]
    fn test_parse_subscriptions_page_series() {
        let html = r#"
        <html><body>
        <dl class="subscription index group">
            <dt><a href="/series/999">Epic Series</a> (Series)</dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
        </dl>
        </body></html>
        "#;
        let subs = parse_subscriptions_page(html).unwrap();
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].sub_type, "series");
        assert_eq!(subs[0].id, "999");
        assert_eq!(subs[0].name, "Epic Series");
    }

    #[test]
    fn test_parse_subscriptions_page_mixed() {
        let html = r#"
        <html><body>
        <dl class="subscription index group">
            <dt><a href="/users/writer1">writer1</a></dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
            <dt><a href="/works/55555">Cool Work</a> (Work)</dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
            <dt><a href="/series/42">My Series</a> (Series)</dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
        </dl>
        </body></html>
        "#;
        let subs = parse_subscriptions_page(html).unwrap();
        assert_eq!(subs.len(), 3);
        let types: Vec<&str> = subs.iter().map(|s| s.sub_type.as_str()).collect();
        assert!(types.contains(&"author"));
        assert!(types.contains(&"work"));
        assert!(types.contains(&"series"));
    }

    #[test]
    fn test_parse_subscriptions_page_empty() {
        let html = "<html><body><dl class=\"subscription index group\"></dl></body></html>";
        let subs = parse_subscriptions_page(html).unwrap();
        assert!(subs.is_empty());
    }

    #[test]
    fn test_parse_subscriptions_no_dl() {
        let html = "<html><body><p>No subscriptions</p></body></html>";
        let subs = parse_subscriptions_page(html).unwrap();
        assert!(subs.is_empty());
    }

}

#[cfg(test)]
mod form_tests {
    use crate::parser::*;
    use crate::models::*;

    #[test]
    fn test_parse_search_form() {
        let html = std::fs::read_to_string("tests/fixtures/search_form.html")
            .expect("Failed to read search form fixture");
        let form = parse_search_form(&html).expect("Failed to parse form");
        println!("Found {} fields:", form.fields.len());
        for f in &form.fields {
            let type_name = match &f.field_type {
                FormFieldType::Text { .. } => "text",
                FormFieldType::Select { options } => &format!("select({})", options.len()),
                FormFieldType::Checkboxes { options } => &format!("checkboxes({})", options.len()),
                FormFieldType::Radio { .. } => "radio",
                FormFieldType::Hidden { .. } => "hidden",
            };
            println!("  [{type_name}] {} = \"{}\"", f.name, f.label);
        }
        assert!(form.fields.len() >= 5, "Should have at least 5 fields, got {}", form.fields.len());
    }
}

#[cfg(test)]
mod live_work_tests {
    use crate::parser::*;
    use crate::models::*;

    #[test]
    fn test_parse_live_work() {
        let html = std::fs::read_to_string("tests/fixtures/work_multi_chapter.html")
            .expect("read fixture");
        let (summary, chapters) = parse_work_page(&html).expect("parse work");
        println!("Title: {}", summary.title);
        println!("Chapters found: {}", chapters.len());
        for (i, ch) in chapters.iter().enumerate() {
            println!("  Ch {}: title={:?}, blocks={}", i+1, ch.title, ch.content.len());
            if let Some(ContentBlock::Paragraph { text }) = ch.content.first() {
                let preview: String = text.iter().map(|ic| match ic {
                    InlineContent::Text { value } => value.chars().take(60).collect::<String>(),
                    _ => "...".to_string(),
                }).collect();
                println!("    First para: {}...", preview);
            }
        }
        assert!(!chapters.is_empty(), "Should have chapters");
        assert!(!chapters[0].content.is_empty(), "Chapter should have content");
    }
}

#[cfg(test)]
mod comment_tests {
    use crate::parser::*;
    use std::fs;

    #[test]
    fn test_parse_comments() {
        let html = fs::read_to_string("tests/fixtures/comments.html")
            .expect("Failed to read comments fixture");
        let page = parse_comments(&html);

        assert_eq!(page.comments.len(), 3, "Should have 3 top-level comments");
        assert_eq!(page.current_page, 1);
        assert_eq!(page.total_pages, 3);

        let first = &page.comments[0];
        assert_eq!(first.id, 12345);
        assert_eq!(first.author.username, "BookwormJane");
        assert!(first.author.profile_url.is_some());
        assert_eq!(first.posted_at, "2025-03-15");
        assert!(!first.content.is_empty());
        assert_eq!(first.replies.len(), 1, "First comment should have 1 reply");
        assert_eq!(first.replies[0].author.username, "AuthorPerson");

        let guest = &page.comments[1];
        assert_eq!(guest.id, 12347);
        assert_eq!(guest.author.username, "A Guest (Guest)");
        assert!(guest.author.profile_url.is_none());
        assert!(guest.author.id.starts_with("guest:"));
        assert_eq!(guest.posted_at, "17 Mar 2025 04:20PM PDT");
        assert!(guest.replies.is_empty());

        let threaded = &page.comments[2];
        assert_eq!(threaded.id, 12348);
        assert_eq!(threaded.replies.len(), 2, "Third comment should have 2 replies");
    }

    #[test]
    fn test_parse_user_profile_fixture() {
        let html = fs::read_to_string("tests/fixtures/user_profile.html")
            .expect("Failed to read user profile fixture");
        let p = parse_user_profile(&html).expect("profile parses");

        assert_eq!(p.username, "MockAuthor");
        assert_eq!(p.numeric_id.as_deref(), Some("12345678"));
        assert_eq!(p.pseuds, vec!["MockAuthor".to_string()]);
        assert_eq!(p.joined, "2020-01-15");
        assert!(p.location.is_empty());
        assert!(p.bio.is_empty());
        assert_eq!(p.works_count, 2);
        assert_eq!(p.series_count, 1);
        assert_eq!(p.bookmarks_count, 0);
        assert_eq!(p.collections_count, 0);
        assert_eq!(p.gifts_count, 0);
        assert!(p.viewer_signed_in);
        assert!(!p.subscribed);
        assert!(p.subscription_ao3_id.is_none());
        assert!(!p.blocked);
        assert!(!p.muted);
        assert!(p.avatar_url.is_some());
    }

    #[test]
    fn test_parse_user_profile_subscribed_blocked_muted() {
        let html = r#"<html><body><div id="main">
          <div class="primary header module">
            <h2 class="heading">SomeAuthor</h2>
            <ul class="navigation actions">
              <li>
                <form class="ajax-create-destroy" id="new_subscription" action="/users/Me/subscriptions/456" method="post">
                  <input type="hidden" name="authenticity_token" value="tok" />
                  <input type="hidden" name="_method" value="delete" />
                  <input type="submit" name="commit" value="Unsubscribe" />
                </form>
              </li>
              <li><a href="/users/Me/blocked/users/77/confirm_unblock">Unblock</a></li>
              <li><a href="/users/Me/muted/users/88/confirm_unmute">Unmute</a></li>
            </ul>
          </div>
          <div class="wrapper">
            <dl class="meta">
              <dt class="pseuds">My pseuds:</dt>
              <dd class="pseuds"><a href="/users/SomeAuthor/pseuds/SomeAuthor">SomeAuthor</a>, <a href="/users/SomeAuthor/pseuds/AltPseud">AltPseud</a></dd>
              <dt>I joined on:</dt><dd>2015-01-02</dd>
              <dt>I live in:</dt><dd>The Library</dd>
              <dt>My user ID is:</dt><dd>424242</dd>
            </dl>
          </div>
          <div class="bio module">
            <blockquote class="userstuff"><p>Hello <em>there</em>.</p></blockquote>
          </div>
        </div></body></html>"#;
        let p = parse_user_profile(html).expect("profile parses");

        assert_eq!(p.username, "SomeAuthor");
        assert_eq!(p.numeric_id.as_deref(), Some("424242"));
        assert_eq!(p.pseuds, vec!["SomeAuthor".to_string(), "AltPseud".to_string()]);
        assert_eq!(p.joined, "2015-01-02");
        assert_eq!(p.location, "The Library");
        assert_eq!(p.bio.len(), 1);
        assert!(p.subscribed);
        assert_eq!(p.subscription_ao3_id.as_deref(), Some("456"));
        assert!(p.blocked);
        assert_eq!(p.block_ao3_id.as_deref(), Some("77"));
        assert!(p.muted);
        assert_eq!(p.mute_ao3_id.as_deref(), Some("88"));
    }

    #[test]
    fn test_parse_moderation_list() {
        let html = r#"<html><body><div id="main"><ul>
          <li class="user blurb group">
            <h4 class="heading"><a href="/users/BlockedOne/pseuds/BlockedOne">BlockedOne</a></h4>
            <ul class="actions"><li><a href="/users/Me/blocked/users/301/confirm_unblock">Unblock</a></li></ul>
          </li>
          <li class="user blurb group">
            <h4 class="heading"><a href="/users/BlockedTwo">BlockedTwo</a></h4>
            <ul class="actions"><li><a href="/users/Me/blocked/users/302/confirm_unblock">Unblock</a></li></ul>
          </li>
        </ul></div></body></html>"#;
        let list = parse_moderation_list(html, "confirm_unblock");
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].0, "BlockedOne");
        assert_eq!(list[0].1.as_deref(), Some("301"));
        assert_eq!(list[1].0, "BlockedTwo");
        assert_eq!(list[1].1.as_deref(), Some("302"));
        assert!(parse_moderation_list(html, "confirm_unmute").is_empty());
    }

    #[test]
    fn test_parse_collection_works_fixture() {
        // Collection listings nest the title link under the collection path
        // ("/collections/{name}/works/{id}") — titles and ids must parse
        // from both that and the plain "/works/{id}" form.
        let html = fs::read_to_string("tests/fixtures/collection_works.html")
            .expect("Failed to read collection works fixture");
        let works = parse_work_listings(&html).expect("collection works parse");
        assert_eq!(works.len(), 2);
        assert_eq!(works[0].id, 2000001);
        assert_eq!(works[0].title, "Nested Link Work");
        assert_eq!(works[0].authors, vec!["MockAuthor".to_string()]);
        assert_eq!(works[0].word_count, 5000);
        assert_eq!(works[1].id, 2000002);
        assert_eq!(works[1].title, "Plain Link Work");
    }

    #[test]
    fn test_parse_collection_bookmarks_fixture() {
        // Bookmark blurbs wrap standard work blurbs; series/external
        // bookmarks (no /works/ link) are skipped, and query strings on the
        // title link don't break id extraction.
        let html = fs::read_to_string("tests/fixtures/collection_bookmarks.html")
            .expect("Failed to read collection bookmarks fixture");
        let works = parse_bookmarked_works(&html).expect("bookmarked works parse");
        assert_eq!(works.len(), 2);
        assert_eq!(works[0].id, 3000001);
        assert_eq!(works[0].title, "Bookmarked Mock Work");
        assert_eq!(works[0].word_count, 7777);
        assert_eq!(works[1].id, 3000002);
        assert_eq!(works[1].title, "Second Bookmarked Work");
    }

    #[test]
    fn test_parse_collection_profile_fixture() {
        let html = fs::read_to_string("tests/fixtures/collection_profile.html")
            .expect("Failed to read collection profile fixture");
        let c = parse_collection_profile(&html, "test_fest_2026").expect("profile parse");
        assert_eq!(c.name, "test_fest_2026");
        assert_eq!(c.title, "Test Fest 2026");
        assert!(c.is_open);
        assert!(c.is_moderated);
        assert!(c.is_anonymous);
        assert_eq!(c.collection_type, "Gift Exchange Challenge");
        assert_eq!(c.maintainers, vec!["mod_one".to_string(), "mod_two".to_string()]);
        assert_eq!(c.tags, vec!["Fandom A".to_string(), "Synthetic Tag".to_string()]);
        assert_eq!(c.summary, "A synthetic collection profile for parser tests.");
        // Profile pages carry no counts — zero means "keep the cached value".
        assert_eq!(c.work_count, 0);

        // Fails closed on a page with no collection header.
        assert!(parse_collection_profile("<html><body><p>login</p></body></html>", "x").is_err());
    }

    #[test]
    fn test_parse_collections_fixture() {
        let html = fs::read_to_string("tests/fixtures/collections.html")
            .expect("Failed to read collections fixture");
        let collections = parse_collections_page(&html).expect("collections parse");
        assert_eq!(collections.len(), 2);

        let first = &collections[0];
        assert_eq!(first.name, "moonlit_teahouse_exchange");
        assert_eq!(first.title, "The Moonlit Teahouse Exchange");
        assert_eq!(first.summary,
                   "Cozy stories traded over imaginary tea.\nSign-ups close at moonrise.");
        assert!(first.is_open);
        assert!(first.is_moderated);
        assert!(first.is_anonymous);
        assert_eq!(first.work_count, 1204);
        assert_eq!(first.bookmarked_count, 37);
        assert_eq!(first.maintainers,
                   vec!["quillwright".to_string(), "inkfeather".to_string()]);
        assert_eq!(first.collection_type, "Gift Exchange Challenge");

        let second = &collections[1];
        assert_eq!(second.name, "paper_lantern_drabbles");
        assert_eq!(second.title, "Paper Lantern Drabbles");
        assert!(second.summary.is_empty());
        assert!(!second.is_open);
        assert!(!second.is_moderated);
        assert!(!second.is_anonymous);
        assert_eq!(second.work_count, 0);
        assert_eq!(second.bookmarked_count, 2);
        assert_eq!(second.maintainers, vec!["lanternkeeper".to_string()]);
        assert!(second.collection_type.is_empty());

        // Pagination markup uses the shared helpers.
        assert!(has_next_page(&html));
        assert_eq!(total_pages(&html), 3);
    }

    #[test]
    fn test_parse_collections_empty_with_container() {
        // Genuinely empty index — container still present, parses as empty.
        let empty_index = r#"<div id="main"><ul class="collection picture index group"></ul></div>"#;
        assert!(parse_collections_page(empty_index).unwrap().is_empty());

        // Zero-state notice without a container.
        let no_results = r#"<div id="main"><p>0 Collections found. Sorry, there were no collections found.</p></div>"#;
        assert!(parse_collections_page(no_results).unwrap().is_empty());
    }

    #[test]
    fn test_parse_collections_fails_closed_on_unrecognized_markup() {
        // No #main — maintenance page or interstitial.
        assert!(parse_collections_page(
            "<html><body><p>Down for maintenance</p></body></html>").is_err());

        // #main present but neither blurbs, an index container, nor an
        // empty-state notice — the blurb selectors no longer match.
        let drifted = r#"<div id="main"><ol class="listing collected"><li class="item">renamed</li></ol></div>"#;
        assert!(parse_collections_page(drifted).is_err());
    }
}
