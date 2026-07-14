import Foundation
import Observation

/// State for AO3 search: the criteria form (scraped from AO3, persisted in
/// the encrypted database, re-scraped on demand) and paged results shown in
/// the reading pane.
@Observable
final class MacSearchModel {
    /// Stable session key so the form survives launches in the DB cache table.
    private static let dbSessionID = "persistent"
    private static let dbFormKey = "searchFormFields"
    /// AO3's search page size — a short page means we're on the last one.
    private static let pageSize = 20

    var formFields: [UFormField] = []
    var fieldValues: [String: String] = [:]
    var checkboxValues: [String: Set<String>] = [:]
    var isLoadingForm = false
    var formError: String?
    var hasSearched = false

    /// What the current results represent — the form's criteria, or a tag
    /// (fandom card / tag pill). Pagination re-runs whichever is active.
    enum ActiveQuery {
        case form(keys: [String], values: [String])
        case tag(String)
    }

    var activeQuery: ActiveQuery?
    var currentPage: UInt32 = 1
    var lastPageCount = 0
    var hasNextPage: Bool { lastPageCount >= Self.pageSize }

    var primaryField: UFormField? {
        formFields.first { $0.fieldType == "text" && $0.name.contains("[query]") }
    }

    /// Everything except the primary query and hidden fields.
    var filterFields: [UFormField] {
        formFields.filter { $0.name != primaryField?.name && $0.fieldType != "hidden" }
    }

    var queryText: String {
        get { primaryField.flatMap { fieldValues[$0.name] } ?? fieldValues["work_search[query]"] ?? "" }
        set {
            let key = primaryField?.name ?? "work_search[query]"
            fieldValues[key] = newValue
        }
    }

    func setQuery(_ text: String) {
        queryText = text
    }

    var activeFilterCount: Int {
        let fields = fieldValues.filter { $0.key != primaryField?.name && !$0.value.isEmpty }.count
        let checkboxes = checkboxValues.reduce(0) { $0 + $1.value.count }
        return fields + checkboxes
    }

    // MARK: - Form: database-first, scraped from AO3 on demand

    @MainActor
    func loadFormIfNeeded(_ appState: AppState) async {
        guard formFields.isEmpty else { return }
        if let json = appState.bridge.getSessionCache(key: Self.dbFormKey, sessionId: Self.dbSessionID),
           let fields = Self.decodeForm(json), !fields.isEmpty {
            formFields = fields
            return
        }
        await scrapeForm(appState)
    }

    /// Re-scrape the criteria fields from AO3 and persist them (header button).
    @MainActor
    func scrapeForm(_ appState: AppState) async {
        guard appState.bridge.isInitialized, !appState.bridge.networkBlocked else {
            formError = "Connect first to load the search fields from AO3."
            return
        }
        guard !isLoadingForm else { return }
        isLoadingForm = true
        formError = nil
        do {
            let fields = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                try await appState.bridge.fetchSearchForm()
            }
            formFields = fields
            if let json = Self.encodeForm(fields) {
                appState.bridge.setSessionCache(key: Self.dbFormKey, data: json, sessionId: Self.dbSessionID)
            }
        } catch {
            if !appState.searchTask.isCancelled && !"\(error)".contains("cancelled") {
                formError = error.localizedDescription
            }
        }
        isLoadingForm = false
    }

    // MARK: - Searching & pagination (page fetches replace results)

    @MainActor
    func performSearch(_ appState: AppState) {
        var keys: [String] = []
        var values: [String] = []
        for (name, value) in fieldValues where !value.isEmpty {
            keys.append(name)
            values.append(value)
        }
        for (name, selected) in checkboxValues {
            for value in selected {
                keys.append(name)
                values.append(value)
            }
        }
        activeQuery = .form(keys: keys, values: values)
        Task { await fetch(page: 1, appState: appState) }
    }

    @MainActor
    func startTagQuery(_ tag: String, appState: AppState) {
        activeQuery = .tag(tag)
        Task { await fetch(page: 1, appState: appState) }
    }

    @MainActor
    func goToPage(_ page: UInt32, appState: AppState) {
        guard page >= 1, activeQuery != nil, !appState.isSearching else { return }
        Task { await fetch(page: page, appState: appState) }
    }

    @MainActor
    private func fetch(page: UInt32, appState: AppState) async {
        guard let query = activeQuery else { return }
        hasSearched = true
        appState.isSearching = true
        appState.searchError = nil
        do {
            let summaries = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                switch query {
                case .form(let keys, let values):
                    return try await appState.bridge.searchWorksRaw(keys: keys, values: values, page: page)
                case .tag(let tag):
                    return try await appState.bridge.searchByTag(tag, page: page)
                }
            }
            appState.searchResults = summaries.map(AppState.workFromSummary)
            currentPage = page
            lastPageCount = summaries.count
        } catch {
            if !appState.searchTask.isCancelled && !"\(error)".contains("cancelled") {
                appState.searchError = error.localizedDescription
            }
        }
        appState.isSearching = false
    }

    func clearFilters() {
        let query = queryText
        fieldValues = [:]
        checkboxValues = [:]
        setQuery(query)
    }

    // MARK: - Form JSON (same shape the iOS cache uses)

    private static func encodeForm(_ fields: [UFormField]) -> String? {
        let data: [[String: Any]] = fields.map { f in
            [
                "name": f.name, "label": f.label, "fieldType": f.fieldType,
                "placeholder": f.placeholder,
                "options": f.options.map { ["value": $0.value, "label": $0.label, "selected": $0.selected] },
            ]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private static func decodeForm(_ json: String) -> [UFormField]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let fields = arr.compactMap { dict -> UFormField? in
            guard let name = dict["name"] as? String,
                  let label = dict["label"] as? String,
                  let fieldType = dict["fieldType"] as? String,
                  let placeholder = dict["placeholder"] as? String,
                  let optArr = dict["options"] as? [[String: Any]] else { return nil }
            let options = optArr.compactMap { o -> UFormOption? in
                guard let value = o["value"] as? String,
                      let label = o["label"] as? String,
                      let selected = o["selected"] as? Bool else { return nil }
                return UFormOption(value: value, label: label, selected: selected)
            }
            return UFormField(name: name, label: label, fieldType: fieldType, placeholder: placeholder, options: options)
        }
        return fields.isEmpty ? nil : fields
    }
}
