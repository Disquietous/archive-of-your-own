import AppKit
import SwiftUI

/// Owns a pane's request-progress banner (`RequestProgressView`) as an
/// AppKit overlay. `update(opID:)` with an id mounts the banner pinned
/// over the pane's content area; nil tears it down. The host is created
/// on show and removed on hide so the banner's poll timer only runs while
/// its tracked operation is in flight, and it's added to `view` after
/// `container` so content swaps inside the container can never cover it.
@MainActor
final class RequestProgressOverlay {
    private var host: NSHostingView<RequestProgressView>?

    func update(opID: UInt64?, over container: NSView, in view: NSView,
                theme: AppTheme, appState: AppState) {
        guard let opID else {
            host?.removeFromSuperview()
            host = nil
            return
        }
        guard host == nil else { return }
        let banner = NSHostingView(rootView: RequestProgressView(theme: theme, appState: appState, opID: opID))
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        host = banner
    }
}
