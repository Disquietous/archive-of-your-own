/// Identify an image payload by magic bytes.
pub fn sniff_image_kind(bytes: &[u8]) -> &'static str {
    if bytes.len() < 12 { return "not-an-image" }
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => "png",
        [0xFF, 0xD8, 0xFF, ..] => "jpeg",
        b if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") => "gif",
        b if b.starts_with(b"RIFF") && &b[8..12] == b"WEBP" => "webp",
        b if b.starts_with(b"BM") => "bmp",
        b if &b[4..8] == b"ftyp" => "heif/avif",
        b if b.starts_with(b"<svg") || b.starts_with(b"<?xml") => "svg",
        _ => "not-an-image",
    }
}
