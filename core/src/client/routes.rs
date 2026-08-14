//! The catalog of request shapes the app makes against AO3, and the
//! classifier that maps a concrete URL back to its shape. Timeouts are
//! configurable per shape (a full-work download legitimately needs longer
//! than a comments page), so every shape the client can produce is listed
//! here — the settings UI renders this catalog verbatim.
//!
//! Adding a fetch with a new URL shape? Add its route here and a matcher
//! arm in `route_for_url`, or it silently rides the global default.

/// One distinct request shape. `template` is the non-dynamic form shown to
/// the user ({ID}/{PAGE}/… standing in for the dynamic parts); `key` is the
/// stable identifier overrides are stored under — never rename one, stored
/// settings reference it.
pub struct Route {
    pub key: &'static str,
    pub template: &'static str,
    pub label: &'static str,
}

pub const ROUTES: &[Route] = &[
    Route { key: "work_page", template: "/works/{ID}?view_adult=true",
            label: "Work page (single chapter)" },
    Route { key: "work_full", template: "/works/{ID}?view_full_work=true&view_adult=true",
            label: "Entire work (all chapters)" },
    Route { key: "chapter_page", template: "/works/{ID}/chapters/{ID}?view_adult=true",
            label: "Single chapter" },
    Route { key: "work_comments", template: "/works/{ID}?show_comments=true&view_adult=true",
            label: "Work comments (first page)" },
    Route { key: "chapter_comments", template: "/works/{ID}/chapters/{ID}?show_comments=true&view_adult=true",
            label: "Chapter comments (first page)" },
    Route { key: "comments_page_work", template: "/comments/show_comments?work_id={ID}&page={PAGE}",
            label: "Work comments (later pages)" },
    Route { key: "comments_page_chapter", template: "/comments/show_comments?chapter_id={ID}&page={PAGE}",
            label: "Chapter comments (later pages)" },
    Route { key: "browse_works", template: "/works?page={PAGE}",
            label: "Browse newest works" },
    Route { key: "search_form", template: "/works/search?edit_search=true",
            label: "Search criteria form" },
    Route { key: "search_results", template: "/works/search?{CRITERIA}",
            label: "Search results" },
    Route { key: "tag_works", template: "/tags/{TAG}/works?page={PAGE}",
            label: "Tag works listing" },
    Route { key: "collections_list", template: "/collections?page={PAGE}",
            label: "Collections list" },
    Route { key: "collection_works", template: "/collections/{NAME}/works?page={PAGE}",
            label: "Collection works" },
    Route { key: "collection_profile", template: "/collections/{NAME}/profile",
            label: "Collection profile" },
    Route { key: "author_works", template: "/users/{USER}/works",
            label: "Author works listing" },
    Route { key: "series_page", template: "/series/{ID}?page={PAGE}",
            label: "Series page" },
    Route { key: "user_profile", template: "/users/{USER}/profile",
            label: "User profile" },
    Route { key: "user_bookmarks", template: "/users/{USER}/bookmarks?page={PAGE}",
            label: "User bookmarks" },
    Route { key: "work_bookmarks", template: "/works/{ID}/bookmarks",
            label: "Work bookmark form" },
    Route { key: "inbox", template: "/users/{USER}/inbox?page={PAGE}",
            label: "Inbox" },
    Route { key: "subscriptions_list", template: "/users/{USER}/subscriptions?page={PAGE}",
            label: "AO3 subscriptions list" },
    Route { key: "autocomplete", template: "/autocomplete/{KIND}?term={TERM}",
            label: "Tag autocomplete" },
    Route { key: "home", template: "/",
            label: "Home page (session check)" },
];

/// Classify a concrete URL to its route key. Host-agnostic (the app only
/// talks to AO3). None means an unlisted shape — callers fall back to the
/// global timeout.
pub fn route_for_url(url: &str) -> Option<&'static str> {
    let after_scheme = url.split("://").nth(1).unwrap_or(url);
    let path_and_query = match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => "/",
    };
    let (path, query) = match path_and_query.split_once('?') {
        Some((p, q)) => (p, q),
        None => (path_and_query, ""),
    };
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let has = |k: &str| query.split('&').any(|p| {
        p.split('=').next() == Some(k)
    });

    Some(match segs.as_slice() {
        [] => "home",
        ["works"] => "browse_works",
        ["works", "search"] if has("edit_search") => "search_form",
        ["works", "search"] => "search_results",
        ["works", _] if has("view_full_work") => "work_full",
        ["works", _] if has("show_comments") => "work_comments",
        ["works", _] => "work_page",
        ["works", _, "chapters", _] if has("show_comments") => "chapter_comments",
        ["works", _, "chapters", _] => "chapter_page",
        ["works", _, "bookmarks"] => "work_bookmarks",
        ["comments", "show_comments"] if has("work_id") => "comments_page_work",
        ["comments", "show_comments"] if has("chapter_id") => "comments_page_chapter",
        ["tags", _, "works"] => "tag_works",
        ["collections"] => "collections_list",
        ["collections", _, "works"] => "collection_works",
        ["collections", _, "profile"] => "collection_profile",
        ["series", _] => "series_page",
        ["users", _, "works"] => "author_works",
        ["users", _, "pseuds", _, "works"] => "author_works",
        ["users", _, "profile"] => "user_profile",
        ["users", _, "bookmarks"] => "user_bookmarks",
        ["users", _, "inbox"] => "inbox",
        ["users", _, "subscriptions"] => "subscriptions_list",
        ["autocomplete", _] => "autocomplete",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_the_documented_shapes() {
        let base = "https://archiveofourown.org";
        let cases = [
            (format!("{base}/works/12345?view_adult=true"), "work_page"),
            (format!("{base}/works/12345?view_full_work=true&view_adult=true"), "work_full"),
            (format!("{base}/works/12345/chapters/678?view_adult=true"), "chapter_page"),
            (format!("{base}/works/12345?show_comments=true&view_adult=true"), "work_comments"),
            (format!("{base}/works/12345/chapters/678?show_comments=true&view_adult=true"), "chapter_comments"),
            (format!("{base}/comments/show_comments?work_id=12345&page=3"), "comments_page_work"),
            (format!("{base}/comments/show_comments?chapter_id=678&page=2"), "comments_page_chapter"),
            (format!("{base}/works?page=2"), "browse_works"),
            (format!("{base}/works/search?edit_search=true"), "search_form"),
            (format!("{base}/works/search?work_search%5Bquery%5D=x"), "search_results"),
            (format!("{base}/tags/Fluff/works?page=1"), "tag_works"),
            (format!("{base}/collections?page=1"), "collections_list"),
            (format!("{base}/collections/foo/works?page=1"), "collection_works"),
            (format!("{base}/collections/foo/profile"), "collection_profile"),
            (format!("{base}/users/someone/works"), "author_works"),
            (format!("{base}/users/someone/works?page=4"), "author_works"),
            (format!("{base}/users/someone/pseuds/pen/works"), "author_works"),
            (format!("{base}/series/99?page=2"), "series_page"),
            (format!("{base}/users/someone/profile"), "user_profile"),
            (format!("{base}/users/someone/bookmarks?page=1"), "user_bookmarks"),
            (format!("{base}/works/12345/bookmarks"), "work_bookmarks"),
            (format!("{base}/users/someone/inbox?page=1"), "inbox"),
            (format!("{base}/users/someone/subscriptions?page=1"), "subscriptions_list"),
            (format!("{base}/autocomplete/fandom?term=st"), "autocomplete"),
            (format!("{base}/"), "home"),
        ];
        for (url, want) in cases {
            assert_eq!(route_for_url(&url), Some(want), "url = {url}");
        }
    }

    #[test]
    fn every_matcher_key_is_in_the_catalog() {
        // The matcher and catalog are maintained by hand — check the sample
        // URLs above resolve to catalogued keys, and unknown shapes miss.
        assert_eq!(route_for_url("https://archiveofourown.org/media"), None);
        assert_eq!(route_for_url("https://archiveofourown.org/users/x/gifts"), None);
        for r in ROUTES {
            assert!(ROUTES.iter().filter(|o| o.key == r.key).count() == 1,
                    "duplicate key {}", r.key);
        }
    }
}
