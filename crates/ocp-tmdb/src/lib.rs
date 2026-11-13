//! TMDB matching and season/episode derivation.

pub mod matcher;

use regex::Regex;
use reqwest::{
    header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION},
    Method, Url,
};
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MediaType {
    Movie,
    Tv,
    Collection,
}

impl Default for MediaType {
    fn default() -> Self {
        Self::Movie
    }
}

#[derive(Debug, Error)]
pub enum TmdbError {
    #[error("TMDB API key is not configured")]
    NotConfigured,
    #[error("invalid TMDB endpoint: {0}")]
    InvalidEndpoint(String),
    #[error("HTTP: {0}")]
    Http(#[from] ocp_http::HttpError),
    #[error("TMDB response: {0}")]
    Response(String),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub struct TmdbSearchResult {
    pub id: i64,
    #[serde(default)]
    pub media_type: MediaType,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub name: Option<String>,
    pub original_name: Option<String>,
    pub release_date: Option<String>,
    pub first_air_date: Option<String>,
    pub popularity: Option<f64>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub struct TmdbSeason {
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    #[serde(default)]
    pub episodes: Vec<TmdbEpisode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub struct TmdbEpisode {
    pub id: i64,
    pub episode_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub still_path: Option<String>,
    pub air_date: Option<String>,
    pub runtime: Option<i32>,
    pub vote_average: Option<f64>,
}

pub struct TmdbClient<T = reqwest::Client> {
    api_key: String,
    api_base: String,
    http: ocp_http::HttpClient<T>,
}

impl TmdbClient<reqwest::Client> {
    pub fn new(api_key: impl Into<String>) -> Self {
        Self::with_endpoint(api_key, "https://api.themoviedb.org/3")
    }
    pub fn with_endpoint(api_key: impl Into<String>, api_base: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            api_base: api_base.into(),
            http: ocp_http::HttpClient::new(),
        }
    }
}

impl<T: ocp_http::HttpTransport> TmdbClient<T> {
    pub fn with_http(
        api_key: impl Into<String>,
        api_base: impl Into<String>,
        http: ocp_http::HttpClient<T>,
    ) -> Self {
        Self {
            api_key: api_key.into(),
            api_base: api_base.into(),
            http,
        }
    }

    fn endpoint(
        &self,
        path: &str,
        language: &str,
        query: &[(&str, String)],
    ) -> Result<Url, TmdbError> {
        if self.api_key.trim().is_empty() {
            return Err(TmdbError::NotConfigured);
        }
        let mut base =
            Url::parse(&self.api_base).map_err(|e| TmdbError::InvalidEndpoint(e.to_string()))?;
        if !matches!(base.scheme(), "http" | "https") {
            return Err(TmdbError::InvalidEndpoint(
                "scheme must be http or https".into(),
            ));
        }
        let prefix = base.path().trim_end_matches('/');
        base.set_path(&format!("{prefix}/{}", path.trim_start_matches('/')));
        {
            let mut pairs = base.query_pairs_mut();
            if self.api_key.starts_with("eyJ") {
                pairs.append_pair("language", language);
            } else {
                pairs.append_pair("api_key", &self.api_key);
                pairs.append_pair("language", language);
            }
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }
        Ok(base)
    }

    async fn get<R: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        language: &str,
        query: &[(&str, String)],
    ) -> Result<R, TmdbError> {
        let url = self.endpoint(path, language, query)?;
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        if self.api_key.starts_with("eyJ") {
            let value = HeaderValue::from_str(&format!("Bearer {}", self.api_key))
                .map_err(|e| TmdbError::InvalidEndpoint(e.to_string()))?;
            headers.insert(AUTHORIZATION, value);
        }
        self.http
            .json(Method::GET, url, headers, None)
            .await
            .map_err(Into::into)
    }

    pub async fn search(
        &self,
        query: &str,
        media_type: MediaType,
        year: Option<i32>,
        language: &str,
    ) -> Result<Vec<TmdbSearchResult>, TmdbError> {
        let mut params = vec![("query", query.to_owned())];
        if let Some(year) = year {
            match media_type {
                MediaType::Movie => params.push(("year", year.to_string())),
                MediaType::Tv => params.push(("first_air_date_year", year.to_string())),
                MediaType::Collection => {}
            }
        }
        let endpoint = match media_type {
            MediaType::Movie => "search/movie",
            MediaType::Tv => "search/tv",
            MediaType::Collection => "search/collection",
        };
        let raw: serde_json::Value = self.get(endpoint, language, &params).await?;
        let raw = object(&raw)?;
        Ok(entries(raw, "results")
            .filter_map(|entry| {
                Some(TmdbSearchResult {
                    id: entry.get("id")?.as_i64()?,
                    media_type,
                    title: text(entry, "title"),
                    original_title: text(entry, "original_title"),
                    name: text(entry, "name"),
                    original_name: text(entry, "original_name"),
                    release_date: text(entry, "release_date"),
                    first_air_date: text(entry, "first_air_date"),
                    popularity: number(entry, "popularity"),
                    overview: text(entry, "overview"),
                    poster_path: text(entry, "poster_path"),
                })
            })
            .collect())
    }

    pub async fn entity(
        &self,
        id: i64,
        media_type: MediaType,
        language: &str,
    ) -> Result<TmdbEntity, TmdbError> {
        let path = match media_type {
            MediaType::Movie => format!("movie/{id}"),
            MediaType::Tv => format!("tv/{id}"),
            MediaType::Collection => format!("collection/{id}"),
        };
        let query = [(
            "append_to_response",
            "credits,images,external_ids,content_ratings".into(),
        )];
        let raw: serde_json::Value = self.get(&path, language, &query).await?;
        let mut primary = decode_entity(&raw, media_type)?;
        let title = if media_type == MediaType::Movie {
            &primary.title
        } else {
            &primary.name
        };
        if language != "en-US" && (title.is_none() || primary.overview.is_none()) {
            // Optional translation failure must not discard usable primary metadata.
            // Cancellation of the enclosing command still drops this entire future.
            if let Ok(raw) = self.get::<serde_json::Value>(&path, "en-US", &query).await {
                if let Ok(other) = decode_entity(&raw, media_type) {
                    primary.title = primary.title.or(other.title);
                    primary.name = primary.name.or(other.name);
                    primary.overview = primary.overview.or(other.overview);
                    primary.poster_path = primary.poster_path.or(other.poster_path);
                    primary.backdrop_path = primary.backdrop_path.or(other.backdrop_path);
                    primary.content_rating = primary.content_rating.or(other.content_rating);
                }
            }
        }
        Ok(primary)
    }

    pub async fn season(
        &self,
        tv_id: i64,
        season_number: i32,
        language: &str,
    ) -> Result<TmdbSeason, TmdbError> {
        if season_number < 0 {
            return Err(TmdbError::Response(
                "season number must be non-negative".into(),
            ));
        }
        let raw: serde_json::Value = self
            .get(&format!("tv/{tv_id}/season/{season_number}"), language, &[])
            .await?;
        let raw = object(&raw)?;
        Ok(TmdbSeason {
            season_number: integer(raw, "season_number").unwrap_or(season_number),
            name: text(raw, "name"),
            overview: text(raw, "overview"),
            poster_path: text(raw, "poster_path"),
            episodes: entries(raw, "episodes")
                .filter_map(|entry| {
                    Some(TmdbEpisode {
                        id: entry
                            .get("id")
                            .and_then(serde_json::Value::as_i64)
                            .unwrap_or_default(),
                        episode_number: integer(entry, "episode_number")?,
                        name: text(entry, "name"),
                        overview: text(entry, "overview"),
                        still_path: text(entry, "still_path"),
                        air_date: text(entry, "air_date"),
                        runtime: integer(entry, "runtime"),
                        vote_average: number(entry, "vote_average"),
                    })
                })
                .collect(),
        })
    }
}

type Object = serde_json::Map<String, serde_json::Value>;
fn object(raw: &serde_json::Value) -> Result<&Object, TmdbError> {
    raw.as_object()
        .ok_or_else(|| TmdbError::Response("response must be a JSON object".into()))
}
fn text(raw: &Object, key: &str) -> Option<String> {
    raw.get(key)?
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}
fn number(raw: &Object, key: &str) -> Option<f64> {
    raw.get(key)?.as_f64()
}
fn integer(raw: &Object, key: &str) -> Option<i32> {
    let number = raw.get(key)?.as_i64()?;
    i32::try_from(number).ok()
}
fn entries<'a>(raw: &'a Object, key: &str) -> impl Iterator<Item = &'a Object> {
    raw.get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
}
fn decode_entity(raw: &serde_json::Value, media_type: MediaType) -> Result<TmdbEntity, TmdbError> {
    let raw = object(raw)?;
    let content_rating = raw
        .get("content_ratings")
        .and_then(serde_json::Value::as_object)
        .and_then(|ratings| {
            let ratings: Vec<_> = entries(ratings, "results").collect();
            ratings
                .iter()
                .find(|rating| text(rating, "iso_3166_1").as_deref() == Some("US"))
                .or_else(|| ratings.first())
                .and_then(|rating| text(rating, "rating"))
        });
    Ok(TmdbEntity {
        id: raw
            .get("id")
            .and_then(serde_json::Value::as_i64)
            .ok_or_else(|| TmdbError::Response("response is missing id".into()))?,
        media_type,
        title: text(raw, "title"),
        original_title: text(raw, "original_title"),
        name: text(raw, "name"),
        original_name: text(raw, "original_name"),
        release_date: text(raw, "release_date"),
        first_air_date: text(raw, "first_air_date"),
        popularity: number(raw, "popularity"),
        vote_average: number(raw, "vote_average"),
        overview: text(raw, "overview"),
        poster_path: text(raw, "poster_path"),
        backdrop_path: text(raw, "backdrop_path"),
        genres: entries(raw, "genres")
            .filter_map(|genre| text(genre, "name"))
            .collect(),
        cast: raw
            .get("credits")
            .and_then(serde_json::Value::as_object)
            .map(|credits| {
                entries(credits, "cast")
                    .take(20)
                    .filter_map(|entry| {
                        Some(TmdbCastMember {
                            id: entry.get("id")?.as_i64()?,
                            name: text(entry, "name")?,
                            character: text(entry, "character"),
                            profile_path: text(entry, "profile_path"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
        seasons: entries(raw, "seasons")
            .filter_map(|entry| {
                Some(TmdbSeasonSummary {
                    season_number: integer(entry, "season_number")?,
                    name: text(entry, "name"),
                    overview: text(entry, "overview"),
                    poster_path: text(entry, "poster_path"),
                    episode_count: integer(entry, "episode_count"),
                })
            })
            .collect(),
        original_language: text(raw, "original_language"),
        imdb_id: raw
            .get("external_ids")
            .and_then(serde_json::Value::as_object)
            .and_then(|ids| text(ids, "imdb_id")),
        content_rating,
        collection_id: raw
            .get("belongs_to_collection")
            .and_then(|value| value.get("id"))
            .and_then(serde_json::Value::as_i64),
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TmdbEntity {
    pub id: i64,
    pub media_type: MediaType,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub name: Option<String>,
    pub original_name: Option<String>,
    pub release_date: Option<String>,
    pub first_air_date: Option<String>,
    pub popularity: Option<f64>,
    pub vote_average: Option<f64>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub cast: Vec<TmdbCastMember>,
    #[serde(default)]
    pub seasons: Vec<TmdbSeasonSummary>,
    pub original_language: Option<String>,
    pub imdb_id: Option<String>,
    pub content_rating: Option<String>,
    pub collection_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TmdbCastMember {
    pub id: i64,
    pub name: String,
    pub character: Option<String>,
    pub profile_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TmdbSeasonSummary {
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub episode_count: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TmdbMatch {
    pub id: i64,
    pub media_type: MediaType,
    pub score: i32,
    pub matched_title: String,
    pub year_delta: Option<i32>,
}

pub fn normalize_title(value: &str) -> String {
    let mut normalized: String = value
        .nfkc()
        .flat_map(char::to_lowercase)
        .filter(|c| c.is_alphanumeric())
        .collect();
    for suffix in [
        "season2", "season3", "season4", "season5", "season6", "season7", "season8", "season9",
    ] {
        if normalized.ends_with(suffix) {
            normalized.truncate(normalized.len() - suffix.len());
            break;
        }
    }
    for suffix in [
        "第一季",
        "第二季",
        "第三季",
        "第四季",
        "第五季",
        "第六季",
        "第七季",
        "第八季",
        "第九季",
    ] {
        if normalized.ends_with(suffix) {
            normalized.truncate(normalized.len() - suffix.len());
            break;
        }
    }
    normalized
}

pub fn extract_year(value: &str) -> Option<i32> {
    Regex::new(r"(?P<year>19\d{2}|20\d{2})")
        .ok()?
        .captures(value)?
        .name("year")?
        .as_str()
        .parse()
        .ok()
}

pub fn score_title(query: &str, candidate: &TmdbEntity) -> i32 {
    let query = normalize_title(query);
    if query.is_empty() {
        return 0;
    }
    let mut best = 0;
    for title in [
        candidate.title.as_deref(),
        candidate.original_title.as_deref(),
        candidate.name.as_deref(),
        candidate.original_name.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        let title = normalize_title(title);
        if title == query {
            best = best.max(1000);
        } else if !title.is_empty() && (title.contains(&query) || query.contains(&title)) {
            best = best.max(600);
        } else {
            best = best.max(overlap_score(&query, &title));
        }
    }
    best
}

pub fn match_candidates(
    query: &str,
    year: Option<i32>,
    candidates: &[TmdbEntity],
) -> Option<TmdbMatch> {
    candidates
        .iter()
        .filter_map(|candidate| {
            let score = score_title(query, candidate);
            let exact = score == 1000;
            let matched_title = [
                candidate.title.as_deref(),
                candidate.name.as_deref(),
                candidate.original_title.as_deref(),
                candidate.original_name.as_deref(),
            ]
            .into_iter()
            .flatten()
            .find(|title| normalize_title(title) == normalize_title(query))
            .or_else(|| candidate.title.as_deref().or(candidate.name.as_deref()))
            .unwrap_or_default()
            .to_owned();
            let candidate_year = candidate
                .release_date
                .as_deref()
                .or(candidate.first_air_date.as_deref())
                .and_then(extract_year);
            let query_year = year.or_else(|| extract_parenthesized_year(query));
            let year_delta = query_year.zip(candidate_year).map(|(a, b)| (a - b).abs());
            let score = match (exact, year_delta) {
                (true, Some(0)) => 950,
                (true, Some(1)) => 800,
                (true, Some(_)) => 400,
                (true, None) => 700,
                (false, Some(0)) => 600,
                (false, Some(1)) => 500,
                (false, Some(_)) => 100,
                (false, None) => (score / 10).min(300),
            };
            (score >= 500).then_some(TmdbMatch {
                id: candidate.id,
                media_type: candidate.media_type,
                score,
                matched_title,
                year_delta,
            })
        })
        .max_by_key(|candidate| candidate.score)
}

fn extract_parenthesized_year(value: &str) -> Option<i32> {
    static YEAR: OnceLock<Regex> = OnceLock::new();
    YEAR.get_or_init(|| Regex::new(r"[（(](19\d{2}|20\d{2})[)）]").expect("valid year regex"))
        .captures(value)?
        .get(1)?
        .as_str()
        .parse()
        .ok()
}

pub fn image_url(base: &str, path: Option<&str>, size: &str) -> Option<String> {
    path.filter(|path| !path.is_empty())
        .map(|path| format!("{}/{}{}", base.trim_end_matches('/'), size, path))
}

fn overlap_score(a: &str, b: &str) -> i32 {
    if a.is_empty() || b.is_empty() {
        return 0;
    }
    let common = a.chars().filter(|character| b.contains(*character)).count();
    ((common * 500) / a.chars().count().max(b.chars().count())) as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entity(title: &str, date: &str) -> TmdbEntity {
        TmdbEntity {
            id: 1,
            media_type: MediaType::Tv,
            title: None,
            original_title: None,
            name: Some(title.into()),
            original_name: None,
            release_date: None,
            first_air_date: Some(date.into()),
            popularity: Some(5.0),
            vote_average: None,
            overview: None,
            poster_path: None,
            backdrop_path: None,
            genres: vec![],
            cast: vec![],
            seasons: vec![],
            original_language: None,
            imdb_id: None,
            content_rating: None,
            collection_id: None,
        }
    }
    #[test]
    fn normalizes_and_matches() {
        let candidate = entity("Frieren: Beyond Journey's End", "2023-09-29");
        let result =
            match_candidates("Frieren Beyond Journey's End", Some(2023), &[candidate]).unwrap();
        assert_eq!(result.score, 950);
    }
    #[test]
    fn requires_year_and_exactness_for_automatic_confidence() {
        let exact_wrong_year = entity("Frieren: Beyond Journey's End", "2021-09-29");
        assert!(match_candidates(
            "Frieren Beyond Journey's End",
            Some(2023),
            &[exact_wrong_year]
        )
        .is_none());

        let exact_unknown_year = entity("Frieren: Beyond Journey's End", "");
        let match_result =
            match_candidates("Frieren Beyond Journey's End", None, &[exact_unknown_year]).unwrap();
        assert_eq!(match_result.score, 700);
    }
    #[test]
    fn builds_image_url() {
        assert_eq!(
            image_url("https://image.tmdb.org/t/p", Some("/a.jpg"), "w500").unwrap(),
            "https://image.tmdb.org/t/p/w500/a.jpg"
        );
    }
}
