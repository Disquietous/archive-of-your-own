import SwiftUI

struct Work: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let fandom: String
    let relationship: String
    let rating: Rating
    let warnings: String
    let category: String
    let tags: [String]
    let words: Int
    let chapterCount: Int
    let totalChapters: Int
    let complete: Bool
    let kudos: Int
    let hits: Int
    let bookmarks: Int
    let comments: Int
    let published: String
    let updated: String
    let summary: String
    let initialProgress: Double
    let lastChapter: Int?
    let downloaded: Bool
    let content: [ChapterContent]?

    var spineColor: Color {
        Fandom.spineColor(for: fandom)
    }
}

struct ChapterContent: Hashable {
    let title: String
    let paragraphs: [String]
}

struct ReadingProgress: Hashable {
    var chapter: Int
    var pct: Double
}

enum Fandom {
    static let hueMap: [String: Int] = [
        "Sherlock Holmes — A.C. Doyle": 40,
        "Pride and Prejudice — Austen": 95,
        "Greek Mythology": 25,
        "Original Work": 320,
        "Jane Eyre — Brontë": 280,
        "Arthurian Legend": 200,
        "The Secret Garden — Burnett": 150,
    ]

    private static let hueToHex: [Int: String] = [
        40: "C67C63",
        95: "A59145",
        25: "C87973",
        320: "AD7EB8",
        280: "868BCE",
        200: "30A4AA",
        150: "63A471",
        60: "BF8350",
    ]

    static func spineColor(for fandom: String) -> Color {
        let hue = hueMap[fandom] ?? 60
        if let hex = hueToHex[hue] {
            return Color(hex: hex)
        }
        return Color(hex: "BF8350")
    }

    static func spineColorForHue(_ hue: Int, opacity: Double = 1.0) -> Color {
        if let hex = hueToHex[hue] {
            return Color(hex: hex).opacity(opacity)
        }
        let normalizedHue = ((hue % 360) + 360) % 360
        if let hex = hueToHex[normalizedHue] {
            return Color(hex: hex).opacity(opacity)
        }
        return Color(hex: "BF8350").opacity(opacity)
    }
}
