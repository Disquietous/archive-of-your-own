import SwiftUI

/// Opens links handed over by the share extension (`SharedLinkInbox`):
/// taken when the main window is in front and unlocked, re-classified,
/// then routed to the matching screen — or reported as unsupported with
/// no navigation.
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
        switch AO3Link.classify(raw) {
        case .failure(let rejection):
            failure = "\(rejection.message) \(AO3Link.supportedSummary)"
        case .success(let link):
            Task { await open(link) }
        }
    }

    private func open(_ link: AO3Link) async {
        switch link {
        case .work(let id):
            guard await ensureWork(id) else { return }
            nav.openWork(id)
        case .entireWork(let id):
            guard await ensureWork(id) else { return }
            nav.openEntireWork(id)
        case .chapter(let workID, let chapterID):
            if let chapter = await state.resolveChapterLink(workID: workID, chapterID: chapterID) {
                nav.openReader(workID, chapterIndex: chapter)
            } else if await ensureWork(workID) {
                nav.openWork(workID)
            }
        case .user(let name, _, let pane):
            // Pseuds share their user's profile.
            let profilePane: AuthorProfileModel.Pane? = switch pane {
            case .profile: nil
            case .works: .works
            case .bookmarks: .bookmarks
            case .collections: .collections
            }
            nav.openAuthor(name, pane: profilePane)
        case .series(let id):
            nav.openSubscriptionWorks(id: id, name: "Series \(id)", subType: "series")
        case .collection(let name):
            nav.openCollection(name: name, title: name)
        case .tag(let name):
            // An AO3 tag listing link: AO3's results regardless of the
            // Library | AO3 source toggle.
            nav.openAO3TagListing(name)
        }
    }

    /// The work's metadata from the library, or one fetch from AO3. False
    /// (with the alert) when it can't be had — nothing half-opens.
    private func ensureWork(_ id: String) async -> Bool {
        if state.work(byID: id) == nil {
            await state.fetchWorkMetadata(id)
        }
        guard state.work(byID: id) != nil else {
            failure = "The work couldn’t be loaded from AO3. It may be restricted, deleted, or the connection failed."
            return false
        }
        return true
    }
}
