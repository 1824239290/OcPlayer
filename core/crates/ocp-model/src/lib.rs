//! Stable JSON-facing domain types shared by the core and platform adapters.

use serde::{Deserialize, Serialize};

pub const ABI_VERSION: u32 = 1;
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, rename_all = "camelCase")]
pub struct CoreConfig {
    #[serde(default, alias = "data_directory")]
    pub data_directory: Option<String>,
    /// Exact existing media cache path for platform clients sharing a database.
    pub media_database_path: Option<String>,
    /// Exact existing Bangumi cache path; independent of the media cache.
    pub bangumi_database_path: Option<String>,
    #[serde(default)]
    pub locale: Option<String>,
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            data_directory: None,
            media_database_path: None,
            bangumi_database_path: None,
            locale: Some("en-US".to_string()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ApiResponse<T> {
    pub ok: bool,
    pub code: i32,
    pub retryable: bool,
    pub message: String,
    pub data: T,
}

impl<T> ApiResponse<T> {
    pub fn ok(data: T) -> Self {
        Self {
            ok: true,
            code: 0,
            retryable: false,
            message: String::new(),
            data,
        }
    }

    pub fn error(code: i32, retryable: bool, message: impl Into<String>, data: T) -> Self {
        Self {
            ok: false,
            code,
            retryable,
            message: message.into(),
            data,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Event {
    pub sequence: u64,
    pub kind: String,
    pub data: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CoreSnapshot {
    #[serde(rename = "abiVersion")]
    pub abi_version: u32,
    #[serde(rename = "coreVersion")]
    pub core_version: String,
    pub ready: bool,
    pub config: CoreConfig,
    #[serde(rename = "surfaceAttached")]
    pub surface_attached: bool,
    #[serde(rename = "activeMethod")]
    pub active_method: Option<String>,
    pub playback: PlaybackSnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackSnapshot {
    pub state: PlaybackState,
    pub source: Option<serde_json::Value>,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub rate: f64,
    pub volume: f64,
    pub muted: bool,
    pub audio_track: Option<String>,
    pub subtitle_track: Option<String>,
    pub error: Option<PlaybackError>,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            state: PlaybackState::Idle,
            source: None,
            position_seconds: 0.0,
            duration_seconds: None,
            rate: 1.0,
            volume: 1.0,
            muted: false,
            audio_track: None,
            subtitle_track: None,
            error: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackState {
    Idle,
    Opening,
    Ready,
    Playing,
    Paused,
    Stopped,
    Ended,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackError {
    pub category: String,
    pub message: String,
}
