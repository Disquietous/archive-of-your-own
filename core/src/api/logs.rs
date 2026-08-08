use super::*;

#[uniffi::export]
impl AO3App {
    // -- Debug Log --

    pub fn get_logs(&self, limit: u32) -> Result<Vec<ULogEntry>, AO3Error> {
        crate::with_log_db(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, timestamp, level, tag, message FROM debug_log ORDER BY id DESC LIMIT ?1"
            ).map_err(|e| AO3Error::Storage { message: e.to_string() })?;
            let rows = stmt.query_map(rusqlite::params![limit as i64], |row| {
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
