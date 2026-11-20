use crate::{
    parse::Parsed, Asset, Error, Item, ItemKind, Job, Library, LibraryRoot, LibraryType, Progress,
    Query, Source, SourceKind,
};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};

pub struct Store {
    pub(crate) db: Connection,
    path: PathBuf,
}

impl Store {
    pub fn open(directory: &Path) -> Result<Self, Error> {
        std::fs::create_dir_all(directory)?;
        Self::open_path(&directory.join(crate::FILE_NAME))
    }

    pub fn open_path(path: &Path) -> Result<Self, Error> {
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.pragma_update(None, "foreign_keys", true)?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 5 {
            return Err(Error::Invalid(
                "library database was created by a newer version".into(),
            ));
        }
        if version < 5 {
            // Rebuild table CHECK/UNIQUE constraints without changing child FK targets.
            db.pragma_update(None, "foreign_keys", false)?;
            let tx = rusqlite::Transaction::new_unchecked(
                &db,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            // Another handle may have migrated while this one waited for the
            // write lock. Read the version again inside the migration boundary.
            let locked_version: i64 = tx.pragma_query_value(None, "user_version", |r| r.get(0))?;
            if locked_version > 5 {
                return Err(Error::Invalid(
                    "library database was created by a newer version".into(),
                ));
            }
            if locked_version == 0 {
                tx.execute_batch(include_str!("../schema/v1.sql"))?;
            }
            if locked_version < 2 {
                tx.execute_batch(include_str!("../schema/v2.sql"))?;
            }
            if locked_version < 3 {
                tx.execute_batch(include_str!("../schema/v3.sql"))?;
            }
            if locked_version < 4 {
                tx.execute_batch(include_str!("../schema/v4.sql"))?;
                tx.pragma_update(None, "user_version", 4)?;
            }
            if locked_version < 5 {
                tx.execute_batch(include_str!("../schema/v5.sql"))?;
                tx.pragma_update(None, "user_version", 5)?;
            }
            let violations: i64 =
                tx.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| {
                    r.get(0)
                })?;
            if violations != 0 {
                return Err(Error::Invalid(
                    "library migration has invalid relationships".into(),
                ));
            }
            tx.commit()?;
            db.pragma_update(None, "foreign_keys", true)?;
        }
        Ok(Self {
            db,
            path: path.to_owned(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn sources(&self) -> Result<Vec<Source>, Error> {
        let mut q = self.db.prepare("SELECT source_id,display_name,root_path,access_ref,created_at,kind FROM source ORDER BY created_at,source_id")?;
        let rows = q
            .query_map([], |r| {
                Ok(Source {
                    source_id: r.get(0)?,
                    kind: match r.get::<_, String>(5)?.as_str() {
                        "webdav" => SourceKind::Webdav,
                        "smb" => SourceKind::Smb,
                        _ => SourceKind::LocalFolder,
                    },
                    display_name: r.get(1)?,
                    root_path: r.get(2)?,
                    access_ref: r.get(3)?,
                    created_at: r.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn source(&self, id: &str) -> Result<Source, Error> {
        self.sources()?
            .into_iter()
            .find(|s| s.source_id == id)
            .ok_or(Error::NotFound)
    }

    pub fn library_roots(
        &self,
        source_id: &str,
        library_id: &str,
    ) -> Result<Vec<LibraryRoot>, Error> {
        let mut q = self.db.prepare(
            "SELECT root_id,root_path,access_ref FROM library_root WHERE source_id=?1 AND library_id=?2 ORDER BY created_at,root_id",
        )?;
        let rows = q
            .query_map(params![source_id, library_id], |r| {
                Ok(LibraryRoot {
                    root_id: r.get(0)?,
                    root_path: r.get(1)?,
                    access_ref: r.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn hydrate_library(&self, mut library: Library) -> Result<Library, Error> {
        library.roots = self.library_roots(&library.source_id, &library.library_id)?;
        Ok(library)
    }

    pub fn libraries(&self, source_id: &str) -> Result<Vec<Library>, Error> {
        self.source(source_id)?;
        let mut q = self.db.prepare("SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE source_id=?1 ORDER BY created_at,library_id")?;
        let rows = q
            .query_map([source_id], read_library)?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter().map(|l| self.hydrate_library(l)).collect()
    }

    pub fn library(&self, source_id: &str, library_id: &str) -> Result<Library, Error> {
        let library = self
            .db
            .query_row(
                "SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE source_id=?1 AND library_id=?2",
                params![source_id, library_id],
                read_library,
            )
            .optional()?
            .ok_or(Error::NotFound)?;
        self.hydrate_library(library)
    }

    pub fn created_draft(&self, draft_id: &str) -> Result<Option<Library>, Error> {
        let library = self
            .db
            .query_row(
                "SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE draft_id=?1",
                [draft_id],
                read_library,
            )
            .optional()?;
        library.map(|l| self.hydrate_library(l)).transpose()
    }

    /// Called only after the runtime verifies the TMDB receipt and host access lease.
    pub fn create_local(
        &self,
        draft_id: &str,
        existing_source: Option<&str>,
        source_name: &str,
        source_root: &Path,
        access_ref: Option<&str>,
        name: &str,
        root: &Path,
        typ: LibraryType,
    ) -> Result<Library, Error> {
        if !root.is_absolute() || !source_root.is_absolute() || !root.starts_with(source_root) {
            return Err(Error::Invalid(
                "library root must be inside the authorized source root".into(),
            ));
        }
        self.create_file_source(
            draft_id,
            existing_source,
            source_name,
            &source_root.to_string_lossy(),
            access_ref,
            name,
            &root.to_string_lossy(),
            typ,
            SourceKind::LocalFolder,
        )
    }

    pub fn create_webdav(
        &self,
        draft_id: &str,
        existing_source: Option<&str>,
        source_name: &str,
        source_root: &str,
        access_ref: Option<&str>,
        name: &str,
        root: &str,
        typ: LibraryType,
    ) -> Result<Library, Error> {
        let source_root =
            ocp_webdav::root_url(source_root).map_err(|e| Error::Invalid(e.to_string()))?;
        let root = ocp_webdav::root_url(root).map_err(|e| Error::Invalid(e.to_string()))?;
        if !ocp_webdav::within(source_root.as_str(), root.as_str()) {
            return Err(Error::Invalid(
                "category is outside WebDAV source root".into(),
            ));
        }
        self.create_file_source(
            draft_id,
            existing_source,
            source_name,
            source_root.as_str(),
            access_ref,
            name,
            root.as_str(),
            typ,
            SourceKind::Webdav,
        )
    }

    pub fn create_smb(
        &self,
        draft_id: &str,
        existing_source: Option<&str>,
        source_name: &str,
        source_root: &str,
        access_ref: Option<&str>,
        name: &str,
        root: &str,
        typ: LibraryType,
    ) -> Result<Library, Error> {
        let source_root =
            ocp_smb::root_url(source_root).map_err(|e| Error::Invalid(e.to_string()))?;
        let root = ocp_smb::root_url(root).map_err(|e| Error::Invalid(e.to_string()))?;
        if !ocp_smb::within(source_root.as_str(), root.as_str()) {
            return Err(Error::Invalid("category is outside SMB source root".into()));
        }
        self.create_file_source(
            draft_id,
            existing_source,
            source_name,
            source_root.as_str(),
            access_ref,
            name,
            root.as_str(),
            typ,
            SourceKind::Smb,
        )
    }

    fn create_file_source(
        &self,
        draft_id: &str,
        existing_source: Option<&str>,
        source_name: &str,
        source_root: &str,
        access_ref: Option<&str>,
        name: &str,
        root: &str,
        typ: LibraryType,
        kind: SourceKind,
    ) -> Result<Library, Error> {
        for value in [draft_id, source_name, name] {
            if value.trim().is_empty() || value.contains('\0') {
                return Err(Error::Invalid(
                    "names and draftId must be nonempty without NUL".into(),
                ));
            }
        }
        if let Some(previous) = self.created_draft(draft_id)? {
            if previous.root_path != root
                || previous.library_type != typ
                || previous.name != name
                || existing_source.is_some_and(|id| id != previous.source_id)
            {
                return Err(Error::Invalid(
                    "draftId has already been used with different inputs".into(),
                ));
            }
            let source = self.source(&previous.source_id)?;
            if source.kind != kind
                || (kind != SourceKind::LocalFolder && source.root_path != source_root)
            {
                return Err(Error::Invalid("draft belongs to a different source".into()));
            }
            return Ok(previous);
        }
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let source_id = if let Some(id) = existing_source {
            let stored_root: String = tx
                .query_row(
                    "SELECT root_path FROM source WHERE source_id=?1",
                    [id],
                    |r| r.get(0),
                )
                .optional()?
                .ok_or(Error::NotFound)?;
            let stored_kind: String =
                tx.query_row("SELECT kind FROM source WHERE source_id=?1", [id], |r| {
                    r.get(0)
                })?;
            if stored_kind != kind.as_str()
                || (kind != SourceKind::LocalFolder && stored_root != source_root)
            {
                return Err(Error::Invalid(
                    "access lease belongs to a different source root".into(),
                ));
            }
            check_no_root_overlap(&tx, id, kind, root)?;
            id.to_owned()
        } else {
            let id = crate::id();
            tx.execute(
                "INSERT INTO source VALUES(?1,?6,?2,?3,?4,?5)",
                params![
                    id,
                    source_name,
                    source_root,
                    access_ref,
                    crate::now(),
                    kind.as_str()
                ],
            )?;
            id
        };
        let library_id = crate::id();
        let created_at = crate::now();
        let primary_root = LibraryRoot {
            root_id: library_id.clone(),
            root_path: root.to_owned(),
            access_ref: access_ref.map(str::to_owned),
        };
        let library = Library {
            library_id: library_id.clone(),
            source_id,
            name: name.into(),
            root_path: root.to_owned(),
            library_type: typ,
            revision: 1,
            created_at,
            roots: vec![primary_root.clone()],
        };
        tx.execute("INSERT INTO library(library_id,source_id,name,root_path,type,revision,created_at,draft_id) VALUES(?1,?2,?3,?4,?5,1,?6,?7)",
            params![library.library_id, library.source_id, name, library.root_path, typ.as_str(), library.created_at, draft_id])?;
        tx.execute(
            "INSERT INTO library_root(root_id,source_id,library_id,root_path,access_ref,created_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![
                primary_root.root_id,
                library.source_id,
                library.library_id,
                primary_root.root_path,
                primary_root.access_ref,
                created_at
            ],
        )?;
        tx.commit()?;
        Ok(library)
    }

    pub fn add_local_root(
        &self,
        source_id: &str,
        library_id: &str,
        source_root: &Path,
        access_ref: Option<&str>,
        root: &Path,
    ) -> Result<(Library, LibraryRoot), Error> {
        if !root.is_absolute() || !source_root.is_absolute() || !root.starts_with(source_root) {
            return Err(Error::Invalid(
                "library root must be inside the authorized source root".into(),
            ));
        }
        self.add_root_inner(
            source_id,
            library_id,
            SourceKind::LocalFolder,
            &source_root.to_string_lossy(),
            access_ref,
            &root.to_string_lossy(),
        )
    }

    pub fn add_webdav_root(
        &self,
        source_id: &str,
        library_id: &str,
        source_root: &str,
        access_ref: Option<&str>,
        root: &str,
    ) -> Result<(Library, LibraryRoot), Error> {
        let source_root =
            ocp_webdav::root_url(source_root).map_err(|e| Error::Invalid(e.to_string()))?;
        let root = ocp_webdav::root_url(root).map_err(|e| Error::Invalid(e.to_string()))?;
        if !ocp_webdav::within(source_root.as_str(), root.as_str()) {
            return Err(Error::Invalid(
                "category is outside WebDAV source root".into(),
            ));
        }
        self.add_root_inner(
            source_id,
            library_id,
            SourceKind::Webdav,
            source_root.as_str(),
            access_ref,
            root.as_str(),
        )
    }

    pub fn add_smb_root(
        &self,
        source_id: &str,
        library_id: &str,
        source_root: &str,
        access_ref: Option<&str>,
        root: &str,
    ) -> Result<(Library, LibraryRoot), Error> {
        let source_root =
            ocp_smb::root_url(source_root).map_err(|e| Error::Invalid(e.to_string()))?;
        let root = ocp_smb::root_url(root).map_err(|e| Error::Invalid(e.to_string()))?;
        if !ocp_smb::within(source_root.as_str(), root.as_str()) {
            return Err(Error::Invalid("category is outside SMB source root".into()));
        }
        self.add_root_inner(
            source_id,
            library_id,
            SourceKind::Smb,
            source_root.as_str(),
            access_ref,
            root.as_str(),
        )
    }

    fn add_root_inner(
        &self,
        source_id: &str,
        library_id: &str,
        kind: SourceKind,
        source_root: &str,
        access_ref: Option<&str>,
        root: &str,
    ) -> Result<(Library, LibraryRoot), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let (stored_root, stored_kind): (String, String) = tx
            .query_row(
                "SELECT root_path,kind FROM source WHERE source_id=?1",
                [source_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .ok_or(Error::NotFound)?;
        if stored_kind != kind.as_str()
            || (kind != SourceKind::LocalFolder && stored_root != source_root)
        {
            return Err(Error::Invalid(
                "access lease belongs to a different source root".into(),
            ));
        }
        let exists: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM library WHERE source_id=?1 AND library_id=?2",
                params![source_id, library_id],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(Error::NotFound);
        }
        check_no_root_overlap(&tx, source_id, kind, root)?;
        let added = LibraryRoot {
            root_id: crate::id(),
            root_path: root.to_owned(),
            access_ref: access_ref.map(str::to_owned),
        };
        let created_at = crate::now();
        tx.execute(
            "INSERT INTO library_root(root_id,source_id,library_id,root_path,access_ref,created_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![
                added.root_id,
                source_id,
                library_id,
                added.root_path,
                added.access_ref,
                created_at
            ],
        )?;
        tx.execute(
            "UPDATE library SET revision=revision+1 WHERE source_id=?1 AND library_id=?2",
            params![source_id, library_id],
        )?;
        tx.commit()?;
        Ok((self.library(source_id, library_id)?, added))
    }

    pub fn rename_library(
        &self,
        source_id: &str,
        library_id: &str,
        name: &str,
    ) -> Result<Library, Error> {
        let trimmed = name.trim();
        if trimmed.is_empty() || trimmed.contains('\0') {
            return Err(Error::Invalid(
                "library name must be nonempty without NUL".into(),
            ));
        }
        let changed = self.db.execute(
            "UPDATE library SET name=?3,revision=revision+1 WHERE source_id=?1 AND library_id=?2",
            params![source_id, library_id, trimmed],
        )?;
        if changed == 0 {
            return Err(Error::NotFound);
        }
        self.library(source_id, library_id)
    }

    pub fn delete_library(&self, source_id: &str, library_id: &str) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let exists: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM library WHERE source_id=?1 AND library_id=?2",
                params![source_id, library_id],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(Error::NotFound);
        }
        delete_library_tx(&tx, source_id, library_id)?;
        tx.commit()?;
        Ok(())
    }

    pub fn remove_library_root(
        &self,
        source_id: &str,
        library_id: &str,
        root_id: &str,
    ) -> Result<Library, Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let current_primary: String = tx
            .query_row(
                "SELECT root_path FROM library WHERE source_id=?1 AND library_id=?2",
                params![source_id, library_id],
                |r| r.get(0),
            )
            .optional()?
            .ok_or(Error::NotFound)?;
        let mut q = tx.prepare(
            "SELECT root_id,root_path FROM library_root WHERE source_id=?1 AND library_id=?2 ORDER BY created_at,root_id",
        )?;
        let roots: Vec<(String, String)> = q
            .query_map(params![source_id, library_id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(q);
        let Some((_, removed_path)) = roots.iter().find(|(id, _)| id == root_id) else {
            return Err(Error::NotFound);
        };
        if roots.len() <= 1 {
            return Err(Error::Invalid(
                "cannot remove the only folder of a category; delete the category instead".into(),
            ));
        }

        // Remove scan checkpoints and file entries belonging to this root.
        tx.execute("DELETE FROM job_directory WHERE root_id=?1", [root_id])?;
        tx.execute(
            "DELETE FROM item_asset WHERE source_id=?1 AND library_id=?2 AND asset_id IN (SELECT asset_id FROM entry WHERE source_id=?1 AND library_id=?2 AND root_id=?3)",
            params![source_id, library_id, root_id],
        )?;
        tx.execute(
            "DELETE FROM entry WHERE source_id=?1 AND library_id=?2 AND root_id=?3",
            params![source_id, library_id, root_id],
        )?;

        // Prune orphaned leaf catalog items (movie / episode / unidentified with no assets left).
        prune_orphan_items_tx(
            &tx,
            source_id,
            library_id,
            "SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2 AND kind IN ('movie','episode','unidentified') AND NOT EXISTS (SELECT 1 FROM item_asset a WHERE a.source_id=catalog_item.source_id AND a.item_id=catalog_item.item_id)",
        )?;
        // Prune empty seasons then empty series.
        prune_orphan_items_tx(
            &tx,
            source_id,
            library_id,
            "SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2 AND kind='season' AND NOT EXISTS (SELECT 1 FROM catalog_item ch WHERE ch.source_id=catalog_item.source_id AND ch.parent_id=catalog_item.item_id)",
        )?;
        prune_orphan_items_tx(
            &tx,
            source_id,
            library_id,
            "SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2 AND kind='series' AND NOT EXISTS (SELECT 1 FROM catalog_item ch WHERE ch.source_id=catalog_item.source_id AND ch.parent_id=catalog_item.item_id)",
        )?;

        tx.execute(
            "DELETE FROM library_root WHERE source_id=?1 AND library_id=?2 AND root_id=?3",
            params![source_id, library_id, root_id],
        )?;
        let next_primary = if current_primary == *removed_path {
            roots
                .iter()
                .find(|(id, _)| id != root_id)
                .map(|(_, path)| path.clone())
                .unwrap_or(current_primary)
        } else {
            current_primary
        };
        tx.execute(
            "UPDATE library SET root_path=?3,revision=revision+1 WHERE source_id=?1 AND library_id=?2",
            params![source_id, library_id, next_primary],
        )?;
        tx.commit()?;
        self.library(source_id, library_id)
    }

    pub fn delete_source(&self, source_id: &str) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let exists: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM source WHERE source_id=?1",
                [source_id],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(Error::NotFound);
        }
        let mut q = tx.prepare("SELECT library_id FROM library WHERE source_id=?1")?;
        let library_ids: Vec<String> = q
            .query_map([source_id], |r| r.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        drop(q);
        for library_id in library_ids {
            delete_library_tx(&tx, source_id, &library_id)?;
        }
        tx.execute("DELETE FROM source WHERE source_id=?1", [source_id])?;
        tx.commit()?;
        Ok(())
    }

    pub fn start_scan(&self, source_id: &str, library_id: &str) -> Result<Job, Error> {
        let library = self.library(source_id, library_id)?;
        let active: Option<String> = self.db.query_row("SELECT job_id FROM job WHERE library_id=?1 AND status IN ('queued','enumerating','paused','interrupted','waitingPermission','waitingCredentials','waitingNetwork') ORDER BY generation DESC LIMIT 1", [library_id], |r| r.get(0)).optional()?;
        if let Some(id) = active {
            let tx = rusqlite::Transaction::new_unchecked(
                &self.db,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            for root in &library.roots {
                let present: i64 = tx.query_row(
                    "SELECT COUNT(*) FROM job_directory WHERE job_id=?1 AND root_id=?2",
                    params![id, root.root_id],
                    |r| r.get(0),
                )?;
                if present == 0 {
                    tx.execute(
                        "INSERT OR IGNORE INTO job_directory(job_id,root_id,relative_path,done) VALUES(?1,?2,'',0)",
                        params![id, root.root_id],
                    )?;
                }
            }
            tx.commit()?;
            return self.job(source_id, &id);
        }
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let generation: i64 = tx.query_row(
            "SELECT COALESCE(MAX(generation),0)+1 FROM job WHERE library_id=?1",
            [library_id],
            |r| r.get(0),
        )?;
        let id = crate::id();
        tx.execute("INSERT INTO job(job_id,source_id,library_id,generation,status,created_at) VALUES(?1,?2,?3,?4,'queued',?5)", params![id, source_id, library_id, generation, crate::now()])?;
        for root in &library.roots {
            tx.execute(
                "INSERT INTO job_directory(job_id,root_id,relative_path,done) VALUES(?1,?2,'',0)",
                params![id, root.root_id],
            )?;
        }
        tx.commit()?;
        self.job(source_id, &id)
    }

    pub fn queued_jobs(&self, limit: i64) -> Result<Vec<Job>, Error> {
        let mut q = self.db.prepare(
            "SELECT source_id,job_id FROM job WHERE status='queued' ORDER BY created_at,job_id LIMIT ?1",
        )?;
        let pairs = q
            .query_map([limit], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        pairs
            .iter()
            .map(|(source_id, job_id)| self.job(source_id, job_id))
            .collect()
    }

    pub fn initial_scan(&self, source_id: &str, library_id: &str) -> Result<Option<Job>, Error> {
        let id:Option<String>=self.db.query_row("SELECT job_id FROM job WHERE source_id=?1 AND library_id=?2 ORDER BY generation LIMIT 1",params![source_id,library_id],|r|r.get(0)).optional()?;
        id.map(|id| self.job(source_id, &id)).transpose()
    }

    pub fn job(&self, source_id: &str, job_id: &str) -> Result<Job, Error> {
        self.db.query_row("SELECT job_id,source_id,library_id,generation,status,files_found,directories_done,error_count,last_error FROM job WHERE source_id=?1 AND job_id=?2", params![source_id, job_id], |r| Ok(Job {
            job_id: r.get(0)?, source_id: r.get(1)?, library_id: r.get(2)?, generation: r.get(3)?, status: r.get(4)?,
            files_found: r.get(5)?, directories_done: r.get(6)?, error_count: r.get(7)?, last_error: r.get(8)?,
        })).optional()?.ok_or(Error::NotFound)
    }

    pub fn jobs(&self, source_id: &str) -> Result<Vec<Job>, Error> {
        self.source(source_id)?;
        let mut q = self.db.prepare(
            "SELECT job_id FROM job WHERE source_id=?1 ORDER BY created_at DESC,job_id LIMIT 100",
        )?;
        let ids = q
            .query_map([source_id], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        ids.iter().map(|id| self.job(source_id, id)).collect()
    }

    pub fn recover_jobs(&self) -> Result<(), Error> {
        self.db.execute(
            "UPDATE job SET status='interrupted' WHERE status IN ('queued','enumerating')",
            [],
        )?;
        Ok(())
    }

    pub fn set_job_status(&self, job_id: &str, status: &str) -> Result<(), Error> {
        self.db.execute(
            "UPDATE job SET status=?2 WHERE job_id=?1",
            params![job_id, status],
        )?;
        Ok(())
    }

    pub fn next_directory(&self, job_id: &str) -> Result<Option<(String, String)>, Error> {
        Ok(self
            .db
            .query_row(
                "SELECT root_id,relative_path FROM job_directory WHERE job_id=?1 AND done=0 ORDER BY root_id,relative_path LIMIT 1",
                [job_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?)
    }

    pub fn add_directory(&self, job_id: &str, root_id: &str, relative: &str) -> Result<(), Error> {
        self.db.execute(
            "INSERT OR IGNORE INTO job_directory(job_id,root_id,relative_path,done) VALUES(?1,?2,?3,0)",
            params![job_id, root_id, relative],
        )?;
        Ok(())
    }

    pub fn directory_done(&self, job_id: &str, root_id: &str, relative: &str) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let changed = tx.execute(
            "UPDATE job_directory SET done=1 WHERE job_id=?1 AND root_id=?2 AND relative_path=?3 AND done=0",
            params![job_id, root_id, relative],
        )?;
        tx.execute(
            "UPDATE job SET directories_done=directories_done+?2 WHERE job_id=?1",
            params![job_id, changed],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn scan_error(&self, job_id: &str, message: &str) -> Result<(), Error> {
        self.db.execute(
            "UPDATE job SET error_count=error_count+1,last_error=?2 WHERE job_id=?1",
            params![job_id, message],
        )?;
        Ok(())
    }

    pub fn finish_scan(&self, job: &Job) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        require_current_generation(&tx, job)?;
        let failures: i64 = tx.query_row(
            "SELECT error_count FROM job WHERE job_id=?1",
            [&job.job_id],
            |r| r.get(0),
        )?;
        if failures == 0 {
            tx.execute("UPDATE entry SET available=0 WHERE source_id=?1 AND library_id=?2 AND seen_generation<>?3", params![job.source_id,job.library_id,job.generation])?;
        }
        tx.execute(
            "UPDATE job SET status=?2 WHERE job_id=?1",
            params![
                job.job_id,
                if failures == 0 {
                    "completed"
                } else {
                    "partialFailure"
                }
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn ingest(
        &self,
        job: &Job,
        relative: &str,
        size: i64,
        mtime: f64,
        parsed: &Parsed,
    ) -> Result<(), Error> {
        self.ingest_remote_for_root(job, &job.library_id, relative, size, mtime, None, parsed)
    }

    pub fn ingest_for_root(
        &self,
        job: &Job,
        root_id: &str,
        relative: &str,
        size: i64,
        mtime: f64,
        parsed: &Parsed,
    ) -> Result<(), Error> {
        self.ingest_remote_for_root(job, root_id, relative, size, mtime, None, parsed)
    }

    pub fn ingest_remote(
        &self,
        job: &Job,
        relative: &str,
        size: i64,
        mtime: f64,
        etag: Option<&str>,
        parsed: &Parsed,
    ) -> Result<(), Error> {
        self.ingest_remote_for_root(job, &job.library_id, relative, size, mtime, etag, parsed)
    }

    pub fn ingest_remote_for_root(
        &self,
        job: &Job,
        root_id: &str,
        relative: &str,
        size: i64,
        mtime: f64,
        etag: Option<&str>,
        parsed: &Parsed,
    ) -> Result<(), Error> {
        let library = self.library(&job.source_id, &job.library_id)?;
        if (library.library_type == LibraryType::Movies && parsed.kind != ItemKind::Movie)
            || (library.library_type == LibraryType::Tvshows
                && !matches!(parsed.kind, ItemKind::Episode | ItemKind::Unidentified))
        {
            return Err(Error::Invalid(
                "parsed file category conflicts with library type".into(),
            ));
        }
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        require_current_generation(&tx, job)?;
        let existing: Option<(String, i64)> = tx
            .query_row(
                "SELECT asset_id,seen_generation FROM entry WHERE source_id=?1 AND library_id=?2 AND root_id=?3 AND relative_path=?4",
                params![job.source_id, job.library_id, root_id, relative],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let asset_id = existing
            .as_ref()
            .map(|e| e.0.clone())
            .unwrap_or_else(crate::id);
        tx.execute(
            "INSERT INTO entry(source_id,asset_id,library_id,root_id,relative_path,size,mtime,seen_generation,etag) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(source_id,library_id,root_id,relative_path) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,etag=excluded.etag,available=1,seen_generation=excluded.seen_generation",
            params![
                job.source_id,
                asset_id,
                job.library_id,
                root_id,
                relative,
                size,
                mtime,
                job.generation,
                etag
            ],
        )?;
        let upsert = |key: &str,
                      kind: ItemKind,
                      name: &str,
                      parent: Option<&str>,
                      series: Option<&str>,
                      season: Option<i64>,
                      episode: Option<i64>|
         -> Result<String, Error> {
            let previous: Option<String> = tx.query_row("SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2 AND group_key=?3", params![job.source_id,job.library_id,key], |r| r.get(0)).optional()?;
            let id = previous.unwrap_or_else(crate::id);
            tx.execute("INSERT INTO catalog_item(source_id,library_id,item_id,group_key,kind,title,year,parent_id,series_id,season_number,episode_number,first_seen_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT(source_id,library_id,group_key) DO UPDATE SET title=excluded.title,year=excluded.year",
                params![job.source_id,job.library_id,id,key,kind.as_str(),name,parsed.year,parent,series,season,episode,crate::now()])?;
            Ok(id)
        };
        let item_id = if parsed.kind == ItemKind::Episode {
            let series_name = parsed
                .series_title
                .as_deref()
                .ok_or_else(|| Error::Invalid("episode has no series".into()))?;
            let series_group = parsed
                .series_group
                .as_deref()
                .ok_or_else(|| Error::Invalid("episode has no structural series group".into()))?;
            let series_key = format!("series:{series_group}");
            let series = upsert(
                &series_key,
                ItemKind::Series,
                series_name,
                None,
                None,
                None,
                None,
            )?;
            let season_number = parsed
                .season
                .ok_or_else(|| Error::Invalid("episode has no season".into()))?;
            let season_key = format!("{series_key}:season:{season_number}");
            let season = upsert(
                &season_key,
                ItemKind::Season,
                &format!("Season {season_number}"),
                Some(&series),
                Some(&series),
                Some(season_number),
                None,
            )?;
            let episode_number = parsed
                .episode
                .ok_or_else(|| Error::Invalid("episode has no number".into()))?;
            upsert(
                &format!("{season_key}:episode:{episode_number}"),
                ItemKind::Episode,
                &parsed.title,
                Some(&season),
                Some(&series),
                Some(season_number),
                Some(episode_number),
            )?
        } else {
            upsert(
                &format!("asset:{asset_id}"),
                parsed.kind,
                &parsed.title,
                None,
                None,
                None,
                None,
            )?
        };
        tx.execute(
            "INSERT OR IGNORE INTO item_asset VALUES(?1,?2,?3,?4)",
            params![job.source_id, job.library_id, item_id, asset_id],
        )?;
        if existing.is_none_or(|e| e.1 != job.generation) {
            tx.execute(
                "UPDATE job SET files_found=files_found+1 WHERE job_id=?1",
                [&job.job_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn query(&self, input: &Query) -> Result<(Vec<Item>, i64), Error> {
        if input.source_id.is_empty() || input.start_index < 0 || !(1..=500).contains(&input.limit)
        {
            return Err(Error::Invalid(
                "sourceId is required; startIndex >= 0, limit in 1...500".into(),
            ));
        }
        let watch_state = match input.watch_state.as_deref() {
            None | Some("") | Some("all") => None,
            Some("played") => Some(true),
            Some("unplayed") => Some(false),
            Some(other) => {
                return Err(Error::Invalid(format!("unsupported watchState: {other}")));
            }
        };
        let sort_field = match input.sort_by.as_deref() {
            None | Some("") if input.parent_id.is_some() => "childOrder",
            None | Some("") | Some("name") => "name",
            Some("dateAdded") => "dateAdded",
            Some("year") => "year",
            Some("rating") => "rating",
            Some(other) => {
                return Err(Error::Invalid(format!("unsupported sortBy: {other}")));
            }
        };
        let ascending = input.sort_ascending.unwrap_or(true);

        self.source(&input.source_id)?;
        if let Some(id) = &input.library_id {
            self.library(&input.source_id, id)?;
        }

        let mut merged: Vec<Item> = if let Some(parent_id) = &input.parent_id {
            self.item(&input.source_id, parent_id)?;
            let parent_group = self.equivalent_item_ids(&input.source_id, parent_id)?;
            let mut raw = Vec::new();
            let sql = format!(
                "{ITEM_SELECT} JOIN library l ON l.library_id=c.library_id WHERE c.source_id=?1 AND (?2 IS NULL OR l.type=?2) AND c.parent_id=?3 AND (?4='' OR instr(lower(c.title),lower(?4))>0 OR instr(lower(COALESCE(json_extract(m.metadata,'$.title'),json_extract(m.metadata,'$.name'),json_extract(d.metadata,'$.name'),'')),lower(?4))>0) ORDER BY c.season_number,c.episode_number,c.first_seen_at,c.item_id"
            );
            let mut q = self.db.prepare(&sql)?;
            for pid in &parent_group {
                let rows = q
                    .query_map(
                        params![
                            input.source_id,
                            input.library_type.map(LibraryType::as_str),
                            pid,
                            input.search
                        ],
                        read_item,
                    )?
                    .collect::<Result<Vec<_>, _>>()?;
                raw.extend(rows);
            }
            drop(q);
            self.merge_child_items(&input.source_id, raw)?
        } else {
            let sql = format!(
                "{ITEM_SELECT} JOIN library l ON l.library_id=c.library_id WHERE c.source_id=?1 AND (?2 IS NULL OR c.library_id=?2) AND (?3 IS NULL OR l.type=?3) AND c.parent_id IS NULL AND (?4='' OR instr(lower(c.title),lower(?4))>0 OR instr(lower(COALESCE(json_extract(m.metadata,'$.title'),json_extract(m.metadata,'$.name'),json_extract(d.metadata,'$.name'),'')),lower(?4))>0) ORDER BY c.first_seen_at ASC,c.item_id ASC"
            );
            let mut q = self.db.prepare(&sql)?;
            let raw = q
                .query_map(
                    params![
                        input.source_id,
                        input.library_id,
                        input.library_type.map(LibraryType::as_str),
                        input.search
                    ],
                    read_item,
                )?
                .collect::<Result<Vec<_>, _>>()?;
            drop(q);
            self.merge_top_level_items(&input.source_id, raw)?
        };

        if let Some(want_played) = watch_state {
            let mut filtered = Vec::with_capacity(merged.len());
            for item in merged {
                let is_played = if item.kind == ItemKind::Series {
                    let group = self.equivalent_item_ids(&input.source_id, &item.item_id)?;
                    let (total_eps, unplayed_eps) =
                        self.series_episode_watch_counts(&input.source_id, &group)?;
                    if want_played {
                        total_eps > 0 && unplayed_eps == 0
                    } else {
                        unplayed_eps > 0
                    }
                } else {
                    let leaf_played = item
                        .progress
                        .as_ref()
                        .is_some_and(|p| p.played || p.completed);
                    leaf_played == want_played
                };
                if is_played {
                    filtered.push(item);
                }
            }
            merged = filtered;
        }

        sort_items(&mut merged, sort_field, ascending);
        let total = merged.len() as i64;
        let start = (input.start_index as usize).min(merged.len());
        let end = start.saturating_add(input.limit as usize).min(merged.len());
        Ok((merged[start..end].to_vec(), total))
    }

    /// Resume contains playable leaves (including episodes), scoped to one source.
    pub fn resume(&self, source_id: &str, limit: i64) -> Result<Vec<Item>, Error> {
        self.source(source_id)?;
        if !(1..=100).contains(&limit) {
            return Err(Error::Invalid("resume limit must be in 1...100".into()));
        }
        let sql = format!("{ITEM_SELECT} WHERE c.source_id=?1 AND ws.position_seconds>0 AND ws.played=0 AND ws.completed=0 AND EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND a.item_id=c.item_id AND e.available=1) ORDER BY ws.recorded_at DESC,c.item_id");
        let mut q = self.db.prepare(&sql)?;
        let raw = q
            .query_map(params![source_id], read_item)?
            .collect::<Result<Vec<_>, _>>()?;
        drop(q);
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        for item in raw {
            if out.len() >= limit as usize {
                break;
            }
            let key = self.canonical_leaf_key(source_id, &item)?;
            if seen.insert(key) {
                out.push(item);
            }
        }
        Ok(out)
    }

    /// Next up returns the next unwatched regular episode after the most recently
    /// completed episode per series, excluding series currently in resume.
    pub fn next_up(&self, source_id: &str, limit: i64) -> Result<Vec<Item>, Error> {
        self.source(source_id)?;
        if !(1..=100).contains(&limit) {
            return Err(Error::Invalid("nextUp limit must be in 1...100".into()));
        }
        let mut series_q = self.db.prepare(
            "SELECT ep.series_id FROM watch_state w JOIN catalog_item ep ON ep.source_id=w.source_id AND ep.item_id=w.item_id WHERE w.source_id=?1 AND ep.kind='episode' AND ep.series_id IS NOT NULL GROUP BY ep.series_id ORDER BY MAX(w.recorded_at) DESC",
        )?;
        let series_ids = series_q
            .query_map([source_id], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        drop(series_q);
        let mut ep_q = self.db.prepare(&format!(
            "{ITEM_SELECT} WHERE c.source_id=?1 AND c.series_id=?2 AND c.kind='episode' AND COALESCE(c.season_number,0)>0 AND EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND a.item_id=c.item_id AND e.available=1) ORDER BY c.season_number ASC,c.episode_number ASC,c.item_id ASC"
        ))?;
        let mut visited_series = std::collections::HashSet::new();
        let mut out = Vec::new();
        for series_id in series_ids {
            if out.len() >= limit as usize {
                break;
            }
            if !visited_series.insert(series_id.clone()) {
                continue;
            }
            let group = self.equivalent_item_ids(source_id, &series_id)?;
            for id in &group {
                visited_series.insert(id.clone());
            }
            let mut raw_episodes = Vec::new();
            for sid in &group {
                let rows = ep_q
                    .query_map(params![source_id, sid], read_item)?
                    .collect::<Result<Vec<_>, _>>()?;
                raw_episodes.extend(rows);
            }
            let episodes = self.merge_child_items(source_id, raw_episodes)?;
            if episodes.iter().any(|ep| {
                ep.progress
                    .as_ref()
                    .is_some_and(|p| p.position_seconds > 0.0 && !p.played && !p.completed)
            }) {
                continue;
            }
            let Some(last_watched) = episodes.iter().rposition(|ep| {
                ep.progress
                    .as_ref()
                    .is_some_and(|p| p.played || p.completed)
            }) else {
                continue;
            };
            if let Some(next) = episodes.into_iter().skip(last_watched + 1).find(|ep| {
                !ep.progress
                    .as_ref()
                    .is_some_and(|p| p.played || p.completed)
            }) {
                out.push(next);
            }
        }
        Ok(out)
    }

    pub fn mark_played(
        &self,
        source_id: &str,
        item_id: &str,
        played: bool,
        recorded_at: f64,
    ) -> Result<Progress, Error> {
        let item = self.item(source_id, item_id)?;
        if !matches!(
            item.kind,
            ItemKind::Movie | ItemKind::Episode | ItemKind::Unidentified
        ) {
            return Err(Error::Invalid(
                "played state must belong to a playable leaf".into(),
            ));
        }
        if !recorded_at.is_finite() {
            return Err(Error::Invalid("invalid recorded timestamp".into()));
        }
        let group = self.equivalent_item_ids(source_id, item_id)?;
        let existing = self.progress(source_id, item_id)?;
        let duration_seconds = existing.as_ref().and_then(|p| p.duration_seconds);
        let effective_at = existing
            .as_ref()
            .map_or(recorded_at, |p| recorded_at.max(p.recorded_at + 0.001));
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        for target_id in &group {
            tx.execute(
                "INSERT INTO watch_state VALUES(?1,?2,0.0,?3,?4,?5,?6) ON CONFLICT(source_id,item_id) DO UPDATE SET position_seconds=0.0,duration_seconds=excluded.duration_seconds,played=excluded.played,completed=excluded.completed,recorded_at=excluded.recorded_at",
                params![
                    source_id,
                    target_id,
                    duration_seconds,
                    played,
                    played,
                    effective_at
                ],
            )?;
        }
        tx.commit()?;
        Ok(Progress {
            source_id: source_id.into(),
            item_id: item_id.into(),
            position_seconds: 0.0,
            duration_seconds,
            played,
            completed: played,
            recorded_at: effective_at,
        })
    }

    pub fn item(&self, source_id: &str, item_id: &str) -> Result<Item, Error> {
        let mut item = self
            .db
            .query_row(
                &format!("{ITEM_SELECT} WHERE c.source_id=?1 AND c.item_id=?2"),
                params![source_id, item_id],
                read_item,
            )
            .optional()?
            .ok_or(Error::NotFound)?;
        let group = self.equivalent_item_ids(source_id, item_id)?;
        if group.len() > 1 {
            match item.kind {
                ItemKind::Series => {
                    item.child_count = Some(self.merged_series_season_count(source_id, &group)?);
                }
                ItemKind::Season => {
                    item.child_count = Some(self.merged_season_episode_count(source_id, &group)?);
                }
                ItemKind::Movie | ItemKind::Episode => {
                    item.playable = self.any_asset_available(source_id, &group)?;
                    item.progress = self.latest_progress_for_group(source_id, item_id, &group)?;
                }
                ItemKind::Unidentified => {}
            }
        }
        Ok(item)
    }

    pub fn assets(&self, source_id: &str, item_id: &str) -> Result<Vec<Asset>, Error> {
        self.item(source_id, item_id)?;
        let group = self.equivalent_item_ids(source_id, item_id)?;
        let mut q = self.db.prepare("SELECT e.source_id,e.asset_id,e.relative_path,e.size,e.available FROM entry e JOIN item_asset a ON a.source_id=e.source_id AND a.asset_id=e.asset_id WHERE a.source_id=?1 AND a.item_id=?2 ORDER BY e.relative_path,e.asset_id")?;
        let mut seen = std::collections::HashSet::new();
        let mut rows = Vec::new();
        for target_id in &group {
            for asset in q.query_map(params![source_id, target_id], |r| {
                Ok(Asset {
                    source_id: r.get(0)?,
                    asset_id: r.get(1)?,
                    relative_path: r.get(2)?,
                    size: r.get(3)?,
                    available: r.get(4)?,
                })
            })? {
                let asset = asset?;
                if seen.insert(asset.asset_id.clone()) {
                    rows.push(asset);
                }
            }
        }
        rows.sort_by(|a, b| {
            a.relative_path
                .cmp(&b.relative_path)
                .then_with(|| a.asset_id.cmp(&b.asset_id))
        });
        Ok(rows)
    }

    pub fn asset_location(
        &self,
        source_id: &str,
        item_id: &str,
        asset_id: &str,
    ) -> Result<(String, String), Error> {
        self.item(source_id, item_id)?;
        let group = self.equivalent_item_ids(source_id, item_id)?;
        for target_id in &group {
            if let Some(found) = self
                .db
                .query_row(
                    "SELECT lr.root_path,e.relative_path FROM entry e JOIN item_asset a ON a.source_id=e.source_id AND a.asset_id=e.asset_id JOIN library_root lr ON lr.root_id=e.root_id WHERE a.source_id=?1 AND a.item_id=?2 AND e.asset_id=?3 AND e.available=1",
                    params![source_id, target_id, asset_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?
            {
                return Ok(found);
            }
        }
        Err(Error::NotFound)
    }

    pub fn playback_path(
        &self,
        source_id: &str,
        item_id: &str,
        asset_id: &str,
    ) -> Result<PathBuf, Error> {
        if self.source(source_id)?.kind != SourceKind::LocalFolder {
            return Err(Error::Invalid(
                "remote assets require a provider resource lease".into(),
            ));
        }
        let (root_path, relative_path) = self.asset_location(source_id, item_id, asset_id)?;
        let root = std::fs::canonicalize(&root_path)?;
        let path = std::fs::canonicalize(root.join(relative_path))?;
        if !path.starts_with(&root) || !path.is_file() {
            return Err(Error::Invalid(
                "asset is outside the library root or is not a file".into(),
            ));
        }
        Ok(path)
    }

    pub fn record_progress(&self, p: &Progress) -> Result<bool, Error> {
        let item = self.item(&p.source_id, &p.item_id)?;
        if !matches!(
            item.kind,
            ItemKind::Movie | ItemKind::Episode | ItemKind::Unidentified
        ) {
            return Err(Error::Invalid(
                "progress must belong to a playable leaf".into(),
            ));
        }
        if !p.position_seconds.is_finite()
            || p.position_seconds < 0.0
            || !p.recorded_at.is_finite()
            || p.duration_seconds
                .is_some_and(|d| !d.is_finite() || d <= 0.0)
        {
            return Err(Error::Invalid("invalid progress time or duration".into()));
        }
        let group = self.equivalent_item_ids(&p.source_id, &p.item_id)?;
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let mut changed = 0usize;
        for target_id in &group {
            changed += tx.execute(
                "INSERT INTO watch_state VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source_id,item_id) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,played=excluded.played,completed=excluded.completed,recorded_at=excluded.recorded_at WHERE excluded.recorded_at>watch_state.recorded_at",
                params![
                    p.source_id,
                    target_id,
                    p.position_seconds,
                    p.duration_seconds,
                    p.played,
                    p.completed,
                    p.recorded_at
                ],
            )?;
        }
        tx.commit()?;
        Ok(changed > 0)
    }

    pub fn progress(&self, source_id: &str, item_id: &str) -> Result<Option<Progress>, Error> {
        self.item(source_id, item_id)?;
        let group = self.equivalent_item_ids(source_id, item_id)?;
        self.latest_progress_for_group(source_id, item_id, &group)
    }

    pub fn bind_metadata(
        &self,
        source_id: &str,
        item_id: &str,
        tmdb_id: i64,
        media_type: &str,
        language: &str,
        metadata: &serde_json::Value,
        manual: bool,
    ) -> Result<bool, Error> {
        let item = self.item(source_id, item_id)?;
        let expected = match item.kind {
            ItemKind::Movie => "movie",
            ItemKind::Series => "tv",
            _ => {
                return Err(Error::Invalid(
                    "match the movie or series before its season/episodes".into(),
                ))
            }
        };
        if media_type != expected
            || tmdb_id <= 0
            || metadata.get("id").and_then(|v| v.as_i64()) != Some(tmdb_id)
        {
            return Err(Error::Invalid(
                "TMDB identity or movie/tv category mismatch".into(),
            ));
        }
        let targets = if manual {
            self.equivalent_item_ids(source_id, item_id)?
        } else {
            vec![item_id.to_owned()]
        };
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let now = crate::now();
        let payload = metadata.to_string();
        let mut total_changed = 0usize;
        for target_id in &targets {
            let changed = tx.execute(
                "INSERT INTO item_match VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(source_id,item_id) DO UPDATE SET media_type=excluded.media_type,tmdb_id=excluded.tmdb_id,language=excluded.language,metadata=excluded.metadata,manual_lock=excluded.manual_lock,fetched_at=excluded.fetched_at WHERE item_match.manual_lock=0 OR excluded.manual_lock=1",
                params![source_id, target_id, media_type, tmdb_id, language, payload, manual, now],
            )?;
            if changed > 0 {
                total_changed += changed;
                tx.execute(
                    "UPDATE catalog_item SET match_revision=match_revision+1 WHERE source_id=?1 AND item_id=?2",
                    params![source_id, target_id],
                )?;
                tx.execute(
                    "DELETE FROM item_metadata WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND series_id=?2)",
                    params![source_id, target_id],
                )?;
            }
        }
        tx.commit()?;
        Ok(total_changed > 0)
    }

    pub(crate) fn equivalent_item_ids(
        &self,
        source_id: &str,
        item_id: &str,
    ) -> Result<Vec<String>, Error> {
        let row: Option<(String, Option<String>, Option<i64>, Option<i64>)> = self
            .db
            .query_row(
                "SELECT kind,series_id,season_number,episode_number FROM catalog_item WHERE source_id=?1 AND item_id=?2",
                params![source_id, item_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let Some((kind, series_id, season_number, episode_number)) = row else {
            return Ok(vec![item_id.to_owned()]);
        };
        match kind.as_str() {
            "movie" | "series" => {
                let matched: Option<(String, i64)> = self
                    .db
                    .query_row(
                        "SELECT media_type,tmdb_id FROM item_match WHERE source_id=?1 AND item_id=?2",
                        params![source_id, item_id],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?;
                let Some((media_type, tmdb_id)) = matched else {
                    return Ok(vec![item_id.to_owned()]);
                };
                let mut q = self.db.prepare(
                    "SELECT c.item_id FROM catalog_item c JOIN item_match m ON m.source_id=c.source_id AND m.item_id=c.item_id WHERE c.source_id=?1 AND c.kind=?2 AND m.media_type=?3 AND m.tmdb_id=?4 ORDER BY c.first_seen_at ASC,c.item_id ASC",
                )?;
                let ids = q
                    .query_map(params![source_id, kind, media_type, tmdb_id], |r| {
                        r.get::<_, String>(0)
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                if ids.is_empty() {
                    Ok(vec![item_id.to_owned()])
                } else {
                    Ok(ids)
                }
            }
            "season" => {
                let (Some(series_id), Some(season_number)) = (series_id, season_number) else {
                    return Ok(vec![item_id.to_owned()]);
                };
                let series_group = self.equivalent_item_ids(source_id, &series_id)?;
                if series_group.len() <= 1 {
                    return Ok(vec![item_id.to_owned()]);
                }
                let mut q = self.db.prepare(
                    "SELECT item_id FROM catalog_item WHERE source_id=?1 AND kind='season' AND series_id=?2 AND season_number=?3 ORDER BY first_seen_at ASC,item_id ASC",
                )?;
                let mut ids = Vec::new();
                for sid in &series_group {
                    for id in q.query_map(params![source_id, sid, season_number], |r| {
                        r.get::<_, String>(0)
                    })? {
                        ids.push(id?);
                    }
                }
                if ids.is_empty() {
                    Ok(vec![item_id.to_owned()])
                } else {
                    Ok(ids)
                }
            }
            "episode" => {
                let (Some(series_id), Some(season_number), Some(episode_number)) =
                    (series_id, season_number, episode_number)
                else {
                    return Ok(vec![item_id.to_owned()]);
                };
                let series_group = self.equivalent_item_ids(source_id, &series_id)?;
                if series_group.len() <= 1 {
                    return Ok(vec![item_id.to_owned()]);
                }
                let mut q = self.db.prepare(
                    "SELECT item_id FROM catalog_item WHERE source_id=?1 AND kind='episode' AND series_id=?2 AND season_number=?3 AND episode_number=?4 ORDER BY first_seen_at ASC,item_id ASC",
                )?;
                let mut ids = Vec::new();
                for sid in &series_group {
                    for id in q.query_map(
                        params![source_id, sid, season_number, episode_number],
                        |r| r.get::<_, String>(0),
                    )? {
                        ids.push(id?);
                    }
                }
                if ids.is_empty() {
                    Ok(vec![item_id.to_owned()])
                } else {
                    Ok(ids)
                }
            }
            _ => Ok(vec![item_id.to_owned()]),
        }
    }

    fn merge_top_level_items(&self, source_id: &str, raw: Vec<Item>) -> Result<Vec<Item>, Error> {
        let mut order: Vec<String> = Vec::new();
        let mut buckets: std::collections::HashMap<String, Vec<Item>> =
            std::collections::HashMap::new();
        for item in raw {
            let key = if matches!(item.kind, ItemKind::Movie | ItemKind::Series) {
                if let Some(tmdb_id) = tmdb_id_of(&item) {
                    format!("{}:{tmdb_id}", item.kind.as_str())
                } else {
                    format!("item:{}", item.item_id)
                }
            } else {
                format!("item:{}", item.item_id)
            };
            if !buckets.contains_key(&key) {
                order.push(key.clone());
            }
            buckets.entry(key).or_default().push(item);
        }
        let mut out = Vec::with_capacity(order.len());
        for key in order {
            let Some(group) = buckets.remove(&key) else {
                continue;
            };
            if group.len() == 1 {
                out.push(group.into_iter().next().unwrap());
                continue;
            }
            let group_ids: Vec<String> = group.iter().map(|i| i.item_id.clone()).collect();
            let mut leader = group[0].clone();
            for member in &group[1..] {
                if member.first_seen_at > leader.first_seen_at {
                    leader.first_seen_at = member.first_seen_at;
                }
                if member.playable {
                    leader.playable = true;
                }
                if let Some(mp) = &member.progress {
                    let take = leader
                        .progress
                        .as_ref()
                        .is_none_or(|lp| mp.recorded_at > lp.recorded_at);
                    if take {
                        let mut updated = mp.clone();
                        updated.item_id = leader.item_id.clone();
                        leader.progress = Some(updated);
                    }
                }
            }
            if leader.kind == ItemKind::Series {
                leader.child_count = Some(self.merged_series_season_count(source_id, &group_ids)?);
            }
            out.push(leader);
        }
        Ok(out)
    }

    fn merge_child_items(&self, source_id: &str, raw: Vec<Item>) -> Result<Vec<Item>, Error> {
        let mut order: Vec<String> = Vec::new();
        let mut buckets: std::collections::HashMap<String, Vec<Item>> =
            std::collections::HashMap::new();
        for item in raw {
            let key = match (item.kind, item.season_number, item.episode_number) {
                (ItemKind::Season, Some(season), _) => format!("season:{season}"),
                (ItemKind::Episode, Some(season), Some(ep)) => format!("ep:{season}:{ep}"),
                _ => format!("item:{}", item.item_id),
            };
            if !buckets.contains_key(&key) {
                order.push(key.clone());
            }
            buckets.entry(key).or_default().push(item);
        }
        let mut out = Vec::with_capacity(order.len());
        for key in order {
            let Some(group) = buckets.remove(&key) else {
                continue;
            };
            if group.len() == 1 {
                out.push(group.into_iter().next().unwrap());
                continue;
            }
            let group_ids: Vec<String> = group.iter().map(|i| i.item_id.clone()).collect();
            let mut leader = group
                .iter()
                .find(|i| i.metadata.is_some() && i.playable)
                .or_else(|| group.iter().find(|i| i.metadata.is_some()))
                .or_else(|| group.iter().find(|i| i.playable))
                .unwrap_or(&group[0])
                .clone();
            for member in &group {
                if member.first_seen_at > leader.first_seen_at {
                    leader.first_seen_at = member.first_seen_at;
                }
                if member.playable {
                    leader.playable = true;
                }
                if let Some(mp) = &member.progress {
                    let take = leader
                        .progress
                        .as_ref()
                        .is_none_or(|lp| mp.recorded_at > lp.recorded_at);
                    if take {
                        let mut updated = mp.clone();
                        updated.item_id = leader.item_id.clone();
                        leader.progress = Some(updated);
                    }
                }
            }
            if leader.kind == ItemKind::Season {
                leader.child_count = Some(self.merged_season_episode_count(source_id, &group_ids)?);
            }
            out.push(leader);
        }
        Ok(out)
    }

    fn merged_series_season_count(
        &self,
        source_id: &str,
        series_ids: &[String],
    ) -> Result<i64, Error> {
        let mut seasons = std::collections::HashSet::new();
        let mut q = self.db.prepare(
            "SELECT season_number,item_id FROM catalog_item WHERE source_id=?1 AND kind='season' AND series_id=?2",
        )?;
        for sid in series_ids {
            for row in q.query_map(params![source_id, sid], |r| {
                Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, String>(1)?))
            })? {
                let (season_num, id) = row?;
                seasons.insert(season_num.map_or(id, |n| format!("s:{n}")));
            }
        }
        Ok(seasons.len() as i64)
    }

    fn merged_season_episode_count(
        &self,
        source_id: &str,
        season_ids: &[String],
    ) -> Result<i64, Error> {
        let mut episodes = std::collections::HashSet::new();
        let mut q = self.db.prepare(
            "SELECT episode_number,item_id FROM catalog_item WHERE source_id=?1 AND kind='episode' AND parent_id=?2",
        )?;
        for sid in season_ids {
            for row in q.query_map(params![source_id, sid], |r| {
                Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, String>(1)?))
            })? {
                let (ep_num, id) = row?;
                episodes.insert(ep_num.map_or(id, |n| format!("e:{n}")));
            }
        }
        Ok(episodes.len() as i64)
    }

    fn any_asset_available(&self, source_id: &str, item_ids: &[String]) -> Result<bool, Error> {
        let mut q = self.db.prepare(
            "SELECT EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=?1 AND a.item_id=?2 AND e.available=1)",
        )?;
        for id in item_ids {
            if q.query_row(params![source_id, id], |r| r.get::<_, bool>(0))? {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn latest_progress_for_group(
        &self,
        source_id: &str,
        requested_item_id: &str,
        item_ids: &[String],
    ) -> Result<Option<Progress>, Error> {
        let mut q = self.db.prepare(
            "SELECT position_seconds,duration_seconds,played,completed,recorded_at FROM watch_state WHERE source_id=?1 AND item_id=?2",
        )?;
        let mut best: Option<Progress> = None;
        for id in item_ids {
            if let Some(p) = q
                .query_row(params![source_id, id], |r| {
                    Ok(Progress {
                        source_id: source_id.into(),
                        item_id: requested_item_id.into(),
                        position_seconds: r.get(0)?,
                        duration_seconds: r.get(1)?,
                        played: r.get(2)?,
                        completed: r.get(3)?,
                        recorded_at: r.get(4)?,
                    })
                })
                .optional()?
            {
                if best.as_ref().is_none_or(|b| p.recorded_at > b.recorded_at) {
                    best = Some(p);
                }
            }
        }
        Ok(best)
    }

    fn series_episode_watch_counts(
        &self,
        source_id: &str,
        series_ids: &[String],
    ) -> Result<(usize, usize), Error> {
        let mut ep_states: std::collections::HashMap<String, bool> =
            std::collections::HashMap::new();
        let mut q = self.db.prepare(
            "SELECT ep.season_number,ep.episode_number,ep.item_id,COALESCE(ew.played,0),COALESCE(ew.completed,0) FROM catalog_item ep JOIN item_asset a ON a.source_id=ep.source_id AND a.item_id=ep.item_id JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id LEFT JOIN watch_state ew ON ew.source_id=ep.source_id AND ew.item_id=ep.item_id WHERE ep.source_id=?1 AND ep.series_id=?2 AND ep.kind='episode' AND e.available=1",
        )?;
        for sid in series_ids {
            for row in q.query_map(params![source_id, sid], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, Option<i64>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, bool>(3)?,
                    r.get::<_, bool>(4)?,
                ))
            })? {
                let (season, ep, id, played, completed) = row?;
                let key = match (season, ep) {
                    (Some(s), Some(e)) => format!("s:{s}:e:{e}"),
                    _ => format!("id:{id}"),
                };
                let done = played || completed;
                ep_states
                    .entry(key)
                    .and_modify(|v| *v = *v || done)
                    .or_insert(done);
            }
        }
        let total = ep_states.len();
        let unplayed = ep_states.values().filter(|&&done| !done).count();
        Ok((total, unplayed))
    }

    fn canonical_leaf_key(&self, source_id: &str, item: &Item) -> Result<String, Error> {
        match item.kind {
            ItemKind::Movie => {
                if let Some(tmdb_id) = tmdb_id_of(item) {
                    return Ok(format!("movie:{tmdb_id}"));
                }
            }
            ItemKind::Episode => {
                if let (Some(series_id), Some(season), Some(ep)) =
                    (&item.series_id, item.season_number, item.episode_number)
                {
                    let matched: Option<i64> = self
                        .db
                        .query_row(
                            "SELECT tmdb_id FROM item_match WHERE source_id=?1 AND item_id=?2 AND media_type='tv'",
                            params![source_id, series_id],
                            |r| r.get(0),
                        )
                        .optional()?;
                    if let Some(tmdb_id) = matched {
                        return Ok(format!("tv:{tmdb_id}:s:{season}:e:{ep}"));
                    }
                }
            }
            _ => {}
        }
        Ok(format!("item:{}", item.item_id))
    }
}

fn tmdb_id_of(item: &Item) -> Option<i64> {
    item.metadata
        .as_ref()
        .and_then(|m| m.get("id"))
        .and_then(|v| v.as_i64())
        .filter(|&id| id > 0)
}

fn rating_of(item: &Item) -> f64 {
    item.metadata
        .as_ref()
        .and_then(|m| m.get("vote_average"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0)
}

fn sort_items(items: &mut [Item], sort_field: &str, ascending: bool) {
    items.sort_by(|a, b| {
        let primary = match sort_field {
            "childOrder" => a
                .season_number
                .cmp(&b.season_number)
                .then_with(|| a.episode_number.cmp(&b.episode_number))
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
                .then_with(|| a.item_id.cmp(&b.item_id)),
            "dateAdded" => {
                let cmp = a
                    .first_seen_at
                    .partial_cmp(&b.first_seen_at)
                    .unwrap_or(std::cmp::Ordering::Equal);
                if ascending {
                    cmp
                } else {
                    cmp.reverse()
                }
            }
            "year" => {
                let cmp = a.year.unwrap_or(0).cmp(&b.year.unwrap_or(0));
                if ascending {
                    cmp
                } else {
                    cmp.reverse()
                }
            }
            "rating" => {
                let cmp = rating_of(a)
                    .partial_cmp(&rating_of(b))
                    .unwrap_or(std::cmp::Ordering::Equal);
                if ascending {
                    cmp
                } else {
                    cmp.reverse()
                }
            }
            _ => {
                let cmp = a.title.to_lowercase().cmp(&b.title.to_lowercase());
                if ascending {
                    cmp
                } else {
                    cmp.reverse()
                }
            }
        };
        primary
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            .then_with(|| a.item_id.cmp(&b.item_id))
    });
}

const ITEM_SELECT: &str = "SELECT c.source_id,c.library_id,c.item_id,c.kind,c.title,c.year,c.parent_id,c.series_id,c.season_number,c.episode_number,c.first_seen_at,COALESCE(m.metadata,d.metadata),EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND a.item_id=c.item_id AND e.available=1),COALESCE(json_extract(sm.metadata,'$.name'),json_extract(sm.metadata,'$.title'),sc.title),json_extract(sm.metadata,'$.backdrop_path'),json_extract(sm.metadata,'$.poster_path'),CASE WHEN c.kind IN ('series','season') THEN (SELECT COUNT(*) FROM catalog_item ch WHERE ch.source_id=c.source_id AND ch.parent_id=c.item_id) ELSE NULL END,ws.position_seconds,ws.duration_seconds,ws.played,ws.completed,ws.recorded_at FROM catalog_item c LEFT JOIN item_match m ON m.source_id=c.source_id AND m.item_id=c.item_id LEFT JOIN item_metadata d ON d.source_id=c.source_id AND d.item_id=c.item_id LEFT JOIN catalog_item sc ON sc.source_id=c.source_id AND sc.item_id=c.series_id LEFT JOIN item_match sm ON sm.source_id=c.source_id AND sm.item_id=c.series_id LEFT JOIN watch_state ws ON ws.source_id=c.source_id AND ws.item_id=c.item_id";

fn require_current_generation(db: &Connection, job: &Job) -> Result<(), Error> {
    let generation: i64 = db.query_row(
        "SELECT MAX(generation) FROM job WHERE source_id=?1 AND library_id=?2",
        params![job.source_id, job.library_id],
        |r| r.get(0),
    )?;
    if generation != job.generation {
        return Err(Error::Invalid("scan generation has been superseded".into()));
    }
    Ok(())
}

fn check_no_root_overlap(
    tx: &rusqlite::Transaction<'_>,
    source_id: &str,
    kind: SourceKind,
    root: &str,
) -> Result<(), Error> {
    let mut q = tx.prepare("SELECT root_path FROM library_root WHERE source_id=?1")?;
    for previous in q.query_map([source_id], |r| r.get::<_, String>(0))? {
        let previous = previous?;
        let overlap = if kind == SourceKind::Webdav {
            ocp_webdav::within(root, &previous) || ocp_webdav::within(&previous, root)
        } else if kind == SourceKind::Smb {
            ocp_smb::within(root, &previous) || ocp_smb::within(&previous, root)
        } else {
            Path::new(root).starts_with(&previous) || Path::new(&previous).starts_with(root)
        };
        if overlap {
            return Err(Error::Invalid(
                "scan roots must not overlap; select separate subdirectories".into(),
            ));
        }
    }
    Ok(())
}

fn read_library(r: &rusqlite::Row<'_>) -> rusqlite::Result<Library> {
    let typ: String = r.get(4)?;
    Ok(Library {
        library_id: r.get(0)?,
        source_id: r.get(1)?,
        name: r.get(2)?,
        root_path: r.get(3)?,
        library_type: if typ == "movies" {
            LibraryType::Movies
        } else {
            LibraryType::Tvshows
        },
        revision: r.get(5)?,
        created_at: r.get(6)?,
        roots: Vec::new(),
    })
}

fn read_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<Item> {
    let kind: String = r.get(3)?;
    let metadata: Option<String> = r.get(11)?;
    let match_status = if metadata.is_some() {
        "matched"
    } else {
        "unmatched"
    };
    let parsed: Option<serde_json::Value> =
        metadata.as_ref().and_then(|m| serde_json::from_str(m).ok());
    let title = parsed
        .as_ref()
        .and_then(|m| {
            ["title", "name"]
                .iter()
                .find_map(|key| m.get(key)?.as_str().filter(|s| !s.is_empty()))
        })
        .map(str::to_owned)
        .unwrap_or(r.get(4)?);
    let year = parsed
        .as_ref()
        .and_then(|m| {
            ["release_date", "first_air_date"]
                .iter()
                .find_map(|key| m.get(key)?.as_str())
        })
        .and_then(|date| date.get(..4)?.parse::<i64>().ok())
        .or(r.get(5)?);
    let source_id: String = r.get(0)?;
    let item_id: String = r.get(2)?;
    let progress = match r.get::<_, Option<f64>>(17)? {
        Some(position_seconds) => Some(Progress {
            source_id: source_id.clone(),
            item_id: item_id.clone(),
            position_seconds,
            duration_seconds: r.get(18)?,
            played: r.get(19)?,
            completed: r.get(20)?,
            recorded_at: r.get(21)?,
        }),
        None => None,
    };
    Ok(Item {
        source_id,
        library_id: r.get(1)?,
        item_id,
        kind: match kind.as_str() {
            "movie" => ItemKind::Movie,
            "series" => ItemKind::Series,
            "season" => ItemKind::Season,
            "episode" => ItemKind::Episode,
            _ => ItemKind::Unidentified,
        },
        title,
        year,
        parent_id: r.get(6)?,
        series_id: r.get(7)?,
        season_number: r.get(8)?,
        episode_number: r.get(9)?,
        first_seen_at: r.get(10)?,
        metadata: parsed,
        match_status: match_status.into(),
        playable: r.get(12)?,
        series_title: r.get(13)?,
        series_backdrop_path: r.get(14)?,
        series_poster_path: r.get(15)?,
        child_count: r.get(16)?,
        progress,
    })
}

fn delete_library_tx(
    tx: &rusqlite::Transaction<'_>,
    source_id: &str,
    library_id: &str,
) -> Result<(), Error> {
    tx.execute(
        "DELETE FROM scrape_target WHERE run_id IN (SELECT run_id FROM scrape_run WHERE source_id=?1 AND library_id=?2)",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM scrape_run WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM job_directory WHERE job_id IN (SELECT job_id FROM job WHERE source_id=?1 AND library_id=?2)",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM job WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM watch_state WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2)",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM item_match WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2)",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM item_metadata WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND library_id=?2)",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM item_asset WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "UPDATE catalog_item SET parent_id=NULL,series_id=NULL WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM catalog_item WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM entry WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM library_root WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    tx.execute(
        "DELETE FROM library WHERE source_id=?1 AND library_id=?2",
        params![source_id, library_id],
    )?;
    Ok(())
}

fn prune_orphan_items_tx(
    tx: &rusqlite::Transaction<'_>,
    source_id: &str,
    library_id: &str,
    sql: &str,
) -> Result<(), Error> {
    let mut q = tx.prepare(sql)?;
    let ids: Vec<String> = q
        .query_map(params![source_id, library_id], |r| r.get(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(q);
    for item_id in ids {
        tx.execute(
            "DELETE FROM watch_state WHERE source_id=?1 AND item_id=?2",
            params![source_id, item_id],
        )?;
        tx.execute(
            "DELETE FROM item_match WHERE source_id=?1 AND item_id=?2",
            params![source_id, item_id],
        )?;
        tx.execute(
            "DELETE FROM item_metadata WHERE source_id=?1 AND item_id=?2",
            params![source_id, item_id],
        )?;
        tx.execute(
            "DELETE FROM scrape_target WHERE item_id=?1 AND run_id IN (SELECT run_id FROM scrape_run WHERE source_id=?2 AND library_id=?3)",
            params![item_id, source_id, library_id],
        )?;
        tx.execute(
            "DELETE FROM catalog_item WHERE source_id=?1 AND item_id=?2",
            params![source_id, item_id],
        )?;
    }
    Ok(())
}
