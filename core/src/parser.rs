use scraper::{Html, Selector, ElementRef};

use crate::error::AppError;
use crate::models::*;

fn sel(s: &str) -> Selector {
    Selector::parse(s).unwrap()
}

fn text(el: &ElementRef) -> String {
    el.text().collect::<Vec<_>>().join("").trim().to_string()
}

fn simple_hash(s: &str) -> u64 {
    let mut h: u64 = 5381;
    for b in s.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    h
}

fn is_landmark_heading(block: &ContentBlock) -> bool {
    if let ContentBlock::Heading { text, .. } = block {
        let lower = text.to_lowercase();
        lower == "chapter text" || lower == "work text" || lower == "summary" || lower == "notes"
    } else {
        false
    }
}

fn parse_number(s: &str) -> u64 {
    s.replace(',', "").trim().parse().unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Work listing parser (search results / tag pages)
// ---------------------------------------------------------------------------

pub fn parse_work_listings(html: &str) -> Result<Vec<WorkSummary>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.work.blurb");
    let mut works = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        match parse_single_blurb(&blurb) {
            Ok(w) => works.push(w),
            Err(_) => continue,
        }
    }

    Ok(works)
}

fn parse_single_blurb(blurb: &ElementRef) -> Result<WorkSummary, AppError> {
    let id = extract_work_id(blurb)?;
    let title = extract_blurb_title(blurb);
    let authors = extract_blurb_authors(blurb);
    let fandoms = extract_tag_list(blurb, "h5.fandoms a.tag");
    let (rating, warnings, categories, complete) = extract_required_tags(blurb);
    let relationships = extract_tag_class_list(blurb, "relationships");
    let characters = extract_tag_class_list(blurb, "characters");
    let tags = extract_tag_class_list(blurb, "freeforms");
    let summary = extract_blurb_summary(blurb);
    let date_updated = extract_blurb_date(blurb);
    let language = extract_stat_text(blurb, "dd.language");
    let (word_count, chapter_count, total_chapters, kudos, hits, bookmarks, comments) =
        extract_blurb_stats(blurb);

    Ok(WorkSummary {
        id,
        title,
        authors,
        fandoms,
        rating,
        warnings,
        categories,
        relationships,
        characters,
        tags,
        summary,
        word_count,
        chapter_count,
        total_chapters,
        kudos,
        hits,
        bookmarks,
        comments,
        date_updated,
        language,
        complete,
    })
}

fn extract_work_id(blurb: &ElementRef) -> Result<u64, AppError> {
    // Try id="work_NNNNN"
    if let Some(id_attr) = blurb.value().id() {
        if let Some(id_str) = id_attr.strip_prefix("work_") {
            if let Ok(id) = id_str.parse::<u64>() {
                return Ok(id);
            }
        }
    }

    // Try class="... work-NNNNN ..." (bookmark blurbs)
    if let Some(classes) = blurb.value().attr("class") {
        for cls in classes.split_whitespace() {
            if let Some(id_str) = cls.strip_prefix("work-") {
                if let Ok(id) = id_str.parse::<u64>() {
                    return Ok(id);
                }
            }
        }
    }

    // Try from the title link href
    let link_sel = sel("h4.heading a[href^='/works/']");
    if let Some(link) = blurb.select(&link_sel).next() {
        if let Some(href) = link.value().attr("href") {
            let id_str = href.trim_start_matches("/works/");
            if let Ok(id) = id_str.parse::<u64>() {
                return Ok(id);
            }
        }
    }

    Err(AppError::ElementNotFound("work id".to_string()))
}

fn extract_blurb_title(blurb: &ElementRef) -> String {
    let sel = sel("h4.heading a[href^='/works/']");
    blurb
        .select(&sel)
        .next()
        .map(|el| text(&el))
        .unwrap_or_default()
}

fn extract_blurb_authors(blurb: &ElementRef) -> Vec<String> {
    let sel = sel("h4.heading a[rel='author']");
    blurb.select(&sel).map(|el| text(&el)).collect()
}

fn extract_tag_list(blurb: &ElementRef, selector: &str) -> Vec<String> {
    let s = sel(selector);
    blurb.select(&s).map(|el| text(&el)).collect()
}

fn extract_tag_class_list(blurb: &ElementRef, class: &str) -> Vec<String> {
    let selector_str = format!("ul.tags li.{} a.tag", class);
    let s = sel(&selector_str);
    blurb.select(&s).map(|el| text(&el)).collect()
}

fn extract_required_tags(blurb: &ElementRef) -> (Rating, Vec<Warning>, Vec<String>, bool) {
    let s = sel("ul.required-tags span");
    let spans: Vec<String> = blurb.select(&s).map(|el| {
        el.value().attr("class").unwrap_or("").to_string()
    }).collect();

    let mut rating = Rating::NotRated;
    let mut warnings = Vec::new();
    let mut categories = Vec::new();
    let mut complete = false;

    for class in &spans {
        if class.contains("rating-") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("rating-"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            rating = Rating::from_ao3_tag(title);
        }
        if class.contains("warning") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("warning"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            warnings.push(Warning::from_ao3_tag(title));
        }
        if class.contains("category-") {
            let title = blurb.select(&s)
                .find(|el| el.value().attr("class").unwrap_or("").contains("category-"))
                .and_then(|el| el.value().attr("title"))
                .unwrap_or("");
            if !title.is_empty() {
                categories.push(title.to_string());
            }
        }
        if class.contains("complete-yes") || class.contains("iswip") {
            complete = class.contains("complete-yes");
        }
    }

    if warnings.is_empty() {
        warnings.push(Warning::None);
    }

    (rating, warnings, categories, complete)
}

fn extract_blurb_summary(blurb: &ElementRef) -> String {
    let s = sel("blockquote.userstuff.summary");
    blurb.select(&s).next().map(|el| {
        el.text().collect::<Vec<_>>().join("").trim().to_string()
    }).unwrap_or_default()
}

fn extract_blurb_date(blurb: &ElementRef) -> String {
    let s = sel("p.datetime");
    blurb.select(&s).next().map(|el| text(&el)).unwrap_or_default()
}

fn extract_stat_text(blurb: &ElementRef, selector: &str) -> String {
    let s = sel(selector);
    blurb.select(&s).next().map(|el| text(&el)).unwrap_or_default()
}

fn extract_blurb_stats(blurb: &ElementRef) -> (u64, u32, Option<u32>, u32, u64, u32, u32) {
    let words = parse_number(&extract_stat_text(blurb, "dd.words"));
    let chapters_str = extract_stat_text(blurb, "dd.chapters");
    let (chapter_count, total_chapters) = parse_chapters(&chapters_str);
    let kudos = parse_number(&extract_stat_text(blurb, "dd.kudos")) as u32;
    let hits = parse_number(&extract_stat_text(blurb, "dd.hits"));
    let bookmarks = parse_number(&extract_stat_text(blurb, "dd.bookmarks")) as u32;
    let comments = parse_number(&extract_stat_text(blurb, "dd.comments")) as u32;

    (words, chapter_count, total_chapters, kudos, hits, bookmarks, comments)
}

fn parse_chapters(s: &str) -> (u32, Option<u32>) {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() == 2 {
        let current = parts[0].trim().parse().unwrap_or(0);
        let total = if parts[1].trim() == "?" {
            None
        } else {
            parts[1].trim().parse().ok()
        };
        (current, total)
    } else {
        (1, Some(1))
    }
}

// ---------------------------------------------------------------------------
// Bookmark listing parser (/users/{username}/bookmarks)
// ---------------------------------------------------------------------------

pub fn parse_bookmark_listings(html: &str) -> Result<Vec<BookmarkListing>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.bookmark.blurb");
    let mut bookmarks = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        match parse_single_bookmark_blurb(&blurb) {
            Ok(bl) => bookmarks.push(bl),
            Err(_) => continue,
        }
    }

    Ok(bookmarks)
}

fn parse_single_bookmark_blurb(blurb: &ElementRef) -> Result<BookmarkListing, AppError> {
    // Extract ao3_bookmark_id from the element's id attribute: "bookmark_12345"
    let ao3_bookmark_id = blurb
        .value()
        .id()
        .and_then(|id| id.strip_prefix("bookmark_"))
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or_else(|| AppError::ElementNotFound("bookmark id".to_string()))?;

    // Extract work_id from the heading link
    let work_link_sel = sel("h4.heading a[href*='/works/']");
    let work_id = blurb
        .select(&work_link_sel)
        .next()
        .and_then(|a| a.value().attr("href"))
        .and_then(|href| {
            href.split("/works/")
                .nth(1)
                .and_then(|s| s.split('/').next())
                .and_then(|s| s.split('?').next())
                .and_then(|s| s.parse::<u64>().ok())
        })
        .ok_or_else(|| AppError::ElementNotFound("work id in bookmark".to_string()))?;

    // Extract bookmarker's notes (not the work summary)
    let note_sel = sel("blockquote.userstuff.notes p");
    let note = blurb
        .select(&note_sel)
        .map(|el| text(&el))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    // Try to parse the work blurb data (reuse existing helpers)
    let work_summary = parse_single_blurb(blurb).ok();

    Ok(BookmarkListing {
        work_id,
        ao3_bookmark_id,
        note,
        work_summary,
    })
}

/// Check whether the HTML page has a "next" pagination link.
pub fn has_next_page(html: &str) -> bool {
    let doc = Html::parse_document(html);
    let next_sel1 = sel("li.next a");
    let next_sel2 = sel("a[rel='next']");
    doc.select(&next_sel1).next().is_some() || doc.select(&next_sel2).next().is_some()
}

// ---------------------------------------------------------------------------
// Work page parser (single work with metadata + chapter content)
// ---------------------------------------------------------------------------

pub fn parse_work_page(html: &str) -> Result<(WorkSummary, Vec<Chapter>), AppError> {
    let doc = Html::parse_document(html);

    let id = extract_work_page_id(&doc);
    let title = extract_work_page_title(&doc);
    let authors = extract_work_page_authors(&doc);
    let (rating, warnings, categories, fandoms, relationships, characters, tags) =
        extract_work_meta(&doc);
    let summary = extract_work_page_summary(&doc);
    let (word_count, chapter_count, total_chapters, kudos, hits, bookmarks, comments) =
        extract_work_page_stats(&doc);
    let language = extract_work_page_stat(&doc, "dd.language");
    let date_updated = extract_work_page_stat(&doc, "dd.published");
    let complete = total_chapters.map_or(false, |t| chapter_count >= t);

    let chapters = parse_chapters_content(&doc);

    let summary_obj = WorkSummary {
        id,
        title,
        authors,
        fandoms,
        rating,
        warnings,
        categories,
        relationships,
        characters,
        tags,
        summary,
        word_count,
        chapter_count,
        total_chapters,
        kudos,
        hits,
        bookmarks,
        comments,
        date_updated,
        language,
        complete,
    };

    Ok((summary_obj, chapters))
}

fn extract_work_page_id(doc: &Html) -> u64 {
    // Try from the comment textarea id: comment_content_for_NNNNN
    let textarea_sel = sel("textarea[id^='comment_content_for_']");
    if let Some(el) = doc.select(&textarea_sel).next() {
        if let Some(id_attr) = el.value().attr("id") {
            let id_str = id_attr.trim_start_matches("comment_content_for_");
            if let Ok(id) = id_str.parse() {
                return id;
            }
        }
    }
    // Try from the kudos link href: /works/NNNNN#kudos
    let kudos_sel = sel("dd.kudos a");
    if let Some(link) = doc.select(&kudos_sel).next() {
        if let Some(href) = link.value().attr("href") {
            let id_str = href
                .trim_start_matches("/works/")
                .split('#')
                .next()
                .unwrap_or("");
            if let Ok(id) = id_str.parse() {
                return id;
            }
        }
    }
    // Try from bookmarks link: /works/NNNNN/bookmarks
    let bm_sel = sel("dd.bookmarks a");
    if let Some(link) = doc.select(&bm_sel).next() {
        if let Some(href) = link.value().attr("href") {
            for part in href.split('/') {
                if let Ok(id) = part.parse::<u64>() {
                    return id;
                }
            }
        }
    }
    0
}

fn extract_work_page_title(doc: &Html) -> String {
    let s = sel("h2.title.heading");
    doc.select(&s).next().map(|el| text(&el)).unwrap_or_default()
}

fn extract_work_page_authors(doc: &Html) -> Vec<String> {
    let s = sel("h3.byline.heading a[rel='author']");
    doc.select(&s).map(|el| text(&el)).collect()
}

fn extract_work_meta(doc: &Html) -> (Rating, Vec<Warning>, Vec<String>, Vec<String>, Vec<String>, Vec<String>, Vec<String>) {
    let rating_sel = sel("dd.rating.tags a.tag");
    let rating = doc.select(&rating_sel)
        .next()
        .map(|el| Rating::from_ao3_tag(&text(&el)))
        .unwrap_or(Rating::NotRated);

    let warning_sel = sel("dd.warning.tags a.tag");
    let warnings: Vec<Warning> = doc.select(&warning_sel)
        .map(|el| Warning::from_ao3_tag(&text(&el)))
        .collect();
    let warnings = if warnings.is_empty() { vec![Warning::None] } else { warnings };

    let cat_sel = sel("dd.category.tags a.tag");
    let categories: Vec<String> = doc.select(&cat_sel).map(|el| text(&el)).collect();

    let fandom_sel = sel("dd.fandom.tags a.tag");
    let fandoms: Vec<String> = doc.select(&fandom_sel).map(|el| text(&el)).collect();

    let rel_sel = sel("dd.relationship.tags a.tag");
    let relationships: Vec<String> = doc.select(&rel_sel).map(|el| text(&el)).collect();

    let char_sel = sel("dd.character.tags a.tag");
    let characters: Vec<String> = doc.select(&char_sel).map(|el| text(&el)).collect();

    let tag_sel = sel("dd.freeform.tags a.tag");
    let tags: Vec<String> = doc.select(&tag_sel).map(|el| text(&el)).collect();

    (rating, warnings, categories, fandoms, relationships, characters, tags)
}

fn extract_work_page_summary(doc: &Html) -> String {
    let s = sel("div.summary blockquote.userstuff");
    doc.select(&s)
        .next()
        .map(|el| el.text().collect::<Vec<_>>().join("").trim().to_string())
        .unwrap_or_default()
}

fn extract_work_page_stat(doc: &Html, selector: &str) -> String {
    let s = sel(selector);
    doc.select(&s).next().map(|el| text(&el)).unwrap_or_default()
}

fn extract_work_page_stats(doc: &Html) -> (u64, u32, Option<u32>, u32, u64, u32, u32) {
    let words = parse_number(&extract_work_page_stat(doc, "dd.words"));
    let chapters_str = extract_work_page_stat(doc, "dd.chapters");
    let (chapter_count, total_chapters) = parse_chapters(&chapters_str);
    let kudos = parse_number(&extract_work_page_stat(doc, "dd.kudos")) as u32;
    let hits = parse_number(&extract_work_page_stat(doc, "dd.hits"));
    let bookmarks = parse_number(&extract_work_page_stat(doc, "dd.bookmarks")) as u32;
    let comments = parse_number(&extract_work_page_stat(doc, "dd.comments")) as u32;

    (words, chapter_count, total_chapters, kudos, hits, bookmarks, comments)
}

// ---------------------------------------------------------------------------
// Chapter body → ContentBlock tree
// ---------------------------------------------------------------------------

fn parse_chapters_content(doc: &Html) -> Vec<Chapter> {
    // Multi-chapter: each chapter is div.chapter[id^="chapter-"] directly under div#chapters
    // Use ID selector to avoid matching nested div.chapter.preface elements
    let mut chapters = Vec::new();

    for i in 1..=200 {
        let ch_sel_str = format!("div#chapter-{i}");
        let Ok(ch_sel) = Selector::parse(&ch_sel_str) else { break };
        let Some(ch) = doc.select(&ch_sel).next() else { break };

        // Title from the first h3.title inside the preface
        let title_sel = sel("div.chapter.preface h3.title");
        let title = ch.select(&title_sel).next().map(|el| text(&el));

        // Notes before (in preface blockquote.userstuff)
        let notes_before_sel = sel("div.chapter.preface blockquote.userstuff");
        let notes_before_blocks: Vec<ContentBlock> = ch.select(&notes_before_sel).next()
            .map(|el| parse_element_children(&el))
            .unwrap_or_default();
        let notes_before = ch.select(&notes_before_sel).next().map(|el| {
            el.text().collect::<Vec<_>>().join("").trim().to_string()
        }).filter(|s| !s.is_empty());

        // Content from div.userstuff.module[role="article"]
        let content_sel = sel("div.userstuff.module[role='article']");
        let body_blocks: Vec<ContentBlock> = ch.select(&content_sel)
            .next()
            .map(|el| parse_element_children(&el))
            .unwrap_or_default()
            .into_iter()
            .filter(|b| !is_landmark_heading(b))
            .collect();

        // Notes after (in div.end.notes blockquote.userstuff)
        let notes_after_sel = sel("div.end.notes blockquote.userstuff");
        let notes_after_blocks: Vec<ContentBlock> = ch.select(&notes_after_sel).next()
            .map(|el| parse_element_children(&el))
            .unwrap_or_default();
        let notes_after = ch.select(&notes_after_sel).next().map(|el| {
            el.text().collect::<Vec<_>>().join("").trim().to_string()
        }).filter(|s| !s.is_empty());

        // Merge: notes_before + body + notes_after
        let mut blocks = Vec::new();
        if !notes_before_blocks.is_empty() {
            blocks.push(ContentBlock::Heading { level: 4, text: "Notes:".to_string() });
            blocks.push(ContentBlock::HorizontalRule);
            blocks.extend(notes_before_blocks);
            blocks.push(ContentBlock::HorizontalRule);
        }
        blocks.extend(body_blocks);
        if !notes_after_blocks.is_empty() {
            blocks.push(ContentBlock::HorizontalRule);
            blocks.push(ContentBlock::Heading { level: 4, text: "End Notes:".to_string() });
            blocks.push(ContentBlock::HorizontalRule);
            blocks.extend(notes_after_blocks);
        }

        // Extract chapter ID from links if available
        let ch_id = ch.select(&sel("h3.title a[href*='/chapters/']"))
            .next()
            .and_then(|a| a.value().attr("href"))
            .and_then(|href| href.rsplit('/').next())
            .and_then(|s| s.parse::<u64>().ok());

        chapters.push(Chapter {
            id: ch_id,
            title,
            number: i as u32,
            content: blocks,
            notes_before,
            notes_after,
        });
    }

    if !chapters.is_empty() {
        return chapters;
    }

    // Single-chapter work — no div#chapter-N elements
    let content_sel = sel("div.userstuff.module[role='article']");
    if let Some(el) = doc.select(&content_sel).next() {
        let blocks: Vec<ContentBlock> = parse_element_children(&el).into_iter().filter(|b| !is_landmark_heading(b)).collect();
        if !blocks.is_empty() {
            return vec![Chapter {
                id: None,
                title: None,
                number: 1,
                content: blocks,
                notes_before: None,
                notes_after: None,
            }];
        }
    }

    // Final fallback: any div.userstuff with paragraphs
    let fallback_sel = sel("div.userstuff");
    for el in doc.select(&fallback_sel) {
        let classes = el.value().attr("class").unwrap_or("");
        if classes.contains("summary") { continue; }
        if el.select(&sel("p")).next().is_none() { continue; }
        let blocks: Vec<ContentBlock> = parse_element_children(&el).into_iter().filter(|b| !is_landmark_heading(b)).collect();
        if !blocks.is_empty() {
            return vec![Chapter {
                id: None,
                title: None,
                number: 1,
                content: blocks,
                notes_before: None,
                notes_after: None,
            }];
        }
    }

    Vec::new()
}

pub fn parse_element_children(el: &ElementRef) -> Vec<ContentBlock> {
    let mut blocks = Vec::new();

    for child in el.children() {
        if let Some(element) = child.value().as_element() {
            let child_ref = ElementRef::wrap(child).unwrap();
            match element.name() {
                "p" => {
                    let inlines = parse_inline_content(&child_ref);
                    if !inlines.is_empty() {
                        blocks.push(ContentBlock::Paragraph { text: inlines });
                    }
                }
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    let level = element.name().chars().last().unwrap().to_digit(10).unwrap() as u8;
                    blocks.push(ContentBlock::Heading {
                        level,
                        text: text(&child_ref),
                    });
                }
                "blockquote" => {
                    let inner = parse_element_children(&child_ref);
                    blocks.push(ContentBlock::Blockquote { blocks: inner });
                }
                "hr" => {
                    blocks.push(ContentBlock::HorizontalRule);
                }
                "ul" => {
                    let items = parse_list_items(&child_ref);
                    blocks.push(ContentBlock::List { ordered: false, items });
                }
                "ol" => {
                    let items = parse_list_items(&child_ref);
                    blocks.push(ContentBlock::List { ordered: true, items });
                }
                "pre" => {
                    blocks.push(ContentBlock::PreFormatted { text: text(&child_ref) });
                }
                "div" | "center" => {
                    let inner = parse_element_children(&child_ref);
                    blocks.extend(inner);
                }
                _ => {}
            }
        }
    }

    blocks
}

fn parse_list_items(list: &ElementRef) -> Vec<Vec<ContentBlock>> {
    let li_sel = sel("li");
    list.select(&li_sel)
        .map(|li| {
            let has_block_children = li.children().any(|c| {
                c.value().as_element().map_or(false, |e| {
                    matches!(e.name(), "p" | "blockquote" | "ul" | "ol" | "div")
                })
            });
            if has_block_children {
                parse_element_children(&li)
            } else {
                let inlines = parse_inline_content(&li);
                if inlines.is_empty() {
                    Vec::new()
                } else {
                    vec![ContentBlock::Paragraph { text: inlines }]
                }
            }
        })
        .collect()
}

pub fn parse_inline_content(el: &ElementRef) -> Vec<InlineContent> {
    let mut inlines = Vec::new();

    for child in el.children() {
        if child.value().is_text() {
            let t = child.value().as_text().unwrap();
            let s = t.to_string();
            if !s.is_empty() {
                if s.contains('\n') && s.trim().is_empty() {
                    inlines.push(InlineContent::Text {
                        value: " ".to_string(),
                    });
                } else {
                    inlines.push(InlineContent::Text { value: s });
                }
            }
        } else if child.value().is_element() {
            let element = child.value().as_element().unwrap();
            let child_ref = ElementRef::wrap(child).unwrap();
            match element.name() {
                "br" => {
                    inlines.push(InlineContent::LineBreak);
                }
                "strong" | "b" => {
                    let content = parse_inline_content(&child_ref);
                    if !content.is_empty() {
                        inlines.push(InlineContent::Bold { content });
                    }
                }
                "em" | "i" => {
                    let content = parse_inline_content(&child_ref);
                    if !content.is_empty() {
                        inlines.push(InlineContent::Italic { content });
                    }
                }
                "a" => {
                    let href = element.attr("href").unwrap_or("").to_string();
                    let content = parse_inline_content(&child_ref);
                    if !content.is_empty() {
                        inlines.push(InlineContent::Link { href, content });
                    }
                }
                "s" | "strike" | "del" => {
                    let content = parse_inline_content(&child_ref);
                    if !content.is_empty() {
                        inlines.push(InlineContent::Strikethrough { content });
                    }
                }
                "sup" => {
                    let content = parse_inline_content(&child_ref);
                    if !content.is_empty() {
                        inlines.push(InlineContent::Superscript { content });
                    }
                }
                "span" | "u" => {
                    let content = parse_inline_content(&child_ref);
                    inlines.extend(content);
                }
                _ => {
                    let content = parse_inline_content(&child_ref);
                    inlines.extend(content);
                }
            }
        }
    }
    while inlines.first().map_or(false, |i| matches!(i, InlineContent::Text { value } if value.trim().is_empty())) {
        inlines.remove(0);
    }
    while inlines.last().map_or(false, |i| matches!(i, InlineContent::Text { value } if value.trim().is_empty())) {
        inlines.pop();
    }
    inlines
}

// ---------------------------------------------------------------------------
// Subscription page parser (/users/{username}/subscriptions)
// ---------------------------------------------------------------------------

/// Parse AO3's subscriptions page to extract subscription entries.
///
/// Each subscription is an `li` or `dl` element containing links that indicate
/// the subscription type via URL pattern:
/// - `/users/{name}/pseuds` or `/users/{name}` => author subscription
/// - `/works/{id}` => work subscription
/// - `/series/{id}` => series subscription
pub fn parse_subscriptions_page(html: &str) -> Result<Vec<Subscription>, AppError> {
    let doc = Html::parse_document(html);
    let mut subs = Vec::new();

    // AO3 subscriptions are in <dl class="subscription index group">
    // Each subscription is a <dt> containing a link:
    //   Author: <a href="/users/Name">Name</a>
    //   Work:   <a href="/works/ID">Title</a> (Work)
    //   Series: <a href="/series/ID">Title</a> (Series)
    let dt_sel = sel("dl.subscription dt");
    let link_sel = sel("a[href]");

    for dt in doc.select(&dt_sel) {
        // Get the first link in this dt — that's the subscription target
        let Some(link) = dt.select(&link_sel).next() else { continue };
        let href = link.value().attr("href").unwrap_or("");
        let display = text(&link);

        if let Some(rest) = href.strip_prefix("/users/") {
            let username = rest.split('/').next().unwrap_or("");
            if !username.is_empty() && !href.contains("/subscriptions") {
                subs.push(Subscription {
                    sub_type: "author".to_string(),
                    id: username.to_string(),
                    name: if display.is_empty() { username.to_string() } else { display },
                });
            }
        } else if let Some(rest) = href.strip_prefix("/works/") {
            let id_str = rest.split('/').next().unwrap_or("");
            if id_str.parse::<u64>().is_ok() {
                subs.push(Subscription {
                    sub_type: "work".to_string(),
                    id: id_str.to_string(),
                    name: if display.is_empty() { format!("Work {id_str}") } else { display },
                });
            }
        } else if let Some(rest) = href.strip_prefix("/series/") {
            let id_str = rest.split('/').next().unwrap_or("");
            if id_str.parse::<u64>().is_ok() {
                subs.push(Subscription {
                    sub_type: "series".to_string(),
                    id: id_str.to_string(),
                    name: if display.is_empty() { format!("Series {id_str}") } else { display },
                });
            }
        }
    }

    Ok(subs)
}

// ---------------------------------------------------------------------------
// Series page parser (/series/{id})
// ---------------------------------------------------------------------------

/// Parse a series page to extract the list of works.
/// Returns Vec of (work_id, title, chapter_count, word_count).
pub fn parse_series_page(html: &str) -> Result<Vec<(u64, String, u32, u64)>, AppError> {
    let doc = Html::parse_document(html);
    let blurb_sel = sel("li.work.blurb");
    let mut works = Vec::new();

    for blurb in doc.select(&blurb_sel) {
        let id = match extract_work_id(&blurb) {
            Ok(id) => id,
            Err(_) => continue,
        };
        let title = extract_blurb_title(&blurb);
        let (word_count, chapter_count, _total, _kudos, _hits, _bookmarks, _comments) =
            extract_blurb_stats(&blurb);

        works.push((id, title, chapter_count, word_count));
    }

    Ok(works)
}

// ---------------------------------------------------------------------------
// Search form parser — extracts form structure from /works/search?edit_search=true
// ---------------------------------------------------------------------------

pub fn parse_search_form(html: &str) -> Result<SearchForm, AppError> {
    let doc = Html::parse_document(html);
    let mut fields = Vec::new();
    let mut seen_names = std::collections::HashSet::new();

    // Find the main search form: <form id="new_work_search">
    let form_sel = sel("form#new_work_search");
    let form = doc.select(&form_sel).next()
        .ok_or_else(|| AppError::ElementNotFound("search form #new_work_search".to_string()))?;

    // Iterate <dd> elements — each contains one field or field group
    let dd_sel = sel("dd");
    let dt_sel = sel("dt");
    let dts: Vec<ElementRef> = form.select(&dt_sel).collect();
    let dds: Vec<ElementRef> = form.select(&dd_sel).collect();

    for (i, dd) in dds.iter().enumerate() {
        // Get the matching <dt> label
        let dt_label = if i < dts.len() {
            text(&dts[i]).trim_end_matches('?').trim().to_string()
        } else {
            String::new()
        };

        // Check what's inside this <dd>
        // 1. Text input
        let input_sel = sel("input[type='text'][name^='work_search']");
        if let Some(input) = dd.select(&input_sel).next() {
            let name = input.value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let id = input.value().attr("id").unwrap_or("");
                let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                fields.push(FormField {
                    name,
                    label,
                    field_type: FormFieldType::Text { placeholder: String::new() },
                });
                continue;
            }
        }

        // 2. Select dropdown
        let select_sel = sel("select[name^='work_search']");
        if let Some(select) = dd.select(&select_sel).next() {
            let name = select.value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let id = select.value().attr("id").unwrap_or("");
                let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                let option_sel = sel("option");
                let options: Vec<FormOption> = select.select(&option_sel).map(|opt| {
                    FormOption {
                        value: opt.value().attr("value").unwrap_or("").to_string(),
                        label: text(&opt),
                        selected: opt.value().attr("selected").is_some(),
                    }
                }).collect();
                fields.push(FormField {
                    name,
                    label,
                    field_type: FormFieldType::Select { options },
                });
                continue;
            }
        }

        // 3. Radio button group
        let radio_sel = sel("input[type='radio'][name^='work_search']");
        let radios: Vec<ElementRef> = dd.select(&radio_sel).collect();
        if !radios.is_empty() {
            let name = radios[0].value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let options: Vec<FormOption> = radios.iter().map(|r| {
                    let value = r.value().attr("value").unwrap_or("").to_string();
                    let id = r.value().attr("id").unwrap_or("");
                    let label = find_label_for(&form, id);
                    let selected = r.value().attr("checked").is_some();
                    FormOption { value, label, selected }
                }).collect();
                fields.push(FormField {
                    name,
                    label: dt_label.clone(),
                    field_type: FormFieldType::Radio { options },
                });
                continue;
            }
        }

        // 4. Checkbox group (multiple checkboxes with same name[])
        let cb_sel = sel("input[type='checkbox'][name^='work_search']");
        let cbs: Vec<ElementRef> = dd.select(&cb_sel).collect();
        if !cbs.is_empty() {
            let name = cbs[0].value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                if cbs.len() == 1 && !name.contains("[]") {
                    // Single checkbox (e.g. single_chapter) — treat as select with on/off
                    let id = cbs[0].value().attr("id").unwrap_or("");
                    let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                    fields.push(FormField {
                        name,
                        label,
                        field_type: FormFieldType::Checkboxes { options: vec![
                            FormOption { value: "1".to_string(), label: "Yes".to_string(), selected: false },
                        ]},
                    });
                } else {
                    // Multi-checkbox group
                    let options: Vec<FormOption> = cbs.iter().map(|cb| {
                        let value = cb.value().attr("value").unwrap_or("").to_string();
                        let id = cb.value().attr("id").unwrap_or("");
                        let label = find_label_for(&form, id);
                        let selected = cb.value().attr("checked").is_some();
                        FormOption { value, label, selected }
                    }).collect();
                    let label = if dt_label.is_empty() { group_label_from_name(&name) } else { dt_label.clone() };
                    fields.push(FormField {
                        name,
                        label,
                        field_type: FormFieldType::Checkboxes { options },
                    });
                }
                continue;
            }
        }
    }

    // Also pick up fields from the second fieldset (Work Tags, etc.) which uses
    // a different structure with <label>+<input> directly, not always in <dl>
    let fieldset_input_sel = sel("fieldset input[type='text'][name^='work_search']");
    for input in form.select(&fieldset_input_sel) {
        let name = input.value().attr("name").unwrap_or("").to_string();
        if name.is_empty() || !seen_names.insert(name.clone()) { continue; }
        let id = input.value().attr("id").unwrap_or("");
        let label = find_label_for(&form, id);
        fields.push(FormField {
            name,
            label,
            field_type: FormFieldType::Text { placeholder: String::new() },
        });
    }

    Ok(SearchForm { fields })
}

fn find_label_for(form: &ElementRef, id: &str) -> String {
    if id.is_empty() { return String::new(); }
    let label_sel_str = format!("label[for='{}']", id);
    if let Ok(s) = Selector::parse(&label_sel_str) {
        if let Some(label) = form.select(&s).next() {
            let t = text(&label);
            // Strip trailing help link text (often "?" from AO3 help icons)
            let cleaned = t.trim_end_matches('?').trim();
            return cleaned.to_string();
        }
    }
    String::new()
}

fn group_label_from_name(name: &str) -> String {
    // "work_search[archive_warning_ids][]" -> "Archive Warnings"
    // "work_search[category_ids][]" -> "Categories"
    let inner = name
        .trim_start_matches("work_search[")
        .trim_end_matches("][]")
        .trim_end_matches(']');
    match inner {
        "archive_warning_ids" => "Archive Warnings".to_string(),
        "category_ids" => "Categories".to_string(),
        "rating_ids" => "Rating".to_string(),
        _ => {
            inner
                .replace('_', " ")
                .split_whitespace()
                .map(|w| {
                    let mut c = w.chars();
                    match c.next() {
                        None => String::new(),
                        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        }
    }
}

pub fn parse_inbox(html: &str) -> InboxPage {
    let doc = Html::parse_document(html);

    // Extract unread count from heading: "My Inbox (16 comments, 3 unread)"
    let unread_count = doc.select(&sel("h2.heading")).next()
        .map(|h| {
            let t = text(&h);
            if let Some(pos) = t.find("unread") {
                let before = &t[..pos];
                before.rsplit(|c: char| !c.is_ascii_digit()).next()
                    .and_then(|s| s.trim().parse::<u32>().ok())
                    .unwrap_or(0)
            } else { 0 }
        })
        .unwrap_or(0);

    let mut items = Vec::new();
    let item_sel = sel("ol.comment.index li.comment");

    for li in doc.select(&item_sel) {
        let classes = li.value().attr("class").unwrap_or("");
        let is_unread = classes.contains("unread");

        // Comment ID from id="feedback_comment_XXXXXXX"
        let comment_id: u64 = li.value().attr("id").unwrap_or("")
            .trim_start_matches("feedback_comment_")
            .parse()
            .unwrap_or(0);
        if comment_id == 0 { continue; }

        // Author and work reference from h4.heading.byline
        let heading = li.select(&sel("h4.heading.byline")).next();
        let (author, author_url, work_reference, work_url) = if let Some(h) = heading {
            let links: Vec<ElementRef> = h.select(&sel("a")).collect();
            let author_name = links.first().map(|a| text(a)).unwrap_or_default();
            let author_href = links.first().and_then(|a| a.value().attr("href")).map(String::from);
            let work_ref = links.get(1).map(|a| text(a)).unwrap_or_default();
            let work_href = links.get(1).and_then(|a| a.value().attr("href")).map(String::from);
            (author_name, author_href, work_ref, work_href)
        } else {
            (String::new(), None, String::new(), None)
        };

        // Avatar
        let avatar_url = li.select(&sel("div.icon img")).next()
            .and_then(|img| img.value().attr("src"))
            .map(|s| {
                if s.starts_with('/') { format!("{}{s}", crate::client::BASE_URL) }
                else { s.to_string() }
            });

        // Date
        let posted_at = li.select(&sel("span.posted.datetime")).next()
            .map(|d| text(&d))
            .unwrap_or_default();

        // Content
        let content = li.select(&sel("blockquote.userstuff")).next()
            .map(|el| parse_element_children(&el))
            .unwrap_or_default();

        items.push(InboxItem {
            comment_id,
            author,
            author_url,
            avatar_url,
            work_reference,
            work_url,
            posted_at,
            is_unread,
            content,
        });
    }

    let has_next_page = has_next_page(html);

    InboxPage { items, unread_count, has_next_page }
}

pub fn parse_comments(html: &str) -> CommentsPage {
    let doc = Html::parse_document(html);
    let pagination_sel = sel("ol.pagination li");

    // Flat approach: find ALL li.comment elements, parse each, then build tree
    let comment_sel = sel("li.comment");
    let all_lis: Vec<ElementRef> = doc.select(&comment_sel).collect();
    log_debug!("comments", "Found {} li.comment elements in {} bytes", all_lis.len(), html.len());

    let mut flat: Vec<(Comment, Option<u64>)> = Vec::new();
    for li in &all_lis {
        if let Some((c, parent_id)) = parse_single_comment(li) {
            flat.push((c, parent_id));
        }
    }

    log_debug!("comments", "Parsed {} comments, building tree", flat.len());

    let comments = build_comment_tree(flat);

    // If document parsing found nothing, try fragment
    let comments = if comments.is_empty() {
        let frag = Html::parse_fragment(html);
        let frag_lis: Vec<ElementRef> = frag.select(&comment_sel).collect();
        let mut flat: Vec<(Comment, Option<u64>)> = Vec::new();
        for li in &frag_lis {
            if let Some((c, parent_id)) = parse_single_comment(li) {
                flat.push((c, parent_id));
            }
        }
        build_comment_tree(flat)
    } else {
        comments
    };

    let (current_page, total_pages) = parse_comment_pagination(&doc, &pagination_sel);

    CommentsPage { comments, current_page, total_pages }
}

fn build_comment_tree(flat: Vec<(Comment, Option<u64>)>) -> Vec<Comment> {
    use std::collections::HashMap;

    let ids: Vec<u64> = flat.iter().map(|(c, _)| c.id).collect();
    let mut comments_map: HashMap<u64, Comment> = HashMap::new();
    let mut parent_map: Vec<(u64, Option<u64>)> = Vec::new();

    for (c, parent_id) in flat {
        parent_map.push((c.id, parent_id));
        comments_map.insert(c.id, c);
    }

    // Process in reverse so children are ready before parents
    let mut children_map: HashMap<u64, Vec<Comment>> = HashMap::new();
    let mut top_level = Vec::new();

    for &(id, parent_id) in parent_map.iter().rev() {
        let mut comment = comments_map.remove(&id).unwrap();
        if let Some(children) = children_map.remove(&id) {
            comment.replies = children;
            comment.replies.reverse();
        }
        match parent_id {
            Some(pid) if ids.contains(&pid) => {
                children_map.entry(pid).or_default().push(comment);
            }
            _ => top_level.push(comment),
        }
    }

    top_level.reverse();
    top_level
}


fn parse_single_comment(li: &ElementRef) -> Option<(Comment, Option<u64>)> {
    let id_str = li.value().attr("id").unwrap_or("");
    let id: u64 = id_str.trim_start_matches("comment_").parse().unwrap_or(0);
    if id == 0 { return None; }

    let div_sel = sel("div.comment");
    let div = li.select(&div_sel).next()
        .or_else(|| Some(*li))?;

    // Avatar
    let avatar_url = div.select(&sel("img.icon")).next()
        .or_else(|| li.select(&sel("img.icon")).next())
        .or_else(|| div.select(&sel("img[src*='avatar']")).next())
        .and_then(|img| img.value().attr("src"))
        .map(|s| {
            if s.starts_with("//") { format!("https:{s}") }
            else if s.starts_with('/') { format!("{}{s}", crate::client::BASE_URL) }
            else { s.to_string() }
        });

    let heading = div.select(&sel("h4.byline")).next()
        .or_else(|| div.select(&sel("h4.heading")).next());

    let (username, profile_url) = if let Some(h) = heading {
        let link_sel = sel("a");
        if let Some(a) = h.select(&link_sel).next() {
            let name = text(&a);
            let href = a.value().attr("href").unwrap_or("").to_string();
            (name, if href.is_empty() { None } else { Some(href) })
        } else {
            (text(&h), None)
        }
    } else {
        ("Anonymous".to_string(), None)
    };

    // Stable user ID: for registered users use the username from their profile path,
    // for guests use a hash of their display name
    let user_id = if let Some(ref url) = profile_url {
        url.rsplit('/').next().unwrap_or(&username).to_string()
    } else {
        format!("guest:{:x}", simple_hash(&username))
    };

    let author = AO3User {
        id: user_id,
        username,
        profile_url,
        avatar_url,
    };

    let posted_at = div.select(&sel("span.posted span.date")).next()
        .or_else(|| div.select(&sel("span.date")).next())
        .or_else(|| div.select(&sel("span.posted")).next())
        .map(|d| text(&d))
        .unwrap_or_default();

    let body_sel = sel("blockquote.userstuff");
    let content = if let Some(body) = div.select(&body_sel).next() {
        parse_element_children(&body)
    } else {
        Vec::new()
    };

    // Extract parent comment ID from this comment's own actions ul (direct child of div,
    // not from nested reply comments)
    let parent_comment_id = {
        let mut found: Option<u64> = None;
        for child in div.children() {
            if let Some(el) = child.value().as_element() {
                if el.name() == "ul" && el.attr("class").unwrap_or("").contains("actions") {
                    let ul_ref = ElementRef::wrap(child).unwrap();
                    for a in ul_ref.select(&sel("a")) {
                        let t = text(&a).to_lowercase();
                        if t.contains("parent comment") || t.contains("parent thread") {
                            if let Some(href) = a.value().attr("href") {
                                let path = href.split('#').next().unwrap_or(href);
                                if let Some(id) = path.rsplit('/').next().and_then(|s| s.parse::<u64>().ok()) {
                                    found = Some(id);
                                    break;
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }
        found
    };

    Some((Comment { id, author, posted_at, content, replies: Vec::new() }, parent_comment_id))
}

fn parse_comment_pagination(doc: &Html, pagination_sel: &Selector) -> (u32, u32) {
    let mut current: u32 = 1;
    let mut max_page: u32 = 1;

    for li in doc.select(pagination_sel) {
        let class = li.value().attr("class").unwrap_or("");
        if class.contains("previous") || class.contains("next") {
            continue;
        }
        if class.contains("current") {
            let num: u32 = text(&li).parse().unwrap_or(1);
            current = num;
            if num > max_page { max_page = num; }
        } else {
            let num: u32 = text(&li).parse().unwrap_or(0);
            if num > max_page { max_page = num; }
        }
    }

    (current, max_page)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

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
    use super::*;

    #[test]
    fn test_parse_subscriptions_page_authors() {
        let html = r#"
        <html><body>
        <dl class="subscription index group">
            <dt><a href="/users/coolwriter">coolwriter</a></dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
            <dt><a href="/users/another_author">another_author</a></dt>
            <dd><form><input type="submit" value="Unsubscribe" /></form></dd>
        </dl>
        </body></html>
        "#;
        let subs = parse_subscriptions_page(html).unwrap();
        assert_eq!(subs.len(), 2);
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

    #[test]
    fn test_parse_series_page() {
        // Use a minimal blurb structure that parse_work_listings would handle
        let html = r#"
        <html><body>
        <ul class="work index group">
            <li id="work_100" class="work blurb group">
                <div class="header module">
                    <h4 class="heading">
                        <a href="/works/100">First Work</a>
                    </h4>
                </div>
                <dl class="stats">
                    <dd class="words">5,000</dd>
                    <dd class="chapters">3/10</dd>
                </dl>
            </li>
            <li id="work_200" class="work blurb group">
                <div class="header module">
                    <h4 class="heading">
                        <a href="/works/200">Second Work</a>
                    </h4>
                </div>
                <dl class="stats">
                    <dd class="words">12,000</dd>
                    <dd class="chapters">7/?</dd>
                </dl>
            </li>
        </ul>
        </body></html>
        "#;
        let works = parse_series_page(html).unwrap();
        assert_eq!(works.len(), 2);
        assert_eq!(works[0].0, 100); // work_id
        assert_eq!(works[0].1, "First Work"); // title
        assert_eq!(works[0].2, 3); // chapter_count
        assert_eq!(works[0].3, 5000); // word_count
        assert_eq!(works[1].0, 200);
        assert_eq!(works[1].1, "Second Work");
        assert_eq!(works[1].2, 7);
        assert_eq!(works[1].3, 12000);
    }
}

#[cfg(test)]
mod form_tests {
    use super::*;

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
    use super::*;

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
    use super::*;
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
        assert_eq!(guest.author.username, "A Guest");
        assert!(guest.author.profile_url.is_none());
        assert!(guest.author.id.starts_with("guest:"));
        assert!(guest.replies.is_empty());

        let threaded = &page.comments[2];
        assert_eq!(threaded.id, 12348);
        assert_eq!(threaded.replies.len(), 2, "Third comment should have 2 replies");
    }
}
