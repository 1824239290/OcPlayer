//! Durable online work. Network credentials never enter the catalog or queue.
use crate::{Error, Item, ItemKind, Store};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrapeRun {
    pub run_id: String,
    pub source_id: String,
    pub library_id: String,
    pub status: String,
    pub language: String,
    pub refresh: bool,
    pub total: i64,
    pub completed: i64,
    pub unmatched: i64,
    pub failed: i64,
    pub last_error: Option<String>,
    pub next_retry_at: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct Target {
    pub item: Item,
    pub input_version: String,
    pub tmdb_id: Option<i64>,
    pub manual: bool,
    pub parent_revision: i64,
    pub cached: bool,
    pub attempts: i64,
}

impl Store {
    pub fn recover_scrapes(&self) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        tx.execute("UPDATE scrape_run SET status='interrupted' WHERE status IN ('queued','running','waitingNetwork')", [])?;
        tx.execute(
            "UPDATE scrape_target SET status='queued' WHERE status='running'",
            [],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn start_scrape(
        &self,
        source: &str,
        library: &str,
        language: &str,
        refresh: bool,
    ) -> Result<ScrapeRun, Error> {
        self.library(source, library)?;
        let existing: Option<String> = self.db.query_row("SELECT run_id FROM scrape_run WHERE source_id=?1 AND library_id=?2 AND status IN ('queued','running','paused','interrupted','waitingCredentials','waitingNetwork') ORDER BY created_at DESC LIMIT 1", params![source,library], |r| r.get(0)).optional()?;
        if let Some(id) = existing {
            return self.scrape_run(source, &id);
        }
        let id = crate::id();
        self.db.execute(
            "INSERT INTO scrape_run VALUES(?1,?2,?3,'queued',?4,?5,?6)",
            params![id, source, library, language, refresh, crate::now()],
        )?;
        self.scrape_run(source, &id)
    }

    pub fn scrape_run(&self, source: &str, id: &str) -> Result<ScrapeRun, Error> {
        self.db.query_row("SELECT run_id,source_id,library_id,status,language,refresh,(SELECT COUNT(*) FROM scrape_target WHERE run_id=r.run_id),(SELECT COUNT(*) FROM scrape_target WHERE run_id=r.run_id AND status IN ('completed','cancelled')),(SELECT COUNT(*) FROM scrape_target WHERE run_id=r.run_id AND status='unmatched'),(SELECT COUNT(*) FROM scrape_target WHERE run_id=r.run_id AND status='failed'),(SELECT last_error FROM scrape_target WHERE run_id=r.run_id AND last_error IS NOT NULL ORDER BY rowid DESC LIMIT 1),(SELECT MIN(next_retry_at) FROM scrape_target WHERE run_id=r.run_id AND status='retryScheduled') FROM scrape_run r WHERE source_id=?1 AND run_id=?2", params![source,id], |r| Ok(ScrapeRun {
            run_id:r.get(0)?,source_id:r.get(1)?,library_id:r.get(2)?,status:r.get(3)?,language:r.get(4)?,refresh:r.get(5)?,total:r.get(6)?,completed:r.get(7)?,unmatched:r.get(8)?,failed:r.get(9)?,last_error:r.get(10)?,next_retry_at:r.get(11)?,
        })).optional()?.ok_or(Error::NotFound)
    }

    pub fn scrape_runs(&self, source: &str) -> Result<Vec<ScrapeRun>, Error> {
        // Latest run per category; old runs remain available for diagnostics.
        self.libraries(source)?;
        let mut q = self.db.prepare("SELECT run_id FROM scrape_run r WHERE source_id=?1 AND rowid=(SELECT MAX(rowid) FROM scrape_run WHERE library_id=r.library_id) ORDER BY created_at")?;
        let ids = q
            .query_map([source], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        ids.iter().map(|id| self.scrape_run(source, id)).collect()
    }

    pub fn set_scrape_status(&self, id: &str, status: &str) -> Result<(), Error> {
        self.db.execute(
            "UPDATE scrape_run SET status=?2 WHERE run_id=?1",
            params![id, status],
        )?;
        Ok(())
    }

    pub fn retry_scrape(&self, run: &ScrapeRun, retry_failed: bool) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        tx.execute("UPDATE scrape_target SET status='queued',next_retry_at=NULL WHERE run_id=?1 AND status='running'", [&run.run_id])?;
        if retry_failed {
            tx.execute("UPDATE scrape_target SET status='queued',attempts=0,error_kind=NULL,last_error=NULL,next_retry_at=NULL WHERE run_id=?1 AND status IN ('failed','unmatched','retryScheduled')", [&run.run_id])?;
        }
        tx.execute(
            "UPDATE scrape_run SET status='queued' WHERE run_id=?1",
            [&run.run_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn change_scrape_language(&self, run: &ScrapeRun, language: &str) -> Result<(), Error> {
        if run.language == language {
            return Ok(());
        }
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        tx.execute(
            "UPDATE scrape_run SET language=?2,refresh=1 WHERE run_id=?1",
            params![run.run_id, language],
        )?;
        tx.execute("UPDATE scrape_target SET status='queued',attempts=0,error_kind=NULL,last_error=NULL,next_retry_at=NULL WHERE run_id=?1",[&run.run_id])?;
        tx.commit()?;
        Ok(())
    }

    pub fn scan_in_progress(&self, run: &ScrapeRun) -> Result<bool, Error> {
        Ok(self.db.query_row("SELECT EXISTS(SELECT 1 FROM job WHERE source_id=?1 AND library_id=?2 AND status IN ('queued','running','enumerating','paused','interrupted','waitingPermission'))", params![run.source_id,run.library_id], |r| r.get(0))?)
    }

    pub fn seed_scrape(&self, run: &ScrapeRun) -> Result<(), Error> {
        self.db.execute("INSERT OR IGNORE INTO scrape_target(run_id,item_id) SELECT ?1,c.item_id FROM catalog_item c WHERE c.source_id=?2 AND c.library_id=?3 AND (c.kind IN ('movie','series') OR (c.kind='season' AND EXISTS(SELECT 1 FROM item_match m WHERE m.source_id=c.source_id AND m.item_id=c.series_id))) AND EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id WHERE a.source_id=c.source_id AND (a.item_id=c.item_id OR a.item_id IN (SELECT item_id FROM catalog_item WHERE source_id=c.source_id AND series_id=c.item_id OR source_id=c.source_id AND parent_id=c.item_id)) AND e.available=1)", params![run.run_id,run.source_id,run.library_id])?;
        self.db.execute("UPDATE scrape_target SET status='completed',error_kind=NULL,last_error=NULL,next_retry_at=NULL WHERE run_id=?1 AND status IN ('queued','retryScheduled') AND NOT EXISTS(SELECT 1 FROM item_asset a JOIN entry e ON e.source_id=a.source_id AND e.asset_id=a.asset_id JOIN catalog_item c ON c.source_id=a.source_id AND c.item_id=a.item_id WHERE c.source_id=?2 AND (c.item_id=scrape_target.item_id OR c.series_id=scrape_target.item_id OR c.parent_id=scrape_target.item_id) AND e.available=1)", params![run.run_id,run.source_id])?;
        Ok(())
    }

    /// Uses original parsed input, never the already localized display title.
    pub fn match_target(
        &self,
        source: &str,
        item_id: &str,
        language: &str,
        refresh: bool,
    ) -> Result<Target, Error> {
        let item = self.item(source, item_id)?;
        if !matches!(
            item.kind,
            ItemKind::Movie | ItemKind::Series | ItemKind::Season
        ) {
            return Err(Error::Invalid("match a movie or its whole series".into()));
        }
        let original: (String,Option<i64>,i64,i64,i64) = self.db.query_row("SELECT c.title,c.year,c.match_revision,l.revision,COALESCE((SELECT MAX(generation) FROM job WHERE library_id=c.library_id),0) FROM catalog_item c JOIN library l ON l.library_id=c.library_id WHERE c.source_id=?1 AND c.item_id=?2", params![source,item_id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?)))?;
        let work_id = item
            .series_id
            .as_deref()
            .filter(|_| item.kind == ItemKind::Season)
            .unwrap_or(item_id);
        let matched: Option<(i64,bool,String,f64,i64)> = self.db.query_row("SELECT m.tmdb_id,m.manual_lock,m.language,m.fetched_at,c.match_revision FROM item_match m JOIN catalog_item c ON c.source_id=m.source_id AND c.item_id=m.item_id WHERE m.source_id=?1 AND m.item_id=?2", params![source,work_id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
        let mut q = self.db.prepare("SELECT e.relative_path,e.size,e.mtime,e.available FROM entry e JOIN item_asset a ON a.source_id=e.source_id AND a.asset_id=e.asset_id JOIN catalog_item c ON c.source_id=a.source_id AND c.item_id=a.item_id WHERE e.source_id=?1 AND (c.item_id=?2 OR c.series_id=?2 OR c.parent_id=?2) ORDER BY e.relative_path")?;
        let assets = q
            .query_map(params![source, item_id], |r| {
                Ok(json!([
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, f64>(2)?,
                    r.get::<_, bool>(3)?
                ]))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let parent_revision = matched.as_ref().map(|m| m.4).unwrap_or(0);
        let snapshot = json!([original, matched, assets, language]);
        let input_version = format!("{:x}", Sha256::digest(snapshot.to_string().as_bytes()));
        let cached = if item.kind == ItemKind::Season {
            self.db.query_row("SELECT EXISTS(SELECT 1 FROM item_metadata WHERE source_id=?1 AND item_id=?2 AND language=?3 AND parent_revision=?4 AND fetched_at>?5) AND NOT EXISTS(SELECT 1 FROM catalog_item c LEFT JOIN item_metadata d ON d.source_id=c.source_id AND d.item_id=c.item_id WHERE c.source_id=?1 AND c.parent_id=?2 AND (d.item_id IS NULL OR d.language!=?3 OR d.parent_revision!=?4))", params![source,item_id,language,parent_revision,crate::now()-30.0*86400.0], |r| r.get::<_,bool>(0))?
        } else {
            matched
                .as_ref()
                .is_some_and(|m| m.2 == language && m.3 > crate::now() - 30.0 * 86400.0)
        };
        let mut item = item;
        item.title = original.0;
        item.year = original.1;
        Ok(Target {
            item,
            input_version,
            tmdb_id: matched.as_ref().map(|m| m.0),
            manual: matched.as_ref().is_some_and(|m| m.1),
            parent_revision,
            cached: cached && !refresh,
            attempts: 0,
        })
    }

    pub fn claim_scrape(&self, run: &ScrapeRun) -> Result<Option<Target>, Error> {
        let id: Option<(String,i64)> = self.db.query_row("SELECT t.item_id,t.attempts FROM scrape_target t JOIN catalog_item c ON c.source_id=?2 AND c.item_id=t.item_id WHERE t.run_id=?1 AND (t.status='queued' OR (t.status='retryScheduled' AND t.next_retry_at<=?3)) ORDER BY CASE c.kind WHEN 'season' THEN 1 ELSE 0 END,t.rowid LIMIT 1",params![run.run_id,run.source_id,crate::now()],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        let Some((id, attempts)) = id else {
            return Ok(None);
        };
        let mut target = self.match_target(&run.source_id, &id, &run.language, run.refresh)?;
        target.attempts = attempts + 1;
        self.db.execute("UPDATE scrape_target SET status='running',input_version=?3,attempts=attempts+1,next_retry_at=NULL WHERE run_id=?1 AND item_id=?2", params![run.run_id,id,target.input_version])?;
        Ok(Some(target))
    }

    pub fn finish_target(
        &self,
        run: &ScrapeRun,
        target: &Target,
        status: &str,
        error_kind: Option<&str>,
        message: Option<&str>,
        retry_at: Option<f64>,
    ) -> Result<(), Error> {
        self.db.execute("UPDATE scrape_target SET status=?3,error_kind=?4,last_error=?5,next_retry_at=?6 WHERE run_id=?1 AND item_id=?2 AND status!='cancelled'", params![run.run_id,target.item.item_id,status,error_kind,message,retry_at])?;
        Ok(())
    }

    pub fn finish_target_checked(
        &self,
        run: &ScrapeRun,
        target: &Target,
        status: &str,
        error_kind: Option<&str>,
        message: Option<&str>,
        retry_at: Option<f64>,
    ) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        if self
            .match_target(
                &run.source_id,
                &target.item.item_id,
                &run.language,
                run.refresh,
            )?
            .input_version
            != target.input_version
            || self.scan_in_progress(run)?
        {
            self.finish_target(run, target, "queued", None, None, None)?;
        } else {
            self.finish_target(run, target, status, error_kind, message, retry_at)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Check and commit in one short transaction. The caller also holds the
    /// credential epoch gate, so invalidation cannot race the final write.
    pub fn commit_scrape(
        &self,
        run: &ScrapeRun,
        target: &Target,
        payload: &Value,
    ) -> Result<bool, Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let current = self.match_target(
            &run.source_id,
            &target.item.item_id,
            &run.language,
            run.refresh,
        )?;
        let status = self.scrape_run(&run.source_id, &run.run_id)?.status;
        let target_status: String = self.db.query_row(
            "SELECT status FROM scrape_target WHERE run_id=?1 AND item_id=?2",
            params![run.run_id, target.item.item_id],
            |r| r.get(0),
        )?;
        if current.input_version != target.input_version
            || !["running", "queued"].contains(&status.as_str())
            || self.scan_in_progress(run)?
            || target_status == "cancelled"
        {
            self.finish_target(run, target, "queued", None, None, None)?;
            tx.commit()?;
            return Ok(false);
        }
        if target.item.kind == ItemKind::Season {
            let number = target
                .item
                .season_number
                .ok_or_else(|| Error::Invalid("season has no number".into()))?;
            if payload.get("season_number").and_then(Value::as_i64) != Some(number) {
                return Err(Error::Invalid("TMDB season identity mismatch".into()));
            }
            self.write_child_metadata(
                &target.item,
                &run.language,
                payload,
                target.parent_revision,
            )?;
            let episodes = payload
                .get("episodes")
                .and_then(Value::as_array)
                .ok_or_else(|| Error::Invalid("season has no episode list".into()))?;
            let mut q = self.db.prepare("SELECT item_id,episode_number FROM catalog_item WHERE source_id=?1 AND parent_id=?2 AND kind='episode'")?;
            let children = q
                .query_map(params![run.source_id, target.item.item_id], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            for (id, number) in children {
                if let Some(metadata) = episodes
                    .iter()
                    .find(|e| e.get("episode_number").and_then(Value::as_i64) == Some(number))
                {
                    self.write_child_metadata(
                        &self.item(&run.source_id, &id)?,
                        &run.language,
                        metadata,
                        target.parent_revision,
                    )?;
                }
            }
        } else {
            let id = payload
                .get("id")
                .and_then(Value::as_i64)
                .filter(|id| *id > 0)
                .ok_or_else(|| Error::Invalid("TMDB entity has no ID".into()))?;
            if target.tmdb_id.is_some_and(|expected| expected != id) {
                return Err(Error::Invalid(
                    "automatic work cannot replace the matched identity".into(),
                ));
            }
            // No nested transaction: the guarded write and revision share this transaction.
            self.db.execute("INSERT INTO item_match VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(source_id,item_id) DO UPDATE SET tmdb_id=excluded.tmdb_id,language=excluded.language,metadata=excluded.metadata,manual_lock=excluded.manual_lock,fetched_at=excluded.fetched_at",params![run.source_id,target.item.item_id,if target.item.kind==ItemKind::Movie {"movie"} else {"tv"},id,run.language,payload.to_string(),target.manual,crate::now()])?;
            self.db.execute("UPDATE catalog_item SET match_revision=match_revision+1 WHERE source_id=?1 AND item_id=?2",params![run.source_id,target.item.item_id])?;
        }
        self.finish_target(run, target, "completed", None, None, None)?;
        tx.commit()?;
        Ok(true)
    }

    pub fn bind_match_checked(
        &self,
        target: &Target,
        language: &str,
        id: i64,
        payload: &Value,
    ) -> Result<(), Error> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let item = &target.item;
        if self
            .match_target(&item.source_id, &item.item_id, language, true)?
            .input_version
            != target.input_version
        {
            return Err(Error::Invalid(
                "catalog changed during matching; please retry".into(),
            ));
        }
        if !matches!(item.kind, ItemKind::Movie | ItemKind::Series)
            || id <= 0
            || payload.get("id").and_then(Value::as_i64) != Some(id)
        {
            return Err(Error::Invalid("TMDB identity mismatch".into()));
        }
        tx.execute("INSERT INTO item_match VALUES(?1,?2,?3,?4,?5,?6,1,?7) ON CONFLICT(source_id,item_id) DO UPDATE SET tmdb_id=excluded.tmdb_id,language=excluded.language,metadata=excluded.metadata,manual_lock=1,fetched_at=excluded.fetched_at",params![item.source_id,item.item_id,if item.kind==ItemKind::Movie {"movie"} else {"tv"},id,language,payload.to_string(),crate::now()])?;
        tx.execute("UPDATE catalog_item SET match_revision=match_revision+1 WHERE source_id=?1 AND item_id=?2",params![item.source_id,item.item_id])?;
        tx.execute("DELETE FROM item_metadata WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND series_id=?2)",params![item.source_id,item.item_id])?;
        tx.execute("UPDATE scrape_target SET status='completed',error_kind=NULL,last_error=NULL,next_retry_at=NULL WHERE item_id=?2 AND run_id IN (SELECT run_id FROM scrape_run WHERE source_id=?1) AND status!='running'",params![item.source_id,item.item_id])?;
        tx.commit()?;
        Ok(())
    }

    fn write_child_metadata(
        &self,
        item: &Item,
        language: &str,
        payload: &Value,
        revision: i64,
    ) -> Result<(), Error> {
        self.db.execute("INSERT INTO item_metadata VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(source_id,item_id) DO UPDATE SET language=excluded.language,metadata=excluded.metadata,parent_revision=excluded.parent_revision,fetched_at=excluded.fetched_at",params![item.source_id,item.item_id,language,payload.to_string(),revision,crate::now()])?;
        Ok(())
    }

    pub fn unbind_match(&self, source: &str, item_id: &str) -> Result<(), Error> {
        let item = self.item(source, item_id)?;
        if !matches!(item.kind, ItemKind::Movie | ItemKind::Series) {
            return Err(Error::Invalid("unbind the movie or whole series".into()));
        }
        let tx = rusqlite::Transaction::new_unchecked(
            &self.db,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        tx.execute(
            "DELETE FROM item_match WHERE source_id=?1 AND item_id=?2",
            params![source, item_id],
        )?;
        tx.execute("UPDATE catalog_item SET match_revision=match_revision+1 WHERE source_id=?1 AND item_id=?2",params![source,item_id])?;
        tx.execute("DELETE FROM item_metadata WHERE source_id=?1 AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND series_id=?2)",params![source,item_id])?;
        // Retire in-flight work for an explicit unbind. A separate new scan or
        // scrape can identify it again; an old result cannot immediately rebind.
        tx.execute("UPDATE scrape_target SET status='cancelled',error_kind=NULL,last_error=NULL,next_retry_at=NULL WHERE run_id IN (SELECT run_id FROM scrape_run WHERE source_id=?1) AND item_id IN (SELECT item_id FROM catalog_item WHERE source_id=?1 AND (item_id=?2 OR series_id=?2))",params![source,item_id])?;
        tx.commit()?;
        Ok(())
    }
}
