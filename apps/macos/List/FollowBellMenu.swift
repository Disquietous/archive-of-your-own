import AppKit
import SwiftUI

/// The bell menu every author, work and series bell opens: exactly
/// "Followed" and "Subscribed", checkmarked like the reading-list menu.
/// Followed changes are local and silent; anything touching AO3 shows the
/// FollowConfirmation sheet first. Subscribed is disabled when signed out.
@MainActor
final class FollowBellMenu: NSObject {
    private let follows: FollowModel
    private let target: FollowModel.Target
    private weak var window: NSWindow?

    private init(follows: FollowModel, target: FollowModel.Target, window: NSWindow?) {
        self.follows = follows
        self.target = target
        self.window = window
    }

    /// Pop the menu under `view`. Synchronous (NSMenu tracking), so the
    /// controller lives exactly as long as the menu is up.
    static func show(for target: FollowModel.Target, follows: FollowModel, from view: NSView) {
        let controller = FollowBellMenu(follows: follows, target: target, window: view.window)
        let state = follows.state(target)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let followed = NSMenuItem(title: "Followed", action: #selector(chooseFollowed), keyEquivalent: "")
        followed.target = controller
        followed.state = state.followed ? .on : .off
        followed.isEnabled = !follows.isBusy(target)
        followed.toolTip = "Follow on this device — What’s New checks followed items. Never sent to AO3."
        menu.addItem(followed)

        let subscribed = NSMenuItem(title: "Subscribed", action: #selector(chooseSubscribed), keyEquivalent: "")
        subscribed.target = controller
        subscribed.state = state.subscribed ? .on : .off
        subscribed.isEnabled = follows.canSubscribe(target) && !follows.isBusy(target)
        subscribed.toolTip = follows.canSubscribe(target)
            ? "Your AO3 subscription — AO3 notifies you of updates. Asks before changing your account."
            : "Sign in to subscribe on AO3"
        menu.addItem(subscribed)

        _ = withExtendedLifetime(controller) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }

    @objc private func chooseFollowed() { run(.followed) }
    @objc private func chooseSubscribed() { run(.subscribed) }

    private func run(_ item: FollowModel.MenuItem) {
        if case .confirm(let confirmation) = follows.toggle(item, for: target) {
            let follows = follows, target = target
            // After the menu closes, so the sheet attaches cleanly.
            DispatchQueue.main.async { [window] in
                FollowConfirmation.present(confirmation, in: window) { option in
                    follows.apply(option, to: target)
                }
            }
        }
    }
}

/// SwiftUI host for the bell (SwiftUI-hosted list variants). The caller
/// passes `shaded` read from FollowModel in its own body, so the bell
/// re-renders when follows change.
struct FollowBell: NSViewRepresentable {
    let theme: AppTheme
    let follows: FollowModel
    let target: FollowModel.Target
    let shaded: Bool
    var size: CGFloat = 12

    func makeNSView(context: Context) -> FollowBellButton {
        FollowBellButton(theme: theme, pointSize: size - 1)
    }

    func updateNSView(_ button: FollowBellButton, context: Context) {
        button.configure(name: target.name, shaded: shaded)
        let follows = follows, target = target
        button.onClick = { view in FollowBellMenu.show(for: target, follows: follows, from: view) }
    }
}
