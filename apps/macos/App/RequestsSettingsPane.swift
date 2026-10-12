import AppKit
import SwiftUI

// MARK: - Requests

/// Everything about how the app talks to the archive: the global request
/// timeout, and per-page overrides for request shapes that deserve more
/// (an entire work) or less (an autocomplete) patience.
/// Settings › Diagnostics: request timeouts, log retention and (debug
/// builds) sample data — tools for troubleshooting, kept out of the
/// everyday panes.
struct RequestsSettingsPane: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

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

            SettingsGroup(theme: theme, label: "Request log") {
                trimAgeRow(value: intBinding(\.requestLogMaxAgeValue),
                           unit: $appState.requestLogMaxAgeUnit)
                trimRowsRow(value: rowsBinding(\.requestLogMaxRows))
                Text("Leave a field empty for no limit. Entries past the age limit are deleted first, then the log is trimmed to the entry cap.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Debug log") {
                trimAgeRow(value: intBinding(\.debugLogMaxAgeValue),
                           unit: $appState.debugLogMaxAgeUnit)
                trimRowsRow(value: rowsBinding(\.debugLogMaxRows))
                Text("Same rules as the request log: empty means no limit, age applies before the entry cap.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Log cleanup") {
                HStack(spacing: 8) {
                    Text("Run cleanup every")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    numberField(intBinding(\.logTrimIntervalValue), width: 60)
                    unitPicker($appState.logTrimIntervalUnit)
                    Spacer()
                }
                Text("Trims both logs in the background on this schedule. Empty falls back to hourly.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A testing tool: debug builds only.
            #if DEBUG
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
                Text("""
                    Fictional works for testing and demos. Samples live in memory only — they never enter your \
                    encrypted library or touch the archive, and they disappear on quit.
                    """)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .padding(16)
    }

    private func trimAgeRow(value: Binding<String>, unit: Binding<AppState.LogTrimUnit>) -> some View {
        HStack(spacing: 8) {
            Text("Delete entries older than")
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink)
            numberField(value, width: 60)
            unitPicker(unit)
            Spacer()
        }
    }

    private func trimRowsRow(value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("Keep at most")
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink)
            numberField(value, width: 90)
            Text("entries")
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink)
            Spacer()
        }
    }

    private func numberField(_ text: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Font(MacFont.ui(13, weight: .semibold)))
            .foregroundStyle(theme.ink)
            .frame(width: width, height: 28)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }

    private func unitPicker(_ unit: Binding<AppState.LogTrimUnit>) -> some View {
        HStack(spacing: 3) {
            ForEach(AppState.LogTrimUnit.allCases, id: \.self) { u in
                segButton(u.rawValue, on: unit.wrappedValue == u) { unit.wrappedValue = u }
            }
        }
        .padding(3)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 220)
    }

    /// Digits-only text binding onto an Int setting; 0 shows as empty
    /// (limit disabled).
    private func intBinding(_ path: ReferenceWritableKeyPath<AppState, Int>) -> Binding<String> {
        Binding(get: { appState[keyPath: path] == 0 ? "" : String(appState[keyPath: path]) },
                set: { appState[keyPath: path] = Int($0.filter(\.isNumber).prefix(12)) ?? 0 })
    }

    /// Same, for the row caps — arbitrary magnitudes (1M+ is fine).
    private func rowsBinding(_ path: ReferenceWritableKeyPath<AppState, UInt64>) -> Binding<String> {
        Binding(get: { appState[keyPath: path] == 0 ? "" : String(appState[keyPath: path]) },
                set: { appState[keyPath: path] = UInt64($0.filter(\.isNumber).prefix(12)) ?? 0 })
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
