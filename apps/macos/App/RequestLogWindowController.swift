import AppKit
import SwiftUI

// The UniFFI record already carries a unique `id`; make it usable in Table.
extension URequestLogEntry: Identifiable {}

/// A network-inspector window (dev-console style) over the request audit log.
final class RequestLogWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState) {
        let host = NSHostingController(rootView: RequestLogView(theme: theme, appState: appState))
        let window = NSWindow(contentViewController: host)
        window.title = "Request Log"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 560))
        window.setFrameAutosaveName("RequestLogWindow")
        self.init(window: window)
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RequestLogView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var entries: [URequestLogEntry] = []
    @State private var selectedID: Int64?
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

    private var selected: URequestLogEntry? {
        entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                requestTable
                    .frame(minWidth: 460)
                detailPane
                    .frame(minWidth: 260)
            }
        }
        .background(theme.bg)
        .onAppear(perform: reload)
        .onReceive(timer) { _ in if autoRefresh { reload() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3)
            TextField("Filter by URL or method", text: $filter)
                .textFieldStyle(.plain)
                .frame(maxWidth: 260)
            Toggle("Failures only", isOn: $failuresOnly)
                .toggleStyle(.checkbox)
                .font(Font(MacFont.ui(12)))
            Spacer()
            Text("\(filtered.count) of \(entries.count)")
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
            Toggle("Live", isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Button("Reload", action: reload)
            Button("Clear") {
                appState.bridge.clearRequestLog()
                reload()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var requestTable: some View {
        Table(filtered, selection: $selectedID) {
            TableColumn("Method") { e in
                Text(e.method)
                    .font(Font(MacFont.ui(11, weight: .semibold)))
                    .foregroundStyle(e.method.hasPrefix("POST") ? theme.accent2 : theme.ink2)
            }
            .width(80)
            TableColumn("Status") { e in
                Text(e.status == 0 ? "—" : "\(e.status)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(statusColor(e))
            }
            .width(52)
            TableColumn("URL") { e in
                Text(shortURL(e.url))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .help(e.url)
            }
            TableColumn("Duration") { e in
                Text("\(e.durationMs) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            .width(72)
            TableColumn("Size") { e in
                Text(bytes(e.responseBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            .width(70)
            TableColumn("Time") { e in
                Text(clock(e.startedMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            .width(84)
        }
    }

    private var detailPane: some View {
        ScrollView {
            if let e = selected {
                VStack(alignment: .leading, spacing: 12) {
                    detailField("URL", e.url, mono: true)
                    HStack(spacing: 20) {
                        detailField("Method", e.method)
                        detailField("Status", e.status == 0 ? "— (no response)" : "\(e.status)")
                    }
                    HStack(spacing: 20) {
                        detailField("Duration", "\(e.durationMs) ms")
                        detailField("Request", bytes(e.requestBytes))
                        detailField("Response", bytes(e.responseBytes))
                    }
                    detailField("When", fullClock(e.startedMs))
                    if let error = e.error {
                        detailField("Error", error, tint: Color(hex: "CE514D"))
                    }
                    if let payload = e.payload {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PAYLOAD")
                                .font(Font(MacFont.ui(10, weight: .bold)))
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
                .padding(14)
            } else {
                Text("Select a request")
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
            }
        }
        .background(theme.surface)
    }

    private func detailField(_ label: String, _ value: String, mono: Bool = false, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Font(MacFont.ui(10, weight: .bold)))
                .foregroundStyle(theme.ink3)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : Font(MacFont.ui(12.5)))
                .foregroundStyle(tint ?? theme.ink)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private func reload() {
        entries = appState.bridge.getRequestLog(limit: 500)
    }

    private func statusColor(_ e: URequestLogEntry) -> Color {
        if e.error != nil || e.status == 0 { return Color(hex: "CE514D") }
        if e.status >= 400 { return Color(hex: "CE514D") }
        if e.status >= 300 { return theme.accent2 }
        return theme.sage
    }

    private func shortURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://archiveofourown.org", with: "")
    }

    private func bytes(_ n: Int64) -> String {
        if n <= 0 { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }

    private func clock(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private func fullClock(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
