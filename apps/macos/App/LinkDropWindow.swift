import AppKit

/// A window that accepts AO3 links dragged in from any app (a browser's
/// address bar or a link on a page, a text selection holding a URL) and
/// opens them exactly as "Open AO3 URL…" does. While dragging, only the
/// string is classified — nothing is read from or sent to the network —
/// and the copy cursor appears only for links the app can open.
final class LinkDropWindow: NSWindow {
    /// Opens a link; returns nil when it opened, else the failure message.
    /// Unset (or `acceptsLinks` false) → drops are refused.
    var openLink: ((String) -> String?)?
    /// False while the window can't route anywhere (e.g. locked).
    var acceptsLinks: () -> Bool = { true }

    func enableLinkDrops() {
        registerForDraggedTypes([.URL, .string])
    }

    /// The first URL-ish string on the drag pasteboard.
    private func linkString(from info: NSDraggingInfo) -> String? {
        let board = info.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { !$0.isFileURL }) {
            return url.absoluteString
        }
        return board.string(forType: .string)
    }

    private func droppable(_ info: NSDraggingInfo) -> String? {
        guard openLink != nil, acceptsLinks(), let raw = linkString(from: info),
              case .success = AO3Link.classify(raw) else { return nil }
        return raw
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppable(sender) == nil ? [] : .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppable(sender) == nil ? [] : .copy
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppable(sender) != nil
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let raw = droppable(sender), let openLink else { return false }
        // Let the drag session finish before any alert runs modally.
        DispatchQueue.main.async {
            if let problem = openLink(raw) {
                AppDelegate.presentLinkFailure(problem)
            }
        }
        return true
    }
}
