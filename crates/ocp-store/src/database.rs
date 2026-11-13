//! Native-compatible disposable media-cache opening, recovery and file accounting.
use crate::{Store, StoreError};
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "Media.sqlite";
pub const JOURNAL_LIMIT: i64 = 8 * 1024 * 1024;

pub struct OpenedCache {
    pub store: Store,
    pub rebuilt: bool,
    pub first_error: Option<String>,
    pub path: PathBuf,
}

fn paths(directory: &Path) -> impl Iterator<Item = PathBuf> + '_ {
    ["", "-wal", "-shm"]
        .into_iter()
        .map(|suffix| directory.join(format!("{FILE_NAME}{suffix}")))
}

/// Mirrors FileManager.removeItem: remove symlinks themselves, and remove an
/// incorrectly placed directory recursively. Individual removal failures are
/// ignored; the second open reports the actual remaining failure.
pub fn remove_files(directory: &Path) {
    for path in paths(directory) {
        if std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir()) {
            let _ = std::fs::remove_dir_all(path);
        } else {
            let _ = std::fs::remove_file(path);
        }
    }
}

pub fn total_bytes(directory: &Path) -> Result<i64, StoreError> {
    paths(directory).try_fold(0_i64, |total, path| {
        let Some(size) = std::fs::metadata(path).ok().map(|m| m.len()) else {
            return Ok(total);
        };
        total
            .checked_add(
                i64::try_from(size)
                    .map_err(|_| StoreError::InvalidRequest("database size overflow".into()))?,
            )
            .ok_or_else(|| StoreError::InvalidRequest("database size overflow".into()))
    })
}

fn attempt(directory: &Path) -> Result<Store, StoreError> {
    std::fs::create_dir_all(directory)?;
    // Pool compatibility: WAL and foreign keys are configured before migrations.
    // Only the journal size limit is best effort, just as in the native factory.
    Store::open_cache_connection(&directory.join(FILE_NAME))
}

pub fn open(directory: &Path) -> Result<OpenedCache, StoreError> {
    let path = directory.join(FILE_NAME);
    match attempt(directory) {
        Ok(store) => Ok(OpenedCache {
            store,
            rebuilt: false,
            first_error: None,
            path,
        }),
        Err(first) => {
            remove_files(directory);
            let store = attempt(directory)?;
            Ok(OpenedCache {
                store,
                rebuilt: true,
                first_error: Some(first.to_string()),
                path,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            Self(std::env::temp_dir().join(format!(
                "ocp-media-open-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            )))
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn new_cache_has_native_ledger_wal_and_journal_limit() {
        let t = Temp::new();
        let opened = open(&t.0).unwrap();
        assert!(!opened.rebuilt);
        assert!(opened.first_error.is_none());
        let db = opened.store.connection();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM grdb_migrations", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            4
        );
        assert_eq!(
            db.query_row("PRAGMA journal_mode", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "wal"
        );
        assert_eq!(
            db.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            db.query_row("PRAGMA journal_size_limit", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            JOURNAL_LIMIT
        );
    }
    #[test]
    fn corrupt_database_and_sidecars_rebuild_once() {
        let t = Temp::new();
        std::fs::create_dir_all(&t.0).unwrap();
        for path in paths(&t.0) {
            std::fs::write(path, b"corrupt cache").unwrap();
        }
        let opened = open(&t.0).unwrap();
        assert!(opened.rebuilt);
        assert!(opened.first_error.is_some());
        assert_eq!(
            opened
                .store
                .connection()
                .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
    }
    #[test]
    fn failed_migration_discards_partial_cache_but_valid_cache_is_preserved() {
        let t = Temp::new();
        std::fs::create_dir_all(&t.0).unwrap();
        let db = Connection::open(t.0.join(FILE_NAME)).unwrap();
        db.execute_batch(
            "CREATE TABLE item(wrong_schema TEXT); INSERT INTO item VALUES ('invalid');",
        )
        .unwrap();
        drop(db);
        let opened = open(&t.0).unwrap();
        assert!(opened.rebuilt);
        opened.store.connection().execute("INSERT INTO tenant(tenant_id,kind,first_seen_at,last_seen_at) VALUES ('t','jellyfin',1,1)",[]).unwrap();
        drop(opened);
        let opened = open(&t.0).unwrap();
        assert!(!opened.rebuilt);
        assert_eq!(
            opened
                .store
                .connection()
                .query_row("SELECT COUNT(*) FROM tenant", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[test]
    fn misplaced_directory_is_rebuilt_and_unrelated_files_survive() {
        let t = Temp::new();
        std::fs::create_dir_all(t.0.join(FILE_NAME).join("nested")).unwrap();
        std::fs::write(t.0.join("report.txt"), "retain").unwrap();
        let opened = open(&t.0).unwrap();
        assert!(opened.rebuilt);
        assert_eq!(
            std::fs::read_to_string(t.0.join("report.txt")).unwrap(),
            "retain"
        );
    }
    #[test]
    fn unrecoverable_parent_failure_is_returned_and_sizes_cover_sidecars() {
        let t = Temp::new();
        std::fs::create_dir_all(&t.0).unwrap();
        for (index, path) in paths(&t.0).enumerate() {
            std::fs::write(path, vec![0; index + 2]).unwrap();
        }
        assert_eq!(total_bytes(&t.0).unwrap(), 9);
        remove_files(&t.0);
        assert_eq!(total_bytes(&t.0).unwrap(), 0);
        std::fs::write(t.0.join("file"), "parent").unwrap();
        assert!(open(&t.0.join("file")).is_err());
        assert_eq!(std::fs::read_to_string(t.0.join("file")).unwrap(), "parent");
    }
}
