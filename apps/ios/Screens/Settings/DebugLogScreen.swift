import SwiftUI

/// The debug log: the core's log entries, newest first, filterable by
/// free text, level and tag, with live refresh, copy-all and clear.
/// Tapping a row opens the full message. The iOS counterpart of the
/// macOS `DebugLogView`.
struct DebugLogScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var entries: [ULogEntry] = []
    @State private var selected: ULogEntry?
    @State private var filterText = ""
    @State private var levelFilter = "All"
    @State private var tagFilter = "All"
    @State private var autoRefresh = true
    @State private var copied = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static let levels = ["All", "DEBUG", "INFO", "WARN", "ERROR"]

    private var distinctTags: [String] {
        var tags = Set(entries.map(\.tag))
        tags.remove("")
        return ["All"] + tags.sorted()
    }

    private var filtered: [ULogEntry] {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            let levelOK = levelFilter == "All" || e.level == levelFilter
            let tagOK = tagFilter == "All" || e.tag == tagFilter
            // Free text matches ANY field.
            let textOK = needle.isEmpty
                || e.message.localizedCaseInsensitiveContains(needle)
                || e.tag.localizedCaseInsensitiveContains(needle)
                || e.level.localizedCaseInsensitiveContains(needle)
                || Self.localTime(e.timestamp).localizedCaseInsensitiveContains(needle)
                || String(e.id).contains(needle)
            return levelOK && tagOK && textOK
        }
        .sorted { $0.id > $1.id }
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
                Section {
                    if filtered.isEmpty {
                        Text(entries.isEmpty ? "No log entries yet." : "No entries match the filter.")
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
                    Text("\(filtered.count) of \(entries.count)".uppercased())
                        .font(Typography.sectionHeader())
                        .tracking(0.08 * 13)
                        .foregroundStyle(theme.ink3)
                        .padding(.leading, theme.pad - 16)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Debug Log", subtitle: autoRefresh ? "Live" : "Paused") {
                ChromeIconButton(symbol: autoRefresh ? "pause.circle" : "play.circle",
                                 tint: autoRefresh ? theme.accent : nil) {
                    autoRefresh.toggle()
                }
                .accessibilityLabel(autoRefresh ? "Pause live refresh" : "Resume live refresh")
                ChromeIconButton(symbol: "arrow.clockwise") { reload() }
                    .accessibilityLabel("Reload")
                Menu {
                    Button {
                        UIPasteboard.general.string = state.bridge.dumpLogs(limit: 5000)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    Button(role: .destructive) {
                        state.bridge.clearLogs()
                        reload()
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
        .onAppear(perform: reload)
        .onReceive(timer) { _ in if autoRefresh { reload() } }
        .sheet(item: $selected) { e in
            DebugLogDetailSheet(entry: e)
                .environment(theme)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListFilterField(text: $filterText, placeholder: "Filter any field")
            HStack(spacing: 8) {
                filterMenu("Level", selection: $levelFilter, options: Self.levels)
                filterMenu("Tag", selection: $tagFilter, options: distinctTags)
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

    private func reload() {
        entries = state.bridge.getLogs(limit: 2000)
    }

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
