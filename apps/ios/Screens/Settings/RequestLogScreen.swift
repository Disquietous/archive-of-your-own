import SwiftUI

/// The request log: every archive request the core has made, newest
/// first, with the live in-flight strip on top. Filter by URL or method,
/// failures only, live refresh, clear. Tapping a row opens its detail.
/// The iOS counterpart of the macOS `RequestLogView`.
struct RequestLogScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var entries: [URequestLogEntry] = []
    @State private var active: [UActiveRequest] = []
    @State private var selected: URequestLogEntry?
    @State private var filter = ""
    @State private var failuresOnly = false
    @State private var autoRefresh = true

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var filtered: [URequestLogEntry] {
        entries.filter { e in
            let matchesText = filter.isEmpty || e.url.localizedCaseInsensitiveContains(filter)
                || e.method.localizedCaseInsensitiveContains(filter)
            let matchesFailure = !failuresOnly || e.error != nil || e.status >= 400 || e.status == 0
            return matchesText && matchesFailure
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            List {
                Section {
                    controls
                        .listRowInsets(EdgeInsets(top: 4, leading: theme.pad, bottom: 8, trailing: theme.pad))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if !active.isEmpty {
                    Section {
                        ForEach(active, id: \.self) { a in
                            inFlightRow(a)
                                .listRowInsets(EdgeInsets(top: 6, leading: theme.pad, bottom: 6, trailing: theme.pad))
                                .listRowBackground(theme.accentSoft.opacity(0.35))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        sectionHeader("\(active.count) in flight")
                    }
                }

                Section {
                    if filtered.isEmpty {
                        Text(entries.isEmpty ? "No requests logged yet." : "No requests match the filter.")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filtered, id: \.id) { e in
                            Button { selected = e } label: { row(e) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 8, leading: theme.pad, bottom: 8, trailing: theme.pad))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.visible)
                        }
                    }
                } header: {
                    sectionHeader("\(filtered.count) of \(entries.count)")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Request Log", subtitle: autoRefresh ? "Live" : "Paused") {
                ChromeIconButton(symbol: autoRefresh ? "pause.circle" : "play.circle",
                                 tint: autoRefresh ? theme.accent : nil) {
                    autoRefresh.toggle()
                }
                .accessibilityLabel(autoRefresh ? "Pause live refresh" : "Resume live refresh")
                ChromeIconButton(symbol: "arrow.clockwise") { reload() }
                    .accessibilityLabel("Reload")
                Menu {
                    Button(role: .destructive) {
                        state.bridge.clearRequestLog()
                        reload()
                    } label: {
                        Label("Clear Request Log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .libraryScreen()
        .onAppear(perform: reload)
        .onReceive(timer) { _ in if autoRefresh { reload() } }
        .sheet(item: $selected) { e in
            RequestLogDetailSheet(entry: e)
                .environment(theme)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListFilterField(text: $filter, placeholder: "Filter by URL or method")
            Toggle(isOn: $failuresOnly) {
                Text("Failures only")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
            }
            .tint(theme.accent)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.sectionHeader())
            .tracking(0.08 * 13)
            .foregroundStyle(theme.ink3)
            .padding(.leading, theme.pad - 16)
    }

    /// Requests that have started but not yet resolved — refreshed by the
    /// same 1s live timer as the list.
    private func inFlightRow(_ a: UActiveRequest) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(theme.ink3)
            Text(a.method)
                .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                .foregroundStyle(a.method.hasPrefix("POST") ? theme.accent2 : theme.ink2)
                .frame(width: 44, alignment: .leading)
            Text(Self.shortURL(a.url))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(Self.elapsed(a.elapsedMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.ink3)
            // The timeout governing this request (route override or
            // global) — makes a mis-applied override visible live.
            Text(a.timeoutSecs > 0 ? "of \(a.timeoutSecs)s" : "of —")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.accent)
        }
    }

    private func row(_ e: URequestLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(e.method)
                    .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                    .foregroundStyle(e.method.hasPrefix("POST") ? theme.accent2 : theme.ink2)
                Text(e.status == 0 ? "—" : "\(e.status)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.statusColor(e, theme: theme))
                Spacer()
                Text("\(e.durationMs) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                Text(Self.bytes(e.responseBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                Text(Self.clock(e.startedMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            Text(Self.shortURL(e.url))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            if let error = e.error {
                Text(error)
                    .font(Typography.uiSmall())
                    .foregroundStyle(Color(hex: "CE514D"))
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func reload() {
        entries = state.bridge.getRequestLog(limit: 500)
        active = state.bridge.getActiveRequests()
    }

    static func shortURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://archiveofourown.org", with: "")
    }

    static func elapsed(_ ms: Int64) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    static func bytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fullClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm:ss"
        return f
    }()

    static func clock(_ ms: Int64) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func fullClock(_ ms: Int64) -> String {
        fullClockFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func statusColor(_ e: URequestLogEntry, theme: AppTheme) -> Color {
        if e.error != nil || e.status == 0 || e.status >= 500 { return Color(hex: "CE514D") }
        if e.status >= 400 { return theme.accent2 }
        return theme.sage
    }
}

extension URequestLogEntry: Identifiable {}

/// One request's full record: URL, status, sizes, timing, error, payload.
struct RequestLogDetailSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let entry: URequestLogEntry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("URL", entry.url, mono: true)
                    HStack(spacing: 20) {
                        field("Method", entry.method)
                        field("Status", entry.status == 0 ? "— (no response)" : "\(entry.status)",
                              tint: RequestLogScreen.statusColor(entry, theme: theme))
                    }
                    HStack(spacing: 20) {
                        field("Duration", "\(entry.durationMs) ms")
                        field("Request", RequestLogScreen.bytes(entry.requestBytes))
                        field("Response", RequestLogScreen.bytes(entry.responseBytes))
                    }
                    field("When", RequestLogScreen.fullClock(entry.startedMs))
                    if let transport = entry.transport {
                        field("Transport", transport, mono: true)
                    }
                    if let error = entry.error {
                        field("Error", error, tint: Color(hex: "CE514D"))
                    }
                    if let payload = entry.payload {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PAYLOAD")
                                .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                                .foregroundStyle(theme.ink3)
                            Text(payload)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.ink2)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(theme.pad)
            }
            .background(theme.bg)
            .navigationTitle("Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy URL") { UIPasteboard.general.string = entry.url }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func field(_ label: String, _ value: String, mono: Bool = false, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                .foregroundStyle(theme.ink3)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : Typography.uiBody())
                .foregroundStyle(tint ?? theme.ink)
                .textSelection(.enabled)
        }
    }
}
