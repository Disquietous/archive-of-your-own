import AppKit
import SwiftUI

// The UniFFI record already carries a unique `id`; make it usable in Table.
extension ULogEntry: Identifiable {}

/// A read-only console over the encrypted debug-log sidecar database —
/// the Rust core's log_debug!/log_info!/log_error! lines plus the Swift
/// layer's writeLog breadcrumbs. Filterable on every field (in SQL, via
/// `DebugLogFeed`), paged in as the table scrolls, sortable within what's
/// loaded.
final class DebugLogWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState) {
        let host = NSHostingController(rootView: DebugLogView(theme: theme, appState: appState))
        let window = NSWindow(contentViewController: host)
        window.title = "Debug Log"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 600))
        window.setFrameAutosaveName("DebugLogWindow")
        self.init(window: window)
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DebugLogView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var feed: DebugLogFeed
    @State private var selectedID: Int64?
    /// Newest first by default; every column header re-sorts.
    @State private var sortOrder = [KeyPathComparator(\ULogEntry.id, order: .reverse)]
    @State private var autoRefresh = true

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static let levels = ["All", "DEBUG", "INFO", "WARN", "ERROR"]

    init(theme: AppTheme, appState: AppState) {
        self.theme = theme
        self.appState = appState
        _feed = State(initialValue: DebugLogFeed(bridge: appState.bridge))
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

    private var tagOptions: [String] { ["All"] + feed.tags }

    /// The loaded rows in the chosen column order. Sorting is local to
    /// what's loaded; the feed itself is always newest first.
    private var rows: [ULogEntry] {
        feed.entries.sorted(using: sortOrder)
    }

    private var selected: ULogEntry? {
        feed.entries.first { $0.id == selectedID }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                logTable
                    .frame(minWidth: 540)
                detailPane
                    .frame(minWidth: 240)
            }
        }
        .background(theme.bg)
        .onAppear { feed.reload() }
        .onReceive(timer) { _ in if autoRefresh { feed.poll() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3)
            TextField("Filter any field", text: $feed.text)
                .textFieldStyle(.plain)
                .frame(maxWidth: 220)
            Picker("Level", selection: $feed.level) {
                ForEach(Self.levels, id: \.self) { Text($0) }
            }
            .frame(maxWidth: 130)
            Picker("Tag", selection: $feed.tag) {
                ForEach(tagOptions, id: \.self) { Text($0) }
            }
            .frame(maxWidth: 160)
            Spacer()
            Text("\(feed.entries.count) of \(feed.total)")
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
                .help("Rows loaded of rows matching the filter — more load as you scroll.")
            Toggle("Live", isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Button("Reload") { feed.reload() }
            Button("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.bridge.dumpLogs(), forType: .string)
            }
            Button("Clear") {
                selectedID = nil
                feed.clear()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var logTable: some View {
        Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("#", value: \.id) { e in
                Text(String(e.id))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                    // Table rows are lazy: a cell appearing means the row
                    // scrolled into view — the feed pages in the next
                    // batch once that nears the oldest loaded row.
                    .onAppear { feed.rowAppeared(e) }
            }
            .width(56)
            TableColumn("Time", value: \.timestamp) { e in
                Text(localTime(e.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            .width(110)
            TableColumn("Level", value: \.level) { e in
                Text(e.level)
                    .font(Font(MacFont.ui(10, weight: .bold)))
                    .foregroundStyle(levelColor(e.level))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(levelColor(e.level).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(64)
            TableColumn("Tag", value: \.tag) { e in
                Text(e.tag)
                    .font(Font(MacFont.ui(11, weight: .semibold)))
                    .foregroundStyle(theme.ink2)
            }
            .width(90)
            TableColumn("Message", value: \.message) { e in
                Text(e.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .help(e.message)
            }
        }
    }

    /// Full, wrapped, selectable copy of the selected entry — messages are
    /// routinely longer than a table row.
    private var detailPane: some View {
        ScrollView {
            if let e = selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 20) {
                        detailField("Entry", "#\(e.id)")
                        detailField("Level", e.level, tint: levelColor(e.level))
                        detailField("Tag", e.tag.isEmpty ? "—" : e.tag)
                    }
                    detailField("When", "\(localTime(e.timestamp)) (\(e.timestamp) UTC)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MESSAGE")
                            .font(Font(MacFont.ui(10, weight: .bold)))
                            .foregroundStyle(theme.ink3)
                        Text(e.message)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.ink)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(14)
            } else {
                Text("Select an entry")
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
            }
        }
        .background(theme.surface)
    }

    private func detailField(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Font(MacFont.ui(10, weight: .bold)))
                .foregroundStyle(theme.ink3)
            Text(value)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(tint ?? theme.ink)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private func localTime(_ sqliteUTC: String) -> String {
        guard let date = Self.parseFormatter.date(from: sqliteUTC) else { return sqliteUTC }
        return Self.displayFormatter.string(from: date)
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR": Color(hex: "CE514D")
        case "WARN": theme.accent2
        case "INFO": theme.sage
        default: theme.ink3
        }
    }
}
