import SafariServices
import SwiftUI
import UIKit

/// Opens URLs that leave the app in the user's chosen way. The choice is
/// stored in the encrypted DB under the same "externalURLApp" pref the
/// macOS app uses: empty means the system default handler (Safari or the
/// user's default browser), "inapp" means an in-app Safari view. Either
/// way the page travels over that browser's own connection, not this
/// app's private one — the settings caption says so.
enum ExternalLinkOpener {
    static let prefKey = "externalURLApp"
    static let inAppValue = "inapp"

    enum Mode: String, CaseIterable {
        case system = ""
        case inApp = "inapp"

        var label: String {
            switch self {
            case .system: "Default Browser"
            case .inApp: "In-App Browser"
            }
        }
    }

    @MainActor
    static func mode(_ bridge: RustBridge) -> Mode {
        Mode(rawValue: bridge.getPref(key: prefKey) ?? "") ?? .system
    }

    @MainActor
    static func setMode(_ mode: Mode, _ bridge: RustBridge) {
        bridge.setPref(key: prefKey, value: mode.rawValue)
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

    /// Open `url` per the stored preference. Only http(s) URLs can go to
    /// the in-app browser; anything else falls back to the system.
    @MainActor
    static func open(_ url: URL, bridge: RustBridge) {
        if mode(bridge) == .inApp, let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", let presenter = topViewController() {
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = nil
            presenter.present(safari, animated: true)
            return
        }
        UIApplication.shared.open(url)
    }

    /// The topmost presented view controller of the active scene — where
    /// a modal Safari view can be presented from.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
