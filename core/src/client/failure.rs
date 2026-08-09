// ---------------------------------------------------------------------------
// Typed failure classification
// ---------------------------------------------------------------------------
//
// Every variant here is derived from a status code or a `reqwest::Error`'s
// typed flags — never from `Display` text. This is what let us delete
// `send_error_message`, whose entire purpose was prefixing "timeout: " so
// Swift's old string-matching retry layer would fire.

/// Typed classification of a failed request. Drives the recovery engine's
/// per-kind remedy (`api::recovery`) and is carried to Swift inside
/// `AO3Error::Http` so the UI can react without string matching.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FailureKind {
    /// HTTP 525 — Cloudflare's TLS handshake to the AO3 origin failed. This
    /// correlates strongly with the specific Tor exit node, and the request
    /// provably never reached AO3.
    EdgeTlsFailure,
    /// HTTP 429 — rate limited. The budget is scoped to the exit IP.
    RateLimited { retry_after_secs: Option<u32> },
    /// HTTP 403 — bot/challenge protection rejected the request.
    Challenged,
    /// HTTP 502/503/504 — an origin-wide outage, unrelated to the circuit.
    OriginUnavailable,
    /// The transport never produced a response: SOCKS/TCP/TLS failure, or
    /// reqwest's own connect-phase timeout.
    ConnectFailure,
    /// Headers arrived but the body stalled past the deadline — the request
    /// definitely reached the origin.
    ResponseTimeout,
    /// AO3 redirected to `/users/login` mid-request — the session is dead.
    SessionExpired,
    /// Any other non-2xx status not covered above.
    Http { code: u16 },
    /// The response body failed to decode.
    Malformed,
}

impl FailureKind {
    /// Classify a terminal HTTP status code.
    pub fn from_status(code: u16, retry_after_secs: Option<u32>) -> Self {
        match code {
            525 => FailureKind::EdgeTlsFailure,
            429 => FailureKind::RateLimited { retry_after_secs },
            403 => FailureKind::Challenged,
            502..=504 => FailureKind::OriginUnavailable,
            other => FailureKind::Http { code: other },
        }
    }

    /// Classify a `reqwest::Error`, using only its typed flags. A decode/body
    /// error means a response came back but couldn't be read; anything else
    /// from the send phase means no response was ever received.
    pub fn from_transport(e: &reqwest::Error) -> Self {
        if e.is_decode() || e.is_body() {
            FailureKind::Malformed
        } else {
            FailureKind::ConnectFailure
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_classification() {
        assert_eq!(FailureKind::from_status(525, None), FailureKind::EdgeTlsFailure);
        assert_eq!(FailureKind::from_status(429, Some(30)),
                   FailureKind::RateLimited { retry_after_secs: Some(30) });
        assert_eq!(FailureKind::from_status(403, None), FailureKind::Challenged);
        assert_eq!(FailureKind::from_status(502, None), FailureKind::OriginUnavailable);
        assert_eq!(FailureKind::from_status(503, None), FailureKind::OriginUnavailable);
        assert_eq!(FailureKind::from_status(504, None), FailureKind::OriginUnavailable);
        assert_eq!(FailureKind::from_status(418, None), FailureKind::Http { code: 418 });
        assert_eq!(FailureKind::from_status(500, None), FailureKind::Http { code: 500 });
    }
}
