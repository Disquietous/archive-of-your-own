import AppKit
import SwiftUI

/// A window that shows and controls the download queue: what the core's
/// worker is doing, the work in flight, everything still queued, and
/// Pause / Resume. A pause takes effect once the work in flight has
/// finished in full; until then the window shows it is waiting. A second
/// panel lists the requests the work in flight needs, by name, as they
/// become known; it starts fresh with each work.
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

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let warning = Color(hex: "CE514D")

    private var monitor: DownloadQueueMonitor { appState.downloadQueue }

    var body: some View {
        let _ = theme.uiFontScale
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            HSplitView {
                queue
                    .frame(minWidth: 300, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                requests
                    .frame(minWidth: 280, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.bg)
        .onReceive(timer) { tick in
            now = tick
            // A held work becomes due on the clock, not on an event.
            if !monitor.held.isEmpty, Int(tick.timeIntervalSince1970) % 15 == 0 {
                appState.refreshDownloadQueue()
            }
        }
        .onAppear { appState.watchDownloadQueue(true) }
        .onDisappear { appState.watchDownloadQueue(false) }
    }

    // MARK: - Header: state, summary

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                stateBadge
                Text(headline)
                    .font(Font(MacFont.ui(15, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                Text(monitor.queuedCount == 0 ? "" : "\(monitor.queuedCount) queued")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
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

    private var stateBadge: some View {
        let (label, color): (String, Color) = {
            switch monitor.state {
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

    private var headline: String {
        switch monitor.state {
        case .idle:
            if monitor.upNext.isEmpty && monitor.held.isEmpty { return "Nothing to download" }
            return monitor.upNext.isEmpty ? "Waiting to retry" : "Between downloads"
        case .working:
            return monitor.current.map { "Downloading \($0.title)" } ?? "Downloading"
        case .pausing: return "Finishing the current download"
        case .paused: return "Paused"
        case .blocked: return "Waiting for a private connection"
        }
    }

    private var detailLine: String {
        switch monitor.state {
        case .pausing:
            return "The queue pauses as soon as this work is completely downloaded. Nothing else will start."
        case .paused:
            return "Nothing is downloading. Queued works keep their place until you resume."
        case .blocked:
            return "Nothing can be sent in the current privacy mode. The queue carries on when it can."
        case .idle, .working:
            var parts: [String] = []
            if !monitor.upNext.isEmpty { parts.append("\(monitor.upNext.count) up next") }
            if !monitor.held.isEmpty { parts.append("\(monitor.held.count) waiting to retry") }
            if !monitor.gaveUp.isEmpty { parts.append("\(monitor.gaveUp.count) gave up") }
            return parts.isEmpty ? "Works added to the library are downloaded here, one at a time."
                                 : parts.joined(separator: " · ")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if monitor.paused {
                controlButton("Resume", symbol: "play.fill", fill: theme.accent) {
                    appState.setDownloadQueuePaused(false)
                }
            } else {
                controlButton("Pause", symbol: "pause.fill", fill: theme.accent2) {
                    appState.setDownloadQueuePaused(true)
                }
            }
            if monitor.state == .pausing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("Waiting for the current download to finish…")
                        .font(Font(MacFont.ui(11, weight: .semibold)))
                        .foregroundStyle(Self.warning)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    // MARK: - Queue

    private var queue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let current = monitor.current {
                    Section(header: sectionHeader(monitor.state == .pausing ? "In flight · finishing before the pause" : "In flight")) {
                        currentRow(current)
                    }
                }
                if !monitor.upNext.isEmpty {
                    Section(header: sectionHeader("Up next · \(monitor.upNext.count)")) {
                        ForEach(Array(monitor.upNext.enumerated()), id: \.element.workId) { i, item in
                            itemRow(item, lead: "\(i + 1)", note: nil, noteColor: theme.ink3)
                        }
                    }
                }
                if !monitor.held.isEmpty {
                    Section(header: sectionHeader("Waiting to retry · \(monitor.held.count)")) {
                        ForEach(monitor.held, id: \.workId) { item in
                            itemRow(item, lead: "…", note: heldNote(item), noteColor: theme.ink3)
                        }
                    }
                }
                if !monitor.gaveUp.isEmpty {
                    Section(header: sectionHeader("Gave up · \(monitor.gaveUp.count)")) {
                        ForEach(monitor.gaveUp, id: \.workId) { item in
                            itemRow(item, lead: "×",
                                    note: "Failed \(item.attempts) times, left until the work changes. \(item.lastError)",
                                    noteColor: Self.warning)
                        }
                    }
                }
                if monitor.queuedCount == 0 {
                    Text("Nothing queued.")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .padding(14)
                }
            }
        }
    }

    // MARK: - Requests of the work in flight

    private var requests: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: sectionHeader(requestsTitle)) {
                    if let current = monitor.current {
                        ForEach(Array(monitor.steps.enumerated()), id: \.offset) { _, step in
                            stepRow(step, work: current.title)
                        }
                        if monitor.steps.isEmpty {
                            requestsNote("Working out what this work needs…")
                        }
                    } else {
                        requestsNote("Nothing is downloading. The requests of the next work appear here.")
                    }
                }
            }
        }
    }

    private var requestsTitle: String {
        guard monitor.current != nil, !monitor.steps.isEmpty else { return "Requests" }
        let done = monitor.steps.filter { $0.state == .done || $0.state == .failed }.count
        return "Requests · \(done) of \(monitor.steps.count)"
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

    private func currentRow(_ item: UContentQueueItem) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 26, height: 14)
            sourceBadge(item)
            Text(item.title)
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

    private func itemRow(_ item: UContentQueueItem, lead: String, note: String?, noteColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(lead)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 26, alignment: .trailing)
                sourceBadge(item)
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

    private func sourceBadge(_ item: UContentQueueItem) -> some View {
        Text(item.sourceName.uppercased())
            .font(Font(MacFont.ui(9, weight: .bold)))
            .foregroundStyle(theme.ink3)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: 96, alignment: .leading)
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
