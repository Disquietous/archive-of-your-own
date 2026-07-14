import Foundation
import Observation

/// State for the full AO3 search form — mirrors the iOS SearchView contract:
/// the form is fetched from AO3 itself (fetchSearchForm), cached in
/// UserDefaults, and searches are built as raw key/value pairs.
@Observable
final class MacSearchModel {
    var formFields: [UFormField] = []
    var fieldValues: [String: String] = [:]
    var checkboxValues: [String: Set<String>] = [:]
    var isLoadingForm = false
    var formError: String?
    var hasSearched = false
    var showFilters = false

    var primaryField: UFormField? {
        formFields.first { $0.fieldType == "text" && $0.name.contains("[query]") }
    }

    /// Everything except the primary query and hidden fields.
    var filterFields: [UFormField] {
        formFields.filter { $0.name != primaryField?.name && $0.fieldType != "hidden" }
    }

    var queryText: String {
        get { primaryField.flatMap { fieldValues[$0.name] } ?? "" }
        set { if let field = primaryField { fieldValues[field.name] = newValue } }
    }

    func setQuery(_ text: String) {
        if let field = primaryField {
            fieldValues[field.name] = text
        } else {
            // Form not loaded yet — AO3's canonical query key.
            fieldValues["work_search[query]"] = text
        }
    }

    // MARK: - Form loading (cache-first, same cache key as iOS)

    @MainActor
    func loadFormIfNeeded(_ appState: AppState) async {
        guard formFields.isEmpty else { return }
        if let cached = Self.loadCachedForm() {
            formFields = cached
            return
        }
        guard appState.bridge.isInitialized, !appState.bridge.networkBlocked else { return }
        isLoadingForm = true
        formError = nil
        do {
            let fields = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                try await appState.bridge.fetchSearchForm()
            }
            formFields = fields
            Self.cacheForm(fields)
        } catch {
            if !appState.searchTask.isCancelled && !"\(error)".contains("cancelled") {
                formError = error.localizedDescription
            }
        }
        isLoadingForm = false
    }

    func performSearch(_ appState: AppState) {
        hasSearched = true
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
        Task { await appState.searchAO3Raw(keys: keys, values: values) }
    }

    func clearFilters() {
        let query = queryText
        fieldValues = [:]
        checkboxValues = [:]
        setQuery(query)
    }

    // MARK: - Cache (format-compatible with the iOS implementation)

    private static func cacheForm(_ fields: [UFormField]) {
        let data: [[String: Any]] = fields.map { f in
            [
                "name": f.name, "label": f.label, "fieldType": f.fieldType,
                "placeholder": f.placeholder,
                "options": f.options.map { ["value": $0.value, "label": $0.label, "selected": $0.selected] },
            ]
        }
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(json, forKey: "cachedSearchForm")
        }
    }

    private static func loadCachedForm() -> [UFormField]? {
        guard let json = UserDefaults.standard.data(forKey: "cachedSearchForm"),
              let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
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
