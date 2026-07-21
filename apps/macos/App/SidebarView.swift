import SwiftUI

/// The navigation source list — SwiftUI hosted inside the AppKit split view.
/// Layout, colors, and grouping follow the Hush macOS handoff; all counts and
/// collections come from the shared AppState.
struct SidebarView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var privacyShown = false
    @State private var torPulse = false

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
                        item(.authors, "person", "Authors",
                             count: model.followedAuthorNames.count + model.followedAuthors.count)
                        item(.browse, "safari", "Browse")
                    }
                    group("Following") {
                        item(.whatsNew, "bell.badge", "What\u{2019}s New", badge: appState.newWorkIDs.count)
                        item(.subscriptions, "bell", "Subscriptions")
                        item(.inbox, "tray", "Inbox", badge: appState.inboxUnreadCount)
                    }
                    group("Saved") {
                        item(.bookmarks, "bookmark", "Bookmarks", count: appState.bookmarkedWorkIDs.count)
                        item(.downloads, "arrow.down.circle", "Offline", count: appState.downloadedWorkIDs.count)
                        item(.stats, "chart.bar", "Reading Stats")
                    }
                    if !appState.readingLists.isEmpty {
                        group("Collections") {
                            ForEach(appState.readingLists, id: \.id) { list in
                                collectionRow(list)
                            }
                        }
                    }
                    if !model.search.savedSearches.isEmpty {
                        group("Saved Searches") {
                            ForEach(model.search.savedSearches, id: \.id) { saved in
                                savedSearchRow(saved)
                            }
                        }
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
            (Text("AoYO").foregroundStyle(theme.ink) + Text(".").foregroundStyle(theme.accent))
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

    private func savedSearchRow(_ saved: USavedSearch) -> some View {
        Button {
            model.goSection(.search)
            model.search.runSavedSearch(saved, appState: appState)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "star")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(theme.ink3)
                Text(saved.name)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
        .padding(.horizontal, 8)
        .contextMenu {
            Button("Delete Saved Search", role: .destructive) {
                model.search.deleteSavedSearch(saved.id, appState: appState)
            }
        }
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
        let selected = effectiveSection == section && model.selectedReadingListID == nil
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
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(selected ? Color.white.opacity(0.3) : theme.accent)
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

    private func collectionRow(_ list: UReadingList) -> some View {
        let selected = model.selectedReadingListID == list.id
        let count = appState.worksInReadingList(list.id).count
        return Button {
            model.goReadingList(list.id)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected ? theme.onAccent : theme.accent2)
                    .frame(width: 9, height: 9)
                Text(list.name)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(selected ? theme.onAccent : theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(Font(MacFont.ui(11, weight: .bold)))
                    .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.25) : theme.ink.opacity(0.08))
                    .clipShape(Capsule())
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

    /// The app-state hub pill: connection on the first line, identity on the
    /// second. Clicking opens the full hub (circuit controls, inline sign-in).
    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                privacyShown = true
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(torConnected ? theme.sage : torConnecting ? theme.accent2 : theme.ink3)
                        .frame(width: 8, height: 8)
                        .shadow(color: (torConnected ? theme.sage : torConnecting ? theme.accent2 : theme.ink3).opacity(0.4), radius: 3)
                        .opacity(torConnecting ? (torPulse ? 1.0 : 0.3) : 1.0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(torConnected ? "Private · Tor" : connectionLine)
                            .font(Font(MacFont.ui(12.5, weight: .bold)))
                            .foregroundStyle(theme.ink)
                        HStack(spacing: 4) {
                            Image(systemName: identityIcon)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(identityNeedsAttention ? theme.accent2 : theme.ink3)
                            Text(identityLine)
                                .font(Font(MacFont.ui(11)))
                                .foregroundStyle(identityNeedsAttention ? theme.accent2 : theme.ink3)
                        }
                    }
                    Spacer()
                    if torConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: torConnected ? "checkmark.shield" : "shield")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(torConnected ? theme.sage : theme.ink3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(torConnecting
                    ? theme.accent2.opacity(0.1)
                    : theme.sage.opacity(torConnected ? 0.12 : 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $privacyShown, arrowEdge: .top) {
                PrivacyPopoverView(theme: theme, appState: appState, model: model)
            }
            .onChange(of: torConnecting) { _, connecting in
                if connecting {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        torPulse = true
                    }
                } else {
                    withAnimation(.default) { torPulse = false }
                }
            }
        }
        .padding(.init(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) {
            theme.line.frame(height: 1)
        }
    }

    private var connectionLine: String {
        if appState.isResolvingCloudflare { return "Resolving challenge…" }
        if appState.isTestingCircuit { return "Testing circuit \(appState.circuitAttempt)…" }
        if appState.torStatus == .connecting { return "Connecting…" }
        return "Not connected"
    }

    private var identityLine: String {
        if appState.needsReauth { return "Session expired — sign back in" }
        if let account = appState.ao3Username { return account }
        return "Not signed in"
    }

    private var identityIcon: String {
        appState.needsReauth ? "person.badge.clock" : "person"
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
