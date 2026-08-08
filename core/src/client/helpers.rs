// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Find `marker` in `html`, then extract the quoted value of `attr_prefix`
/// (e.g. `value="`) within the same tag. Attribute order-independent, no DOM.
pub(super) fn scan_attr_near(html: &str, marker: &str, attr_prefix: &str) -> Option<String> {
    let idx = html.find(marker)?;
    let tag_start = html[..idx].rfind('<')?;
    let tag_end = idx + html[idx..].find('>')?;
    let tag = &html[tag_start..tag_end];
    let value_start = tag.find(attr_prefix)? + attr_prefix.len();
    let rest = &tag[value_start..];
    let value_end = rest.find('"')?;
    let value = &rest[..value_end];
    if value.is_empty() { None } else { Some(value.to_string()) }
}

/// Identify an image payload by magic bytes — the formats AO3 embeds use.
/// Escape the five characters Rails' HTML escaping rewrites — the form
/// AO3 renders posted comment text back in.
fn html_escape_min(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Did the response page actually include the posted comment? AO3 echoes
/// the comment HTML-ESCAPED and splits multi-line comments into <p>
/// blocks, so a verbatim substring check fails for any comment with an
/// apostrophe, quote, or line break despite a successful post.
pub(crate) fn comment_post_succeeded(body: &str, content: &str) -> bool {
    if body.contains("Comment created") || body.contains("was added") || body.contains(content) {
        return true;
    }
    let escaped = html_escape_min(content);
    if body.contains(&escaped) {
        return true;
    }
    // Multi-line comments never appear contiguously (paragraph markup
    // between lines) — match the longest single line instead. Guard the
    // length so a trivial fragment can't false-positive off page chrome.
    let longest = escaped
        .lines()
        .map(str::trim)
        .max_by_key(|l| l.len())
        .unwrap_or("");
    longest.len() >= 8 && body.contains(longest)
}

pub fn sniff_image_kind(bytes: &[u8]) -> &'static str {
    if bytes.len() < 12 { return "not-an-image" }
    match bytes {
        b if b.starts_with(&[0x89, b'P', b'N', b'G']) => "png",
        b if b.starts_with(&[0xFF, 0xD8, 0xFF]) => "jpeg",
        b if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") => "gif",
        b if b.starts_with(b"RIFF") && &b[8..12] == b"WEBP" => "webp",
        b if b.starts_with(b"BM") => "bmp",
        b if &b[4..8] == b"ftyp" => "heif/avif",
        b if b.starts_with(b"<svg") || b.starts_with(b"<?xml") => "svg",
        _ => "not-an-image",
    }
}

/// The numeric AO3 subscription record id from a form action like
/// "/users/name/subscriptions/1551470436" — None for the create action.
pub(super) fn sub_id_from_action(action: &str) -> Option<String> {
    action.rsplit('/').next()
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_string)
}

/// Minimal percent-encoding for AO3 tag URLs. AO3 uses *. (dot)* as a tag
/// separator in URLs, so we only encode what's strictly necessary for a valid
/// URL path segment.
pub(super) fn urlencoded(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// Try to extract a bookmark ID from AO3's response HTML.
/// Looks for patterns like id="bookmark_12345" or /bookmarks/12345.
pub(super) fn extract_bookmark_id_from_response(html: &str) -> Option<u64> {
    // Try id="bookmark_NNNNN"
    if let Some(pos) = html.find("id=\"bookmark_") {
        let after = &html[pos + 13..]; // skip `id="bookmark_`
        let end = after.find('"').unwrap_or(after.len());
        if let Ok(id) = after[..end].parse::<u64>() {
            return Some(id);
        }
    }
    // Try /bookmarks/NNNNN in the URL or body
    for part in html.split("/bookmarks/") {
        if part.is_empty() {
            continue;
        }
        let num_str: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(id) = num_str.parse::<u64>() {
            return Some(id);
        }
    }
    None
}

pub(super) fn ao3_tag_encode(tag: &str) -> String {
    tag.replace('/', "*s*")
       .replace('&', "*a*")
       .replace('.', "*d*")
       .replace(' ', "%20")
}
