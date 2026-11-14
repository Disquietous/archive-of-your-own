//! Source-specific work statistics (Area 3.3): the `fields` registry
//! names what a source reports beyond the AO3-shaped columns, and
//! `work_stats` holds one value per (work, field). Any field is
//! filterable and sortable in SQL; AO3 has none (its stats are columns).

use std::sync::Arc;

use rusqlite::params;

use crate::error::AppError;

use super::fields_cache::FieldEntity;
use super::{map_sql, Storage};

/// One stat on one work, as stored.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkStat {
    pub field_id: i64,
    pub num_value: Option<f64>,
    pub text_value: Option<String>,
}

impl Storage {
    /// Register a field if the registry lacks it; an existing row is left
    /// exactly as it is (never rewritten at startup). Returns the row id.
    pub fn ensure_field(&self, source: &str, key: &str, label: &str, value_type: &str,
                        display_order: i64) -> Result<i64, AppError> {
        if value_type != "num" && value_type != "text" {
            return Err(AppError::StorageError(format!("field value type must be num or text, not {value_type}")));
        }
        self.fields_cache.ensure(&self.conn, source, "work", key, label, value_type, display_order)
    }

    /// Register a user property under the registry (entity "user"); the
    /// label and type come from the source's vocabulary (`user_fields`).
    pub fn ensure_user_field(&self, source: &str, name: &str) -> Result<i64, AppError> {
        let (label, value_type) = crate::user_fields::registry_entry(source, name);
        self.fields_cache.ensure(&self.conn, source, "user", name, &label, value_type, 0)
    }

    pub fn get_field(&self, id: i64) -> Option<Arc<FieldEntity>> {
        self.fields_cache.get(id)
    }

    pub fn field_id(&self, source: &str, key: &str) -> Option<i64> {
        self.fields_cache.id_of(source, "work", key)
    }

    /// A source's work-stat fields in display order.
    pub fn fields_for_source(&self, source: &str) -> Vec<Arc<FieldEntity>> {
        self.fields_cache.for_source(source, "work")
    }

    /// Write the stats a partial view of a work carries (a listing blurb):
    /// each given field is set, and every field the view does not carry
    /// keeps the value it has. A listing not mentioning a figure says
    /// nothing about it — only the work's own page can take one away
    /// (`set_work_stats`).
    pub fn merge_work_stats(&self, work_id: u64, stats: &[WorkStat]) -> Result<(), AppError> {
        let mut stmt = self.conn.prepare_cached(
            "INSERT INTO work_stats (work_id, field_id, num_value, text_value) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(work_id, field_id) DO UPDATE SET
                 num_value = excluded.num_value, text_value = excluded.text_value"
        ).map_err(map_sql)?;
        for s in stats {
            stmt.execute(params![work_id as i64, s.field_id, s.num_value, s.text_value])
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// Replace a work's stats with `stats` (one value per field; a field
    /// absent from the slice is removed — absent, never zero). For a
    /// fetch of the work itself, which states everything the source has.
    pub fn set_work_stats(&self, work_id: u64, stats: &[WorkStat]) -> Result<(), AppError> {
        self.conn.execute("DELETE FROM work_stats WHERE work_id = ?1", params![work_id as i64])
            .map_err(map_sql)?;
        let mut stmt = self.conn.prepare_cached(
            "INSERT INTO work_stats (work_id, field_id, num_value, text_value) VALUES (?1, ?2, ?3, ?4)"
        ).map_err(map_sql)?;
        for s in stats {
            stmt.execute(params![work_id as i64, s.field_id, s.num_value, s.text_value])
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// One numeric stat of one work; None when the work has no value.
    pub fn get_work_stat_num(&self, work_id: u64, field_id: i64) -> Result<Option<f64>, AppError> {
        use rusqlite::OptionalExtension;
        self.conn.query_row(
            "SELECT num_value FROM work_stats WHERE work_id = ?1 AND field_id = ?2",
            params![work_id as i64, field_id], |r| r.get::<_, Option<f64>>(0),
        ).optional().map_err(map_sql).map(Option::flatten)
    }

    pub fn get_work_stats(&self, work_id: u64) -> Result<Vec<WorkStat>, AppError> {
        let mut stmt = self.conn.prepare(
            "SELECT field_id, num_value, text_value FROM work_stats WHERE work_id = ?1 ORDER BY field_id"
        ).map_err(map_sql)?;
        let rows = stmt.query_map(params![work_id as i64], |r| Ok(WorkStat {
            field_id: r.get(0)?, num_value: r.get(1)?, text_value: r.get(2)?,
        })).map_err(map_sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sql)
    }
}
