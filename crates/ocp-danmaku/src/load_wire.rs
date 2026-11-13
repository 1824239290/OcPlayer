//! Native gateway decoding and retry policy for the standalone shared loader.
use crate::{providers, Candidate, DanmakuComment, DanmakuError, DanmakuGateway, MatchRequest};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use std::{
    collections::hash_map::RandomState,
    hash::{BuildHasher, Hasher},
    time::Duration,
};

#[derive(Debug, Clone)]
pub struct Failure {
    pub kind: &'static str,
    pub status: Option<u16>,
    pub message: String,
    pub code: i32,
    pub retryable: bool,
    retry_after: Option<f64>,
}
impl Failure {
    fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind,
            status: None,
            message: message.into(),
            code: if kind == "invalidRequest" { 1002 } else { 1502 },
            retryable: false,
            retry_after: None,
        }
    }
    pub fn reply(&self) -> Value {
        json!({"kind":self.kind,"status":self.status,"message":self.message})
    }
}
impl From<DanmakuError> for Failure {
    fn from(error: DanmakuError) -> Self {
        let mut failure = Self::new("invalidRequest", error.to_string());
        failure.code = 1002;
        if let DanmakuError::Http(error) = error {
            failure.kind = "network";
            failure.code = if error.category() == Some(ocp_http::ErrorCategory::Timeout) {
                1503
            } else {
                1501
            };
            failure.retryable = error.retryable();
            failure.retry_after = error.retry_after().map(|v| v.as_secs_f64());
        }
        failure
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Base {
    success: bool,
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    error_code: Option<i64>,
    error_message: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Matched {
    success: bool,
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    error_code: Option<i64>,
    error_message: Option<String>,
    is_matched: Option<bool>,
    #[serde(
        rename = "resultCount",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    _result_count: Option<i64>,
    matches: Vec<WireCandidate>,
}
#[derive(Deserialize)]
struct WireCandidate {
    #[serde(rename = "episodeId", deserialize_with = "swift_int")]
    episode_id: i64,
    #[serde(
        rename = "animeId",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    anime_id: Option<i64>,
    #[serde(rename = "animeTitle")]
    anime_title: Option<String>,
    #[serde(rename = "episodeTitle")]
    episode_title: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(rename = "typeDescription")]
    type_description: Option<String>,
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    shift: Option<i64>,
    #[serde(rename = "fileName")]
    _file_name: Option<String>,
    #[serde(
        rename = "fileSize",
        default,
        deserialize_with = "providers::optional_swift_int"
    )]
    _file_size: Option<i64>,
    #[serde(rename = "hash")]
    _hash: Option<String>,
}
fn swift_int<'de, D: serde::Deserializer<'de>>(decoder: D) -> Result<i64, D::Error> {
    providers::optional_swift_int(decoder)?
        .ok_or_else(|| serde::de::Error::custom("integer is required"))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Searched {
    success: bool,
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    error_code: Option<i64>,
    error_message: Option<String>,
    animes: Vec<Anime>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Anime {
    #[serde(deserialize_with = "swift_int")]
    anime_id: i64,
    anime_title: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
    type_description: Option<String>,
    episodes: Vec<Episode>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Episode {
    #[serde(deserialize_with = "swift_int")]
    episode_id: i64,
    episode_title: Option<String>,
}
#[derive(Deserialize)]
struct Comments {
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    count: Option<i64>,
    comments: Option<Vec<WireComment>>,
}
#[derive(Deserialize)]
struct WireComment {
    #[serde(default, deserialize_with = "providers::optional_swift_int")]
    cid: Option<i64>,
    p: String,
    m: String,
}
fn business(success: bool, code: Option<i64>, message: Option<String>) -> Result<(), Failure> {
    if success {
        Ok(())
    } else {
        let _ = code;
        Err(Failure::new(
            "businessError",
            message.unwrap_or_else(|| "弹幕服务返回错误".to_owned()),
        ))
    }
}
fn decode<T: DeserializeOwned>(
    bytes: &[u8],
    shape: &Value,
    checking_base: bool,
) -> Result<T, Failure> {
    match providers::decode_response(bytes, shape) {
        Ok(value) => Ok(value),
        Err(error) => {
            if checking_base {
                if let Ok(base) = providers::decode_response::<Base>(
                    bytes,
                    &json!({"success":null,"errorCode":null,"errorMessage":null}),
                ) {
                    business(base.success, base.error_code, base.error_message)?;
                }
            }
            Err(Failure::new("decodingFailed", error.to_string()))
        }
    }
}
pub struct Gateway<T> {
    gateway: DanmakuGateway<T>,
    timeout: f64,
    attempts: usize,
}
impl<T: ocp_http::HttpTransport> Gateway<T> {
    pub fn new(gateway: DanmakuGateway<T>, timeout: f64, attempts: usize) -> Self {
        Self {
            gateway,
            timeout,
            attempts,
        }
    }
    async fn bytes(
        &self,
        path: &str,
        query: Vec<(&str, String)>,
        body: Option<Value>,
    ) -> Result<Vec<u8>, Failure> {
        let mut url = self.gateway.url(path)?;
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query);
        }
        let body = body.map(|v| v.to_string().into_bytes());
        let mut attempt = 1;
        loop {
            let response = self
                .gateway
                .exchange(
                    url.as_str(),
                    if body.is_some() { "POST" } else { "GET" },
                    body.clone(),
                    self.timeout,
                )
                .await;
            let result = match response {
                Err(error) => Err(Failure::from(error)),
                Ok(response) => {
                    let status = response["status"].as_u64().unwrap() as u16;
                    if (200..300).contains(&status) {
                        Ok(STANDARD
                            .decode(response["bodyBase64"].as_str().unwrap())
                            .unwrap())
                    } else {
                        let kind = match status {
                            401 => "unauthorized",
                            403 => "forbidden",
                            429 => "rateLimited",
                            _ => "httpStatus",
                        };
                        let mut error = Failure::new(kind, format!("gateway HTTP {status}"));
                        error.status = Some(status);
                        error.retryable = matches!(status, 429 | 500 | 502 | 503 | 504);
                        if status == 429 {
                            error.retry_after = response["headers"]["retry-after"]
                                .as_str()
                                .and_then(|v| v.parse::<f64>().ok())
                                .filter(|v| v.is_finite() && *v > 0.0);
                        }
                        Err(error)
                    }
                }
            };
            match result {
                Err(error) if error.retryable && attempt < self.attempts => {
                    let jitter =
                        0.5 + RandomState::new().build_hasher().finish() as f64 / u64::MAX as f64;
                    let seconds = error
                        .retry_after
                        .map(|v| v.min(60.0))
                        .unwrap_or_else(|| 2_f64.powi((attempt - 1) as i32) * jitter);
                    tokio::time::sleep(Duration::from_secs_f64(seconds)).await;
                    attempt += 1;
                }
                result => return result,
            }
        }
    }
    pub async fn matches(&self, args: &Value) -> Result<Value, Failure> {
        let mut request: MatchRequest = serde_json::from_value(args.clone())
            .map_err(|e| Failure::new("invalidRequest", e.to_string()))?;
        request.file_name = request
            .file_name
            .map(|v| crate::identity::trim(&v).to_owned())
            .filter(|v| !v.is_empty());
        request.file_hash = request
            .file_hash
            .map(|v| crate::identity::trim(&v).to_ascii_lowercase())
            .filter(|v| !v.is_empty());
        let hash = request.file_hash.as_deref().unwrap_or("");
        if hash.len() != 32
            || !hash.bytes().all(|v| v.is_ascii_hexdigit())
            || request.file_size.is_some_and(|v| v < 0)
            || request.video_duration.is_some_and(|v| v <= 0)
            || (matches!(
                request.match_mode.as_deref(),
                Some("hashAndFileName" | "fileNameOnly")
            ) && request.file_name.is_none())
        {
            return Err(Failure::new(
                "invalidRequest",
                "invalid media fingerprint parameters",
            ));
        }
        let mut body = serde_json::to_value(request).unwrap();
        body.as_object_mut()
            .unwrap()
            .retain(|_, value| !value.is_null());
        let bytes = self.bytes("v1/match", vec![], Some(body)).await?;
        let matched: Matched = decode(
            &bytes,
            &json!({"success":null,"errorCode":null,"errorMessage":null,"resultCount":null,"isMatched":null,"matches":[{"episodeId":null,"animeId":null,"animeTitle":null,"episodeTitle":null,"type":null,"typeDescription":null,"shift":null,"fileName":null,"fileSize":null,"hash":null}]}),
            true,
        )?;
        business(matched.success, matched.error_code, matched.error_message)?;
        let candidates: Vec<Value> = matched
            .matches
            .into_iter()
            .map(|v| {
                let candidate = Candidate {
                    episode_id: v.episode_id,
                    anime_title: v.anime_title,
                    episode_title: v.episode_title,
                    kind: v.kind,
                    type_description: v.type_description,
                    shift: v.shift,
                };
                let mut value = serde_json::to_value(candidate).unwrap();
                value["animeId"] = json!(v.anime_id);
                value
            })
            .collect();
        Ok(json!({"isMatched":matched.is_matched,"candidates":candidates}))
    }
    pub async fn search(&self, args: &Value) -> Result<Value, Failure> {
        let has_tmdb = !args["tmdbId"].is_null();
        if (has_tmdb && args["tmdbId"].as_i64().is_none_or(|v| v < 1))
            || (!has_tmdb
                && args["anime"]
                    .as_str()
                    .is_none_or(|v| crate::identity::trim(v).is_empty()))
        {
            return Err(Failure::new(
                "invalidRequest",
                "anime or positive tmdbId is required",
            ));
        }
        let mut query = Vec::new();
        for key in ["anime", "episode", "tmdbId", "tmdbIdType"] {
            if key == "tmdbIdType" && !has_tmdb {
                continue;
            }
            if let Some(value) = args.get(key).filter(|v| !v.is_null()) {
                query.push((
                    key,
                    value
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| value.to_string()),
                ));
            }
        }
        let bytes = self.bytes("v1/search/episodes", query, None).await?;
        let response: Searched = decode(
            &bytes,
            &json!({"success":null,"errorCode":null,"errorMessage":null,"animes":[{"animeId":null,"animeTitle":null,"type":null,"typeDescription":null,"episodes":[{"episodeId":null,"episodeTitle":null}]}]}),
            true,
        )?;
        business(
            response.success,
            response.error_code,
            response.error_message,
        )?;
        let candidates: Vec<Value> = response.animes.into_iter().flat_map(|a| a.episodes.into_iter().map(move |e| json!({
            "episodeId":e.episode_id,"animeId":a.anime_id,"animeTitle":a.anime_title,"episodeTitle":e.episode_title,"type":a.kind,"typeDescription":a.type_description,"shift":0
        }))).collect();
        Ok(json!({"candidates":candidates}))
    }
    pub async fn comments(&self, episode: i64) -> Result<Vec<DanmakuComment>, Failure> {
        let bytes = self
            .bytes(
                &format!("v1/comments/{episode}"),
                vec![("chConvert", "0".into()), ("withRelated", "true".into())],
                None,
            )
            .await?;
        let response: Comments = decode(
            &bytes,
            &json!({"count":null,"comments":[{"cid":null,"p":null,"m":null}]}),
            true,
        )?;
        let _ = response.count;
        Ok(response
            .comments
            .unwrap_or_default()
            .into_iter()
            .map(|v| DanmakuComment {
                cid: v.cid,
                p: v.p,
                m: v.m,
            })
            .collect())
    }
}
