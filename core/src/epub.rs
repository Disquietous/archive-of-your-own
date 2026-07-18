//! EPUB3 export: the work's ContentBlock trees rendered to XHTML inside a
//! zip container. Entries are STORED (uncompressed) — EPUB permits it, and
//! it keeps the writer free of compression dependencies.

use crate::error::AppError;
use crate::models::{Chapter, ContentBlock, InlineContent, WorkSummary};

/// Write `work` (with its downloaded chapters) as an EPUB3 file at `dest`.
pub fn export_epub(work: &WorkSummary, chapters: &[Chapter], dest: &str) -> Result<(), AppError> {
    if chapters.is_empty() {
        return Err(AppError::StorageError("no chapters to export".to_string()));
    }
    let mut zip = StoredZipWriter::new();
    // The mimetype entry must be first and uncompressed.
    zip.add("mimetype", b"application/epub+zip");
    zip.add("META-INF/container.xml", CONTAINER_XML.as_bytes());
    zip.add("OEBPS/style.css", STYLE_CSS.as_bytes());
    zip.add("OEBPS/content.opf", package_opf(work, chapters).as_bytes());
    zip.add("OEBPS/nav.xhtml", nav_xhtml(work, chapters).as_bytes());
    zip.add("OEBPS/titlepage.xhtml", title_page_xhtml(work).as_bytes());
    for (index, chapter) in chapters.iter().enumerate() {
        zip.add(
            &format!("OEBPS/chapter{}.xhtml", index + 1),
            chapter_xhtml(chapter, index).as_bytes(),
        );
    }
    std::fs::write(dest, zip.finish())
        .map_err(|e| AppError::StorageError(format!("writing EPUB: {e}")))
}

// ---------------------------------------------------------------------------
// Package documents
// ---------------------------------------------------------------------------

const CONTAINER_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#;

const STYLE_CSS: &str = r#"body { font-family: serif; line-height: 1.6; margin: 1em; }
h1, h2, h3 { font-weight: 600; }
blockquote { margin-left: 1.2em; padding-left: 0.8em; border-left: 3px solid #999; }
hr { border: none; text-align: center; margin: 1.4em 0; }
hr:after { content: "⁂"; }
.notes { font-size: 0.9em; color: #555; border: 1px solid #ccc; padding: 0.6em 0.9em; margin: 1em 0; }
.tags { font-size: 0.9em; color: #555; }
"#;

/// dc:language wants an RFC 5646 tag; AO3 gives a display name.
fn language_code(display: &str) -> &'static str {
    let lower = display.to_lowercase();
    match () {
        _ if lower.contains("english") || lower.is_empty() => "en",
        _ if lower.contains("deutsch") => "de",
        _ if lower.contains("español") || lower.contains("espanol") => "es",
        _ if lower.contains("français") || lower.contains("francais") => "fr",
        _ if lower.contains("italiano") => "it",
        _ if lower.contains("русский") => "ru",
        _ if lower.contains("中文") => "zh",
        _ if lower.contains("日本語") => "ja",
        _ => "en",
    }
}

fn package_opf(work: &WorkSummary, chapters: &[Chapter]) -> String {
    let mut manifest = String::new();
    let mut spine = String::new();
    manifest.push_str("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n");
    manifest.push_str("    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n");
    manifest.push_str("    <item id=\"titlepage\" href=\"titlepage.xhtml\" media-type=\"application/xhtml+xml\"/>\n");
    spine.push_str("    <itemref idref=\"titlepage\"/>\n");
    for index in 1..=chapters.len() {
        manifest.push_str(&format!(
            "    <item id=\"ch{index}\" href=\"chapter{index}.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        ));
        spine.push_str(&format!("    <itemref idref=\"ch{index}\"/>\n"));
    }

    let creators: String = work.authors.iter().enumerate()
        .map(|(i, a)| format!("    <dc:creator id=\"creator{i}\">{}</dc:creator>\n", xml_escape(a)))
        .collect();
    let modified = if work.date_updated.len() == 10 {
        format!("{}T00:00:00Z", work.date_updated)
    } else {
        "2000-01-01T00:00:00Z".to_string()
    };

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:ao3:work:{id}</dc:identifier>
    <dc:title>{title}</dc:title>
{creators}    <dc:language>{lang}</dc:language>
    <dc:source>https://archiveofourown.org/works/{id}</dc:source>
    <meta property="dcterms:modified">{modified}</meta>
  </metadata>
  <manifest>
{manifest}  </manifest>
  <spine>
{spine}  </spine>
</package>
"#,
        id = work.id,
        title = xml_escape(&work.title),
        creators = creators,
        lang = language_code(&work.language),
        modified = modified,
        manifest = manifest,
        spine = spine,
    )
}

fn chapter_title(chapter: &Chapter, index: usize) -> String {
    match &chapter.title {
        Some(t) if !t.is_empty() => t.clone(),
        _ => format!("Chapter {}", index + 1),
    }
}

fn nav_xhtml(work: &WorkSummary, chapters: &[Chapter]) -> String {
    let mut items = String::new();
    items.push_str("      <li><a href=\"titlepage.xhtml\">About This Work</a></li>\n");
    for (index, chapter) in chapters.iter().enumerate() {
        items.push_str(&format!(
            "      <li><a href=\"chapter{}.xhtml\">{}</a></li>\n",
            index + 1,
            xml_escape(&chapter_title(chapter, index))
        ));
    }
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>{title}</title><link rel="stylesheet" href="style.css"/></head>
<body>
  <nav epub:type="toc">
    <h1>Contents</h1>
    <ol>
{items}    </ol>
  </nav>
</body>
</html>
"#,
        title = xml_escape(&work.title),
        items = items,
    )
}

fn title_page_xhtml(work: &WorkSummary) -> String {
    let authors = xml_escape(&work.authors.join(", "));
    let fandoms = xml_escape(&work.fandoms.join(", "));
    let tags = xml_escape(&work.tags.join(" · "));
    let summary = if work.summary.is_empty() {
        String::new()
    } else {
        format!("  <blockquote><p>{}</p></blockquote>\n", xml_escape(&work.summary))
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>{title}</title><link rel="stylesheet" href="style.css"/></head>
<body>
  <h1>{title}</h1>
  <p>by {authors}</p>
  <p class="tags">{fandoms}</p>
{summary}  <p class="tags">{tags}</p>
  <p class="tags">Exported from the Archive of Our Own: https://archiveofourown.org/works/{id}</p>
</body>
</html>
"#,
        title = xml_escape(&work.title),
        authors = authors,
        fandoms = fandoms,
        summary = summary,
        tags = tags,
        id = work.id,
    )
}

fn chapter_xhtml(chapter: &Chapter, index: usize) -> String {
    let title = chapter_title(chapter, index);
    let mut body = String::new();
    if let Some(notes) = &chapter.notes_before {
        if !notes.is_empty() {
            body.push_str(&format!("  <div class=\"notes\"><p>{}</p></div>\n", xml_escape(notes)));
        }
    }
    for block in &chapter.content {
        render_block(block, &mut body);
    }
    if let Some(notes) = &chapter.notes_after {
        if !notes.is_empty() {
            body.push_str(&format!("  <div class=\"notes\"><p>{}</p></div>\n", xml_escape(notes)));
        }
    }
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>{title}</title><link rel="stylesheet" href="style.css"/></head>
<body>
  <h2>{title}</h2>
{body}</body>
</html>
"#,
        title = xml_escape(&title),
        body = body,
    )
}

// ---------------------------------------------------------------------------
// ContentBlock → XHTML
// ---------------------------------------------------------------------------

fn render_block(block: &ContentBlock, out: &mut String) {
    match block {
        ContentBlock::Paragraph { text } => {
            out.push_str("  <p>");
            for inline in text {
                render_inline(inline, out);
            }
            out.push_str("</p>\n");
        }
        ContentBlock::Heading { level, text } => {
            let level = (*level).clamp(1, 6);
            out.push_str(&format!("  <h{level}>{}</h{level}>\n", xml_escape(text)));
        }
        ContentBlock::Blockquote { blocks } => {
            out.push_str("  <blockquote>\n");
            for inner in blocks {
                render_block(inner, out);
            }
            out.push_str("  </blockquote>\n");
        }
        ContentBlock::HorizontalRule => out.push_str("  <hr/>\n"),
        ContentBlock::List { ordered, items } => {
            let tag = if *ordered { "ol" } else { "ul" };
            out.push_str(&format!("  <{tag}>\n"));
            for item in items {
                out.push_str("    <li>");
                for inner in item {
                    render_block(inner, out);
                }
                out.push_str("</li>\n");
            }
            out.push_str(&format!("  </{tag}>\n"));
        }
        ContentBlock::PreFormatted { text } => {
            out.push_str(&format!("  <pre>{}</pre>\n", xml_escape(text)));
        }
    }
}

fn render_inline(inline: &InlineContent, out: &mut String) {
    match inline {
        InlineContent::Text { value } => out.push_str(&xml_escape(value)),
        InlineContent::Bold { content } => wrap_inline("strong", content, out),
        InlineContent::Italic { content } => wrap_inline("em", content, out),
        InlineContent::Strikethrough { content } => wrap_inline("del", content, out),
        InlineContent::Superscript { content } => wrap_inline("sup", content, out),
        InlineContent::Link { href, content } => {
            out.push_str(&format!("<a href=\"{}\">", xml_escape(href)));
            for inner in content {
                render_inline(inner, out);
            }
            out.push_str("</a>");
        }
        InlineContent::LineBreak => out.push_str("<br/>"),
    }
}

fn wrap_inline(tag: &str, content: &[InlineContent], out: &mut String) {
    out.push_str(&format!("<{tag}>"));
    for inner in content {
        render_inline(inner, out);
    }
    out.push_str(&format!("</{tag}>"));
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

// ---------------------------------------------------------------------------
// Minimal STORED-only zip writer
// ---------------------------------------------------------------------------

struct StoredZipWriter {
    data: Vec<u8>,
    central: Vec<u8>,
    entries: u16,
}

impl StoredZipWriter {
    fn new() -> Self {
        Self { data: Vec::new(), central: Vec::new(), entries: 0 }
    }

    fn add(&mut self, name: &str, content: &[u8]) {
        let offset = self.data.len() as u32;
        let crc = crc32(content);
        let size = content.len() as u32;
        let name_bytes = name.as_bytes();

        // Local file header
        self.data.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        self.data.extend_from_slice(&20u16.to_le_bytes()); // version needed
        self.data.extend_from_slice(&0u16.to_le_bytes()); // flags
        self.data.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        self.data.extend_from_slice(&0u16.to_le_bytes()); // mod time
        self.data.extend_from_slice(&0x21u16.to_le_bytes()); // mod date (1980-01-01)
        self.data.extend_from_slice(&crc.to_le_bytes());
        self.data.extend_from_slice(&size.to_le_bytes()); // compressed
        self.data.extend_from_slice(&size.to_le_bytes()); // uncompressed
        self.data.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        self.data.extend_from_slice(&0u16.to_le_bytes()); // extra len
        self.data.extend_from_slice(name_bytes);
        self.data.extend_from_slice(content);

        // Central directory record
        self.central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        self.central.extend_from_slice(&20u16.to_le_bytes()); // version made by
        self.central.extend_from_slice(&20u16.to_le_bytes()); // version needed
        self.central.extend_from_slice(&0u16.to_le_bytes()); // flags
        self.central.extend_from_slice(&0u16.to_le_bytes()); // method
        self.central.extend_from_slice(&0u16.to_le_bytes()); // mod time
        self.central.extend_from_slice(&0x21u16.to_le_bytes()); // mod date
        self.central.extend_from_slice(&crc.to_le_bytes());
        self.central.extend_from_slice(&size.to_le_bytes());
        self.central.extend_from_slice(&size.to_le_bytes());
        self.central.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        self.central.extend_from_slice(&0u16.to_le_bytes()); // extra len
        self.central.extend_from_slice(&0u16.to_le_bytes()); // comment len
        self.central.extend_from_slice(&0u16.to_le_bytes()); // disk number
        self.central.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        self.central.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        self.central.extend_from_slice(&offset.to_le_bytes());
        self.central.extend_from_slice(name_bytes);

        self.entries += 1;
    }

    fn finish(mut self) -> Vec<u8> {
        let central_offset = self.data.len() as u32;
        let central_size = self.central.len() as u32;
        self.data.extend_from_slice(&self.central);
        // End of central directory
        self.data.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        self.data.extend_from_slice(&0u16.to_le_bytes()); // disk
        self.data.extend_from_slice(&0u16.to_le_bytes()); // cd disk
        self.data.extend_from_slice(&self.entries.to_le_bytes());
        self.data.extend_from_slice(&self.entries.to_le_bytes());
        self.data.extend_from_slice(&central_size.to_le_bytes());
        self.data.extend_from_slice(&central_offset.to_le_bytes());
        self.data.extend_from_slice(&0u16.to_le_bytes()); // comment len
        self.data
    }
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Rating;

    fn sample_work() -> WorkSummary {
        WorkSummary {
            id: 12345,
            title: "A Test & Trial".to_string(),
            authors: vec!["someauthor".to_string()],
            fandoms: vec!["Testing".to_string()],
            rating: Rating::General,
            warnings: vec![],
            categories: vec![],
            relationships: vec![],
            characters: vec![],
            tags: vec!["Fluff".to_string()],
            summary: "A summary with <brackets>.".to_string(),
            word_count: 100,
            chapter_count: 1,
            total_chapters: Some(1),
            kudos: 1,
            hits: 2,
            bookmarks: 0,
            comments: 0,
            date_published: "2024-01-01".to_string(),
            date_updated: "2024-01-02".to_string(),
            language: "English".to_string(),
            complete: true,
        }
    }

    fn sample_chapter() -> Chapter {
        Chapter {
            id: Some(1),
            title: Some("One".to_string()),
            number: 1,
            content: vec![
                ContentBlock::Paragraph {
                    text: vec![
                        InlineContent::Text { value: "Hello ".to_string() },
                        InlineContent::Bold {
                            content: vec![InlineContent::Text { value: "world & co".to_string() }],
                        },
                    ],
                },
                ContentBlock::HorizontalRule,
            ],
            notes_before: Some("A note.".to_string()),
            notes_after: None,
        }
    }

    #[test]
    fn test_export_epub_structure() {
        let dir = std::env::temp_dir().join("ao3_epub_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.epub");
        let path_str = path.to_str().unwrap();

        export_epub(&sample_work(), &[sample_chapter()], path_str).unwrap();
        let bytes = std::fs::read(&path).unwrap();

        // Zip magic, and the mimetype entry stored first (offset 30 = name).
        assert_eq!(&bytes[0..4], b"PK\x03\x04");
        assert_eq!(&bytes[30..38], b"mimetype");
        assert_eq!(&bytes[38..58], b"application/epub+zip");

        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("META-INF/container.xml"));
        assert!(text.contains("OEBPS/content.opf"));
        assert!(text.contains("OEBPS/chapter1.xhtml"));
        assert!(text.contains("A Test &amp; Trial"));
        assert!(text.contains("<strong>world &amp; co</strong>"));
        // End-of-central-directory record present.
        assert!(bytes.windows(4).any(|w| w == [0x50, 0x4b, 0x05, 0x06]));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_export_epub_requires_chapters() {
        assert!(export_epub(&sample_work(), &[], "/tmp/never.epub").is_err());
    }
}
