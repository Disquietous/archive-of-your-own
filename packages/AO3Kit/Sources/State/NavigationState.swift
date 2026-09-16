import SwiftUI

enum AppTab: String, Hashable {
    case library, browse, search, settings
}

enum AppDestination: Hashable {
    case workDetail(workID: String)
    case reader(workID: String, chapterIndex: Int, entireWork: Bool = false)
    case collectionsBrowse
    case collectionWorks(name: String, title: String)
    case readingList(listID: Int64, name: String)
    case authorWorks(username: String)
    case inbox
    case inboxThread
    case accountManagement
    /// Settings › Requests drill-ins (iOS).
    case routeTimeouts
    case logRetention
    case requestLog
    /// Settings › iCloud Sync › Backups (iOS).
    case libraryBackups
    case debugLog
    /// A Library hub section (iOS): one list screen per macOS sidebar entry.
    case librarySection(LibrarySection)
    /// Fandoms drill-in: the library's works in one fandom.
    case fandomWorks(tag: String)
    /// Subscriptions drill-in: one author's or series' stored works.
    case subscriptionWorks(id: String, name: String, subType: String)
}

enum SheetType: Identifiable, Hashable {
    case privacy
    case readingSettings
    case databasePasswordReset
    case reauth
    case comment(workID: String, chapterID: UInt64?)
    case viewComments(workID: String, chapterID: UInt64?)
    case bookmarkEdit(workID: String)
    /// Find-or-create reading list picker for one work.
    case readingListPicker(workID: String)
    case themeEditor

    var id: String {
        switch self {
        case .privacy: "privacy"
        case .readingSettings: "readingSettings"
        case .databasePasswordReset: "databasePasswordReset"
        case .reauth: "reauth"
        case .comment(let workID, let chapterID): "comment-\(workID)-\(chapterID ?? 0)"
        case .viewComments(let workID, let chapterID): "viewComments-\(workID)-\(chapterID ?? 0)"
        case .bookmarkEdit(let workID): "bookmarkEdit-\(workID)"
        case .readingListPicker(let workID): "readingListPicker-\(workID)"
        case .themeEditor: "themeEditor"
        }
    }
}

@Observable
final class NavigationState {
    var selectedTab: AppTab = .library
    var libraryPath = NavigationPath()
    var browsePath = NavigationPath()
    var searchPath = NavigationPath()
    var settingsPath = NavigationPath()
    var presentedSheet: SheetType?
    var goHomeRequested = false

    // MARK: - iPad detail column

    /// The three-column iPad layout's detail stack: work detail and the
    /// reader live here, beside the section list, like the mac reading
    /// pane. Unused (empty) on iPhone.
    var detailPath = NavigationPath()
    /// True while the three-column layout is showing: `openWork` /
    /// `openReader` route to `detailPath` instead of the tab's stack.
    var usesDetailColumn = false
    /// The reader has hidden its chrome — the split collapses to the
    /// detail column alone (immersive), like the mac split.
    var readerImmersive = false

    /// Open a work's detail. On iPad the detail column shows exactly this
    /// work (a selection, not a push); on iPhone it pushes on the tab.
    func openWork(_ id: String) {
        let dest = AppDestination.workDetail(workID: id)
        if usesDetailColumn {
            detailPath = NavigationPath([dest])
            return
        }
        push(dest)
    }

    func openReader(_ workID: String, chapterIndex: Int) {
        let dest = AppDestination.reader(workID: workID, chapterIndex: chapterIndex)
        if usesDetailColumn {
            detailPath.append(dest)
            return
        }
        push(dest)
    }

    func openEntireWork(_ workID: String) {
        let dest = AppDestination.reader(workID: workID, chapterIndex: 0, entireWork: true)
        if usesDetailColumn {
            detailPath.append(dest)
            return
        }
        push(dest)
    }

    func openReadingList(_ listId: Int64, name: String) {
        let dest = AppDestination.readingList(listID: listId, name: name)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    // MARK: - Driving the Search tab from elsewhere

    /// A tag query handed to the Search tab (a tag pill, a fandom card):
    /// the Search screen consumes it by running `SearchModel.startTagQuery`
    /// under the source toggle. Cleared once consumed.
    var pendingTagQuery: String?
    /// AO3's paged tag listing, handed to the Search tab — the Fandoms
    /// drill-in's explicit "Search AO3" action, which bypasses the source
    /// toggle by design (`SearchModel.startAO3TagListing`).
    var pendingAO3TagListing: String?
    /// The tab a search was triggered from, when it wasn't the Search tab
    /// — the results back arrow returns there instead of to the form.
    var searchReturnTab: AppTab?

    /// A tag pill or fandom card: live tag-scoped results shown in Search.
    func openTag(_ tag: String) {
        openSearch { pendingTagQuery = tag }
    }

    /// The explicit "Search AO3" hand-off for a fandom: AO3's paged tag
    /// listing in the Search tab, whatever the source toggle says.
    func openAO3TagListing(_ tag: String) {
        openSearch { pendingAO3TagListing = tag }
    }

    /// The one process for driving the Search tab from anywhere: switch
    /// tabs (remembering the origin as the back arrow's return target),
    /// then record the caller's query for the Search screen to run.
    private func openSearch(_ run: () -> Void) {
        if selectedTab != .search {
            searchReturnTab = selectedTab
            selectedTab = .search
        } else {
            searchReturnTab = nil
        }
        presentedSheet = nil
        run()
    }

    func openCollections() {
        let dest = AppDestination.collectionsBrowse
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openCollection(name: String, title: String) {
        let dest = AppDestination.collectionWorks(name: name, title: title)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openLibrarySection(_ section: LibrarySection) {
        push(.librarySection(section))
    }

    /// The hub section at the root of the Library stack, when the stack was
    /// last reset to one (iPad sidebar selection). Cleared when the user
    /// navigates elsewhere.
    private(set) var libraryRootSection: LibrarySection?

    /// iPad sidebar: show a section as the Library stack's root.
    func showLibrarySection(_ section: LibrarySection) {
        selectedTab = .library
        libraryRootSection = section
        var path = NavigationPath()
        path.append(AppDestination.librarySection(section))
        libraryPath = path
    }

    func openInboxThread() {
        push(.inboxThread)
    }

    func openFandomWorks(_ tag: String) {
        push(.fandomWorks(tag: tag))
    }

    func openSubscriptionWorks(id: String, name: String, subType: String) {
        push(.subscriptionWorks(id: id, name: name, subType: subType))
    }

    /// Push onto the selected tab's stack.
    private func push(_ dest: AppDestination) {
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func goHome() {
        libraryRootSection = nil
        detailPath = NavigationPath()
        readerImmersive = false
        libraryPath = NavigationPath()
        browsePath = NavigationPath()
        searchPath = NavigationPath()
        settingsPath = NavigationPath()
        presentedSheet = nil
        selectedTab = .library
        goHomeRequested = true
    }

    func openInbox() {
        let dest = AppDestination.inbox
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
        presentedSheet = nil
    }

    func goBack() {
        if usesDetailColumn, !detailPath.isEmpty {
            detailPath.removeLast()
            return
        }
        switch selectedTab {
        case .library: if !libraryPath.isEmpty { libraryPath.removeLast() }
        case .browse: if !browsePath.isEmpty { browsePath.removeLast() }
        case .search: if !searchPath.isEmpty { searchPath.removeLast() }
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }
        }
    }
}
