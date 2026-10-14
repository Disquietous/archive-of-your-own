import AppKit

/// Avatars for the thread table. Images are decoded once per user and
/// shared across panels. Saved avatars come from the DB off the main
/// thread. Network fetches go one at a time and only when the host allows
/// it (images set to load automatically, no comment page loading — they
/// share the core's rate limit — and the list idle), and only for users
/// still on screen. Everyone else keeps a letter placeholder.
@MainActor
final class DiscussionAvatarLoader {
    private let appState: AppState
    /// "Load images automatically": off means letter placeholders only —
    /// no avatar is shown or looked up, saved or not.
    var isEnabled: () -> Bool = { false }
    /// Whether a network fetch may start now.
    var canFetch: () -> Bool = { true }
    /// Whether a user is still on screen when their turn comes.
    var isWanted: (String) -> Bool = { _ in true }

    private static var decoded: [String: NSImage] = [:]
    private var lookedUp: Set<String> = []
    private var queue: [(name: String, hint: String?)] = []
    private var fetching = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// The decoded avatar, if its bytes are in the session cache.
    func image(for username: String) -> NSImage? {
        guard isEnabled() else { return nil }
        if let image = Self.decoded[username] { return image }
        guard let data = appState.authorAvatars[username], let image = NSImage(data: data) else { return nil }
        Self.decoded[username] = image
        return image
    }

    /// Make the avatar available eventually: DB cache now (off-main), the
    /// network later and only for real accounts.
    func request(_ c: ParsedComment) {
        let name = c.authorName
        guard isEnabled(), !name.isEmpty, appState.authorAvatars[name] == nil,
              !appState.avatarFailures.contains(name), !lookedUp.contains(name),
              let app = appState.bridge.coreApp else { return }
        lookedUp.insert(name)
        let fetchable = !c.isGuest && (!c.authorProfileUrl.isEmpty || !c.authorAvatarUrl.isEmpty)
        let hint = c.authorAvatarUrl.isEmpty ? nil : c.authorAvatarUrl
        Task {
            let data = await Task.detached(priority: .utility) {
                (try? app.getCachedAuthorAvatar(username: name)) ?? nil
            }.value
            if let data {
                if appState.authorAvatars[name] == nil { appState.authorAvatars[name] = data }
                return
            }
            guard fetchable else { return }
            queue.append((name, hint))
            pump()
        }
    }

    /// Start the next queued fetch if nothing else is in flight.
    func pump() {
        guard !fetching, canFetch() else { return }
        while let next = queue.first {
            queue.removeFirst()
            let name = next.name
            guard appState.authorAvatars[name] == nil, !appState.avatarFailures.contains(name),
                  !appState.avatarFetchesInFlight.contains(name) else { continue }
            guard isWanted(name) else {
                lookedUp.remove(name)  // ask again if it scrolls back into view
                continue
            }
            fetching = true
            appState.avatarFetchesInFlight.insert(name)
            Task {
                do {
                    appState.authorAvatars[name] = try await appState.bridge.fetchAuthorAvatar(name, urlHint: next.hint)
                } catch {
                    appState.avatarFailures.insert(name)
                }
                appState.avatarFetchesInFlight.remove(name)
                fetching = false
                pump()
            }
            return
        }
    }

    /// The panel closed: drop queued fetches (they're re-requested when the
    /// rows show again).
    func cancelQueued() {
        for item in queue { lookedUp.remove(item.name) }
        queue.removeAll()
    }

    /// Theme changes recolor the letter placeholders.
    func clearPlaceholders() { placeholders.removeAll() }

    private var placeholders: [String: NSImage] = [:]

    /// A letter disc for users without an avatar (yet).
    func placeholder(for username: String, style: DiscussionStyle) -> NSImage {
        let letter = String(username.prefix(1)).uppercased()
        if let image = placeholders[letter] { return image }
        let size = DiscussionStyle.avatar
        let font = MacFont.ui(size * 0.45, weight: .bold)
        let (fill, ink) = (style.surface2, style.ink3)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let s = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: ink])
            let m = s.size()
            s.draw(at: NSPoint(x: (rect.width - m.width) / 2, y: (rect.height - m.height) / 2))
            return true
        }
        placeholders[letter] = image
        return image
    }
}
