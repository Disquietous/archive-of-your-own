use crate::error::AppError;
use crate::parser;

use super::{AO3Client, BASE_URL, FailureKind};
use super::audit::{ActiveRequestGuard, AuditCtx, redact_payload};
use super::helpers::{comment_post_succeeded, urlencoded};

impl AO3Client {
    /// Log in to AO3 with username and password.
    /// Returns true on success, false on failure.
    pub async fn login(&self, username: &str, password: &str) -> Result<bool, AppError> {
        // Step 1: GET login page to get authenticity_token and session cookie
        let login_html = self.fetch(&format!("{BASE_URL}/users/login")).await?;

        // Get the token from the MAIN login form (#new_user), not the small header form
        let token = {
            let doc = scraper::Html::parse_document(&login_html);
            let form_sel = scraper::Selector::parse("form#new_user input[name='authenticity_token']").unwrap();
            doc.select(&form_sel)
                .next()
                .and_then(|el| el.value().attr("value"))
                .map(|s| s.to_string())
                .ok_or_else(|| AppError::ParseError("No authenticity_token found".to_string()))
        }?;

        // Step 2: POST login form
        self.enforce_rate_limit().await;

        let client = self.http();

        let timeout = self.request_timeout();

        let params = [
            ("authenticity_token", token.as_str()),
            ("user[login]", username),
            ("user[password]", password),
            ("user[remember_me]", "1"),
            ("commit", "Log In"),
        ];

        let login_url = format!("{BASE_URL}/users/login");
        let _active = ActiveRequestGuard::new("POST", &login_url, timeout.as_secs());
        let audit = AuditCtx::new("POST", &login_url, Some(redact_payload(&params)));

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(&login_url)
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;

            let status = resp.status().as_u16();

            // Check for user_credentials cookie in response headers
            let has_cred_cookie = resp.headers().get_all("set-cookie")
                .iter()
                .any(|v| v.to_str().unwrap_or("").contains("user_credentials"));

            let final_url = resp.url().to_string();
            let body = resp.text().await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;

            Ok::<(bool, String, String, u16, usize), AppError>((has_cred_cookie, final_url, body, status, 0))
        }).await;

        let (has_cred_cookie, final_url, body, status, _) = match result {
            // The whole round trip (connect through body) shares one
            // deadline, so a manual timeout here can't prove whether AO3
            // ever saw the request — treat it like a dead circuit.
            Err(_) => {
                audit.record(0, 0, Some("timeout".to_string()));
                return Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() });
            }
            Ok(Err(e)) => { audit.record(0, 0, Some(format!("{e}"))); return Err(e); }
            Ok(Ok(v)) => v,
        };
        audit.record(status, body.len() as u64, None);
        let _body = body;

        let logged_in = has_cred_cookie || !final_url.contains("/users/login");

        Ok(logged_in)
    }

    /// POST a form to AO3, scraping the CSRF token from the POST URL itself.
    /// Only valid when GET on that URL renders a page (bookmarks, deletes) —
    /// for endpoints with no GET route use post_form_from with a token page.
    pub async fn post_form(&self, url: &str, params: &[(String, String)]) -> Result<String, AppError> {
        self.post_form_from(url, url, params).await
    }

    /// POST a form to AO3 with the CSRF token scraped from `token_page` —
    /// the page that hosts the form. Falls back to the csrf-token meta tag
    /// (present on every AO3 page; session-scoped, so any page's token is
    /// valid), and refuses to POST with an empty token — that's a guaranteed
    /// Rails 500.
    pub async fn post_form_from(&self, url: &str, token_page: &str, params: &[(String, String)]) -> Result<String, AppError> {
        let page = self.fetch(token_page).await?;
        let token = {
            let doc = scraper::Html::parse_document(&page);
            doc.select(&scraper::Selector::parse("input[name='authenticity_token']").unwrap())
                .next()
                .and_then(|el| el.value().attr("value").map(str::to_string))
                .or_else(|| {
                    doc.select(&scraper::Selector::parse("meta[name='csrf-token']").unwrap())
                        .next()
                        .and_then(|el| el.value().attr("content").map(str::to_string))
                })
                .unwrap_or_default()
        };
        if token.is_empty() {
            return Err(AppError::ParseError(format!("no CSRF token found on {token_page}")));
        }

        let mut form_params: Vec<(String, String)> = vec![
            ("authenticity_token".to_string(), token),
        ];
        form_params.extend_from_slice(params);
        self.post_form_raw(url, form_params).await
    }

    /// POST a comment from cached credentials — no preparatory GET. The form
    /// fields mirror AO3's comment form exactly: authenticity_token,
    /// comment[pseud_id], controller_name, comment[comment_content], commit.
    /// If credentials are missing or the archive rejects them, `form_page`
    /// is fetched ONCE (which re-harvests both) and the POST retried.
    pub async fn post_comment_direct(&self, endpoint: &str, controller_name: &str,
                                     form_page: &str, content: &str) -> Result<bool, AppError> {
        let mut refreshed = false;
        loop {
            let (token, pseud) = (self.cached_csrf_token(), self.cached_pseud_id());
            let (Some(token), Some(pseud)) = (token, pseud) else {
                if refreshed {
                    return Err(AppError::ParseError(format!(
                        "no posting credentials found on {form_page} — are you signed in?")));
                }
                self.fetch(form_page).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let params = vec![
                ("authenticity_token".to_string(), token),
                ("comment[pseud_id]".to_string(), pseud),
                ("controller_name".to_string(), controller_name.to_string()),
                ("comment[comment_content]".to_string(), content.to_string()),
                ("commit".to_string(), "Comment".to_string()),
            ];
            let body = self.post_form_raw(endpoint, params).await?;
            if comment_post_succeeded(&body, content) {
                return Ok(true);
            }
            if !refreshed {
                // Stale token (session changed since it was harvested) —
                // refresh once and retry.
                refreshed = true;
                self.fetch(form_page).await?;
                continue;
            }
            log_info!("comment", "Rejected POST to {endpoint}: {}",
                      body.chars().take(300).collect::<String>());
            return Ok(false);
        }
    }

    /// POST pre-assembled form params (token already included).
    pub(super) async fn post_form_raw(&self, url: &str, form_params: Vec<(String, String)>) -> Result<String, AppError> {
        self.enforce_rate_limit().await;

        let client = self.http();

        let timeout = self.request_timeout();

        let _active = ActiveRequestGuard::new("POST", url, timeout.as_secs());
        let audit = AuditCtx::new("POST", url, Some(redact_payload(
            &form_params.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect::<Vec<_>>())));

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(url)
                .form(&form_params)
                .send()
                .await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            let status = resp.status().as_u16();
            let body = resp.text().await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            Ok::<(u16, String), AppError>((status, body))
        }).await;

        match result {
            // See the comment on login()'s equivalent branch: one deadline
            // covers the whole round trip, so this is treated as connect-class.
            Err(_) => {
                audit.record(0, 0, Some("timeout".to_string()));
                Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() })
            }
            Ok(Err(e)) => { audit.record(0, 0, Some(format!("{e}"))); Err(e) }
            Ok(Ok((status, body))) if status >= 400 => {
                // A non-success POST response (e.g. a Cloudflare 525 error
                // page) must not be mistaken for a successful post whose
                // content just doesn't match what the caller expected.
                let detail = format!("HTTP {status} for {url}");
                audit.record(status, body.len() as u64, Some(detail.clone()));
                Err(AppError::Http { kind: FailureKind::from_status(status, None), detail })
            }
            Ok(Ok((status, body))) => { audit.record(status, body.len() as u64, None); Ok(body) }
        }
    }

    /// Leave kudos on a work using the cached CSRF token — no preparatory
    /// GET. On a cache miss or a stale-token rejection, the work page is
    /// fetched ONCE (re-harvesting the token) and the POST retried.
    pub async fn leave_kudos(&self, work_id: u64) -> Result<bool, AppError> {
        let work_url = format!("{BASE_URL}/works/{work_id}?view_adult=true");
        let mut refreshed = false;
        loop {
            let Some(token) = self.cached_csrf_token() else {
                if refreshed {
                    return Err(AppError::ParseError("no CSRF token available — are you signed in?".to_string()));
                }
                self.fetch(&work_url).await?; // harvest hook fills the cache
                refreshed = true;
                continue;
            };
            let (status, body) = self.post_kudos_raw(work_id, &token, &work_url).await?;
            let already = body.contains("already left kudos");
            if status < 300 || already {
                return Ok(true);
            }
            // A transient infrastructure failure disguised as a completed
            // HTTP response (e.g. a Cloudflare 525 error page) is not AO3
            // rejecting the kudos. Surface it as a typed failure so the
            // recovery engine can rotate and retry — returning `Ok(false)`
            // here (the original bug) is indistinguishable from a genuine
            // rejection to every caller above this.
            if matches!(status, 429 | 502 | 503 | 504 | 525) {
                let kind = FailureKind::from_status(status, None);
                return Err(AppError::Http { kind, detail: format!("HTTP {status} leaving kudos") });
            }
            if !refreshed {
                refreshed = true;
                self.fetch(&work_url).await?;
                continue;
            }
            log_info!("kudos", "Rejected (HTTP {status}): {}", body.chars().take(300).collect::<String>());
            return Ok(false);
        }
    }

    async fn post_kudos_raw(&self, work_id: u64, token: &str, work_url: &str) -> Result<(u16, String), AppError> {
        let _active = ActiveRequestGuard::new("POST", &format!("{BASE_URL}/kudos"), self.request_timeout().as_secs());
        self.enforce_rate_limit().await;

        let client = self.http();
        let timeout = self.request_timeout();

        let id_string = work_id.to_string();
        let params = [
            ("authenticity_token", token),
            ("kudo[commentable_id]", id_string.as_str()),
            ("kudo[commentable_type]", "Work"),
        ];
        let kudos_url = format!("{BASE_URL}/kudos");
        let audit = AuditCtx::new("POST", &kudos_url, Some(redact_payload(&params)));

        let result = tokio::time::timeout(timeout, async {
            let resp = client.post(&kudos_url)
                // Match the site's own AJAX submission: JSON responses, and a
                // 422 (not a redirect chain) for "already left kudos".
                .header("X-Requested-With", "XMLHttpRequest")
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .header("Referer", work_url)
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            let status = resp.status().as_u16();
            let body = resp.text().await
                .map_err(|e| AppError::Http { kind: FailureKind::from_transport(&e), detail: format!("{e}") })?;
            Ok::<(u16, String), AppError>((status, body))
        }).await;

        match result {
            Err(_) => {
                audit.record(0, 0, Some("timeout".to_string()));
                Err(AppError::Http { kind: FailureKind::ConnectFailure, detail: "timeout".to_string() })
            }
            Ok(Err(e)) => {
                audit.record(0, 0, Some(format!("{e}")));
                Err(e)
            }
            Ok(Ok((status, body))) => {
                let accepted = status < 300 || body.contains("already left kudos");
                audit.record(status, body.len() as u64,
                             if accepted { None } else { Some(format!("HTTP {status}")) });
                Ok((status, body))
            }
        }
    }

    /// A user's profile page as an AO3User record (avatar URL included when
    /// the page has one). One request.
    pub async fn fetch_user_profile(&self, username: &str) -> Result<crate::models::AO3User, AppError> {
        let html = self.fetch(&format!("{BASE_URL}/users/{}/profile", urlencoded(username))).await?;
        Ok(crate::models::AO3User {
            id: username.to_string(),
            username: username.to_string(),
            profile_url: Some(format!("{BASE_URL}/users/{username}")),
            avatar_url: parser::extract_user_icon_url(&html),
        })
    }

    /// A user's profile icon: profile page → icon URL → image. Returns the
    /// bytes plus the resolved icon URL so callers can record it.
    /// Two requests; callers cache the result so this runs once per user.
    pub async fn fetch_user_icon(&self, username: &str) -> Result<(Vec<u8>, String), AppError> {
        let profile = self.fetch_user_profile(username).await?;
        let Some(url) = profile.avatar_url else {
            return Err(AppError::ElementNotFound(format!("profile icon for {username}")));
        };
        let bytes = self.fetch_image(&url).await?;
        Ok((bytes, url))
    }

    /// AO3's JSON autocomplete for canonical tag names — fired ONLY on an
    /// explicit user action, never on keystrokes (local cache handles those).
    /// tag_type: fandom | character | relationship | freeform | creator.
    pub async fn autocomplete(&self, tag_type: &str, term: &str) -> Result<Vec<String>, AppError> {
        let endpoint = match tag_type {
            "creator" => "pseud",
            other => other,
        };
        let url = format!("{BASE_URL}/autocomplete/{}?term={}", endpoint, urlencoded(term));
        let body = self.fetch_ajax(&url).await?;
        let parsed: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| AppError::ParseError(format!("autocomplete JSON: {e}")))?;
        let mut names = Vec::new();
        if let Some(items) = parsed.as_array() {
            for item in items {
                if let Some(name) = item.get("name").and_then(|v| v.as_str()) {
                    names.push(name.to_string());
                }
            }
        }
        Ok(names)
    }

    /// Log out of AO3 by sending a DELETE request to the session endpoint.
    pub async fn logout(&self) -> Result<(), AppError> {
        let html = self.fetch(&format!("{BASE_URL}/")).await?;
        let token = {
            let doc = scraper::Html::parse_document(&html);
            let sel = scraper::Selector::parse("a[href='/users/logout']").unwrap();
            if doc.select(&sel).next().is_none() {
                return Ok(());
            }
            let meta_sel = scraper::Selector::parse("meta[name='csrf-token']").unwrap();
            doc.select(&meta_sel)
                .next()
                .and_then(|el| el.value().attr("content"))
                .map(|s| s.to_string())
                .unwrap_or_default()
        };

        if token.is_empty() {
            self.clear_cookies();
            return Ok(());
        }

        self.enforce_rate_limit().await;

        let client = self.http();

        let timeout = self.request_timeout();

        let params = [
            ("authenticity_token", token.as_str()),
            ("_method", "delete"),
        ];

        let result = tokio::time::timeout(timeout, async {
            client.post(&format!("{BASE_URL}/users/logout"))
                .form(&params)
                .send()
                .await
                .map_err(|e| AppError::NetworkError(format!("{e}")))?;
            Ok::<(), AppError>(())
        }).await;

        match result {
            Err(_) => {},
            Ok(Err(_)) => {},
            Ok(Ok(())) => {},
        }

        self.clear_cookies();
        Ok(())
    }
}
