use super::*;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AO3Error {
    #[error("Network error: {message}")]
    Network { message: String },
    #[error("Parse error: {message}")]
    Parse { message: String },
    #[error("Storage error: {message}")]
    Storage { message: String },
    #[error("Not found: {message}")]
    NotFound { message: String },
    /// The operation was cancelled (user action or task abort).
    #[error("cancelled")]
    Cancelled,
    /// No usable session and no way to restore one without the user's
    /// password — the UI must prompt for re-authentication.
    #[error("password_needed")]
    PasswordNeeded,
    /// AO3 redirected to the login page mid-operation: the session cookie
    /// is no longer valid.
    #[error("session_expired")]
    SessionExpired,
}

impl From<AppError> for AO3Error {
    fn from(e: AppError) -> Self {
        match e {
            AppError::NetworkError(m) => AO3Error::Network { message: m },
            AppError::TorError(m) => AO3Error::Network { message: m },
            AppError::ParseError(m) => AO3Error::Parse { message: m },
            AppError::StorageError(m) => AO3Error::Storage { message: m },
            AppError::ElementNotFound(m) => AO3Error::NotFound { message: m },
            AppError::InvalidWorkId(m) => AO3Error::Parse { message: m },
            AppError::SessionExpired => AO3Error::SessionExpired,
        }
    }
}
