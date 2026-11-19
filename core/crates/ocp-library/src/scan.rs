//! Resumable local enumeration on a worker connection, outside the playback mutex.
use crate::{parse, Error, Job, Store};
use std::{
    path::{Component, Path},
    sync::atomic::{AtomicU8, Ordering},
};

pub const RUN: u8 = 0;
pub const PAUSE: u8 = 1;
pub const CANCEL: u8 = 2;

fn safe_join(root: &Path, relative: &Path) -> Result<std::path::PathBuf, Error> {
    if relative
        .components()
        .any(|c| !matches!(c, Component::Normal(_)))
        && !relative.as_os_str().is_empty()
    {
        return Err(Error::Invalid("invalid scan directory".into()));
    }
    let path = std::fs::canonicalize(root.join(relative))?;
    if !path.starts_with(root) {
        return Err(Error::Invalid("scan directory escapes root".into()));
    }
    Ok(path)
}

pub fn run(store: &Store, job: &Job, control: &AtomicU8) -> Result<(), Error> {
    let library = store.library(&job.source_id, &job.library_id)?;
    let root = match std::fs::canonicalize(&library.root_path) {
        Ok(root) if root.is_dir() => root,
        Ok(_) => {
            store.set_job_status(&job.job_id, "waitingPermission")?;
            return Ok(());
        }
        Err(error) => {
            store.scan_error(&job.job_id, &error.to_string())?;
            store.set_job_status(&job.job_id, "waitingPermission")?;
            return Ok(());
        }
    };
    store.set_job_status(&job.job_id, "enumerating")?;
    while let Some(relative) = store.next_directory(&job.job_id)? {
        if stop(store, job, control)? {
            return Ok(());
        }
        let entries =
            safe_join(&root, Path::new(&relative)).and_then(|path| Ok(std::fs::read_dir(path)?));
        match entries {
            Ok(entries) => {
                for entry in entries {
                    if stop(store, job, control)? {
                        return Ok(());
                    }
                    let result = (|| {
                        let entry = entry?;
                        let metadata = std::fs::symlink_metadata(entry.path())?;
                        if metadata.file_type().is_symlink() {
                            return Ok(());
                        }
                        let path = entry.path();
                        let relative = path
                            .strip_prefix(&root)
                            .map_err(|_| Error::Invalid("entry outside root".into()))?;
                        // Lossy path conversion can alias different Unix filenames. Retain them as errors.
                        let key = relative
                            .to_str()
                            .ok_or_else(|| Error::Invalid("filename is not valid UTF-8".into()))?;
                        if metadata.is_dir() {
                            store.add_directory(&job.job_id, key)?;
                        } else if metadata.is_file() && parse::is_video(relative) {
                            let size = i64::try_from(metadata.len())
                                .map_err(|_| Error::Invalid("video size overflow".into()))?;
                            let mtime = metadata
                                .modified()?
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs_f64();
                            store.ingest(
                                job,
                                key,
                                size,
                                mtime,
                                &parse::parse(relative, library.library_type),
                            )?;
                        }
                        Ok::<_, Error>(())
                    })();
                    if let Err(error) = result {
                        store.scan_error(&job.job_id, &error.to_string())?;
                    }
                }
            }
            Err(error) => store.scan_error(&job.job_id, &error.to_string())?,
        }
        store.directory_done(&job.job_id, &relative)?;
    }
    if !stop(store, job, control)? {
        store.finish_scan(job)?;
    }
    Ok(())
}

fn stop(store: &Store, job: &Job, control: &AtomicU8) -> Result<bool, Error> {
    match control.load(Ordering::Acquire) {
        PAUSE => {
            store.set_job_status(&job.job_id, "paused")?;
            Ok(true)
        }
        CANCEL => {
            store.set_job_status(&job.job_id, "cancelled")?;
            Ok(true)
        }
        _ => Ok(false),
    }
}
