import Foundation

extension SearchModel {
    func loadSavedSearches(_ appState: AppState) {
        savedSearches = appState.bridge.getSavedSearches()
    }

    /// Persist the current criteria (query, fields, checkboxes) under a name.
    func saveCurrentSearch(named name: String, appState: AppState) {
        NSLog("[saved-search] saveCurrentSearch(%@): %d field(s), %d checkbox group(s)",
              name, fieldValues.count, checkboxValues.count)
        let payload: [String: Any] = [
            "fieldValues": fieldValues,
            "checkboxValues": checkboxValues.mapValues { Array($0) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[saved-search] saveCurrentSearch(%@): JSON encode failed", name)
            return
        }
        appState.bridge.saveSearch(name: name, paramsJson: json)
        loadSavedSearches(appState)
    }

    /// Restore a saved search's criteria into the form (query, fields,
    /// checkboxes) so the user can tweak them before running the search.
    @MainActor
    func applySavedSearch(_ saved: USavedSearch) {
        guard let data = saved.paramsJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        fieldValues = payload["fieldValues"] as? [String: String] ?? [:]
        let boxes = payload["checkboxValues"] as? [String: [String]] ?? [:]
        checkboxValues = boxes.mapValues(Set.init)
    }

    func deleteSavedSearch(_ id: Int64, appState: AppState) {
        appState.bridge.deleteSavedSearch(id)
        loadSavedSearches(appState)
    }

    /// One-line criteria summary for a saved-search row: the query text plus
    /// how many other criteria are set — so same-named searches are tellable
    /// apart without running them.
    static func summary(of saved: USavedSearch) -> String? {
        guard let data = saved.paramsJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = payload["fieldValues"] as? [String: String] ?? [:]
        let boxes = payload["checkboxValues"] as? [String: [String]] ?? [:]
        let query = fields.first { $0.key.hasSuffix("[query]") && !$0.value.isEmpty }?.value
        let filterCount = fields.filter { !$0.key.hasSuffix("[query]") && !$0.value.isEmpty }.count
            + boxes.reduce(0) { $0 + $1.value.count }
        var parts: [String] = []
        if let query { parts.append("“\(query)”") }
        if filterCount > 0 {
            parts.append(filterCount == 1 ? "1 filter" : "\(filterCount) filters")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
