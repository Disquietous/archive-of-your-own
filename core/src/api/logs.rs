use super::*;

// Every `blocking_*` call below runs on Swift's calling thread, never on
// `_runtime` — see the lock discipline invariant in `api/mod.rs`.
#[uniffi::export]
impl AO3App {
    // -- Debug Log --

    /// The newest `limit` rows, oldest first; `limit` 0 = every row.
    pub fn get_logs(&self, limit: u32) -> Result<Vec<ULogEntry>, AO3Error> {
        crate::with_log_db(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, timestamp, level, tag, message FROM debug_log ORDER BY id DESC LIMIT ?1"
            ).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            // SQLite: a negative LIMIT means no limit.
            let limit = if limit == 0 { -1 } else { limit as i64 };
            let rows = stmt.query_map(rusqlite::params![limit], |row| {
                Ok(ULogEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    level: row.get(2)?,
                    tag: row.get(3)?,
                    message: row.get(4)?,
                })
            }).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| AO3Error::Storage { message: e.to_string() })
        }).unwrap_or_else(|| Ok(Vec::new()))
         .map(|mut v| { v.reverse(); v })
    }

    /// One page of the debug log for the viewer: rows matching `query`
    /// with `after_id < id < before_id` (0 = unbounded on that side),
    /// newest first, at most `limit` (0 = no limit). Paging down passes
    /// the oldest loaded id as `before_id`; a live tail passes the newest
    /// loaded id as `after_id`.
    pub fn query_logs(&self, query: ULogQuery, before_id: i64, after_id: i64, limit: u32)
        -> Result<Vec<ULogEntry>, AO3Error> {
        let (clause, mut params) = log_query_clause(&query);
        let sql = format!(
            "SELECT id, timestamp, level, tag, message FROM debug_log
             WHERE {clause} AND (?{b} = 0 OR id < ?{b}) AND id > ?{a}
             ORDER BY id DESC LIMIT ?{l}",
            b = params.len() + 1, a = params.len() + 2, l = params.len() + 3);
        params.push(Box::new(before_id));
        params.push(Box::new(after_id));
        // SQLite: a negative LIMIT means no limit.
        params.push(Box::new(if limit == 0 { -1 } else { limit as i64 }));
        crate::with_log_db(|conn| {
            let mut stmt = conn.prepare(&sql)
                .map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            let rows = stmt.query_map(rusqlite::params_from_iter(params.iter()), |row| {
                Ok(ULogEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    level: row.get(2)?,
                    tag: row.get(3)?,
                    message: row.get(4)?,
                })
            }).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| AO3Error::Storage { message: e.to_string() })
        }).unwrap_or_else(|| Ok(Vec::new()))
    }

    /// How many rows match `query` — the viewer's "loaded of total".
    pub fn count_logs(&self, query: ULogQuery) -> u64 {
        let (clause, params) = log_query_clause(&query);
        crate::with_log_db(|conn| {
            conn.query_row(&format!("SELECT COUNT(*) FROM debug_log WHERE {clause}"),
                           rusqlite::params_from_iter(params.iter()),
                           |r| r.get::<_, i64>(0)).unwrap_or(0) as u64
        }).unwrap_or(0)
    }

    /// Every distinct tag in the log, sorted — the viewer's tag picker,
    /// independent of which rows are loaded.
    pub fn log_tags(&self) -> Vec<String> {
        crate::with_log_db(|conn| {
            let Ok(mut stmt) = conn.prepare(
                "SELECT DISTINCT tag FROM debug_log WHERE tag <> '' ORDER BY tag") else { return Vec::new() };
            stmt.query_map([], |r| r.get::<_, String>(0))
                .map(|rows| rows.filter_map(Result::ok).collect())
                .unwrap_or_default()
        }).unwrap_or_default()
    }

    /// `get_logs` as text, one line per row; `limit` 0 = every row.
    pub fn dump_logs(&self, limit: u32) -> Result<String, AO3Error> {
        let logs = self.get_logs(limit)?;
        let mut output = String::new();
        for e in &logs {
            output.push_str(&format!("[{}] {} [{}] {}: {}\n", e.id, e.timestamp, e.level, e.tag, e.message));
        }
        Ok(output)
    }

    pub fn clear_logs(&self) -> Result<(), AO3Error> {
        crate::with_log_db(|conn| {
            conn.execute("DELETE FROM debug_log", [])
                .map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            Ok(())
        }).unwrap_or(Ok(()))
    }

    pub fn write_log(&self, level: String, tag: String, message: String) -> Result<(), AO3Error> {
        crate::dlog(&level, &tag, &message);
        Ok(())
    }

    // -- Request Audit Log --

    /// Persist any buffered requests, then return the most recent `limit` rows
    /// (newest first) from the encrypted database.
    pub fn get_request_log(&self, limit: u32) -> Result<Vec<URequestLogEntry>, AO3Error> {
        self.flush_request_log();
        let storage = self.storage.blocking_lock();
        let rows = storage.get_request_logs(limit).map_err(AO3Error::from)?;
        Ok(rows.into_iter().map(|(id, started, method, url, status, dur, req_b, resp_b, error, payload)| {
            URequestLogEntry {
                id, started_ms: started as i64, method, url, status,
                duration_ms: dur as i64, request_bytes: req_b as i64,
                response_bytes: resp_b as i64, error, payload,
            }
        }).collect())
    }

    pub fn clear_request_log(&self) -> Result<(), AO3Error> {
        let _ = crate::client::drain_request_records();
        let storage = self.storage.blocking_lock();
        storage.clear_request_logs().map_err(AO3Error::from)
    }

    /// Cached avatar bytes for an author, if previously fetched. Sync,
    /// DB-only — never touches the network.
    pub fn get_cached_author_avatar(&self, username: String) -> Result<Option<Vec<u8>>, AO3Error> {
        let s = self.storage.blocking_lock();
        s.get_cached_image(&format!("avatar:{username}")).map_err(AO3Error::from)
    }
}

/// WHERE fragment (without the keyword) and its bound values for a
/// viewer filter. `text` is wrapped as `%text%` with LIKE wildcards
/// escaped, so the user's `%` and `_` match literally.
fn log_query_clause(q: &ULogQuery) -> (String, Vec<Box<dyn rusqlite::types::ToSql>>) {
    let mut parts: Vec<String> = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
    if let Some(level) = q.level.as_deref().filter(|s| !s.is_empty()) {
        params.push(Box::new(level.to_string()));
        parts.push(format!("level = ?{}", params.len()));
    }
    if let Some(tag) = q.tag.as_deref().filter(|s| !s.is_empty()) {
        params.push(Box::new(tag.to_string()));
        parts.push(format!("tag = ?{}", params.len()));
    }
    if let Some(text) = q.text.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let escaped = text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
        params.push(Box::new(format!("%{escaped}%")));
        let n = params.len();
        parts.push(format!(
            "(message LIKE ?{n} ESCAPE '\\' OR tag LIKE ?{n} ESCAPE '\\' OR level LIKE ?{n} ESCAPE '\\'
              OR timestamp LIKE ?{n} ESCAPE '\\' OR CAST(id AS TEXT) LIKE ?{n} ESCAPE '\\')"));
    }
    if parts.is_empty() { ("1".to_string(), params) } else { (parts.join(" AND "), params) }
}
