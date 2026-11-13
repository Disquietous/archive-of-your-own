import AppKit

/// Opens URLs that leave the app in the user's chosen application.
/// The choice is a bundle identifier stored in the encrypted DB under
/// the "externalURLApp" pref; empty or absent means the system default
/// handler. A chosen app that's since been uninstalled falls back to
/// the system default rather than dropping the click.
///
/// While the registered VPN is carrying this Mac's traffic, every browser
/// is as private as the stored choice, so the opener asks which one to
/// use each time instead of applying the preference silently.
enum ExternalLinkOpener {
    static let prefKey = "externalURLApp"

    /// The browser picked in the VPN chooser most recently this session;
    /// preselected the next time it asks. Falls back to the stored pref.
    @MainActor private static var lastChosen: String?

    /// An app registered with Launch Services as an https handler.
    struct BrowserApp: Identifiable {
        let id: String  // bundle identifier
        let name: String
        let appURL: URL
    }

    /// Every installed app that can open https URLs, name-sorted.
    static func installedBrowsers() -> [BrowserApp] {
        guard let probe = URL(string: "https://example.com") else { return [] }
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

    @MainActor
    static func open(_ url: URL, bridge: RustBridge) {
        if case .vpn(.matched, let label) = bridge.privacyStatus {
            askBrowser(for: url, bridge: bridge, vpnLabel: label)
            return
        }
        open(url, inApp: bridge.getPref(key: prefKey) ?? "")
    }

    /// Open `url` in the app with bundle identifier `bundleID`; empty or
    /// uninstalled means the system default handler.
    private static func open(_ url: URL, inApp bundleID: String) {
        guard !bundleID.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The VPN-mode chooser: a sheet on the key window (or a modal alert
    /// when there is none) with a popup of System Default plus every
    /// installed https handler. Cancel drops the click.
    @MainActor
    private static func askBrowser(for url: URL, bridge: RustBridge, vpnLabel: String?) {
        let alert = NSAlert()
        alert.messageText = "Open in which browser?"
        alert.informativeText = """
            \(vpnLabel ?? "Your VPN") is carrying this Mac's traffic, so the page travels through it \
            whichever browser opens it.
            """
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        // Items go through the menu directly: NSPopUpButton.addItem(withTitle:)
        // drops an earlier item with the same title, and two installed
        // browsers can share a display name.
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        let systemItem = NSMenuItem(title: "System Default", action: nil, keyEquivalent: "")
        systemItem.representedObject = ""
        popup.menu?.addItem(systemItem)
        for browser in installedBrowsers() {
            let item = NSMenuItem(title: browser.name, action: nil, keyEquivalent: "")
            item.representedObject = browser.id
            popup.menu?.addItem(item)
        }
        let preferred = lastChosen ?? bridge.getPref(key: prefKey) ?? ""
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == preferred }) {
            popup.selectItem(at: index)
        }
        alert.accessoryView = popup

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let chosen = popup.selectedItem?.representedObject as? String ?? ""
            lastChosen = chosen
            open(url, inApp: chosen)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
