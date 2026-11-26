import Foundation
import Observation

/// Form state for the Wattpad tab: the site's story search with the
/// filters beside its results — nothing it cannot send. The option lists
/// (length, last updated) come from the adapter's declaration in the
/// core; the layout and controls are this platform's. `query()` packs
/// the values into the generic `SearchQuery` the core hands to the
/// adapter. The site offers no sort.
@Observable
@MainActor
final class WattpadSearchModel {
    static let sourceID = "wattpad"

    var text = ""
    /// Tags, separated by spaces or commas; the site searches them as
    /// `#tag` words.
    var tags = ""
    /// "any", or one of the site's part-count bands.
    var length = "any"
    /// "any", or the site's window in days.
    var updated = "any"
    var completeOnly = false

    /// The adapter's declared fields, read once for the option tables.
    private(set) var schema: SearchSchema?

    func loadIfNeeded(_ appState: AppState) {
        guard schema == nil else { return }
        schema = appState.bridge.searchSchema(source: Self.sourceID, languageCandidates: [])
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

    var activeFilterCount: Int {
        var n = 0
        if !tags.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        if length != "any" { n += 1 }
        if updated != "any" { n += 1 }
        if completeOnly { n += 1 }
        return n
    }

    func clear() {
        tags = ""; length = "any"; updated = "any"; completeOnly = false
    }

    /// The form as the adapter's query. Keys are the Wattpad adapter's
    /// field keys (core/src/source/wattpad/search.rs).
    func query() -> SearchQuery {
        var values: [QueryValue] = []
        func put(_ key: String, _ v: FieldValue?) {
            if let v { values.append(QueryValue(key: key, value: v)) }
        }
        let t = text.trimmingCharacters(in: .whitespaces)
        put("query", t.isEmpty ? nil : .text(value: t))
        let g = tags.trimmingCharacters(in: .whitespaces)
        put("tags", g.isEmpty ? nil : .text(value: g))
        put("length", .choice(value: length))
        put("updated", .choice(value: updated))
        put("complete", completeOnly ? .bool(value: true) : nil)
        return SearchQuery(source: Self.sourceID, schemaVersion: schema?.version ?? 0, values: values,
                           sortColumn: nil, sortDirection: nil)
    }

    /// Go: run the form through the shared search model (results pane,
    /// paging, progress banner are the works-results standard).
    func run(_ search: SearchModel, appState: AppState) {
        loadIfNeeded(appState)
        search.runSourceSearch(query(), appState: appState)
    }
}
