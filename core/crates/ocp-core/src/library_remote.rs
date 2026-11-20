//! SMB and DAV workers share the permanent catalog and local scan checkpoints.
use ocp_library::{parse, scan, Job, Store};
use ocp_resource::Provider;
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc,
    },
    time::Duration,
};

pub fn run(
    store: Store,
    job: Job,
    provider: Provider,
    control: Arc<AtomicU8>,
) -> Result<(), ocp_library::Error> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let library = store.library(&job.source_id, &job.library_id)?;
        let mut scoped_providers: HashMap<String, Provider> = HashMap::new();
        for root in &library.roots {
            let scoped = provider
                .scoped(&root.root_path)
                .map_err(|e| ocp_library::Error::Invalid(e.to_string()))?;
            scoped_providers.insert(root.root_id.clone(), scoped);
        }
        store.set_job_status(&job.job_id, "enumerating")?;
        while let Some((root_id, relative)) = store.next_directory(&job.job_id)? {
            if stop(&store, &job, &control)? {
                return Ok(());
            }
            let Some(scoped) = scoped_providers.get(&root_id) else {
                store.scan_error(&job.job_id, "remote scan root is missing")?;
                store.directory_done(&job.job_id, &root_id, &relative)?;
                continue;
            };
            let listed = tokio::select! {
                result = scoped.list(&relative) => result,
                _ = async { while control.load(Ordering::Acquire) == scan::RUN { tokio::time::sleep(Duration::from_millis(20)).await; } } => {
                    stop(&store, &job, &control)?; return Ok(());
                }
            };
            match listed {
                Ok(entries) => {
                    for entry in entries {
                        if stop(&store, &job, &control)? {
                            return Ok(());
                        }
                        if entry.is_directory {
                            store.add_directory(&job.job_id, &root_id, &entry.relative_path)?;
                        } else if parse::is_video(Path::new(&entry.relative_path)) {
                            store.ingest_remote_for_root(
                                &job,
                                &root_id,
                                &entry.relative_path,
                                entry.size,
                                entry.modified_at,
                                entry.etag.as_deref(),
                                &parse::parse(Path::new(&entry.relative_path), library.library_type),
                            )?;
                        }
                    }
                    store.directory_done(&job.job_id, &root_id, &relative)?;
                }
                Err(error) => {
                    // Keep this checkpoint unfinished. A later resume retries it;
                    // no partial network listing may prove that files disappeared.
                    store.scan_error(&job.job_id, &error.to_string())?;
                    store.set_job_status(
                        &job.job_id,
                        if error.credentials() {
                            "waitingCredentials"
                        } else {
                            "waitingNetwork"
                        },
                    )?;
                    return Ok(());
                }
            }
        }
        if !stop(&store, &job, &control)? {
            store.finish_scan(&job)?;
        }
        Ok(())
    })
}
fn stop(store: &Store, job: &Job, control: &AtomicU8) -> Result<bool, ocp_library::Error> {
    let status = match control.load(Ordering::Acquire) {
        scan::PAUSE => "paused",
        scan::CANCEL => "cancelled",
        _ => return Ok(false),
    };
    store.set_job_status(&job.job_id, status)?;
    Ok(true)
}
