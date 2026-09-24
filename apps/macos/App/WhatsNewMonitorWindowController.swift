import AppKit
import SwiftUI

/// A floating-capable window that shows and controls the What's New check:
/// the queue the run is working through, the item in flight, what each
/// finished item came back with, and Start / Pause / Stop. Movable and
/// resizable like the log windows; "Keep on top" raises it above the main
/// window so it stays visible while the app is in front.
final class WhatsNewMonitorWindowController: NSWindowController {
    private static let keepOnTopKey = "whatsNewMonitorKeepOnTop"

    convenience init(theme: AppTheme, appState: AppState) {
        let host = NSHostingController(rootView: WhatsNewMonitorView(theme: theme, appState: appState))
        let window = NSWindow(contentViewController: host)
        window.title = "What's New Check"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 600))
        window.minSize = NSSize(width: 420, height: 380)
        window.setFrameAutosaveName("WhatsNewMonitorWindow")
        window.isReleasedWhenClosed = false
        // A floating window must not vanish when the main window hides
        // behind another app's; it follows the app's activation instead.
        window.hidesOnDeactivate = false
        self.init(window: window)
        applyKeepOnTop(UserDefaults.standard.bool(forKey: Self.keepOnTopKey))
    }

    func show() {
        if let window, !window.isVisible, window.frameAutosaveName.isEmpty {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Raise the window above the main window (floating level) or return it
    /// to the normal stack. Persisted so the choice survives relaunch.
    func applyKeepOnTop(_ on: Bool) {
        window?.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: Self.keepOnTopKey)
    }

    static var keepOnTopPreference: Bool {
        UserDefaults.standard.bool(forKey: keepOnTopKey)
    }
}

struct WhatsNewMonitorView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var keepOnTop = WhatsNewMonitorWindowController.keepOnTopPreference
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var monitor: SubscriptionCheckMonitor { appState.checkMonitor }

    var body: some View {
        let _ = theme.uiFontScale
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            queue
        }
        .background(theme.bg)
        .onReceive(timer) { now = $0 }
        .onAppear { keepOnTop = WhatsNewMonitorWindowController.keepOnTopPreference }
    }

    // MARK: - Header: phase, summary, progress

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                phaseBadge
                Text(headline)
                    .font(Font(MacFont.ui(15, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                Text(counts)
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            if let fraction = monitor.fraction, monitor.isRunning || monitor.doneCount > 0 {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
            }
            Text(detailLine)
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink2)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surface)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = {
            switch monitor.phase {
            case .idle: return ("Idle", theme.ink3)
            case .connecting: return ("Connecting", theme.accent2)
            case .running: return ("Running", theme.accent)
            case .pausedByUser: return ("Paused", theme.accent2)
            case .pausedForBrowsing: return ("Yielding", theme.accent2)
            case .stopping: return ("Stopping", Color(hex: "CE514D"))
            }
        }()
        return Text(label.uppercased())
            .font(Font(MacFont.ui(10, weight: .bold)))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private var headline: String {
        switch monitor.phase {
        case .idle:
            if monitor.completed.isEmpty {
                return monitor.pending.isEmpty ? "No check running" : "Check paused with items queued"
            }
            return "Last check finished"
        case .connecting: return "Waiting for Tor"
        case .running:
            if let c = monitor.current { return c.census ? "Census: \(c.name)" : "Checking \(c.name)" }
            return "Checking"
        case .pausedByUser: return "Paused"
        case .pausedForBrowsing: return "Paused while you browse"
        case .stopping: return "Finishing current item"
        }
    }

    private var counts: String {
        guard monitor.total > 0 else { return "" }
        return "\(monitor.doneCount) of \(monitor.total)"
    }

    private var detailLine: String {
        var parts: [String] = []
        if monitor.updatedCount > 0 { parts.append("\(monitor.updatedCount) updated") }
        if monitor.failedCount > 0 { parts.append("\(monitor.failedCount) failed") }
        if !monitor.pending.isEmpty { parts.append("\(monitor.pending.count) queued") }
        if let err = monitor.runError { parts.append(err) }
        if monitor.phase == .idle, let at = monitor.finishedAt {
            parts.append("finished \(Self.clock(at))")
        } else if monitor.isRunning, let at = monitor.startedAt {
            parts.append("running \(Self.elapsed(since: at, now: now))")
        }
        if parts.isEmpty {
            if let last = appState.bridge.getLastSubscriptionCheck(), !last.isEmpty {
                return "Last completed check: \(last)"
            }
            return "Start a check to see progress here."
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if monitor.isRunning {
                if monitor.phase == .pausedByUser {
                    controlButton("Resume", symbol: "play.fill", fill: theme.accent) {
                        appState.resumeSubscriptionCheck()
                    }
                } else {
                    controlButton("Pause", symbol: "pause.fill", fill: theme.accent2,
                                  disabled: monitor.phase == .stopping || monitor.phase == .connecting) {
                        appState.pauseSubscriptionCheck()
                    }
                }
                controlButton("Stop", symbol: "stop.fill", fill: Color(hex: "CE514D"),
                              disabled: monitor.phase == .stopping) {
                    appState.stopSubscriptionCheck()
                }
            } else {
                controlButton(monitor.pending.isEmpty ? "Start" : "Resume", symbol: "play.fill", fill: theme.accent,
                              disabled: appState.ao3Username == nil) {
                    appState.startSubscriptionCheck(all: false)
                }
                controlButton("Check All", symbol: "arrow.clockwise", fill: theme.accent2,
                              disabled: appState.ao3Username == nil) {
                    appState.startSubscriptionCheck(all: true)
                }
            }
            Spacer()
            Toggle("Keep on top", isOn: $keepOnTop)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink2)
                .onChange(of: keepOnTop) { _, on in
                    (NSApp.delegate as? AppDelegate)?.whatsNewMonitor?.applyKeepOnTop(on)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func controlButton(_ label: String, symbol: String, fill: Color, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(label).font(Font(MacFont.ui(12, weight: .semibold)))
            }
            .foregroundStyle(disabled ? theme.ink3 : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(disabled ? theme.surface2 : fill)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Queue

    private var queue: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let current = monitor.current {
                        Section(header: sectionHeader("In flight")) {
                            currentRow(current)
                        }
                    }
                    if !monitor.pending.isEmpty {
                        Section(header: sectionHeader("Up next · \(monitor.pending.count)")) {
                            // The head of the queue is the in-flight item
                            // until the core pops it; don't list it twice.
                            ForEach(Array(pendingRows.enumerated()), id: \.offset) { i, item in
                                pendingRow(item, position: i + 1)
                            }
                        }
                    }
                    if !monitor.completed.isEmpty {
                        Section(header: sectionHeader("Done · \(monitor.completed.count)")) {
                            ForEach(monitor.completed.reversed()) { c in
                                completedRow(c)
                            }
                        }
                    }
                    if monitor.current == nil && monitor.pending.isEmpty && monitor.completed.isEmpty {
                        Text("Nothing queued.")
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink3)
                            .padding(14)
                    }
                }
            }
        }
    }

    private var pendingRows: [UCheckQueueItem] {
        guard let current = monitor.current, let first = monitor.pending.first,
              first.subType == current.subType, first.subId == current.subId, first.census == current.census
        else { return monitor.pending }
        return Array(monitor.pending.dropFirst())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Font(MacFont.ui(10, weight: .bold)))
            .foregroundStyle(theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.surface)
    }

    private func currentRow(_ item: UCheckQueueItem) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            kindBadge(item)
            Text(item.name)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            if let at = monitor.currentStartedAt {
                Text(Self.elapsed(since: at, now: now))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.accentSoft.opacity(0.35))
    }

    private func pendingRow(_ item: UCheckQueueItem, position: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.ink3)
                .frame(width: 26, alignment: .trailing)
            kindBadge(item)
            Text(item.name)
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func completedRow(_ c: SubscriptionCheckMonitor.Completed) -> some View {
        let (symbol, color, note): (String, Color, String?) = {
            switch c.outcome {
            case .updated: return ("sparkles", theme.accent, "updated")
            case .unchanged: return ("checkmark", theme.ink3, nil)
            case .failed(let msg): return ("xmark", Color(hex: "CE514D"), msg)
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 26)
                kindBadge(c.item)
                Text(c.item.name)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                if c.outcome == .updated {
                    Text("updated")
                        .font(Font(MacFont.ui(10, weight: .bold)))
                        .foregroundStyle(theme.accent)
                }
                Text(Self.clock(c.finishedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
            if case .failed = c.outcome, let note {
                Text(note)
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .lineLimit(2)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func kindBadge(_ item: UCheckQueueItem) -> some View {
        let label: String = {
            if item.census { return "CENSUS" }
            switch item.subType {
            case "author": return "AUTHOR"
            case "series": return "SERIES"
            case "work": return "WORK"
            default: return item.subType.uppercased()
            }
        }()
        return Text(label)
            .font(Font(MacFont.ui(9, weight: .bold)))
            .foregroundStyle(item.census ? theme.accent2 : theme.ink3)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: 58, alignment: .leading)
    }

    // MARK: - Formatting

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
