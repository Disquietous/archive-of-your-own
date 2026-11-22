import Foundation
import Observation

/// Form state for the Literotica tab: the site's advanced story search,
/// field for field — nothing it cannot send. The option lists (search
/// scope, period, categories, sort) come from the adapter's declaration
/// in the core; the layout and controls are this platform's. `query()`
/// packs the values into the generic `SearchQuery` the core hands to the
/// adapter.
@Observable
@MainActor
final class LiteroticaSearchModel {
    static let sourceID = "literotica"

    var text = ""
    /// What the words are looked for in: text, titles or tags.
    var scope = "text"
    /// "all" = any date, else one of the form's periods.
    var period = "all"
    /// "newer" or "before" (the form's "and Older").
    var timeDirection = "newer"
    var author = ""
    var editorsChoice = false
    var winner = false
    var popular = false
    /// Category ids; empty = the form's "Search all categories".
    var categories: [String] = []
    var sortColumn = "relevancy"
    var sortDirection = "desc"

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

    private func field(_ key: String) -> SearchField? {
        schema?.sections.flatMap(\.fields).first { $0.key == key }
    }

    func options(_ key: String) -> [FieldOption] {
        switch field(key)?.kind {
        case .choice(let options, _), .choiceSet(let options, _, _, _): return options
        default: return []
        }
    }

    func label(_ key: String, _ value: String) -> String {
        options(key).first { $0.value == value }?.label ?? value
    }

    func toggleCategory(_ id: String) {
        if categories.contains(id) { categories.removeAll { $0 == id } } else { categories.append(id) }
    }

    var activeFilterCount: Int {
        var n = 0
        if scope != "text" { n += 1 }
        if period != "all" { n += 1 }
        if !author.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        n += [editorsChoice, winner, popular].filter { $0 }.count
        n += categories.count
        return n
    }

    func clear() {
        scope = "text"; period = "all"; timeDirection = "newer"; author = ""
        editorsChoice = false; winner = false; popular = false
        categories = []
    }

    /// The form as the adapter's query. Keys are the Literotica adapter's
    /// field keys (core/src/source/literotica/search.rs).
    func query() -> SearchQuery {
        var values: [QueryValue] = []
        func put(_ key: String, _ v: FieldValue?) {
            if let v { values.append(QueryValue(key: key, value: v)) }
        }
        let t = text.trimmingCharacters(in: .whitespaces)
        put("query", t.isEmpty ? nil : .text(value: t))
        put("where", .choice(value: scope))
        put("period", .choice(value: period))
        put("time_direction", .choice(value: timeDirection))
        let a = author.trimmingCharacters(in: .whitespaces)
        put("author", a.isEmpty ? nil : .text(value: a))
        put("editors_choice", editorsChoice ? .bool(value: true) : nil)
        put("winner", winner ? .bool(value: true) : nil)
        put("popular", popular ? .bool(value: true) : nil)
        if !categories.isEmpty {
            put("categories", .set(include: categories, exclude: [], mode: nil))
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
