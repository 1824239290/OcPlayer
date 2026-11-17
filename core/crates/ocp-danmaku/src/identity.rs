//! AniList identity matching, resolution plans and native-compatible ID storage.
use crate::{
    cache::atomic_write,
    providers::{self, ProviderError},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use ocp_http::HttpClient;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::PathBuf,
};
use unicode_segmentation::UnicodeSegmentation;

pub const NEGATIVE_LIFETIME: f64 = 604800.0;
const LOOKUP_QUERY: &str = "query ($id: Int) { Media(id: $id) { id idMal } }";
const SEARCH_QUERY: &str = "query ($search: String) { Page(perPage: 10) { media(search: $search, type: ANIME) { id idMal title { native romaji english } synonyms } } }";
const REFERENCE_EPOCH: f64 = 978307200.0;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    #[serde(rename = "malID")]
    pub mal_id: Option<i64>,
    #[serde(rename = "anilistID")]
    pub anilist_id: Option<i64>,
    pub title: Option<String>,
    #[serde(default)]
    pub alternative_titles: Vec<String>,
    pub season_number: Option<i64>,
    pub year: Option<i64>,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IDs {
    #[serde(rename = "malID")]
    pub mal_id: Option<i64>,
    #[serde(rename = "anilistID")]
    pub anilist_id: Option<i64>,
}
impl IDs {
    pub fn is_empty(&self) -> bool {
        self.mal_id.is_none() && self.anilist_id.is_none()
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    #[serde(
        rename = "malID",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    pub mal_id: Option<i64>,
    #[serde(
        rename = "anilistID",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    pub anilist_id: Option<i64>,
    pub resolved_at: f64,
}
impl Record {
    fn ids(&self) -> IDs {
        IDs {
            mal_id: self.mal_id,
            anilist_id: self.anilist_id,
        }
    }
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchMedia {
    #[serde(rename = "anilistID")]
    pub anilist_id: Option<i64>,
    pub id_mal: Option<i64>,
    pub native: Option<String>,
    pub romaji: Option<String>,
    pub english: Option<String>,
    #[serde(default)]
    pub synonyms: Vec<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchRule {
    Exact,
    Contained,
    FirstWithID,
}
#[derive(Debug, PartialEq, Serialize)]
pub struct Match {
    pub index: usize,
    pub rule: MatchRule,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub cache_key: Option<String>,
    pub ready: Option<IDs>,
    #[serde(rename = "anilistID")]
    pub anilist_id: Option<i64>,
    pub search_titles: Vec<String>,
}

#[derive(Deserialize)]
struct MediaTitle {
    native: Option<String>,
    romaji: Option<String>,
    english: Option<String>,
}
#[derive(Deserialize)]
struct WireMedia {
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    id: Option<i64>,
    #[serde(
        rename = "idMal",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    mal: Option<i64>,
    title: Option<MediaTitle>,
    synonyms: Option<Vec<String>>,
}
#[derive(Deserialize)]
struct SearchPage {
    media: Option<Vec<WireMedia>>,
}
#[derive(Deserialize)]
struct SearchData {
    #[serde(rename = "Page")]
    page: Option<SearchPage>,
}
#[derive(Deserialize)]
struct SearchResponse {
    data: Option<SearchData>,
}
#[derive(Deserialize)]
struct LookupMedia {
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    id: Option<i64>,
    #[serde(
        rename = "idMal",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    mal: Option<i64>,
}
#[derive(Deserialize)]
struct LookupData {
    #[serde(rename = "Media")]
    media: Option<LookupMedia>,
}
#[derive(Deserialize)]
struct LookupResponse {
    data: Option<LookupData>,
}
pub fn decode_search(bytes: &[u8]) -> Result<Vec<SearchMedia>, ProviderError> {
    let value: SearchResponse = providers::decode_response(
        bytes,
        &json!({"data":{"Page":{"media":[{"id":null,"idMal":null,"title":{"native":null,"romaji":null,"english":null},"synonyms":[null]}]}}}),
    )?;
    Ok(value
        .data
        .and_then(|v| v.page)
        .and_then(|v| v.media)
        .unwrap_or_default()
        .into_iter()
        .map(|media| SearchMedia {
            anilist_id: media.id,
            id_mal: media.mal,
            native: media.title.as_ref().and_then(|v| v.native.clone()),
            romaji: media.title.as_ref().and_then(|v| v.romaji.clone()),
            english: media.title.and_then(|v| v.english),
            synonyms: media.synonyms.unwrap_or_default(),
        })
        .collect())
}
pub fn decode_lookup(bytes: &[u8], anilist_id: i64) -> Result<IDs, ProviderError> {
    let value: LookupResponse =
        providers::decode_response(bytes, &json!({"data":{"Media":{"id":null,"idMal":null}}}))?;
    let media = value.data.and_then(|v| v.media);
    // The supplied AniList ID is authoritative; missing Media still keeps it.
    let mal_id = media
        .map(|v| {
            let _ = v.id;
            v.mal
        })
        .flatten();
    Ok(IDs {
        mal_id,
        anilist_id: Some(anilist_id),
    })
}
async fn query<T: ocp_http::HttpTransport>(
    http: &HttpClient<T>,
    args: &Value,
    query: &str,
    variables: Value,
) -> Result<(u16, Vec<u8>), ProviderError> {
    let mut request = args.clone();
    let object = request
        .as_object_mut()
        .ok_or_else(|| invalid("arguments must be an object"))?;
    object.insert("provider".into(), json!("aniList"));
    object.insert("query".into(), json!(query));
    object.insert("variables".into(), variables);
    let prepared = providers::prepare(&request)?;
    let result = providers::exchange(http, &serde_json::to_value(prepared).unwrap()).await?;
    let status = result["status"].as_u64().unwrap() as u16;
    let bytes = STANDARD
        .decode(result["bodyBase64"].as_str().unwrap())
        .unwrap();
    Ok((status, bytes))
}
/// Complete ordered AniList lookup/search flow, retaining failures as diagnostics.
/// HTTP and decoding errors degrade to empty candidates; cancellation is owned by Core.
pub async fn resolve_ids<T: ocp_http::HttpTransport>(
    http: &HttpClient<T>,
    args: &Value,
) -> Result<Resolution, ProviderError> {
    let anilist_id: Option<i64> = read(args.get("anilistID").cloned().unwrap_or(Value::Null))?;
    let titles: Vec<String> = read(args.get("searchTitles").cloned().unwrap_or(json!([])))?;
    let mut attempts = Vec::new();
    if let Some(id) = anilist_id {
        let result = query(http, args, LOOKUP_QUERY, json!({"id":id.to_string()})).await;
        let ids = match result {
            Ok((status, bytes)) => {
                let result = if (200..300).contains(&status) {
                    decode_lookup(&bytes, id)
                } else {
                    Err(ProviderError::Status(status))
                };
                attempts.push(Attempt {
                    title: None,
                    status: Some(status),
                    error: result.as_ref().err().map(|e| e.to_string()),
                });
                result.unwrap_or_default()
            }
            Err(error) => {
                attempts.push(Attempt {
                    title: None,
                    status: None,
                    error: Some(error.to_string()),
                });
                IDs::default()
            }
        };
        return Ok(Resolution {
            ids,
            title: None,
            rule: None,
            attempts,
        });
    }
    let mut fallback: Option<SearchMedia> = None;
    for title in titles {
        let result = query(http, args, SEARCH_QUERY, json!({"search":title})).await;
        let media = match result {
            Ok((status, bytes)) => {
                let result = if (200..300).contains(&status) {
                    decode_search(&bytes)
                } else {
                    Err(ProviderError::Status(status))
                };
                attempts.push(Attempt {
                    title: Some(title.clone()),
                    status: Some(status),
                    error: result.as_ref().err().map(|e| e.to_string()),
                });
                match result {
                    Ok(media) => media,
                    Err(_) => continue,
                }
            }
            Err(error) => {
                attempts.push(Attempt {
                    title: Some(title.clone()),
                    status: None,
                    error: Some(error.to_string()),
                });
                continue;
            }
        };
        if let Some(hit) = best_match(&media, &title) {
            let rule = hit.rule;
            let hit = &media[hit.index];
            return Ok(Resolution {
                ids: IDs {
                    mal_id: hit.id_mal,
                    anilist_id: hit.anilist_id,
                },
                title: Some(title),
                rule: Some(rule),
                attempts,
            });
        }
        if fallback.is_none() {
            fallback = media.into_iter().find(|v| v.id_mal.is_some());
        }
    }
    let (ids, rule) = fallback
        .map(|v| {
            (
                IDs {
                    mal_id: v.id_mal,
                    anilist_id: v.anilist_id,
                },
                Some(MatchRule::FirstWithID),
            )
        })
        .unwrap_or_default();
    Ok(Resolution {
        ids,
        title: None,
        rule,
        attempts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn titles_order_key_scope_and_whitespace() {
        assert_eq!(crate::swift_lowercase("ΟΣ İ"), "οσ i\u{307}");
        assert_eq!(crate::comparable_title("ΟΣ"), crate::comparable_title("οσ"));
        let identity:Identity=read(json!({"title":"\nＡＢＣ\u{85}","alternativeTitles":["abc","！？"," 作品名称 ","作品名稱"],"anilistID":i64::MAX})).unwrap();
        assert_eq!(
            search_titles(&identity),
            vec!["ＡＢＣ", "作品名称", "作品名稱"]
        );
        let key = cache_key(&identity);
        let mut other = identity.clone();
        other.alternative_titles.push("unrelated".into());
        other.mal_id = Some(1);
        assert_eq!(cache_key(&other), key);
        other.season_number = Some(2);
        assert_ne!(cache_key(&other), key);
    }
    #[test]
    fn matching_prefers_exact_and_retains_first_contained() {
        let media = vec![
            SearchMedia {
                id_mal: Some(0),
                native: Some("longquery extra".into()),
                ..Default::default()
            },
            SearchMedia {
                id_mal: Some(2),
                synonyms: vec!["longquery".into()],
                ..Default::default()
            },
        ];
        assert_eq!(
            best_match(&media, "longquery"),
            Some(Match {
                index: 1,
                rule: MatchRule::Exact
            })
        );
        assert_eq!(
            best_match(&media[..1], "longquery"),
            Some(Match {
                index: 0,
                rule: MatchRule::Contained
            })
        );
        assert!(best_match(&media, "long").is_none());
    }
    #[test]
    fn cache_boundaries_direct_and_empty_clues() {
        let identity = Identity {
            title: Some("works".into()),
            ..Default::default()
        };
        let record = Record {
            mal_id: None,
            anilist_id: None,
            resolved_at: 0.0,
        };
        assert!(
            plan(&identity, Some(&record), false, NEGATIVE_LIFETIME - 1.0)
                .ready
                .is_some()
        );
        assert!(plan(&identity, Some(&record), false, NEGATIVE_LIFETIME)
            .ready
            .is_none());
        assert!(plan(&identity, Some(&record), true, 0.0).ready.is_none());
        assert!(plan(&Identity::default(), None, false, 0.0)
            .cache_key
            .is_none());
        let direct = Identity {
            mal_id: Some(1),
            anilist_id: Some(-1),
            ..Default::default()
        };
        assert_eq!(
            plan(&direct, Some(&record), true, 0.0)
                .ready
                .unwrap()
                .anilist_id,
            Some(-1)
        );
    }
    #[test]
    fn lookup_missing_media_preserves_caller_but_bad_fields_fail() {
        assert_eq!(
            decode_lookup(b"{}", i64::MAX).unwrap(),
            IDs {
                mal_id: None,
                anilist_id: Some(i64::MAX)
            }
        );
        assert!(decode_lookup(br#"{"data":{"Media":{"id":"bad","idMal":1}}}"#, 1).is_err());
        let result =
            decode_search(br#"{"data":{"Page":{"media":[{"id":1.0,"idMal":2.0}]}}}"#).unwrap();
        assert_eq!(result[0].id_mal, Some(2));
    }
}
#[derive(Debug, Serialize)]
pub struct Attempt {
    pub title: Option<String>,
    pub status: Option<u16>,
    pub error: Option<String>,
}
#[derive(Debug, Serialize)]
pub struct Resolution {
    pub ids: IDs,
    pub title: Option<String>,
    pub rule: Option<MatchRule>,
    pub attempts: Vec<Attempt>,
}

fn invalid(message: impl Into<String>) -> ProviderError {
    ProviderError::Request(message.into())
}
fn read<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ProviderError> {
    serde_json::from_value(value).map_err(|e| invalid(e.to_string()))
}
pub fn input(args: &Value) -> Result<Value, ProviderError> {
    match args.get("payloadJSON") {
        Some(Value::String(value)) => {
            serde_json::from_str(value).map_err(|e| invalid(e.to_string()))
        }
        Some(value) => Ok(value.clone()),
        None => Err(invalid("payloadJSON is required")),
    }
}
pub(crate) fn trim(value: &str) -> &str {
    value.trim_matches(|c: char| {
        crate::intro_unicode::TRIMMING
            .iter()
            .any(|&(lo, hi)| (lo..=hi).contains(&(c as u32)))
    })
}
pub fn search_titles(identity: &Identity) -> Vec<String> {
    let mut seen = HashSet::new();
    identity
        .title
        .iter()
        .chain(identity.alternative_titles.iter())
        .filter_map(|title| {
            let title = trim(title);
            let comparable = crate::comparable_title(title);
            (!comparable.is_empty() && seen.insert(comparable)).then(|| title.to_owned())
        })
        .collect()
}
pub fn cache_key(identity: &Identity) -> String {
    let number = |v: Option<i64>| v.map(|v| v.to_string()).unwrap_or_else(|| "-".into());
    let raw = format!(
        "v2|{}|{}|{}|{}",
        number(identity.anilist_id),
        crate::swift_lowercase(trim(identity.title.as_deref().unwrap_or(""))),
        number(identity.season_number),
        number(identity.year)
    );
    format!("{:x}", Sha256::digest(raw.as_bytes()))
}
pub fn best_match(media: &[SearchMedia], title: &str) -> Option<Match> {
    let query = crate::comparable_title(title);
    if query.is_empty() {
        return None;
    }
    let mut contained = None;
    for (index, candidate) in media.iter().enumerate() {
        if candidate.id_mal.is_none() {
            continue;
        }
        for name in candidate
            .native
            .iter()
            .chain(candidate.romaji.iter())
            .chain(candidate.english.iter())
            .chain(candidate.synonyms.iter())
        {
            let normalized = crate::comparable_title(name);
            if normalized.is_empty() {
                continue;
            }
            if normalized == query {
                return Some(Match {
                    index,
                    rule: MatchRule::Exact,
                });
            }
            if contained.is_none()
                && query.graphemes(true).count() >= 6
                && normalized.contains(&query)
            {
                contained = Some(index);
            }
        }
    }
    contained.map(|index| Match {
        index,
        rule: MatchRule::Contained,
    })
}
pub fn plan(identity: &Identity, record: Option<&Record>, force: bool, now: f64) -> Plan {
    if identity.mal_id.is_some_and(|id| id >= 1) {
        return Plan {
            cache_key: None,
            ready: Some(IDs {
                mal_id: identity.mal_id,
                anilist_id: identity.anilist_id,
            }),
            anilist_id: None,
            search_titles: vec![],
        };
    }
    let titles = search_titles(identity);
    if identity.anilist_id.is_none() && titles.is_empty() {
        return Plan {
            cache_key: None,
            ready: Some(IDs::default()),
            anilist_id: None,
            search_titles: vec![],
        };
    }
    let ready = record
        .filter(|record| {
            !force && (!record.ids().is_empty() || now - record.resolved_at < NEGATIVE_LIFETIME)
        })
        .map(Record::ids);
    Plan {
        cache_key: Some(cache_key(identity)),
        ready,
        anilist_id: identity.anilist_id,
        search_titles: titles,
    }
}
pub fn reference_now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0 - REFERENCE_EPOCH
}
pub fn clock(args: &Value) -> Result<f64, ProviderError> {
    match args.get("now") {
        None => Ok(reference_now()),
        Some(value) => value
            .as_f64()
            .filter(|v| v.is_finite())
            .ok_or_else(|| invalid("now must be finite reference-date seconds")),
    }
}
pub fn force(args: &Value) -> Result<bool, ProviderError> {
    boolean(args, "forceRefresh", false)
}
pub fn boolean(args: &Value, key: &str, default: bool) -> Result<bool, ProviderError> {
    match args.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_bool()
            .ok_or_else(|| invalid(format!("{key} must be a boolean"))),
    }
}
pub fn identity(args: &Value) -> Result<Identity, ProviderError> {
    read(input(args)?)
}
pub fn policy(method: &str, args: &Value) -> Result<Value, ProviderError> {
    match method {
        "searchTitles" => providers::payload(search_titles(&identity(args)?)),
        "cacheKey" => providers::payload(cache_key(&identity(args)?)),
        "bestMatch" => {
            let media: Vec<SearchMedia> = read(input(args)?)?;
            let title = args
                .get("title")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid("title is required"))?;
            providers::payload(best_match(&media, title))
        }
        "plan" => {
            let record: Option<Record> = args
                .get("recordJSON")
                .map(|v| {
                    v.as_str()
                        .ok_or_else(|| invalid("recordJSON must be a string"))
                        .and_then(|v| serde_json::from_str(v).map_err(|e| invalid(e.to_string())))
                })
                .transpose()?
                .flatten();
            providers::payload(plan(
                &identity(args)?,
                record.as_ref(),
                force(args)?,
                clock(args)?,
            ))
        }
        _ => Err(invalid("unknown intro identity policy")),
    }
}

/// One map per Core store, including cached-empty and write-through memory on I/O failure.
pub struct IDStore {
    file: PathBuf,
    cached: Option<BTreeMap<String, Record>>,
}
impl IDStore {
    pub fn open(args: &Value) -> Result<Self, ProviderError> {
        let path = args
            .get("directory")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| invalid("directory is required"))?;
        let directory = PathBuf::from(path);
        if !directory.is_absolute() {
            return Err(invalid("directory must be absolute"));
        }
        let _ = fs::create_dir_all(&directory);
        Ok(Self {
            file: directory.join("aniskip-ids.json"),
            cached: None,
        })
    }
    fn load(&mut self) -> &mut BTreeMap<String, Record> {
        if self.cached.is_none() {
            self.cached = Some(
                fs::read(&self.file)
                    .ok()
                    .and_then(|bytes| {
                        providers::decode_response(
                            &bytes,
                            &json!({"*":{"malID":null,"anilistID":null,"resolvedAt":null}}),
                        )
                        .ok()
                    })
                    .unwrap_or_default(),
            );
        }
        self.cached.as_mut().unwrap()
    }
    pub fn record(&mut self, key: &str) -> Option<Record> {
        self.load().get(key).cloned()
    }
    pub fn write(&mut self, key: &str, record: Record) -> Result<(), ProviderError> {
        if !record.resolved_at.is_finite() {
            return Err(invalid("resolvedAt must be finite"));
        }
        let mut map = self.load().clone();
        map.insert(key.into(), record);
        let bytes = serde_json::to_vec(&map).map_err(|e| invalid(e.to_string()))?;
        let _ = atomic_write(&self.file, &bytes);
        self.cached = Some(map);
        Ok(())
    }
    pub fn prepare(&mut self, identity: &Identity, force: bool, now: f64) -> Plan {
        let preliminary = plan(identity, None, force, now);
        if preliminary.ready.is_some() || force {
            return preliminary;
        }
        let record = self.record(preliminary.cache_key.as_ref().unwrap());
        plan(identity, record.as_ref(), force, now)
    }
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, ProviderError> {
        match method {
            "record" => {
                let key = args
                    .get("key")
                    .and_then(Value::as_str)
                    .ok_or_else(|| invalid("key is required"))?;
                providers::payload(self.record(key))
            }
            "write" => {
                let key = args
                    .get("key")
                    .and_then(Value::as_str)
                    .ok_or_else(|| invalid("key is required"))?;
                self.write(key, read(input(args)?)?)?;
                providers::payload(true)
            }
            "plan" => {
                providers::payload(self.prepare(&identity(args)?, force(args)?, clock(args)?))
            }
            "stats" => providers::payload(
                json!({"loaded":self.cached.is_some(),"records":self.cached.as_ref().map(|v|v.len()).unwrap_or(0)}),
            ),
            _ => Err(invalid("unknown intro ID store command")),
        }
    }
}
