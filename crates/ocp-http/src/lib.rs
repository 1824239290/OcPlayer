//! Shared HTTP transport with bounded retries and stable error classification.

use async_trait::async_trait;
use reqwest::{
    header::{HeaderMap, HeaderValue, RETRY_AFTER},
    Method, StatusCode, Url,
};
use serde::de::DeserializeOwned;
use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCategory {
    Cancelled,
    Timeout,
    Unauthorized,
    NotFound,
    RateLimited,
    Server,
    Transport,
    Decode,
    InvalidRequest,
}

#[derive(Debug, Error)]
pub enum HttpError {
    #[error("{category:?}: {message}")]
    Request {
        category: ErrorCategory,
        message: String,
        status: Option<u16>,
        retryable: bool,
        retry_after: Option<Duration>,
    },
    #[error("invalid URL: {0}")]
    InvalidUrl(#[from] url::ParseError),
    #[error("JSON decode failed: {0}")]
    Decode(#[from] reqwest::Error),
}

impl HttpError {
    pub fn category(&self) -> Option<ErrorCategory> {
        match self {
            Self::Request { category, .. } => Some(*category),
            Self::InvalidUrl(_) => Some(ErrorCategory::InvalidRequest),
            Self::Decode(error) => Some(if error.is_timeout() {
                ErrorCategory::Timeout
            } else if error.is_connect() || error.is_body() || error.is_request() {
                ErrorCategory::Transport
            } else {
                ErrorCategory::Decode
            }),
        }
    }

    pub fn retryable(&self) -> bool {
        matches!(
            self,
            Self::Request {
                retryable: true,
                ..
            }
        ) || matches!(self, Self::Decode(error) if error.is_timeout() || error.is_connect() || error.is_body() || error.is_request())
    }

    pub fn retry_after(&self) -> Option<Duration> {
        match self {
            Self::Request { retry_after, .. } => *retry_after,
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct RetryPolicy {
    pub max_attempts: usize,
    pub base_delay: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay: Duration::from_millis(250),
        }
    }
}

#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn send(&self, request: reqwest::Request) -> Result<reqwest::Response, reqwest::Error>;
}

#[async_trait]
impl HttpTransport for reqwest::Client {
    async fn send(&self, request: reqwest::Request) -> Result<reqwest::Response, reqwest::Error> {
        self.execute(request).await
    }
}

#[derive(Clone)]
pub struct HttpClient<T = reqwest::Client> {
    transport: T,
    pub retry: RetryPolicy,
    retry_server_errors: bool,
}

impl HttpClient<reqwest::Client> {
    pub fn new() -> Self {
        Self {
            transport: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build()
                .expect("default HTTP client configuration is valid"),
            retry: RetryPolicy::default(),
            retry_server_errors: true,
        }
    }
}

impl Default for HttpClient<reqwest::Client> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> HttpClient<T> {
    pub fn with_transport(transport: T) -> Self {
        Self {
            transport,
            retry: RetryPolicy::default(),
            retry_server_errors: true,
        }
    }

    /// Some domains retry rate limits and transport failures, while treating
    /// other HTTP failures as final. This preserves the existing connection pool.
    pub fn retry_rate_limits_only(mut self) -> Self {
        self.retry_server_errors = false;
        self
    }
}

impl<T: HttpTransport> HttpClient<T> {
    /// A single JSON attempt for a caller-owned polling/retry policy.
    pub async fn json_once<R: DeserializeOwned>(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<serde_json::Value>,
    ) -> Result<R, HttpError> {
        let mut request = reqwest::Request::new(method, url);
        *request.headers_mut() = headers;
        if let Some(body) = body {
            *request.body_mut() = Some(reqwest::Body::from(body.to_string()));
            request.headers_mut().insert(
                reqwest::header::CONTENT_TYPE,
                HeaderValue::from_static("application/json"),
            );
        }
        let mut response = self.exchange_once(request).await?;
        if !response.status().is_success() {
            let error = status_error(response.status(), response.headers());
            // Drain small error bodies so the shared connection stays reusable.
            // Never include authentication response payloads in diagnostics.
            let mut bytes = 0;
            while let Ok(Some(chunk)) = response.chunk().await {
                bytes += chunk.len();
                if bytes > 16 * 1024 {
                    break;
                }
            }
            return Err(error);
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|error| HttpError::Decode(error.without_url()))?;
        serde_json::from_slice(&bytes).map_err(|error| HttpError::Request {
            category: ErrorCategory::Decode,
            message: error.to_string(),
            status: None,
            retryable: false,
            retry_after: None,
        })
    }

    /// Executes exactly once, preserving status and binary response bodies.
    /// Platform authentication/retry loops can reuse the pool without nested retries.
    pub async fn exchange_once(
        &self,
        request: reqwest::Request,
    ) -> Result<reqwest::Response, HttpError> {
        self.transport
            .send(request)
            .await
            .map_err(|error| HttpError::Decode(error.without_url()))
    }

    /// Explicitly read-only POST operations such as issuing a login token.
    pub async fn exchange_idempotent(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<(Vec<u8>, &'static str)>,
    ) -> Result<reqwest::Response, HttpError> {
        self.exchange_with_status(method, url, headers, body, false, true)
            .await
    }

    pub async fn json<R: DeserializeOwned>(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<serde_json::Value>,
    ) -> Result<R, HttpError> {
        let bytes = self.bytes(method, url, headers, body).await?;
        serde_json::from_slice(&bytes).map_err(|error| HttpError::Request {
            category: ErrorCategory::Decode,
            message: error.to_string(),
            status: None,
            retryable: false,
            retry_after: None,
        })
    }

    /// For domain operations known to be read-only despite using POST (search).
    pub async fn json_idempotent<R: DeserializeOwned>(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<serde_json::Value>,
    ) -> Result<R, HttpError> {
        let response = self
            .exchange_with_status(
                method,
                url,
                headers,
                body.map(|value| (value.to_string().into_bytes(), "application/json")),
                false,
                true,
            )
            .await?;
        let bytes = response
            .bytes()
            .await
            .map_err(|error| HttpError::Decode(error.without_url()))?;
        serde_json::from_slice(&bytes).map_err(|error| HttpError::Request {
            category: ErrorCategory::Decode,
            message: error.to_string(),
            status: None,
            retryable: false,
            retry_after: None,
        })
    }

    pub async fn bytes(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<serde_json::Value>,
    ) -> Result<Vec<u8>, HttpError> {
        let body = body.map(|value| (value.to_string().into_bytes(), "application/json"));
        self.bytes_with_body(method, url, headers, body).await
    }

    pub async fn form<I, K, V>(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        fields: I,
    ) -> Result<Vec<u8>, HttpError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let body = {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            for (key, value) in fields {
                serializer.append_pair(key.as_ref(), value.as_ref());
            }
            serializer.finish().into_bytes()
        };
        self.bytes_with_body(
            method,
            url,
            headers,
            Some((body, "application/x-www-form-urlencoded")),
        )
        .await
    }

    async fn bytes_with_body(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<(Vec<u8>, &'static str)>,
    ) -> Result<Vec<u8>, HttpError> {
        self.exchange(method, url, headers, body)
            .await?
            .bytes()
            .await
            .map(|bytes| bytes.to_vec())
            .map_err(|error| HttpError::Decode(error.without_url()))
    }

    /// Returns headers immediately, allowing callers to consume an SSE body incrementally.
    pub async fn exchange(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<(Vec<u8>, &'static str)>,
    ) -> Result<reqwest::Response, HttpError> {
        self.exchange_with_status(method, url, headers, body, false, false)
            .await
    }

    /// Preserves the final status, headers and body for host-owned authentication
    /// lifecycle and domain error envelopes. Only idempotent operations are retried.
    pub async fn exchange_preserving_status(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<(Vec<u8>, &'static str)>,
        idempotent: bool,
    ) -> Result<reqwest::Response, HttpError> {
        self.exchange_with_status(method, url, headers, body, true, idempotent)
            .await
    }

    async fn exchange_with_status(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
        body: Option<(Vec<u8>, &'static str)>,
        preserve_status: bool,
        idempotent: bool,
    ) -> Result<reqwest::Response, HttpError> {
        // A failed response does not prove a creation request was never applied.
        let attempts = if idempotent
            || matches!(
                method,
                Method::GET | Method::HEAD | Method::PUT | Method::DELETE | Method::OPTIONS
            ) {
            self.retry.max_attempts.max(1)
        } else {
            1
        };
        for attempt in 0..attempts {
            let mut retry_after = None;
            let mut request = reqwest::Request::new(method.clone(), url.clone());
            *request.headers_mut() = headers.clone();
            if let Some((body, content_type)) = body.clone() {
                *request.body_mut() = Some(reqwest::Body::from(body));
                request.headers_mut().insert(
                    reqwest::header::CONTENT_TYPE,
                    content_type.parse().expect("static header"),
                );
            }
            match self.transport.send(request).await {
                Ok(response) if response.status().is_success() => {
                    return Ok(response);
                }
                Ok(mut response) => {
                    let mut error = status_error(response.status(), response.headers());
                    if !self.retry_server_errors
                        && response.status() != StatusCode::TOO_MANY_REQUESTS
                    {
                        if let HttpError::Request { retryable, .. } = &mut error {
                            *retryable = false;
                        }
                    }
                    if preserve_status && (!error.retryable() || attempt + 1 >= attempts) {
                        return Ok(response);
                    }
                    // Read only a bounded error payload; never include the request URL.
                    let mut body = Vec::new();
                    while let Ok(Some(chunk)) = response.chunk().await {
                        if body.len() + chunk.len() > 16 * 1024 {
                            break;
                        }
                        body.extend_from_slice(&chunk);
                    }
                    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) {
                        if let Some(text) = value
                            .get("message")
                            .or_else(|| value.get("detail"))
                            .and_then(serde_json::Value::as_str)
                        {
                            if let HttpError::Request { message, .. } = &mut error {
                                *message = text.to_owned();
                            }
                        }
                    }
                    if !error.retryable() || attempt + 1 >= attempts {
                        return Err(error);
                    }
                    retry_after = error.retry_after();
                }
                Err(error) => {
                    let classified = HttpError::Decode(error.without_url());
                    if !classified.retryable() || attempt + 1 >= attempts {
                        return Err(classified);
                    }
                }
            }
            let delay = retry_after
                .unwrap_or_else(|| self.retry.base_delay.saturating_mul(1u32 << attempt.min(4)));
            tokio::time::sleep(delay).await;
        }
        unreachable!("retry loop returns on every attempt")
    }

    pub async fn empty(
        &self,
        method: Method,
        url: Url,
        headers: HeaderMap,
    ) -> Result<(), HttpError> {
        self.bytes(method, url, headers, None).await.map(|_| ())
    }
}

fn status_error(status: StatusCode, headers: &HeaderMap) -> HttpError {
    let (category, retryable) = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => (ErrorCategory::Unauthorized, false),
        StatusCode::NOT_FOUND => (ErrorCategory::NotFound, false),
        StatusCode::TOO_MANY_REQUESTS => (ErrorCategory::RateLimited, true),
        status if status.is_server_error() => (ErrorCategory::Server, true),
        _ => (ErrorCategory::InvalidRequest, false),
    };
    HttpError::Request {
        category,
        message: format!("HTTP {status}"),
        status: Some(status.as_u16()),
        retryable,
        retry_after: if status == StatusCode::TOO_MANY_REQUESTS {
            headers.get(RETRY_AFTER).and_then(parse_retry_after)
        } else {
            None
        },
    }
}

fn parse_retry_after(value: &reqwest::header::HeaderValue) -> Option<Duration> {
    let value = value.to_str().ok()?.trim();
    let seconds = value.parse::<f64>().ok()?;
    (seconds.is_finite() && seconds >= 0.0).then(|| Duration::from_secs_f64(seconds.min(86_400.0)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::HeaderValue;

    struct FailingTransport(std::sync::atomic::AtomicUsize);

    #[async_trait]
    impl HttpTransport for FailingTransport {
        async fn send(&self, _: reqwest::Request) -> Result<reqwest::Response, reqwest::Error> {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(reqwest::Response::from(
                http::Response::builder()
                    .status(503)
                    .body("unavailable")
                    .unwrap(),
            ))
        }
    }

    #[tokio::test]
    async fn retries_reads_but_never_replays_creation_requests() {
        for (method, expected) in [
            (Method::GET, 3),
            (Method::POST, 1),
            (Method::PATCH, 1),
            (Method::PUT, 3),
            (Method::DELETE, 3),
        ] {
            let mut client = HttpClient::with_transport(FailingTransport(
                std::sync::atomic::AtomicUsize::new(0),
            ));
            client.retry.base_delay = Duration::ZERO;
            assert!(client
                .bytes(
                    method,
                    Url::parse("http://localhost/test").unwrap(),
                    HeaderMap::new(),
                    None
                )
                .await
                .is_err());
            assert_eq!(
                client.transport.0.load(std::sync::atomic::Ordering::SeqCst),
                expected
            );
        }
    }

    #[test]
    fn classifies_statuses() {
        assert_eq!(
            status_error(StatusCode::UNAUTHORIZED, &HeaderMap::new()).category(),
            Some(ErrorCategory::Unauthorized)
        );
        assert!(status_error(StatusCode::SERVICE_UNAVAILABLE, &HeaderMap::new()).retryable());
        assert!(!status_error(StatusCode::BAD_REQUEST, &HeaderMap::new()).retryable());
    }

    #[tokio::test]
    async fn rate_limit_only_policy_keeps_http_errors_final_without_changing_other_domains() {
        struct StatusTransport {
            status: u16,
            calls: std::sync::atomic::AtomicUsize,
        }
        #[async_trait]
        impl HttpTransport for StatusTransport {
            async fn send(&self, _: reqwest::Request) -> Result<reqwest::Response, reqwest::Error> {
                self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(reqwest::Response::from(
                    http::Response::builder()
                        .status(self.status)
                        .body("{}".to_owned())
                        .unwrap(),
                ))
            }
        }
        for (status, limited, expected, retryable) in [
            (500, true, 1, false),
            (503, true, 1, false),
            (429, true, 3, true),
            (401, true, 1, false),
            (503, false, 3, true),
        ] {
            let client = HttpClient::with_transport(StatusTransport {
                status,
                calls: Default::default(),
            });
            let mut client = if limited {
                client.retry_rate_limits_only()
            } else {
                client
            };
            client.retry.base_delay = Duration::ZERO;
            let error = client
                .bytes(
                    Method::GET,
                    Url::parse("http://localhost/fixture").unwrap(),
                    HeaderMap::new(),
                    None,
                )
                .await
                .unwrap_err();
            assert_eq!(
                client
                    .transport
                    .calls
                    .load(std::sync::atomic::Ordering::SeqCst),
                expected
            );
            assert_eq!(error.retryable(), retryable);
        }
    }

    #[test]
    fn parses_retry_after_seconds_only_for_rate_limits() {
        let mut headers = HeaderMap::new();
        headers.insert(RETRY_AFTER, HeaderValue::from_static("2.5"));
        assert_eq!(
            status_error(StatusCode::TOO_MANY_REQUESTS, &headers).retry_after(),
            Some(Duration::from_millis(2500))
        );
        assert_eq!(
            status_error(StatusCode::SERVICE_UNAVAILABLE, &headers).retry_after(),
            None
        );
    }
}
