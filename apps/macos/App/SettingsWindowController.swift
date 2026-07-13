import AppKit
import SwiftUI

/// Standard macOS Settings window (⌘,): toolbar-style tabs hosting SwiftUI
/// panes styled with the app's design language (matching the reading pane).
final class SettingsWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        func pane(_ content: some View, minHeight: CGFloat) -> NSHostingController<AnyView> {
            NSHostingController(rootView: AnyView(
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(width: 360)
                .frame(minHeight: minHeight, maxHeight: .infinity)
            ))
        }

        let general = NSTabViewItem(viewController: pane(
            GeneralSettingsPane(theme: theme, model: model), minHeight: 360))
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        let reading = NSTabViewItem(viewController: pane(
            ReadingSettingsView(theme: theme, themedBackground: false), minHeight: 480))
        reading.label = "Reading"
        reading.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Reading")

        let privacy = NSTabViewItem(viewController: pane(
            PrivacySettingsPane(theme: theme, appState: appState, model: model), minHeight: 420))
        privacy.label = "Privacy"
        privacy.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Privacy")

        tabs.addTabViewItem(general)
        tabs.addTabViewItem(reading)
        tabs.addTabViewItem(privacy)

        let window = NSWindow(contentViewController: tabs)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setFrameAutosaveName("SettingsWindow")
        self.init(window: window)
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    var sublabel: String? = nil
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

// MARK: - General

struct GeneralSettingsPane: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    private let timeouts = [15, 30, 60, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Content") {
                SettingsCard(theme: theme) {
                    SettingsToggleRow(theme: theme, label: "Hide explicit works",
                                      sublabel: "Filters Explicit-rated works from browse and search",
                                      isOn: $model.hideExplicit)
                }
            }

            SettingsGroup(theme: theme, label: "Network") {
                HStack(spacing: 3) {
                    ForEach(timeouts, id: \.self) { seconds in
                        segButton("\(seconds)s", on: theme.requestTimeout == seconds) {
                            theme.requestTimeout = seconds
                        }
                    }
                }
                .padding(3)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("How long to wait for the archive to respond")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
            }

            SettingsGroup(theme: theme, label: "Account") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "AO3 account",
                                    value: "Available once archive sync lands on macOS")
                }
            }
        }
        .padding(16)
    }

    private func segButton(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(on ? theme.ink : theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Privacy

struct PrivacySettingsPane: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Tor") {
                SettingsCard(theme: theme) {
                    SettingsToggleRow(theme: theme, label: "Connect via Tor on launch",
                                      sublabel: "Require a circuit before any network request",
                                      isOn: $theme.useTorByDefault)
                    theme.line.frame(height: 1)
                    SettingsInfoRow(theme: theme, label: "Status", value: appState.torStatus.displayText)
                }
                Button {
                    Task { await appState.connectTor() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text(appState.torStatus.isConnected ? "New circuit" : "Connect")
                            .font(Font(MacFont.ui(13.5, weight: .bold)))
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            SettingsGroup(theme: theme, label: "Storage") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Database", value: "Encrypted on device (SQLCipher)")
                    theme.line.frame(height: 1)
                    SettingsInfoRow(theme: theme, label: "Encryption key",
                                    value: appState.bridge.hasDbPassword ? "Your password" : "Stored in Keychain")
                }
            }
        }
        .padding(16)
    }
}
