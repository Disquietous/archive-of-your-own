import SwiftUI

/// Opens links handed over by the share extension (`SharedLinkInbox`):
/// taken when the main window is in front and unlocked, classified by the
/// core, then routed to the matching screen — or reported as unsupported
/// with no navigation.
struct SharedLinkRouterModifier: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.scenePhase) private var scenePhase

    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: takePendingLink)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { takePendingLink() }
            }
            .alert("Couldn’t open that link",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    private func takePendingLink() {
        guard let raw = SharedLinkInbox.take() else { return }
        Task {
            if let problem = await LinkRouter(state: state, nav: nav).open(raw) {
                failure = problem
            }
        }
    }
}

/// Routes a link to its screen. The core classifies it for every source
/// and names the destination by library id; this only navigates.
@MainActor
struct LinkRouter {
    let state: AppState
    let nav: NavigationState

    /// A link tapped in content: a page the app has a view for opens
    /// there; anything else — or one that then fails to load — leaves the
    /// app the way external links do.
    func openContentLink(_ url: URL) {
        guard state.bridge.canOpenLink(url.absoluteString) else {
            ExternalLinkOpener.open(url, bridge: state.bridge)
            return
        }
        Task {
            if await open(url.absoluteString) != nil {
                ExternalLinkOpener.open(url, bridge: state.bridge)
            }
        }
    }

    /// Open a pasted, shared or tapped link. Returns nil when it opened,
    /// else the message to show.
    func open(_ raw: String) async -> String? {
        guard let destination = state.bridge.openLink(raw) else { return unresolvable }
        switch destination {
        case .unknown(let message), .unsupported(let message):
            return "\(message) \(AppState.supportedLinkSummary)"
        case .work(let workID, let entire):
            let id = String(workID)
            if let problem = await ensureWork(id) { return problem }
            if entire {
                nav.openEntireWork(id)
            } else {
                nav.openWork(id)
            }
        case .chapter(let workID, let chapterID):
            let id = String(workID)
            if let chapter = await state.resolveChapterLink(workID: id, chapterID: chapterID) {
                nav.openReader(id, chapterIndex: chapter)
            } else {
                if let problem = await ensureWork(id) { return problem }
                nav.openWork(id)
            }
        case .user(_, let username, let pane):
            // The author screens here are keyed by username, which only
            // some sources use as the user's key.
            guard let username else { return "Authors from this site can’t be opened here yet." }
            let profilePane: AuthorProfileModel.Pane? = switch pane {
            case .profile: nil
            case .works: .works
            case .bookmarks: .bookmarks
            case .collections: .collections
            }
            nav.openAuthor(username, pane: profilePane)
        case .series(let seriesID, let name):
            let id = String(seriesID)
            nav.openSubscriptionWorks(id: id, name: name.isEmpty ? "Series \(id)" : name, subType: "series")
        case .collection(let name):
            nav.openCollection(name: name, title: name)
        case .tag(let name):
            // A tag listing link: the site's results regardless of the
            // Library | AO3 source toggle.
            nav.openAO3TagListing(name)
        }
        return nil
    }

    private var unresolvable: String {
        "The link couldn’t be opened — the library isn’t available."
    }

    /// The work's metadata from the library, or one fetch from its site.
    /// Returns the message to show when it can't be had — nothing
    /// half-opens. `id` is the library id.
    private func ensureWork(_ id: String) async -> String? {
        if state.work(byID: id) == nil {
            await state.fetchWorkMetadata(id)
        }
        guard state.work(byID: id) != nil else {
            return "The work couldn’t be loaded. It may be restricted, deleted, or the connection failed."
        }
        return nil
    }
}
