//! Jellyfin / Emby protocol models, URL derivation and service operations.

use ocp_http::{ErrorCategory, HttpClient, HttpError};
use reqwest::{
    header::{HeaderMap, HeaderValue},
    Method, Url,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub mod endpoint;

pub const MEDIA_LIST_FIELDS: &str =
    "Overview,Genres,CommunityRating,OfficialRating,PrimaryImageAspectRatio,ProviderIds";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfo {
    #[serde(alias = "Id")]
    pub id: Option<String>,
    #[serde(alias = "ServerName")]
    pub server_name: Option<String>,
    #[serde(alias = "ProductName")]
    pub product_name: Option<String>,
    #[serde(alias = "Version")]
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LoginResult {
    pub token: String,
    pub user_id: String,
    pub user_name: Option<String>,
    pub primary_image_tag: Option<String>,
}

impl LoginResult {
    /// The native clients only require token and user ID. Server/plugin-specific
    /// optional field types must not prevent an otherwise valid login.
    fn parse(value: serde_json::Value) -> Result<Self, JellyfinError> {
        let string =
            |value: &serde_json::Value| value.as_str().filter(|s| !s.is_empty()).map(str::to_owned);
        Ok(Self {
            token: string(&value["AccessToken"]).ok_or(JellyfinError::Unauthorized)?,
            user_id: string(&value["User"]["Id"]).ok_or(JellyfinError::Unauthorized)?,
            user_name: value["User"]["Name"].as_str().map(str::to_owned),
            primary_image_tag: string(&value["User"]["PrimaryImageTag"]),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QuickConnectState {
    pub secret: Option<String>,
    pub code: Option<String>,
    pub authenticated: bool,
}

impl QuickConnectState {
    fn parse(value: serde_json::Value) -> Self {
        Self {
            secret: value["Secret"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            code: value["Code"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            authenticated: value["Authenticated"].as_bool() == Some(true),
        }
    }
}

struct PlaybackReport<'a> {
    item_id: &'a str,
    media_source_id: Option<&'a str>,
    play_session_id: Option<&'a str>,
    position_seconds: f64,
    play_method: &'a str,
    paused: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ServerKind {
    Jellyfin,
    Emby,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ServerProfile {
    pub id: String,
    pub kind: ServerKind,
    #[serde(alias = "baseURL")]
    pub base_url: String,
    #[serde(alias = "userID")]
    pub user_id: Option<String>,
    pub token: Option<String>,
    #[serde(default)]
    pub authorization_header: Option<String>,
    #[serde(default)]
    pub user_agent: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    #[serde(alias = "Id")]
    pub id: String,
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(rename = "Type", alias = "type")]
    pub kind: String,
    #[serde(alias = "Overview")]
    pub overview: Option<String>,
    #[serde(alias = "OriginalTitle")]
    pub original_title: Option<String>,
    #[serde(alias = "ProductionYear")]
    pub production_year: Option<i32>,
    #[serde(alias = "Genres", default)]
    pub genres: Vec<String>,
    #[serde(alias = "CommunityRating")]
    pub community_rating: Option<f64>,
    #[serde(alias = "OfficialRating")]
    pub official_rating: Option<String>,
    #[serde(alias = "SeriesId")]
    pub series_id: Option<String>,
    #[serde(alias = "SeriesName")]
    pub series_name: Option<String>,
    #[serde(alias = "SeasonId")]
    pub season_id: Option<String>,
    #[serde(alias = "SeasonName")]
    pub season_name: Option<String>,
    #[serde(alias = "ParentIndexNumber")]
    pub season_number: Option<i32>,
    #[serde(alias = "IndexNumber")]
    pub index_number: Option<i32>,
    #[serde(alias = "RunTimeTicks")]
    pub run_time_ticks: Option<i64>,
    #[serde(alias = "ChildCount")]
    pub child_count: Option<i32>,
    #[serde(alias = "ImageTags", default)]
    pub image_tags: serde_json::Value,
    #[serde(alias = "BackdropImageTags", default)]
    pub backdrop_image_tags: serde_json::Value,
    #[serde(alias = "ParentThumbItemId")]
    pub parent_thumb_item_id: Option<String>,
    #[serde(alias = "ParentThumbImageTag")]
    pub parent_thumb_image_tag: Option<String>,
    #[serde(alias = "ParentBackdropItemId")]
    pub parent_backdrop_item_id: Option<String>,
    #[serde(alias = "ParentBackdropImageTag")]
    pub parent_backdrop_image_tag: Option<String>,
    #[serde(alias = "PrimaryImageAspectRatio")]
    pub primary_image_aspect_ratio: Option<f64>,
    #[serde(alias = "People", default)]
    pub cast: Vec<Person>,
    #[serde(alias = "ProviderIds")]
    #[serde(default)]
    pub provider_ids: serde_json::Value,
    #[serde(default, alias = "UserData")]
    user_data: Option<WirePlayState>,
    #[serde(default, rename = "playState")]
    pub play_state: PlayState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    #[serde(alias = "Id")]
    pub id: String,
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(alias = "Role")]
    pub role: Option<String>,
    #[serde(alias = "Type")]
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "PascalCase")]
struct WirePlayState {
    #[serde(default)]
    playback_position_ticks: i64,
    #[serde(default)]
    played: bool,
    #[serde(default)]
    played_percentage: Option<f64>,
    #[serde(default)]
    unplayed_item_count: Option<i32>,
    last_played_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PlayState {
    pub position_seconds: f64,
    pub played: bool,
    pub percentage: f64,
    pub unplayed_count: Option<i32>,
    pub last_played_at: Option<String>,
}

impl MediaItem {
    pub fn normalized_play_state(&self) -> PlayState {
        self.user_data
            .as_ref()
            .map_or_else(PlayState::default, |data| PlayState {
                position_seconds: data.playback_position_ticks as f64 / 10_000_000.0,
                played: data.played,
                percentage: data.played_percentage.unwrap_or_default() / 100.0,
                unplayed_count: data.unplayed_item_count,
                last_played_at: data.last_played_date.clone(),
            })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MediaItemsPage {
    pub items: Vec<MediaItem>,
    pub start_index: i32,
    pub total_record_count: Option<i32>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MediaLibrary {
    #[serde(alias = "Id")]
    pub id: String,
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(alias = "CollectionType")]
    pub collection_type: Option<String>,
    #[serde(default, alias = "ImageTags")]
    pub image_tags: serde_json::Value,
}

impl Serialize for MediaLibrary {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut value = serializer.serialize_struct("MediaLibrary", 4)?;
        value.serialize_field("id", &self.id)?;
        value.serialize_field("name", &self.name)?;
        value.serialize_field("collectionType", &self.collection_type)?;
        value.serialize_field("primaryImageTag", &image_tag(&self.image_tags, "Primary"))?;
        value.end()
    }
}

impl Serialize for MediaItem {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut value = serializer.serialize_struct("MediaItem", 30)?;
        value.serialize_field("id", &self.id)?;
        value.serialize_field("name", &self.name)?;
        value.serialize_field("originalTitle", &self.original_title)?;
        value.serialize_field("kind", &swift_kind(&self.kind))?;
        value.serialize_field("overview", &self.overview)?;
        value.serialize_field("year", &self.production_year)?;
        value.serialize_field(
            "runtimeSeconds",
            &self.run_time_ticks.map(|ticks| ticks as f64 / 10_000_000.0),
        )?;
        value.serialize_field("genres", &self.genres)?;
        value.serialize_field("communityRating", &self.community_rating)?;
        value.serialize_field("officialRating", &self.official_rating)?;
        value.serialize_field("seriesID", &self.series_id)?;
        value.serialize_field("seriesName", &self.series_name)?;
        value.serialize_field("seasonID", &self.season_id)?;
        value.serialize_field("seasonName", &self.season_name)?;
        value.serialize_field("seasonNumber", &self.season_number)?;
        value.serialize_field("episodeNumber", &self.index_number)?;
        let play_state = if self.user_data.is_some() {
            self.normalized_play_state()
        } else {
            self.play_state.clone()
        };
        value.serialize_field("playState", &play_state)?;
        value.serialize_field("cast", &self.cast)?;
        value.serialize_field("childCount", &self.child_count)?;
        value.serialize_field("primaryImageTag", &image_tag(&self.image_tags, "Primary"))?;
        value.serialize_field("primaryImageAspectRatio", &self.primary_image_aspect_ratio)?;
        value.serialize_field("thumbImageTag", &image_tag(&self.image_tags, "Thumb"))?;
        value.serialize_field("backdropImageTag", &image_tag(&self.image_tags, "Backdrop"))?;
        value.serialize_field("parentThumbItemID", &self.parent_thumb_item_id)?;
        value.serialize_field("parentThumbImageTag", &self.parent_thumb_image_tag)?;
        value.serialize_field("parentBackdropItemID", &self.parent_backdrop_item_id)?;
        value.serialize_field("parentBackdropImageTag", &self.parent_backdrop_image_tag)?;
        let provider = &self.provider_ids;
        value.serialize_field("tmdbID", &provider_string(provider, "Tmdb"))?;
        value.serialize_field("malID", &provider_string(provider, "Tvdb"))?;
        value.serialize_field("anilistID", &provider_string(provider, "AniList"))?;
        value.end()
    }
}

fn image_tag(value: &serde_json::Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
}

fn provider_string(value: &serde_json::Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(|v| v.as_str().or_else(|| v.as_i64().map(|_| "")))
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
}

fn swift_kind(value: &str) -> String {
    match value {
        "Movie" | "movie" => "movie",
        "Series" | "series" => "series",
        "Season" | "season" => "season",
        "Episode" | "episode" => "episode",
        "BoxSet" | "boxSet" | "boxset" => "boxSet",
        "MusicAlbum" | "musicAlbum" | "musicalbum" => "musicAlbum",
        "MusicArtist" | "musicArtist" | "musicartist" => "musicArtist",
        "Audio" | "audio" => "audio",
        "Book" | "book" => "book",
        "Photo" | "photo" => "photo",
        "Folder" | "folder" => "folder",
        "Playlist" | "playlist" => "playlist",
        _ => "other",
    }
    .to_owned()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlayedItem {
    pub item: MediaItem,
    pub last_played_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlayedItemsPage {
    pub items: Vec<PlayedItem>,
    pub start_index: i32,
    pub total_record_count: Option<i32>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackSource {
    #[serde(alias = "Id")]
    pub id: Option<String>,
    #[serde(alias = "Path")]
    pub path: Option<String>,
    #[serde(alias = "Protocol")]
    pub protocol: Option<String>,
    #[serde(alias = "Container")]
    pub container: Option<String>,
    #[serde(alias = "Bitrate")]
    pub bitrate: Option<i64>,
    #[serde(alias = "Name")]
    pub name: Option<String>,
    #[serde(alias = "Size")]
    pub size: Option<i64>,
    #[serde(alias = "SupportsDirectPlay")]
    pub supports_direct_play: Option<bool>,
    #[serde(alias = "SupportsDirectStream")]
    pub supports_direct_stream: Option<bool>,
    #[serde(alias = "SupportsTranscoding")]
    pub supports_transcoding: Option<bool>,
    #[serde(alias = "RunTimeTicks")]
    pub run_time_ticks: Option<i64>,
    #[serde(alias = "VideoRangeType")]
    pub video_range_type: Option<String>,
    #[serde(default, alias = "MediaStreams")]
    pub media_streams: Vec<MediaStream>,
}

impl Serialize for PlaybackSource {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut value = serializer.serialize_struct("PlaybackSource", 14)?;
        value.serialize_field("id", &self.id)?;
        value.serialize_field("name", &self.name)?;
        value.serialize_field("path", &self.path)?;
        value.serialize_field("size", &self.size)?;
        value.serialize_field("container", &self.container)?;
        value.serialize_field("protocol", &self.protocol)?;
        value.serialize_field("supportsDirectPlay", &self.supports_direct_play)?;
        value.serialize_field("supportsDirectStream", &self.supports_direct_stream)?;
        value.serialize_field("supportsTranscoding", &self.supports_transcoding)?;
        value.serialize_field("bitrate", &self.bitrate)?;
        value.serialize_field(
            "runTimeSeconds",
            &self.run_time_ticks.map(|ticks| ticks as f64 / 10_000_000.0),
        )?;
        value.serialize_field("videoRangeType", &self.video_range_type)?;
        value.serialize_field("mediaStreams", &self.media_streams)?;
        value.end()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MediaStream {
    pub index: Option<i32>,
    #[serde(rename = "Type", alias = "type")]
    pub kind: Option<String>,
    pub language: Option<String>,
    pub display_title: Option<String>,
    pub codec: Option<String>,
    pub is_forced: Option<bool>,
    pub is_default: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackInfo {
    pub media_sources: Vec<PlaybackSource>,
    pub play_session_id: Option<String>,
}

#[derive(Debug, Error)]
pub enum JellyfinError {
    #[error("authentication response has no valid credentials")]
    Unauthorized,
    #[error("Quick Connect is disabled")]
    QuickConnectDisabled,
    #[error("Quick Connect authorization timed out")]
    QuickConnectTimeout,
    #[error("invalid server profile: {0}")]
    InvalidProfile(String),
    #[error("HTTP: {0}")]
    Http(#[from] HttpError),
    #[error("server response: {0}")]
    Server(String),
}

pub fn normalize_base_url(value: &str) -> Result<Url, JellyfinError> {
    let mut url = Url::parse(value).map_err(|e| JellyfinError::InvalidProfile(e.to_string()))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(JellyfinError::InvalidProfile(
            "scheme must be http or https".into(),
        ));
    }
    url.set_query(None);
    url.set_fragment(None);
    let path = url.path().trim_end_matches('/').to_string();
    url.set_path(&path);
    Ok(url)
}

pub fn image_url(
    profile: &ServerProfile,
    item_id: &str,
    image_type: &str,
    tag: Option<&str>,
    max_width: Option<u32>,
) -> Result<Url, JellyfinError> {
    let mut url = normalize_base_url(&profile.base_url)?;
    let prefix = match profile.kind {
        ServerKind::Jellyfin => "Items",
        ServerKind::Emby => "Items",
    };
    append_path(&mut url, &format!("{prefix}/{item_id}/Images/{image_type}"));
    {
        let mut query = url.query_pairs_mut();
        if let Some(tag) = tag {
            query.append_pair("tag", tag);
        }
        if let Some(width) = max_width {
            query.append_pair("maxWidth", &width.to_string());
        }
    }
    Ok(url)
}

pub fn user_image_url(
    profile: &ServerProfile,
    tag: Option<&str>,
) -> Result<Option<Url>, JellyfinError> {
    let Some(user_id) = profile.user_id.as_deref().filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let mut url = normalize_base_url(&profile.base_url)?;
    match profile.kind {
        ServerKind::Jellyfin => append_path(&mut url, "UserImage"),
        ServerKind::Emby => append_path(&mut url, &format!("Users/{user_id}/Images/Primary")),
    }
    {
        let mut query = url.query_pairs_mut();
        if matches!(profile.kind, ServerKind::Jellyfin) {
            query.append_pair("userId", user_id);
        }
        if let Some(tag) = tag.filter(|value| !value.is_empty()) {
            query.append_pair("tag", tag);
        }
    }
    Ok(Some(url))
}

pub fn stream_url(
    profile: &ServerProfile,
    item_id: &str,
    media_source_id: Option<&str>,
    play_session_id: Option<&str>,
) -> Result<Url, JellyfinError> {
    let mut url = normalize_base_url(&profile.base_url)?;
    append_path(&mut url, &format!("Videos/{item_id}/stream"));
    {
        let mut query = url.query_pairs_mut();
        query.append_pair("static", "true");
        if let Some(id) = media_source_id {
            query.append_pair("MediaSourceId", id);
        }
        if let Some(session) = play_session_id {
            query.append_pair("PlaySessionId", session);
        }
    }
    Ok(url)
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ItemsQuery {
    pub parent_id: Option<String>,
    pub kinds: Option<Vec<String>>,
    pub recursive: bool,
    pub start_index: i32,
    pub limit: i32,
    pub sort: Option<ItemsSort>,
    pub watch_state: Option<WatchState>,
    pub search_term: Option<String>,
}

impl Default for ItemsQuery {
    fn default() -> Self {
        Self {
            parent_id: None,
            kinds: None,
            recursive: true,
            start_index: 0,
            limit: 50,
            sort: None,
            watch_state: None,
            search_term: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ItemsSort {
    pub field: SortField,
    pub ascending: bool,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SortField {
    Name,
    DateAdded,
    Year,
    Rating,
    Runtime,
    Random,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WatchState {
    All,
    Watched,
    Unwatched,
}

impl ItemsQuery {
    fn parameters(&self) -> Vec<(&'static str, String)> {
        let (field, ascending) = self
            .sort
            .as_ref()
            .map(|s| (s.field, s.ascending))
            .unwrap_or((SortField::Name, true));
        let primary = match field {
            SortField::Name => "SortName",
            SortField::DateAdded => "DateCreated",
            SortField::Year => "ProductionYear",
            SortField::Rating => "CommunityRating",
            SortField::Runtime => "Runtime",
            SortField::Random => "Random",
        };
        let order = if ascending { "Ascending" } else { "Descending" };
        let secondary = !matches!(field, SortField::Name | SortField::Random);
        let mut params = vec![
            ("startIndex", self.start_index.to_string()),
            ("limit", self.limit.to_string()),
            ("recursive", self.recursive.to_string()),
            ("fields", MEDIA_LIST_FIELDS.into()),
            (
                "sortBy",
                if secondary {
                    format!("{primary},SortName")
                } else {
                    primary.into()
                },
            ),
            (
                "sortOrder",
                if secondary {
                    format!("{order},Ascending")
                } else {
                    order.into()
                },
            ),
            ("enableImageTypes", "Primary,Backdrop,Logo".into()),
            ("enableTotalRecordCount", "true".into()),
        ];
        if let Some(parent) = &self.parent_id {
            params.push(("parentId", parent.clone()));
        }
        if let Some(search) = self
            .search_term
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            params.push(("searchTerm", search.into()));
        }
        if let Some(kinds) = &self.kinds {
            let wire = kinds
                .iter()
                .filter_map(|kind| match kind.as_str() {
                    "movie" => Some("Movie"),
                    "series" => Some("Series"),
                    "season" => Some("Season"),
                    "episode" => Some("Episode"),
                    "boxSet" => Some("BoxSet"),
                    "musicAlbum" => Some("MusicAlbum"),
                    "musicArtist" => Some("MusicArtist"),
                    "audio" => Some("Audio"),
                    "book" => Some("Book"),
                    "photo" => Some("Photo"),
                    "playlist" => Some("Playlist"),
                    _ => None,
                })
                .collect::<Vec<_>>();
            if !wire.is_empty() {
                params.push(("includeItemTypes", wire.join(",")));
            }
        }
        match self.watch_state {
            Some(WatchState::Watched) => params.push(("filters", "IsPlayed".into())),
            Some(WatchState::Unwatched) => params.push(("filters", "IsUnplayed".into())),
            _ => (),
        }
        params
    }
}

pub struct MediaServerClient<T = reqwest::Client> {
    pub profile: ServerProfile,
    http: HttpClient<T>,
}

impl MediaServerClient<reqwest::Client> {
    pub fn new(profile: ServerProfile) -> Self {
        Self {
            profile,
            http: HttpClient::new(),
        }
    }
}
impl<T: ocp_http::HttpTransport> MediaServerClient<T> {
    pub fn with_http(profile: ServerProfile, http: HttpClient<T>) -> Self {
        Self { profile, http }
    }
    fn headers(&self) -> HeaderMap {
        self.auth_headers()
    }
    fn auth_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            reqwest::header::ACCEPT,
            HeaderValue::from_static("application/json"),
        );
        let scheme = match self.profile.kind {
            ServerKind::Jellyfin => "MediaBrowser",
            ServerKind::Emby => "Emby",
        };
        let mut fields = vec![
            "Client=\"OcPlayer\"".to_owned(),
            "Device=\"OcPlayer\"".to_owned(),
            "DeviceId=\"ocplayer-core\"".to_owned(),
            format!("Version=\"{}\"", env!("CARGO_PKG_VERSION")),
        ];
        if let Some(user_id) = self.profile.user_id.as_deref().filter(|v| !v.is_empty()) {
            fields.push(format!("UserId=\"{}\"", user_id.replace('"', "")));
        }
        if let Some(token) = self.profile.token.as_deref().filter(|v| !v.is_empty()) {
            fields.push(format!("Token=\"{}\"", token.replace('"', "")));
        }
        let identity = self
            .profile
            .authorization_header
            .clone()
            .unwrap_or_else(|| format!("{scheme} {}", fields.join(", ")));
        if let Ok(value) = HeaderValue::from_str(&identity) {
            headers.insert("Authorization", value.clone());
            headers.insert("X-Emby-Authorization", value);
        }
        if let Some(user_agent) = &self.profile.user_agent {
            if let Ok(value) = HeaderValue::from_str(user_agent) {
                headers.insert("User-Agent", value);
            }
        }
        headers
    }
    async fn get<R: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        mut params: Vec<(&str, String)>,
    ) -> Result<R, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, path);
        if let Some(user_id) = &self.profile.user_id {
            params.push(("userId", user_id.clone()));
        }
        {
            let mut query = url.query_pairs_mut();
            for (key, value) in params {
                query.append_pair(key, &value);
            }
        }
        self.http
            .json(Method::GET, url, self.headers(), None)
            .await
            .map_err(Into::into)
    }

    /// Fetch an endpoint whose wire shape is intentionally kept flexible.
    /// Jellyfin and Emby plugins add fields to chapters, segments and subtitle
    /// responses over time; the core forwards those payloads without dropping
    /// unknown fields so platform adapters can apply their own domain mapping.
    pub async fn raw_get(
        &self,
        path: &str,
        params: Vec<(&str, String)>,
    ) -> Result<serde_json::Value, JellyfinError> {
        self.get(path, params).await
    }

    pub async fn raw_post<B: Serialize>(
        &self,
        path: &str,
        body: &B,
        params: Vec<(&str, String)>,
    ) -> Result<serde_json::Value, JellyfinError> {
        self.post(path, body, params).await
    }

    pub async fn current_user(&self) -> Result<serde_json::Value, JellyfinError> {
        let user_id = self
            .profile
            .user_id
            .as_deref()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| JellyfinError::InvalidProfile("user id is required".into()))?;
        self.raw_get(&format!("Users/{user_id}"), vec![]).await
    }
    async fn post<R: for<'de> Deserialize<'de>, B: Serialize>(
        &self,
        path: &str,
        body: &B,
        mut params: Vec<(&str, String)>,
    ) -> Result<R, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, path);
        if let Some(user_id) = &self.profile.user_id {
            params.push(("userId", user_id.clone()));
        }
        {
            let mut query = url.query_pairs_mut();
            for (key, value) in params {
                query.append_pair(key, &value);
            }
        }
        self.http
            .json(
                Method::POST,
                url,
                self.auth_headers(),
                Some(serde_json::to_value(body).map_err(|error| {
                    JellyfinError::Server(format!("failed to encode request: {error}"))
                })?),
            )
            .await
            .map_err(Into::into)
    }
    async fn post_empty<B: Serialize>(&self, path: &str, body: &B) -> Result<(), JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, path);
        let body = serde_json::to_value(body)
            .map_err(|error| JellyfinError::Server(format!("failed to encode request: {error}")))?;
        self.http
            .bytes(Method::POST, url, self.auth_headers(), Some(body))
            .await
            .map(|_| ())
            .map_err(Into::into)
    }
    pub async fn probe(&self) -> Result<ServerInfo, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, "System/Info/Public");
        self.http
            .json(Method::GET, url, self.auth_headers(), None)
            .await
            .map_err(Into::into)
    }
    pub async fn login(
        &self,
        username: &str,
        password: &str,
    ) -> Result<LoginResult, JellyfinError> {
        let value = self
            .auth_json(
                "Users/AuthenticateByName",
                Some(serde_json::json!({
                    "Username": username, "Pw": password,
                })),
            )
            .await
            .map_err(|error| match error {
                JellyfinError::Http(HttpError::Request {
                    category: ErrorCategory::Decode,
                    ..
                }) => JellyfinError::Unauthorized,
                JellyfinError::Http(HttpError::Request {
                    status: Some(400), ..
                }) => JellyfinError::Unauthorized,
                other => other,
            })?;
        LoginResult::parse(value)
    }

    pub async fn login_quick_connect(&self, secret: &str) -> Result<LoginResult, JellyfinError> {
        self.require_quick_connect()?;
        let value = self
            .auth_json(
                "Users/AuthenticateWithQuickConnect",
                Some(serde_json::json!({"Secret":secret})),
            )
            .await?;
        LoginResult::parse(value)
    }

    fn require_quick_connect(&self) -> Result<(), JellyfinError> {
        if self.profile.kind == ServerKind::Emby {
            Err(JellyfinError::QuickConnectDisabled)
        } else {
            Ok(())
        }
    }

    async fn auth_json(
        &self,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, path);
        self.http
            .json_once(Method::POST, url, self.auth_headers(), body)
            .await
            .map_err(Into::into)
    }

    pub async fn quick_connect_initiate(&self) -> Result<QuickConnectState, JellyfinError> {
        self.require_quick_connect()?;
        let value = self
            .auth_json("QuickConnect/Initiate", None)
            .await
            .map_err(quick_connect_error)?;
        let state = QuickConnectState::parse(value);
        if state.secret.is_none() || state.code.is_none() {
            return Err(JellyfinError::Server(
                "Quick Connect response has no secret or code".into(),
            ));
        }
        Ok(state)
    }

    pub async fn quick_connect_state(
        &self,
        secret: &str,
    ) -> Result<QuickConnectState, JellyfinError> {
        self.require_quick_connect()?;
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(&mut url, "QuickConnect/Connect");
        url.query_pairs_mut().append_pair("secret", secret);
        let value = self
            .http
            .json_once(Method::GET, url, self.auth_headers(), None)
            .await
            .map_err(JellyfinError::from)
            .map_err(quick_connect_error)?;
        Ok(QuickConnectState::parse(value))
    }

    /// Shared SDK-equivalent polling policy: immediate first check, reset the
    /// consecutive failure budget on any successful poll, and a bounded wait.
    pub async fn quick_connect_wait(
        &self,
        secret: &str,
        interval: std::time::Duration,
        max_polls: u32,
        failure_tolerance: u32,
    ) -> Result<QuickConnectState, JellyfinError> {
        self.require_quick_connect()?;
        let mut failures = 0;
        for _ in 0..max_polls {
            match self.quick_connect_state(secret).await {
                Ok(state) => {
                    if state.authenticated && state.secret.is_some() {
                        return Ok(state);
                    }
                    failures = 0;
                }
                Err(JellyfinError::QuickConnectDisabled) => {
                    return Err(JellyfinError::QuickConnectDisabled)
                }
                Err(error) => {
                    failures += 1;
                    if failures > failure_tolerance {
                        return Err(error);
                    }
                }
            }
            tokio::time::sleep(interval).await;
        }
        Err(JellyfinError::QuickConnectTimeout)
    }
    pub async fn report_playback_start(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        play_session_id: Option<&str>,
        position_seconds: f64,
        play_method: &str,
    ) -> Result<(), JellyfinError> {
        self.report_playback(
            "Sessions/Playing",
            PlaybackReport {
                item_id,
                media_source_id,
                play_session_id,
                position_seconds,
                play_method,
                paused: false,
            },
        )
        .await
    }
    pub async fn report_playback_progress(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        play_session_id: Option<&str>,
        position_seconds: f64,
        play_method: &str,
        paused: bool,
    ) -> Result<(), JellyfinError> {
        self.report_playback(
            "Sessions/Playing/Progress",
            PlaybackReport {
                item_id,
                media_source_id,
                play_session_id,
                position_seconds,
                play_method,
                paused,
            },
        )
        .await
    }
    pub async fn report_playback_stopped(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        play_session_id: Option<&str>,
        position_seconds: f64,
    ) -> Result<(), JellyfinError> {
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct Stop<'a> {
            item_id: &'a str,
            media_source_id: Option<&'a str>,
            play_session_id: Option<&'a str>,
            position_ticks: i64,
        }
        self.post_empty(
            "Sessions/Playing/Stopped",
            &Stop {
                item_id,
                media_source_id,
                play_session_id,
                position_ticks: seconds_to_ticks(position_seconds),
            },
        )
        .await
    }
    async fn report_playback(
        &self,
        path: &str,
        report: PlaybackReport<'_>,
    ) -> Result<(), JellyfinError> {
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct Progress<'a> {
            can_seek: bool,
            is_paused: bool,
            item_id: &'a str,
            media_source_id: Option<&'a str>,
            play_method: &'a str,
            play_session_id: Option<&'a str>,
            position_ticks: i64,
            session_id: Option<&'a str>,
        }
        self.post_empty(
            path,
            &Progress {
                can_seek: true,
                is_paused: report.paused,
                item_id: report.item_id,
                media_source_id: report.media_source_id,
                play_method: report.play_method,
                play_session_id: report.play_session_id,
                position_ticks: seconds_to_ticks(report.position_seconds),
                session_id: report.play_session_id,
            },
        )
        .await
    }
    pub async fn user_views(&self) -> Result<Vec<MediaItem>, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "Items")]
            items: Vec<MediaItem>,
        }
        let response: Response = self.get("UserViews", vec![]).await?;
        Ok(response.items)
    }

    pub async fn libraries(&self) -> Result<Vec<MediaLibrary>, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "Items")]
            items: Vec<MediaLibrary>,
        }
        let path = match self.profile.kind {
            ServerKind::Jellyfin => "UserViews".to_string(),
            ServerKind::Emby => format!(
                "Users/{}/Views",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        };
        Ok(self.get::<Response>(&path, vec![]).await?.items)
    }

    async fn item_list(
        &self,
        path: &str,
        params: Vec<(&str, String)>,
    ) -> Result<Vec<MediaItem>, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "Items")]
            items: Vec<MediaItem>,
        }
        Ok(self.get::<Response>(path, params).await?.items)
    }

    pub async fn resume_items(&self, limit: i32) -> Result<Vec<MediaItem>, JellyfinError> {
        let path = match self.profile.kind {
            ServerKind::Jellyfin => "UserItems/Resume".to_string(),
            ServerKind::Emby => format!(
                "Users/{}/Items/Resume",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        };
        self.item_list(
            &path,
            vec![
                ("limit", limit.clamp(1, 100).to_string()),
                ("mediaTypes", "Video".into()),
                ("fields", MEDIA_LIST_FIELDS.into()),
            ],
        )
        .await
    }

    pub async fn next_up(&self, limit: i32) -> Result<Vec<MediaItem>, JellyfinError> {
        self.item_list(
            "Shows/NextUp",
            vec![
                ("limit", limit.clamp(1, 100).to_string()),
                ("fields", MEDIA_LIST_FIELDS.into()),
            ],
        )
        .await
    }

    pub async fn latest_items(&self, limit: i32) -> Result<Vec<MediaItem>, JellyfinError> {
        if self.profile.kind == ServerKind::Emby {
            return self
                .get(
                    &format!(
                        "Users/{}/Items/Latest",
                        self.profile.user_id.as_deref().unwrap_or_default()
                    ),
                    vec![
                        ("limit", limit.clamp(1, 100).to_string()),
                        ("fields", MEDIA_LIST_FIELDS.into()),
                    ],
                )
                .await;
        }
        self.item_list(
            "Items",
            vec![
                ("limit", limit.clamp(1, 100).to_string()),
                ("recursive", "true".into()),
                ("includeItemTypes", "Movie,Series".into()),
                ("sortBy", "DateCreated".into()),
                ("sortOrder", "Descending".into()),
                ("fields", MEDIA_LIST_FIELDS.into()),
            ],
        )
        .await
    }

    pub async fn random_items(&self, limit: i32) -> Result<Vec<MediaItem>, JellyfinError> {
        let path = match self.profile.kind {
            ServerKind::Jellyfin => "Items".to_string(),
            ServerKind::Emby => format!(
                "Users/{}/Items",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        };
        self.item_list(
            &path,
            vec![
                ("limit", limit.clamp(1, 100).to_string()),
                ("recursive", "true".into()),
                ("includeItemTypes", "Movie,Series".into()),
                ("sortBy", "Random".into()),
                ("fields", MEDIA_LIST_FIELDS.into()),
            ],
        )
        .await
    }

    pub async fn played_items_page(
        &self,
        start: i32,
        limit: i32,
    ) -> Result<PlayedItemsPage, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "Items")]
            items: Vec<MediaItem>,
            #[serde(rename = "StartIndex")]
            start_index: i32,
            #[serde(rename = "TotalRecordCount")]
            total: Option<i32>,
        }
        let path = match self.profile.kind {
            ServerKind::Jellyfin => "Items".to_string(),
            ServerKind::Emby => format!(
                "Users/{}/Items",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        };
        let response: Response = self
            .get(
                &path,
                vec![
                    ("startIndex", start.max(0).to_string()),
                    ("limit", limit.clamp(1, 500).to_string()),
                    ("recursive", "true".into()),
                    ("includeItemTypes", "Movie,Episode".into()),
                    ("isPlayed", "true".into()),
                    ("sortBy", "DatePlayed".into()),
                    ("sortOrder", "Descending".into()),
                    ("enableTotalRecordCount", "true".into()),
                    ("fields", MEDIA_LIST_FIELDS.into()),
                ],
            )
            .await?;
        let items = response
            .items
            .into_iter()
            .map(|item| PlayedItem {
                last_played_at: item.normalized_play_state().last_played_at.clone(),
                item,
            })
            .collect();
        Ok(PlayedItemsPage {
            items,
            start_index: response.start_index,
            total_record_count: response.total,
        })
    }

    pub async fn mark_played(&self, item_id: &str) -> Result<PlayState, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(
            &mut url,
            &format!(
                "Users/{}/PlayedItems/{item_id}",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        );
        self.http
            .empty(Method::POST, url, self.auth_headers())
            .await?;
        Ok(PlayState {
            position_seconds: 0.0,
            played: true,
            percentage: 1.0,
            unplayed_count: None,
            last_played_at: None,
        })
    }

    pub async fn mark_unplayed(&self, item_id: &str) -> Result<PlayState, JellyfinError> {
        let mut url = normalize_base_url(&self.profile.base_url)?;
        append_path(
            &mut url,
            &format!(
                "Users/{}/PlayedItems/{item_id}",
                self.profile.user_id.as_deref().unwrap_or_default()
            ),
        );
        self.http
            .empty(Method::DELETE, url, self.auth_headers())
            .await?;
        Ok(PlayState::default())
    }
    pub async fn item(&self, id: &str) -> Result<MediaItem, JellyfinError> {
        self.get(
            &format!("Items/{id}"),
            vec![("fields", MEDIA_LIST_FIELDS.into())],
        )
        .await
    }
    pub async fn items_page(
        &self,
        parent_id: Option<&str>,
        start: i32,
        limit: i32,
        search: Option<&str>,
    ) -> Result<MediaItemsPage, JellyfinError> {
        self.items_page_filtered(&ItemsQuery {
            parent_id: parent_id.map(str::to_owned),
            start_index: start,
            limit,
            search_term: search.map(str::to_owned),
            ..Default::default()
        })
        .await
    }

    pub async fn items_page_filtered(
        &self,
        query: &ItemsQuery,
    ) -> Result<MediaItemsPage, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "Items", default)]
            items: Vec<MediaItem>,
            #[serde(rename = "TotalRecordCount")]
            total: Option<i32>,
        }
        let response: Response = self.get("Items", query.parameters()).await?;
        Ok(MediaItemsPage {
            items: response.items,
            start_index: query.start_index,
            total_record_count: response.total,
        })
    }
    pub async fn playback_info(&self, id: &str) -> Result<PlaybackInfo, JellyfinError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(rename = "MediaSources")]
            media_sources: Vec<PlaybackSource>,
            #[serde(rename = "PlaySessionId")]
            play_session_id: Option<String>,
        }
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct DeviceProfile {
            name: &'static str,
            max_streaming_bitrate: u32,
            direct_play_profiles: Vec<DirectPlayProfile>,
        }
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct DirectPlayProfile {
            container: &'static str,
            audio_codec: Option<&'static str>,
            video_codec: Option<&'static str>,
            #[serde(rename = "Type")]
            media_type: &'static str,
        }
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct PlaybackInfoRequest {
            allow_audio_stream_copy: bool,
            allow_video_stream_copy: bool,
            enable_direct_play: bool,
            enable_direct_stream: bool,
            enable_transcoding: bool,
            device_profile: DeviceProfile,
            user_id: Option<String>,
        }
        let body = PlaybackInfoRequest {
            allow_audio_stream_copy: true,
            allow_video_stream_copy: true,
            enable_direct_play: true,
            enable_direct_stream: true,
            enable_transcoding: false,
            device_profile: DeviceProfile {
                name: "OcPlayer",
                max_streaming_bitrate: 120_000_000,
                direct_play_profiles: vec![
                    DirectPlayProfile {
                        container: "mkv,mp4,ts,m2ts",
                        audio_codec: Some("aac,ac3,eac3,dts,truehd,flac,opus"),
                        video_codec: Some("h264,hevc,av1,vc1"),
                        media_type: "Video",
                    },
                    DirectPlayProfile {
                        container: "mp4,m4a,flac,opus,aac,ac3,eac3",
                        audio_codec: None,
                        video_codec: None,
                        media_type: "Audio",
                    },
                ],
            },
            user_id: self.profile.user_id.clone(),
        };
        let response: Response = self
            .post(&format!("Items/{id}/PlaybackInfo"), &body, vec![])
            .await?;
        Ok(PlaybackInfo {
            media_sources: response.media_sources,
            play_session_id: response.play_session_id,
        })
    }
}

fn append_path(url: &mut Url, path: &str) {
    let base = url.path().trim_end_matches('/');
    let suffix = path.trim_matches('/');
    url.set_path(&format!("{base}/{suffix}"));
}

fn seconds_to_ticks(seconds: f64) -> i64 {
    if !seconds.is_finite() || seconds <= 0.0 {
        0
    } else {
        (seconds * 10_000_000.0).round().min(i64::MAX as f64) as i64
    }
}

fn quick_connect_error(error: JellyfinError) -> JellyfinError {
    match error {
        JellyfinError::Http(HttpError::Request {
            status: Some(404), ..
        }) => JellyfinError::QuickConnectDisabled,
        other => other,
    }
}

pub fn classify_http_error(error: &JellyfinError) -> ErrorCategory {
    match error {
        JellyfinError::Unauthorized => ErrorCategory::Unauthorized,
        JellyfinError::QuickConnectDisabled | JellyfinError::QuickConnectTimeout => {
            ErrorCategory::InvalidRequest
        }
        JellyfinError::Http(error) => error.category().unwrap_or(ErrorCategory::Transport),
        JellyfinError::InvalidProfile(_) | JellyfinError::Server(_) => {
            ErrorCategory::InvalidRequest
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authentication_requires_credentials_but_ignores_unrelated_field_types() {
        let result = LoginResult::parse(serde_json::json!({"AccessToken":"t", "User":{"Id":"u", "Name":5,"PrimaryImageTag":[],"Policy":false}})).unwrap();
        assert_eq!(result.user_name, None);
        assert_eq!(result.primary_image_tag, None);
        for value in [
            serde_json::json!({"AccessToken":"", "User":{"Id":"u"}}),
            serde_json::json!({"AccessToken":5, "User":{"Id":"u"}}),
            serde_json::json!({"AccessToken":"t", "User":{"Id":3}}),
            serde_json::Value::Null,
        ] {
            assert!(matches!(
                LoginResult::parse(value),
                Err(JellyfinError::Unauthorized)
            ));
        }
    }

    #[test]
    fn quick_connect_requires_true_and_nonempty_secret() {
        let value = QuickConnectState::parse(
            serde_json::json!({"Authenticated":"true","Secret":"","Code":123}),
        );
        assert!(!value.authenticated);
        assert_eq!(value.secret, None);
        assert_eq!(value.code, None);
        assert_eq!(
            QuickConnectState::parse(
                serde_json::json!({"Authenticated":true,"Secret":"s","Code":"1"})
            ),
            QuickConnectState {
                authenticated: true,
                secret: Some("s".into()),
                code: Some("1".into())
            }
        );
    }
    #[test]
    fn builds_auth_free_urls() {
        let profile = ServerProfile {
            id: "s".into(),
            kind: ServerKind::Jellyfin,
            base_url: "HTTP://NAS.local:8096/".into(),
            user_id: Some("u".into()),
            token: None,
            authorization_header: None,
            user_agent: None,
        };
        assert_eq!(
            image_url(&profile, "id", "Primary", Some("tag"), Some(600))
                .unwrap()
                .as_str(),
            "http://nas.local:8096/Items/id/Images/Primary?tag=tag&maxWidth=600"
        );
        assert!(stream_url(&profile, "id", Some("src"), None)
            .unwrap()
            .as_str()
            .contains("MediaSourceId=src"));
    }

    #[test]
    fn decodes_server_wire_casing_and_nested_user_data() {
        let item: MediaItem = serde_json::from_value(serde_json::json!({
            "Id": "episode-1",
            "Name": "Episode 1",
            "Type": "Episode",
            "SeriesId": "series-1",
            "ParentIndexNumber": 2,
            "IndexNumber": 1,
            "RunTimeTicks": 18000000000_i64,
            "ProviderIds": {"Tmdb": "123"},
            "UserData": {"PlaybackPositionTicks": 450000000_i64, "Played": false}
        }))
        .unwrap();
        let progress = item.normalized_play_state();
        assert_eq!(item.id, "episode-1");
        assert_eq!(item.season_number, Some(2));
        assert_eq!(progress.position_seconds, 45.0);
        assert_eq!(item.provider_ids["Tmdb"], "123");
    }

    #[test]
    fn decodes_library_and_played_history_wire_models() {
        let library: MediaLibrary = serde_json::from_value(serde_json::json!({
            "Id": "movies",
            "Name": "Movies",
            "CollectionType": "movies",
            "ImageTags": {"Primary": "tag-1"}
        }))
        .unwrap();
        assert_eq!(library.collection_type.as_deref(), Some("movies"));
        assert_eq!(library.image_tags["Primary"], "tag-1");

        let item: MediaItem = serde_json::from_value(serde_json::json!({
            "Id": "episode-2",
            "Name": "Episode 2",
            "Type": "Episode",
            "UserData": {"Played": true, "LastPlayedDate": "2026-11-12T12:00:00Z"}
        }))
        .unwrap();
        assert_eq!(
            item.normalized_play_state().last_played_at.as_deref(),
            Some("2026-11-12T12:00:00Z")
        );
    }

    #[test]
    fn serializes_swift_domain_casing_and_play_state() {
        let item: MediaItem = serde_json::from_value(serde_json::json!({
            "Id": "movie-1",
            "Name": "Movie",
            "Type": "Movie",
            "ProductionYear": 2024,
            "RunTimeTicks": 10_000_000_i64,
            "ImageTags": {"Primary": "p1"},
            "UserData": {"Played": true, "PlayedPercentage": 100.0}
        }))
        .unwrap();
        let encoded = serde_json::to_value(item).unwrap();
        assert_eq!(encoded["kind"], "movie");
        assert_eq!(encoded["runtimeSeconds"], 1.0);
        assert_eq!(encoded["primaryImageTag"], "p1");
        assert_eq!(encoded["playState"]["played"], true);
        assert_eq!(encoded["playState"]["percentage"], 1.0);
    }

    #[test]
    fn preserves_server_base_path_when_building_endpoint() {
        let profile = ServerProfile {
            id: "s".into(),
            kind: ServerKind::Emby,
            base_url: "https://example.test/emby/".into(),
            user_id: None,
            token: None,
            authorization_header: None,
            user_agent: None,
        };
        assert_eq!(
            image_url(&profile, "item", "Primary", None, None)
                .unwrap()
                .path(),
            "/emby/Items/item/Images/Primary"
        );
    }
}
