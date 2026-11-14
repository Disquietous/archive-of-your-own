//! EPUB → a library work (Area 11.1): chapters from the spine, the record
//! from the package document, the external id from the declared
//! identifier (a hash of the file when it declares none).
//!
//! The package documents are XML and the chapters XHTML; both are read
//! with the HTML parser the rest of the core uses, after self-closing
//! tags are spelled out (HTML has no `<item/>`, and would nest every
//! following element inside it). Chapter text goes through the shared
//! `html_to_blocks`, so a local book renders exactly like a fetched one.
//!
//! Not carried over in this pass: images (their bytes live in the file,
//! which is not kept) and links inside the book (there is no page to
//! open) — images are dropped and such links become plain text.

use std::collections::{HashMap, HashSet};

use scraper::{ElementRef, Html};
use sha2::{Digest, Sha256};

use crate::error::AppError;
use crate::models::{Chapter, ContentBlock, InlineContent, Rating, WorkSummary};
use crate::source::FetchedWork;

use super::zip::ZipArchive;
use super::SOURCE_ID;

fn bad(what: &str) -> AppError {
    AppError::ParseError(format!("not a readable EPUB: {what}"))
}

/// Read an EPUB file's bytes into a work and its chapters. `file_name`
/// names the book when the package has no title.
pub fn read_epub(bytes: &[u8], file_name: &str) -> Result<FetchedWork, AppError> {
    let zip = ZipArchive::open(bytes)?;

    let container = zip.read_text("META-INF/container.xml")?.ok_or_else(|| bad("no META-INF/container.xml"))?;
    let container = parse_xml(&container);
    let opf_path = elements(&container, "rootfile").into_iter()
        .find_map(|e| e.value().attr("full-path").map(str::to_string))
        .ok_or_else(|| bad("the container names no package document"))?;
    let opf_text = zip.read_text(&opf_path)?.ok_or_else(|| bad("the package document is missing"))?;
    let opf = parse_xml(&opf_text);

    // Manifest: id → (path in the archive, media type, properties).
    let mut manifest: HashMap<String, (String, String, String)> = HashMap::new();
    for item in elements(&opf, "item") {
        let v = item.value();
        if let (Some(id), Some(href)) = (v.attr("id"), v.attr("href")) {
            manifest.insert(id.to_string(), (
                resolve_path(&opf_path, href),
                v.attr("media-type").unwrap_or("").to_ascii_lowercase(),
                v.attr("properties").unwrap_or("").to_string(),
            ));
        }
    }

    let titles = toc_titles(&zip, &opf, &manifest)?;
    let protected = encrypted_paths(&zip)?;

    let mut chapters: Vec<Chapter> = Vec::new();
    let mut words: u64 = 0;
    for itemref in elements(&opf, "itemref") {
        let v = itemref.value();
        if v.attr("linear").is_some_and(|l| l.eq_ignore_ascii_case("no")) {
            continue;
        }
        let Some((path, media, properties)) = v.attr("idref").and_then(|id| manifest.get(id)) else { continue };
        let is_document = media.contains("html") || path.ends_with(".xhtml") || path.ends_with(".html") || path.ends_with(".htm");
        if !is_document || properties.split_whitespace().any(|p| p == "nav") {
            continue;
        }
        if protected.contains(path) {
            return Err(bad("the book is copy-protected (DRM), so its text can't be read"));
        }
        let Some(text) = zip.read_text(path)? else { continue };
        let Some((mut title, mut blocks, count)) = read_document(&text) else { continue };
        if let Some(listed) = titles.get(path) {
            title = Some(listed.clone());
        }
        // The table of contents (or the page's own heading) names the
        // chapter; the same heading repeated as the first block is noise.
        if let (Some(t), Some(ContentBlock::Heading { text: h, .. })) = (&title, blocks.first()) {
            if h.trim().eq_ignore_ascii_case(t.trim()) {
                blocks.remove(0);
            }
        }
        if blocks.is_empty() {
            continue;
        }
        words += count;
        chapters.push(Chapter {
            id: None,
            title,
            number: chapters.len() as u32 + 1,
            content: blocks,
            notes_before: None,
            notes_after: None,
        });
    }
    if chapters.is_empty() {
        return Err(bad("the book has no readable text"));
    }

    let text_of = |name: &str| elements(&opf, name).into_iter()
        .map(|e| clean(&e.text().collect::<String>()))
        .find(|t| !t.is_empty());
    let all_of = |name: &str| -> Vec<String> {
        let mut seen = HashSet::new();
        elements(&opf, name).into_iter()
            .map(|e| clean(&e.text().collect::<String>()))
            .filter(|t| !t.is_empty() && seen.insert(t.to_lowercase()))
            .collect()
    };

    // The declared unique identifier; any identifier; else the file's hash
    // — the same file always maps to the same library row.
    let declared = elements(&opf, "package").first()
        .and_then(|p| p.value().attr("unique-identifier").map(str::to_string));
    let identifiers = elements(&opf, "dc:identifier");
    let external_id = identifiers.iter()
        .find(|e| declared.is_some() && e.value().attr("id") == declared.as_deref())
        .or(identifiers.first())
        .map(|e| clean(&e.text().collect::<String>()))
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| {
            let digest = Sha256::digest(bytes);
            let hex: String = digest.iter().take(16).map(|b| format!("{b:02x}")).collect();
            format!("sha256:{hex}")
        });

    let title = text_of("dc:title").unwrap_or_else(|| {
        let stem = file_name.rsplit('/').next().unwrap_or(file_name);
        let stem = stem.strip_suffix(".epub").or_else(|| stem.strip_suffix(".EPUB")).unwrap_or(stem);
        if stem.trim().is_empty() { "Untitled".to_string() } else { stem.trim().to_string() }
    });
    let published = text_of("dc:date").and_then(|d| iso_day(&d)).unwrap_or_default();
    // <meta property="dcterms:modified">…</meta>: `meta` is a void element
    // to the HTML parser, so its text arrives as the following sibling.
    let modified = elements(&opf, "meta").into_iter()
        .filter(|m| m.value().attr("property") == Some("dcterms:modified"))
        .find_map(|m| m.next_sibling().and_then(|n| n.value().as_text().map(|t| t.to_string())))
        .and_then(|d| iso_day(&d))
        .unwrap_or_else(|| published.clone());
    let description = text_of("dc:description")
        .map(|d| clean(&Html::parse_fragment(&d).root_element().text().collect::<String>()))
        .unwrap_or_default();
    let count = chapters.len() as u32;

    let summary = WorkSummary {
        id: 0,
        source: SOURCE_ID.to_string(),
        external_id,
        url: String::new(),
        title,
        authors: all_of("dc:creator"),
        author_ids: Vec::new(),
        fandoms: Vec::new(),
        rating: Rating::NotRated,
        warnings: Vec::new(),
        categories: Vec::new(),
        relationships: Vec::new(),
        characters: Vec::new(),
        tags: all_of("dc:subject"),
        summary: description,
        word_count: Some(words),
        chapter_count: count,
        total_chapters: Some(count),
        kudos: None,
        hits: None,
        bookmarks: None,
        comments: None,
        date_published: published,
        date_updated: modified,
        language: text_of("dc:language").map(|l| language_name(&l)).unwrap_or_default(),
        complete: true,
        status: String::new(),
        series: Vec::new(),
        fetched_at: crate::timefmt::now_utc_datetime(),
    };
    Ok(FetchedWork { summary, chapters, stats: Vec::new(), reacted_by: Vec::new(), authors: Vec::new() })
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

/// One spine document: its own title (first heading, if any), its text as
/// blocks, and a word count. None when it holds no text (a cover page).
fn read_document(xhtml: &str) -> Option<(Option<String>, Vec<ContentBlock>, u64)> {
    let doc = parse_xml(xhtml);
    let body = elements(&doc, "body").into_iter().next()?;
    let blocks = clean_blocks(crate::parser::html_to_blocks(&body.inner_html(), ""));
    if blocks.is_empty() {
        return None;
    }
    let title = ["h1", "h2", "h3"].iter()
        .find_map(|tag| elements(&doc, tag).into_iter().next())
        .map(|h| clean(&h.text().collect::<String>()))
        .filter(|t| !t.is_empty());
    let words = body.text().flat_map(str::split_whitespace).count() as u64;
    Some((title, blocks, words))
}

/// Chapter titles by document path, from the EPUB 3 navigation document
/// or the EPUB 2 NCX. The first entry that points into a document names
/// it.
fn toc_titles(zip: &ZipArchive, opf: &Html, manifest: &HashMap<String, (String, String, String)>)
    -> Result<HashMap<String, String>, AppError>
{
    let mut titles = HashMap::new();
    let nav = manifest.values().find(|(_, _, props)| props.split_whitespace().any(|p| p == "nav"));
    if let Some((path, _, _)) = nav {
        if let Some(text) = zip.read_text(path)? {
            let doc = parse_xml(&text);
            let navs = elements(&doc, "nav");
            let toc = navs.iter().find(|n| n.value().attr("epub:type") == Some("toc")).or(navs.first());
            if let Some(toc) = toc {
                for a in toc.descendants().filter_map(ElementRef::wrap).filter(|e| e.value().name() == "a") {
                    let label = clean(&a.text().collect::<String>());
                    if let (Some(href), false) = (a.value().attr("href"), label.is_empty()) {
                        titles.entry(resolve_path(path, href)).or_insert(label);
                    }
                }
            }
        }
    }
    if titles.is_empty() {
        let ncx = elements(opf, "spine").first()
            .and_then(|s| s.value().attr("toc"))
            .and_then(|id| manifest.get(id))
            .or_else(|| manifest.values().find(|(_, media, _)| media == "application/x-dtbncx+xml"));
        if let Some((path, _, _)) = ncx {
            if let Some(text) = zip.read_text(path)? {
                let doc = parse_xml(&text);
                for point in elements(&doc, "navpoint") {
                    let inner = |name: &str| point.descendants().filter_map(ElementRef::wrap)
                        .find(|e| e.value().name() == name);
                    let label = inner("text").map(|t| clean(&t.text().collect::<String>())).unwrap_or_default();
                    let src = inner("content").and_then(|c| c.value().attr("src").map(str::to_string));
                    if let (Some(src), false) = (src, label.is_empty()) {
                        titles.entry(resolve_path(path, &src)).or_insert(label);
                    }
                }
            }
        }
    }
    Ok(titles)
}

/// Archive paths META-INF/encryption.xml lists as encrypted. Font
/// obfuscation lists fonts there too, which is harmless; a listed
/// chapter means the text is unreadable.
fn encrypted_paths(zip: &ZipArchive) -> Result<HashSet<String>, AppError> {
    let mut paths = HashSet::new();
    if zip.contains("META-INF/encryption.xml") {
        if let Some(text) = zip.read_text("META-INF/encryption.xml")? {
            let doc = parse_xml(&text);
            for e in doc.root_element().descendants().filter_map(ElementRef::wrap) {
                if e.value().name().ends_with("cipherreference") {
                    if let Some(uri) = e.value().attr("uri") {
                        paths.insert(resolve_path("", uri));
                    }
                }
            }
        }
    }
    Ok(paths)
}

/// Drop what a local book can't serve: images whose bytes are in the
/// file (anything not on the web), and blocks left empty by that.
fn clean_blocks(blocks: Vec<ContentBlock>) -> Vec<ContentBlock> {
    blocks.into_iter().filter_map(|block| match block {
        ContentBlock::Image { src, alt } => {
            is_web(&src).then_some(ContentBlock::Image { src, alt })
        }
        ContentBlock::Paragraph { text } => {
            let text = clean_inline(text);
            (!text.is_empty()).then_some(ContentBlock::Paragraph { text })
        }
        ContentBlock::Blockquote { blocks } => {
            let blocks = clean_blocks(blocks);
            (!blocks.is_empty()).then_some(ContentBlock::Blockquote { blocks })
        }
        ContentBlock::List { ordered, items } => {
            let items: Vec<_> = items.into_iter().map(clean_blocks).filter(|i| !i.is_empty()).collect();
            (!items.is_empty()).then_some(ContentBlock::List { ordered, items })
        }
        other => Some(other),
    }).collect()
}

/// A link inside the book (another chapter, a footnote) has nowhere to
/// go: keep its text, drop the link. Web links stay.
fn clean_inline(content: Vec<InlineContent>) -> Vec<InlineContent> {
    let mut out = Vec::with_capacity(content.len());
    for inline in content {
        match inline {
            InlineContent::Link { href, content } => {
                let content = clean_inline(content);
                if is_web(&href) || href.starts_with("mailto:") {
                    out.push(InlineContent::Link { href, content });
                } else {
                    out.extend(content);
                }
            }
            InlineContent::Bold { content } => out.push(InlineContent::Bold { content: clean_inline(content) }),
            InlineContent::Italic { content } => out.push(InlineContent::Italic { content: clean_inline(content) }),
            InlineContent::Strikethrough { content } => {
                out.push(InlineContent::Strikethrough { content: clean_inline(content) })
            }
            InlineContent::Superscript { content } => {
                out.push(InlineContent::Superscript { content: clean_inline(content) })
            }
            other => out.push(other),
        }
    }
    out
}

fn is_web(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

// ---------------------------------------------------------------------------
// XML through the HTML parser
// ---------------------------------------------------------------------------

/// HTML's void elements: the only ones `<x/>` closes for the HTML parser.
const VOID: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                        "source", "track", "wbr"];

fn parse_xml(xml: &str) -> Html {
    Html::parse_document(&expand_self_closing(xml))
}

/// Every element with this name (lowercase, prefix included: "dc:title"),
/// in document order.
fn elements<'a>(doc: &'a Html, name: &str) -> Vec<ElementRef<'a>> {
    doc.root_element().descendants().filter_map(ElementRef::wrap)
        .filter(|e| e.value().name().eq_ignore_ascii_case(name))
        .collect()
}

/// Rewrite `<x a="b"/>` as `<x a="b"></x>` for every non-void element, so
/// the HTML parser closes what XML closed. Comments, CDATA, processing
/// instructions and closing tags pass through untouched.
fn expand_self_closing(xml: &str) -> String {
    let bytes = xml.as_bytes();
    let mut out = String::with_capacity(xml.len() + 64);
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'<' {
            let next = xml[i..].find('<').map_or(bytes.len(), |n| i + n);
            out.push_str(&xml[i..next]);
            i = next;
            continue;
        }
        let rest = &xml[i..];
        // Spans the tag scanner must not look inside.
        let skip = if rest.starts_with("<!--") {
            Some(rest.find("-->").map_or(rest.len(), |n| n + 3))
        } else if rest.starts_with("<![CDATA[") {
            Some(rest.find("]]>").map_or(rest.len(), |n| n + 3))
        } else if rest.starts_with("<?") {
            Some(rest.find("?>").map_or(rest.len(), |n| n + 2))
        } else {
            None
        };
        if let Some(len) = skip {
            out.push_str(&rest[..len]);
            i += len;
            continue;
        }
        // The tag's end, quotes respected.
        let mut end = None;
        let mut quote: Option<u8> = None;
        for (offset, &b) in bytes[i + 1..].iter().enumerate() {
            match quote {
                Some(q) if b == q => quote = None,
                Some(_) => {}
                None if b == b'"' || b == b'\'' => quote = Some(b),
                None if b == b'>' => { end = Some(i + 1 + offset); break; }
                None => {}
            }
        }
        let Some(end) = end else {
            out.push_str(rest);
            break;
        };
        let tag = &xml[i..=end];
        let name: String = tag[1..].chars()
            .take_while(|c| c.is_alphanumeric() || matches!(c, ':' | '-' | '_' | '.'))
            .collect();
        if tag.ends_with("/>") && !name.is_empty() && !VOID.contains(&name.to_ascii_lowercase().as_str()) {
            out.push_str(tag[..tag.len() - 2].trim_end());
            out.push_str("></");
            out.push_str(&name);
            out.push('>');
        } else {
            out.push_str(tag);
        }
        i = end + 1;
    }
    out
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Whitespace runs to single spaces, ends trimmed.
fn clean(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `href` (relative to the document at `base`) as an archive path:
/// fragment and query dropped, percent-escapes decoded, `.`/`..` folded.
fn resolve_path(base: &str, href: &str) -> String {
    let href = href.split(['#', '?']).next().unwrap_or("");
    let href = percent_decode(href);
    let mut parts: Vec<&str> = if href.starts_with('/') {
        Vec::new()
    } else {
        let mut dir: Vec<&str> = base.split('/').collect();
        dir.pop();
        dir
    };
    for part in href.split('/') {
        match part {
            "" | "." => {}
            ".." => { parts.pop(); }
            other => parts.push(other),
        }
    }
    parts.join("/")
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = (bytes[i] == b'%').then(|| s.get(i + 1..i + 3)).flatten()
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match hex {
            Some(byte) => { out.push(byte); i += 3; }
            None => { out.push(bytes[i]); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The leading "YYYY-MM-DD" of a date, or a bare year as January 1st.
fn iso_day(date: &str) -> Option<String> {
    let d = date.trim();
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if d.len() >= 10 && d.is_char_boundary(10) {
        let day = &d[..10];
        let b = day.as_bytes();
        if digits(&day[..4]) && b[4] == b'-' && digits(&day[5..7]) && b[7] == b'-' && digits(&day[8..10]) {
            return Some(day.to_string());
        }
    }
    (d.len() == 4 && digits(d)).then(|| format!("{d}-01-01"))
}

/// The library's language names are display names (AO3's own); a package
/// declares a code. Unknown codes are kept as written.
fn language_name(code: &str) -> String {
    let primary = code.trim().split(['-', '_']).next().unwrap_or("").to_ascii_lowercase();
    match primary.as_str() {
        "en" => "English",
        "de" => "Deutsch",
        "es" => "Español",
        "fr" => "Français",
        "it" => "Italiano",
        "ru" => "Русский",
        "zh" => "中文-普通话 國語",
        "ja" => "日本語",
        "pt" => "Português",
        "nl" => "Nederlands",
        "pl" => "Polski",
        _ => return code.trim().to_string(),
    }.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::epub::StoredZipWriter;
    use std::io::Write;

    const CONTAINER: &str = r#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#;

    // An EPUB 3 package, hand-authored: self-closing manifest and spine
    // entries, a cover page with no text, a nav document, a non-linear
    // extra, a percent-escaped href, two creators and repeated subjects.
    const OPF3: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="other">isbn:0000000000</dc:identifier>
    <dc:identifier id="book-id">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
    <dc:title>The Lighthouse   Ledger</dc:title>
    <dc:creator id="c1">Wren Okafor</dc:creator>
    <dc:creator id="c2">T. Marsh</dc:creator>
    <dc:language>en-GB</dc:language>
    <dc:description>&lt;p&gt;A keeper counts the ships that &lt;em&gt;do not&lt;/em&gt; come back.&lt;/p&gt;</dc:description>
    <dc:subject>Mystery</dc:subject>
    <dc:subject>Sea Stories</dc:subject>
    <dc:subject>mystery</dc:subject>
    <dc:date>2024-03-09T12:00:00Z</dc:date>
    <meta property="dcterms:modified">2025-01-02T08:30:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="img" href="images/map.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="cover"/>
    <itemref idref="nav"/>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="notes" linear="no"/>
  </spine>
</package>"#;

    const NAV: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body>
  <nav epub:type="landmarks"><ol><li><a href="cover.xhtml">Cover</a></li></ol></nav>
  <nav epub:type="toc"><ol>
    <li><a href="text/chapter%201.xhtml">The First Night</a></li>
    <li><a href="text/chapter2.xhtml#start">The Second Night</a></li>
  </ol></nav>
</body></html>"#;

    const COVER: &str = r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
<body><div><img src="images/map.png" alt="A map"/></div></body></html>"#;

    // A self-closing anchor (a page marker) before the text, an image in
    // the file, a link to another chapter and a link to the web.
    const CH1: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>ignored</title></head>
<body>
  <a id="page1"/>
  <h2>The First Night</h2>
  <p>The lamp was lit at <em>dusk</em>, as it always was.</p>
  <p><img src="../images/map.png" alt="A map"/></p>
  <p>See <a href="chapter2.xhtml#start">the second night</a> or <a href="https://example.org/tides">the tide tables</a>.</p>
  <hr/>
  <blockquote><p>Nine ships out. Eight home.</p></blockquote>
</body></html>"#;

    const CH2: &str = r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>ignored</title></head>
<body><h1 id="start">Chapter Two</h1><p>Morning came without the ninth.</p></body></html>"#;

    const NOTES: &str = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Not in the reading order.</p></body></html>"#;

    fn epub3() -> Vec<u8> {
        let mut zip = StoredZipWriter::new();
        zip.add("mimetype", b"application/epub+zip");
        zip.add("META-INF/container.xml", CONTAINER.as_bytes());
        zip.add("OEBPS/content.opf", OPF3.as_bytes());
        zip.add("OEBPS/nav.xhtml", NAV.as_bytes());
        zip.add("OEBPS/cover.xhtml", COVER.as_bytes());
        zip.add("OEBPS/text/chapter 1.xhtml", CH1.as_bytes());
        zip.add("OEBPS/text/chapter2.xhtml", CH2.as_bytes());
        zip.add("OEBPS/text/notes.xhtml", NOTES.as_bytes());
        zip.finish()
    }

    fn plain(text: &str) -> InlineContent {
        InlineContent::Text { value: text.to_string() }
    }

    #[test]
    fn epub3_package_becomes_a_work() {
        let book = read_epub(&epub3(), "ledger.epub").unwrap();
        let w = &book.summary;
        assert_eq!(w.source, "local");
        assert_eq!(w.external_id, "urn:uuid:11111111-2222-3333-4444-555555555555", "the declared unique identifier");
        assert_eq!(w.url, "");
        assert_eq!(w.title, "The Lighthouse Ledger");
        assert_eq!(w.authors, vec!["Wren Okafor", "T. Marsh"]);
        assert_eq!(w.tags, vec!["Mystery", "Sea Stories"], "subjects, repeats dropped");
        assert_eq!(w.summary, "A keeper counts the ships that do not come back.");
        assert_eq!(w.language, "English");
        assert_eq!((w.date_published.as_str(), w.date_updated.as_str()), ("2024-03-09", "2025-01-02"));
        assert_eq!((w.chapter_count, w.total_chapters, w.complete), (2, Some(2), true));
        assert_eq!((w.kudos, w.hits, w.bookmarks, w.comments), (None, None, None, None), "absent, never zero");
        assert!(w.word_count.unwrap() > 20);
        assert!(book.stats.is_empty() && book.authors.is_empty());
    }

    #[test]
    fn spine_gives_the_chapters_in_reading_order() {
        let book = read_epub(&epub3(), "ledger.epub").unwrap();
        // The cover (no text), the nav document and the non-linear notes
        // are not chapters.
        assert_eq!(book.chapters.len(), 2);
        let (one, two) = (&book.chapters[0], &book.chapters[1]);
        assert_eq!((one.number, one.title.as_deref()), (1, Some("The First Night")));
        // The nav entry names the chapter, not the page's own <h1>.
        assert_eq!((two.number, two.title.as_deref()), (2, Some("The Second Night")));

        // The heading that repeats the title is dropped; the self-closing
        // anchor swallowed nothing; the in-file image is gone; the link to
        // another chapter is plain text and the web link is kept.
        assert_eq!(one.content, vec![
            ContentBlock::Paragraph { text: vec![
                plain("The lamp was lit at "),
                InlineContent::Italic { content: vec![plain("dusk")] },
                plain(", as it always was."),
            ] },
            ContentBlock::Paragraph { text: vec![
                plain("See "),
                plain("the second night"),
                plain(" or "),
                InlineContent::Link { href: "https://example.org/tides".to_string(), content: vec![plain("the tide tables")] },
                plain("."),
            ] },
            ContentBlock::HorizontalRule,
            ContentBlock::Blockquote { blocks: vec![
                ContentBlock::Paragraph { text: vec![plain("Nine ships out. Eight home.")] },
            ] },
        ]);
        // The page's heading differs from the listed title, so it stays.
        assert_eq!(two.content, vec![
            ContentBlock::Heading { level: 1, text: "Chapter Two".to_string() },
            ContentBlock::Paragraph { text: vec![plain("Morning came without the ninth.")] },
        ]);
    }

    // An EPUB 2 book: NCX for titles, no declared identifier, no title,
    // the package at the archive root, and DEFLATE-compressed entries.
    const OPF2: &str = r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:creator opf:role="aut">Ines Calder</dc:creator>
    <dc:language>xx</dc:language>
    <dc:date>1998</dc:date>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="a" href="a.html" media-type="application/xhtml+xml"/>
    <item id="b" href="b.html" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="a"/><itemref idref="b"/></spine>
</package>"#;

    const NCX: &str = r#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="none"/></head>
  <docTitle><text>Untitled Draft</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Prologue</text></navLabel><content src="a.html"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>One</text></navLabel><content src="b.html#top"/></navPoint>
  </navMap>
</ncx>"#;

    /// A zip whose entries are DEFLATE-compressed, written by hand.
    fn deflated_zip(files: &[(&str, &str)]) -> Vec<u8> {
        let (mut data, mut central) = (Vec::new(), Vec::new());
        for (name, content) in files {
            let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
            enc.write_all(content.as_bytes()).unwrap();
            let packed = enc.finish().unwrap();
            let offset = data.len() as u32;
            let header = |sig: u32, out: &mut Vec<u8>, central: bool| {
                out.extend_from_slice(&sig.to_le_bytes());
                if central { out.extend_from_slice(&20u16.to_le_bytes()); }
                out.extend_from_slice(&20u16.to_le_bytes());
                out.extend_from_slice(&0u16.to_le_bytes());
                out.extend_from_slice(&8u16.to_le_bytes());
                out.extend_from_slice(&[0; 4]);
                out.extend_from_slice(&0u32.to_le_bytes()); // crc: the reader does not check it
                out.extend_from_slice(&(packed.len() as u32).to_le_bytes());
                out.extend_from_slice(&(content.len() as u32).to_le_bytes());
                out.extend_from_slice(&(name.len() as u16).to_le_bytes());
                out.extend_from_slice(&0u16.to_le_bytes());
            };
            header(0x0403_4b50, &mut data, false);
            data.extend_from_slice(name.as_bytes());
            data.extend_from_slice(&packed);
            header(0x0201_4b50, &mut central, true);
            central.extend_from_slice(&[0; 10]); // comment len, disk, attributes
            central.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(name.as_bytes());
        }
        let dir_offset = data.len() as u32;
        let count = files.len() as u16;
        data.extend_from_slice(&central);
        data.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        data.extend_from_slice(&[0; 4]);
        data.extend_from_slice(&count.to_le_bytes());
        data.extend_from_slice(&count.to_le_bytes());
        data.extend_from_slice(&(central.len() as u32).to_le_bytes());
        data.extend_from_slice(&dir_offset.to_le_bytes());
        data.extend_from_slice(&0u16.to_le_bytes());
        data
    }

    fn epub2() -> Vec<u8> {
        deflated_zip(&[
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", &CONTAINER.replace("OEBPS/content.opf", "book.opf")),
            ("book.opf", OPF2),
            ("toc.ncx", NCX),
            ("a.html", "<html><body><p>Before anything, there was the tide.</p></body></html>"),
            ("b.html", "<html><body><h3>One</h3><p>Then there was a boat.</p></body></html>"),
        ])
    }

    #[test]
    fn epub2_ncx_deflate_and_fallbacks() {
        let bytes = epub2();
        let book = read_epub(&bytes, "/tmp/My Draft.epub").unwrap();
        let w = &book.summary;
        assert_eq!(w.title, "My Draft", "no dc:title: the file's name");
        assert!(w.external_id.starts_with("sha256:") && w.external_id.len() == 7 + 32, "no identifier: the file's hash");
        assert_eq!(read_epub(&bytes, "other.epub").unwrap().summary.external_id, w.external_id, "same file, same id");
        assert_eq!(w.authors, vec!["Ines Calder"]);
        assert_eq!(w.language, "xx", "an unknown code is kept");
        assert_eq!((w.date_published.as_str(), w.date_updated.as_str()), ("1998-01-01", "1998-01-01"));
        assert_eq!(w.summary, "");
        let titles: Vec<_> = book.chapters.iter().map(|c| c.title.as_deref()).collect();
        assert_eq!(titles, vec![Some("Prologue"), Some("One")]);
        // "One" was also the page heading: dropped from the text.
        assert_eq!(book.chapters[1].content, vec![
            ContentBlock::Paragraph { text: vec![plain("Then there was a boat.")] },
        ]);
    }

    #[test]
    fn chapter_without_a_listed_title_uses_its_heading_or_none() {
        let mut zip = StoredZipWriter::new();
        zip.add("META-INF/container.xml", CONTAINER.replace("OEBPS/content.opf", "p.opf").as_bytes());
        zip.add("p.opf", br#"<package><metadata><dc:title>T</dc:title></metadata>
            <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
                      <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="a"/><itemref idref="b"/></spine></package>"#);
        zip.add("a.xhtml", b"<html><body><h1>Arrival</h1><p>Text.</p></body></html>");
        zip.add("b.xhtml", b"<html><body><p>No heading here.</p></body></html>");
        let book = read_epub(&zip.finish(), "t.epub").unwrap();
        assert_eq!(book.chapters[0].title.as_deref(), Some("Arrival"));
        assert_eq!(book.chapters[0].content.len(), 1, "the heading became the title");
        assert_eq!(book.chapters[1].title, None);
    }

    #[test]
    fn unreadable_files_are_refused_with_a_reason() {
        let message = |r: Result<FetchedWork, AppError>| r.err().map(|e| e.to_string()).unwrap_or_default();
        assert!(message(read_epub(b"definitely not a zip file, just text", "x.epub")).contains("no zip directory"));
        assert!(message(read_epub(b"tiny", "x.epub")).contains("too small"));

        let mut zip = StoredZipWriter::new();
        zip.add("hello.txt", b"hi");
        assert!(message(read_epub(&zip.finish(), "x.epub")).contains("container.xml"));

        // A book whose only document is a cover has nothing to read.
        let mut zip = StoredZipWriter::new();
        zip.add("META-INF/container.xml", CONTAINER.replace("OEBPS/content.opf", "p.opf").as_bytes());
        zip.add("p.opf", br#"<package><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="a"/></spine></package>"#);
        zip.add("a.xhtml", COVER.as_bytes());
        assert!(message(read_epub(&zip.finish(), "x.epub")).contains("no readable text"));

        // A chapter listed in encryption.xml is copy-protected.
        let mut zip = StoredZipWriter::new();
        zip.add("META-INF/container.xml", CONTAINER.replace("OEBPS/content.opf", "p.opf").as_bytes());
        zip.add("META-INF/encryption.xml", br#"<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptedData><enc:CipherData><enc:CipherReference URI="a.xhtml"/></enc:CipherData></enc:EncryptedData>
            </encryption>"#);
        zip.add("p.opf", br#"<package><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="a"/></spine></package>"#);
        zip.add("a.xhtml", b"<html><body><p>scrambled</p></body></html>");
        assert!(message(read_epub(&zip.finish(), "x.epub")).contains("copy-protected"));
    }

    #[test]
    fn exported_books_read_back() {
        // The app's own export is a valid input: same title, authors and
        // chapter text (its title page becomes a leading chapter).
        let chapter = Chapter {
            id: Some(5), title: Some("Opening".to_string()), number: 1,
            content: vec![ContentBlock::Paragraph { text: vec![plain("It began at low tide.")] }],
            notes_before: None, notes_after: None,
        };
        let mut work = read_epub(&epub3(), "ledger.epub").unwrap().summary;
        work.external_id = "42".to_string();
        let path = std::env::temp_dir().join(format!("aoyo-epub-roundtrip-{}.epub", std::process::id()));
        crate::epub::export_epub(&work, &[chapter], path.to_str().unwrap()).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let _ = std::fs::remove_file(&path);

        let book = read_epub(&bytes, "export.epub").unwrap();
        assert_eq!(book.summary.title, "The Lighthouse Ledger");
        assert_eq!(book.summary.external_id, "urn:local:work:42");
        assert_eq!(book.summary.authors, vec!["Wren Okafor", "T. Marsh"]);
        let last = book.chapters.last().unwrap();
        assert!(last.content.contains(&ContentBlock::Paragraph { text: vec![plain("It began at low tide.")] }));
    }

    #[test]
    fn self_closing_tags_are_spelled_out() {
        assert_eq!(expand_self_closing(r#"<a id="x"/><br/><item href="a>b"/>"#),
                   r#"<a id="x"></a><br/><item href="a>b"></item>"#);
        assert_eq!(expand_self_closing("<!-- <p/> --><?xml version='1.0'?><p>t</p>"),
                   "<!-- <p/> --><?xml version='1.0'?><p>t</p>");
        assert_eq!(resolve_path("OEBPS/content.opf", "text/ch%201.xhtml#a"), "OEBPS/text/ch 1.xhtml");
        assert_eq!(resolve_path("OEBPS/text/ch1.xhtml", "../images/a.png"), "OEBPS/images/a.png");
        assert_eq!(resolve_path("content.opf", "a.html"), "a.html");
    }
}
