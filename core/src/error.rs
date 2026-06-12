use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("Failed to parse HTML: {0}")]
    ParseError(String),

    #[error("Element not found: {0}")]
    ElementNotFound(String),

    #[error("Network error: {0}")]
    NetworkError(String),

    #[error("Invalid work ID: {0}")]
    InvalidWorkId(String),

    #[error("Storage error: {0}")]
    StorageError(String),

    #[error("Tor connection error: {0}")]
    TorError(String),
}

impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        AppError::StorageError(e.to_string())
    }
}

impl From<reqwest::Error> for AppError {
    fn from(e: reqwest::Error) -> Self {
        AppError::NetworkError(e.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        AppError::ParseError(e.to_string())
    }
}
