import SwiftUI

// MARK: - Work Cache Serialization

extension AppState {
    nonisolated static func workFromSummary(_ s: UWorkSummary) -> Work {
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
            words: Int(s.wordCount ?? 0),
            chapterCount: Int(s.chapterCount),
            totalChapters: s.totalChapters > 0 ? Int(s.totalChapters) : Int(s.chapterCount),
            complete: s.complete,
            kudos: Int(s.kudos ?? 0),
            hits: Int(s.hits ?? 0),
            bookmarks: Int(s.bookmarksCount ?? 0),
            comments: Int(s.comments ?? 0),
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
                    prevWorkExternalID: $0.prevWorkExternalId,
                    nextWorkExternalID: $0.nextWorkExternalId
                )
            },
            fetchedAt: s.fetchedAt,
            url: s.url
        )
    }

    nonisolated private static func ratingFromString(_ s: String) -> Rating {
        switch s {
        case "General": .general
        case "Teen": .teen
        case "Mature": .mature
        case "Explicit": .explicit
        default: .general
        }
    }

}
