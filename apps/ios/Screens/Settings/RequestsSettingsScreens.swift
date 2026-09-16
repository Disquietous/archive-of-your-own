import SwiftUI

/// Settings › Requests › Per-page timeouts: the per-route timeout catalog —
/// every request shape the app makes, each with an editable timeout. A
/// page expected to be slow (an entire work) can wait longer than one
/// expected to be quick (an autocomplete). An empty field means the page
/// follows the global timeout. Mirrors the macOS `RouteTimeoutsList`.
struct RouteTimeoutsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var routes: [URouteTimeout] = []
    @State private var filter = ""

    private var matches: [URouteTimeout] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return routes }
        return routes.filter {
            $0.label.lowercased().contains(needle) || $0.template.lowercased().contains(needle)
        }
    }

    private var overrideCount: Int { routes.filter { $0.timeoutSecs != nil }.count }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ListFilterField(text: $filter, placeholder: "Filter pages")

                    Text("Pages without a value use the global timeout (\(theme.requestTimeout)s). Clear a field to go back to the default.")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)

                    if matches.isEmpty {
                        Text("No pages match “\(filter)”")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(matches, id: \.key) { route in
                                RouteTimeoutRow(route: route, defaultSecs: theme.requestTimeout) { secs in
                                    state.bridge.setRouteTimeout(key: route.key, seconds: secs)
                                    routes = state.bridge.getRouteTimeouts()
                                }
                                if route.key != matches.last?.key {
                                    Divider().foregroundStyle(theme.line)
                                }
                            }
                        }
                        .padding(.horizontal, theme.cardPad)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.settingsGroup)
                                .fill(theme.surface)
                        )
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: "Per-Page Timeouts",
                         subtitle: overrideCount == 0 ? "All pages use the global timeout"
                                   : "\(overrideCount) override\(overrideCount == 1 ? "" : "s")")
        }
        .libraryScreen()
        .onAppear { routes = state.bridge.getRouteTimeouts() }
    }
}

/// One catalog row: page name over its URL template, and a numeric field
/// that commits on Return or focus loss. Any positive number of seconds;
/// invalid input reverts.
private struct RouteTimeoutRow: View {
    @Environment(AppTheme.self) private var theme

    let route: URouteTimeout
    let defaultSecs: Int
    let onSet: (UInt64?) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(route: URouteTimeout, defaultSecs: Int, onSet: @escaping (UInt64?) -> Void) {
        self.route = route
        self.defaultSecs = defaultSecs
        self.onSet = onSet
        _text = State(initialValue: route.timeoutSecs.map(String.init) ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.label)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
                Text(route.template)
                    .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the global timeout")
            }
            TextField("\(defaultSecs)", text: $text)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.custom("HankenGrotesk", size: 15).weight(route.timeoutSecs != nil ? .bold : .regular))
                .foregroundStyle(route.timeoutSecs != nil ? theme.accent : theme.ink)
                .frame(width: 52)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Text("s")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 10)
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

/// Settings › Requests › Log retention: how long the request and debug
/// logs keep entries, their entry caps, and the background trim schedule.
/// Mirrors the macOS Requests pane's log groups.
struct LogRetentionScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    group("Request log") {
                        trimAgeRow(value: intBinding(\.requestLogMaxAgeValue),
                                   unit: unitBinding(\.requestLogMaxAgeUnit))
                        Divider().foregroundStyle(theme.line)
                        trimRowsRow(value: rowsBinding(\.requestLogMaxRows))
                        caption("Leave a field empty for no limit. Entries past the age limit are deleted first, then the log is trimmed to the entry cap.")
                    }

                    group("Debug log") {
                        trimAgeRow(value: intBinding(\.debugLogMaxAgeValue),
                                   unit: unitBinding(\.debugLogMaxAgeUnit))
                        Divider().foregroundStyle(theme.line)
                        trimRowsRow(value: rowsBinding(\.debugLogMaxRows))
                        caption("Same rules as the request log: empty means no limit, age applies before the entry cap.")
                    }

                    group("Log cleanup") {
                        HStack(spacing: 8) {
                            Text("Run cleanup every")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                            Spacer()
                            numberField(intBinding(\.logTrimIntervalValue), width: 60)
                        }
                        unitPicker(unitBinding(\.logTrimIntervalUnit))
                        caption("Trims both logs in the background on this schedule. Empty falls back to hourly.")
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: "Log Retention")
        }
        .libraryScreen()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, theme.cardPad)
            .padding(.vertical, theme.cardPad + 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.settingsGroup)
                    .fill(theme.surface)
            )
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func trimAgeRow(value: Binding<String>, unit: Binding<AppState.LogTrimUnit>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Delete entries older than")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
                Spacer()
                numberField(value, width: 60)
            }
            unitPicker(unit)
        }
    }

    private func trimRowsRow(value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("Keep at most")
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
            Spacer()
            numberField(value, width: 90)
            Text("entries")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
        }
    }

    private func numberField(_ text: Binding<String>, width: CGFloat) -> some View {
        TextField("∞", text: text)
            .textFieldStyle(.plain)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
            .foregroundStyle(theme.ink)
            .frame(width: width, height: 36)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func unitPicker(_ unit: Binding<AppState.LogTrimUnit>) -> some View {
        SegmentedControlView(selection: unit,
                             items: AppState.LogTrimUnit.allCases.map { (key: $0, label: $0.rawValue.capitalized) })
    }

    /// Digits-only text binding onto an Int setting; 0 shows as empty
    /// (limit disabled).
    private func intBinding(_ path: ReferenceWritableKeyPath<AppState, Int>) -> Binding<String> {
        Binding(get: { state[keyPath: path] == 0 ? "" : String(state[keyPath: path]) },
                set: { state[keyPath: path] = Int($0.filter(\.isNumber).prefix(12)) ?? 0 })
    }

    /// Same, for the row caps — arbitrary magnitudes (1M+ is fine).
    private func rowsBinding(_ path: ReferenceWritableKeyPath<AppState, UInt64>) -> Binding<String> {
        Binding(get: { state[keyPath: path] == 0 ? "" : String(state[keyPath: path]) },
                set: { state[keyPath: path] = UInt64($0.filter(\.isNumber).prefix(12)) ?? 0 })
    }

    private func unitBinding(_ path: ReferenceWritableKeyPath<AppState, AppState.LogTrimUnit>)
        -> Binding<AppState.LogTrimUnit> {
        Binding(get: { state[keyPath: path] }, set: { state[keyPath: path] = $0 })
    }
}
