import Foundation

/// The library's sections — the macOS sidebar entries and the iOS Library
/// hub rows. One shared enum so per-section preferences (sort, filters)
/// persist under the same keys on both platforms.
enum LibrarySection: String, CaseIterable {
    case reading, history, subscriptions, whatsNew, inbox, fandoms, authors,
         bookmarks, downloads, stats, search, authorWorks, readingLists,
         settings,
         /// iOS Browse tab (the latest-works listing) — its own sort/filter slot.
         browse
}
