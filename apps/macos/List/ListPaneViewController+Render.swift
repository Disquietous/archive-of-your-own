import AppKit
import SwiftUI

// MARK: - Render

extension ListPaneViewController {
    func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()

        // Density and app text size change row metrics — drop the rendered-ID
        // caches so the table reloads and re-measures. (Reading them here also
        // makes the relay re-render when the settings change.)
        if renderedDensity != theme.density || renderedUIScale != theme.uiFontScale {
            renderedDensity = theme.density
            renderedUIScale = theme.uiFontScale
            renderedWorkIDs = []
            renderedSubscriptionIDs = []
        }

        let section = model.section
        switch section {
        case .authorWorks:
            break

        case .search, .settings, .browse:
            // The list pane is collapsed for Search and Settings — the
            // reading pane hosts the whole flow. Nothing to render here.
            break

        case .reading, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = sectionMeta(for: section)
            let downloading = section == .reading ? bulkDownload.statusSuffix : ""
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)\(downloading)")
            toolbar.setLeading([])
            var trailing: [NSView] = [sortFilterMenu.makeButton(for: section), worksFilterButton(for: section)]
            if section == .reading && !works.isEmpty {
                trailing.insert(removeAllReadingButton(), at: 0)
                trailing.insert(bulkDownload.update(ids: works.map(\.id)), at: 0)
            }
            if section == .history && !works.isEmpty {
                trailing.insert(clearHistoryButton(), at: 0)
            }
            toolbar.setTrailing(trailing)
            let empty = works.isEmpty
                ? AnyView(EmptyStateMac(theme: theme, icon: meta.empty.0, title: meta.empty.1, message: meta.empty.2))
                : nil
            showWorksContent(section: section, header: nil, overlay: empty)

        case .whatsNew:
            do {
                works = model.works(for: .whatsNew)
                let checkSub: String
                if works.isEmpty {
                    checkSub = "No updates"
                } else {
                    checkSub = "\(works.count) updated"
                }
                toolbar.configure(title: "What's New", sub: checkSub)
                var buttons: [NSView] = []
                if !works.isEmpty {
                    buttons.append(ToolButton(theme: theme, symbol: "trash", tooltip: "Clear all") { [weak self] in
                        self?.appState.clearNewWorks()
                    })
                }
                buttons.append(ToolButton(theme: theme, symbol: "list.bullet.rectangle", tooltip: "Show the check monitor") {
                    (NSApp.delegate as? AppDelegate)?.openWhatsNewMonitor()
                })
                buttons.append(ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check for updates") { [weak self] in
                    guard let self else { return }
                    // A running check owns the queue; clearing it underneath
                    // that loop ends it early and the guard refuses the new
                    // one, so the click would do nothing useful.
                    guard !self.appState.isCheckingWhatsNew else { return }
                    Task {
                        self.appState.bridge.resetWhatsNewCheck()
                        await self.appState.runWhatsNewCheck(force: true)
                    }
                })
                buttons.append(sortFilterMenu.makeButton(for: .whatsNew))
                buttons.append(worksFilterButton(for: .whatsNew))
                toolbar.setLeading([])
                toolbar.setTrailing(buttons)
                let overlay: AnyView?
                if !appState.isCheckingWhatsNew && works.isEmpty {
                    let checkStatus = appState.whatsNewCheckTask.statusMessage
                    overlay = AnyView(EmptyStateMac(theme: theme, icon: "bell",
                                                    title: "Nothing new",
                                                    message: checkStatus ?? "Updates from works and authors you follow appear here."))
                } else {
                    overlay = nil
                }
                showWorksContent(section: section, header: nil, overlay: overlay)
            }

        case .subscriptions:
            do {
                displayedSubscriptions = model.lists.filteredSubscriptions
                works = []
                let subtitle: String
                if appState.isLoadingSubscriptions {
                    subtitle = "Loading from AO3…"
                } else if let err = appState.subscriptionError, !err.isEmpty {
                    subtitle = "Error — \(err)"
                } else {
                    subtitle = "\(displayedSubscriptions.count) subscriptions"
                }
                toolbar.configure(title: "Subscriptions", sub: subtitle)
                let subscriptionsFilter = filterButton(key: "following", active: !model.lists.subscriptionListFilter.isEmpty) { [theme, model] in
                    AnyView(SingleFieldFilterView(theme: theme, model: model,
                                                  title: "Filter Subscriptions",
                                                  placeholder: "Name",
                                                  text: Binding(get: { model.lists.subscriptionListFilter },
                                                                set: { model.lists.subscriptionListFilter = $0 })))
                }
                toolbar.setLeading([])
                toolbar.setTrailing([subscriptionsFilter, ToolButton(theme: theme, symbol: "arrow.down.circle",
                                                                     tooltip: "Refresh list from AO3") { [weak self] in
                    guard let self else { return }
                    guard appState.ao3Username != nil else {
                        appState.subscriptionError = "Sign in to AO3 in Settings first"
                        return
                    }
                    guard !appState.isLoadingSubscriptions else { return }
                    appState.subscriptionError = nil
                    Task { await self.appState.loadSubscriptions(force: true, userInitiated: true) }
                }])
                let overlay: AnyView?
                if let err = appState.subscriptionError, !err.isEmpty, !appState.isLoadingSubscriptions {
                    overlay = AnyView(VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(theme.line2)
                        Text("Couldn't load subscriptions")
                            .font(Font(MacFont.serif(18, weight: .semibold)))
                            .foregroundStyle(theme.ink2)
                        Text(err)
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(theme.bg))
                } else if displayedSubscriptions.isEmpty {
                    overlay = AnyView(EmptyStateMac(theme: theme, icon: "bell",
                                                   title: "No subscriptions",
                                                   message: "Works, series, and authors you subscribe to on AO3 appear here."))
                } else {
                    overlay = nil
                }
                showSubscriptionsContent(section: section, overlay: overlay)
            }

        case .readingLists:
            displayedReadingLists = appState.readingLists
            works = []
            let count = displayedReadingLists.count
            toolbar.configure(title: "Reading Lists",
                              sub: count == 1 ? "1 list" : "\(count) lists")
            toolbar.setLeading([])
            toolbar.setTrailing([ToolButton(theme: theme, symbol: "plus", tooltip: "New reading list") { [weak self] in
                self?.createReadingList()
            }])
            let overlay: AnyView? = displayedReadingLists.isEmpty
                ? AnyView(EmptyStateMac(theme: theme, icon: "books.vertical",
                                        title: "No reading lists",
                                        message: "Create a list here, or right-click any work and choose Add to Reading List."))
                : nil
            showReadingListsContent(section: section, overlay: overlay)

        case .inbox:
            let sub: String
            if appState.isLoadingInbox && appState.inboxMessages.isEmpty {
                sub = "Loading…"
            } else if appState.inboxUnreadCount > 0 {
                sub = "\(appState.inboxUnreadCount) unread"
            } else {
                sub = "\(appState.inboxMessages.count) messages"
            }
            toolbar.configure(title: "Inbox", sub: sub)
            toolbar.setLeading([])
            let inboxFilter = filterButton(key: "inbox", active: !model.lists.inboxFilterAuthor.isEmpty
                                               || !model.lists.inboxFilterWork.isEmpty
                                               || !model.lists.inboxFilterText.isEmpty) { [theme, model] in
                AnyView(InboxFilterView(theme: theme, model: model))
            }
            toolbar.setTrailing([inboxFilter] + inboxToolbarButtons())
            showVariant(InboxView(theme: theme, appState: appState, model: model), section: section)

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(model.follows.followedFandoms.count) followed")
            toolbar.setLeading([])
            toolbar.setTrailing([filterButton(key: "fandoms", active: !model.lists.fandomsListFilter.isEmpty) { [theme, model] in
                AnyView(SingleFieldFilterView(theme: theme, model: model,
                                              title: "Filter Fandoms",
                                              placeholder: "Fandom name",
                                              text: Binding(get: { model.lists.fandomsListFilter },
                                                            set: { model.lists.fandomsListFilter = $0 })))
            }])
            showVariant(FollowedFandomsView(theme: theme, model: model), section: section)

        case .authors:
            // Drill-in: the author's profile replaces the list — their
            // works/bookmarks/collections render in the reading pane.
            if let author = model.author.username {
                toolbar.configure(title: appState.userProfile(author)?.username ?? author,
                                  sub: appState.isLoadingUserProfile(author)
                                      ? "Fetching profile from AO3…" : "Author profile")
                toolbar.setLeading([authorBackButton()])
                toolbar.setTrailing([authorAO3Button(username: author),
                                     authorProfileRefreshButton(username: author),
                                     authorFollowButton(username: author)])
                showAuthorProfileContent(username: author, activePane: model.author.pane)
                break
            }
            let count = model.follows.follows(of: .author).count + model.follows.follows(of: .work).count
                + model.follows.follows(of: .series).count
            toolbar.configure(title: "Following", sub: "\(count) followed")
            toolbar.setLeading([])
            let followButton = ToolButton(theme: theme, symbol: "plus", tooltip: "Follow an author") { [model] in
                model.lists.showFollowAuthorField.toggle()
            }
            followButton.isOn = model.lists.showFollowAuthorField
            toolbar.setTrailing([followButton])
            showVariant(AuthorsList(theme: theme, appState: appState, model: model), section: section)

        case .stats:
            toolbar.configure(title: "Reading Stats", sub: "Counted on device")
            toolbar.setTrailing([])
            showVariant(StatsView(theme: theme, model: model), section: section)
        }
        renderedSection = section
        updateStatusBar(section: section)
    }

    private func updateStatusBar(section: MacAppModel.Section) {
        var message: String?
        var active = false

        switch section {
        case .whatsNew:
            if appState.whatsNewCheckTask.isReconnecting,
               let msg = appState.whatsNewCheckTask.statusMessage {
                message = msg
                active = true
            } else if appState.isCheckingWhatsNew {
                let done = appState.whatsNewCheckTotal - appState.whatsNewCheckRemaining
                message = "Checking \(done) of \(appState.whatsNewCheckTotal)"
                active = true
            } else if let msg = appState.whatsNewCheckTask.statusMessage, !msg.isEmpty {
                message = msg
            }
        case .subscriptions:
            if appState.isLoadingSubscriptions {
                message = "Refreshing subscriptions from AO3…"
                active = true
            }
        case .inbox:
            if appState.isCheckingInbox {
                message = "Checking for new messages…"
                active = true
            } else if appState.isLoadingInbox {
                message = "Loading inbox…"
                active = true
            } else if let msg = appState.inboxCheckTask.statusMessage, !msg.isEmpty {
                message = msg
            }
        default:
            break
        }
        // A bell-menu outcome ("Subscribed on AO3 and followed on this
        // device.") shows here on any section until it auto-clears.
        var isError = false
        if let notice = model.follows.notice {
            message = notice.message
            active = false
            isError = notice.isError
        }

        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = isError ? NSColor(Color(hex: "CE514D")) : theme.nsInk3
            statusBar.layer?.backgroundColor = theme.nsSurface.cgColor
            statusBarHeight.constant = 26
            statusBar.isHidden = false
            if active {
                statusSpinner.startAnimation(nil)
                statusSpinner.isHidden = false
            } else {
                statusSpinner.stopAnimation(nil)
                statusSpinner.isHidden = true
            }
        } else {
            statusBarHeight.constant = 0
            statusBar.isHidden = true
            statusSpinner.stopAnimation(nil)
        }
    }

    private func sectionMeta(for section: MacAppModel.Section) -> (title: String, sub: String, empty: (String, String, String)) {
        switch section {
        case .reading: return ("Currently Reading", "In progress", ("book", "Nothing in progress", "Open a work to begin reading."))
        case .history: return ("History", "Recently read", ("clock", "No history yet", "Works you read appear here."))
        case .bookmarks: return ("Bookmarks", "Saved works", ("bookmark", "No bookmarks", "Bookmark works to keep them."))
        case .downloads: return ("Downloaded", "Available offline", ("arrow.down.circle", "No downloads", "Download works to read offline."))
        default: return ("Works", "", ("book", "Nothing here", ""))
        }
    }

    private func subtitleForNetworkList(count: Int, loading: Bool) -> String {
        if appState.bridge.networkBlocked { return "Tor required — not connected" }
        if loading && count == 0 { return "Loading…" }
        if let error = appState.searchError, count == 0 { return error }
        return "\(count) works"
    }

    private func networkOverlay(loading: Bool, loadingMessage: String,
                                emptyIcon: String, emptyTitle: String, emptyMessage: String) -> AnyView? {
        guard works.isEmpty else { return nil }
        if appState.bridge.networkBlocked {
            return AnyView(EmptyStateMac(theme: theme, icon: "shield.lefthalf.filled",
                                         title: "Waiting for Tor",
                                         message: "Tor is required in your settings but not connected. Connect from the sidebar's privacy pill."))
        }
        if loading {
            return AnyView(LoadingStateMac(theme: theme, message: loadingMessage,
                                           detail: "Requests are rate-limited to be kind to the archive."))
        }
        if let error = appState.searchError {
            return AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                         title: "Couldn’t reach the archive", message: error))
        }
        return AnyView(EmptyStateMac(theme: theme, icon: emptyIcon, title: emptyTitle, message: emptyMessage))
    }
}
