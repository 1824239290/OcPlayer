use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    LocalFolder,
    Smb,
    Webdav,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum LibraryType {
    Movies,
    Tvshows,
}

impl LibraryType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Movies => "movies",
            Self::Tvshows => "tvshows",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Movie,
    Series,
    Season,
    Episode,
    Unidentified,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Movie => "movie",
            Self::Series => "series",
            Self::Season => "season",
            Self::Episode => "episode",
            Self::Unidentified => "unidentified",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub source_id: String,
    pub kind: SourceKind,
    pub display_name: String,
    /// The host keeps platform bookmark bytes and credentials outside this database.
    pub access_ref: Option<String>,
    pub root_path: String,
    pub created_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub library_id: String,
    pub source_id: String,
    pub name: String,
    pub root_path: String,
    #[serde(rename = "type")]
    pub library_type: LibraryType,
    pub revision: i64,
    pub created_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub source_id: String,
    pub library_id: String,
    pub item_id: String,
    pub kind: ItemKind,
    pub title: String,
    pub year: Option<i64>,
    pub parent_id: Option<String>,
    pub series_id: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub first_seen_at: f64,
    pub metadata: Option<serde_json::Value>,
    pub match_status: String,
    pub playable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub source_id: String,
    pub asset_id: String,
    pub relative_path: String,
    pub size: i64,
    pub available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub job_id: String,
    pub source_id: String,
    pub library_id: String,
    pub generation: i64,
    pub status: String,
    pub files_found: i64,
    pub directories_done: i64,
    pub error_count: i64,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Progress {
    pub source_id: String,
    pub item_id: String,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub played: bool,
    pub completed: bool,
    pub recorded_at: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Query {
    pub source_id: String,
    pub library_id: Option<String>,
    #[serde(rename = "type")]
    pub library_type: Option<LibraryType>,
    pub parent_id: Option<String>,
    #[serde(default)]
    pub search: String,
    #[serde(default)]
    pub start_index: i64,
    #[serde(default = "default_limit")]
    pub limit: i64,
}

fn default_limit() -> i64 {
    50
}
