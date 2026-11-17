//! SQLite persistence compatible with the Apple Media.sqlite migration ledger.

mod bangumi;
mod cache;
pub mod database;
pub mod repository;
pub use bangumi::BangumiStore;

use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("filesystem: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid cache request: {0}")]
    InvalidRequest(String),
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid progress: {0}")]
    InvalidProgress(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredItem {
    pub tenant_id: String,
    pub id: String,
    pub title: String,
    pub kind: String,
    pub overview: Option<String>,
    pub series_id: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub payload: serde_json::Value,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub played: bool,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProgressRecord {
    pub tenant_id: String,
    pub item_id: String,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub played: bool,
    /// Unix seconds, including the fractional part used by Swift Date.
    pub recorded_at: f64,
    pub confirmed_at: Option<f64>,
    #[serde(default)]
    pub completed: bool,
    /// The existing MediaItem JSON, retaining fields unknown to this core version.
    #[serde(default)]
    pub item: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredLibrary {
    pub tenant_id: String,
    pub id: String,
    pub position: i64,
    pub payload: serde_json::Value,
    pub fetched_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredRail {
    pub tenant_id: String,
    pub rail: String,
    pub payload: serde_json::Value,
    pub fetched_at: i64,
    pub payload_version: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PageKey {
    pub tenant_id: String,
    pub parent_id: String,
    pub kinds: String,
    pub sort_key: String,
    pub watch_state: String,
    pub search_term: String,
    pub start_index: i64,
    pub limit: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredPage {
    pub key: PageKey,
    pub payload: serde_json::Value,
    pub fetched_at: i64,
    pub payload_version: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TmdbCacheEntry {
    pub entity_key: String,
    pub language: String,
    pub kind: String,
    pub tmdb_id: i64,
    pub season_number: Option<i64>,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub payload_version: i64,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TmdbLink {
    pub tenant_id: String,
    pub item_id: String,
    pub entity_key: String,
    pub source: String,
    pub confidence: f64,
    pub linked_at: i64,
}

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &str) -> Result<Self, StoreError> {
        let connection = if path == ":memory:" {
            Connection::open_in_memory()?
        } else {
            Connection::open(path)?
        };
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", true)?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub(crate) fn open_cache_connection(path: &std::path::Path) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", true)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        let _ = connection.pragma_update(None, "journal_size_limit", database::JOURNAL_LIMIT);
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn migrate(&self) -> Result<(), StoreError> {
        self.connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS grdb_migrations(identifier TEXT PRIMARY KEY);",
        )?;
        self.migration("createMediaSchemaV1", |tx| {
            tx.execute_batch(include_str!("../../../schema/media_v1.sql"))
        })?;
        self.migration("addTMDbSchemaV2", |tx| {
            tx.execute_batch(include_str!("../../../schema/media_v2.sql"))
        })?;
        self.migration("addLocalProgressV3", |tx| {
            tx.execute_batch(include_str!("../../../schema/media_v3.sql"))
        })?;
        self.migration("makeLocalProgressIndependentV4", |tx| {
            tx.execute_batch(include_str!("../../../schema/media_v4.sql"))
        })?;
        Ok(())
    }

    fn migration<F>(&self, name: &str, f: F) -> Result<(), StoreError>
    where
        F: FnOnce(&Transaction<'_>) -> Result<(), rusqlite::Error>,
    {
        let applied: Option<String> = self
            .connection
            .query_row(
                "SELECT identifier FROM grdb_migrations WHERE identifier = ?1",
                [name],
                |row| row.get(0),
            )
            .optional()?;
        if applied.is_some() {
            return Ok(());
        }
        let tx = self.connection.unchecked_transaction()?;
        f(&tx)?;
        tx.execute(
            "INSERT INTO grdb_migrations(identifier) VALUES (?1)",
            [name],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn upsert_item(&self, item: &StoredItem) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO item(tenant_id,item_id,kind,name,series_id,season_number,episode_number,played,position_seconds,fetched_at,progress_fetched_at,payload_version,payload)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10,1,?11)
             ON CONFLICT(tenant_id,item_id) DO UPDATE SET kind=excluded.kind,name=excluded.name,series_id=excluded.series_id,season_number=excluded.season_number,episode_number=excluded.episode_number,payload=excluded.payload,position_seconds=excluded.position_seconds,played=excluded.played,fetched_at=excluded.fetched_at",
            params![item.tenant_id, item.id, item.kind, item.title, item.series_id, item.season_number, item.episode_number, item.played, item.position_seconds, item.updated_at, serde_json::to_vec(&item.payload)?],
        )?;
        Ok(())
    }

    pub fn item(&self, tenant_id: &str, item_id: &str) -> Result<Option<StoredItem>, StoreError> {
        self.connection.query_row(
            "SELECT name,kind,series_id,season_number,episode_number,payload,position_seconds,played,fetched_at FROM item WHERE tenant_id=?1 AND item_id=?2",
            params![tenant_id, item_id], |row| {
                Ok(StoredItem { tenant_id: tenant_id.to_string(), id: item_id.to_string(), title: row.get(0)?, kind: row.get(1)?, overview: None, series_id: row.get(2)?, season_number: row.get(3)?, episode_number: row.get(4)?, payload: serde_json::from_slice(&row.get::<_, Vec<u8>>(5)?).unwrap_or(serde_json::Value::Null), position_seconds: row.get::<_, Option<f64>>(6)?.unwrap_or_default(), duration_seconds: None, played: row.get::<_, Option<i64>>(7)?.unwrap_or_default() != 0, updated_at: row.get(8)? })
            }).optional().map_err(StoreError::from)
    }

    pub fn save_libraries(&self, libraries: &[StoredLibrary]) -> Result<(), StoreError> {
        let tx = self.connection.unchecked_transaction()?;
        for library in libraries {
            tx.execute(
                "INSERT INTO library(tenant_id,library_id,position,fetched_at,payload) VALUES(?1,?2,?3,?4,?5)
                 ON CONFLICT(tenant_id,library_id) DO UPDATE SET position=excluded.position,fetched_at=excluded.fetched_at,payload=excluded.payload",
                params![library.tenant_id, library.id, library.position, library.fetched_at, serde_json::to_vec(&library.payload)?],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn libraries(&self, tenant_id: &str) -> Result<Vec<StoredLibrary>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT library_id,position,fetched_at,payload FROM library WHERE tenant_id=?1 ORDER BY position,library_id",
        )?;
        let rows = statement.query_map([tenant_id], |row| {
            let payload = row.get::<_, Vec<u8>>(3).unwrap_or_default();
            Ok(StoredLibrary {
                tenant_id: tenant_id.to_owned(),
                id: row.get(0)?,
                position: row.get(1)?,
                fetched_at: row.get(2)?,
                payload: serde_json::from_slice(&payload).unwrap_or(serde_json::Value::Null),
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    pub fn save_rail(&self, rail: &StoredRail) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO rail(tenant_id,rail,fetched_at,payload_version,payload) VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(tenant_id,rail) DO UPDATE SET fetched_at=excluded.fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",
            params![rail.tenant_id, rail.rail, rail.fetched_at, rail.payload_version, serde_json::to_vec(&rail.payload)?],
        )?;
        Ok(())
    }

    pub fn rail(&self, tenant_id: &str, name: &str) -> Result<Option<StoredRail>, StoreError> {
        self.connection.query_row(
            "SELECT fetched_at,payload_version,payload FROM rail WHERE tenant_id=?1 AND rail=?2",
            params![tenant_id, name],
            |row| {
                let payload = row.get::<_, Vec<u8>>(2).unwrap_or_default();
                Ok(StoredRail {
                    tenant_id: tenant_id.to_owned(),
                    rail: name.to_owned(),
                    fetched_at: row.get(0)?,
                    payload_version: row.get(1)?,
                    payload: serde_json::from_slice(&payload).unwrap_or(serde_json::Value::Null),
                })
            },
        ).optional().map_err(StoreError::from)
    }

    pub fn save_page(&self, page: &StoredPage) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO page(tenant_id,parent_id,kinds,sort_key,watch_state,search_term,start_index,limit_value,fetched_at,payload_version,payload)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(tenant_id,parent_id,kinds,sort_key,watch_state,search_term,start_index,limit_value)
             DO UPDATE SET fetched_at=excluded.fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",
            params![page.key.tenant_id, page.key.parent_id, page.key.kinds, page.key.sort_key, page.key.watch_state, page.key.search_term, page.key.start_index, page.key.limit, page.fetched_at, page.payload_version, serde_json::to_vec(&page.payload)?],
        )?;
        Ok(())
    }

    pub fn page(&self, key: &PageKey) -> Result<Option<StoredPage>, StoreError> {
        self.connection.query_row(
            "SELECT fetched_at,payload_version,payload FROM page WHERE tenant_id=?1 AND parent_id=?2 AND kinds=?3 AND sort_key=?4 AND watch_state=?5 AND search_term=?6 AND start_index=?7 AND limit_value=?8",
            params![key.tenant_id, key.parent_id, key.kinds, key.sort_key, key.watch_state, key.search_term, key.start_index, key.limit],
            |row| {
                let payload = row.get::<_, Vec<u8>>(2).unwrap_or_default();
                Ok(StoredPage {
                    key: key.clone(),
                    fetched_at: row.get(0)?,
                    payload_version: row.get(1)?,
                    payload: serde_json::from_slice(&payload).unwrap_or(serde_json::Value::Null),
                })
            },
        ).optional().map_err(StoreError::from)
    }

    pub fn save_tmdb_entity(&self, entry: &TmdbCacheEntry) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO tmdb_entity(entity_key,language,kind,tmdb_id,season_number,fetched_at,expires_at,payload_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
             ON CONFLICT(entity_key,language) DO UPDATE SET kind=excluded.kind,tmdb_id=excluded.tmdb_id,season_number=excluded.season_number,fetched_at=excluded.fetched_at,expires_at=excluded.expires_at,payload_version=excluded.payload_version,payload=excluded.payload",
            params![entry.entity_key, entry.language, entry.kind, entry.tmdb_id, entry.season_number, entry.fetched_at, entry.expires_at, entry.payload_version, serde_json::to_vec(&entry.payload)?],
        )?;
        Ok(())
    }

    pub fn tmdb_entity(
        &self,
        entity_key: &str,
        language: &str,
        now: i64,
    ) -> Result<Option<TmdbCacheEntry>, StoreError> {
        self.connection.query_row(
            "SELECT kind,tmdb_id,season_number,fetched_at,expires_at,payload_version,payload FROM tmdb_entity WHERE entity_key=?1 AND language=?2 AND expires_at>?3",
            params![entity_key, language, now],
            |row| {
                let payload = row.get::<_, Vec<u8>>(6).unwrap_or_default();
                Ok(TmdbCacheEntry {
                    entity_key: entity_key.to_owned(), language: language.to_owned(), kind: row.get(0)?, tmdb_id: row.get(1)?, season_number: row.get(2)?, fetched_at: row.get(3)?, expires_at: row.get(4)?, payload_version: row.get(5)?, payload: serde_json::from_slice(&payload).unwrap_or(serde_json::Value::Null),
                })
            },
        ).optional().map_err(StoreError::from)
    }

    pub fn save_tmdb_link(&self, link: &TmdbLink) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO tmdb_link(tenant_id,item_id,entity_key,source,confidence,linked_at) VALUES(?1,?2,?3,?4,?5,?6)
             ON CONFLICT(tenant_id,item_id) DO UPDATE SET entity_key=excluded.entity_key,source=excluded.source,confidence=excluded.confidence,linked_at=excluded.linked_at",
            params![link.tenant_id, link.item_id, link.entity_key, link.source, link.confidence, link.linked_at],
        )?;
        Ok(())
    }

    pub fn tmdb_link(
        &self,
        tenant_id: &str,
        item_id: &str,
    ) -> Result<Option<TmdbLink>, StoreError> {
        self.connection.query_row(
            "SELECT entity_key,source,confidence,linked_at FROM tmdb_link WHERE tenant_id=?1 AND item_id=?2",
            params![tenant_id, item_id],
            |row| Ok(TmdbLink { tenant_id: tenant_id.to_owned(), item_id: item_id.to_owned(), entity_key: row.get(0)?, source: row.get(1)?, confidence: row.get(2)?, linked_at: row.get(3)? }),
        ).optional().map_err(StoreError::from)
    }

    pub fn save_progress(&mut self, progress: &ProgressRecord) -> Result<(), StoreError> {
        if !progress.position_seconds.is_finite()
            || progress.position_seconds < 0.0
            || !progress.recorded_at.is_finite()
            || progress.confirmed_at.is_some_and(|v| !v.is_finite())
            || progress
                .duration_seconds
                .is_some_and(|v| !v.is_finite() || v < 0.0)
        {
            return Err(StoreError::InvalidProgress(
                "non-finite or negative playback value".into(),
            ));
        }
        let tx = self.connection.transaction()?;
        let previous: Option<(f64, Vec<u8>, i64)> = tx.query_row(
            "SELECT recorded_at,payload,payload_version FROM local_progress WHERE tenant_id=?1 AND item_id=?2",
            params![progress.tenant_id, progress.item_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).optional()?;
        if previous
            .as_ref()
            .is_some_and(|(time, _, _)| *time > progress.recorded_at)
        {
            return Ok(());
        }
        let canonical: Option<Vec<u8>> = tx
            .query_row(
                "SELECT payload FROM item WHERE tenant_id=?1 AND item_id=?2 AND payload_version=1",
                params![progress.tenant_id, progress.item_id],
                |row| row.get(0),
            )
            .optional()?;
        let mut item: serde_json::Value = if let Some(bytes) = canonical {
            serde_json::from_slice(&bytes)?
        } else if let Some((_, bytes, 1)) = previous {
            serde_json::from_slice(&bytes)?
        } else {
            progress.item.clone().unwrap_or_else(|| {
                serde_json::json!({
                    "id": progress.item_id, "name": progress.item_id, "kind": "other"
                })
            })
        };
        let Some(object) = item.as_object_mut() else {
            return Err(StoreError::InvalidProgress(
                "item payload must be an object".into(),
            ));
        };
        if object.get("id").and_then(serde_json::Value::as_str) != Some(progress.item_id.as_str()) {
            return Err(StoreError::InvalidProgress(
                "item payload identity mismatch".into(),
            ));
        }
        if let Some(duration) = progress.duration_seconds {
            object.insert("runtimeSeconds".into(), serde_json::json!(duration));
        }
        let percentage = if progress.played {
            1.0
        } else {
            progress
                .duration_seconds
                .filter(|d| *d > 0.0)
                .map(|d| (progress.position_seconds / d).clamp(0.0, 1.0))
                .unwrap_or_else(|| {
                    object
                        .get("playState")
                        .and_then(|state| state.get("percentage"))
                        .and_then(serde_json::Value::as_f64)
                        .unwrap_or_default()
                })
        };
        let mut play_state = object
            .get("playState")
            .and_then(serde_json::Value::as_object)
            .cloned()
            .unwrap_or_default();
        play_state.insert("played".into(), serde_json::json!(progress.played));
        play_state.insert(
            "positionSeconds".into(),
            serde_json::json!(progress.position_seconds),
        );
        play_state.insert("percentage".into(), serde_json::json!(percentage));
        object.insert("playState".into(), serde_json::Value::Object(play_state));
        let payload = serde_json::to_vec(&item)?;
        tx.execute(
            "INSERT INTO local_progress(tenant_id,item_id,recorded_at,confirmed_at,completed,payload_version,payload) VALUES(?1,?2,?3,?4,?5,1,?6)
             ON CONFLICT(tenant_id,item_id) DO UPDATE SET recorded_at=excluded.recorded_at,confirmed_at=excluded.confirmed_at,completed=excluded.completed,payload_version=1,payload=excluded.payload",
            params![progress.tenant_id, progress.item_id, progress.recorded_at, progress.confirmed_at, progress.completed, payload],
        )?;
        // Swift reads playState from the canonical JSON, not from projection columns.
        tx.execute("UPDATE item SET position_seconds=?3,played=?4,progress_fetched_at=?5,played_percentage=?6,payload=?7 WHERE tenant_id=?1 AND item_id=?2",
            params![progress.tenant_id, progress.item_id, progress.position_seconds, progress.played, progress.recorded_at as i64, percentage, payload])?;
        tx.commit()?;
        Ok(())
    }

    pub fn progress(
        &self,
        tenant_id: &str,
        item_id: &str,
    ) -> Result<Option<ProgressRecord>, StoreError> {
        let row: Option<(f64, Option<f64>, bool, Vec<u8>)> = self.connection.query_row(
            "SELECT recorded_at,confirmed_at,completed,payload FROM local_progress WHERE tenant_id=?1 AND item_id=?2 AND payload_version=1",
            params![tenant_id, item_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        ).optional()?;
        let Some((recorded_at, confirmed_at, completed, bytes)) = row else {
            return Ok(None);
        };
        let item: serde_json::Value = serde_json::from_slice(&bytes)?;
        let state = &item["playState"];
        Ok(Some(ProgressRecord {
            tenant_id: tenant_id.into(),
            item_id: item_id.into(),
            position_seconds: state["positionSeconds"].as_f64().unwrap_or_default(),
            duration_seconds: item["runtimeSeconds"].as_f64(),
            played: state["played"].as_bool().unwrap_or(false),
            recorded_at,
            confirmed_at,
            completed,
            item: Some(item),
        }))
    }
}

pub fn now_seconds() -> f64 {
    Utc::now().timestamp_micros() as f64 / 1_000_000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_names_and_progress_are_persistent() {
        let mut store = Store::open(":memory:").unwrap();
        let names: Vec<String> = store
            .connection()
            .prepare("SELECT identifier FROM grdb_migrations ORDER BY identifier")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(
            names,
            vec![
                "addLocalProgressV3",
                "addTMDbSchemaV2",
                "createMediaSchemaV1",
                "makeLocalProgressIndependentV4"
            ]
        );
        store
            .save_progress(&ProgressRecord {
                tenant_id: "t".into(),
                item_id: "i".into(),
                position_seconds: 12.0,
                duration_seconds: Some(100.0),
                played: false,
                recorded_at: 10.0,
                confirmed_at: None,
                completed: false,
                item: None,
            })
            .unwrap();
        store
            .save_progress(&ProgressRecord {
                tenant_id: "t".into(),
                item_id: "i".into(),
                position_seconds: 2.0,
                duration_seconds: Some(100.0),
                played: false,
                recorded_at: 9.0,
                confirmed_at: None,
                completed: false,
                item: None,
            })
            .unwrap();
        assert_eq!(
            store.progress("t", "i").unwrap().unwrap().position_seconds,
            12.0
        );
    }

    #[test]
    fn library_rail_page_and_tmdb_cache_round_trip_with_tenant_scope() {
        let store = Store::open(":memory:").unwrap();
        store
            .save_libraries(&[
                StoredLibrary {
                    tenant_id: "tenant-a".into(),
                    id: "library-1".into(),
                    position: 0,
                    payload: serde_json::json!({"name":"Movies"}),
                    fetched_at: 10,
                },
                StoredLibrary {
                    tenant_id: "tenant-b".into(),
                    id: "library-1".into(),
                    position: 0,
                    payload: serde_json::json!({"name":"Other"}),
                    fetched_at: 11,
                },
            ])
            .unwrap();
        assert_eq!(
            store.libraries("tenant-a").unwrap()[0].payload["name"],
            "Movies"
        );
        assert_eq!(
            store.libraries("tenant-b").unwrap()[0].payload["name"],
            "Other"
        );

        let rail = StoredRail {
            tenant_id: "tenant-a".into(),
            rail: "resume".into(),
            payload: serde_json::json!([{"id":"episode-1"}]),
            fetched_at: 12,
            payload_version: 1,
        };
        store.save_rail(&rail).unwrap();
        assert_eq!(store.rail("tenant-a", "resume").unwrap(), Some(rail));
        assert_eq!(store.rail("tenant-b", "resume").unwrap(), None);

        let key = PageKey {
            tenant_id: "tenant-a".into(),
            parent_id: "library-1".into(),
            kinds: "Episode".into(),
            sort_key: "SortName".into(),
            watch_state: "unplayed".into(),
            search_term: "pilot".into(),
            start_index: 0,
            limit: 50,
        };
        let page = StoredPage {
            key: key.clone(),
            payload: serde_json::json!({"items":[]}),
            fetched_at: 13,
            payload_version: 1,
        };
        store.save_page(&page).unwrap();
        assert_eq!(store.page(&key).unwrap(), Some(page));

        let entity = TmdbCacheEntry {
            entity_key: "frieren".into(),
            language: "en-US".into(),
            kind: "tv".into(),
            tmdb_id: 123,
            season_number: None,
            fetched_at: 14,
            expires_at: 100,
            payload_version: 1,
            payload: serde_json::json!({"name":"Frieren"}),
        };
        store.save_tmdb_entity(&entity).unwrap();
        assert_eq!(
            store.tmdb_entity("frieren", "en-US", 15).unwrap(),
            Some(entity.clone())
        );
        assert_eq!(store.tmdb_entity("frieren", "en-US", 100).unwrap(), None);

        let link = TmdbLink {
            tenant_id: "tenant-a".into(),
            item_id: "episode-1".into(),
            entity_key: "frieren".into(),
            source: "manual".into(),
            confidence: 1.0,
            linked_at: 16,
        };
        store.save_tmdb_link(&link).unwrap();
        assert_eq!(
            store.tmdb_link("tenant-a", "episode-1").unwrap(),
            Some(link)
        );
        assert_eq!(store.tmdb_link("tenant-b", "episode-1").unwrap(), None);
    }
}
