use scraper::{Html, Selector, ElementRef};

use crate::error::AppError;
use crate::models::*;

use super::{sel, text, parse_number, normalize_ao3_date};
use super::listings::parse_chapters;

fn is_landmark_heading(block: &ContentBlock) -> bool {
    if let ContentBlock::Heading { text, .. } = block {
        let lower = text.to_lowercase();
        lower == "chapter text" || lower == "work text" || lower == "summary" || lower == "notes"
    } else {
        false
    }
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
    let date_published = normalize_ao3_date(&extract_work_page_stat(&doc, "dd.published"));
    let mut date_updated = normalize_ao3_date(&extract_work_page_stat(&doc, "dd.status"));
    if date_updated.is_empty() {
        date_updated = date_published.clone();
    }
    let complete = total_chapters.map_or(false, |t| chapter_count >= t);
    let series = extract_work_page_series(&doc);

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
        date_published,
        date_updated,
        language,
        complete,
        series,
        fetched_at: String::new(),
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

pub(super) fn extract_work_page_series(doc: &Html) -> Vec<SeriesMembership> {
    let span_sel = sel("dd.series span.series");
    let pos_sel = sel("span.position");
    let series_link_sel = sel("a[href^='/series/']");
    let prev_sel = sel("a.previous");
    let next_sel = sel("a.next");

    let mut memberships = Vec::new();
    for span in doc.select(&span_sel) {
        let Some(position) = span.select(&pos_sel).next() else {
            continue;
        };
        let Some(link) = position.select(&series_link_sel).next() else {
            continue;
        };
        let Some(series_id) = link
            .value()
            .attr("href")
            .and_then(|href| href.split('/').find_map(|seg| seg.parse::<u64>().ok()))
        else {
            continue;
        };
        let name = text(&link);

        // Position number: first integer in the text nodes before the series
        // link. The wording around it is localizable and series names may
        // start with digits, so neither "Part" nor the full flattened text
        // is safe to match against.
        let mut before_link = String::new();
        for child in position.children() {
            if child.id() == link.id() {
                break;
            }
            if let Some(t) = child.value().as_text() {
                before_link.push_str(t);
            }
        }
        let part = first_number_in(&before_link) as u32;

        let prev_work_id = span.select(&prev_sel).next().and_then(work_id_from_href);
        let next_work_id = span.select(&next_sel).next().and_then(work_id_from_href);

        memberships.push(SeriesMembership {
            series_id,
            name,
            part,
            prev_work_id,
            next_work_id,
        });
    }
    memberships
}

fn work_id_from_href(el: ElementRef) -> Option<u64> {
    el.value()
        .attr("href")?
        .split('/')
        .find_map(|seg| seg.parse::<u64>().ok())
}

/// First integer in `s`, honoring comma grouping ("1,002"); 0 if none.
fn first_number_in(s: &str) -> u64 {
    let mut num = String::new();
    for ch in s.chars() {
        if ch.is_ascii_digit() || (ch == ',' && !num.is_empty()) {
            num.push(ch);
        } else if !num.is_empty() {
            break;
        }
    }
    parse_number(num.trim_end_matches(','))
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

    const CHAPTER_PARSE_CAP: usize = 200;
    for i in 1..=CHAPTER_PARSE_CAP {
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

    if chapters.len() == CHAPTER_PARSE_CAP {
        // Surfaced, not silent: a 200+-chapter work is truncated here.
        log_error!("parser",
            "Chapter parse hit the {CHAPTER_PARSE_CAP}-chapter cap — later chapters were not parsed");
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
        // Never mine the site-wide announcement banner — it precedes the
        // work content in document order, so it would win this fallback.
        // Fetches strip it (strip_admin_banner); this guards other paths.
        if el.ancestors().filter_map(ElementRef::wrap)
            .any(|a| a.value().id() == Some("admin-banner")) { continue; }
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
                    // AO3 usually embeds images inside a paragraph of their
                    // own; inline parsing ignores them, so lift any imgs out
                    // as block-level images after the paragraph's text.
                    for img in child_ref.select(&sel("img")) {
                        if let Some(block) = image_block(&img) {
                            blocks.push(block);
                        }
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
                "img" => {
                    if let Some(block) = image_block(&child_ref) {
                        blocks.push(block);
                    }
                }
                _ => {}
            }
        }
    }

    blocks
}

/// An `<img>` as a block, with its URL resolved to an absolute https form.
/// Returns None for sources the app won't fetch (data: URIs, junk).
fn image_block(img: &ElementRef) -> Option<ContentBlock> {
    let raw = img.value().attr("src")?.trim();
    let src = if raw.starts_with("https://") || raw.starts_with("http://") {
        raw.to_string()
    } else if let Some(rest) = raw.strip_prefix("//") {
        format!("https://{rest}")
    } else if raw.starts_with('/') {
        format!("{}{raw}", crate::client::BASE_URL)
    } else {
        return None;
    };
    let alt = img.value().attr("alt").unwrap_or("").trim().to_string();
    Some(ContentBlock::Image { src, alt })
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

/// Collapse every run of whitespace (spaces, newlines, tabs) to one space,
/// preserving a leading/trailing space when the node had any — that space
/// is significant between inline elements ("word <b>bold</b>").
fn collapse_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_whitespace = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            if !in_whitespace {
                out.push(' ');
            }
            in_whitespace = true;
        } else {
            out.push(ch);
            in_whitespace = false;
        }
    }
    out
}

pub fn parse_inline_content(el: &ElementRef) -> Vec<InlineContent> {
    let mut inlines = Vec::new();

    for child in el.children() {
        if child.value().is_text() {
            let t = child.value().as_text().unwrap();
            // HTML whitespace semantics: newlines/tabs/space runs in source
            // markup collapse to a single space when rendered. Passing them
            // through verbatim made the UI draw authors' source-file line
            // wraps as real line breaks mid-paragraph.
            let s = collapse_whitespace(t);
            if !s.is_empty() {
                inlines.push(InlineContent::Text { value: s });
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

/// Usernames shown in a work page's kudos list ("X, Y, and Z left kudos on
/// this work"). Truncated by AO3 past ~150 names ("and N more users"), so
/// absence proves nothing — presence proves the user left kudos.
pub fn parse_kudos_usernames(html: &str) -> Vec<String> {
    let doc = Html::parse_document(html);
    let link_sel = sel("#kudos a[href^='/users/']");
    doc.select(&link_sel).map(|el| text(&el)).collect()
}
