//! DanDanPlay matching, parsing, scoring, timeline scheduling, and cache models.

use chrono::{DateTime, Utc};
use md5::{Digest, Md5};
use reqwest::{
    header::{HeaderMap, HeaderValue, ACCEPT, CONTENT_TYPE},
    Method, Url,
};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
pub mod cache;
mod filename;
pub mod intro;
mod intro_unicode;
pub mod policy;
pub mod providers;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ParsedAnimeInfo {
    pub raw_name: String,
    pub title: String,
    pub episode_number: Option<i64>,
    pub season_number: Option<i64>,
    pub is_final: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SpecialKind {
    Special,
    Extra,
    Other,
}

impl SpecialKind {
    pub fn prefix(self) -> &'static str {
        match self {
            Self::Special => "S",
            Self::Extra => "C",
            Self::Other => "O",
        }
    }
    pub fn keyword(self) -> &'static str {
        match self {
            Self::Special => "SP",
            Self::Extra => "C",
            Self::Other => "O",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "tokenType", rename_all = "camelCase")]
pub enum EpisodeToken {
    Number { value: i64 },
    Special { kind: SpecialKind, index: i64 },
}

impl EpisodeToken {
    pub fn search_value(self) -> String {
        match self {
            Self::Number { value } => value.to_string(),
            Self::Special { kind, index } => format!("{}{index}", kind.prefix()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DanmakuMatch {
    pub episode_id: i64,
    pub shift_seconds: i32,
    pub anime_title: Option<String>,
    pub episode_title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DanmakuComment {
    pub cid: Option<i64>,
    pub p: String,
    pub m: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MatchRequest {
    pub file_name: Option<String>,
    pub file_hash: Option<String>,
    pub file_size: Option<i64>,
    pub video_duration: Option<i64>,
    pub match_mode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MatchResponse {
    pub success: bool,
    pub error_code: Option<i64>,
    pub error_message: Option<String>,
    pub result_count: Option<i64>,
    pub is_matched: Option<bool>,
    #[serde(default)]
    pub matches: Vec<Candidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AnimeSummary {
    pub anime_id: i64,
    pub anime_title: Option<String>,
    pub kind: Option<String>,
    pub type_description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeSummary {
    pub episode_id: i64,
    pub episode_title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AnimeWithEpisodes {
    pub anime_id: i64,
    pub anime_title: Option<String>,
    pub kind: Option<String>,
    pub type_description: Option<String>,
    #[serde(default)]
    pub episodes: Vec<EpisodeSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SearchAnimeResponse {
    pub success: bool,
    pub error_code: Option<i64>,
    pub error_message: Option<String>,
    #[serde(default)]
    pub animes: Vec<AnimeSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SearchEpisodesResponse {
    pub success: bool,
    pub error_code: Option<i64>,
    pub error_message: Option<String>,
    #[serde(default)]
    pub animes: Vec<AnimeWithEpisodes>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommentResponse {
    #[serde(default)]
    pub count: usize,
    pub comments: Option<Vec<DanmakuComment>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DanmakuEntry {
    pub time: f64,
    pub mode: DanmakuMode,
    pub color: u32,
    pub text: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DanmakuMode {
    Scroll,
    Top,
    Bottom,
}

pub fn normalize_full_width(input: &str) -> String {
    input
        .chars()
        .map(|ch| match ch {
            '\u{3000}' => ' ',
            ch if ('\u{ff01}'..='\u{ff5e}').contains(&ch) => {
                char::from_u32(ch as u32 - 0xfee0).unwrap_or(ch)
            }
            _ => ch,
        })
        .collect()
}

pub fn parse_chinese_number(input: &str) -> Option<i64> {
    if let Ok(value) = input.parse() {
        return Some(value);
    }
    let values = input
        .chars()
        .map(|ch| match ch {
            '零' => Some(0),
            '一' => Some(1),
            '二' | '两' => Some(2),
            '三' => Some(3),
            '四' => Some(4),
            '五' => Some(5),
            '六' => Some(6),
            '七' => Some(7),
            '八' => Some(8),
            '九' => Some(9),
            '十' => Some(10),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    match values.as_slice() {
        [n] => Some(*n),
        [10, n] => Some(10 + n),
        [n, 10] => Some(n * 10),
        [a, 10, b] => Some(a * 10 + b),
        _ => None,
    }
}

pub use filename::{parse_episode_token, parse_filename};

pub fn comparable_title(title: &str) -> String {
    let normalized: String = normalize_full_width(title).to_lowercase().nfc().collect();
    normalized
        .graphemes(true)
        .filter(|g| g.chars().next().is_some_and(char::is_alphanumeric))
        .collect()
}

pub fn canonical_match_name(
    series_title: Option<&str>,
    season: Option<i64>,
    episode: Option<EpisodeToken>,
    raw_file_name: &str,
) -> String {
    let name = normalize_full_width(raw_file_name).replace('\\', "/");
    let file = name
        .split('/')
        .filter(|p| !p.is_empty())
        .next_back()
        .unwrap_or(&name);
    let fallback = file
        .rsplit_once('.')
        .filter(|(stem, extension)| !stem.is_empty() && !extension.is_empty())
        .map(|(stem, _)| stem.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or(file);
    let Some(series) = series_title.map(str::trim).filter(|s| !s.is_empty()) else {
        return fallback.to_owned();
    };
    let normalized_series = comparable_title(series);
    if !normalized_series.is_empty() && comparable_title(fallback).contains(&normalized_series) {
        return fallback.to_owned();
    }
    let mut output = series.to_owned();
    if let Some(season) = season.filter(|s| *s > 1) {
        output.push_str(&format!(" 第{season}季"));
    }
    match episode {
        Some(EpisodeToken::Number { value }) => output.push_str(&format!(" 第{value:02}话")),
        Some(EpisodeToken::Special { kind, index }) => {
            output.push_str(&format!(" {}{index}", kind.keyword()))
        }
        None => {}
    }
    output
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DanmakuWireComment {
    pub cid: Option<i64>,
    pub p: String,
    pub m: String,
}

pub fn convert_comments(comments: &[DanmakuWireComment]) -> Vec<DanmakuEntry> {
    let mut entries = comments
        .iter()
        .filter_map(|comment| {
            let mut fields = comment.p.split(',');
            let time: f64 = fields.next()?.parse().ok()?;
            let mode: i32 = fields.next()?.parse().ok()?;
            let color: i64 = fields.next()?.parse().ok()?;
            if !time.is_finite()
                || time < 0.0
                || !matches!(mode, 1 | 4 | 5)
                || !(0..=0xFFFFFF).contains(&color)
                || comment.m.trim().is_empty()
            {
                return None;
            }
            Some(DanmakuEntry {
                time,
                mode: match mode {
                    4 => DanmakuMode::Bottom,
                    5 => DanmakuMode::Top,
                    _ => DanmakuMode::Scroll,
                },
                color: color as u32,
                text: comment.m.clone(),
            })
        })
        .collect::<Vec<_>>();
    entries.sort_by(|a, b| a.time.total_cmp(&b.time));
    entries
}

#[derive(Debug, thiserror::Error)]
pub enum DanmakuError {
    #[error("invalid gateway URL: {0}")]
    InvalidUrl(#[from] url::ParseError),
    #[error("HTTP: {0}")]
    Http(#[from] ocp_http::HttpError),
    #[error("gateway rejected request: {0}")]
    Gateway(String),
    #[error("invalid request: {0}")]
    Request(String),
    #[error("file hash: {0}")]
    FileHash(#[from] std::io::Error),
}

pub const HASH_HEAD_BYTES: usize = 16 * 1024 * 1024;

pub fn head16m_md5(path: impl AsRef<Path>) -> Result<String, DanmakuError> {
    let mut file = File::open(path)?;
    let mut hasher = Md5::new();
    let mut remaining = HASH_HEAD_BYTES;
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let read_limit = remaining.min(64 * 1024);
        let read = file.read(&mut buffer[..read_limit])?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        remaining -= read;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GatewayConfig {
    pub base_url: String,
    pub api_key: String,
    pub user_agent: String,
}

pub struct DanmakuGateway<T = reqwest::Client> {
    pub config: GatewayConfig,
    http: ocp_http::HttpClient<T>,
}

impl DanmakuGateway<reqwest::Client> {
    pub fn new(config: GatewayConfig) -> Self {
        Self {
            config,
            http: ocp_http::HttpClient::new(),
        }
    }
}

impl<T: ocp_http::HttpTransport> DanmakuGateway<T> {
    pub fn with_http(config: GatewayConfig, http: ocp_http::HttpClient<T>) -> Self {
        Self { config, http }
    }

    fn url(&self, path: &str) -> Result<Url, DanmakuError> {
        let mut base = Url::parse(&self.config.base_url)?;
        let prefix = base.path().trim_end_matches('/');
        base.set_path(&format!("{prefix}/{}", path.trim_start_matches('/')));
        Ok(base)
    }

    fn headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Ok(value) = HeaderValue::from_str(&self.config.api_key) {
            headers.insert("X-API-Key", value);
        }
        if let Ok(value) = HeaderValue::from_str(&self.config.user_agent) {
            headers.insert("User-Agent", value);
        }
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        headers
    }

    /// One exchange for a platform-owned retry/decoding policy. Retains arbitrary
    /// fields, error bytes and cache/rate-limit headers without nested retries.
    pub async fn exchange(
        &self,
        url: &str,
        method: &str,
        body: Option<Vec<u8>>,
        timeout_seconds: f64,
    ) -> Result<serde_json::Value, DanmakuError> {
        use base64::Engine;
        let url = Url::parse(url)?;
        let base = Url::parse(&self.config.base_url)?;
        if !matches!(base.scheme(), "http" | "https")
            || base.host_str().is_none()
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
            || url.origin() != base.origin()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(DanmakuError::Request(
                "request must use the configured HTTP origin".into(),
            ));
        }
        let prefix = base.path().trim_end_matches('/');
        let path = url.path().strip_prefix(prefix).unwrap_or("");
        let allowed = match method {
            "POST" => path == "/v1/match",
            "GET" => {
                matches!(path, "/v1/search/anime" | "/v1/search/episodes")
                    || path.strip_prefix("/v1/comments/").is_some_and(|id| {
                        !id.is_empty()
                            && id.bytes().all(|b| b.is_ascii_digit())
                            && id.parse::<i64>().is_ok()
                    })
            }
            _ => false,
        };
        if !allowed || (method == "GET" && body.is_some()) {
            return Err(DanmakuError::Request(
                "unsupported gateway route or body".into(),
            ));
        }
        if !timeout_seconds.is_finite() || timeout_seconds <= 0.0 || timeout_seconds > 300.0 {
            return Err(DanmakuError::Request(
                "timeoutSeconds must be in (0, 300]".into(),
            ));
        }
        let mut request =
            reqwest::Request::new(Method::from_bytes(method.as_bytes()).unwrap(), url);
        *request.headers_mut() = self.headers();
        request
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        if let Some(body) = body {
            *request.body_mut() = Some(body.into());
        }
        *request.timeout_mut() = Some(std::time::Duration::from_secs_f64(timeout_seconds));
        let response = self.http.exchange_once(request).await?;
        let status = response.status().as_u16();
        let headers: std::collections::HashMap<_, _> = response
            .headers()
            .iter()
            .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.to_string(), v.to_owned())))
            .collect();
        let bytes = response
            .bytes()
            .await
            .map_err(|e| ocp_http::HttpError::Decode(e.without_url()))?;
        Ok(serde_json::json!({"status":status, "headers":headers,
            "bodyBase64":base64::engine::general_purpose::STANDARD.encode(bytes)}))
    }

    pub async fn match_file(&self, request: &MatchRequest) -> Result<MatchResponse, DanmakuError> {
        if request.file_hash.is_none() {
            return Err(DanmakuError::Gateway("fileHash is required".into()));
        }
        if request.match_mode.as_deref() != Some("hashOnly") && request.file_name.is_none() {
            return Err(DanmakuError::Gateway(
                "fileName is required for this match mode".into(),
            ));
        }
        let mut headers = self.headers();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let response: MatchResponse = self
            .http
            .json(
                Method::POST,
                self.url("v1/match")?,
                headers,
                Some(
                    serde_json::to_value(request)
                        .map_err(|e| DanmakuError::Gateway(e.to_string()))?,
                ),
            )
            .await?;
        check_gateway(
            response.success,
            response.error_code,
            response.error_message.clone(),
        )?;
        Ok(response)
    }

    pub async fn search_anime(&self, keyword: &str) -> Result<SearchAnimeResponse, DanmakuError> {
        let response: SearchAnimeResponse = self
            .get("v1/search/anime", vec![("keyword", keyword)])
            .await?;
        check_gateway(
            response.success,
            response.error_code,
            response.error_message.clone(),
        )?;
        Ok(response)
    }

    pub async fn search_episodes(
        &self,
        anime: Option<&str>,
        tmdb_id: Option<i64>,
        episode: Option<&str>,
    ) -> Result<SearchEpisodesResponse, DanmakuError> {
        if anime.is_none() && tmdb_id.is_none() {
            return Err(DanmakuError::Gateway("anime or tmdbId is required".into()));
        }
        let mut query = Vec::new();
        if let Some(anime) = anime {
            query.push(("anime", anime));
        }
        let tmdb_id_string = tmdb_id.map(|v| v.to_string());
        if let Some(value) = tmdb_id_string.as_deref() {
            query.push(("tmdbId", value));
        }
        if let Some(episode) = episode {
            query.push(("episode", episode));
        }
        let response: SearchEpisodesResponse = self.get("v1/search/episodes", query).await?;
        check_gateway(
            response.success,
            response.error_code,
            response.error_message.clone(),
        )?;
        Ok(response)
    }

    pub async fn comments(&self, episode_id: i64) -> Result<CommentResponse, DanmakuError> {
        if episode_id < 0 {
            return Err(DanmakuError::Gateway(
                "episodeId must be non-negative".into(),
            ));
        }
        let path = format!("v1/comments/{episode_id}");
        self.get(&path, vec![]).await
    }

    async fn get<R: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        params: Vec<(&str, &str)>,
    ) -> Result<R, DanmakuError> {
        let mut url = self.url(path)?;
        {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in params {
                pairs.append_pair(key, value);
            }
        }
        Ok(self
            .http
            .json(Method::GET, url, self.headers(), None)
            .await?)
    }
}

fn check_gateway(
    success: bool,
    code: Option<i64>,
    message: Option<String>,
) -> Result<(), DanmakuError> {
    if success {
        Ok(())
    } else {
        Err(DanmakuError::Gateway(format!(
            "{}{}",
            code.map(|v| format!("{v}: ")).unwrap_or_default(),
            message.unwrap_or_else(|| "request failed".into())
        )))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub episode_id: i64,
    pub anime_title: Option<String>,
    pub episode_title: Option<String>,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub type_description: Option<String>,
    pub shift: Option<i64>,
}

pub fn score_candidate(
    candidate: &Candidate,
    anime_title: Option<&str>,
    season: Option<i64>,
    episode: Option<i64>,
    rank: usize,
) -> i32 {
    policy::score(
        candidate,
        &policy::TargetContext {
            anime_title: anime_title.map(str::to_owned),
            episode_number: episode,
            season_number: season,
            ..Default::default()
        },
        rank as i64,
    ) as i32
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimedHint {
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub kind: String,
}

pub fn active_hint(hints: &[TimedHint], position: f64) -> Option<&TimedHint> {
    hints
        .iter()
        .find(|hint| position >= hint.start_seconds && position < hint.end_seconds)
}

pub fn cache_is_fresh(fetched_at: DateTime<Utc>, now: DateTime<Utc>, ttl_seconds: i64) -> bool {
    now.signed_duration_since(fetched_at).num_seconds() < ttl_seconds
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_common_names() {
        let r = parse_filename("[NC-Raws] 葬送的芙莉莲 - 01 (B-Global 1920x1080 HEVC AAC).mkv");
        assert_eq!(r.title, "葬送的芙莉莲");
        assert_eq!(r.episode_number, Some(1));
        let r = parse_filename("进击的巨人 第二季 第06话.mkv");
        assert_eq!((r.season_number, r.episode_number), (Some(2), Some(6)));
    }
    #[test]
    fn canonical_name_removes_ambiguous_bare_file_number() {
        assert_eq!(
            canonical_match_name(
                Some("葬送的芙莉莲"),
                Some(1),
                Some(EpisodeToken::Number { value: 5 }),
                "01.mkv"
            ),
            "葬送的芙莉莲 第05话"
        );
    }
    #[test]
    fn filters_and_sorts_comments() {
        let comments = vec![
            DanmakuWireComment {
                cid: None,
                p: "2,5,100,0".into(),
                m: "top".into(),
            },
            DanmakuWireComment {
                cid: None,
                p: "1,1,200,0".into(),
                m: "scroll".into(),
            },
            DanmakuWireComment {
                cid: None,
                p: "-1,1,0,0".into(),
                m: "bad".into(),
            },
        ];
        let entries = convert_comments(&comments);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].time, 1.0);
    }

    #[test]
    fn hashes_only_the_first_sixteen_mebibytes() {
        let path = std::env::temp_dir().join(format!("ocp-hash-{}", std::process::id()));
        std::fs::write(&path, b"abc").unwrap();
        let hash = head16m_md5(&path).unwrap();
        std::fs::remove_file(path).unwrap();
        assert_eq!(hash, "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn decodes_gateway_camel_case_and_wire_type_field() {
        let response: MatchResponse = serde_json::from_value(serde_json::json!({
            "success": true,
            "resultCount": 1,
            "isMatched": true,
            "matches": [{"episodeId": 42, "animeTitle": "Show", "episodeTitle": "第1话", "type": "tv"}]
        })).unwrap();
        assert_eq!(response.matches[0].episode_id, 42);
        assert_eq!(response.matches[0].kind.as_deref(), Some("tv"));
    }
}
