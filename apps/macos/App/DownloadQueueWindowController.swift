import AppKit
import SwiftUI

/// A window that shows and controls the download queue. The queue
/// downloads one work of each source at a time, the sources side by
/// side, so the window is a tab a source: what that source's lane is
/// doing, its work in flight, everything of it still queued, and the
/// requests the work in flight needs, by name, as they become known. A
/// strip above the tabs gives every source's progress at a glance, and
/// Pause / Resume for the whole queue: a pause takes effect once the
/// works in flight have finished in full; until then the window shows it
/// is waiting.
final class DownloadQueueWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState) {
        let host = NSHostingController(rootView: DownloadQueueView(theme: theme, appState: appState))
        let window = NSWindow(contentViewController: host)
        window.title = "Download Queue"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 600))
        window.minSize = NSSize(width: 640, height: 380)
        window.setFrameAutosaveName("DownloadQueueWindow")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        self.init(window: window)
    }

    func show() {
        if let window, !window.isVisible, window.frameAutosaveName.isEmpty {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DownloadQueueView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var now = Date()
    /// The tab showing. Set when the window appears and by a click; a
    /// source that is gone falls back to the first tab.
    @State private var selectedSource: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let warning = Color(hex: "CE514D")

    private var monitor: DownloadQueueMonitor { appState.downloadQueue }

    /// The lane of the tab showing.
    private var lane: DownloadQueueLane? {
        selectedSource.flatMap { monitor.lane($0) } ?? monitor.lanes.first
    }

    /// The tab a freshly opened window shows: a source that is
    /// downloading, else one with something queued, else the first.
    private var defaultSource: String? {
        (monitor.lanes.first { $0.current != nil }
            ?? monitor.lanes.first { $0.queuedCount > 0 }
            ?? monitor.lanes.first)?.id
    }

    var body: some View {
        let _ = theme.uiFontScale
        VStack(spacing: 0) {
            summary
            Divider()
            tabs
            if let lane {
                header(lane)
                Divider()
                HSplitView {
                    queue(lane)
                        .frame(minWidth: 300, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    requests(lane)
                        .frame(minWidth: 280, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Spacer()
            }
        }
        .background(theme.bg)
        .onReceive(timer) { tick in
            now = tick
            // A held work becomes due on the clock, not on an event.
            if monitor.hasHeld, Int(tick.timeIntervalSince1970) % 15 == 0 {
                appState.refreshDownloadQueue()
            }
        }
        .onAppear {
            appState.watchDownloadQueue(true)
            if selectedSource == nil { selectedSource = defaultSource }
        }
        .onDisappear { appState.watchDownloadQueue(false) }
    }

    // MARK: - Summary: every source's progress, pause

    private var summary: some View {
        let active = monitor.lanes.filter { $0.total > 0 }
        return HStack(alignment: .center, spacing: 12) {
            if active.isEmpty {
                Text("Nothing to download")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 0) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { i, lane in
                        summaryEntry(lane, last: i == active.count - 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if monitor.state == .pausing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("Finishing downloads in flight…")
                        .font(Font(MacFont.ui(11, weight: .semibold)))
                        .foregroundStyle(Self.warning)
                        .lineLimit(1)
                }
            }
            if monitor.paused {
                controlButton("Resume", symbol: "play.fill", fill: theme.accent) {
                    appState.setDownloadQueuePaused(false)
                }
            } else {
                controlButton("Pause", symbol: "pause.fill", fill: theme.accent2) {
                    appState.setDownloadQueuePaused(true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surface)
    }

    /// One source's progress: its badge and "5 of 23" — the work its
    /// lane is on out of the run it is working through.
    private func summaryEntry(_ lane: DownloadQueueLane, last: Bool) -> some View {
        let ink = lane.current != nil ? theme.ink : lane.remaining > 0 ? theme.ink2 : theme.ink3
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                SourceBadgeView(source: lane.id, size: 13)
                Text("\(lane.position) of \(lane.total)")
                    .font(Font(MacFont.ui(12, weight: lane.current != nil ? .semibold : .regular)))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .help(lane.inFlight ? "\(lane.name): downloading \(lane.position) of \(lane.total)"
                                : "\(lane.name): \(lane.completed) of \(lane.total) downloaded")
            Text("|")
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.line)
                .padding(.horizontal, 10)
                .opacity(last ? 0 : 1)
        }
        .padding(.vertical, 3)
    }

    private func controlButton(_ label: String, symbol: String, fill: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(label).font(Font(MacFont.ui(12, weight: .semibold)))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tabs: one a source

    private var tabs: some View {
        FlowLayout(spacing: 2) {
            ForEach(monitor.lanes) { lane in
                tab(lane)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            theme.line.frame(height: 1)
        }
    }

    private func tab(_ lane: DownloadQueueLane) -> some View {
        let selected = lane.id == self.lane?.id
        let ink = selected ? theme.ink : theme.ink3
        return Button {
            selectedSource = lane.id
        } label: {
            HStack(spacing: 6) {
                SourceBadgeView(source: lane.id, size: 13)
                Text(lane.name)
                    .font(Font(MacFont.ui(13, weight: .semibold)))
                    .lineLimit(1)
                if lane.current != nil {
                    Circle()
                        .fill(lane.state == .pausing ? Self.warning : theme.accent)
                        .frame(width: 6, height: 6)
                }
                if lane.queuedCount > 0 {
                    Text("\(lane.queuedCount)")
                        .font(Font(MacFont.ui(10, weight: .bold)))
                        .monospacedDigit()
                        .foregroundStyle(theme.ink3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.surface2)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(selected ? theme.bg : .clear)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
            .overlay(alignment: .bottom) {
                (selected ? theme.accent : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header: the source's state, summary

    private func header(_ lane: DownloadQueueLane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                stateBadge(lane.state)
                Text(headline(lane))
                    .font(Font(MacFont.ui(15, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                Text(lane.queuedCount == 0 ? "" : "\(lane.queuedCount) queued")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            Text(detailLine(lane))
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink2)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateBadge(_ state: ContentQueueState) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .idle: return ("Idle", theme.ink3)
            case .working: return ("Downloading", theme.accent)
            case .pausing: return ("Pausing", Self.warning)
            case .paused: return ("Paused", theme.accent2)
            case .blocked: return ("Waiting", theme.accent2)
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

    private func headline(_ lane: DownloadQueueLane) -> String {
        switch lane.state {
        case .idle:
            if lane.upNext.isEmpty && lane.held.isEmpty { return "Nothing to download" }
            return lane.upNext.isEmpty ? "Waiting to retry" : "Between downloads"
        case .working:
            return lane.current.map { "Downloading \($0.title)" } ?? "Downloading"
        case .pausing: return "Finishing the current download"
        case .paused: return "Paused"
        case .blocked: return "Waiting for a private connection"
        }
    }

    private func detailLine(_ lane: DownloadQueueLane) -> String {
        switch lane.state {
        case .pausing:
            return "The queue pauses as soon as this work is completely downloaded. Nothing else will start."
        case .paused:
            return "Nothing from \(lane.name) is downloading. Queued works keep their place until you resume."
        case .blocked:
            return "Nothing can be sent in the current privacy mode. The queue carries on when it can."
        case .idle, .working:
            var parts: [String] = []
            if !lane.upNext.isEmpty { parts.append("\(lane.upNext.count) up next") }
            if !lane.held.isEmpty { parts.append("\(lane.held.count) waiting to retry") }
            if !lane.gaveUp.isEmpty { parts.append("\(lane.gaveUp.count) gave up") }
            return parts.isEmpty ? "Works from \(lane.name) are downloaded here, one at a time."
                                 : parts.joined(separator: " · ")
        }
    }

    // MARK: - Queue

    private func queue(_ lane: DownloadQueueLane) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let current = lane.current {
                    Section(header: sectionHeader(lane.state == .pausing ? "In flight · finishing before the pause" : "In flight")) {
                        currentRow(current, startedAt: lane.currentStartedAt)
                    }
                }
                if !lane.upNext.isEmpty {
                    Section(header: sectionHeader("Up next · \(lane.upNext.count)")) {
                        ForEach(Array(lane.upNext.enumerated()), id: \.element.workId) { i, item in
                            itemRow(item, lead: "\(i + 1)", note: nil, noteColor: theme.ink3)
                        }
                    }
                }
                if !lane.held.isEmpty {
                    Section(header: sectionHeader("Waiting to retry · \(lane.held.count)")) {
                        ForEach(lane.held, id: \.workId) { item in
                            itemRow(item, lead: "…", note: heldNote(item), noteColor: theme.ink3)
                        }
                    }
                }
                if !lane.gaveUp.isEmpty {
                    Section(header: sectionHeader("Gave up · \(lane.gaveUp.count)")) {
                        ForEach(lane.gaveUp, id: \.workId) { item in
                            itemRow(item, lead: "×",
                                    note: "Failed \(item.attempts) times, left until the work changes. \(item.lastError)",
                                    noteColor: Self.warning)
                        }
                    }
                }
                if lane.queuedCount == 0 {
                    Text("Nothing queued.")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .padding(14)
                }
            }
        }
    }

    // MARK: - Requests of the work in flight

    private func requests(_ lane: DownloadQueueLane) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: sectionHeader(requestsTitle(lane))) {
                    if let current = lane.current {
                        ForEach(Array(lane.steps.enumerated()), id: \.offset) { _, step in
                            stepRow(step, work: current.title)
                        }
                        if lane.steps.isEmpty {
                            requestsNote("Working out what this work needs…")
                        }
                    } else {
                        requestsNote("Nothing from \(lane.name) is downloading. The requests of its next work appear here.")
                    }
                }
            }
        }
    }

    private func requestsTitle(_ lane: DownloadQueueLane) -> String {
        guard lane.current != nil, !lane.steps.isEmpty else { return "Requests" }
        let done = lane.steps.filter { $0.state == .done || $0.state == .failed }.count
        return "Requests · \(done) of \(lane.steps.count)"
    }

    private func requestsNote(_ text: String) -> some View {
        Text(text)
            .font(Font(MacFont.ui(12)))
            .foregroundStyle(theme.ink3)
            .padding(14)
    }

    /// One request by name: the work, then each part down to the request
    /// itself ("Title › Chapter 3 › Page 2 of 5").
    private func stepRow(_ step: UContentQueueStep, work: String) -> some View {
        let active = step.state == .active
        return HStack(spacing: 8) {
            stepMark(step.state)
                .frame(width: 16, height: 14)
            Text(work)
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            ForEach(Array(step.parts.enumerated()), id: \.offset) { i, part in
                Text("›")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                Text(part)
                    .font(Font(MacFont.ui(12, weight: active && i == step.parts.count - 1 ? .semibold : .regular)))
                    .foregroundStyle(step.state == .failed ? Self.warning
                                     : step.state == .pending ? theme.ink3 : theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(active ? theme.accentSoft.opacity(0.35) : Color.clear)
    }

    @ViewBuilder
    private func stepMark(_ state: StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(theme.ink3)
        case .active:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.accent)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Self.warning)
        }
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

    private func currentRow(_ item: UContentQueueItem, startedAt: Date?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 26, height: 14)
            Text(item.title)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            if let startedAt {
                Text(Self.elapsed(since: startedAt, now: now))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.accentSoft.opacity(0.35))
    }

    private func itemRow(_ item: UContentQueueItem, lead: String, note: String?, noteColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(lead)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 26, alignment: .trailing)
                Text(item.title)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Spacer()
                if item.attempts > 0 && item.attempts < item.maxAttempts {
                    Text("try \(item.attempts + 1) of \(item.maxAttempts)")
                        .font(Font(MacFont.ui(10)))
                        .foregroundStyle(theme.ink3)
                }
            }
            if let note {
                Text(note)
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(noteColor)
                    .lineLimit(2)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func heldNote(_ item: UContentQueueItem) -> String {
        let secs = max(0, Int(item.retryAt) - Int(now.timeIntervalSince1970))
        let wait = secs < 60 ? "under a minute" : "\(secs / 60) min"
        return item.lastError.isEmpty ? "Next try in \(wait)." : "Next try in \(wait). \(item.lastError)"
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
