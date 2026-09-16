import SwiftUI

struct ContentView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad split columns: all three normally; the detail column alone
    /// while the reader is immersive, like the mac split collapsing its
    /// sidebar and list.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .tint(theme.accent)
        .appSheets()
        .alert("iCloud has \(state.cloudSync.pendingConflict?.deviceName ?? "another device")'s library",
               isPresented: Binding(get: { state.cloudSync.pendingConflict != nil }, set: { _ in })) {
            Button("Use iCloud Copy") { state.cloudSync.resolve(.useCloudCopy) }
            Button("Replace iCloud Copy", role: .destructive) { state.cloudSync.resolve(.overwriteCloudCopy) }
            Button("Not Now", role: .cancel) { state.cloudSync.resolve(.notNow) }
        } message: {
            Text("Use it on this device (this device's library is kept as a backup), or replace the iCloud copy with this device's library (the iCloud copy is kept as a backup). You can also decide later in Settings.")
        }
        .onChange(of: sizeClass, initial: true) { _, size in
            let usesDetail = size == .regular
            guard nav.usesDetailColumn != usesDetail else { return }
            nav.usesDetailColumn = usesDetail
            // When the columns merge (a narrow multitasking layout) the
            // detail column's stack has no home — it is dropped and the tab
            // stack stays as it was; the work is one tap away in its list.
            if !usesDetail {
                nav.detailPath = NavigationPath()
                nav.readerImmersive = false
            }
        }
        .onChange(of: nav.readerImmersive, initial: true) { _, immersive in
            withAnimation(.easeInOut(duration: 0.32)) {
                columnVisibility = immersive ? .detailOnly : .all
            }
        }
    }

    // MARK: - iPhone (TabView)

    private var iPhoneLayout: some View {
        @Bindable var nav = nav
        return TabView(selection: $nav.selectedTab) {
            Tab("Shelf", systemImage: "book", value: AppTab.library) {
                NavigationStack(path: $nav.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            }
            .badge(state.newUnviewedWorkCount + state.inboxUnreadCount)
            Tab("Browse", systemImage: "square.grid.2x2", value: AppTab.browse) {
                NavigationStack(path: $nav.browsePath) {
                    BrowseView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: $nav.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $nav.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            }
        }
        .background(theme.bg)
    }

    // MARK: - iPad (three-column NavigationSplitView)

    /// Sections / list / detail+reader — the mac window's sidebar, list
    /// pane and reading pane. The middle column hosts the selected tab's
    /// stack (section screens, search, browse, settings); the detail
    /// column hosts work detail and the reader.
    private var iPadLayout: some View {
        @Bindable var nav = nav
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            switch nav.selectedTab {
            case .library:
                NavigationStack(path: $nav.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            case .browse:
                NavigationStack(path: $nav.browsePath) {
                    BrowseView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            case .search:
                NavigationStack(path: $nav.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            case .settings:
                NavigationStack(path: $nav.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
                }
            }
        } detail: {
            NavigationStack(path: $nav.detailPath) {
                detailEmptyState
                    .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(theme.bg)
        .background { sectionShortcuts }
    }

    private var sidebar: some View {
        List {
            Section {
                sidebarSection(.reading, "book", "Currently Reading", count: state.currentlyReading.count)
                sidebarTab(.search, "magnifyingglass", "Search")
                sidebarSection(.history, "clock", "History")
            }
            Section("Discover") {
                sidebarTab(.browse, "square.grid.2x2", "Browse")
                sidebarSection(.fandoms, "flame", "Fandoms", count: follows.followedFandoms.count)
                sidebarSection(.authors, "person", "Authors",
                               count: follows.followedAuthorNames.count + state.followedAuthors.count)
            }
            Section("Following") {
                sidebarSection(.whatsNew, "bell.badge", "What’s New", badge: state.newUnviewedWorkCount)
                sidebarSection(.subscriptions, "bell", "Subscriptions")
                sidebarSection(.inbox, "tray", "Inbox", badge: state.inboxUnreadCount)
            }
            Section("Saved") {
                sidebarSection(.bookmarks, "bookmark", "Bookmarks", count: state.bookmarkedWorkIDs.count)
                sidebarSection(.readingLists, "books.vertical", "Reading Lists", count: state.readingLists.count)
                sidebarSection(.downloads, "arrow.down.circle", "Offline", count: state.downloadedWorkIDs.count)
                sidebarSection(.stats, "chart.bar", "Reading Stats")
            }
            Section("App") {
                sidebarTab(.settings, "gearshape", "Settings")
            }
        }
        .navigationTitle("Archive.")
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    }

    private var detailEmptyState: some View {
        EmptyStateView(systemImage: "book",
                       title: "Select a work to begin",
                       subtitle: "Choose something from the list, or browse the archive. Everything you read stays private.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .toolbar(.hidden, for: .navigationBar)
    }

    /// Hardware keyboard section jumps — the mac Go menu's ⌘1–⌘0, minus
    /// the entries that have no key there either. Invisible buttons keep
    /// the shortcuts registered whatever column has focus.
    private var sectionShortcuts: some View {
        Group {
            shortcutButton("1") { nav.showLibrarySection(.reading) }
            shortcutButton("2") { nav.selectedTab = .search }
            shortcutButton("3") { nav.showLibrarySection(.history) }
            shortcutButton("4") { nav.showLibrarySection(.fandoms) }
            shortcutButton("5") { nav.showLibrarySection(.authors) }
            shortcutButton("7") { nav.showLibrarySection(.whatsNew) }
            shortcutButton("8") { nav.showLibrarySection(.inbox) }
            shortcutButton("9") { nav.showLibrarySection(.bookmarks) }
            shortcutButton("0") { nav.showLibrarySection(.downloads) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(_ key: Character, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("") }
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    /// The section the Library stack is currently showing at its root
    /// level, for sidebar highlighting.
    private var activeLibrarySection: LibrarySection? {
        guard nav.selectedTab == .library, let root = nav.libraryRootSection else { return nil }
        return root
    }

    private func sidebarSection(_ section: LibrarySection, _ icon: String, _ label: String,
                                count: Int? = nil, badge: Int = 0) -> some View {
        let selected = activeLibrarySection == section
        return Button {
            nav.showLibrarySection(section)
        } label: {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundStyle(selected ? theme.accent : theme.ink)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.custom("HankenGrotesk", size: 11).weight(.bold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(theme.accent)
                        .clipShape(Capsule())
                } else if let count, count > 0 {
                    Text("\(count)")
                        .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                }
            }
        }
    }

    private func sidebarTab(_ tab: AppTab, _ icon: String, _ label: String) -> some View {
        Button {
            nav.selectedTab = tab
        } label: {
            Label(label, systemImage: icon)
                .foregroundStyle(nav.selectedTab == tab && activeLibrarySection == nil ? theme.accent : theme.ink)
        }
    }
}
