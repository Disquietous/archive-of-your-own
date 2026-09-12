import AppKit

/// Confirmation sheet for AO3 author subscription changes. Every control
/// that changes the user's real AO3 subscription routes through here, so
/// the request only ever fires from the confirmed branch. Cancel leaves
/// state untouched.
enum AuthorSubscriptionConfirmation {
    static func present(in window: NSWindow?, username: String, subscribe: Bool,
                        confirmed: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = subscribe
            ? "Subscribe to \(username) on AO3?"
            : "Unsubscribe from \(username) on AO3?"
        alert.informativeText = subscribe
            ? "This changes your AO3 account: AO3 will notify you when \(username) posts a new work. The request is sent over Tor."
            : "This changes your AO3 account: AO3 will stop notifying you when \(username) posts. The request is sent over Tor."
        alert.addButton(withTitle: subscribe ? "Subscribe" : "Unsubscribe")
        alert.addButton(withTitle: "Cancel")
        if !subscribe {
            alert.buttons.first?.hasDestructiveAction = true
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                confirmed()
            }
        }
    }
}
