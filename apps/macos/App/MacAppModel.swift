import Foundation
import Observation

/// Navigation + selection state for the three-pane reader, mirroring the
/// handoff's state machine. Library data is mock for now; this is the seam
/// where AppState/Rust wiring lands later.
@Observable
final class MacAppModel {
    enum Section: String, CaseIterable {
        case browse, reading, later, history, subscriptions, fandoms, authors,
             bookmarks, downloads, stats, search
    }

    var section: Section = .browse
    var selectedWorkID: String? = "baker"
    var readerOpen = false
    var readerChapter = 0
    var immersive = false
    var query = ""
    var activeTags: Set<String> = []
    var notifsRead = false
    var hideExplicit = UserDefaults.standard.bool(forKey: "hideExplicit") {
        didSet { UserDefaults.standard.set(hideExplicit, forKey: "hideExplicit") }
    }

    // Seeded to match the prototype so the design review state is reproducible.
    var bookmarks: Set<String> = ["lamplight", "olive", "garden"]
    var kudos: Set<String> = ["baker"]
    var downloaded: Set<String> = Set(MockData.works.filter(\.downloaded).map(\.id))
    var history: [String] = ["baker", "lamplight"]
    var progressMap: [String: ReadingProgress] = [
        "baker": ReadingProgress(chapter: 4, pct: 0.38),
        "olive": ReadingProgress(chapter: 17, pct: 0.71),
    ]

    let works = MockData.works

    var selectedWork: Work? {
        works.first { $0.id == selectedWorkID }
    }

    // MARK: - Intents (names follow the prototype's ctx)

    func goSection(_ s: Section) {
        section = s
        readerOpen = false
        if s == .subscriptions { notifsRead = false }
    }

    func selectWork(_ id: String) {
        selectedWorkID = id
        readerOpen = false
    }

    func openReader(_ id: String, chapter: Int) {
        selectedWorkID = id
        readerChapter = chapter
        readerOpen = true
        pushHistory(id)
    }

    func closeReader() {
        readerOpen = false
        immersive = false
    }

    func openFandom(_ fandom: MacFandom) {
        query = fandom.short
        goSection(.search)
    }

    func pushHistory(_ id: String) {
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
    }

    func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    func progress(for work: Work) -> Double {
        progressMap[work.id]?.pct ?? work.initialProgress
    }

    /// Book-level progress is monotonic — it never decreases.
    func recordProgress(workID: String, chapter: Int, chapterPct: Double, totalChapters: Int) {
        let bookPct = (Double(chapter) + chapterPct) / Double(totalChapters)
        let previous = progressMap[workID]?.pct ?? 0
        progressMap[workID] = ReadingProgress(chapter: chapter + 1, pct: max(bookPct, previous))
    }

    // MARK: - Lists

    var currentlyReading: [Work] {
        works.filter { progress(for: $0) > 0 }
    }

    func works(for section: Section) -> [Work] {
        switch section {
        case .reading: currentlyReading
        case .later: works.filter { ["olive", "salt", "letters", "moor", "wireframe", "garden"].contains($0.id) }
        case .history: history.compactMap { id in works.first { $0.id == id } }
        case .bookmarks: works.filter { bookmarks.contains($0.id) }
        case .downloads: works.filter { downloaded.contains($0.id) }
        default: works
        }
    }

    var searchResults: [Work] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return works.filter { w in
            let hay = "\(w.title) \(w.author) \(w.fandom) \(w.tags.joined(separator: " ")) \(w.relationship)".lowercased()
            let matchesQuery = q.isEmpty || hay.contains(q)
            let matchesTags = activeTags.allSatisfy { w.tags.contains($0) }
            let passesRating = !hideExplicit || w.rating != .explicit
            return matchesQuery && matchesTags && passesRating
        }
    }

    var unreadCount: Int {
        notifsRead ? 0 : MacMockData.subUpdates.filter(\.unread).count
    }
}

// MARK: - Aux mock data (mirrors prototype data.jsx; placeholder until Rust wiring)

struct MacCollection: Identifiable {
    let id: String, name: String, count: Int, hue: Int
}

struct MacFandom: Identifiable {
    let name: String, short: String, works: Int, unread: Int, hue: Int
    var id: String { name }
}

struct MacAuthor: Identifiable {
    let id: String, handle: String, works: Int, subs: String, fandoms: String, notify: Bool, hue: Int
}

struct MacSubUpdate: Identifiable {
    enum Kind: String { case work, author, collection, series }
    let id: String, type: Kind, target: String
    var by: String? = nil
    let action: String, time: String
    var unread = false
    var detail: String? = nil
    var workID: String? = nil
    let hue: Int
}

struct MacSubscription: Identifiable {
    let id: String, name: String
    var by: String? = nil
    let status: String
    var notify: Bool
}

enum MacMockData {
    static let collections = [
        MacCollection(id: "comfort", name: "Comfort reads", count: 14, hue: 40),
        MacCollection(id: "longfic", name: "Long-haul WIPs", count: 6, hue: 200),
        MacCollection(id: "rainy", name: "Rainy day", count: 9, hue: 150),
    ]

    static let popularTags = [
        "Slow Burn", "Hurt/Comfort", "Fluff", "Angst with a Happy Ending",
        "Found Family", "Enemies to Lovers", "Case Fic", "Epistolary",
        "Mythology Retelling", "Gothic",
    ]

    static let subUpdates = [
        MacSubUpdate(id: "u1", type: .work, target: "Salt and Static", by: "harborlights", action: "New chapter — Ch. 23 posted", time: "2h ago", unread: true, workID: "salt", hue: 320),
        MacSubUpdate(id: "u2", type: .author, target: "sixpomegranateseeds", action: "Posted a new work in Greek Mythology", time: "5h ago", unread: true, detail: "“A Bargain Struck in Spring”", hue: 25),
        MacSubUpdate(id: "u3", type: .work, target: "What the Olive Branch Knew", by: "sixpomegranateseeds", action: "New chapter — Ch. 25 posted", time: "Yesterday", unread: true, workID: "olive", hue: 25),
        MacSubUpdate(id: "u4", type: .collection, target: "Rainy Day Reads", action: "3 works added", time: "Yesterday", detail: "by curator quietfeathers", hue: 150),
        MacSubUpdate(id: "u5", type: .series, target: "The Lamplight Letters", action: "New entry added — part 4 of 5", time: "2 days ago", hue: 95),
        MacSubUpdate(id: "u6", type: .author, target: "thornfieldlight", action: "Posted a new work in Jane Eyre", time: "3 days ago", detail: "“Ashes, and What Grew After”", hue: 280),
        MacSubUpdate(id: "u7", type: .work, target: "The Moor at Midnight", by: "thornfieldlight", action: "Work marked complete", time: "5 days ago", workID: "moor", hue: 280),
    ]

    static let subscriptions: [(label: String, icon: String, items: [MacSubscription])] = [
        ("Works", "book.closed", [
            MacSubscription(id: "salt", name: "Salt and Static", by: "harborlights", status: "WIP · 22/?", notify: true),
            MacSubscription(id: "olive", name: "What the Olive Branch Knew", by: "sixpomegranateseeds", status: "WIP · 24/30", notify: true),
        ]),
        ("Series", "square.stack", [
            MacSubscription(id: "s_lamp", name: "The Lamplight Letters", status: "4/5 entries", notify: true),
        ]),
        ("Authors", "person", [
            MacSubscription(id: "a_pom", name: "sixpomegranateseeds", status: "12 works", notify: true),
            MacSubscription(id: "a_harbor", name: "harborlights", status: "8 works", notify: true),
            MacSubscription(id: "a_thorn", name: "thornfieldlight", status: "5 works", notify: false),
        ]),
        ("Collections", "folder", [
            MacSubscription(id: "c_rainy", name: "Rainy Day Reads", status: "curated · 41 works", notify: true),
        ]),
    ]

    static let fandoms = [
        MacFandom(name: "Sherlock Holmes — A.C. Doyle", short: "Sherlock Holmes", works: 12840, unread: 24, hue: 40),
        MacFandom(name: "Greek Mythology", short: "Greek Mythology", works: 38210, unread: 112, hue: 25),
        MacFandom(name: "Pride and Prejudice — Austen", short: "Pride and Prejudice", works: 9420, unread: 8, hue: 95),
        MacFandom(name: "Jane Eyre — Brontë", short: "Jane Eyre", works: 3110, unread: 3, hue: 280),
        MacFandom(name: "Arthurian Legend", short: "Arthurian Legend", works: 6730, unread: 17, hue: 200),
        MacFandom(name: "The Secret Garden — Burnett", short: "The Secret Garden", works: 1290, unread: 0, hue: 150),
        MacFandom(name: "Original Work", short: "Original Work", works: 52600, unread: 41, hue: 320),
    ]

    static let authors = [
        MacAuthor(id: "a_pom", handle: "sixpomegranateseeds", works: 12, subs: "4.1k", fandoms: "Greek Myth · Original", notify: true, hue: 25),
        MacAuthor(id: "a_harbor", handle: "harborlights", works: 8, subs: "2.9k", fandoms: "Original Work", notify: true, hue: 320),
        MacAuthor(id: "a_thorn", handle: "thornfieldlight", works: 5, subs: "690", fandoms: "Jane Eyre · Gothic", notify: false, hue: 280),
        MacAuthor(id: "a_marble", handle: "marblestaircase", works: 19, subs: "8.4k", fandoms: "Sherlock Holmes", notify: true, hue: 40),
        MacAuthor(id: "a_quiet", handle: "quietfeathers", works: 7, subs: "1.2k", fandoms: "Austen", notify: true, hue: 95),
    ]

    static let stats = (wordsThisYear: 1_284_000, worksFinished: 47, streakDays: 12,
                        hoursThisMonth: 23, weekly: [42, 31, 55, 28, 64, 47, 38])

    static func fmt(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let v = Double(n) / 1000
        let s = n >= 10000 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return s.replacingOccurrences(of: ".0", with: "") + "k"
    }
}
