import Foundation
import Observation

/// Form state for the ScribbleHub tab: the Series Finder's own fields,
/// laid out by hand for that site. The vocabularies (genres, content
/// warnings, tags, contests, sort columns) come from the adapter's
/// declaration in the core so the id tables live in one place; the layout
/// and controls are this platform's. `query()` packs the values into the
/// generic `SearchQuery` the core hands to the ScribbleHub adapter.
@Observable
@MainActor
final class ScribbleHubSearchModel {
    static let sourceID = "scribblehub"

    /// Include/exclude state of one option set, plus its AND/OR mode.
    struct Picks: Equatable {
        var include: [String] = []
        var exclude: [String] = []
        var mode = "or"

        var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

        /// none → include → exclude → none.
        mutating func cycle(_ id: String, allowExclude: Bool = true) {
            if include.contains(id) {
                include.removeAll { $0 == id }
                if allowExclude { exclude.append(id) }
            } else if exclude.contains(id) {
                exclude.removeAll { $0 == id }
            } else {
                include.append(id)
            }
        }
    }

    struct Bounds: Equatable {
        var min = ""
        var max = ""
        var isEmpty: Bool { min.isEmpty && max.isEmpty }
    }

    var title = ""
    var genres = Picks(mode: "or")
    var contentWarnings = Picks(mode: "and")
    var tags = Picks(mode: "and")
    /// "" = all, else completed / ongoing / hiatus.
    var status = ""
    var contest = ""
    /// Comma-separated fandom names; the adapter resolves them to ids.
    var fandoms = ""
    var chapters = Bounds()
    var chaptersPerWeek = Bounds()
    var favorites = Bounds()
    var rating = Bounds()
    var ratingCount = Bounds()
    var readers = Bounds()
    var reviews = Bounds()
    var pages = Bounds()
    var pageviews = Bounds()
    var totalWords = Bounds()
    var updatedFrom = ""
    var updatedTo = ""
    var sortColumn = "ratings"
    var sortDirection = "desc"
    var showAdvanced = false

    /// The adapter's declared fields, read once for the option tables.
    private(set) var schema: SearchSchema?

    func loadIfNeeded(_ appState: AppState) {
        guard schema == nil else { return }
        schema = appState.bridge.searchSchema(source: Self.sourceID, languageCandidates: [])
        if let sort = schema?.sort {
            sortColumn = sort.defaultColumn
            sortDirection = sort.defaultDirection
        }
    }

    func options(_ key: String) -> [FieldOption] {
        guard let field = schema?.sections.flatMap(\.fields).first(where: { $0.key == key }) else { return [] }
        switch field.kind {
        case .choice(let options, _), .choiceSet(let options, _, _, _): return options
        default: return []
        }
    }

    func label(_ key: String, _ value: String) -> String {
        options(key).first { $0.value == value }?.label ?? value
    }

    var activeFilterCount: Int {
        var n = 0
        for picks in [genres, contentWarnings, tags] where !picks.isEmpty { n += 1 }
        for text in [status, contest, fandoms, updatedFrom, updatedTo] where !text.isEmpty { n += 1 }
        for bounds in [chapters, chaptersPerWeek, favorites, rating, ratingCount, readers, reviews, pages, pageviews, totalWords]
        where !bounds.isEmpty { n += 1 }
        return n
    }

    func clear() {
        genres = Picks(mode: "or"); contentWarnings = Picks(mode: "and"); tags = Picks(mode: "and")
        status = ""; contest = ""; fandoms = ""
        chapters = Bounds(); chaptersPerWeek = Bounds(); favorites = Bounds(); rating = Bounds()
        ratingCount = Bounds(); readers = Bounds(); reviews = Bounds(); pages = Bounds()
        pageviews = Bounds(); totalWords = Bounds()
        updatedFrom = ""; updatedTo = ""
    }

    private static func number(_ s: String) -> Double? {
        let cleaned = s.filter { $0 != "," && !$0.isWhitespace }
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    private static func range(_ b: Bounds) -> FieldValue? {
        let (lo, hi) = (number(b.min), number(b.max))
        guard lo != nil || hi != nil else { return nil }
        return .range(min: lo, max: hi)
    }

    private static func set(_ p: Picks) -> FieldValue? {
        guard !p.isEmpty else { return nil }
        return .set(include: p.include, exclude: p.exclude, mode: p.mode)
    }

    /// The form as the adapter's query. Keys are the ScribbleHub
    /// adapter's field keys (core/src/source/scribblehub/search.rs).
    func query() -> SearchQuery {
        var values: [QueryValue] = []
        func put(_ key: String, _ v: FieldValue?) {
            if let v { values.append(QueryValue(key: key, value: v)) }
        }
        let t = title.trimmingCharacters(in: .whitespaces)
        put("title", t.isEmpty ? nil : .text(value: t))
        put("genres", Self.set(genres))
        put("content_warnings", Self.set(contentWarnings))
        put("tags", Self.set(tags))
        put("status", status.isEmpty ? nil : .choice(value: status))
        put("contest", contest.isEmpty ? nil : .choice(value: contest))
        let f = fandoms.trimmingCharacters(in: .whitespaces)
        put("fandom", f.isEmpty ? nil : .text(value: f))
        put("chapters", Self.range(chapters))
        put("releases_per_week", Self.range(chaptersPerWeek))
        put("favorites", Self.range(favorites))
        put("rating", Self.range(rating))
        put("rating_count", Self.range(ratingCount))
        put("readers", Self.range(readers))
        put("reviews", Self.range(reviews))
        put("pages", Self.range(pages))
        put("pageviews", Self.range(pageviews))
        put("total_words", Self.range(totalWords))
        let from = updatedFrom.trimmingCharacters(in: .whitespaces)
        let to = updatedTo.trimmingCharacters(in: .whitespaces)
        if !from.isEmpty || !to.isEmpty {
            put("last_update", .dateRange(from: from.isEmpty ? nil : from, to: to.isEmpty ? nil : to))
        }
        return SearchQuery(source: Self.sourceID, schemaVersion: schema?.version ?? 0, values: values,
                           sortColumn: sortColumn, sortDirection: sortDirection)
    }

    /// Go: run the form through the shared search model (results pane,
    /// paging, progress banner are the works-results standard).
    func run(_ search: SearchModel, appState: AppState) {
        loadIfNeeded(appState)
        search.runSourceSearch(query(), appState: appState)
    }
}
