//! MoviePilot authentication, media, torrent, subscription, and task API models.

use ocp_http::{HttpClient, HttpError};
use reqwest::{
    header::{HeaderMap, HeaderValue, AUTHORIZATION},
    Method,
};
use serde::{de::DeserializeOwned, Deserialize, Deserializer, Serialize};
use serde_json::Value;
use thiserror::Error;
use url::Url;

pub mod account;
mod stream;
pub use stream::{SearchUpdate, StreamDecoder};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct User {
    pub id: Option<i64>,
    pub name: String,
    pub permissions: Option<Vec<String>>,
    pub avatar: Option<String>,
    pub email: Option<String>,
    pub is_superuser: Option<bool>,
    pub is_active: Option<bool>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MediaInfo {
    pub title: Option<String>,
    pub year: Option<i32>,
    pub media_type: Option<String>,
    pub tmdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub poster: Option<String>,
    pub overview: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Torrent {
    pub id: String,
    pub title: String,
    pub size: Option<u64>,
    pub seeders: Option<u32>,
    pub leechers: Option<u32>,
    pub site: Option<String>,
    pub download_url: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadTask {
    pub id: String,
    pub name: String,
    pub state: Option<String>,
    pub progress: Option<f64>,
    pub size: Option<u64>,
    pub speed: Option<u64>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Subscription {
    pub id: i64,
    pub name: String,
    pub keyword: Option<String>,
    pub enabled: bool,
    pub state: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchProgress {
    pub text: Option<String>,
    pub finished: u32,
    pub total: u32,
    #[serde(rename = "total_items")]
    pub total_items: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TorrentResult {
    pub torrent: Value,
    pub meta: Option<Value>,
}

#[derive(Debug, Clone)]
pub enum ApiEnvelope<T> {
    Direct(T),
    Wrapped {
        success: Option<bool>,
        code: Option<i32>,
        message: Option<String>,
        data: Option<T>,
    },
}
impl<'de, T: DeserializeOwned> Deserialize<'de> for ApiEnvelope<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        let is_wrapped = value.get("success").is_some()
            || (value.get("code").is_some() && value.get("message").is_some());
        if is_wrapped {
            let data = value
                .get("data")
                .cloned()
                .map(serde_json::from_value)
                .transpose()
                .map_err(serde::de::Error::custom)?;
            Ok(Self::Wrapped {
                success: value.get("success").and_then(serde_json::Value::as_bool),
                code: value
                    .get("code")
                    .and_then(serde_json::Value::as_i64)
                    .map(|v| v as i32),
                message: value
                    .get("message")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                data,
            })
        } else {
            serde_json::from_value(value)
                .map(Self::Direct)
                .map_err(serde::de::Error::custom)
        }
    }
}
impl<T> ApiEnvelope<T> {
    pub fn into_result(self) -> Result<T, String> {
        match self {
            Self::Direct(data) => Ok(data),
            Self::Wrapped {
                success,
                code,
                message,
                data,
            } => {
                if success == Some(false) || !matches!(code, None | Some(0 | 200)) {
                    return Err(message.unwrap_or_else(|| {
                        format!("MoviePilot API error {}", code.unwrap_or_default())
                    }));
                }
                data.ok_or_else(|| "MoviePilot response has no data".into())
            }
        }
    }
}

fn envelope_value(value: Value) -> Result<Value, MoviePilotError> {
    serde_json::from_value::<ApiEnvelope<Value>>(value)
        .map_err(MoviePilotError::Json)?
        .into_result()
        .map_err(MoviePilotError::Api)
}

fn list_value(value: Value) -> Result<Vec<Value>, MoviePilotError> {
    let value = envelope_value(value)?;
    match value {
        Value::Array(items) if items.iter().all(Value::is_object) => Ok(items),
        _ => Err(MoviePilotError::Api("expected an array of objects".into())),
    }
}

#[derive(Debug, Error)]
pub enum MoviePilotError {
    #[error("invalid URL: {0}")]
    Url(#[from] url::ParseError),
    #[error("HTTP: {0}")]
    Http(#[from] HttpError),
    #[error("API: {0}")]
    Api(String),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid request: {0}")]
    Invalid(String),
}

impl MoviePilotError {
    pub fn is_authentication_failure(&self) -> bool {
        match self {
            Self::Http(HttpError::Request {
                status: Some(401), ..
            }) => true,
            Self::Http(HttpError::Request {
                status: Some(403),
                message,
                ..
            }) => {
                let lower = message.to_lowercase();
                lower.contains("token")
                    && [
                        "校验",
                        "不通过",
                        "过期",
                        "无效",
                        "非法",
                        "invalid",
                        "expired",
                        "verify",
                    ]
                    .iter()
                    .any(|word| lower.contains(word))
            }
            _ => false,
        }
    }
}

/// Canonical server identity used by account-scoped connection pools.
pub fn normalize_base_url(base: &str) -> Result<Url, MoviePilotError> {
    let mut base = Url::parse(base)?;
    if !matches!(base.scheme(), "http" | "https")
        || base.host_str().is_none()
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err(MoviePilotError::Invalid(
            "baseURL must be an HTTP(S) server URL without credentials, query or fragment".into(),
        ));
    }
    if !base.path().ends_with('/') {
        base.set_path(&format!("{}/", base.path()))
    }
    Ok(base)
}

pub struct Client {
    base: Url,
    token: Option<String>,
    http: HttpClient<reqwest::Client>,
    stream_http: HttpClient<reqwest::Client>,
}
impl Client {
    pub fn new(base: &str, token: Option<String>) -> Result<Self, MoviePilotError> {
        let jar = std::sync::Arc::new(reqwest::cookie::Jar::default());
        let build = |idle, timeout| {
            reqwest::Client::builder()
                .cookie_provider(jar.clone())
                .connect_timeout(std::time::Duration::from_secs(idle))
                .read_timeout(std::time::Duration::from_secs(idle))
                .timeout(std::time::Duration::from_secs(timeout))
                .build()
                .map_err(|error| MoviePilotError::Http(HttpError::Decode(error.without_url())))
        };
        Self::with_http(
            base,
            token,
            HttpClient::with_transport(build(15, 30)?),
            HttpClient::with_transport(build(30, 300)?),
        )
    }

    /// The host may retain these transports across commands. Both must use the
    /// same account-scoped cookie jar so the JWT preflight authenticates SSE.
    pub fn with_http(
        base: &str,
        token: Option<String>,
        http: HttpClient<reqwest::Client>,
        stream_http: HttpClient<reqwest::Client>,
    ) -> Result<Self, MoviePilotError> {
        let base = normalize_base_url(base)?;
        Ok(Self {
            base,
            token,
            http,
            stream_http,
        })
    }
    pub fn set_token(&mut self, token: Option<String>) {
        self.token = token
    }
    pub fn access_token(&self) -> Option<&str> {
        self.token.as_deref()
    }
    pub async fn get<T: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
    ) -> Result<T, MoviePilotError> {
        self.request(Method::GET, path, None).await
    }
    pub async fn post<B: Serialize + Sync, T: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, MoviePilotError> {
        self.request(Method::POST, path, Some(serde_json::to_value(body)?))
            .await
    }

    pub async fn login(&mut self, username: &str, password: &str) -> Result<User, MoviePilotError> {
        self.issue_token(username, password).await?;
        self.current_user().await
    }

    /// Refresh only the JWT; silent reauthentication must not require a second
    /// current-user request before it can retry the original operation.
    pub async fn issue_token(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<String, MoviePilotError> {
        let body = {
            let mut form = url::form_urlencoded::Serializer::new(String::new());
            form.append_pair("username", username);
            form.append_pair("password", password);
            form.finish().into_bytes()
        };
        let response = self
            .http
            .exchange_idempotent(
                Method::POST,
                self.url("api/v1/login/access-token", &[])?,
                Self::public_headers(),
                Some((body, "application/x-www-form-urlencoded")),
            )
            .await?
            .bytes()
            .await
            .map_err(|error| HttpError::Decode(error.without_url()))?;
        #[derive(Deserialize)]
        struct TokenResponse {
            #[serde(alias = "token")]
            access_token: String,
        }
        // Malformed token JSON is an authentication protocol failure, distinct
        // from an empty token. Hosts use this category to trip relogin's fuse.
        let token: TokenResponse = serde_json::from_slice(&response)?;
        let token = token.access_token;
        if token.is_empty() {
            return Err(MoviePilotError::Api(
                "login response has no access token".into(),
            ));
        }
        self.set_token(Some(token.clone()));
        Ok(token)
    }

    /// One byte-preserving exchange. The native caller owns retries and token
    /// refresh, so this path never retries internally or decodes the body as JSON.
    pub async fn raw_request(
        &self,
        url: &str,
        method: &str,
        extra_headers: &std::collections::HashMap<String, String>,
        body: Option<Vec<u8>>,
        timeout: Option<std::time::Duration>,
    ) -> Result<reqwest::Response, MoviePilotError> {
        let target = Url::parse(url)?;
        if target.origin() != self.base.origin()
            || !target.path().starts_with(self.base.path())
            || !target.username().is_empty()
            || target.password().is_some()
            || target.fragment().is_some()
        {
            return Err(MoviePilotError::Invalid(
                "request URL leaves server base URL or contains credentials/fragment".into(),
            ));
        }
        let method = Method::from_bytes(method.as_bytes())
            .map_err(|_| MoviePilotError::Invalid("invalid HTTP method".into()))?;
        let mut request = reqwest::Request::new(method, target);
        *request.headers_mut() = self.headers()?;
        for (key, value) in extra_headers {
            let key = reqwest::header::HeaderName::from_bytes(key.as_bytes())
                .map_err(|_| MoviePilotError::Invalid("invalid header name".into()))?;
            let value = HeaderValue::from_str(value)
                .map_err(|_| MoviePilotError::Invalid("invalid header value".into()))?;
            // Credentials always belong to the selected account's token/jar.
            if key == AUTHORIZATION
                || key == reqwest::header::COOKIE
                || key == reqwest::header::HOST
            {
                return Err(MoviePilotError::Invalid(
                    "account/host headers must not be overridden".into(),
                ));
            }
            request.headers_mut().insert(key, value);
        }
        if let Some(body) = body {
            *request.body_mut() = Some(body.into());
        }
        *request.timeout_mut() = timeout;
        Ok(self.http.exchange_once(request).await?)
    }

    pub async fn current_user(&self) -> Result<User, MoviePilotError> {
        let value = envelope_value(
            self.request_value(Method::GET, "api/v1/user/current", None)
                .await?,
        )?;
        serde_json::from_value(value).map_err(MoviePilotError::Json)
    }

    pub async fn search_media(&self, title: &str) -> Result<Vec<Value>, MoviePilotError> {
        let query = [
            ("title", title),
            ("type", "media"),
            ("page", "1"),
            ("count", "24"),
        ];
        list_value(
            self.request_value(Method::GET, "api/v1/media/search", Some(&query))
                .await?,
        )
    }

    pub async fn sites(&self) -> Result<Vec<Value>, MoviePilotError> {
        list_value(
            self.request_value(Method::GET, "api/v1/site/", None)
                .await?,
        )
    }

    pub async fn add_download(&self, media: Value, torrent: Value) -> Result<(), MoviePilotError> {
        self.expect_success(
            self.request_json(
                Method::POST,
                "api/v1/download/",
                serde_json::json!({ "media_in": media, "torrent_in": torrent }),
            )
            .await?,
        )
    }

    pub async fn downloading_tasks(&self) -> Result<Vec<Value>, MoviePilotError> {
        list_value(
            self.request_value(Method::GET, "api/v1/download/", None)
                .await?,
        )
    }

    pub async fn download_control(&self, action: &str, hash: &str) -> Result<(), MoviePilotError> {
        if !matches!(action, "start" | "stop") {
            return Err(MoviePilotError::Invalid(
                "unsupported download action".into(),
            ));
        }
        let path = format!("api/v1/download/{action}/{}", path_segment(hash)?);
        self.request_status(Method::GET, &path).await
    }

    pub async fn remove_download(&self, hash: &str) -> Result<(), MoviePilotError> {
        let path = format!("api/v1/download/{}", path_segment(hash)?);
        self.request_status(Method::DELETE, &path).await
    }

    pub async fn subscriptions(&self) -> Result<Vec<Value>, MoviePilotError> {
        list_value(
            self.request_value(Method::GET, "api/v1/subscribe/", None)
                .await?,
        )
    }

    pub async fn add_subscription(&self, body: Value) -> Result<(), MoviePilotError> {
        self.expect_success(
            self.request_json(Method::POST, "api/v1/subscribe/", body)
                .await?,
        )
    }

    pub async fn update_subscription(&self, body: Value) -> Result<(), MoviePilotError> {
        self.expect_success(
            self.request_json(Method::PUT, "api/v1/subscribe/", body)
                .await?,
        )
    }

    pub async fn delete_subscription(&self, id: i64) -> Result<(), MoviePilotError> {
        if id <= 0 {
            return Err(MoviePilotError::Invalid("id must be positive".into()));
        }
        let path = format!("api/v1/subscribe/{id}");
        self.request_status(Method::DELETE, &path).await
    }

    pub async fn delete_subscription_by_media(
        &self,
        media_id: &str,
    ) -> Result<(), MoviePilotError> {
        let path = format!("api/v1/subscribe/media/{}", path_segment(media_id)?);
        self.request_status(Method::DELETE, &path).await
    }

    pub async fn refresh_subscriptions(&self) -> Result<(), MoviePilotError> {
        self.request_status(Method::GET, "api/v1/subscribe/refresh")
            .await
    }

    pub async fn search_subscriptions(&self) -> Result<(), MoviePilotError> {
        self.request_status(Method::GET, "api/v1/subscribe/search")
            .await
    }

    pub async fn search_torrents_stream(
        &self,
        keyword: &str,
        sites: &[i64],
    ) -> Result<Vec<TorrentResult>, MoviePilotError> {
        self.search_torrents_with_updates(keyword, sites, |_| {})
            .await
    }

    pub async fn search_torrents_with_updates(
        &self,
        keyword: &str,
        sites: &[i64],
        mut on_update: impl FnMut(SearchUpdate),
    ) -> Result<Vec<TorrentResult>, MoviePilotError> {
        // MoviePilot's stream authenticates with a resource cookie issued by JWT requests.
        self.current_user().await?;
        let sites = sites
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let query = if sites.is_empty() {
            vec![("keyword", keyword.to_string())]
        } else {
            vec![("keyword", keyword.to_string()), ("sites", sites)]
        };
        let refs = query
            .iter()
            .map(|(k, v)| (*k, v.as_str()))
            .collect::<Vec<_>>();
        let url = self.url("api/v1/search/title/stream", &refs)?;
        let mut headers = self.headers()?;
        headers.insert(
            reqwest::header::ACCEPT,
            HeaderValue::from_static("text/event-stream"),
        );
        let mut response = self
            .stream_http
            .exchange(Method::GET, url, headers, None)
            .await?;
        let mut decoder = StreamDecoder::default();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| HttpError::Decode(error.without_url()))?
        {
            for update in decoder.push(&chunk)? {
                on_update(update);
            }
            if decoder.is_done() {
                break;
            }
        }
        for update in decoder.finish()? {
            on_update(update);
        }
        Ok(decoder.into_items())
    }

    async fn request_value(
        &self,
        method: Method,
        path: &str,
        query: Option<&[(&str, &str)]>,
    ) -> Result<Value, MoviePilotError> {
        let url = self.url(path, query.unwrap_or_default())?;
        let bytes = self.http.bytes(method, url, self.headers()?, None).await?;
        serde_json::from_slice(&bytes).map_err(MoviePilotError::Json)
    }

    async fn request_json(
        &self,
        method: Method,
        path: &str,
        body: Value,
    ) -> Result<Value, MoviePilotError> {
        let url = self.url(path, &[])?;
        let bytes = self
            .http
            .bytes(method, url, self.headers()?, Some(body))
            .await?;
        serde_json::from_slice(&bytes)
            .or(Ok(Value::Null))
            .map_err(MoviePilotError::Json)
    }

    async fn request_status(&self, method: Method, path: &str) -> Result<(), MoviePilotError> {
        let url = self.url(path, &[])?;
        let bytes = self.http.bytes(method, url, self.headers()?, None).await?;
        if bytes.is_empty() {
            return Ok(());
        }
        let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        self.expect_success(value)
    }

    fn expect_success(&self, value: Value) -> Result<(), MoviePilotError> {
        match value {
            Value::Null => Ok(()),
            Value::Object(object)
                if object.get("success").and_then(Value::as_bool) == Some(false) =>
            {
                Err(MoviePilotError::Api(
                    object
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("operation failed")
                        .into(),
                ))
            }
            _ => Ok(()),
        }
    }

    fn public_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            reqwest::header::USER_AGENT,
            HeaderValue::from_static("OcPlayer/0.1 (MoviePilotKit)"),
        );
        headers
    }

    fn headers(&self) -> Result<HeaderMap, MoviePilotError> {
        let mut headers = Self::public_headers();
        if let Some(token) = &self.token {
            let value = HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|_| MoviePilotError::Invalid("invalid access token header".into()))?;
            headers.insert(AUTHORIZATION, value);
        }
        Ok(headers)
    }

    fn url(&self, path: &str, query: &[(&str, &str)]) -> Result<Url, MoviePilotError> {
        let mut url = self.base.join(path.trim_start_matches('/'))?;
        if url.origin() != self.base.origin() || !url.path().starts_with(self.base.path()) {
            return Err(MoviePilotError::Invalid(
                "request path leaves server base URL".into(),
            ));
        }
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query.iter().copied());
        }
        Ok(url)
    }
    async fn request<T: for<'de> Deserialize<'de>>(
        &self,
        method: Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<T, MoviePilotError> {
        let url = self.url(path, &[])?;
        let response: T = self.http.json(method, url, self.headers()?, body).await?;
        Ok(response)
    }
}

fn path_segment(value: &str) -> Result<String, MoviePilotError> {
    if value.is_empty() || matches!(value, "." | "..") {
        return Err(MoviePilotError::Invalid(
            "path identifier must be non-empty and not a dot segment".into(),
        ));
    }
    Ok(value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect())
}

#[cfg(test)]
fn parse_sse(bytes: &[u8]) -> Result<Vec<TorrentResult>, MoviePilotError> {
    let mut decoder = StreamDecoder::default();
    decoder.push(bytes)?;
    decoder.finish()?;
    Ok(decoder.into_items())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn supports_both_envelope_shapes() {
        let direct: ApiEnvelope<User> = serde_json::from_str(r#"{"id":1,"name":"user"}"#).unwrap();
        assert_eq!(direct.into_result().unwrap().name, "user");
        let wrapped: ApiEnvelope<User> =
            serde_json::from_str(r#"{"success":false,"code":401,"message":"denied"}"#).unwrap();
        assert!(wrapped.into_result().unwrap_err().contains("denied"));
    }
    #[test]
    fn joins_base_url() {
        let client = Client::new("https://example.test/mp", None).unwrap();
        assert_eq!(
            client.base.join("api/v1/user").unwrap().as_str(),
            "https://example.test/mp/api/v1/user"
        );
    }

    #[test]
    fn parses_sse_and_deduplicates_torrents() {
        let body = br#"data: {"type":"append","items":[{"torrent_info":{"enclosure":"https://t/1","title":"one"},"meta_info":{"season_episode":"S01E01"}}]}

data: {"type":"done","items":[{"torrent_info":{"enclosure":"https://t/1","title":"one"}},{"torrent_info":{"enclosure":"https://t/2","title":"two"}}]}"#;
        let items = parse_sse(body).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].meta.as_ref().unwrap()["season_episode"], "S01E01");
    }

    #[test]
    fn list_value_accepts_wrapped_and_direct_arrays() {
        let wrapped = serde_json::json!({"success": true, "data": [{"id": 1}]});
        let direct = serde_json::json!([{"id": 2}]);
        assert_eq!(list_value(wrapped).unwrap().len(), 1);
        assert_eq!(list_value(direct).unwrap()[0]["id"], 2);
    }
}
