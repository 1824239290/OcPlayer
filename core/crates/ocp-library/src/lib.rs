//! Permanent file-library catalog. Never participates in disposable cache recovery.

pub mod model;
pub mod parse;
pub mod scan;
pub mod scrape;
pub mod store;

pub use model::*;
pub use store::Store;

use thiserror::Error;

pub const FILE_NAME: &str = "Library.sqlite";

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid library request: {0}")]
    Invalid(String),
    #[error("library record not found")]
    NotFound,
    #[error("filesystem: {0}")]
    Io(#[from] std::io::Error),
    #[error("library database: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("library JSON: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

pub fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
