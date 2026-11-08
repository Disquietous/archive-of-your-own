use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{params, Connection};

use crate::error::AppError;

use super::map_sql;

/// One row of the `fields` registry: a source-specific work statistic
/// (Area 3.3) — what a source reports that has no AO3-shaped column.
/// `value_type` is "num" or "text"; `display_order` orders a source's
/// fields in the UI.
#[derive(Clone, Debug, PartialEq)]
pub struct FieldEntity {
    pub id: i64,
    pub source: String,
    /// What the field describes: "work" (stats) or "user" (properties).
    pub entity: String,
    pub key: String,
    pub label: String,
    pub value_type: String,
    pub display_order: i64,
}

/// The fields registry's in-memory mirror and single write authority —
/// small and read constantly (Area 6.3). Keyed by row id with a
/// (source, key) index. Rows are inserted if missing and never rewritten
/// at startup; `ensure` is the only write.
#[derive(Default)]
pub(super) struct FieldsCache {
    map: RefCell<HashMap<i64, Arc<FieldEntity>>>,
    by_key: RefCell<HashMap<(String, String, String), i64>>,
}

impl FieldsCache {
    pub(super) fn load(&self, conn: &Connection) -> Result<(), AppError> {
        let mut stmt = conn
            .prepare("SELECT id, source, entity, key, label, value_type, display_order FROM fields")
            .map_err(map_sql)?;
        let rows = stmt
            .query_map([], |r| Ok(FieldEntity {
                id: r.get(0)?, source: r.get(1)?, entity: r.get(2)?, key: r.get(3)?, label: r.get(4)?,
                value_type: r.get(5)?, display_order: r.get(6)?,
            }))
            .map_err(map_sql)?;
        let mut map = self.map.borrow_mut();
        let mut by_key = self.by_key.borrow_mut();
        map.clear();
        by_key.clear();
        for row in rows {
            let f = row.map_err(map_sql)?;
            by_key.insert((f.source.clone(), f.entity.clone(), f.key.clone()), f.id);
            map.insert(f.id, Arc::new(f));
        }
        Ok(())
    }

    pub(super) fn get(&self, id: i64) -> Option<Arc<FieldEntity>> {
        self.map.borrow().get(&id).cloned()
    }

    pub(super) fn id_of(&self, source: &str, entity: &str, key: &str) -> Option<i64> {
        self.by_key.borrow().get(&(source.to_string(), entity.to_string(), key.to_string())).copied()
    }

    /// Every field of a source for one entity kind, in display order.
    pub(super) fn for_source(&self, source: &str, entity: &str) -> Vec<Arc<FieldEntity>> {
        let mut out: Vec<Arc<FieldEntity>> = self.map.borrow().values()
            .filter(|f| f.source == source && f.entity == entity)
            .cloned()
            .collect();
        out.sort_by(|a, b| a.display_order.cmp(&b.display_order).then_with(|| a.id.cmp(&b.id)));
        out
    }

    /// Insert the field if the registry lacks it; an existing row is left
    /// exactly as it is. Returns the row id.
    pub(super) fn ensure(&self, conn: &Connection, source: &str, entity: &str, key: &str, label: &str,
                         value_type: &str, display_order: i64) -> Result<i64, AppError> {
        if let Some(id) = self.id_of(source, entity, key) {
            return Ok(id);
        }
        conn.execute(
                "INSERT INTO fields (source, entity, key, label, value_type, display_order)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![source, entity, key, label, value_type, display_order],
            )
            .map_err(map_sql)?;
        let id = conn.last_insert_rowid();
        let f = FieldEntity {
            id, source: source.to_string(), entity: entity.to_string(), key: key.to_string(), label: label.to_string(),
            value_type: value_type.to_string(), display_order,
        };
        self.by_key.borrow_mut().insert((f.source.clone(), f.entity.clone(), f.key.clone()), id);
        self.map.borrow_mut().insert(id, Arc::new(f));
        Ok(id)
    }
}
