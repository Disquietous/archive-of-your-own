import SwiftUI

// MARK: - Work Cache Serialization

extension AppState {
    static func workFromSummary(_ s: UWorkSummary) -> Work {
        Work(
            id: String(s.id),
            title: s.title,
            author: s.authors.first ?? "Unknown",
            fandom: s.fandoms.first ?? "Unknown Fandom",
            relationship: s.relationships.first ?? "",
            rating: ratingFromString(s.rating),
            warnings: s.warnings.first ?? "No Archive Warnings Apply",
            category: s.categories.first ?? "",
            tags: s.tags,
            words: Int(s.wordCount),
            chapterCount: Int(s.chapterCount),
            totalChapters: s.totalChapters > 0 ? Int(s.totalChapters) : Int(s.chapterCount),
            complete: s.complete,
            kudos: Int(s.kudos),
            hits: Int(s.hits),
            bookmarks: Int(s.bookmarksCount),
            comments: Int(s.comments),
            published: s.datePublished,
            updated: s.dateUpdated,
            summary: s.summary,
            initialProgress: 0,
            lastChapter: nil,
            downloaded: false,
            content: nil,
            fandoms: s.fandoms,
            series: s.series.map {
                SeriesInfo(
                    seriesID: String($0.seriesId),
                    name: $0.name,
                    part: Int($0.part),
                    prevWorkID: $0.prevWorkId.map(String.init),
                    nextWorkID: $0.nextWorkId.map(String.init)
                )
            },
            fetchedAt: s.fetchedAt
        )
    }

    private static func ratingFromString(_ s: String) -> Rating {
        switch s {
        case "General": .general
        case "Teen": .teen
        case "Mature": .mature
        case "Explicit": .explicit
        default: .general
        }
    }

}
