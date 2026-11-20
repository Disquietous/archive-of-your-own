import Foundation
import Observation

/// Form state for the Library tab: one search over every source's cached
/// works. A few fields every work has (text, author, rating, completion,
/// length), a source picker, and any number of conditions on things one
/// source records — a stat or a tag kind — each with the values the
/// library currently holds for it. Nothing here goes to the network.
///
/// Conditions belong to their source: all of one source's conditions
/// must hold for its works, and each source answers only its own, so
/// conditions on several sources find works from all of them.
@Observable
@MainActor
final class LibrarySearchModel {
    /// One condition: a field of one source, and what it must be.
    struct Row: Identifiable {
        let id = UUID()
        let field: LibraryField
        /// A range field's expression as typed (">1500", "1500-10000").
        var range = ""
        /// A pick-list or tag field: any of these values.
        var values: [String] = []
        /// A free-text field: text the value must contain.
        var contains = ""
        /// What a searched value list is narrowed to, and the list itself.
        var filter = ""
        var options: [LibraryFieldValue] = []
    }

    static let ratingLabels = ["General Audiences", "Teen And Up Audiences", "Mature", "Explicit", "Not Rated"]
    /// How many of a field's values the list shows at once; typing
    /// narrows to the rest.
    static let optionLimit: UInt32 = 60
    /// What a range box accepts, shown as its placeholder.
    static let rangeExample = ">1500, 1500-10000, <100000"

    var text = ""
    var title = ""
    var author = ""
    /// Tag names by kind, comma-separated.
    var fandoms = ""
    var characters = ""
    var relationships = ""
    var tags = ""
    /// Date expressions ("< 2 weeks ago", "> 2024-01-01", "2024-06").
    var updated = ""
    var published = ""
    var language = ""
    var fullyDownloaded = false
    /// Picked sources; empty = all.
    var sources: Set<String> = []
    var ratings: Set<String> = []
    /// "" = any, "T" complete, "F" in progress.
    var complete = ""
    /// A range expression on the word count.
    var words = ""
    var rows: [Row] = []

    private(set) var sourceCounts: [LibrarySourceCount] = []
    private(set) var fields: [LibraryField] = []
    private(set) var languages: [String] = []

    /// Read what the library holds now; called each time the form shows,
    /// since works arrive while it is away.
    func load(_ appState: AppState) {
        sourceCounts = appState.bridge.libraryQuerySources()
        fields = appState.bridge.libraryQueryFields()
        languages = appState.bridge.libraryQueryLanguages()
        sources = sources.filter { id in sourceCounts.contains { $0.source == id } }
    }

    func sourceName(_ id: String) -> String {
        sourceCounts.first { $0.source == id }?.name ?? id
    }

    func fieldTitle(_ field: LibraryField) -> String {
        "\(sourceName(field.source)) › \(field.label)"
    }

    func toggleSource(_ id: String) {
        if sources.contains(id) { sources.remove(id) } else { sources.insert(id) }
    }

    func toggleRating(_ label: String) {
        if ratings.contains(label) { ratings.remove(label) } else { ratings.insert(label) }
    }

    // MARK: Conditions

    func addRow(_ field: LibraryField, appState: AppState) {
        var row = Row(field: field)
        switch field.input {
        case .choice:
            // Few enough to show them all.
            row.options = appState.bridge.libraryFieldValues(field)
        case .search:
            row.options = appState.bridge.libraryFieldValues(field, limit: Self.optionLimit)
        case .range, .contains:
            break
        }
        rows.append(row)
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    func setFilter(_ id: UUID, _ filter: String, appState: AppState) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].filter = filter
        rows[index].options = appState.bridge.libraryFieldValues(rows[index].field, filter: filter, limit: Self.optionLimit)
    }

    func setRange(_ id: UUID, _ range: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].range = range
    }

    func setContains(_ id: UUID, _ text: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].contains = text
    }

    /// A range box holding text that does not read as a range.
    static func rangeIsWrong(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !libraryRangeIsValid(text: text)
    }

    func toggleValue(_ id: UUID, _ value: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if let at = rows[index].values.firstIndex(of: value) {
            rows[index].values.remove(at: at)
        } else {
            rows[index].values.append(value)
        }
    }

    var activeFilterCount: Int {
        var n = sources.count + ratings.count + rows.count
        for value in [title, author, fandoms, characters, relationships, tags, updated, published, language, complete, words] where !value.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        if fullyDownloaded { n += 1 }
        return n
    }

    func clear() {
        title = ""; author = ""; fandoms = ""; characters = ""; relationships = ""; tags = ""
        updated = ""; published = ""; language = ""; fullyDownloaded = false
        sources = []; ratings = []; complete = ""; words = ""; rows = []
    }

    // MARK: Query

    func query() -> LibraryQuery {
        LibraryQuery(
            text: text,
            title: title,
            author: author,
            fandoms: fandoms,
            characters: characters,
            relationships: relationships,
            tags: tags,
            updated: updated,
            published: published,
            fullyDownloaded: fullyDownloaded,
            sources: sourceCounts.map(\.source).filter(sources.contains),
            ratings: Self.ratingLabels.filter(ratings.contains),
            complete: complete == "T" ? true : (complete == "F" ? false : nil),
            words: words,
            language: language,
            conditions: rows.map { row in
                LibraryCondition(source: row.field.source, kind: row.field.kind, key: row.field.key,
                                 range: row.field.input == .range ? row.range : "",
                                 values: row.field.input == .choice || row.field.input == .search ? row.values : [],
                                 contains: row.field.input == .contains ? row.contains : "")
            },
            sortColumn: "",
            sortDirection: "",
            excludedSources: [])
    }

    func run(_ search: SearchModel, appState: AppState) {
        search.runLibraryQuery(query(), appState: appState)
    }
}
