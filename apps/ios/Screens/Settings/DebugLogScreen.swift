import SwiftUI

/// The debug log: the core's log entries, newest first, filterable by
/// free text, level and tag (in SQL, via `DebugLogFeed`), paged in as the
/// list scrolls, with live refresh, copy-all and clear. Tapping a row
/// opens the full message. The iOS counterpart of the macOS `DebugLogView`.
struct DebugLogScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    /// Created on first appearance — the bridge comes from the environment.
    @State private var feed: DebugLogFeed?
    @State private var selected: ULogEntry?
    @State private var autoRefresh = true
    @State private var copied = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static let levels = ["All", "DEBUG", "INFO", "WARN", "ERROR"]

    var body: some View {
        ZStack(alignment: .top) {
            if let feed {
                content(feed)
            }
            ScreenChrome(title: "Debug Log", subtitle: autoRefresh ? "Live" : "Paused") {
                ChromeIconButton(symbol: autoRefresh ? "pause.circle" : "play.circle",
                                 tint: autoRefresh ? theme.accent : nil) {
                    autoRefresh.toggle()
                }
                .accessibilityLabel(autoRefresh ? "Pause live refresh" : "Resume live refresh")
                ChromeIconButton(symbol: "arrow.clockwise") { feed?.reload() }
                    .accessibilityLabel("Reload")
                Menu {
                    Button {
                        UIPasteboard.general.string = state.bridge.dumpLogs()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    Button(role: .destructive) {
                        feed?.clear()
                    } label: {
                        Label("Clear Debug Log", systemImage: "trash")
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
        .onAppear {
            if feed == nil { feed = DebugLogFeed(bridge: state.bridge) }
            feed?.reload()
        }
        .onReceive(timer) { _ in if autoRefresh { feed?.poll() } }
        .sheet(item: $selected) { e in
            DebugLogDetailSheet(entry: e)
                .environment(theme)
        }
    }

    private func content(_ feed: DebugLogFeed) -> some View {
        @Bindable var feed = feed
        return List {
            Section {
                controls(feed)
                    .listRowInsets(EdgeInsets(top: 4, leading: theme.pad, bottom: 8, trailing: theme.pad))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                if feed.entries.isEmpty {
                    Text(feed.total == 0 && feed.level == "All" && feed.tag == "All" && feed.text.isEmpty
                         ? "No log entries yet." : "No entries match the filter.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(feed.entries, id: \.id) { e in
                        Button { selected = e } label: { row(e) }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 8, leading: theme.pad, bottom: 8, trailing: theme.pad))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible)
                            // List rows are lazy: appearing means scrolled
                            // into view — the feed pages in the next batch
                            // once that nears the oldest loaded row.
                            .onAppear { feed.rowAppeared(e) }
                    }
                }
            } header: {
                Text("\(feed.entries.count) of \(feed.total)".uppercased())
                    .font(Typography.sectionHeader())
                    .tracking(0.08 * 13)
                    .foregroundStyle(theme.ink3)
                    .padding(.leading, theme.pad - 16)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
    }

    private func controls(_ feed: DebugLogFeed) -> some View {
        @Bindable var feed = feed
        return VStack(alignment: .leading, spacing: 10) {
            ListFilterField(text: $feed.text, placeholder: "Filter any field")
            HStack(spacing: 8) {
                filterMenu("Level", selection: $feed.level, options: Self.levels)
                filterMenu("Tag", selection: $feed.tag, options: ["All"] + feed.tags)
            }
        }
    }

    private func filterMenu(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if option == selection.wrappedValue {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue == "All" ? title : "\(title): \(selection.wrappedValue)")
                    .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                    .foregroundStyle(selection.wrappedValue == "All" ? theme.ink2 : theme.accent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.surface2)
            .clipShape(Capsule())
        }
    }

    private func row(_ e: ULogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(e.level)
                    .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                    .foregroundStyle(Self.levelColor(e.level, theme: theme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Self.levelColor(e.level, theme: theme).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if !e.tag.isEmpty {
                    Text(e.tag)
                        .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                        .foregroundStyle(theme.ink2)
                }
                Spacer()
                Text(Self.localTime(e.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            Text(e.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.ink)
                .lineLimit(3)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    /// Timestamps arrive as SQLite UTC "yyyy-MM-dd HH:mm:ss".
    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    static func localTime(_ sqliteUTC: String) -> String {
        guard let date = parseFormatter.date(from: sqliteUTC) else { return sqliteUTC }
        return displayFormatter.string(from: date)
    }

    static func levelColor(_ level: String, theme: AppTheme) -> Color {
        switch level {
        case "ERROR": Color(hex: "CE514D")
        case "WARN": theme.accent2
        case "INFO": theme.sage
        default: theme.ink3
        }
    }
}

extension ULogEntry: Identifiable {}

/// Full, wrapped, selectable copy of one entry — messages are routinely
/// longer than a row.
struct DebugLogDetailSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let entry: ULogEntry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        field("Entry", "#\(entry.id)")
                        field("Level", entry.level, tint: DebugLogScreen.levelColor(entry.level, theme: theme))
                        field("Tag", entry.tag.isEmpty ? "—" : entry.tag)
                    }
                    field("When", "\(DebugLogScreen.localTime(entry.timestamp)) (\(entry.timestamp) UTC)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MESSAGE")
                            .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                            .foregroundStyle(theme.ink3)
                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.ink)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(theme.pad)
            }
            .background(theme.bg)
            .navigationTitle("Log Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { UIPasteboard.general.string = entry.message }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func field(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                .foregroundStyle(theme.ink3)
            Text(value)
                .font(Typography.uiBody())
                .foregroundStyle(tint ?? theme.ink)
                .textSelection(.enabled)
        }
    }
}
