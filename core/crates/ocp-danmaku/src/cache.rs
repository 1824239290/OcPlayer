//! Compatible mapping/comments/intro-hint cache. Files retain Swift Codable's
//! reference-date timestamps and original names; per-instance memory is bounded.
use crate::DanmakuComment;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

#[derive(Debug, thiserror::Error)]
pub enum CacheError {
    #[error("{0}")]
    Invalid(String),
    #[error("cache I/O: {0}")]
    Io(#[from] std::io::Error),
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EpisodeMatch {
    #[serde(rename = "episodeID")]
    pub episode_id: i64,
    #[serde(rename = "shiftSeconds")]
    pub shift_seconds: i64,
    #[serde(rename = "animeID", skip_serializing_if = "Option::is_none")]
    pub anime_id: Option<i64>,
    #[serde(rename = "animeTitle", skip_serializing_if = "Option::is_none")]
    pub anime_title: Option<String>,
    #[serde(rename = "episodeTitle", skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
}
impl EpisodeMatch {
    pub fn resolved_anime_id(&self) -> Option<i64> {
        self.anime_id
            .or_else(|| (self.episode_id >= 10_000).then_some(self.episode_id / 10_000))
    }
    fn legacy(episode_id: i64) -> Self {
        Self {
            episode_id,
            shift_seconds: 0,
            anime_id: None,
            anime_title: None,
            episode_title: None,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntroHint {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_seconds: Option<f64>,
    pub end_seconds: f64,
    pub evidence_count: i64,
    #[serde(default, deserialize_with = "decode_source")]
    pub source: IntroSource,
}
fn decode_source<'de, D: serde::Deserializer<'de>>(decoder: D) -> Result<IntroSource, D::Error> {
    Ok(Option::<IntroSource>::deserialize(decoder)?.unwrap_or_default())
}
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub enum IntroSource {
    #[default]
    #[serde(rename = "danmaku")]
    Danmaku,
    #[serde(rename = "aniskip")]
    Aniskip,
    #[serde(rename = "animeSkip")]
    AnimeSkip,
    #[serde(rename = "theIntroDB")]
    TheIntroDB,
    #[serde(rename = "learned")]
    Learned,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedComments {
    fetched_at: f64,
    comments: Vec<DanmakuComment>,
}

pub struct DanmakuCache {
    directory: PathBuf,
    ttl: f64,
    capacity: usize,
    disk_capacity: Option<u64>,
    revisions: HashMap<String, u64>,
    mapping: Option<HashMap<String, EpisodeMatch>>,
    hints: Option<HashMap<String, IntroHint>>,
    comments: HashMap<i64, CachedComments>,
    order: VecDeque<i64>,
    write_failures: u64,
}
pub fn now() -> f64 {
    chrono::Utc::now().timestamp_micros() as f64 / 1e6 - 978307200.0
}
fn invalid(message: impl Into<String>) -> CacheError {
    CacheError::Invalid(message.into())
}
fn decode<T: for<'d> Deserialize<'d>>(value: &Value) -> Result<T, CacheError> {
    let value = if let Some(s) = value.as_str() {
        serde_json::from_str(s).map_err(|e| invalid(format!("invalid payload JSON: {e}")))?
    } else {
        value.clone()
    };
    serde_json::from_value(value).map_err(|e| invalid(format!("invalid payload: {e}")))
}
fn string<'a>(args: &'a Value, key: &str) -> Result<&'a str, CacheError> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{key} is required")))
}
fn id(args: &Value, key: &str) -> Result<i64, CacheError> {
    args.get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid(format!("{key} must be a signed integer")))
}
fn revision(args: &Value) -> Result<Option<u64>, CacheError> {
    match args.get("revision") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid("revision must be an unsigned integer")),
    }
}
fn timestamp(args: &Value) -> Result<f64, CacheError> {
    match args.get("now") {
        None => Ok(now()),
        Some(v) => v
            .as_f64()
            .filter(|v| v.is_finite())
            .ok_or_else(|| invalid("now must be finite reference-date seconds")),
    }
}

impl DanmakuCache {
    pub fn open(args: &Value) -> Result<Self, CacheError> {
        let directory = PathBuf::from(string(args, "directory")?);
        if !directory.is_absolute() || directory.parent().is_none() {
            return Err(invalid("directory must be an absolute cache folder"));
        }
        let ttl = args
            .get("commentsTTL")
            .map(|v| {
                v.as_f64()
                    .filter(|v| v.is_finite())
                    .ok_or_else(|| invalid("commentsTTL must be finite"))
            })
            .transpose()?
            .unwrap_or(3600.0);
        let capacity = args
            .get("commentsMemoryCapacity")
            .map(|v| {
                v.as_u64()
                    .and_then(|v| usize::try_from(v).ok())
                    .ok_or_else(|| invalid("commentsMemoryCapacity must be non-negative"))
            })
            .transpose()?
            .unwrap_or(2);
        // Opt-in policy: Apple clients retain their existing disk behavior.
        let disk_capacity = args
            .get("commentsDiskCapacityBytes")
            .map(|v| {
                v.as_u64()
                    .ok_or_else(|| invalid("commentsDiskCapacityBytes must be non-negative"))
            })
            .transpose()?;
        // As with FileManager, a temporary unavailable directory leaves the
        // memory cache usable; later writes may recover without replacing data.
        let _ = fs::create_dir_all(&directory);
        let mut cache = Self {
            directory,
            ttl,
            capacity,
            disk_capacity,
            revisions: HashMap::new(),
            mapping: None,
            hints: None,
            comments: HashMap::new(),
            order: VecDeque::new(),
            write_failures: 0,
        };
        if cache.disk_capacity.is_some() {
            cache.prune_comments()?;
        }
        Ok(cache)
    }
    fn comment_files(&self) -> Result<Vec<(i64, PathBuf, u64, std::time::SystemTime)>, CacheError> {
        let mut files = Vec::new();
        let entries = match fs::read_dir(&self.directory) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(files),
            Err(e) => return Err(e.into()),
        };
        for entry in entries {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let Some(id) = name
                .strip_prefix("comments-")
                .and_then(|v| v.strip_suffix(".json"))
                .and_then(|v| v.parse::<i64>().ok())
            else {
                continue;
            };
            let metadata = entry.metadata()?;
            files.push((id, entry.path(), metadata.len(), metadata.modified()?));
        }
        Ok(files)
    }
    fn prune_comments(&mut self) -> Result<u64, CacheError> {
        let Some(capacity) = self.disk_capacity else {
            return Ok(0);
        };
        let mut files = self.comment_files()?;
        files.sort_by_key(|file| file.3);
        let mut bytes = files.iter().map(|file| file.2).sum::<u64>();
        let mut removed = 0;
        for (id, path, size, _) in files {
            if bytes <= capacity {
                break;
            }
            fs::remove_file(path)?;
            self.forget(id);
            bytes = bytes.saturating_sub(size);
            removed += 1;
        }
        Ok(removed)
    }
    fn load_mapping(&mut self) -> Option<HashMap<String, EpisodeMatch>> {
        if let Some(mapping) = &self.mapping {
            return Some(mapping.clone());
        }
        let path = self.directory.join("mapping.json");
        let mapping = match fs::read(path) {
            Ok(bytes) => serde_json::from_slice::<HashMap<String, EpisodeMatch>>(&bytes)
                .ok()
                .or_else(|| {
                    serde_json::from_slice::<HashMap<String, i64>>(&bytes)
                        .ok()
                        .map(|m| {
                            m.into_iter()
                                .map(|(k, v)| (k, EpisodeMatch::legacy(v)))
                                .collect()
                        })
                })?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(_) => return None,
        };
        self.mapping = Some(mapping.clone());
        Some(mapping)
    }
    fn accept(&mut self, key: &str, revision: Option<u64>) -> bool {
        match revision {
            None => {
                self.revisions.remove(key);
                true
            }
            Some(r) => {
                if r < *self.revisions.get(key).unwrap_or(&0) {
                    return false;
                }
                self.revisions.insert(key.to_owned(), r);
                true
            }
        }
    }
    fn save<T: Serialize>(&mut self, name: &str, value: &T) -> bool {
        match serde_json::to_vec(value)
            .ok()
            .map(|data| atomic_write(&self.directory.join(name), &data))
        {
            Some(Ok(())) => true,
            _ => {
                self.write_failures = self.write_failures.saturating_add(1);
                false
            }
        }
    }
    fn forget(&mut self, id: i64) {
        self.comments.remove(&id);
        self.order.retain(|v| *v != id);
    }
    fn touch(&mut self, id: i64) {
        self.order.retain(|v| *v != id);
        self.order.push_back(id);
    }
    fn remember(&mut self, id: i64, entry: CachedComments) {
        if self.capacity == 0 {
            return;
        }
        self.comments.insert(id, entry);
        self.touch(id);
        while self.order.len() > self.capacity {
            if let Some(id) = self.order.pop_front() {
                self.comments.remove(&id);
            }
        }
    }
    fn read_comments(&mut self, id: i64, now: f64) -> Option<Vec<DanmakuComment>> {
        if let Some(entry) = self.comments.get(&id) {
            if now - entry.fetched_at <= self.ttl {
                let value = entry.comments.clone();
                self.touch(id);
                return Some(value);
            }
            self.forget(id);
        }
        let path = self.directory.join(format!("comments-{id}.json"));
        let entry: CachedComments = serde_json::from_slice(&fs::read(&path).ok()?).ok()?;
        // Expired memory is not authority to remove a file refreshed by another
        // cache instance. Decide using this disk entry's own timestamp.
        if now - entry.fetched_at > self.ttl {
            let _ = fs::remove_file(path);
            return None;
        }
        let result = entry.comments.clone();
        self.remember(id, entry);
        Some(result)
    }
    fn load_hints(&mut self) -> Option<HashMap<String, IntroHint>> {
        if let Some(hints) = &self.hints {
            return Some(hints.clone());
        }
        let hints = match fs::read(self.directory.join("intro-hints.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes).ok()?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(_) => return None,
        };
        self.hints = Some(hints.clone());
        Some(hints)
    }
    pub fn episode_ids(&mut self, anime_id: i64) -> Vec<i64> {
        self.load_mapping()
            .unwrap_or_default()
            .into_values()
            .filter(|entry| entry.resolved_anime_id() == Some(anime_id))
            .map(|entry| entry.episode_id)
            .collect()
    }
    pub fn intro_hint(&mut self, episode_id: i64) -> Option<IntroHint> {
        self.load_hints()
            .and_then(|h| h.get(&episode_id.to_string()).cloned())
    }
    pub fn set_intro_hint(&mut self, episode_id: i64, hint: IntroHint) -> bool {
        let mut hints = self.load_hints().unwrap_or_default();
        hints.insert(episode_id.to_string(), hint);
        let saved = self.save("intro-hints.json", &hints);
        self.hints = Some(hints);
        saved
    }
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, CacheError> {
        let result = match method {
            "episodeMatch" => {
                let key = string(args, "mediaID")?;
                json!(self.load_mapping().and_then(|m| m.get(key).cloned()))
            }
            "allEpisodeMatches" => json!(self
                .load_mapping()
                .unwrap_or_default()
                .into_values()
                .collect::<Vec<_>>()),
            "claimRevision" => {
                let key = string(args, "mediaID")?;
                let r = revision(args)?.ok_or_else(|| invalid("revision is required"))?;
                json!(self.accept(key, Some(r)))
            }
            "claimedRevision" => json!(self.revisions.get(string(args, "mediaID")?)),
            "setEpisodeMatch" => {
                let key = string(args, "mediaID")?;
                let revision = revision(args)?;
                let entry: EpisodeMatch = decode(
                    args.get("payloadJSON")
                        .ok_or_else(|| invalid("payloadJSON is required"))?,
                )?;
                if let Some(mut mapping) = self.load_mapping() {
                    if self.accept(key, revision) {
                        mapping.insert(key.to_owned(), entry);
                        let saved = self.save("mapping.json", &mapping);
                        self.mapping = Some(mapping);
                        json!(saved)
                    } else {
                        json!(false)
                    }
                } else {
                    json!(false)
                }
            }
            "removeEpisodeMatch" => {
                let key = string(args, "mediaID")?;
                let revision = revision(args)?;
                if let Some(mut mapping) = self.load_mapping() {
                    if self.accept(key, revision) {
                        if mapping.remove(key).is_some() {
                            let _ = self.save("mapping.json", &mapping);
                            self.mapping = Some(mapping);
                        }
                        json!(true)
                    } else {
                        json!(false)
                    }
                } else {
                    json!(false)
                }
            }
            "comments" => json!(self.read_comments(id(args, "episodeID")?, timestamp(args)?)),
            "setComments" => {
                let id = id(args, "episodeID")?;
                let comments: Vec<DanmakuComment> = decode(
                    args.get("payloadJSON")
                        .ok_or_else(|| invalid("payloadJSON is required"))?,
                )?;
                let entry = CachedComments {
                    fetched_at: timestamp(args)?,
                    comments,
                };
                let saved = self.save(&format!("comments-{id}.json"), &entry);
                self.remember(id, entry);
                if self.prune_comments().is_err() {
                    self.write_failures = self.write_failures.saturating_add(1);
                }
                json!(saved)
            }
            "introHint" => json!(self.intro_hint(id(args, "episodeID")?)),
            "setIntroHint" => {
                let episode_id = id(args, "episodeID")?;
                let hint: IntroHint = decode(
                    args.get("payloadJSON")
                        .ok_or_else(|| invalid("payloadJSON is required"))?,
                )?;
                json!(self.set_intro_hint(episode_id, hint))
            }
            "memoryCount" => json!(self.comments.len()),
            "clearComments" => {
                for (id, path, _, _) in self.comment_files()? {
                    fs::remove_file(path)?;
                    self.forget(id);
                }
                self.comments.clear();
                self.order.clear();
                json!(true)
            }
            "pruneComments" => json!(self.prune_comments()?),
            "stats" => {
                json!({"commentsMemoryCount":self.comments.len(),"commentsMemoryCapacity":self.capacity,"writeFailures":self.write_failures})
            }
            "purge" => {
                self.revisions.clear();
                self.mapping = None;
                self.hints = None;
                self.comments.clear();
                self.order.clear();
                let _ = fs::remove_dir_all(&self.directory);
                let _ = fs::create_dir_all(&self.directory);
                json!(true)
            }
            _ => return Err(invalid("unknown danmaku cache operation")),
        };
        // JSON text preserves all integer IDs, revisions and original wire data
        // through clients whose generic JSON projection uses floating point.
        Ok(json!({"payloadJSON":result.to_string()}))
    }
}
pub(crate) fn atomic_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("missing parent"))?;
    let temp = parent.join(format!(
        ".ocp-cache-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod disk_policy_tests {
    use super::*;
    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "ocp-danmaku-disk-policy-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn comments(cache: &mut DanmakuCache, id: i64) {
        cache
            .call(
                "setComments",
                &json!({"episodeID":id,"payloadJSON":[{"p":"0,1,16777215","m":"test comment"}]}),
            )
            .unwrap();
    }
    #[test]
    fn disk_capacity_is_opt_in_and_evicts_oldest_comments() {
        let directory = Directory::new();
        let mut cache = DanmakuCache::open(&json!({"directory":directory.0})).unwrap();
        comments(&mut cache, 1);
        comments(&mut cache, 2);
        assert_eq!(cache.comment_files().unwrap().len(), 2);
        let first = directory.0.join("comments-1.json");
        fs::OpenOptions::new()
            .write(true)
            .open(&first)
            .unwrap()
            .set_modified(std::time::SystemTime::UNIX_EPOCH)
            .unwrap();
        let size = fs::metadata(&first).unwrap().len();
        let mut bounded = DanmakuCache::open(
            &json!({"directory":directory.0,"commentsDiskCapacityBytes":size+10}),
        )
        .unwrap();
        assert!(!first.exists());
        assert!(directory.0.join("comments-2.json").exists());
        comments(&mut bounded, 3);
        assert_eq!(bounded.comment_files().unwrap().len(), 1);
        assert_eq!(bounded.comments.len(), 1);
    }
    #[test]
    fn clearing_comments_preserves_matches_hints_and_other_files() {
        let directory = Directory::new();
        let mut cache = DanmakuCache::open(&json!({"directory":directory.0})).unwrap();
        cache
            .call(
                "setEpisodeMatch",
                &json!({"mediaID":"media","payloadJSON":{"episodeID":1,"shiftSeconds":3}}),
            )
            .unwrap();
        cache.call("setIntroHint", &json!({"episodeID":1,"payloadJSON":{"endSeconds":90,"evidenceCount":1,"source":"danmaku"}})).unwrap();
        comments(&mut cache, 1);
        fs::write(directory.0.join("comments-note.json"), b"preserve").unwrap();
        cache.call("clearComments", &json!({})).unwrap();
        assert!(cache.comments.is_empty());
        assert!(cache.comment_files().unwrap().is_empty());
        assert!(cache.load_mapping().unwrap().contains_key("media"));
        assert!(cache.intro_hint(1).is_some());
        assert!(directory.0.join("mapping.json").exists());
        assert!(directory.0.join("intro-hints.json").exists());
        assert!(directory.0.join("comments-note.json").exists());
    }
    #[test]
    fn zero_capacity_disables_disk_and_memory_comment_reuse() {
        let directory = Directory::new();
        let mut cache =
            DanmakuCache::open(&json!({"directory":directory.0,"commentsDiskCapacityBytes":0}))
                .unwrap();
        comments(&mut cache, 1);
        assert!(cache.comment_files().unwrap().is_empty());
        assert!(cache.comments.is_empty());
        assert!(DanmakuCache::open(
            &json!({"directory":directory.0,"commentsDiskCapacityBytes":-1})
        )
        .is_err());
    }
}
