import AppKit

/// Confirmation sheet for every bell-menu change that touches AO3 (and so
/// may change follows too). The wording comes from FollowModel so both
/// platforms say the same thing; this only renders it: one button per
/// option, then Cancel. The AO3 request only ever fires from a chosen
/// option — Cancel leaves state untouched.
enum FollowConfirmation {
    static func present(_ confirmation: FollowModel.Confirmation, in window: NSWindow?,
                        chosen: @escaping (FollowModel.ConfirmationOption) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        for option in confirmation.options {
            let button = alert.addButton(withTitle: option.label)
            button.hasDestructiveAction = option.isDestructive
        }
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < confirmation.options.count else { return }
            chosen(confirmation.options[index])
        }
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
