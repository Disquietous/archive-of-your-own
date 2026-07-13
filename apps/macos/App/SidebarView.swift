import SwiftUI

/// SwiftUI sidebar hosted inside the AppKit split view.
struct SidebarView: View {
    let appState: AppState

    enum Section: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case library = "Library"
        case history = "History"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .browse: "magnifyingglass"
            case .library: "books.vertical"
            case .history: "clock"
            }
        }
    }

    @State private var selection: Section? = .library

    var body: some View {
        List(selection: $selection) {
            ForEach(Section.allCases) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            statusFooter
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                appState.bridge.isInitialized ? "Core ready" : "Core locked",
                systemImage: appState.bridge.isInitialized ? "checkmark.circle" : "lock"
            )
            Label(appState.torStatus.displayText, systemImage: "network.badge.shield.half.filled")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
