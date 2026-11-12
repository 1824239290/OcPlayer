//! Stable JSON-facing domain types shared by the core and platform adapters.

use serde::{Deserialize, Serialize};

pub const ABI_VERSION: u32 = 1;
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CoreConfig {
    #[serde(default)]
    pub data_directory: Option<String>,
    #[serde(default)]
    pub locale: Option<String>,
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            data_directory: None,
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
    pub abi_version: u32,
    pub core_version: String,
    pub ready: bool,
    pub config: CoreConfig,
    pub surface_attached: bool,
    pub active_method: Option<String>,
}
