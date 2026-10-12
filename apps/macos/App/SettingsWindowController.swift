import AppKit
import SwiftUI

/// In-window Settings: the sidebar's Settings section hosts this in the
/// reading pane, spanning the collapsed list pane's space. A tab strip
/// along the top switches between the same panes the old standalone
/// settings window showed, with pane content centered at a readable width.
struct SettingsRootView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    private enum Tab: String, CaseIterable {
        case general = "General"
        case reading = "Reading"
        case diagnostics = "Diagnostics"
        case privacy = "Privacy"
        case sync = "Sync"

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .reading: "textformat.size"
            case .diagnostics: "stethoscope"
            case .privacy: "shield.lefthalf.filled"
            case .sync: "icloud"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            tabStrip
                .padding(.top, 14)
                .padding(.bottom, 4)
            ScrollView {
                Group {
                    switch tab {
                    case .general:
                        GeneralSettingsPane(theme: theme, appState: appState, model: model)
                    case .reading:
                        ReadingSettingsView(theme: theme, themedBackground: false)
                    case .diagnostics:
                        RequestsSettingsPane(theme: theme, appState: appState, model: model)
                    case .privacy:
                        PrivacySettingsPane(theme: theme, appState: appState, model: model)
                    case .sync:
                        CloudSyncSettingsPane(theme: theme, appState: appState)
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(t.rawValue)
                            .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    }
                    .foregroundStyle(tab == t ? theme.ink : theme.ink3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(tab == t ? theme.surface : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Shared styled pieces (same vocabulary as ReadingSettingsView)

struct SettingsGroup<Content: View>: View {
    @Bindable var theme: AppTheme
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.8)
                .foregroundStyle(theme.ink3)
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @Bindable var theme: AppTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.init(top: 4, leading: 13, bottom: 4, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1.5))
    }
}

struct SettingsToggleRow: View {
    @Bindable var theme: AppTheme
    let label: String
    var sublabel: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(theme.ink)
                if let sublabel {
                    Text(sublabel)
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.sage)
        }
        .padding(.vertical, 9)
    }
}

struct SettingsInfoRow: View {
    @Bindable var theme: AppTheme
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Font(MacFont.ui(13.5, weight: .medium)))
                .foregroundStyle(theme.ink)
            Spacer()
            Text(value)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
    }
}
