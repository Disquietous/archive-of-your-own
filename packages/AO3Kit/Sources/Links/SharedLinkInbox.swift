import Foundation

/// The iOS share extension's hand-off to the app: one pending link in the
/// app group's defaults, written by the extension (only after it classified
/// the link as one the app opens) and taken — read and deleted — by the app
/// the next time it's in front and unlocked. No network, no library access.
enum SharedLinkInbox {
    static let appGroup = "group.com.archiveofyourown.reader"
    private static let key = "pendingSharedLink"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Replace any pending link. False when the app group is unavailable.
    @discardableResult
    static func put(_ link: String) -> Bool {
        guard let defaults else { return false }
        defaults.set(link, forKey: key)
        return true
    }

    /// The pending link, removed as it's read.
    static func take() -> String? {
        guard let defaults, let link = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return link
    }
}
