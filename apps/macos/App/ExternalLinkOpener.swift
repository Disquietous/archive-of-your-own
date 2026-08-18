import AppKit

/// Opens URLs that leave the app in the user's chosen application.
/// The choice is a bundle identifier stored in the encrypted DB under
/// the "externalURLApp" pref; empty or absent means the system default
/// handler. A chosen app that's since been uninstalled falls back to
/// the system default rather than dropping the click.
enum ExternalLinkOpener {
    static let prefKey = "externalURLApp"

    /// An app registered with Launch Services as an https handler.
    struct BrowserApp: Identifiable {
        let id: String  // bundle identifier
        let name: String
        let appURL: URL
    }

    /// Every installed app that can open https URLs, name-sorted.
    static func installedBrowsers() -> [BrowserApp] {
        guard let probe = URL(string: "https://archiveofourown.org") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .compactMap { url -> BrowserApp? in
                guard let id = Bundle(url: url)?.bundleIdentifier,
                      seen.insert(id).inserted else { return nil }
                let name = FileManager.default.displayName(atPath: url.path)
                return BrowserApp(id: id, name: name, appURL: url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The .link attribute value from a TextKit click — URL or String.
    static func url(from link: Any) -> URL? {
        if let url = link as? URL { return url }
        if let s = link as? String { return URL(string: s) }
        return nil
    }

    // MARK: - AO3 entity URLs

    static func ao3WorkURL(_ id: String) -> URL? {
        URL(string: "https://archiveofourown.org/works/\(id)")
    }

    static func ao3UserURL(_ username: String) -> URL? {
        URL(string: "https://archiveofourown.org/users/\(username)")
    }

    static func ao3CollectionURL(_ name: String) -> URL? {
        URL(string: "https://archiveofourown.org/collections/\(name)")
    }

    /// AO3's tag-in-URL substitutions (mirrors the core's ao3_tag_encode),
    /// then percent-encoding for whatever remains.
    static func ao3TagURL(_ tag: String) -> URL? {
        let substituted = tag
            .replacingOccurrences(of: "/", with: "*s*")
            .replacingOccurrences(of: "&", with: "*a*")
            .replacingOccurrences(of: ".", with: "*d*")
        let encoded = substituted.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? substituted
        return URL(string: "https://archiveofourown.org/tags/\(encoded)/works")
    }

    static func open(_ url: URL, bridge: RustBridge) {
        let chosen = bridge.getPref(key: prefKey) ?? ""
        guard !chosen.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
