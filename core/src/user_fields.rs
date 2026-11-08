//! What a source says about a user, and what the app calls it.
//!
//! A user's identity is the `users` row (source, source id, display
//! name). Everything else a source reports — avatar, bio, counts,
//! moderation state — is a *source property*, stored under the source's
//! own name in `user_source_properties`. The UI never sees those names:
//! `UserField` is the app's vocabulary, and each source's table here maps
//! its names onto it. A property with no mapping is kept but not shown.

use crate::models::SOURCE_AO3;

/// The app-global user attributes the UI knows about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UserField {
    ProfileUrl,
    AvatarUrl,
    /// Free-text self-description (AO3 bio, ScribbleHub "About"), as a
    /// ContentBlock JSON array.
    Info,
    Joined,
    Location,
    Birthday,
    /// What the user has published: AO3 works, ScribbleHub series.
    Works,
    Series,
    Bookmarks,
    Collections,
    Gifts,
    Followers,
    Following,
    Readers,
    Words,
    Views,
    Reviews,
    Comments,
    LastActive,
    /// Signed-in viewer has blocked / muted this user (AO3 account features).
    Blocked,
    Muted,
    /// JSON array of the account's other names (AO3 pseuds).
    Pseuds,
    /// The source's numeric id for the user when it differs from the key
    /// (AO3's subscribable id).
    NumericId,
}

/// One source's vocabulary: native property name, the global field it
/// means, the registry label, and whether it is numeric.
pub struct Mapping {
    pub name: &'static str,
    pub field: UserField,
    pub label: &'static str,
    pub numeric: bool,
}

const fn m(name: &'static str, field: UserField, label: &'static str, numeric: bool) -> Mapping {
    Mapping { name, field, label, numeric }
}

/// AO3's native property names, as `parser::profile` and the sighting
/// paths write them.
pub const AO3: &[Mapping] = &[
    m("profile_url", UserField::ProfileUrl, "Profile", false),
    m("avatar_url", UserField::AvatarUrl, "Icon", false),
    m("bio", UserField::Info, "Bio", false),
    m("joined", UserField::Joined, "Joined", false),
    m("location", UserField::Location, "Location", false),
    m("birthday", UserField::Birthday, "Birthday", false),
    m("works", UserField::Works, "Works", true),
    m("series", UserField::Series, "Series", true),
    m("bookmarks", UserField::Bookmarks, "Bookmarks", true),
    m("collections", UserField::Collections, "Collections", true),
    m("gifts", UserField::Gifts, "Gifts", true),
    m("blocked", UserField::Blocked, "Blocked", false),
    m("muted", UserField::Muted, "Muted", false),
    m("pseuds", UserField::Pseuds, "Pseuds", false),
    m("numeric_id", UserField::NumericId, "User id", false),
];

/// ScribbleHub's native names, as `source::scribblehub::parse` writes them.
pub const SCRIBBLEHUB: &[Mapping] = &[
    m("profile_url", UserField::ProfileUrl, "Profile", false),
    m("avatar", UserField::AvatarUrl, "Avatar", false),
    m("about", UserField::Info, "About", false),
    m("joined", UserField::Joined, "Joined", false),
    m("location", UserField::Location, "Location", false),
    m("birthday", UserField::Birthday, "Birthday", false),
    m("series", UserField::Works, "Series", true),
    m("followers", UserField::Followers, "Followers", true),
    m("following", UserField::Following, "Following", true),
    m("readers", UserField::Readers, "Readers", true),
    m("total_words", UserField::Words, "Total words", true),
    m("total_pageviews", UserField::Views, "Total pageviews", true),
    m("reviews_received", UserField::Reviews, "Reviews received", true),
    m("comments", UserField::Comments, "Comments", true),
    m("last_active", UserField::LastActive, "Last active", false),
];

/// Properties AO3 keeps that are not shown anywhere but drive flows.
pub const AO3_BLOCK_RECORD: &str = "block_record_id";
pub const AO3_MUTE_RECORD: &str = "mute_record_id";
/// When the user's profile page was last fetched (every source).
pub const PROFILE_FETCHED_AT: &str = "profile_fetched_at";

pub fn mappings(source: &str) -> &'static [Mapping] {
    match source {
        SOURCE_AO3 => AO3,
        "scribblehub" => SCRIBBLEHUB,
        _ => &[],
    }
}

/// The native name a source uses for a global field, if it has one.
pub fn native_name(source: &str, field: UserField) -> Option<&'static str> {
    mappings(source).iter().find(|m| m.field == field).map(|m| m.name)
}

/// The global field a source's native property means, if any.
pub fn field_of(source: &str, name: &str) -> Option<UserField> {
    mappings(source).iter().find(|m| m.name == name).map(|m| m.field)
}

/// Registry label and value type for a native property; unmapped
/// properties register under their own name as text.
pub fn registry_entry(source: &str, name: &str) -> (String, &'static str) {
    match mappings(source).iter().find(|m| m.name == name) {
        Some(m) => (m.label.to_string(), if m.numeric { "num" } else { "text" }),
        None => (name.to_string(), "text"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_source_maps_one_name_per_field() {
        for (source, table) in [("ao3", AO3), ("scribblehub", SCRIBBLEHUB)] {
            let mut seen = std::collections::HashSet::new();
            for m in table {
                assert!(seen.insert(m.field), "{source} maps {:?} twice", m.field);
            }
            assert_eq!(native_name(source, UserField::ProfileUrl), Some("profile_url"));
        }
        assert_eq!(field_of("scribblehub", "series"), Some(UserField::Works));
        assert_eq!(field_of("ao3", "series"), Some(UserField::Series));
        assert_eq!(registry_entry("scribblehub", "gender"), ("gender".to_string(), "text"));
    }
}
