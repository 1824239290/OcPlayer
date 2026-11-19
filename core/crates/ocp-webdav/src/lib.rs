//! Credential-scoped DAV enumeration and a bounded loopback Range resource.
//! No credentials, signed URLs or request diagnostics are persisted here.
use base64::Engine;
use reqwest::{header, Client, Method, Response};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use url::Url;

const MAX_XML: usize = 8 * 1024 * 1024;
const PROPERTIES: &str = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>"#;

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum Error {
    #[error("WebDAV 地址或路径无效")]
    Path,
    #[error("WebDAV 凭据无效或没有目录权限")]
    Unauthorized,
    #[error("WebDAV 连接失败，请检查服务器后重试")]
    Network,
    #[error("WebDAV 目录响应无效或超出大小限制")]
    Listing,
    #[error("WebDAV 服务器未正确支持 Range 读取")]
    Range,
    #[error("WebDAV 重定向超出来源范围；请填写最终目录地址")]
    Redirect,
    #[error("本机播放资源不可用")]
    Bridge,
}

#[derive(Clone, Serialize, Deserialize, Default)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Credential {
    #[default]
    None,
    Basic {
        username: String,
        password: String,
    },
    Bearer {
        token: String,
    },
}

#[derive(Clone)]
pub struct Provider {
    root: Url,
    client: Client,
    authorization: Option<header::HeaderValue>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Decoded relative segments. Always re-encode segments when making a URL.
    pub relative_path: String,
    pub is_directory: bool,
    pub size: i64,
    pub modified_at: f64,
    pub etag: Option<String>,
}

/// Canonical connection URL, never a credential-bearing or signed URL.
pub fn root_url(raw: &str) -> Result<Url, Error> {
    reject_segments(raw)?;
    let mut url = Url::parse(raw).map_err(|_| Error::Path)?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(Error::Path);
    }
    let segments = decoded_segments(&url)?;
    url.set_path("/");
    {
        let mut path = url.path_segments_mut().map_err(|_| Error::Path)?;
        path.clear();
        for segment in segments {
            path.push(&segment);
        }
        path.push("");
    }
    Ok(url)
}

fn reject_segments(raw: &str) -> Result<(), Error> {
    if raw.contains(['\\', '\0', '\r', '\n']) {
        return Err(Error::Path);
    }
    // Inspect before Url::join can normalize away an encoded traversal.
    for segment in raw.split(['/', '?', '#']) {
        let decoded = percent_encoding::percent_decode_str(segment)
            .decode_utf8()
            .map_err(|_| Error::Path)?;
        if matches!(decoded.as_ref(), "." | "..") || decoded.contains(['/', '\\', '\0', '\r', '\n'])
        {
            return Err(Error::Path);
        }
    }
    Ok(())
}

fn decoded_segments(url: &Url) -> Result<Vec<String>, Error> {
    if url.path().contains("//") {
        return Err(Error::Path);
    }
    url.path_segments()
        .ok_or(Error::Path)?
        .filter(|s| !s.is_empty())
        .map(|s| {
            let s = percent_encoding::percent_decode_str(s)
                .decode_utf8()
                .map_err(|_| Error::Path)?
                .into_owned();
            if s.is_empty()
                || matches!(s.as_str(), "." | "..")
                || s.contains(['/', '\\', '\0', '\r', '\n'])
            {
                Err(Error::Path)
            } else {
                Ok(s)
            }
        })
        .collect()
}

/// Both roots must already be normalized; directory boundaries are significant.
pub fn within(root: &str, candidate: &str) -> bool {
    let (Ok(root), Ok(candidate)) = (root_url(root), root_url(candidate)) else {
        return false;
    };
    root.origin() == candidate.origin() && candidate.path().starts_with(root.path())
}

impl Provider {
    pub fn new(root: &str, credential: Credential) -> Result<Self, Error> {
        let authorization = match credential {
            Credential::None => None,
            Credential::Basic { username, password } => {
                if username.contains([':', '\r', '\n', '\0']) {
                    return Err(Error::Unauthorized);
                }
                Some(format!(
                    "Basic {}",
                    base64::engine::general_purpose::STANDARD
                        .encode(format!("{username}:{password}"))
                ))
            }
            Credential::Bearer { token } => {
                if token.trim().is_empty() {
                    return Err(Error::Unauthorized);
                }
                Some(format!("Bearer {}", token.trim()))
            }
        }
        .map(|s| header::HeaderValue::from_str(&s).map_err(|_| Error::Unauthorized))
        .transpose()?;
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| Error::Network)?;
        Ok(Self {
            root: root_url(root)?,
            client,
            authorization,
        })
    }
    pub fn root(&self) -> &str {
        self.root.as_str()
    }
    pub fn same_access(&self, other: &Self) -> bool {
        self.root == other.root && self.authorization == other.authorization
    }
    pub fn scoped(&self, root: &str) -> Result<Self, Error> {
        if !within(self.root(), root) {
            return Err(Error::Path);
        }
        let mut provider = self.clone();
        provider.root = root_url(root)?;
        Ok(provider)
    }

    pub fn url(&self, relative: &str, directory: bool) -> Result<Url, Error> {
        if relative.starts_with('/') || relative.contains(['\\', '\0', '\r', '\n']) {
            return Err(Error::Path);
        }
        let mut url = self.root.clone();
        let mut segments = url.path_segments_mut().map_err(|_| Error::Path)?;
        segments.pop_if_empty();
        if !relative.is_empty() {
            for segment in relative.split('/') {
                if segment.is_empty() || matches!(segment, "." | "..") {
                    return Err(Error::Path);
                }
                segments.push(segment);
            }
        }
        if directory {
            segments.push("");
        }
        drop(segments);
        Ok(url)
    }

    async fn request(
        &self,
        method: Method,
        initial: Url,
        range: Option<&str>,
        propfind: bool,
    ) -> Result<Response, Error> {
        let mut url = initial;
        // Same origin, within the configured root only. Never forward DAV auth
        // to a CDN, downgrade HTTPS or persist a redirected URL.
        for _ in 0..5 {
            let mut request = self
                .client
                .request(method.clone(), url.clone())
                .header(header::ACCEPT_ENCODING, "identity");
            if let Some(auth) = &self.authorization {
                request = request.header(header::AUTHORIZATION, auth);
            }
            if let Some(range) = range {
                request = request.header(header::RANGE, range);
            }
            if propfind {
                request = request
                    .timeout(Duration::from_secs(30))
                    .header("Depth", "1")
                    .header(header::CONTENT_TYPE, "application/xml; charset=utf-8")
                    .body(PROPERTIES);
            }
            let response = request.send().await.map_err(|_| Error::Network)?;
            if matches!(response.status().as_u16(), 401 | 403) {
                return Err(Error::Unauthorized);
            }
            if response.status().is_redirection() {
                let location = response
                    .headers()
                    .get(header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or(Error::Redirect)?;
                reject_segments(location).map_err(|_| Error::Redirect)?;
                let next = url.join(location).map_err(|_| Error::Redirect)?;
                if next.origin() != self.root.origin()
                    || !next.path().starts_with(self.root.path())
                    || !next.username().is_empty()
                    || next.password().is_some()
                    || next.query().is_some()
                    || next.fragment().is_some()
                {
                    return Err(Error::Redirect);
                }
                url = next;
                continue;
            }
            return Ok(response);
        }
        Err(Error::Redirect)
    }

    pub async fn list(&self, relative: &str) -> Result<Vec<Entry>, Error> {
        let requested = self.url(relative, true)?;
        let mut response = self
            .request(
                Method::from_bytes(b"PROPFIND").unwrap(),
                requested.clone(),
                None,
                true,
            )
            .await?;
        if response.status().as_u16() != 207 {
            return Err(Error::Listing);
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_XML as u64)
        {
            return Err(Error::Listing);
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Network)? {
            if body.len() + chunk.len() > MAX_XML {
                return Err(Error::Listing);
            }
            body.extend_from_slice(&chunk);
        }
        parse_listing(
            &self.root,
            &requested,
            std::str::from_utf8(&body).map_err(|_| Error::Listing)?,
        )
    }

    pub async fn range(
        &self,
        relative: &str,
        start: u64,
        end: u64,
        total: Option<u64>,
    ) -> Result<Response, Error> {
        let response = self
            .request(
                Method::GET,
                self.url(relative, false)?,
                Some(&format!("bytes={start}-{end}")),
                false,
            )
            .await?;
        if response.status().as_u16() != 206
            || response
                .headers()
                .get(header::CONTENT_ENCODING)
                .is_some_and(|v| v != "identity")
        {
            return Err(Error::Range);
        }
        let value = response
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .ok_or(Error::Range)?;
        let (actual_start, actual_end, actual_total) = content_range(value)?;
        if actual_start != start
            || actual_end != end.min(actual_total - 1)
            || total.is_some_and(|n| n != actual_total)
            || response
                .content_length()
                .is_some_and(|n| n != actual_end - actual_start + 1)
        {
            return Err(Error::Range);
        }
        // Probe consumes its body at the call site, not here; this remains streaming.
        Ok(response)
    }

    pub async fn probe(&self, relative: &str) -> Result<u64, Error> {
        let mut response = self.range(relative, 0, 0, None).await?;
        let (_, _, size) = content_range(
            response
                .headers()
                .get(header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .ok_or(Error::Range)?,
        )?;
        let mut count = 0;
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Network)? {
            count += chunk.len();
            if count > 1 {
                return Err(Error::Range);
            }
        }
        if count != 1 {
            return Err(Error::Range);
        }
        Ok(size)
    }
}

fn content_range(value: &str) -> Result<(u64, u64, u64), Error> {
    let value = value.strip_prefix("bytes ").ok_or(Error::Range)?;
    let (interval, total) = value.split_once('/').ok_or(Error::Range)?;
    let (start, end) = interval.split_once('-').ok_or(Error::Range)?;
    let (start, end, total) = (
        start.parse::<u64>().map_err(|_| Error::Range)?,
        end.parse::<u64>().map_err(|_| Error::Range)?,
        total.parse::<u64>().map_err(|_| Error::Range)?,
    );
    if start > end || end >= total || total > i64::MAX as u64 {
        return Err(Error::Range);
    }
    Ok((start, end, total))
}

fn dav(node: roxmltree::Node<'_, '_>, name: &str) -> bool {
    node.has_tag_name(("DAV:", name))
}
fn child<'a>(node: roxmltree::Node<'a, 'a>, name: &str) -> Option<roxmltree::Node<'a, 'a>> {
    node.children().find(|n| dav(*n, name))
}
fn status_ok(value: &str) -> bool {
    value
        .split_whitespace()
        .nth(1)
        .is_some_and(|s| s.parse::<u16>().is_ok_and(|s| (200..300).contains(&s)))
}

pub fn parse_listing(root: &Url, requested: &Url, xml: &str) -> Result<Vec<Entry>, Error> {
    let document = roxmltree::Document::parse(xml).map_err(|_| Error::Listing)?;
    if !dav(document.root_element(), "multistatus") {
        return Err(Error::Listing);
    }
    let root_segments = decoded_segments(root)?;
    let requested_segments = decoded_segments(requested)?;
    let mut entries = std::collections::BTreeMap::new();
    let mut saw_self = false;
    for response in document
        .root_element()
        .children()
        .filter(|n| dav(*n, "response"))
    {
        let href = child(response, "href")
            .and_then(|n| n.text())
            .ok_or(Error::Listing)?;
        reject_segments(href).map_err(|_| Error::Listing)?;
        let url = requested.join(href).map_err(|_| Error::Listing)?;
        if url.origin() != root.origin()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(Error::Listing);
        }
        let segments = decoded_segments(&url)?;
        if !segments.starts_with(&requested_segments) || !segments.starts_with(&root_segments) {
            return Err(Error::Listing);
        }
        let is_self = segments == requested_segments;
        if !is_self && segments.len() != requested_segments.len() + 1 {
            return Err(Error::Listing);
        }
        if let Some(status) = child(response, "status") {
            if !status_ok(status.text().unwrap_or("")) {
                return Err(Error::Listing);
            }
        }
        let mut directory = None;
        let mut size = None;
        let mut modified = 0.0;
        let mut etag = None;
        for propstat in response.children().filter(|n| dav(*n, "propstat")) {
            if !child(propstat, "status")
                .and_then(|n| n.text())
                .is_some_and(status_ok)
            {
                continue;
            }
            let prop = child(propstat, "prop").ok_or(Error::Listing)?;
            if let Some(resource) = child(prop, "resourcetype") {
                directory = Some(resource.children().any(|n| dav(n, "collection")));
            }
            if let Some(value) = child(prop, "getcontentlength").and_then(|n| n.text()) {
                size = Some(value.trim().parse::<i64>().map_err(|_| Error::Listing)?);
            }
            if let Some(value) = child(prop, "getlastmodified").and_then(|n| n.text()) {
                modified = chrono::DateTime::parse_from_rfc2822(value)
                    .map(|d| d.timestamp() as f64)
                    .unwrap_or(0.0);
            }
            etag = child(prop, "getetag")
                .and_then(|n| n.text())
                .map(str::to_owned)
                .or(etag);
        }
        let directory = directory.ok_or(Error::Listing)?;
        if is_self {
            if !directory {
                return Err(Error::Listing);
            }
            saw_self = true;
            continue;
        }
        let size = if directory {
            0
        } else {
            size.filter(|n| *n >= 0).ok_or(Error::Listing)?
        };
        let relative_path = segments[root_segments.len()..].join("/");
        let entry = Entry {
            relative_path: relative_path.clone(),
            is_directory: directory,
            size,
            modified_at: modified,
            etag,
        };
        if entries.insert(relative_path, entry).is_some() {
            return Err(Error::Listing);
        }
        if entries.len() > 50000 {
            return Err(Error::Listing);
        }
    }
    if !saw_self {
        return Err(Error::Listing);
    }
    Ok(entries.into_values().collect())
}
