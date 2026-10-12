import AppKit
import SwiftUI

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
                Text("""
                    Links that leave the app open in this application. Anything opened this way travels over that \
                    app's own connection, not this app's private one.
                    """)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AccountSection(theme: theme, appState: appState)

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
