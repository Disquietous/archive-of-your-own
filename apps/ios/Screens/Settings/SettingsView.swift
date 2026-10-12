import SwiftUI

/// The Settings tab, grouped General / Reading / Requests / Privacy to
/// match the macOS settings window. iOS-only items (theme editor,
/// recovery key, wipe threshold, accounts) keep their
/// place inside the matching group.
struct SettingsView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav

    @State var chapterCleanupRan = false
    @State var confirmRemoveCloudCopy = false
    @State var linkMode: ExternalLinkOpener.Mode = .system
    /// Mirrors `BiometricUnlock.isEnabled` (UserDefaults isn't observed).
    @State var biometricEnabled = BiometricUnlock.isEnabled
    /// Turning biometric unlock on: the password prompt is up.
    @State var biometricPasswordPrompt = false
    @State var biometricPassword = ""
    @State var biometricError: String?

    let timeouts = [15, 30, 60, 120]

    enum Page { case main, diagnostics }
    /// `.diagnostics`: the pushed Diagnostics screen (timeouts, logs,
    /// debug-build sample data) — kept off the main list.
    var page: Page = .main

    var body: some View {
        switch page {
        case .main: mainPage
        case .diagnostics: diagnosticsPage
        }
    }

    var diagnosticsPage: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    requestsGroup
                    #if DEBUG
                    sampleDataGroup
                    #endif
                }
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: "Diagnostics")
        }
        .libraryScreen()
    }

    var diagnosticsGroup: some View {
        settingsGroup(title: "Troubleshooting") {
            navRow(icon: "stethoscope", title: "Diagnostics", detail: nil) {
                nav.settingsPath.append(AppDestination.diagnostics)
            }
            settingsCaption("Request timeouts, the request and debug logs, and log retention.")
        }
    }

    #if DEBUG
    var sampleDataGroup: some View {
        settingsGroup(title: "Sample Data") {
            Button {
                if state.sampleDataLoaded {
                    state.clearSampleData()
                } else {
                    state.loadSampleData()
                }
            } label: {
                HStack(spacing: 12) {
                    settingsLabel(icon: "testtube.2",
                                  title: state.sampleDataLoaded ? "Remove Sample Data" : "Load Sample Data")
                    Spacer()
                    Text(state.sampleDataLoaded ? "Loaded" : "Not loaded")
                        .font(Typography.uiSmall())
                        .foregroundStyle(state.sampleDataLoaded ? theme.sage : theme.ink3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            settingsCaption("""
                Fictional works for testing and demos. Samples live in memory only — they never enter your encrypted \
                library or touch the archive, and they disappear on quit.
                """)
        }
    }
    #endif

    var mainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack {
                    Text("Settings")
                        .font(Typography.browseTitle())
                        .foregroundStyle(theme.ink)
                    Spacer()
                    PrivacyPillView {
                        nav.presentedSheet = .privacy
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.top, 8)

                generalGroup
                readingGroup
                privacyGroup
                syncGroup
                diagnosticsGroup

                // Footer
                VStack(spacing: 8) {
                    Text("Archive of Your Own")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink3)

                    Text("Nothing you read leaves this device.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .padding(.bottom, 16)
        }
        .background { ThemeBackgroundView() }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            linkMode = ExternalLinkOpener.mode(state.bridge)
            biometricEnabled = BiometricUnlock.isEnabled
        }
        .alert("Enter your library password", isPresented: $biometricPasswordPrompt) {
            SecureField("Password", text: $biometricPassword)
            Button("Turn On") { enableBiometricUnlock() }
            Button("Cancel", role: .cancel) { biometricPassword = "" }
        } message: {
            Text("""
                \(BiometricUnlock.biometryName ?? "Biometrics") will unlock the library on this device with this \
                password. It stays required after a restart or a wrong attempt.
                """)
        }
        .alert("Couldn’t turn on biometric unlock",
               isPresented: Binding(get: { biometricError != nil }, set: { if !$0 { biometricError = nil } })) {
            Button("OK", role: .cancel) { biometricError = nil }
        } message: {
            Text(biometricError ?? "")
        }
    }

    func enableBiometricUnlock() {
        let password = biometricPassword
        biometricPassword = ""
        guard state.bridge.verifyPassword(password) else {
            biometricError = "That password doesn’t unlock the library."
            return
        }
        guard BiometricUnlock.enable(password: password) else {
            biometricError = "The Keychain refused to store it. Check that a passcode and biometrics are set up on this device."
            return
        }
        biometricEnabled = true
    }

}

#Preview {
    SettingsView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
