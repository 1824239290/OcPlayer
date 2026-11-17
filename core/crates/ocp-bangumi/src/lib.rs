//! Bangumi API models, episode partitioning and collection progress policy.

pub mod account;
pub mod auth_flow;
pub mod progress;
pub mod sync;

use ocp_http::HttpClient;
use reqwest::{
    header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION},
    Method,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(try_from = "i32", into = "i32")]
pub enum SubjectType {
    Book,
    Anime,
    Music,
    Game,
    Real,
}

impl TryFrom<i32> for SubjectType {
    type Error = String;
    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Book),
            2 => Ok(Self::Anime),
            3 => Ok(Self::Music),
            4 => Ok(Self::Game),
            6 => Ok(Self::Real),
            _ => Err(format!("unknown Bangumi subject type {value}")),
        }
    }
}

impl From<SubjectType> for i32 {
    fn from(value: SubjectType) -> Self {
        match value {
            SubjectType::Book => 1,
            SubjectType::Anime => 2,
            SubjectType::Music => 3,
            SubjectType::Game => 4,
            SubjectType::Real => 6,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CollectionType {
    Wish,
    Collect,
    Doing,
    OnHold,
    Dropped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Subject {
    pub id: i64,
    pub name: String,
    pub name_cn: Option<String>,
    #[serde(rename = "type")]
    pub subject_type: SubjectType,
    pub date: Option<String>,
    pub summary: Option<String>,
    pub images: Option<serde_json::Value>,
    pub rating: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Episode {
    pub id: i64,
    pub subject_id: i64,
    pub name: String,
    pub name_cn: Option<String>,
    pub sort: f64,
    #[serde(rename = "type")]
    pub episode_type: i32,
    pub duration: Option<String>,
    pub airdate: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EpisodePartition {
    pub main: Vec<Episode>,
    pub specials: Vec<Episode>,
    pub openings_endings: Vec<Episode>,
    pub trailers: Vec<Episode>,
}

pub fn partition_episodes(episodes: Vec<Episode>) -> EpisodePartition {
    let mut result = EpisodePartition {
        main: vec![],
        specials: vec![],
        openings_endings: vec![],
        trailers: vec![],
    };
    for episode in episodes {
        match episode.episode_type {
            0 => result.main.push(episode),
            1 | 2 => result.specials.push(episode),
            3 => result.openings_endings.push(episode),
            4 => result.trailers.push(episode),
            _ => result.specials.push(episode),
        }
    }
    result.main.sort_by(|a, b| a.sort.total_cmp(&b.sort));
    result
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CollectionProgress {
    pub subject_id: i64,
    pub watched_main: i32,
    pub total_main: i32,
    pub watched_special: i32,
    pub total_special: i32,
}

pub fn progress(
    episodes: &[Episode],
    watched_ids: &std::collections::HashSet<i64>,
) -> CollectionProgress {
    let partition = partition_episodes(episodes.to_vec());
    CollectionProgress {
        subject_id: episodes.first().map(|e| e.subject_id).unwrap_or_default(),
        watched_main: partition
            .main
            .iter()
            .filter(|e| watched_ids.contains(&e.id))
            .count() as i32,
        total_main: partition.main.len() as i32,
        watched_special: partition
            .specials
            .iter()
            .filter(|e| watched_ids.contains(&e.id))
            .count() as i32,
        total_special: partition.specials.len() as i32,
    }
}

#[derive(Debug, Error)]
pub enum BangumiError {
    #[error("HTTP: {0}")]
    Http(#[from] ocp_http::HttpError),
    #[error("invalid URL: {0}")]
    Url(#[from] url::ParseError),
    #[error("request failed: {0}")]
    Request(String),
    #[error("API returned status {0}")]
    Status(u16),
    #[error("invalid response: {0}")]
    Decode(#[from] serde_json::Error),
}

pub fn api_url(base: &str, path: &str) -> Result<Url, BangumiError> {
    let mut url = Url::parse(base)?;
    url.set_path(&format!(
        "{}/{}",
        url.path().trim_end_matches('/'),
        path.trim_start_matches('/')
    ));
    Ok(url)
}

/// Async Bangumi v0/p1 client. Credentials remain owned by the platform layer.
pub struct BangumiClient {
    base_url: Url,
    access_token: Option<String>,
    http: HttpClient<reqwest::Client>,
}

impl BangumiClient {
    pub fn new(base_url: &str, access_token: Option<String>) -> Result<Self, BangumiError> {
        Self::with_http(base_url, access_token, HttpClient::new())
    }

    pub fn with_http(
        base_url: &str,
        access_token: Option<String>,
        http: HttpClient<reqwest::Client>,
    ) -> Result<Self, BangumiError> {
        let mut base_url = Url::parse(base_url)?;
        if !matches!(base_url.scheme(), "http" | "https") {
            return Err(BangumiError::Request("scheme must be http or https".into()));
        }
        if !base_url.path().ends_with('/') {
            base_url.set_path(&format!("{}/", base_url.path()));
        }
        Ok(Self {
            base_url,
            access_token,
            http,
        })
    }

    fn headers(&self, authenticated: bool) -> Result<HeaderMap, BangumiError> {
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        headers.insert(
            reqwest::header::USER_AGENT,
            HeaderValue::from_static("OcPlayer/0.1 (BangumiKit)"),
        );
        if authenticated
            || self
                .access_token
                .as_deref()
                .is_some_and(|token| !token.is_empty())
        {
            let token = self
                .access_token
                .as_deref()
                .filter(|token| !token.is_empty())
                .ok_or_else(|| BangumiError::Request("Bangumi login is required".into()))?;
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|error| BangumiError::Request(error.to_string()))?,
            );
        }
        Ok(headers)
    }

    async fn get(
        &self,
        path: &str,
        query: &[(&str, String)],
        authenticated: bool,
    ) -> Result<serde_json::Value, BangumiError> {
        let mut url = self.base_url.join(path.trim_start_matches('/'))?;
        if !query.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(query.iter().map(|(key, value)| (*key, value.as_str())));
        }
        Ok(self
            .http
            .json(Method::GET, url, self.headers(authenticated)?, None)
            .await?)
    }

    /// Complete response projection for Apple credential lifecycle and p1 APIs.
    /// URL and per-request headers are supplied by the host after mirror selection.
    pub async fn request(
        &self,
        url: &str,
        method: &str,
        extra_headers: &std::collections::HashMap<String, String>,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, BangumiError> {
        let url = Url::parse(url)?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(BangumiError::Request("scheme must be http or https".into()));
        }
        let method = Method::from_bytes(method.as_bytes())
            .map_err(|error| BangumiError::Request(error.to_string()))?;
        let mut headers = self.headers(false)?;
        headers.insert(
            reqwest::header::USER_AGENT,
            HeaderValue::from_static("OcPlayer/0.1 (BangumiKit)"),
        );
        if let Some(token) = self
            .access_token
            .as_deref()
            .filter(|token| !token.is_empty())
        {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|error| BangumiError::Request(error.to_string()))?,
            );
        }
        for (key, value) in extra_headers {
            let key = reqwest::header::HeaderName::from_bytes(key.as_bytes())
                .map_err(|error| BangumiError::Request(error.to_string()))?;
            let value = HeaderValue::from_str(value)
                .map_err(|error| BangumiError::Request(error.to_string()))?;
            headers.insert(key, value);
        }
        let read_only_search =
            method == Method::POST && url.path().ends_with("/p1/search/subjects");
        let response = self
            .http
            .exchange_preserving_status(
                method,
                url,
                headers,
                body.map(|body| (body.to_string().into_bytes(), "application/json")),
                read_only_search,
            )
            .await?;
        let status = response.status().as_u16();
        let headers: std::collections::HashMap<_, _> = response
            .headers()
            .iter()
            .filter_map(|(key, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (key.to_string(), value.to_owned()))
            })
            .collect();
        let bytes = response
            .bytes()
            .await
            .map_err(|error| ocp_http::HttpError::Decode(error.without_url()))?;
        let body = String::from_utf8(bytes.to_vec())
            .map_err(|error| BangumiError::Request(format!("response is not UTF-8: {error}")))?;
        Ok(serde_json::json!({ "status": status, "headers": headers, "body": body }))
    }

    pub async fn subject(&self, id: i64) -> Result<serde_json::Value, BangumiError> {
        if id <= 0 {
            return Err(BangumiError::Request("subjectId must be positive".into()));
        }
        self.get(&format!("p1/subjects/{id}"), &[], false).await
    }

    pub async fn search_subjects(
        &self,
        keyword: &str,
        subject_type: Option<i32>,
        limit: u32,
        offset: u32,
    ) -> Result<serde_json::Value, BangumiError> {
        if keyword.trim().is_empty() || limit == 0 || limit > 100 || offset > i32::MAX as u32 {
            return Err(BangumiError::Request("invalid search arguments".into()));
        }
        let mut body = serde_json::json!({"keyword": keyword, "sort": "match"});
        if let Some(kind) = subject_type.filter(|kind| *kind != 0) {
            SubjectType::try_from(kind).map_err(BangumiError::Request)?;
            body["filter"] = serde_json::json!({"type": [kind]});
        }
        let mut url = self.base_url.join("p1/search/subjects")?;
        url.query_pairs_mut()
            .append_pair("limit", &limit.to_string())
            .append_pair("offset", &offset.to_string());
        self.http
            .json_idempotent(Method::POST, url, self.headers(false)?, Some(body))
            .await
            .map_err(Into::into)
    }

    pub async fn subject_collection(
        &self,
        subject_id: i64,
        username: &str,
    ) -> Result<serde_json::Value, BangumiError> {
        if subject_id <= 0 || username.is_empty() || username == "-" {
            return Err(BangumiError::Request(
                "subjectId and account username are required".into(),
            ));
        }
        let mut url = self.base_url.join("v0/users/")?;
        url.path_segments_mut()
            .map_err(|_| BangumiError::Request("invalid base URL".into()))?
            .pop_if_empty()
            .push(username)
            .push("collections")
            .push(&subject_id.to_string());
        self.http
            .json(Method::GET, url, self.headers(true)?, None)
            .await
            .map_err(Into::into)
    }

    pub async fn update_subject_collection(
        &self,
        subject_id: i64,
        body: serde_json::Value,
    ) -> Result<(), BangumiError> {
        if subject_id <= 0 || !body.is_object() {
            return Err(BangumiError::Request(
                "invalid subject collection arguments".into(),
            ));
        }
        let url = self
            .base_url
            .join(&format!("v0/users/-/collections/{subject_id}"))?;
        self.http
            .bytes(Method::POST, url, self.headers(true)?, Some(body))
            .await?;
        Ok(())
    }

    pub async fn episodes(
        &self,
        subject_id: i64,
        limit: u32,
        offset: u32,
    ) -> Result<serde_json::Value, BangumiError> {
        if subject_id <= 0 || limit == 0 || limit > 100 || offset > i32::MAX as u32 {
            return Err(BangumiError::Request(
                "invalid episode page arguments".into(),
            ));
        }
        self.get(
            &format!("p1/subjects/{subject_id}/episodes"),
            &[("limit", limit.to_string()), ("offset", offset.to_string())],
            false,
        )
        .await
    }

    pub async fn calendar(&self) -> Result<serde_json::Value, BangumiError> {
        self.get("calendar", &[], false).await
    }

    pub async fn collections(
        &self,
        collection_type: Option<i32>,
        subject_type: Option<i32>,
        since: i64,
        limit: u32,
        offset: u32,
    ) -> Result<serde_json::Value, BangumiError> {
        if since < 0 || limit == 0 || limit > 100 || offset > i32::MAX as u32 {
            return Err(BangumiError::Request(
                "invalid collection page arguments".into(),
            ));
        }
        let mut query = vec![
            ("since", since.to_string()),
            ("limit", limit.to_string()),
            ("offset", offset.to_string()),
        ];
        if let Some(value) = collection_type {
            query.push(("type", value.to_string()));
        }
        if let Some(value) = subject_type {
            query.push(("subjectType", value.to_string()));
        }
        self.get("p1/collections/subjects", &query, true).await
    }

    pub async fn update_episode_collection(
        &self,
        episode_id: i64,
        collection_type: i32,
        batch: bool,
    ) -> Result<(), BangumiError> {
        if episode_id <= 0 || !(0..=3).contains(&collection_type) {
            return Err(BangumiError::Request(
                "invalid episode collection arguments".into(),
            ));
        }
        let mut body = serde_json::json!({ "type": collection_type });
        if batch {
            body["batch"] = serde_json::Value::Bool(true);
        }
        let url = self
            .base_url
            .join(&format!("p1/collections/episodes/{episode_id}"))?;
        self.http
            .bytes(Method::PATCH, url, self.headers(true)?, Some(body))
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn ep(id: i64, kind: i32, sort: f64) -> Episode {
        Episode {
            id,
            subject_id: 10,
            name: String::new(),
            name_cn: None,
            sort,
            episode_type: kind,
            duration: None,
            airdate: None,
        }
    }
    #[test]
    fn partitions_and_counts() {
        let episodes = vec![ep(1, 0, 2.0), ep(2, 0, 1.0), ep(3, 1, 1.0)];
        let partition = partition_episodes(episodes.clone());
        assert_eq!(partition.main[0].id, 2);
        let watched = [2].into_iter().collect();
        assert_eq!(progress(&episodes, &watched).watched_main, 1);
    }

    #[test]
    fn maps_bangumi_numeric_subject_type_wire_values() {
        let subject: Subject = serde_json::from_value(serde_json::json!({
            "id": 12,
            "name": "Show",
            "type": 2
        }))
        .unwrap();
        assert_eq!(subject.subject_type, SubjectType::Anime);
        assert_eq!(serde_json::to_value(subject).unwrap()["type"], 2);
    }

    #[test]
    fn client_preserves_api_base_path() {
        let client = BangumiClient::new("https://example.test/bangumi", None).unwrap();
        assert_eq!(
            client.base_url.join("v0/subjects/1").unwrap().as_str(),
            "https://example.test/bangumi/v0/subjects/1"
        );
    }
}
