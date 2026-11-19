use crate::{
    parse::Parsed, Asset, Error, Item, ItemKind, Job, Library, LibraryType, Progress, Query,
    Source, SourceKind,
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
        if version > 2 {
            return Err(Error::Invalid(
                "library database was created by a newer version".into(),
            ));
        }
        if version < 2 {
            let tx = rusqlite::Transaction::new_unchecked(
                &db,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            // Another handle may have migrated while this one waited for the
            // write lock. Read the version again inside the migration boundary.
            let locked_version: i64 = tx.pragma_query_value(None, "user_version", |r| r.get(0))?;
            if locked_version == 0 {
                tx.execute_batch(include_str!("../schema/v1.sql"))?;
            }
            if locked_version < 2 {
                tx.execute_batch(include_str!("../schema/v2.sql"))?;
                tx.pragma_update(None, "user_version", 2)?;
            }
            tx.commit()?;
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
        let mut q = self.db.prepare("SELECT source_id,display_name,root_path,access_ref,created_at FROM source ORDER BY created_at,source_id")?;
        let rows = q
            .query_map([], |r| {
                Ok(Source {
                    source_id: r.get(0)?,
                    kind: SourceKind::LocalFolder,
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

    pub fn libraries(&self, source_id: &str) -> Result<Vec<Library>, Error> {
        self.source(source_id)?;
        let mut q = self.db.prepare("SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE source_id=?1 ORDER BY created_at,library_id")?;
        let rows = q
            .query_map([source_id], read_library)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn library(&self, source_id: &str, library_id: &str) -> Result<Library, Error> {
        self.db.query_row("SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE source_id=?1 AND library_id=?2", params![source_id, library_id], read_library)
            .optional()?.ok_or(Error::NotFound)
    }

    pub fn created_draft(&self, draft_id: &str) -> Result<Option<Library>, Error> {
        Ok(self.db.query_row("SELECT library_id,source_id,name,root_path,type,revision,created_at FROM library WHERE draft_id=?1", [draft_id], read_library).optional()?)
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
        for value in [draft_id, source_name, name] {
            if value.trim().is_empty() || value.contains('\0') {
                return Err(Error::Invalid(
                    "names and draftId must be nonempty without NUL".into(),
                ));
            }
        }
        if !root.is_absolute() || !source_root.is_absolute() || !root.starts_with(source_root) {
            return Err(Error::Invalid(
                "library root must be inside the authorized source root".into(),
            ));
        }
        if let Some(previous) = self.created_draft(draft_id)? {
            if previous.root_path != root.to_string_lossy()
                || previous.library_type != typ
                || previous.name != name
                || existing_source.is_some_and(|id| id != previous.source_id)
            {
                return Err(Error::Invalid(
                    "draftId has already been used with different inputs".into(),
                ));
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
            if Path::new(&stored_root) != source_root {
                return Err(Error::Invalid(
                    "access lease belongs to a different source root".into(),
                ));
            }
            let mut q = tx.prepare("SELECT root_path FROM library WHERE source_id=?1")?;
            for previous in q.query_map([id], |r| r.get::<_, String>(0))? {
                let previous = PathBuf::from(previous?);
                if root.starts_with(&previous) || previous.starts_with(root) {
                    return Err(Error::Invalid(
                        "scan roots must not overlap; select separate subdirectories".into(),
                    ));
                }
            }
            id.to_owned()
        } else {
            let id = crate::id();
            tx.execute(
                "INSERT INTO source VALUES(?1,'localFolder',?2,?3,?4,?5)",
                params![
                    id,
                    source_name,
                    source_root.to_string_lossy(),
                    access_ref,
                    crate::now()
                ],
            )?;
            id
        };
        let library = Library {
            library_id: crate::id(),
            source_id,
            name: name.into(),
            root_path: root.to_string_lossy().into_owned(),
            library_type: typ,
            revision: 1,
            created_at: crate::now(),
        };
        tx.execute("INSERT INTO library(library_id,source_id,name,root_path,type,revision,created_at,draft_id) VALUES(?1,?2,?3,?4,?5,1,?6,?7)",
            params![library.library_id, library.source_id, name, library.root_path, typ.as_str(), library.created_at, draft_id])?;
        tx.commit()?;
        Ok(library)
    }

    pub fn start_scan(&self, source_id: &str, library_id: &str) -> Result<Job, Error> {
        self.library(source_id, library_id)?;
        let active: Option<String> = self.db.query_row("SELECT job_id FROM job WHERE library_id=?1 AND status IN ('queued','enumerating','paused','interrupted','waitingPermission') ORDER BY generation DESC LIMIT 1", [library_id], |r| r.get(0)).optional()?;
        if let Some(id) = active {
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
        tx.execute("INSERT INTO job_directory VALUES(?1,'',0)", [&id])?;
        tx.commit()?;
        self.job(source_id, &id)
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

    pub fn next_directory(&self, job_id: &str) -> Result<Option<String>, Error> {
        Ok(self.db.query_row("SELECT relative_path FROM job_directory WHERE job_id=?1 AND done=0 ORDER BY relative_path LIMIT 1", [job_id], |r| r.get(0)).optional()?)
    }

    pub fn add_directory(&self, job_id: &str, relative: &str) -> Result<(), Error> {
        self.db.execute(
            "INSERT OR IGNORE INTO job_directory VALUES(?1,?2,0)",
            params![job_id, relative],
        )?;
        Ok(())
    }

    pub fn directory_done(&self, job_id: &str, relative: &str) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let changed = tx.execute(
            "UPDATE job_directory SET done=1 WHERE job_id=?1 AND relative_path=?2 AND done=0",
            params![job_id, relative],
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
        let existing: Option<(String,i64)> = tx.query_row("SELECT asset_id,seen_generation FROM entry WHERE source_id=?1 AND library_id=?2 AND relative_path=?3", params![job.source_id,job.library_id,relative], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
        let asset_id = existing
            .as_ref()
            .map(|e| e.0.clone())
            .unwrap_or_else(crate::id);
        tx.execute("INSERT INTO entry(source_id,asset_id,library_id,relative_path,size,mtime,seen_generation) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source_id,library_id,relative_path) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,available=1,seen_generation=excluded.seen_generation",
            params![job.source_id,asset_id,job.library_id,relative,size,mtime,job.generation])?;
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
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        self.source(&input.source_id)?;
        if let Some(id) = &input.library_id {
            self.library(&input.source_id, id)?;
        }
        if let Some(id) = &input.parent_id {
            self.item(&input.source_id, id)?;
        }
        let where_clause = "c.source_id=?1 AND (?2 IS NULL OR c.library_id=?2) AND (?3 IS NULL OR l.type=?3) AND ((?4 IS NULL AND c.parent_id IS NULL) OR c.parent_id=?4) AND (?5='' OR instr(lower(c.title),lower(?5))>0 OR instr(lower(COALESCE(json_extract(m.metadata,'$.title'),json_extract(m.metadata,'$.name'),json_extract(d.metadata,'$.name'),'')),lower(?5))>0)";
        let keys = params![
            input.source_id,
            input.library_id,
            input.library_type.map(LibraryType::as_str),
            input.parent_id,
            input.search,
            input.limit,
            input.start_index
        ];
        let sql = format!("{ITEM_SELECT} JOIN library l ON l.library_id=c.library_id WHERE {where_clause} ORDER BY c.season_number,c.episode_number,COALESCE(json_extract(m.metadata,'$.title'),json_extract(m.metadata,'$.name'),json_extract(d.metadata,'$.name'),c.title) COLLATE NOCASE,c.item_id LIMIT ?6 OFFSET ?7");
        let mut q = self.db.prepare(&sql)?;
        let items = q
            .query_map(keys, read_item)?
            .collect::<Result<Vec<_>, _>>()?;
        let total = self.db.query_row(&format!("SELECT COUNT(*) FROM catalog_item c JOIN library l ON l.library_id=c.library_id LEFT JOIN item_match m ON m.source_id=c.source_id AND m.item_id=c.item_id LEFT JOIN item_metadata d ON d.source_id=c.source_id AND d.item_id=c.item_id WHERE {where_clause}"),
            params![input.source_id,input.library_id,input.library_type.map(LibraryType::as_str),input.parent_id,input.search], |r| r.get(0))?;
        drop(q);
        tx.commit()?;
        Ok((items, total))
    }

    /// Resume contains playable leaves (including episodes), scoped to one source.
    pub fn resume(&self, source_id: &str, limit: i64) -> Result<Vec<Item>, Error> {
        self.source(source_id)?;
        if !(1..=100).contains(&limit) {
            return Err(Error::Invalid("resume limit must be in 1...100".into()));
        }
        let sql = format!("{ITEM_SELECT} JOIN watch_state w ON w.source_id=c.source_id AND w.item_id=c.item_id WHERE c.source_id=?1 AND w.position_seconds>0 AND w.played=0 AND w.completed=0 AND EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND a.item_id=c.item_id AND e.available=1) ORDER BY w.recorded_at DESC,c.item_id LIMIT ?2");
        let mut q = self.db.prepare(&sql)?;
        let items = q
            .query_map(params![source_id, limit], read_item)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(items)
    }

    pub fn item(&self, source_id: &str, item_id: &str) -> Result<Item, Error> {
        self.db
            .query_row(
                &format!("{ITEM_SELECT} WHERE c.source_id=?1 AND c.item_id=?2"),
                params![source_id, item_id],
                read_item,
            )
            .optional()?
            .ok_or(Error::NotFound)
    }

    pub fn assets(&self, source_id: &str, item_id: &str) -> Result<Vec<Asset>, Error> {
        self.item(source_id, item_id)?;
        let mut q = self.db.prepare("SELECT e.source_id,e.asset_id,e.relative_path,e.size,e.available FROM entry e JOIN item_asset a ON a.source_id=e.source_id AND a.asset_id=e.asset_id WHERE a.source_id=?1 AND a.item_id=?2 ORDER BY e.relative_path,e.asset_id")?;
        let rows = q
            .query_map(params![source_id, item_id], |r| {
                Ok(Asset {
                    source_id: r.get(0)?,
                    asset_id: r.get(1)?,
                    relative_path: r.get(2)?,
                    size: r.get(3)?,
                    available: r.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn playback_path(
        &self,
        source_id: &str,
        item_id: &str,
        asset_id: &str,
    ) -> Result<PathBuf, Error> {
        let item = self.item(source_id, item_id)?;
        let library = self.library(source_id, &item.library_id)?;
        let asset = self
            .assets(source_id, item_id)?
            .into_iter()
            .find(|a| a.asset_id == asset_id && a.available)
            .ok_or(Error::NotFound)?;
        let root = std::fs::canonicalize(&library.root_path)?;
        let path = std::fs::canonicalize(root.join(asset.relative_path))?;
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
        let changed = self.db.execute("INSERT INTO watch_state VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source_id,item_id) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,played=excluded.played,completed=excluded.completed,recorded_at=excluded.recorded_at WHERE excluded.recorded_at>watch_state.recorded_at",
            params![p.source_id,p.item_id,p.position_seconds,p.duration_seconds,p.played,p.completed,p.recorded_at])?;
        Ok(changed > 0)
    }

    pub fn progress(&self, source_id: &str, item_id: &str) -> Result<Option<Progress>, Error> {
        self.item(source_id, item_id)?;
        Ok(self.db.query_row("SELECT position_seconds,duration_seconds,played,completed,recorded_at FROM watch_state WHERE source_id=?1 AND item_id=?2", params![source_id,item_id], |r| Ok(Progress {
            source_id:source_id.into(),item_id:item_id.into(),position_seconds:r.get(0)?,duration_seconds:r.get(1)?,played:r.get(2)?,completed:r.get(3)?,recorded_at:r.get(4)?,
        })).optional()?)
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
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let changed = tx.execute("INSERT INTO item_match VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(source_id,item_id) DO UPDATE SET media_type=excluded.media_type,tmdb_id=excluded.tmdb_id,language=excluded.language,metadata=excluded.metadata,manual_lock=excluded.manual_lock,fetched_at=excluded.fetched_at WHERE item_match.manual_lock=0 OR excluded.manual_lock=1",
            params![source_id,item_id,media_type,tmdb_id,language,metadata.to_string(),manual,crate::now()])?;
        if changed > 0 {
            tx.execute("UPDATE catalog_item SET match_revision=match_revision+1 WHERE source_id=?1 AND item_id=?2", params![source_id,item_id])?;
            tx.execute("DELETE FROM item_metadata WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND series_id=?2)", params![source_id,item_id])?;
        }
        tx.commit()?;
        Ok(changed > 0)
    }
}

const ITEM_SELECT: &str = "SELECT c.source_id,c.library_id,c.item_id,c.kind,c.title,c.year,c.parent_id,c.series_id,c.season_number,c.episode_number,c.first_seen_at,COALESCE(m.metadata,d.metadata),EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND a.item_id=c.item_id AND e.available=1) FROM catalog_item c LEFT JOIN item_match m ON m.source_id=c.source_id AND m.item_id=c.item_id LEFT JOIN item_metadata d ON d.source_id=c.source_id AND d.item_id=c.item_id";

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
    Ok(Item {
        source_id: r.get(0)?,
        library_id: r.get(1)?,
        item_id: r.get(2)?,
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
    })
}
