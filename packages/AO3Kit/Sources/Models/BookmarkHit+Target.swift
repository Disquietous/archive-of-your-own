import Foundation

/// Target-agnostic accessors for a bookmark hit: a bookmark points at a
/// work or a series, and list rows/filters read the same display fields
/// from whichever is present.
public extension UBookmarkHit {
    var isSeries: Bool { bookmarkType == "series" }

    /// "work:123" / "series:45" — unique per target across a hit list.
    var targetKey: String { "\(bookmarkType):\(targetId)" }

    var displayTitle: String {
        work?.title ?? series?.name ?? ""
    }

    var displayAuthors: [String] {
        work?.authors ?? series?.authors ?? []
    }

    var displaySummary: String {
        work?.summary ?? series?.summary ?? ""
    }

    /// Works carry fandoms; series blurbs don't.
    var displayFandoms: [String] { work?.fandoms ?? [] }

    /// The work's tags across every category; series blurbs carry none.
    var displayWorkTags: [String] {
        guard let work else { return [] }
        return work.relationships + work.characters + work.tags
    }

    var displayWordCount: UInt64 {
        work?.wordCount ?? series?.wordCount ?? 0
    }

    var displayKudos: UInt32 { work?.kudos ?? 0 }

    var displayComplete: Bool {
        work?.complete ?? series?.complete ?? false
    }
}
