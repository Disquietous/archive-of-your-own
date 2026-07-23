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
            GeneralSettingsPane(theme: theme, appState: appState, model: model), minHeight: 420))
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
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    private let timeouts = [15, 30, 60, 120]

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
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

            AccountSection(theme: theme, appState: appState)

            SettingsGroup(theme: theme, label: "Sample Data") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Sample works",
                                    value: model.sampleDataLoaded ? "Loaded" : "Not loaded")
                }
                Button {
                    if model.sampleDataLoaded {
                        model.clearSampleData()
                    } else {
                        model.loadSampleData()
                    }
                } label: {
                    Text(model.sampleDataLoaded ? "Remove Sample Data" : "Load Sample Data")
                        .font(Font(MacFont.ui(13, weight: .bold)))
                        .foregroundStyle(model.sampleDataLoaded ? Color(hex: "CE514D") : theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Text("Fictional works for testing and demos. Samples live in memory only — they never enter your encrypted library or touch the archive, and they disappear on quit.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
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

    @State private var showPasswordSheet = false
    @State private var showRemoveConfirm = false

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Protection") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Library password",
                                    value: appState.bridge.hasDbPassword ? "On" : "Off")
                }
                HStack(spacing: 8) {
                    ghostButton(appState.bridge.hasDbPassword ? "Change Password…" : "Set Password…",
                                tint: theme.ink) {
                        showPasswordSheet = true
                    }
                    if appState.bridge.hasDbPassword {
                        ghostButton("Remove Password", tint: Color(hex: "CE514D")) {
                            showRemoveConfirm = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordChangeSheet(theme: theme, appState: appState)
            }
            .alert("Remove Password?", isPresented: $showRemoveConfirm) {
                Button("Remove", role: .destructive) {
                    if appState.bridge.removePassword() {
                        RecoveryKey.deleteEncryptedBlob()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The library stays encrypted, but the key will be stored in the Keychain instead of requiring your password at launch.")
            }

            SettingsGroup(theme: theme, label: "Reading History") {
                HStack(spacing: 3) {
                    historyModeButton("Persisted", mode: .persisted)
                    historyModeButton("Clear on Quit", mode: .clearOnClose)
                    historyModeButton("Disabled", mode: .disabled)
                }
                .padding(3)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(historyModeCaption)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    private var historyModeCaption: String {
        switch appState.historyMode {
        case .persisted: "Reading history is kept in your encrypted library until you clear it."
        case .clearOnClose: "History is erased automatically every time the app quits."
        case .disabled: "No new reading history is recorded. Existing entries stay until cleared."
        }
    }

    private func historyModeButton(_ label: String, mode: AppState.HistoryMode) -> some View {
        let on = appState.historyMode == mode
        return Button {
            appState.historyMode = mode
        } label: {
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

    private func ghostButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(13, weight: .bold)))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Set or change the library password from Settings. Rekeys the open database
/// and issues a fresh recovery key.
struct PasswordChangeSheet: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var recoveryKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.bridge.hasDbPassword ? "Change Password" : "Set Password")
                .font(Font(MacFont.ui(15, weight: .bold)))
                .foregroundStyle(theme.ink)

            if let key = recoveryKey {
                VStack(spacing: 8) {
                    Text("RECOVERY KEY")
                        .font(Font(MacFont.ui(11, weight: .bold)))
                        .kerning(0.9)
                        .foregroundStyle(theme.ink3)
                    Text(key)
                        .font(.system(size: 16, design: .monospaced).weight(.bold))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                    Text("Write this down and keep it safe. If you forget your password, this is the only way to recover your data. It will not be shown again.")
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .fixedSize(horizontal: false, vertical: true)
                    GateButton(theme: theme, label: "I've saved my recovery key", fill: theme.accent) {
                        dismiss()
                    }
                }
            } else {
                SecureField("New password", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                if let error {
                    Text(error)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(theme.surface)
    }

    private func save() {
        error = nil
        guard !password.isEmpty else { error = "Password cannot be empty."; return }
        guard password == confirmPassword else { error = "Passwords don't match."; return }
        guard password.count >= 4 else { error = "Password must be at least 4 characters."; return }
        guard appState.bridge.changePassword(to: password) else {
            error = "Failed to update the password."
            return
        }
        let key = RecoveryKey.generate()
        if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
            RecoveryKey.storeEncryptedBlob(blob)
            recoveryKey = key
        }
        RecoveryKey.resetFailureCount()
    }
}
