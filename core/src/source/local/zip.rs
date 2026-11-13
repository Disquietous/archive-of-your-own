//! A read-only zip reader, just enough for an EPUB: the central
//! directory, STORED and DEFLATE entries. No zip64, no encryption, no
//! multi-disk archives. Every read is bounds-checked — the file is the
//! user's, but it is still untrusted input.

use std::collections::HashMap;
use std::io::Read;

use crate::error::AppError;

/// Largest single entry the reader will inflate. A chapter of prose is a
/// few hundred KB; this stops a crafted entry from exhausting memory.
const MAX_ENTRY_BYTES: u64 = 32 * 1024 * 1024;

struct Entry {
    method: u16,
    encrypted: bool,
    compressed_size: usize,
    local_offset: usize,
}

pub(super) struct ZipArchive<'a> {
    data: &'a [u8],
    entries: HashMap<String, Entry>,
}

fn bad(what: &str) -> AppError {
    AppError::ParseError(format!("not a readable EPUB: {what}"))
}

fn u16_at(data: &[u8], at: usize) -> Result<u16, AppError> {
    data.get(at..at + 2).map(|b| u16::from_le_bytes([b[0], b[1]])).ok_or_else(|| bad("truncated zip"))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, AppError> {
    data.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).ok_or_else(|| bad("truncated zip"))
}

impl<'a> ZipArchive<'a> {
    pub(super) fn open(data: &'a [u8]) -> Result<Self, AppError> {
        // End of central directory: 22 bytes plus a comment of up to 64K,
        // found by scanning back from the end for its signature.
        const EOCD: [u8; 4] = [0x50, 0x4b, 0x05, 0x06];
        if data.len() < 22 {
            return Err(bad("too small to be a zip"));
        }
        let floor = data.len().saturating_sub(22 + 0xFFFF);
        let eocd = (floor..=data.len() - 22).rev()
            .find(|&i| data[i..i + 4] == EOCD)
            .ok_or_else(|| bad("no zip directory"))?;
        let count = u16_at(data, eocd + 10)? as usize;
        let dir_offset = u32_at(data, eocd + 16)?;
        if count == 0xFFFF || dir_offset == 0xFFFF_FFFF {
            return Err(bad("zip64 archives are not supported"));
        }

        let mut entries = HashMap::with_capacity(count);
        let mut at = dir_offset as usize;
        for _ in 0..count {
            if u32_at(data, at)? != 0x0201_4b50 {
                return Err(bad("damaged zip directory"));
            }
            let flags = u16_at(data, at + 8)?;
            let method = u16_at(data, at + 10)?;
            let compressed_size = u32_at(data, at + 20)? as usize;
            let name_len = u16_at(data, at + 28)? as usize;
            let extra_len = u16_at(data, at + 30)? as usize;
            let comment_len = u16_at(data, at + 32)? as usize;
            let local_offset = u32_at(data, at + 42)? as usize;
            let name = data.get(at + 46..at + 46 + name_len).ok_or_else(|| bad("truncated zip"))?;
            entries.insert(String::from_utf8_lossy(name).into_owned(), Entry {
                method,
                encrypted: flags & 1 != 0,
                compressed_size,
                local_offset,
            });
            at += 46 + name_len + extra_len + comment_len;
        }
        Ok(ZipArchive { data, entries })
    }

    pub(super) fn contains(&self, name: &str) -> bool {
        self.entries.contains_key(name)
    }

    /// One entry's bytes, inflated. None when the archive has no such
    /// entry.
    pub(super) fn read(&self, name: &str) -> Result<Option<Vec<u8>>, AppError> {
        let Some(entry) = self.entries.get(name) else { return Ok(None) };
        if entry.encrypted {
            return Err(bad("the file is encrypted"));
        }
        let at = entry.local_offset;
        if u32_at(self.data, at)? != 0x0403_4b50 {
            return Err(bad("damaged zip entry"));
        }
        let start = at + 30 + u16_at(self.data, at + 26)? as usize + u16_at(self.data, at + 28)? as usize;
        let raw = self.data.get(start..start + entry.compressed_size).ok_or_else(|| bad("truncated zip entry"))?;
        match entry.method {
            0 => {
                if raw.len() as u64 > MAX_ENTRY_BYTES {
                    return Err(bad("an entry is too large"));
                }
                Ok(Some(raw.to_vec()))
            }
            8 => {
                let mut out = Vec::new();
                flate2::read::DeflateDecoder::new(raw).take(MAX_ENTRY_BYTES + 1).read_to_end(&mut out)
                    .map_err(|e| bad(&format!("an entry would not inflate ({e})")))?;
                if out.len() as u64 > MAX_ENTRY_BYTES {
                    return Err(bad("an entry is too large"));
                }
                Ok(Some(out))
            }
            other => Err(bad(&format!("unsupported zip compression method {other}"))),
        }
    }

    /// An entry as text: UTF-8 (lossy), byte-order mark dropped.
    pub(super) fn read_text(&self, name: &str) -> Result<Option<String>, AppError> {
        Ok(self.read(name)?.map(|bytes| {
            let text = String::from_utf8_lossy(&bytes);
            text.strip_prefix('\u{feff}').unwrap_or(&text).to_string()
        }))
    }
}
