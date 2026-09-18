import Foundation

/// The scraped AO3 works-search form (criteria fields), persisted in the
/// library's session cache so a scrape survives launches and both apps read
/// the same copy. Cache-forever: only an explicit re-scrape replaces it.
enum SearchFormCache {
    private static let sessionID = "persistent"
    private static let key = "searchFormFields"

    @MainActor
    static func load(_ bridge: RustBridge) -> [UFormField]? {
        guard let json = bridge.getSessionCache(key: key, sessionId: sessionID),
              let fields = decode(json), !fields.isEmpty else { return nil }
        return fields
    }

    @MainActor
    static func store(_ fields: [UFormField], _ bridge: RustBridge) {
        guard let json = encode(fields) else { return }
        bridge.setSessionCache(key: key, data: json, sessionId: sessionID)
    }

    // MARK: - JSON

    static func encode(_ fields: [UFormField]) -> String? {
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

    static func decode(_ json: String) -> [UFormField]? {
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
