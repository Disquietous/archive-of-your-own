import Foundation
import Observation

/// Form state for the Hentai Foundry tab: the site's story search form,
/// field for field — nothing it cannot send. The option lists (search
/// scope, categories, content levels and kinds) come from the adapter's
/// declaration in the core; the layout and controls are this platform's.
/// The site has no sort parameter (order is the reader's account
/// setting), so there is none here: results are sorted in the app.
/// `query()` packs the values into the generic `SearchQuery` the core
/// hands to the adapter.
@Observable
@MainActor
final class HentaiFoundrySearchModel {
    static let sourceID = "hentaifoundry"

    /// One graded content kind: no limit ("") / at most / at least, and
    /// the level the limit is set at.
    struct Level: Equatable {
        var limit = ""
        var level = "3"
    }

    var text = ""
    var searchIn = "all"
    var lengthCompare = ">"
    var length = ""
    var lengthUnit = "words"
    /// "" = any, else the form's 0 (incomplete) / 1 (complete).
    var status = ""
    var category = ""
    var includeSubcategories = false
    var username = ""
    /// The site's own names for what is typed in Username (its "Limit
    /// User" lookup: up to ten, by prefix).
    private(set) var usernameSuggestions: [String] = []
    @ObservationIgnored private var suggestionsTask: Task<Void, Never>?
    /// A name just picked from the list is not looked up again.
    @ObservationIgnored private var pickedUsername = ""
    /// Keyed by the adapter's graded kind (nudity, violence, …).
    var levels: [String: Level] = [:]
    /// Yes/no content kinds the results must have, and must not have.
    var required: [String] = []
    var blocked: [String] = []
    var showRating = false

    static let gradedKinds = ["nudity", "violence", "profanity", "racism", "sex", "spoilers"]

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

    /// The site's own name for a graded kind ("Sexual content").
    func kindLabel(_ kind: String) -> String {
        field("\(kind)_limit")?.label ?? kind.capitalized
    }

    /// none → required → blocked → none.
    func cycle(_ flag: String) {
        if required.contains(flag) {
            required.removeAll { $0 == flag }
            blocked.append(flag)
        } else if blocked.contains(flag) {
            blocked.removeAll { $0 == flag }
        } else {
            required.append(flag)
        }
    }

    var activeFilterCount: Int {
        var n = 0
        for value in [length, status, category, username] where !value.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        n += levels.values.filter { !$0.limit.isEmpty }.count
        n += required.count + blocked.count
        return n
    }

    /// Look up names for the Username field as it is typed.
    func usernameChanged(_ appState: AppState) {
        suggestionsTask?.cancel()
        let query = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query != pickedUsername else { usernameSuggestions = []; return }
        pickedUsername = ""
        let bridge = appState.bridge
        suggestionsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let hits = (try? await bridge.searchUsers(source: Self.sourceID, query: query)) ?? []
            guard !Task.isCancelled, username.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            usernameSuggestions = hits.map(\.username).filter { $0 != query }
        }
    }

    func pickUsername(_ name: String) {
        suggestionsTask?.cancel()
        pickedUsername = name
        usernameSuggestions = []
        username = name
    }

    func dismissUsernameSuggestions() {
        suggestionsTask?.cancel()
        usernameSuggestions = []
    }

    func clear() {
        length = ""; status = ""; category = ""; includeSubcategories = false; username = ""
        levels = [:]; required = []; blocked = []
    }

    /// The form as the adapter's query. Keys are the Hentai Foundry
    /// adapter's field keys (core/src/source/hentaifoundry/search.rs).
    func query() -> SearchQuery {
        var values: [QueryValue] = []
        func put(_ key: String, _ v: FieldValue?) {
            if let v { values.append(QueryValue(key: key, value: v)) }
        }
        let t = text.trimmingCharacters(in: .whitespaces)
        put("query", t.isEmpty ? nil : .text(value: t))
        put("search_in", .choice(value: searchIn))
        let words = length.filter { $0 != "," && !$0.isWhitespace }
        if let n = Double(words), n >= 0 {
            put("length_compare", .choice(value: lengthCompare))
            put("length", .number(value: n))
            put("length_unit", .choice(value: lengthUnit))
        }
        put("status", status.isEmpty ? nil : .choice(value: status))
        if !category.isEmpty {
            put("category", .choice(value: category))
            put("include_sub", includeSubcategories ? .bool(value: true) : nil)
        }
        let u = username.trimmingCharacters(in: .whitespaces)
        put("author", u.isEmpty ? nil : .text(value: u))
        for kind in Self.gradedKinds {
            guard let level = levels[kind], !level.limit.isEmpty else { continue }
            put("\(kind)_limit", .choice(value: level.limit))
            put("\(kind)_level", .choice(value: level.level))
        }
        if !required.isEmpty || !blocked.isEmpty {
            put("flags", .set(include: required, exclude: blocked, mode: nil))
        }
        return SearchQuery(source: Self.sourceID, schemaVersion: schema?.version ?? 0, values: values,
                           sortColumn: nil, sortDirection: nil)
    }

    /// Go: run the form through the shared search model (results pane,
    /// paging, progress banner are the works-results standard).
    func run(_ search: SearchModel, appState: AppState) {
        loadIfNeeded(appState)
        dismissUsernameSuggestions()
        search.runSourceSearch(query(), appState: appState)
    }
}
