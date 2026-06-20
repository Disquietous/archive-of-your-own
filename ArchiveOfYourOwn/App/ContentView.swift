import SwiftUI

struct ContentView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var nav = nav

        Group {
            if sizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .tint(theme.accent)
        .sheet(item: $nav.presentedSheet) { sheet in
            sheetView(for: sheet)
                .environment(theme)
                .environment(state)
                .environment(nav)
        }
    }

    // MARK: - iPhone (TabView)

    private var iPhoneLayout: some View {
        @Bindable var nav = nav
        return TabView(selection: $nav.selectedTab) {
            Tab("Shelf", systemImage: "book", value: AppTab.library) {
                NavigationStack(path: $nav.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            }
            .badge(state.unreadNotificationCount > 0 ? state.unreadNotificationCount : 0)
            Tab("Browse", systemImage: "square.grid.2x2", value: AppTab.browse) {
                NavigationStack(path: $nav.browsePath) {
                    BrowseView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: $nav.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $nav.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            }
        }
        .background(theme.bg)
    }

    // MARK: - iPad (NavigationSplitView)

    private var iPadLayout: some View {
        @Bindable var nav = nav
        return NavigationSplitView {
            List {
                ForEach([
                    (AppTab.library, "Shelf", "book"),
                    (AppTab.browse, "Browse", "square.grid.2x2"),
                    (AppTab.search, "Search", "magnifyingglass"),
                    (AppTab.settings, "Settings", "gearshape"),
                ], id: \.0) { tab, label, icon in
                    Button {
                        nav.selectedTab = tab
                    } label: {
                        Label(label, systemImage: icon)
                            .foregroundStyle(nav.selectedTab == tab ? theme.accent : theme.ink)
                    }
                }
            }
            .navigationTitle("Archive.")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 230)
        } detail: {
            switch nav.selectedTab {
            case .library:
                NavigationStack(path: $nav.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            case .browse:
                NavigationStack(path: $nav.browsePath) {
                    BrowseView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            case .search:
                NavigationStack(path: $nav.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            case .settings:
                NavigationStack(path: $nav.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppDestination.self, destination: destinationView)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(theme.bg)
    }

    // MARK: - Shared

    @ViewBuilder
    private func destinationView(for destination: AppDestination) -> some View {
        switch destination {
        case .workDetail(let workID):
            WorkDetailView(workID: workID)
        case .reader(let workID, let chapterIndex, let entireWork):
            ReaderView(workID: workID, chapterIndex: chapterIndex, entireWork: entireWork)
        case .tagBrowse(let tag):
            TagBrowseView(tag: tag)
        case .readingList(let listID, let name):
            ReadingListView(listID: listID, listName: name)
        case .authorWorks(let username):
            AuthorWorksView(username: username)
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .inbox:
            InboxView()
        case .accountManagement:
            AccountManagementView()
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: SheetType) -> some View {
        switch sheet {
        case .privacy:
            PrivacySheetView()
        case .readingSettings:
            ReadingSettingsSheetView()
        case .databasePasswordReset:
            DatabasePasswordSheet(isReset: true)
        case .ao3Login:
            AO3LoginSheet()
        case .comment(let workID, let chapterID):
            CommentSheet(workID: workID, chapterID: chapterID)
        case .viewComments(let workID, let chapterID):
            CommentThreadView(workID: workID, chapterID: chapterID)
        case .bookmarkEdit(let workID):
            BookmarkEditSheet(workID: workID)
        case .themeEditor:
            ThemeEditorSheet()
        }
    }
}
