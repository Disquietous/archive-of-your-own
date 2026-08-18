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
        case requests = "Requests"
        case privacy = "Privacy"

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .reading: "textformat.size"
            case .requests: "network"
            case .privacy: "shield.lefthalf.filled"
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
                    case .requests:
                        RequestsSettingsPane(theme: theme, appState: appState)
                    case .privacy:
                        PrivacySettingsPane(theme: theme, appState: appState, model: model)
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

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Content") {
                SettingsCard(theme: theme) {
                    SettingsToggleRow(theme: theme, label: "Hide explicit works",
                                      sublabel: "Filters Explicit-rated works from search results",
                                      isOn: $model.hideExplicit)
                }
            }

            SettingsGroup(theme: theme, label: "Links") {
                ExternalLinkAppRow(theme: theme, appState: appState)
                Text("Links that leave the app open in this application. Anything opened this way travels over that app's own connection, not this app's private one.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
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
}

/// The "open links in" picker: System Default plus every installed app
/// registered as an https handler. The choice is a bundle identifier in
/// the encrypted DB (ExternalLinkOpener.prefKey); "" means system default.
private struct ExternalLinkAppRow: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var browsers: [ExternalLinkOpener.BrowserApp] = []
    @State private var selection = ""

    var body: some View {
        SettingsCard(theme: theme) {
            HStack(spacing: 12) {
                Text("Open links in")
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(theme.ink)
                Spacer()
                Picker("", selection: $selection) {
                    Text("System Default").tag("")
                    ForEach(browsers) { browser in
                        Text(browser.name).tag(browser.id)
                    }
                    // A chosen app that's been uninstalled since: keep the
                    // choice visible instead of showing a blank picker.
                    if !selection.isEmpty && !browsers.contains(where: { $0.id == selection }) {
                        Text("Missing App").tag(selection)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            .padding(.vertical, 9)
        }
        .onAppear {
            browsers = ExternalLinkOpener.installedBrowsers()
            selection = appState.bridge.getPref(key: ExternalLinkOpener.prefKey) ?? ""
        }
        .onChange(of: selection) { _, chosen in
            appState.bridge.setPref(key: ExternalLinkOpener.prefKey, value: chosen)
        }
    }
}

// MARK: - Requests

/// Everything about how the app talks to the archive: the global request
/// timeout, and per-page overrides for request shapes that deserve more
/// (an entire work) or less (an autocomplete) patience.
struct RequestsSettingsPane: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    private let timeouts = [15, 30, 60, 120]

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Global timeout") {
                HStack(spacing: 3) {
                    ForEach(timeouts, id: \.self) { seconds in
                        segButton("\(seconds)s", on: theme.requestTimeout == seconds) {
                            theme.requestTimeout = seconds
                            // Mirror into the core — theme only persists the
                            // preference; requests read the bridge's value.
                            appState.bridge.setRequestTimeout(UInt64(seconds))
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

            SettingsGroup(theme: theme, label: "Per-page timeouts") {
                RouteTimeoutsList(theme: theme, appState: appState)
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

// MARK: - Per-page request timeouts

/// The per-route timeout catalog: every request shape the app makes, each
/// with an editable timeout. A page expected to be slow (an entire work)
/// can wait longer than one expected to be quick (an autocomplete). An
/// empty field means the page follows the global timeout above.
private struct RouteTimeoutsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var routes: [URouteTimeout] = []
    @State private var filter = ""

    private var matches: [URouteTimeout] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return routes }
        return routes.filter {
            $0.label.lowercased().contains(needle) || $0.template.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            SettingsCard(theme: theme) {
                if matches.isEmpty {
                    Text("No pages match “\(filter)”")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(matches, id: \.key) { route in
                                RouteTimeoutRow(theme: theme, route: route,
                                                defaultSecs: theme.requestTimeout) { secs in
                                    appState.bridge.setRouteTimeout(key: route.key, seconds: secs)
                                    routes = appState.bridge.getRouteTimeouts()
                                }
                                if route.key != matches.last?.key {
                                    theme.line.frame(height: 1)
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                }
            }
            Text("Pages without a value use the global timeout. Press Return to apply; clear the field to go back to the default.")
                .font(Font(MacFont.ui(11.5)))
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { routes = appState.bridge.getRouteTimeouts() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Filter pages", text: $filter)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }
}

/// One catalog row: page name over its URL template, and a numeric field
/// that commits on Return or focus loss. Any positive number of seconds;
/// invalid input reverts.
private struct RouteTimeoutRow: View {
    @Bindable var theme: AppTheme
    let route: URouteTimeout
    let defaultSecs: Int
    let onSet: (UInt64?) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(theme: AppTheme, route: URouteTimeout, defaultSecs: Int, onSet: @escaping (UInt64?) -> Void) {
        self.theme = theme
        self.route = route
        self.defaultSecs = defaultSecs
        self.onSet = onSet
        _text = State(initialValue: route.timeoutSecs.map(String.init) ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(route.label)
                    .font(Font(MacFont.ui(12.5, weight: .medium)))
                    .foregroundStyle(theme.ink)
                Text(route.template)
                    .font(Font(MacFont.ui(10.5)))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if route.timeoutSecs != nil {
                Button {
                    text = ""
                    onSet(nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the global timeout")
            }
            TextField("\(defaultSecs)", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Font(MacFont.ui(12, weight: route.timeoutSecs != nil ? .bold : .regular)))
                .foregroundStyle(route.timeoutSecs != nil ? theme.accent : theme.ink)
                .frame(width: 42)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Text("s")
                .font(Font(MacFont.ui(11.5)))
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 7)
        .onChange(of: route.timeoutSecs) { _, secs in
            if !focused { text = secs.map(String.init) ?? "" }
        }
    }

    /// Empty clears the override; a positive integer sets it; anything else
    /// reverts to the stored value.
    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if route.timeoutSecs != nil { onSet(nil) }
            return
        }
        if let secs = UInt64(trimmed), secs > 0 {
            if secs != route.timeoutSecs { onSet(secs) }
        } else {
            text = route.timeoutSecs.map(String.init) ?? ""
        }
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

            SettingsGroup(theme: theme, label: "Auto-Lock") {
                HStack(spacing: 8) {
                    Text("Lock when idle for")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    TextField("5", text: autoLockBinding)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(Font(MacFont.ui(13, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .frame(width: 52, height: 28)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                    Text("minutes")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                }
                Text(autoLockCaption)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var autoLockBinding: Binding<String> {
        Binding(get: { String(appState.autoLockMinutes) },
                set: { appState.autoLockMinutes = min(9999, max(0, Int($0.filter(\.isNumber)) ?? 0)) })
    }

    private var autoLockCaption: String {
        if !appState.bridge.hasDbPassword {
            return "Auto-lock requires a library password — set one above to enable it."
        }
        if appState.autoLockMinutes == 0 {
            return "Auto-lock is disabled. Enter a number of minutes to lock the library after inactivity."
        }
        return "After \(appState.autoLockMinutes) idle minute\(appState.autoLockMinutes == 1 ? "" : "s"), the library locks and the app returns to the unlock screen. Any activity in the app resets the timer. 0 disables."
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
