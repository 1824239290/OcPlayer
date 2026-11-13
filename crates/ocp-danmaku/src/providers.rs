//! Intro provider wire contracts. Each exchange is exactly one HTTP attempt.
use base64::{engine::general_purpose::STANDARD, Engine};
use ocp_http::HttpClient;
use reqwest::{header::HeaderMap, Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, time::Duration};

pub const USER_AGENT: &str = "OcPlayer (https://github.com/1824239290/OcPlayer)";
const ANIME_QUERY: &str = "query ($service: ExternalService!, $id: String!) {\n  findShowsByExternalId(service: $service, serviceId: $id) {\n    episodes { season number timestamps { at type { name } } }\n  }\n}";

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("invalid provider request: {0}")]
    Request(String),
    #[error("provider JSON decode failed: {0}")]
    Decode(String),
    #[error("provider HTTP {0}")]
    Status(u16),
    #[error(transparent)]
    Http(#[from] ocp_http::HttpError),
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    AniSkip,
    AnimeSkip,
    TheIntroDB,
    AniList,
}
impl Provider {
    fn base(self) -> &'static str {
        match self {
            Self::AniSkip => "https://api.aniskip.com",
            Self::AnimeSkip => "https://api.anime-skip.com",
            Self::TheIntroDB => "https://api.theintrodb.org",
            Self::AniList => "https://graphql.anilist.co",
        }
    }
    fn allows(self, path: &str, method: &str) -> bool {
        match self {
            Self::AniSkip if method == "GET" => {
                let ids: Vec<_> = path
                    .strip_prefix("/v2/skip-times/")
                    .unwrap_or("")
                    .split('/')
                    .collect();
                ids.len() == 2 && ids.iter().all(|id| id.parse::<i64>().is_ok_and(|n| n >= 1))
            }
            Self::AnimeSkip => method == "POST" && path == "/graphql",
            Self::TheIntroDB => method == "GET" && path == "/v3/media",
            Self::AniList => method == "POST" && matches!(path, "" | "/"),
            _ => false,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedRequest {
    pub provider: Provider,
    #[serde(rename = "baseURL")]
    pub base_url: String,
    pub url: String,
    pub http_method: String,
    pub headers: BTreeMap<String, String>,
    pub body_base64: Option<String>,
    pub timeout_seconds: f64,
}
fn invalid(message: impl Into<String>) -> ProviderError {
    ProviderError::Request(message.into())
}
fn read<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ProviderError> {
    serde_json::from_value(value).map_err(|e| invalid(e.to_string()))
}
fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, ProviderError> {
    let bytes = json_utf8(bytes)?;
    let value: FirstValue =
        serde_json::from_slice(&bytes).map_err(|e| ProviderError::Decode(e.to_string()))?;
    serde_json::from_value(value.0).map_err(|e| ProviderError::Decode(e.to_string()))
}
fn decode_response<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
    shape: &Value,
) -> Result<T, ProviderError> {
    let bytes = json_utf8(bytes)?;
    for index in 0..=bytes.len() {
        let marker = format!("__ocp_invalid_utf8_{index}");
        let Some(sanitized) = lazy_utf8_values(&bytes, &marker)? else {
            continue;
        };
        let value: FirstValue =
            serde_json::from_slice(&sanitized).map_err(|e| ProviderError::Decode(e.to_string()))?;
        validate_shape(&value.0, shape, &marker)?;
        return serde_json::from_value(value.0).map_err(|e| ProviderError::Decode(e.to_string()));
    }
    Err(ProviderError::Decode(
        "cannot represent invalid UTF-8 value".into(),
    ))
}
fn is_marker(value: &Value, marker: &str) -> bool {
    value
        .as_object()
        .is_some_and(|v| v.len() == 1 && v.get(marker) == Some(&Value::Bool(true)))
}
fn validate_shape(value: &Value, shape: &Value, marker: &str) -> Result<(), ProviderError> {
    if is_marker(value, marker) {
        return Err(ProviderError::Decode("invalid encoded string field".into()));
    }
    match (value, shape) {
        (Value::Object(value), Value::Object(shape)) => {
            for (key, shape) in shape {
                if let Some(value) = value.get(key) {
                    validate_shape(value, shape, marker)?;
                }
            }
        }
        (Value::Array(value), Value::Array(shape)) if !shape.is_empty() => {
            for value in value {
                validate_shape(value, &shape[0], marker)?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Foundation accepts UTF-8/16 BOMs and unmarked UTF-32; its UTF-32 BOM path fails.
fn json_utf8(bytes: &[u8]) -> Result<Vec<u8>, ProviderError> {
    if bytes.starts_with(&[0, 0, 0xfe, 0xff]) || bytes.starts_with(&[0xff, 0xfe, 0, 0]) {
        return Err(ProviderError::Decode(
            "UTF-32 byte order mark is not accepted by the native decoder".into(),
        ));
    }
    let (encoding, bytes) = if bytes.starts_with(&[0xfe, 0xff]) {
        (2, &bytes[2..])
    } else if bytes.starts_with(&[0xff, 0xfe]) {
        (-2, &bytes[2..])
    } else if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        (1, &bytes[3..])
    } else if bytes.len() >= 4 && bytes[0..3] == [0, 0, 0] {
        (4, bytes)
    } else if bytes.len() >= 4 && bytes[1..4] == [0, 0, 0] {
        (-4, bytes)
    } else if bytes.len() >= 4 && bytes[0] == 0 && bytes[2] == 0 {
        (2, bytes)
    } else if bytes.len() >= 4 && bytes[1] == 0 && bytes[3] == 0 {
        (-2, bytes)
    } else {
        (1, bytes)
    };
    if encoding == 1 {
        return Ok(bytes.to_vec());
    }
    let width = if encoding == 2 || encoding == -2 {
        2
    } else {
        4
    };
    if bytes.len() % width != 0 {
        return Err(ProviderError::Decode("incomplete Unicode code unit".into()));
    }
    let text = if width == 2 {
        let units = bytes.chunks_exact(2).map(|b| {
            if encoding > 0 {
                u16::from_be_bytes([b[0], b[1]])
            } else {
                u16::from_le_bytes([b[0], b[1]])
            }
        });
        char::decode_utf16(units)
            .collect::<Result<String, _>>()
            .map_err(|e| ProviderError::Decode(e.to_string()))?
    } else {
        bytes
            .chunks_exact(4)
            .map(|b| {
                let unit = if encoding > 0 {
                    u32::from_be_bytes(b.try_into().unwrap())
                } else {
                    u32::from_le_bytes(b.try_into().unwrap())
                };
                char::from_u32(unit)
                    .ok_or_else(|| ProviderError::Decode("invalid Unicode scalar".into()))
            })
            .collect::<Result<String, _>>()?
    };
    Ok(text.into_bytes())
}

/// Foundation defers string decoding until a DTO requests the value. A sentinel
/// retains invalid UTF-8/escapes in unknown fields and ignored duplicate values.
fn lazy_utf8_values(bytes: &[u8], marker: &str) -> Result<Option<Vec<u8>>, ProviderError> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'"' {
            output.push(bytes[index]);
            index += 1;
            continue;
        }
        let start = index;
        index += 1;
        let mut escaped = false;
        let mut closed = false;
        while index < bytes.len() {
            let byte = bytes[index];
            index += 1;
            if !escaped && byte == b'"' {
                closed = true;
                break;
            }
            escaped = !escaped && byte == b'\\';
        }
        let token = &bytes[start..index];
        if !closed {
            return Err(ProviderError::Decode("unterminated JSON string".into()));
        }
        let next = bytes[index..].iter().find(|b| !b.is_ascii_whitespace());
        if let Ok(value) = serde_json::from_slice::<String>(token) {
            if next == Some(&b':') && value == marker {
                return Ok(None);
            }
            output.extend_from_slice(token);
            continue;
        }
        if next == Some(&b':') {
            return Err(ProviderError::Decode("invalid encoded object key".into()));
        }
        // The native scanner still consumes four hex digits after a Unicode escape.
        let mut at = 1;
        while at < token.len() - 1 {
            if token[at] == b'\\' {
                at += 1;
                if token[at] == b'u' {
                    if at + 4 >= token.len() - 1
                        || !token[at + 1..at + 5].iter().all(u8::is_ascii_hexdigit)
                    {
                        return Err(ProviderError::Decode("invalid Unicode escape".into()));
                    }
                    at += 4;
                }
            }
            at += 1;
        }
        output.extend_from_slice(format!("{{\"{marker}\":true}}").as_bytes());
    }
    Ok(Some(output))
}

/// JSONDecoder uses the first duplicate object key, including in nested objects.
struct FirstValue(Value);
impl<'de> Deserialize<'de> for FirstValue {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = FirstValue;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a JSON value")
            }
            fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_string<E: serde::de::Error>(self, v: String) -> Result<FirstValue, E> {
                Ok(FirstValue(json!(v)))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<FirstValue, E> {
                Ok(FirstValue(Value::Null))
            }
            fn visit_none<E: serde::de::Error>(self) -> Result<FirstValue, E> {
                Ok(FirstValue(Value::Null))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> Result<FirstValue, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = seq.next_element::<FirstValue>()? {
                    values.push(value.0);
                }
                Ok(FirstValue(Value::Array(values)))
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<FirstValue, A::Error> {
                let mut values = serde_json::Map::new();
                while let Some((key, value)) = map.next_entry::<String, FirstValue>()? {
                    values.entry(key).or_insert(value.0);
                }
                Ok(FirstValue(Value::Object(values)))
            }
        }
        d.deserialize_any(Visitor)
    }
}
fn provider(args: &Value) -> Result<Provider, ProviderError> {
    read(
        args.get("provider")
            .cloned()
            .ok_or_else(|| invalid("provider is required"))?,
    )
}
fn integer(args: &Value, key: &str) -> Result<i64, ProviderError> {
    args.get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid(format!("{key} must be an integer")))
}
fn optional_integer(args: &Value, key: &str) -> Result<Option<i64>, ProviderError> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        _ => integer(args, key).map(Some),
    }
}
fn string<'a>(args: &'a Value, key: &str, default: &'a str) -> Result<&'a str, ProviderError> {
    match args.get(key) {
        None => Ok(default),
        Some(Value::String(value)) => Ok(value),
        _ => Err(invalid(format!("{key} must be a string"))),
    }
}
fn base(args: &Value, p: Provider) -> Result<Url, ProviderError> {
    let base =
        Url::parse(string(args, "baseURL", p.base())?).map_err(|e| invalid(e.to_string()))?;
    if !matches!(base.scheme(), "http" | "https")
        || base.host_str().is_none()
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err(invalid(
            "baseURL must be an HTTP origin with an optional path prefix",
        ));
    }
    Ok(base)
}
fn timeout(args: &Value) -> Result<f64, ProviderError> {
    let timeout = match args.get("timeoutSeconds") {
        None => 30.0,
        Some(value) => value
            .as_f64()
            .ok_or_else(|| invalid("invalid timeoutSeconds"))?,
    };
    if !timeout.is_finite() || timeout <= 0.0 || timeout > 300.0 {
        return Err(invalid("timeoutSeconds must be in (0, 300]"));
    }
    Ok(timeout)
}

/// Builds provider requests, including repeated AniSkip types and string GraphQL variables.
pub fn prepare(args: &Value) -> Result<PreparedRequest, ProviderError> {
    let p = provider(args)?;
    let base = base(args, p)?;
    let mut url = base.clone();
    let mut headers = BTreeMap::from([
        ("Accept".into(), "application/json".into()),
        (
            "User-Agent".into(),
            string(args, "userAgent", USER_AGENT)?.into(),
        ),
    ]);
    let mut body = None;
    let path = match p {
        Provider::AniSkip => {
            let mal = integer(args, "malID")?;
            let episode = integer(args, "episodeNumber")?;
            if mal < 1 || episode < 1 {
                return Err(invalid("malID and episodeNumber must be positive"));
            }
            format!("/v2/skip-times/{mal}/{episode}")
        }
        Provider::AnimeSkip => "/graphql".into(),
        Provider::TheIntroDB => "/v3/media".into(),
        Provider::AniList => "/".into(),
    };
    let prefix = base.path().trim_end_matches('/');
    url.set_path(&format!("{prefix}{path}"));
    match p {
        Provider::AniSkip => {
            let mut q = url.query_pairs_mut();
            for kind in ["op", "ed", "mixed-op", "mixed-ed"] {
                q.append_pair("types", kind);
            }
            q.append_pair(
                "episodeLength",
                &optional_integer(args, "episodeLengthSeconds")?
                    .unwrap_or(0)
                    .max(0)
                    .to_string(),
            );
        }
        Provider::TheIntroDB => {
            url.query_pairs_mut()
                .append_pair("tmdb_id", &integer(args, "tmdbID")?.to_string())
                .append_pair(
                    "season",
                    &optional_integer(args, "seasonNumber")?
                        .unwrap_or(1)
                        .to_string(),
                )
                .append_pair("episode", &integer(args, "episodeNumber")?.to_string());
        }
        Provider::AnimeSkip | Provider::AniList => {
            headers.insert("Content-Type".into(), "application/json".into());
            let value = if p == Provider::AnimeSkip {
                headers.insert("X-Client-ID".into(), string(args, "clientID", "")?.into());
                json!({"query":ANIME_QUERY,"variables":{"service":"ANILIST","id":integer(args,"anilistID")?.to_string()}})
            } else {
                let query = string(args, "query", "")?;
                let variables: BTreeMap<String, String> =
                    read(args.get("variables").cloned().unwrap_or(json!({})))?;
                json!({"query":query,"variables":variables})
            };
            body = Some(STANDARD.encode(value.to_string()));
        }
    }
    Ok(PreparedRequest {
        provider: p,
        base_url: base.to_string(),
        url: url.to_string(),
        http_method: if body.is_some() { "POST" } else { "GET" }.into(),
        headers,
        body_base64: body,
        timeout_seconds: timeout(args)?,
    })
}

/// Restricts the raw bridge to each provider's read endpoints and retains status/bytes/headers.
pub async fn exchange<T: ocp_http::HttpTransport>(
    http: &HttpClient<T>,
    args: &Value,
) -> Result<Value, ProviderError> {
    let p = provider(args)?;
    let base = base(args, p)?;
    let url = Url::parse(string(args, "url", "")?).map_err(|e| invalid(e.to_string()))?;
    if url.origin() != base.origin()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(invalid("request must use the configured HTTP origin"));
    }
    let prefix = base.path().trim_end_matches('/');
    let path = url.path().strip_prefix(prefix).unwrap_or("");
    let method = string(args, "httpMethod", "GET")?;
    let body = match args.get("bodyBase64") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(
            STANDARD
                .decode(value)
                .map_err(|_| invalid("invalid bodyBase64"))?,
        ),
        _ => return Err(invalid("bodyBase64 must be a string")),
    };
    if !p.allows(path, method) || (method == "GET" && body.is_some()) {
        return Err(invalid("unsupported provider route or body"));
    }
    let values: BTreeMap<String, String> = read(args.get("headers").cloned().unwrap_or(json!({})))?;
    let mut headers = HeaderMap::new();
    // Native specs supply only these provider headers; arbitrary host/auth overrides are rejected.
    for (key, value) in values {
        if !["accept", "content-type", "user-agent", "x-client-id"]
            .contains(&key.to_ascii_lowercase().as_str())
        {
            return Err(invalid("unsupported provider header"));
        }
        headers.insert(
            reqwest::header::HeaderName::from_bytes(key.as_bytes())
                .map_err(|e| invalid(e.to_string()))?,
            value
                .parse()
                .map_err(|e: reqwest::header::InvalidHeaderValue| invalid(e.to_string()))?,
        );
    }
    let mut request = reqwest::Request::new(
        Method::from_bytes(method.as_bytes()).map_err(|e| invalid(e.to_string()))?,
        url,
    );
    *request.headers_mut() = headers;
    if let Some(body) = body {
        *request.body_mut() = Some(body.into());
    }
    *request.timeout_mut() = Some(Duration::from_secs_f64(timeout(args)?));
    let response = http.exchange_once(request).await?;
    let status = response.status().as_u16();
    let headers: BTreeMap<_, _> = response
        .headers()
        .iter()
        .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.to_string(), v.to_owned())))
        .collect();
    let bytes = response
        .bytes()
        .await
        .map_err(|e| ocp_http::HttpError::Decode(e.without_url()))?;
    Ok(json!({"status":status,"headers":headers,"bodyBase64":STANDARD.encode(bytes)}))
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AniSkipInterval {
    #[serde(rename = "type")]
    pub kind: String,
    pub start_seconds: f64,
    pub end_seconds: f64,
}
#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExternalInterval {
    pub start_seconds: Option<f64>,
    pub end_seconds: f64,
}
impl ExternalInterval {
    pub fn clamped(&self) -> Option<Self> {
        let start = self.start_seconds.unwrap_or(0.0).max(0.0);
        let end = self.end_seconds;
        (end >= 10.0 && end <= 1800.0 && start < end - 1.0 && end - start <= 400.0).then_some(
            Self {
                start_seconds: Some(start),
                end_seconds: end,
            },
        )
    }
}
pub fn decode_aniskip(bytes: &[u8]) -> Result<Option<Vec<AniSkipInterval>>, ProviderError> {
    #[derive(Deserialize)]
    struct Interval {
        #[serde(rename = "startTime")]
        start: f64,
        #[serde(rename = "endTime")]
        end: f64,
    }
    #[derive(Deserialize)]
    struct ResultItem {
        interval: Interval,
        #[serde(rename = "skipType")]
        kind: String,
    }
    #[derive(Deserialize)]
    struct Response {
        found: bool,
        results: Option<Vec<ResultItem>>,
    }
    let response: Response = decode_response(
        bytes,
        &json!({"found":null,"results":[{"skipType":null,"interval":{"startTime":null,"endTime":null}}]}),
    )?;
    Ok(response.found.then(|| {
        response
            .results
            .unwrap_or_default()
            .into_iter()
            .filter(|v| ["op", "ed", "mixed-op", "mixed-ed", "recap"].contains(&v.kind.as_str()))
            .map(|v| AniSkipInterval {
                kind: v.kind,
                start_seconds: v.interval.start,
                end_seconds: v.interval.end,
            })
            .collect()
    }))
}
pub fn aniskip_hint(intervals: &[AniSkipInterval]) -> Option<crate::cache::IntroHint> {
    let opening = intervals
        .iter()
        .find(|v| matches!(v.kind.as_str(), "op" | "mixed-op"))?;
    let interval = ExternalInterval {
        start_seconds: Some(opening.start_seconds),
        end_seconds: opening.end_seconds,
    }
    .clamped()?;
    Some(crate::cache::IntroHint {
        start_seconds: interval.start_seconds,
        end_seconds: interval.end_seconds,
        evidence_count: 1,
        source: crate::cache::IntroSource::Aniskip,
    })
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AnimeEpisode {
    pub season: Option<String>,
    pub number: Option<String>,
    pub timestamps: Option<Vec<AnimeTimestamp>>,
}
#[derive(Debug, Deserialize, Serialize)]
pub struct AnimeTimestamp {
    pub at: Option<f64>,
    #[serde(rename = "type")]
    pub kind: Option<AnimeTimestampType>,
}
#[derive(Debug, Deserialize, Serialize)]
pub struct AnimeTimestampType {
    pub name: Option<String>,
}
pub fn anime_interval(
    episodes: &[AnimeEpisode],
    season: Option<i64>,
    number: i64,
) -> Option<ExternalInterval> {
    let candidates: Vec<_> = episodes
        .iter()
        .filter(|ep| ep.number.as_ref().and_then(|n| n.parse::<i64>().ok()) == Some(number))
        .collect();
    let expected = season.unwrap_or(1).to_string();
    let episode = candidates
        .iter()
        .find(|ep| ep.season.as_deref() == Some(&expected))
        .or_else(|| candidates.first())?;
    let mut stamps: Vec<_> = episode
        .timestamps
        .as_ref()?
        .iter()
        .filter_map(|ts| {
            ts.at
                .map(|at| (at, ts.kind.as_ref().and_then(|v| v.name.as_deref())))
        })
        .collect();
    stamps.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let index = stamps
        .iter()
        .position(|v| matches!(v.1, Some("Intro" | "Mixed Intro" | "New Intro")))?;
    Some(ExternalInterval {
        start_seconds: Some(stamps[index].0),
        end_seconds: stamps.get(index + 1)?.0,
    })
}
pub fn decode_anime_skip(
    bytes: &[u8],
    season: Option<i64>,
    number: i64,
) -> Result<Option<ExternalInterval>, ProviderError> {
    #[derive(Deserialize)]
    struct Show {
        episodes: Option<Vec<AnimeEpisode>>,
    }
    #[derive(Deserialize)]
    struct Data {
        #[serde(rename = "findShowsByExternalId")]
        shows: Option<Vec<Show>>,
    }
    #[derive(Deserialize)]
    struct GraphError {
        #[serde(rename = "message")]
        _message: String,
    }
    #[derive(Deserialize)]
    struct Response {
        data: Option<Data>,
        #[serde(rename = "errors")]
        _errors: Option<Vec<GraphError>>,
    }
    let response: Response = decode_response(
        bytes,
        &json!({"data":{"findShowsByExternalId":[{"episodes":[{"season":null,"number":null,"timestamps":[{"at":null,"type":{"name":null}}]}]}]},"errors":[{"message":null}]}),
    )?;
    let episodes: Vec<_> = response
        .data
        .and_then(|v| v.shows)
        .unwrap_or_default()
        .into_iter()
        .flat_map(|v| v.episodes.unwrap_or_default())
        .collect();
    Ok(anime_interval(&episodes, season, number).and_then(|v| v.clamped()))
}

// JSONDecoder accepts integral floating JSON numbers for Int (e.g. 90000.0).
fn optional_swift_int<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    let value = Option::<serde_json::Number>::deserialize(d)?;
    value
        .map(|n| {
            n.as_i64()
                .or_else(|| {
                    n.as_f64()
                        .filter(|v| {
                            v.is_finite()
                                && v.fract() == 0.0
                                && *v >= i64::MIN as f64
                                && *v < (i64::MAX as f64)
                        })
                        .map(|v| v as i64)
                })
                .ok_or_else(|| serde::de::Error::custom("expected a 64-bit integer"))
        })
        .transpose()
}
pub fn decode_intro_db(bytes: &[u8]) -> Result<Option<ExternalInterval>, ProviderError> {
    #[derive(Deserialize)]
    struct Segment {
        #[serde(default, deserialize_with = "optional_swift_int")]
        start_ms: Option<i64>,
        #[serde(default, deserialize_with = "optional_swift_int")]
        end_ms: Option<i64>,
    }
    #[derive(Deserialize)]
    struct Response {
        intro: Option<Vec<Segment>>,
    }
    let response: Response =
        decode_response(bytes, &json!({"intro":[{"start_ms":null,"end_ms":null}]}))?;
    Ok(response
        .intro
        .and_then(|v| v.into_iter().next())
        .and_then(|v| {
            Some(ExternalInterval {
                start_seconds: Some(v.start_ms? as f64 / 1000.0),
                end_seconds: v.end_ms? as f64 / 1000.0,
            })
        })
        .and_then(|v| v.clamped()))
}
pub fn payload(value: impl Serialize) -> Result<Value, ProviderError> {
    Ok(
        json!({"payloadJSON":serde_json::to_string(&value).map_err(|e|ProviderError::Decode(e.to_string()))?}),
    )
}
fn input(args: &Value) -> Result<Value, ProviderError> {
    match args.get("payloadJSON") {
        Some(Value::String(value)) => decode(value.as_bytes()),
        Some(value) => Ok(value.clone()),
        None => Err(invalid("payloadJSON is required")),
    }
}
fn response_bytes(args: &Value) -> Result<Vec<u8>, ProviderError> {
    match args.get("responseBase64") {
        Some(Value::String(value)) => STANDARD
            .decode(value)
            .map_err(|_| invalid("invalid responseBase64")),
        Some(_) => Err(invalid("responseBase64 must be a string")),
        None => Ok(string(args, "responseJSON", "")?.as_bytes().to_vec()),
    }
}
pub fn policy(method: &str, args: &Value) -> Result<Value, ProviderError> {
    match method {
        "request" => Ok(serde_json::to_value(prepare(args)?).unwrap()),
        "decodeAniSkip" => payload(decode_aniskip(&response_bytes(args)?)?),
        "decodeAnimeSkip" => payload(decode_anime_skip(
            &response_bytes(args)?,
            optional_integer(args, "seasonNumber")?,
            integer(args, "episodeNumber")?,
        )?),
        "decodeTheIntroDB" => payload(decode_intro_db(&response_bytes(args)?)?),
        "clamp" => payload(read::<ExternalInterval>(input(args)?)?.clamped()),
        "aniskipHint" => payload(aniskip_hint(&read::<Vec<AniSkipInterval>>(input(args)?)?)),
        "animeInterval" => payload(anime_interval(
            &read::<Vec<AnimeEpisode>>(input(args)?)?,
            optional_integer(args, "seasonNumber")?,
            integer(args, "episodeNumber")?,
        )),
        _ => Err(invalid("unknown intro provider policy")),
    }
}
pub async fn fetch<T: ocp_http::HttpTransport>(
    http: &HttpClient<T>,
    method: &str,
    args: &Value,
) -> Result<Value, ProviderError> {
    if method == "exchange" {
        return exchange(http, args).await;
    }
    let p = match method {
        "aniskip" => Provider::AniSkip,
        "animeSkip" => Provider::AnimeSkip,
        "theIntroDB" => Provider::TheIntroDB,
        _ => return Err(invalid("unknown intro provider")),
    };
    let mut args = args.clone();
    args.as_object_mut()
        .ok_or_else(|| invalid("arguments must be an object"))?
        .insert("provider".into(), json!(p));
    if p == Provider::AnimeSkip {
        integer(&args, "episodeNumber")?;
        optional_integer(&args, "seasonNumber")?;
    }
    let prepared = prepare(&args)?;
    let response = exchange(http, &serde_json::to_value(prepared).unwrap()).await?;
    let status = response["status"].as_u64().unwrap() as u16;
    if p == Provider::AniSkip && status == 404 {
        return payload(Option::<Vec<AniSkipInterval>>::None);
    }
    if !(200..300).contains(&status) {
        return Err(ProviderError::Status(status));
    }
    let bytes = STANDARD
        .decode(response["bodyBase64"].as_str().unwrap())
        .unwrap();
    match p {
        Provider::AniSkip => payload(decode_aniskip(&bytes)?),
        Provider::AnimeSkip => payload(decode_anime_skip(
            &bytes,
            optional_integer(&args, "seasonNumber")?,
            integer(&args, "episodeNumber")?,
        )?),
        Provider::TheIntroDB => payload(decode_intro_db(&bytes)?),
        Provider::AniList => unreachable!(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn first_opening_and_first_segment_are_authoritative() {
        let intervals=decode_aniskip(br#"{"found":true,"results":[{"skipType":"future","interval":{"startTime":0,"endTime":80}},{"skipType":"op","interval":{"startTime":90,"endTime":80}},{"skipType":"op","interval":{"startTime":0,"endTime":80}}]}"#).unwrap().unwrap();
        assert_eq!(intervals.len(), 2);
        assert!(aniskip_hint(&intervals).is_none());
        assert!(
            decode_intro_db(br#"{"intro":[{}, {"start_ms":0,"end_ms":90000}]}"#)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            decode_intro_db(br#"{"intro":[{"start_ms":-1.0,"end_ms":90000.0}]}"#)
                .unwrap()
                .unwrap()
                .end_seconds,
            90.0
        );
        assert!(decode_intro_db(br#"{"intro":[{"start_ms":0,"end_ms":90000.1}]}"#).is_err());
    }
    #[test]
    fn strict_full_response_decode_and_nil_tolerance() {
        assert!(decode_aniskip(br#"{"found":false,"results":[{}]}"#).is_err());
        assert!(decode_aniskip(br#"{"found":false}"#).unwrap().is_none());
        assert_eq!(decode_aniskip(br#"{"found":true}"#).unwrap(), Some(vec![]));
        assert!(decode_anime_skip(br#"{"errors":[{}]}"#, None, 1).is_err());
        assert!(decode_anime_skip(b"{}", None, 1).unwrap().is_none());
    }
    #[test]
    fn request_prefix_repeated_types_and_strings() {
        let r=prepare(&json!({"provider":"aniSkip","baseURL":"http://localhost/root/","malID":42,"episodeNumber":1,"episodeLengthSeconds":-10})).unwrap();
        assert_eq!(r.url,"http://localhost/root/v2/skip-times/42/1?types=op&types=ed&types=mixed-op&types=mixed-ed&episodeLength=0");
        let r = prepare(&json!({"provider":"animeSkip","anilistID":i64::MAX,"clientID":"key"}))
            .unwrap();
        let body: Value =
            serde_json::from_slice(&STANDARD.decode(r.body_base64.unwrap()).unwrap()).unwrap();
        assert_eq!(body["variables"]["id"], i64::MAX.to_string());
    }
    #[test]
    fn season_precedence_and_next_timestamp_even_equal() {
        let episodes: Vec<AnimeEpisode> = serde_json::from_value(json!([
            {"number":"01","timestamps":[{"at":0,"type":{"name":"Intro"}},{"at":90}]},
            {"season":"2","number":"+1","timestamps":[{"at":30,"type":{"name":"Intro"}},{"at":30},{"at":100}]}
        ])).unwrap();
        assert_eq!(
            anime_interval(&episodes, Some(2), 1).unwrap().end_seconds,
            30.0
        );
        assert!(anime_interval(&episodes, Some(2), 1)
            .unwrap()
            .clamped()
            .is_none());
        assert_eq!(
            anime_interval(&episodes, None, 1).unwrap().end_seconds,
            90.0
        );
    }
}
