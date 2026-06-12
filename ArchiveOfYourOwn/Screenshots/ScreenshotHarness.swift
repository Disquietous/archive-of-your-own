import SwiftUI

struct ScreenshotHarness: View {
    @State private var theme = AppTheme()
    @State private var state = ScreenshotState.makePopulatedState()
    @State private var nav = NavigationState()

    @State private var currentScene: ScreenshotScene = .library
    @State private var running = false

    enum ScreenshotScene: String, CaseIterable {
        case library
        case subscriptions
        case browse
        case workDetail
        case reader
        case search
        case settings
        case privacySheet
        case comments
    }

    private static let themes: [(String, ThemeDefinition)] = [
        ("paper", PresetThemes.paper),
        ("night", PresetThemes.night),
    ]

    var body: some View {
        ZStack {
            contentBody
                .environment(theme)
                .environment(state)
                .environment(nav)
                .preferredColorScheme(theme.preferredColorScheme)
        }
        .task {
            guard !running else { return }
            running = true
            await runScreenshotSequence()
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch currentScene {
        case .library, .browse, .settings:
            tabbedContent
        case .search:
            searchContent
        case .subscriptions:
            subscriptionsContent
        case .workDetail:
            NavigationStack {
                WorkDetailView(workID: "baker")
            }
            .environment(theme)
            .environment(state)
            .environment(nav)
        case .reader:
            ReaderView(workID: "baker", chapterIndex: 0)
        case .privacySheet:
            tabbedContent
                .sheet(isPresented: .constant(true)) {
                    PrivacySheetView()
                        .environment(theme)
                        .environment(state)
                        .environment(nav)
                }
        case .comments:
            tabbedContent
                .sheet(isPresented: .constant(true)) {
                    CommentThreadView(
                        workID: "baker",
                        chapterID: nil,
                        initialComments: ScreenshotState.mockComments,
                        overrideLoggedIn: true
                    )
                    .environment(theme)
                    .environment(state)
                    .environment(nav)
                }
        }
    }

    // Tab bar screens rendered through the real ContentView TabView
    private var tabbedContent: some View {
        ContentView()
    }

    private var searchContent: some View {
        ScreenshotTabView(selectedTab: .search) {
            SearchView(initialShowFilters: true)
        }
    }

    private var subscriptionsContent: some View {
        ScreenshotTabView(selectedTab: .library) {
            LibraryView(
                initialTab: .subscriptions,
                initialExpandedSections: ["Authors", "Works", "Series"]
            )
        }
    }

    // MARK: - Orchestration

    private func runScreenshotSequence() async {
        let dir = screenshotDirectory()

        for (themeName, themeDef) in Self.themes {
            theme.switchTheme(themeDef)
            try? await Task.sleep(for: .milliseconds(500))

            for scene in ScreenshotScene.allCases {
                configureNavForScene(scene)
                currentScene = scene
                try? await Task.sleep(for: .seconds(1.5))

                let signalName = "ready_\(themeName)_\(scene.rawValue).signal"
                let signalPath = dir.appendingPathComponent(signalName)
                FileManager.default.createFile(atPath: signalPath.path, contents: nil)

                while FileManager.default.fileExists(atPath: signalPath.path) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        let donePath = dir.appendingPathComponent("done.signal")
        FileManager.default.createFile(atPath: donePath.path, contents: nil)
    }

    private func configureNavForScene(_ scene: ScreenshotScene) {
        nav.presentedSheet = nil
        nav.libraryPath = NavigationPath()
        nav.browsePath = NavigationPath()
        nav.searchPath = NavigationPath()
        nav.settingsPath = NavigationPath()

        switch scene {
        case .library, .subscriptions:
            nav.selectedTab = .library
        case .browse:
            nav.selectedTab = .browse
        case .search:
            nav.selectedTab = .search
        case .settings:
            nav.selectedTab = .settings
        case .workDetail, .reader:
            nav.selectedTab = .library
        case .privacySheet:
            nav.selectedTab = .library
        case .comments:
            nav.selectedTab = .library
        }
    }

    private func screenshotDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in contents where file.hasSuffix(".signal") {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(file).path)
            }
        }

        return dir
    }
}

// A minimal TabView that shows custom content in the selected tab with the system tab bar
private struct ScreenshotTabView<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    let selectedTab: AppTab
    @ViewBuilder let content: () -> Content

    var body: some View {
        TabView(selection: .constant(selectedTab)) {
            Tab("Shelf", systemImage: "book", value: AppTab.library) {
                NavigationStack {
                    if selectedTab == .library { content() } else { LibraryView() }
                }
            }
            Tab("Browse", systemImage: "square.grid.2x2", value: AppTab.browse) {
                NavigationStack {
                    if selectedTab == .browse { content() } else { BrowseView() }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack {
                    if selectedTab == .search { content() } else { SearchView() }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    if selectedTab == .settings { content() } else { SettingsView() }
                }
            }
        }
        .background(theme.bg)
    }
}
