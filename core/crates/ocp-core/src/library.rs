//! Independent file-library storage and workers, outside the playback state mutex.
use crate::library_scrape::{self, Credentials, Gate};
use ocp_library::{scan, Error, LibraryType, Query, SourceKind, Store};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const RECEIPT_TTL: Duration = Duration::from_secs(600);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ValidateArgs {
    pub api_key: String,
    pub api_base: String,
    pub credential_revision: String,
    pub draft_id: String,
    #[serde(default = "default_language")]
    pub language: String,
}

fn default_language() -> String {
    "zh-CN".into()
}

impl ValidateArgs {
    pub fn check(&self) -> Result<(), Error> {
        for value in [
            &self.api_key,
            &self.api_base,
            &self.credential_revision,
            &self.draft_id,
            &self.language,
        ] {
            nonempty(value)?;
        }
        Ok(())
    }
}

struct Verification {
    draft_id: String,
    credential_revision: String,
    api_base: String,
    credential_digest: Vec<u8>,
    expires: Instant,
}

struct Access {
    root: PathBuf,
    access_ref: Option<String>,
    expires: Instant,
    remote: Option<ocp_resource::Provider>,
    verified_directories: HashSet<String>,
}

struct Worker {
    control: Arc<AtomicU8>,
    handle: JoinHandle<()>,
    credential_generation: Option<u64>,
}

#[derive(Default)]
pub(crate) struct Runtime {
    store: Option<Store>,
    verifications: HashMap<String, Verification>,
    accesses: HashMap<String, Access>,
    workers: HashMap<String, Worker>,
    scrapers: HashMap<String, Worker>,
    online: Option<Credentials>,
    gate: Gate,
    credential_revision: Option<String>,
    credential_digest: Option<Vec<u8>>,
    credential_api_base: Option<String>,
    access_generation: u64,
    remote: HashMap<String, ocp_resource::Provider>,
    remote_epochs: HashMap<String, u64>,
    resources: HashMap<String, ocp_resource::bridge::Lease>,
}

impl Drop for Runtime {
    fn drop(&mut self) {
        for worker in self.workers.values() {
            worker.control.store(scan::PAUSE, Ordering::Release);
        }
        for worker in self.scrapers.values() {
            worker.control.store(scan::PAUSE, Ordering::Release);
        }
        // No native worker may outlive the ABI handle and library unload.
        for (_, worker) in self.workers.drain() {
            let _ = worker.handle.join();
        }
        for (_, worker) in self.scrapers.drain() {
            let _ = worker.handle.join();
        }
    }
}

impl Runtime {
    pub fn begin_validation(&mut self, input: &ValidateArgs) -> Result<u64, Error> {
        input.check()?;
        let digest = Sha256::digest(input.api_key.trim().as_bytes()).to_vec();
        if self.credential_revision.as_deref() != Some(&input.credential_revision)
            || self.credential_digest.as_ref() != Some(&digest)
            || self.credential_api_base.as_deref() != Some(&input.api_base)
            || self
                .online
                .as_ref()
                .is_some_and(|c| c.language != input.language)
        {
            self.verifications.clear();
            self.access_generation = self.access_generation.wrapping_add(1);
            self.revoke_online();
        }
        self.credential_revision = Some(input.credential_revision.clone());
        self.credential_digest = Some(digest.clone());
        self.credential_api_base = Some(input.api_base.clone());
        Ok(self.access_generation)
    }

    /// Only the authenticated network command may mint creation receipts.
    pub fn validated(&mut self, input: &ValidateArgs, generation: u64) -> Result<Value, Error> {
        if generation != self.access_generation
            || self.credential_revision.as_deref() != Some(&input.credential_revision)
        {
            return Err(Error::Invalid(
                "TMDB configuration changed during validation".into(),
            ));
        }
        self.online = Some(Credentials {
            key: input.api_key.trim().into(),
            api_base: input.api_base.clone(),
            language: input.language.clone(),
            generation,
        });
        *self
            .gate
            .lock()
            .map_err(|_| Error::Invalid("TMDB credential service unavailable".into()))? =
            library_scrape::Epoch {
                generation,
                valid: true,
            };
        let digest = Sha256::digest(input.api_key.trim().as_bytes()).to_vec();
        self.verifications
            .retain(|_, v| v.expires > Instant::now() && v.draft_id != input.draft_id);
        if self.verifications.len() >= 32 {
            return Err(Error::Invalid("too many pending library drafts".into()));
        }
        let id = ocp_library::id();
        self.verifications.insert(
            id.clone(),
            Verification {
                draft_id: input.draft_id.clone(),
                credential_revision: input.credential_revision.clone(),
                api_base: input.api_base.clone(),
                credential_digest: digest,
                expires: Instant::now() + RECEIPT_TTL,
            },
        );
        Ok(json!({"status":"valid","verificationId":id,"expiresInSeconds":RECEIPT_TTL.as_secs()}))
    }

    pub fn call(
        &mut self,
        method: &str,
        args: Value,
        default_directory: Option<&str>,
    ) -> Result<Value, Error> {
        self.reap();
        match method {
            "library.capabilities" => {
                return Ok(
                    json!({"schemaVersion":5,"sourceKinds":["localFolder","webdav","smb"],"libraryTypes":["movies","tvshows"],"aggregation":false,"backgroundScan":true,"tmdbAccessValidation":true,"tmdbScraping":true,"remoteProviders":true}),
                )
            }
            "tmdb.access.invalidate" => {
                self.verifications.clear();
                self.credential_revision = None;
                self.credential_digest = None;
                self.credential_api_base = None;
                self.access_generation = self.access_generation.wrapping_add(1);
                self.revoke_online();
                return Ok(json!({"invalidated":true}));
            }
            "library.access.prepare" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase", deny_unknown_fields)]
                struct Input {
                    root_path: String,
                    access_ref: Option<String>,
                }
                let input: Input = serde_json::from_value(args)?;
                let root = std::fs::canonicalize(&input.root_path)?;
                if !root.is_dir() {
                    return Err(Error::Invalid("select a directory".into()));
                }
                self.accesses.retain(|_, a| a.expires > Instant::now());
                if self.accesses.len() >= 32 {
                    return Err(Error::Invalid("too many pending directory leases".into()));
                }
                let id = ocp_library::id();
                self.accesses.insert(
                    id.clone(),
                    Access {
                        root: root.clone(),
                        access_ref: input.access_ref,
                        expires: Instant::now() + RECEIPT_TTL,
                        remote: None,
                        verified_directories: HashSet::new(),
                    },
                );
                return Ok(json!({"accessId":id,"rootPath":root.to_string_lossy()}));
            }
            "library.open" => {
                let directory = Path::new(string(&args, "directory")?);
                let path = directory.join(ocp_library::FILE_NAME);
                if self.store.as_ref().is_some_and(|s| s.path() == path) {
                    return Ok(json!({"path":path.to_string_lossy()}));
                }
                if !self.workers.is_empty()
                    || !self.scrapers.is_empty()
                    || !self.resources.is_empty()
                {
                    return Err(Error::Invalid(
                        "pause running scans before changing library database".into(),
                    ));
                }
                let store = Store::open(directory)?;
                store.recover_jobs()?;
                store.recover_scrapes()?;
                self.store = Some(store);
                self.remote.clear();
                self.remote_epochs.clear();
                self.accesses.clear();
                return Ok(json!({"path":path.to_string_lossy()}));
            }
            _ => {}
        }
        if self.store.is_none() {
            let directory = default_directory
                .ok_or_else(|| Error::Invalid("open the library database first".into()))?;
            let store = Store::open(Path::new(directory))?;
            store.recover_jobs()?;
            store.recover_scrapes()?;
            self.store = Some(store);
        }
        match method {
            "library.playback.release" => {
                self.resources.remove(string(&args, "leaseId")?);
                Ok(json!({"released":true}))
            }
            "library.create" => self.create(args),
            "library.rename" => {
                let source = string(&args, "sourceId")?;
                let library = string(&args, "libraryId")?;
                let name = string(&args, "name")?;
                Ok(json!({"library":self.db()?.rename_library(source, library, name)?}))
            }
            "library.delete" => {
                let source = string(&args, "sourceId")?.to_owned();
                let library = string(&args, "libraryId")?.to_owned();
                self.stop_library_workers(&source, &library)?;
                self.db()?.delete_library(&source, &library)?;
                Ok(json!({"deleted":true}))
            }
            "library.root.add" => self.add_root(args),
            "library.root.remove" => {
                let source = string(&args, "sourceId")?.to_owned();
                let library = string(&args, "libraryId")?.to_owned();
                let root_id = string(&args, "rootId")?.to_owned();
                self.stop_library_workers(&source, &library)?;
                let updated = self
                    .db()?
                    .remove_library_root(&source, &library, &root_id)?;
                Ok(json!({"library":updated}))
            }
            "library.source.delete" => {
                let source = string(&args, "sourceId")?.to_owned();
                self.stop_source_workers(&source)?;
                self.remote.remove(&source);
                self.remote_epochs.remove(&source);
                self.db()?.delete_source(&source)?;
                Ok(json!({"deleted":true}))
            }
            "library.sources.list" => Ok(json!({"sources":self.db()?.sources()?})),
            "library.libraries.list" => {
                Ok(json!({"libraries":self.db()?.libraries(string(&args,"sourceId")?)?}))
            }
            "library.query.page" => {
                let query: Query = serde_json::from_value(args)?;
                let (items, total) = self.db()?.query(&query)?;
                Ok(json!({"items":items,"totalCount":total,"startIndex":query.start_index}))
            }
            "library.query.detail" => {
                let source = string(&args, "sourceId")?;
                let item = string(&args, "itemId")?;
                Ok(
                    json!({"item":self.db()?.item(source,item)?,"assets":self.db()?.assets(source,item)?,"progress":self.db()?.progress(source,item)?}),
                )
            }
            "library.query.resume" => Ok(json!({"items":self.db()?.resume(
                string(&args,"sourceId")?, args.get("limit").and_then(Value::as_i64).unwrap_or(20))?})),
            "library.query.nextUp" => Ok(json!({"items":self.db()?.next_up(
                string(&args,"sourceId")?, args.get("limit").and_then(Value::as_i64).unwrap_or(20))?})),
            "library.scan.start" | "library.scan.resume" => {
                let source = string(&args, "sourceId")?;
                let job = if method == "library.scan.resume" {
                    let job = self.db()?.job(source, string(&args, "jobId")?)?;
                    if ![
                        "paused",
                        "interrupted",
                        "waitingPermission",
                        "waitingCredentials",
                        "waitingNetwork",
                        "queued",
                    ]
                    .contains(&job.status.as_str())
                    {
                        return Err(Error::Invalid(
                            "job cannot be resumed in its current state".into(),
                        ));
                    }
                    job
                } else {
                    self.db()?.start_scan(source, string(&args, "libraryId")?)?
                };
                if !self.workers.contains_key(&job.job_id) && self.workers.len() >= 2 {
                    return Err(Error::Invalid(
                        "at most two scans may run; pause another scan first".into(),
                    ));
                }
                self.spawn(&job)?;
                self.queue_scrape(source, &job.library_id, false)?;
                Ok(json!({"job":self.db()?.job(source,&job.job_id)?}))
            }
            "library.scan.pause" | "library.scan.cancel" => {
                let source = string(&args, "sourceId")?;
                let id = string(&args, "jobId")?;
                let job = self.db()?.job(source, id)?;
                if let Some(worker) = self.workers.get(id) {
                    worker.control.store(
                        if method == "library.scan.pause" {
                            scan::PAUSE
                        } else {
                            scan::CANCEL
                        },
                        Ordering::Release,
                    );
                } else if [
                    "queued",
                    "interrupted",
                    "paused",
                    "waitingPermission",
                    "waitingCredentials",
                    "waitingNetwork",
                ]
                .contains(&job.status.as_str())
                {
                    self.db()?.set_job_status(
                        id,
                        if method == "library.scan.pause" {
                            "paused"
                        } else {
                            "cancelled"
                        },
                    )?;
                }
                Ok(json!({"job":self.db()?.job(source,id)?}))
            }
            "library.jobs.snapshot" => {
                Ok(json!({"jobs":self.db()?.jobs(string(&args,"sourceId")?)?}))
            }
            "library.scrape.start" => {
                let source = string(&args, "sourceId")?;
                let library = string(&args, "libraryId")?;
                let run = self.queue_scrape(
                    source,
                    library,
                    args.get("refresh")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                )?;
                Ok(json!({"run":run}))
            }
            "library.scrape.snapshot" => {
                Ok(json!({"runs":self.db()?.scrape_runs(string(&args,"sourceId")?)?}))
            }
            "library.scrape.pause" | "library.scrape.cancel" => {
                let source = string(&args, "sourceId")?;
                let id = string(&args, "runId")?;
                self.db()?.scrape_run(source, id)?;
                if let Some(worker) = self.scrapers.get(id) {
                    worker.control.store(
                        if method == "library.scrape.cancel" {
                            scan::CANCEL
                        } else {
                            scan::PAUSE
                        },
                        Ordering::Release,
                    );
                }
                self.db()?.set_scrape_status(
                    id,
                    if method == "library.scrape.cancel" {
                        "cancelled"
                    } else {
                        "paused"
                    },
                )?;
                Ok(json!({"run":self.db()?.scrape_run(source,id)?}))
            }
            "library.scrape.resume" | "library.scrape.retry" => {
                let source = string(&args, "sourceId")?;
                let id = string(&args, "runId")?;
                let run = self.db()?.scrape_run(source, id)?;
                if let Some(worker) = self.scrapers.get(id) {
                    if method == "library.scrape.resume"
                        && worker.control.load(Ordering::Acquire) == scan::RUN
                        && worker.credential_generation == Some(self.access_generation)
                        && self.require_online().is_ok()
                    {
                        return Ok(json!({"run":self.db()?.scrape_run(source,id)?}));
                    }
                    return Err(Error::Invalid(
                        "wait for the running scrape to stop before resuming".into(),
                    ));
                }
                let credentials = self.require_online()?;
                if method == "library.scrape.resume"
                    && ![
                        "paused",
                        "interrupted",
                        "waitingCredentials",
                        "waitingNetwork",
                        "queued",
                    ]
                    .contains(&run.status.as_str())
                {
                    return Err(Error::Invalid(
                        "scrape cannot be resumed in its current state".into(),
                    ));
                }
                self.db()?
                    .retry_scrape(&run, method == "library.scrape.retry")?;
                self.db()?
                    .change_scrape_language(&run, &credentials.language)?;
                self.spawn_scraper(&self.db()?.scrape_run(source, id)?)?;
                Ok(json!({"run":self.db()?.scrape_run(source,id)?}))
            }
            "library.match.unbind" => {
                self.db()?
                    .unbind_match(string(&args, "sourceId")?, string(&args, "itemId")?)?;
                Ok(json!({"unbound":true}))
            }
            "library.playback.prepare" => {
                let source = string(&args, "sourceId")?;
                let item = string(&args, "itemId")?;
                let asset = string(&args, "assetId")?;
                let path = self.db()?.playback_path(source, item, asset)?;
                let uri = url::Url::from_file_path(path)
                    .map_err(|_| Error::Invalid("invalid local playback path".into()))?
                    .to_string();
                Ok(
                    json!({"sourceId":source,"itemId":item,"assetId":asset,"uri":uri,"headers":{},"progress":self.db()?.progress(source,item)?}),
                )
            }
            "library.progress.record" => {
                let progress: ocp_library::Progress = serde_json::from_value(args)?;
                Ok(
                    json!({"accepted":self.db()?.record_progress(&progress)?,"progress":self.db()?.progress(&progress.source_id,&progress.item_id)?}),
                )
            }
            "library.progress.get" => Ok(
                json!({"progress":self.db()?.progress(string(&args,"sourceId")?,string(&args,"itemId")?)?}),
            ),
            "library.progress.markPlayed" | "library.progress.markUnplayed" => {
                let source = string(&args, "sourceId")?;
                let item = string(&args, "itemId")?;
                let recorded_at = args
                    .get("recordedAt")
                    .and_then(Value::as_f64)
                    .unwrap_or_else(ocp_library::now);
                let progress = self.db()?.mark_played(
                    source,
                    item,
                    method == "library.progress.markPlayed",
                    recorded_at,
                )?;
                Ok(json!({"progress":progress}))
            }
            _ => Err(Error::Invalid(format!("unknown library command: {method}"))),
        }
    }

    fn db(&self) -> Result<&Store, Error> {
        self.store
            .as_ref()
            .ok_or_else(|| Error::Invalid("library database is not open".into()))
    }

    fn create(&mut self, args: Value) -> Result<Value, Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Input {
            draft_id: String,
            verification_id: String,
            credential_revision: String,
            api_base: String,
            access_id: String,
            kind: SourceKind,
            source_id: Option<String>,
            source_name: String,
            root_path: String,
            name: String,
            #[serde(rename = "type")]
            typ: LibraryType,
        }
        let input: Input = serde_json::from_value(args)?;
        self.verifications
            .get(&input.verification_id)
            .filter(|v| {
                let draft_matches = v.draft_id == input.draft_id
                    || input
                        .draft_id
                        .strip_prefix(&v.draft_id)
                        .is_some_and(|rest| rest.starts_with(':') && rest.len() > 1);
                v.expires > Instant::now()
                    && draft_matches
                    && v.credential_revision == input.credential_revision
                    && v.api_base == input.api_base
                    && self.credential_revision.as_deref() == Some(&v.credential_revision)
                    && self.credential_digest.as_ref() == Some(&v.credential_digest)
                    && library_scrape::valid(&self.gate, self.access_generation)
            })
            .ok_or_else(|| {
                Error::Invalid(
                    "validate the current TMDB credential before creating this library".into(),
                )
            })?;
        let access = self
            .accesses
            .get(&input.access_id)
            .filter(|a| a.expires > Instant::now())
            .ok_or_else(|| Error::Invalid("directory access lease has expired".into()))?;
        let previous = self.db()?.created_draft(&input.draft_id)?.is_some();
        let provider = access.remote.clone();
        let library = if input.kind != SourceKind::LocalFolder {
            let provider = provider
                .as_ref()
                .filter(|p| p.kind() == input.kind.as_str())
                .ok_or_else(|| {
                    Error::Invalid("validate access for this source kind first".into())
                })?;
            let root = provider.scoped(&input.root_path).map_err(remote_error)?;
            if !access.verified_directories.contains(root.root()) {
                return Err(Error::Invalid(
                    "open the selected remote directory before adding it".into(),
                ));
            }
            let create = if input.kind == SourceKind::Smb {
                Store::create_smb
            } else {
                Store::create_webdav
            };
            create(
                self.db()?,
                &input.draft_id,
                input.source_id.as_deref(),
                &input.source_name,
                provider.root(),
                access.access_ref.as_deref(),
                &input.name,
                root.root(),
                input.typ,
            )?
        } else {
            if provider.is_some() {
                return Err(Error::Invalid("access belongs to a remote source".into()));
            }
            let root = std::fs::canonicalize(&input.root_path)?;
            if !root.is_dir() || !root.starts_with(&access.root) {
                return Err(Error::Invalid(
                    "selected directory is outside the authorized root".into(),
                ));
            }
            self.db()?.create_local(
                &input.draft_id,
                input.source_id.as_deref(),
                &input.source_name,
                &access.root,
                access.access_ref.as_deref(),
                &input.name,
                &root,
                input.typ,
            )?
        };
        if let Some(provider) = provider {
            if (!previous || !self.remote.contains_key(&library.source_id))
                && !self
                    .remote
                    .get(&library.source_id)
                    .is_some_and(|old| old.same_access(&provider))
            {
                let epoch = self
                    .remote_epochs
                    .entry(library.source_id.clone())
                    .or_default();
                *epoch = epoch.wrapping_add(1);
                for job in self.db()?.jobs(&library.source_id)? {
                    if let Some(worker) = self.workers.get(&job.job_id) {
                        worker.control.store(scan::PAUSE, Ordering::Release);
                    }
                }
                self.remote.insert(library.source_id.clone(), provider);
            }
        }
        if previous {
            if let Some(job) = self
                .db()?
                .initial_scan(&library.source_id, &library.library_id)?
            {
                return Ok(json!({"library":library,"job":job}));
            }
        }
        let job = self
            .db()?
            .start_scan(&library.source_id, &library.library_id)?;
        if self.workers.len() < 2 {
            self.spawn(&job)?;
        }
        self.queue_scrape(&library.source_id, &library.library_id, false)?;
        Ok(json!({"library":library,"job":job}))
    }

    fn add_root(&mut self, args: Value) -> Result<Value, Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Input {
            source_id: String,
            library_id: String,
            access_id: String,
            kind: SourceKind,
            root_path: String,
        }
        let input: Input = serde_json::from_value(args)?;
        let access = self
            .accesses
            .get(&input.access_id)
            .filter(|a| a.expires > Instant::now())
            .ok_or_else(|| Error::Invalid("directory access lease has expired".into()))?;
        let provider = access.remote.clone();
        let (library, added) = if input.kind != SourceKind::LocalFolder {
            let provider = provider
                .as_ref()
                .filter(|p| p.kind() == input.kind.as_str())
                .ok_or_else(|| {
                    Error::Invalid("validate access for this source kind first".into())
                })?;
            let root = provider.scoped(&input.root_path).map_err(remote_error)?;
            if !access.verified_directories.contains(root.root()) {
                return Err(Error::Invalid(
                    "open the selected remote directory before adding it".into(),
                ));
            }
            if input.kind == SourceKind::Smb {
                self.db()?.add_smb_root(
                    &input.source_id,
                    &input.library_id,
                    provider.root(),
                    access.access_ref.as_deref(),
                    root.root(),
                )?
            } else {
                self.db()?.add_webdav_root(
                    &input.source_id,
                    &input.library_id,
                    provider.root(),
                    access.access_ref.as_deref(),
                    root.root(),
                )?
            }
        } else {
            if provider.is_some() {
                return Err(Error::Invalid("access belongs to a remote source".into()));
            }
            let root = std::fs::canonicalize(&input.root_path)?;
            if !root.is_dir() || !root.starts_with(&access.root) {
                return Err(Error::Invalid(
                    "selected directory is outside the authorized root".into(),
                ));
            }
            self.db()?.add_local_root(
                &input.source_id,
                &input.library_id,
                &access.root,
                access.access_ref.as_deref(),
                &root,
            )?
        };
        if let Some(provider) = provider {
            if !self
                .remote
                .get(&library.source_id)
                .is_some_and(|old| old.same_access(&provider))
            {
                let epoch = self
                    .remote_epochs
                    .entry(library.source_id.clone())
                    .or_default();
                *epoch = epoch.wrapping_add(1);
                self.remote.insert(library.source_id.clone(), provider);
            }
        }
        let job = self
            .db()?
            .start_scan(&library.source_id, &library.library_id)?;
        if self.workers.len() < 2 {
            self.spawn(&job)?;
        }
        self.queue_scrape(&library.source_id, &library.library_id, false)?;
        Ok(json!({"library":library,"root":added,"job":job}))
    }

    fn stop_library_workers(&mut self, source_id: &str, library_id: &str) -> Result<(), Error> {
        let job_ids: Vec<String> = self
            .db()?
            .jobs(source_id)?
            .into_iter()
            .filter(|j| j.library_id == library_id)
            .map(|j| j.job_id)
            .collect();
        for id in &job_ids {
            if let Some(worker) = self.workers.get(id) {
                worker.control.store(scan::CANCEL, Ordering::Release);
            }
        }
        for id in job_ids {
            if let Some(worker) = self.workers.remove(&id) {
                let _ = worker.handle.join();
            }
        }
        let run_ids: Vec<String> = self
            .db()?
            .scrape_runs(source_id)?
            .into_iter()
            .filter(|r| r.library_id == library_id)
            .map(|r| r.run_id)
            .collect();
        for id in &run_ids {
            if let Some(worker) = self.scrapers.get(id) {
                worker.control.store(scan::CANCEL, Ordering::Release);
            }
        }
        for id in run_ids {
            if let Some(worker) = self.scrapers.remove(&id) {
                let _ = worker.handle.join();
            }
        }
        Ok(())
    }

    fn stop_source_workers(&mut self, source_id: &str) -> Result<(), Error> {
        let libraries = self.db()?.libraries(source_id)?;
        for lib in libraries {
            self.stop_library_workers(source_id, &lib.library_id)?;
        }
        Ok(())
    }

    fn spawn(&mut self, job: &ocp_library::Job) -> Result<(), Error> {
        if let Some(worker) = self.workers.get(&job.job_id) {
            if worker.control.load(Ordering::Acquire) != scan::RUN {
                return Err(Error::Invalid(
                    "wait for the running scan to stop before resuming".into(),
                ));
            }
            return Ok(());
        }
        let path = self.db()?.path().to_owned();
        // Opening before spawn reports corruption/IO immediately instead of leaving a queued ghost job.
        let store = Store::open_path(&path)?;
        let source = store.source(&job.source_id)?;
        let provider = if source.kind != SourceKind::LocalFolder {
            let Some(provider) = self.remote.get(&job.source_id) else {
                self.db()?
                    .set_job_status(&job.job_id, "waitingCredentials")?;
                return Ok(());
            };
            Some(provider.clone())
        } else {
            None
        };
        let job = job.clone();
        let id = job.job_id.clone();
        let control = Arc::new(AtomicU8::new(scan::RUN));
        let worker_control = control.clone();
        let handle = std::thread::Builder::new()
            .name("ocp-library-scan".into())
            .spawn(move || {
                let fallback = Store::open_path(store.path());
                let result = if let Some(provider) = provider {
                    crate::library_remote::run(store, job.clone(), provider, worker_control)
                } else {
                    scan::run(&store, &job, &worker_control)
                };
                if let Err(error) = result {
                    let Ok(store) = fallback else {
                        return;
                    };
                    let _ = store.scan_error(&job.job_id, &error.to_string());
                    let _ = store.set_job_status(&job.job_id, "failed");
                }
            })?;
        self.workers.insert(
            id,
            Worker {
                control,
                handle,
                credential_generation: None,
            },
        );
        Ok(())
    }

    fn reap(&mut self) {
        let done: Vec<_> = self
            .workers
            .iter()
            .filter(|(_, w)| w.handle.is_finished())
            .map(|(id, _)| id.clone())
            .collect();
        for id in done {
            if let Some(worker) = self.workers.remove(&id) {
                let _ = worker.handle.join();
            }
        }
        if self.workers.len() < 2 {
            if let Ok(queued) = self.db().and_then(|store| store.queued_jobs(8)) {
                for job in queued {
                    if self.workers.len() >= 2 {
                        break;
                    }
                    if self.workers.contains_key(&job.job_id) {
                        continue;
                    }
                    let _ = self.spawn(&job);
                }
            }
        }
        let done: Vec<_> = self
            .scrapers
            .iter()
            .filter(|(_, w)| w.handle.is_finished())
            .map(|(id, _)| id.clone())
            .collect();
        for id in done {
            if let Some(worker) = self.scrapers.remove(&id) {
                let _ = worker.handle.join();
            }
        }
        if self.require_online().is_ok() && self.scrapers.len() < 2 {
            let queued = self.db().and_then(|store| {
                let sources = store.sources()?;
                sources
                    .iter()
                    .map(|s| store.scrape_runs(&s.source_id))
                    .collect::<Result<Vec<_>, _>>()
            });
            if let Ok(runs) = queued {
                for run in runs.into_iter().flatten().filter(|r| r.status == "queued") {
                    if self.scrapers.len() >= 2 {
                        break;
                    }
                    let _ = self.spawn_scraper(&run);
                }
            }
        }
    }

    fn revoke_online(&mut self) {
        self.online = None;
        if let Ok(mut epoch) = self.gate.lock() {
            epoch.generation = self.access_generation;
            epoch.valid = false;
        }
    }

    fn require_online(&self) -> Result<Credentials, Error> {
        self.online
            .as_ref()
            .filter(|c| library_scrape::valid(&self.gate, c.generation))
            .cloned()
            .ok_or_else(|| {
                Error::Invalid(
                    "configure and validate TMDB credentials before online scraping".into(),
                )
            })
    }

    fn queue_scrape(
        &mut self,
        source: &str,
        library: &str,
        refresh: bool,
    ) -> Result<ocp_library::scrape::ScrapeRun, Error> {
        let language = self
            .online
            .as_ref()
            .map(|c| c.language.as_str())
            .unwrap_or("zh-CN");
        let run = self
            .db()?
            .start_scrape(source, library, language, refresh)?;
        // An automatic rescan cannot undo the user's explicit pause.
        if ["queued", "running"].contains(&run.status.as_str()) {
            if self.require_online().is_ok() && self.scrapers.len() < 2 {
                self.spawn_scraper(&run)?;
            } else if self.require_online().is_err() {
                self.db()?
                    .set_scrape_status(&run.run_id, "waitingCredentials")?;
            }
        }
        self.db()?.scrape_run(source, &run.run_id)
    }

    fn spawn_scraper(&mut self, run: &ocp_library::scrape::ScrapeRun) -> Result<(), Error> {
        if self.scrapers.contains_key(&run.run_id) {
            return Ok(());
        }
        if self.scrapers.len() >= 2 {
            return Err(Error::Invalid("at most two scrape queues may run".into()));
        }
        let credentials = self.require_online()?;
        let credential_generation = Some(credentials.generation);
        let store = Store::open_path(self.db()?.path())?;
        let run = run.clone();
        let id = run.run_id.clone();
        let gate = self.gate.clone();
        let control = Arc::new(AtomicU8::new(scan::RUN));
        let worker_control = control.clone();
        let handle = std::thread::Builder::new()
            .name("ocp-library-tmdb".into())
            .spawn(move || {
                let fallback = Store::open_path(store.path());
                if library_scrape::run(store, run.clone(), credentials, gate, worker_control)
                    .is_err()
                {
                    if let Ok(store) = fallback {
                        let _ = store.set_scrape_status(&run.run_id, "failed");
                    }
                }
            })?;
        self.scrapers.insert(
            id,
            Worker {
                control,
                handle,
                credential_generation,
            },
        );
        Ok(())
    }

    pub(crate) fn prepare_match(&self, args: &Value, binding: bool) -> Result<MatchRequest, Error> {
        let credentials = self.require_online()?;
        let source = string(args, "sourceId")?;
        let target = self.db()?.match_target(
            source,
            string(args, "itemId")?,
            &credentials.language,
            true,
        )?;
        if !matches!(
            target.item.kind,
            ocp_library::ItemKind::Movie | ocp_library::ItemKind::Series
        ) {
            return Err(Error::Invalid(
                "select the whole series for matching".into(),
            ));
        }
        let tmdb_id = if binding {
            if string(args, "inputVersion")? != target.input_version {
                return Err(Error::Invalid(
                    "catalog changed; search for candidates again".into(),
                ));
            }
            Some(
                args.get("tmdbId")
                    .and_then(Value::as_i64)
                    .filter(|id| *id > 0)
                    .ok_or_else(|| Error::Invalid("positive tmdbId is required".into()))?,
            )
        } else {
            None
        };
        let query = if binding {
            None
        } else {
            Some(
                args.get("query")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or(&target.item.title)
                    .to_owned(),
            )
        };
        Ok(MatchRequest {
            credentials,
            gate: self.gate.clone(),
            target,
            query,
            tmdb_id,
        })
    }

    pub(crate) fn finish_match(
        &mut self,
        request: &MatchRequest,
        payload: Value,
    ) -> Result<Value, Error> {
        let epoch = request
            .gate
            .lock()
            .map_err(|_| Error::Invalid("TMDB credential service unavailable".into()))?;
        if !epoch.valid || epoch.generation != request.credentials.generation {
            return Err(Error::Invalid(
                "TMDB configuration changed during matching".into(),
            ));
        }
        let item = &request.target.item;
        let current = self.db()?.match_target(
            &item.source_id,
            &item.item_id,
            &request.credentials.language,
            true,
        )?;
        if current.input_version != request.target.input_version {
            return Err(Error::Invalid(
                "catalog changed during matching; please retry".into(),
            ));
        }
        if let Some(id) = request.tmdb_id {
            self.db()?.bind_match_checked(
                &request.target,
                &request.credentials.language,
                id,
                &payload,
            )?;
            Ok(json!({"bound":true,"item":self.db()?.item(&item.source_id,&item.item_id)?}))
        } else {
            Ok(json!({"inputVersion":request.target.input_version,"candidates":payload}))
        }
    }

    pub(crate) fn online_failed(&mut self, generation: u64) {
        if self.access_generation == generation {
            self.verifications.clear();
            self.revoke_online();
        }
    }
}

pub(crate) struct MatchRequest {
    pub credentials: Credentials,
    pub gate: Gate,
    pub target: ocp_library::scrape::Target,
    pub query: Option<String>,
    pub tmdb_id: Option<i64>,
}

fn nonempty(value: &str) -> Result<(), Error> {
    if value.trim().is_empty() || value.contains('\0') {
        Err(Error::Invalid(
            "required text must be nonempty without NUL".into(),
        ))
    } else {
        Ok(())
    }
}

fn string<'a>(args: &'a Value, key: &str) -> Result<&'a str, Error> {
    let value = args
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Invalid(format!("{key} is required")))?;
    nonempty(value)?;
    Ok(value)
}

fn remote_error(error: ocp_resource::Error) -> Error {
    Error::Invalid(error.to_string())
}
pub(crate) struct RemoteRequest {
    provider: Option<ocp_resource::Provider>,
    relative: String,
    purpose: RemotePurpose,
}
enum RemotePurpose {
    Access {
        access_ref: Option<String>,
    },
    Browse {
        access_id: String,
    },
    Restore {
        source: String,
        epoch: u64,
    },
    Playback {
        source: String,
        item: String,
        asset: String,
        epoch: u64,
    },
    LocalPlayback(Value),
}
pub(crate) enum RemoteReply {
    Entries(Vec<ocp_resource::Entry>),
    Snapshot(ocp_resource::Snapshot),
    Local,
}
impl RemoteRequest {
    pub(crate) fn is_local(&self) -> bool {
        matches!(self.purpose, RemotePurpose::LocalPlayback(_))
    }

    pub(crate) async fn execute(&self) -> Result<RemoteReply, Error> {
        let Some(provider) = &self.provider else {
            return Ok(RemoteReply::Local);
        };
        if matches!(self.purpose, RemotePurpose::Playback { .. }) {
            Ok(RemoteReply::Snapshot(
                provider.probe(&self.relative).await.map_err(remote_error)?,
            ))
        } else {
            Ok(RemoteReply::Entries(
                provider.list(&self.relative).await.map_err(remote_error)?,
            ))
        }
    }
}
impl Runtime {
    pub(crate) fn prepare_remote(
        &mut self,
        method: &str,
        args: Value,
    ) -> Result<RemoteRequest, Error> {
        self.reap();
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Connection {
            root_url: String,
            credential: Value,
            access_ref: Option<String>,
            source_id: Option<String>,
        }
        match method {
            "library.webdav.access.prepare"
            | "library.webdav.credentials.restore"
            | "library.smb.access.prepare"
            | "library.smb.credentials.restore" => {
                let input: Connection = serde_json::from_value(args)?;
                let provider = if method.starts_with("library.smb.") {
                    ocp_resource::Provider::Smb(
                        ocp_smb::Provider::new(
                            &input.root_url,
                            serde_json::from_value(input.credential)?,
                        )
                        .map_err(|e| remote_error(e.into()))?,
                    )
                } else {
                    ocp_resource::Provider::Webdav(
                        ocp_webdav::Provider::new(
                            &input.root_url,
                            serde_json::from_value(input.credential)?,
                        )
                        .map_err(|e| remote_error(e.into()))?,
                    )
                };
                let purpose = if method.ends_with("restore") {
                    let source_id = input
                        .source_id
                        .ok_or_else(|| Error::Invalid("sourceId is required".into()))?;
                    let source = self.db()?.source(&source_id)?;
                    if source.kind.as_str() != provider.kind()
                        || source.root_path != provider.root()
                    {
                        return Err(Error::Invalid(
                            "remote credentials belong to a different source root".into(),
                        ));
                    }
                    let epoch = self.remote_epochs.entry(source_id.clone()).or_default();
                    *epoch = epoch.wrapping_add(1);
                    let epoch = *epoch;
                    self.remote.remove(&source_id);
                    for job in self.db()?.jobs(&source_id)? {
                        if let Some(worker) = self.workers.get(&job.job_id) {
                            worker.control.store(scan::PAUSE, Ordering::Release);
                        }
                    }
                    RemotePurpose::Restore {
                        source: source_id,
                        epoch,
                    }
                } else {
                    if input.source_id.is_some() {
                        return Err(Error::Invalid(
                            "use credentials.restore for an existing source".into(),
                        ));
                    }
                    RemotePurpose::Access {
                        access_ref: input.access_ref,
                    }
                };
                Ok(RemoteRequest {
                    provider: Some(provider),
                    relative: String::new(),
                    purpose,
                })
            }
            "library.webdav.browse" | "library.smb.browse" => {
                let access_id = string(&args, "accessId")?.to_owned();
                let access = self
                    .accesses
                    .get(&access_id)
                    .filter(|a| a.expires > Instant::now())
                    .ok_or_else(|| Error::Invalid("remote access has expired; reconnect".into()))?;
                let provider = access
                    .remote
                    .clone()
                    .filter(|p| method == format!("library.{}.browse", p.kind()))
                    .ok_or_else(|| {
                        Error::Invalid("access belongs to a different source kind".into())
                    })?;
                let relative = args
                    .get("relativePath")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                provider.directory_url(&relative).map_err(remote_error)?;
                Ok(RemoteRequest {
                    provider: Some(provider),
                    relative,
                    purpose: RemotePurpose::Browse { access_id },
                })
            }
            "library.playback.prepare" => {
                let source = string(&args, "sourceId")?.to_owned();
                if self.db()?.source(&source)?.kind == SourceKind::LocalFolder {
                    return Ok(RemoteRequest {
                        provider: None,
                        relative: String::new(),
                        purpose: RemotePurpose::LocalPlayback(args),
                    });
                }
                if self.resources.len() >= 32 {
                    return Err(Error::Invalid(
                        "close another file playback before opening more resources".into(),
                    ));
                }
                let item = string(&args, "itemId")?.to_owned();
                let asset = string(&args, "assetId")?.to_owned();
                let (root_path, path) = self.db()?.asset_location(&source, &item, &asset)?;
                let provider = self
                    .remote
                    .get(&source)
                    .ok_or_else(|| {
                        Error::Invalid("restore remote credentials before playback".into())
                    })?
                    .scoped(&root_path)
                    .map_err(remote_error)?;
                let epoch = *self.remote_epochs.get(&source).unwrap_or(&0);
                Ok(RemoteRequest {
                    provider: Some(provider),
                    relative: path,
                    purpose: RemotePurpose::Playback {
                        source,
                        item,
                        asset,
                        epoch,
                    },
                })
            }
            _ => Err(Error::Invalid("unknown remote library command".into())),
        }
    }
    pub(crate) fn finish_remote(
        &mut self,
        request: RemoteRequest,
        reply: RemoteReply,
    ) -> Result<Value, Error> {
        match request.purpose {
            RemotePurpose::LocalPlayback(args) => self.call("library.playback.prepare", args, None),
            RemotePurpose::Access { access_ref } => {
                self.accesses.retain(|_, a| a.expires > Instant::now());
                if self.accesses.len() >= 32 {
                    return Err(Error::Invalid("too many pending directory leases".into()));
                }
                let provider = request
                    .provider
                    .ok_or_else(|| Error::Invalid("missing provider".into()))?;
                let id = ocp_library::id();
                let root = provider.root().to_owned();
                self.accesses.insert(
                    id.clone(),
                    Access {
                        root: PathBuf::new(),
                        access_ref,
                        expires: Instant::now() + RECEIPT_TTL,
                        remote: Some(provider),
                        verified_directories: HashSet::from([root.clone()]),
                    },
                );
                Ok(json!({"accessId":id,"rootPath":root}))
            }
            RemotePurpose::Browse { access_id } => {
                let access = self
                    .accesses
                    .get_mut(&access_id)
                    .filter(|a| a.expires > Instant::now())
                    .ok_or_else(|| Error::Invalid("directory access has expired".into()))?;
                let provider = request
                    .provider
                    .ok_or_else(|| Error::Invalid("missing provider".into()))?;
                let root = provider
                    .directory_url(&request.relative)
                    .map_err(remote_error)?
                    .to_string();
                if access.verified_directories.len() >= 256 {
                    return Err(Error::Invalid(
                        "too many browsed directories; reconnect".into(),
                    ));
                }
                access.verified_directories.insert(root.clone());
                let RemoteReply::Entries(entries) = reply else {
                    return Err(Error::Invalid("invalid directory reply".into()));
                };
                Ok(json!({"rootPath":root,"relativePath":request.relative,"entries":entries}))
            }
            RemotePurpose::Restore { source, epoch } => {
                if self.remote_epochs.get(&source) != Some(&epoch) {
                    return Err(Error::Invalid(
                        "remote credentials changed during validation".into(),
                    ));
                }
                self.remote.insert(
                    source,
                    request
                        .provider
                        .ok_or_else(|| Error::Invalid("missing provider".into()))?,
                );
                Ok(json!({"restored":true}))
            }
            RemotePurpose::Playback {
                source,
                item,
                asset,
                epoch,
            } => {
                if *self.remote_epochs.get(&source).unwrap_or(&0) != epoch
                    || !self.remote.contains_key(&source)
                {
                    return Err(Error::Invalid(
                        "remote credentials changed during playback preparation".into(),
                    ));
                }
                if !self.db()?.assets(&source, &item)?.iter().any(|a| {
                    a.asset_id == asset && a.available && a.relative_path == request.relative
                }) {
                    return Err(Error::NotFound);
                }
                let RemoteReply::Snapshot(snapshot) = reply else {
                    return Err(Error::Invalid("invalid range reply".into()));
                };
                if self.resources.len() >= 32 {
                    return Err(Error::Invalid("too many active playback resources".into()));
                }
                let lease = ocp_resource::bridge::Lease::start(
                    request
                        .provider
                        .ok_or_else(|| Error::Invalid("missing provider".into()))?,
                    request.relative,
                    snapshot,
                )
                .map_err(remote_error)?;
                let result = json!({"sourceId":source,"itemId":item,"assetId":asset,"uri":lease.uri,"headers":{},"leaseId":lease.id,"progress":self.db()?.progress(&source,&item)?});
                self.resources.insert(lease.id.clone(), lease);
                Ok(result)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn late_smb_credential_validation_cannot_replace_new_connection() {
        let directory = std::env::temp_dir().join(format!("ocp-smb-epoch-{}", ocp_library::id()));
        let store = Store::open(&directory).unwrap();
        let library = store
            .create_smb(
                "epoch",
                None,
                "SMB",
                "smb://nas/Media/",
                None,
                "电影",
                "smb://nas/Media/Movies/",
                LibraryType::Movies,
            )
            .unwrap();
        let mut runtime = Runtime::default();
        runtime.store = Some(store);
        let args = json!({"sourceId":library.source_id,"rootUrl":"smb://nas/Media/","credential":{"type":"guest"}});
        let old = runtime
            .prepare_remote("library.smb.credentials.restore", args.clone())
            .unwrap();
        let new = runtime
            .prepare_remote("library.smb.credentials.restore", args)
            .unwrap();
        assert!(runtime
            .finish_remote(old, RemoteReply::Entries(Vec::new()))
            .is_err());
        assert!(runtime.remote.is_empty());
        assert_eq!(
            runtime
                .finish_remote(new, RemoteReply::Entries(Vec::new()))
                .unwrap()["restored"],
            true
        );
        assert_eq!(
            runtime.db().unwrap().libraries(&library.source_id).unwrap()[0].library_id,
            library.library_id
        );
        drop(runtime);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalidation_rejects_late_validation_receipts() {
        let mut runtime = Runtime::default();
        let input = ValidateArgs {
            api_key: "fixture".into(),
            api_base: "http://fixture/3".into(),
            credential_revision: "revision".into(),
            draft_id: "draft".into(),
            language: default_language(),
        };
        let generation = runtime.begin_validation(&input).unwrap();
        runtime
            .call("tmdb.access.invalidate", json!({}), None)
            .unwrap();
        assert!(runtime.validated(&input, generation).is_err());
        assert!(runtime.verifications.is_empty());
    }

    #[test]
    fn endpoint_or_key_change_revokes_previous_receipts_before_network_returns() {
        let mut runtime = Runtime::default();
        let mut input = ValidateArgs {
            api_key: "first".into(),
            api_base: "http://fixture/3".into(),
            credential_revision: "r".into(),
            draft_id: "draft".into(),
            language: default_language(),
        };
        let generation = runtime.begin_validation(&input).unwrap();
        runtime.validated(&input, generation).unwrap();
        input.api_base = "http://other/3".into();
        runtime.begin_validation(&input).unwrap();
        assert!(runtime.verifications.is_empty());
        let generation = runtime.begin_validation(&input).unwrap();
        runtime.validated(&input, generation).unwrap();
        input.api_key = "second".into();
        runtime.begin_validation(&input).unwrap();
        assert!(runtime.verifications.is_empty());
    }
}
