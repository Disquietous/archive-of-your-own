import SwiftUI

/// The navigation source list — SwiftUI hosted inside the AppKit split view.
/// Layout, colors, and grouping follow the Hush macOS handoff; all counts and
/// collections come from the shared AppState.
struct SidebarView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var privacyShown = false
    @State private var requestingNewNodes = false
    @State private var pillHover = false
    @State private var shieldHover = false
    @State private var circuitInfoShown = false

    /// Hub-pill hover, minus the shield: hovering the shield triggers the
    /// shield's own action, so only it should light up — not the whole pill.
    private var hubHover: Bool {
        pillHover && !shieldHover
    }

    var body: some View {
        // Track the app text-size setting: MacFont reads it via a plain static,
        // so this observable read is what re-renders the sidebar when it changes.
        let _ = theme.uiFontScale
        return VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 6) {
                    topGroup
                    group("Discover") {
                        item(.fandoms, "flame", "Fandoms", count: model.followedFandoms.count)
                        item(.collections, "square.grid.2x2", "Collections")
                        item(.authors, "person", "Authors",
                             count: model.followedAuthorNames.count + model.followedAuthors.count)
                        item(.browse, "safari", "Browse")
                    }
                    group("Following") {
                        item(.whatsNew, "bell.badge", "What\u{2019}s New", badge: appState.newUnviewedWorkCount)
                        item(.subscriptions, "bell", "Subscriptions")
                        item(.inbox, "tray", "Inbox", badge: appState.inboxUnreadCount)
                    }
                    group("Saved") {
                        item(.bookmarks, "bookmark", "Bookmarks", count: appState.bookmarkedWorkIDs.count)
                        item(.readingLists, "books.vertical", "Reading Lists", count: appState.readingLists.count)
                        item(.downloads, "arrow.down.circle", "Offline", count: appState.downloadedWorkIDs.count)
                        item(.stats, "chart.bar", "Reading Stats")
                    }
                }
                .padding(.bottom, 8)
            }
            footer
        }
        .background(theme.sidebarFill)
        .overlay(alignment: .trailing) {
            theme.line.frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            // Leading space clears the system traffic lights.
            Spacer().frame(width: 62)
            Text("AoYO")
                .foregroundStyle(theme.ink)
                .font(Font(MacFont.serif(21, weight: .semibold)))
            Spacer()
        }
        .frame(height: 52)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
    }

    private var topGroup: some View {
        VStack(spacing: 1) {
            item(.reading, "book", "Currently Reading", count: model.currentlyReading.count)
            item(.search, "magnifyingglass", "Search")
            item(.history, "clock", "History")
        }
        .padding(.top, 6)
    }

    private func group(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(label.uppercased())
                    .font(Font(MacFont.ui(10.5, weight: .bold)))
                    .kerning(0.6)
                    .foregroundStyle(theme.ink3)
                Spacer()
            }
            .padding(.init(top: 8, leading: 18, bottom: 4, trailing: 18))
            content()
        }
    }

    private func item(_ section: MacAppModel.Section, _ icon: String, _ label: String,
                      count: Int? = nil, badge: Int = 0) -> some View {
        // Author-works browsing keeps Authors highlighted.
        let effectiveSection = model.section == .authorWorks ? MacAppModel.Section.authors : model.section
        let selected = effectiveSection == section
        return Button {
            model.goSection(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                Text(label)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(selected ? theme.onAccent : theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(Font(MacFont.ui(10.5, weight: .bold)))
                        .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(selected ? Color.white.opacity(0.25) : theme.ink.opacity(0.08))
                        .clipShape(Capsule())
                } else if let count, count > 0 {
                    Text("\(count)")
                        .font(Font(MacFont.ui(11, weight: .bold)))
                        .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : theme.ink.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? theme.accent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
        .padding(.horizontal, 8)
    }


    /// The app-state hub pill: identity on the first line, the circuit's
    /// node country codes on the second. Clicking opens the full hub
    /// (circuit controls, inline sign-in); the shield shows Private (sage) /
    /// Public (red) and requests fresh relay nodes when private.
    ///
    /// Deliberately NOT one big Button: `.help()` tooltips do not fire on
    /// views nested inside a Button's label on macOS, and the hop codes and
    /// shield need working hover balloons. A tap gesture opens the hub.
    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(torConnected ? theme.sage : torConnecting ? theme.accent2 : theme.ink3)
                    .frame(width: 8, height: 8)
                    .shadow(color: (torConnected ? theme.sage : torConnecting ? theme.accent2 : theme.ink3).opacity(0.4), radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identityLine)
                        .font(Font(MacFont.ui(12.5, weight: .bold)))
                        .foregroundStyle(identityNeedsAttention ? theme.accent2 : theme.ink)
                        .lineLimit(1)
                    connectionDetailRow
                }
                Spacer()
                newNodesButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((torConnecting
                ? theme.accent2.opacity(hubHover ? 0.18 : 0.1)
                : theme.sage.opacity(torConnected ? (hubHover ? 0.2 : 0.12) : (hubHover ? 0.14 : 0.07))))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(theme.line.opacity(hubHover ? 1 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: hubHover)
            .contentShape(Rectangle())
            .onHover { inside in
                pillHover = inside
            }
            .onTapGesture { privacyShown = true }
            .popover(isPresented: $privacyShown, arrowEdge: .top) {
                PrivacyPopoverView(theme: theme, appState: appState, model: model)
            }
        }
        .padding(.init(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) {
            theme.line.frame(height: 1)
        }
    }

    /// Second row: while connecting, the progress phase; when connected, the
    /// circuit's Guard/Relay/Exit country-code chips — hovering them raises
    /// a balloon listing every node's role, country, and IP; otherwise the
    /// direct-connection note. Balloons are state-driven popovers, NOT
    /// .help() tooltips — those never fire reliably in this nested hierarchy.
    @ViewBuilder
    private var connectionDetailRow: some View {
        if torConnecting {
            Text(connectionLine)
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
        } else if torConnected {
            let hops = appState.bridge.circuitHops
            if hops.isEmpty {
                // The Rust core reports the path of the circuit that actually
                // carried traffic, so the hop list stays empty until the first
                // stream runs on this circuit — show the generic three-node
                // diagram (roles only, no invented identities) until then.
                HStack(spacing: 4) {
                    ForEach(Self.genericHops, id: \.label) { hop in
                        HStack(spacing: 3) {
                            Image(systemName: hop.icon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(hop.chip)
                                .font(Font(MacFont.ui(10, weight: .bold)))
                                .kerning(0.3)
                        }
                        .foregroundStyle(theme.ink2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.ink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .onHover { inside in
                    // Traffic may have flowed since the last refresh point —
                    // re-read so the first hover can already show real nodes.
                    if inside { appState.bridge.refreshCircuitHops() }
                    circuitInfoShown = inside
                }
                .popover(isPresented: $circuitInfoShown, arrowEdge: .top) {
                    genericCircuitBalloon
                }
            } else {
                // The real path: one chip per node, role icon plus the
                // relay's country code (or its IP when GeoIP has no entry).
                HStack(spacing: 4) {
                    ForEach(Array(hops.enumerated()), id: \.offset) { _, hop in
                        HStack(spacing: 3) {
                            Image(systemName: Self.roleIcon(hop.role))
                                .font(.system(size: 8, weight: .semibold))
                            Text(hop.country.isEmpty ? hop.address : hop.country.uppercased())
                                .font(Font(MacFont.ui(10, weight: .bold)))
                                .kerning(0.3)
                        }
                        .foregroundStyle(theme.ink2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.ink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .onHover { inside in
                    if inside { appState.bridge.refreshCircuitHops() }
                    circuitInfoShown = inside
                }
                .popover(isPresented: $circuitInfoShown, arrowEdge: .top) {
                    circuitBalloon
                }
            }
        } else {
            Text("Direct connection")
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
        }
    }

    /// The generic three-hop circuit shown before any stream has run on the
    /// current circuit: roles only — the real nodes appear once traffic flows.
    static let genericHops: [(icon: String, chip: String, label: String)] = [
        ("shield.lefthalf.filled", "GUARD", "Guard"),
        ("arrow.triangle.swap", "RELAY", "Middle relay"),
        ("arrow.up.forward", "EXIT", "Exit"),
    ]

    /// SF Symbol for a hop role reported by the Rust core.
    static func roleIcon(_ role: String) -> String {
        switch role {
        case "Guard": "shield.lefthalf.filled"
        case "Exit": "arrow.up.forward"
        default: "arrow.triangle.swap"
        }
    }

    /// Hover balloon for the generic circuit: the three roles plus a note
    /// that node identities appear once the circuit carries traffic.
    private var genericCircuitBalloon: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RELAY CIRCUIT")
                .font(Font(MacFont.ui(10, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            ForEach(Self.genericHops, id: \.label) { hop in
                HStack(spacing: 8) {
                    Image(systemName: hop.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.sage)
                        .frame(width: 16)
                    Text(hop.label)
                        .font(Font(MacFont.ui(11.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                }
            }
            Text("No circuit used yet — nodes appear once traffic flows")
                .font(Font(MacFont.ui(10.5)))
                .foregroundStyle(theme.ink3)
        }
        .padding(12)
        .frame(maxWidth: 240, alignment: .leading)
    }

    /// Hover balloon: the full real circuit, one row per node — role icon and
    /// label, the relay's country code (omitted when GeoIP has no entry, never
    /// invented), and its IP address.
    private var circuitBalloon: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RELAY CIRCUIT")
                .font(Font(MacFont.ui(10, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            ForEach(Array(appState.bridge.circuitHops.enumerated()), id: \.offset) { _, hop in
                HStack(spacing: 8) {
                    Image(systemName: Self.roleIcon(hop.role))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.sage)
                        .frame(width: 16)
                    Text(hop.role)
                        .font(Font(MacFont.ui(11.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .frame(width: 42, alignment: .leading)
                    if !hop.country.isEmpty {
                        Text(hop.country.uppercased())
                            .font(Font(MacFont.ui(10, weight: .bold)))
                            .foregroundStyle(theme.ink2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(hop.address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.ink2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
    }

    /// The shield stands for the connection mode: sage = Private (routed
    /// through relays), red = Public (direct). When private, clicking
    /// requests a fresh set of relay nodes; when public, it opens the hub
    /// to connect. Hovering raises an explanatory balloon.
    @ViewBuilder
    private var newNodesButton: some View {
        if torConnecting || requestingNewNodes {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else {
            Button {
                shieldHover = false
                if torConnected {
                    requestingNewNodes = true
                    Task { @MainActor in
                        _ = await appState.newCircuitNow()
                        requestingNewNodes = false
                    }
                } else {
                    privacyShown = true
                }
            } label: {
                Image(systemName: torConnected ? "checkmark.shield" : "xmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(torConnected ? theme.sage : Color(hex: "CE514D"))
                    .frame(width: 26, height: 26)
                    .background((torConnected ? theme.sage : Color(hex: "CE514D"))
                        .opacity(shieldHover ? 0.15 : 0))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { shieldHover = $0 }
            .overlay(alignment: .topTrailing) {
                if shieldHover {
                    shieldBalloon
                }
            }
        }
    }

    /// The shield's hover balloon, drawn in-window rather than as a popover:
    /// a transient popover window swallows the click that dismisses it, which
    /// ate the first click on the shield — the circuit only rotated on the
    /// second try.
    private var shieldBalloon: some View {
        Text(torConnected
             ? "Private connection — click to request new relay nodes"
             : "Public connection — traffic is not routed through relays. Click to connect.")
            .font(Font(MacFont.ui(11.5)))
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(width: 200, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .allowsHitTesting(false)
    }

    private var connectionLine: String {
        if appState.isResolvingCloudflare { return "Resolving challenge…" }
        if appState.isTestingCircuit { return "Testing circuit \(appState.circuitAttempt)…" }
        if appState.torStatus == .connecting { return "Connecting…" }
        return "Not connected"
    }

    private var identityLine: String {
        if appState.needsReauth { return "session expired" }
        if let account = appState.ao3Username { return account }
        return "not signed in"
    }

    private var identityNeedsAttention: Bool {
        appState.needsReauth
    }

    private var torConnected: Bool {
        appState.torStatus.isConnected
    }

    private var torConnecting: Bool {
        appState.torStatus == .connecting || appState.isTestingCircuit || appState.isResolvingCloudflare
    }
}

struct SidebarItemStyle: ButtonStyle {
    let hover: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? hover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}
