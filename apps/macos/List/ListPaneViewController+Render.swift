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
        case .browse:
            works = model.works(for: .browse)
            toolbar.configure(title: "Browse", sub: subtitleForNetworkList(count: works.count, loading: appState.isBrowsing))
            toolbar.setLeading([])
            toolbar.setTrailing([browseRefreshButton(), sortFilterMenu.makeButton(for: .browse),
                                 worksFilterButton(for: .browse), eyeToggleButton()])
            showWorksContent(section: section, header: nil,
                             overlay: networkOverlay(loading: appState.isBrowsing,
                                                     loadingMessage: "Fetching latest works…",
                                                     emptyIcon: "safari", emptyTitle: "Nothing here yet",
                                                     emptyMessage: "Connect and refresh to browse the newest works on the archive."))

        case .search:
            toolbar.configure(title: "Search", sub: model.search.formFields.isEmpty ? "Criteria" : "AO3 criteria")
            toolbar.setLeading([])
            toolbar.setTrailing([searchGoButton(), saveSearchButton(), reloadFieldsButton(), eyeToggleButton()])
            showVariant(SearchFormView(theme: theme, appState: appState, model: model), section: section)

        case .authorWorks:
            break

        case .settings:
            // The list pane is collapsed for Settings — the reading pane
            // hosts the whole thing. Nothing to render here.
            break

        case .reading, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = sectionMeta(for: section)
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)")
            toolbar.setLeading([])
            var trailing: [NSView] = [sortFilterMenu.makeButton(for: section), worksFilterButton(for: section)]
            if section == .reading && !works.isEmpty {
                trailing.insert(removeAllReadingButton(), at: 0)
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
                buttons.append(ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check for updates") { [weak self] in
                    guard let self else { return }
                    Task {
                        self.appState.bridge.resetSubscriptionCheck()
                        await self.appState.checkSubscriptions(force: true)
                    }
                })
                buttons.append(sortFilterMenu.makeButton(for: .whatsNew))
                buttons.append(worksFilterButton(for: .whatsNew))
                toolbar.setLeading([])
                toolbar.setTrailing(buttons)
                let overlay: AnyView?
                if !appState.isCheckingSubscriptions && works.isEmpty {
                    let checkStatus = appState.subscriptionCheckTask.statusMessage
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
                displayedSubscriptions = model.filteredSubscriptions
                displayedLastChecked = appState.subscriptionLastChecked
                works = []
                let subtitle: String
                if appState.isLoadingSubscriptions {
                    subtitle = "Loading from AO3…"
                } else if let err = appState.subscriptionError, !err.isEmpty {
                    subtitle = "Error — \(err)"
                } else {
                    subtitle = "\(displayedSubscriptions.count) subscriptions"
                }
                toolbar.configure(title: "Following", sub: subtitle)
                let followingFilter = filterButton(key: "following", active: !model.subscriptionListFilter.isEmpty) { [theme, model] in
                    AnyView(SingleFieldFilterView(theme: theme, model: model,
                                                  title: "Filter Following",
                                                  placeholder: "Name",
                                                  text: Binding(get: { model.subscriptionListFilter },
                                                                set: { model.subscriptionListFilter = $0 })))
                }
                toolbar.setLeading([])
                toolbar.setTrailing([followingFilter, ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Refresh list from AO3") { [weak self] in
                    guard let self else { return }
                    guard appState.ao3Username != nil else {
                        appState.subscriptionError = "Sign in to AO3 in Settings first"
                        return
                    }
                    guard !appState.isLoadingSubscriptions else { return }
                    appState.subscriptionError = nil
                    Task { await self.appState.loadSubscriptions(force: true) }
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
            let inboxFilter = filterButton(key: "inbox", active: !model.inboxFilterAuthor.isEmpty
                                               || !model.inboxFilterWork.isEmpty
                                               || !model.inboxFilterText.isEmpty) { [theme, model] in
                AnyView(InboxFilterView(theme: theme, model: model))
            }
            toolbar.setTrailing([inboxFilter] + inboxToolbarButtons())
            showVariant(InboxView(theme: theme, appState: appState, model: model), section: section)

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(model.followedFandoms.count) followed")
            toolbar.setLeading([])
            toolbar.setTrailing([filterButton(key: "fandoms", active: !model.fandomsListFilter.isEmpty) { [theme, model] in
                AnyView(SingleFieldFilterView(theme: theme, model: model,
                                              title: "Filter Fandoms",
                                              placeholder: "Fandom name",
                                              text: Binding(get: { model.fandomsListFilter },
                                                            set: { model.fandomsListFilter = $0 })))
            }])
            showVariant(FollowedFandomsView(theme: theme, model: model), section: section)

        case .collections:
            let sub: String
            if model.isLoadingCollections && model.collections.isEmpty {
                sub = "Loading…"
            } else {
                let count = model.filteredCollections.count
                sub = count == 1 ? "1 collection" : "\(count) collections"
            }
            toolbar.configure(title: "Collections", sub: sub)
            toolbar.setLeading([])
            toolbar.setTrailing([filterButton(key: "collections", active: !model.collectionsListFilter.isEmpty) { [theme, model] in
                AnyView(SingleFieldFilterView(theme: theme, model: model,
                                              title: "Filter Collections",
                                              placeholder: "Collection name",
                                              text: Binding(get: { model.collectionsListFilter },
                                                            set: { model.collectionsListFilter = $0 })))
            }])
            showVariant(CollectionsListView(theme: theme, model: model), section: section)

        case .authors:
            let count = model.followedAuthorNames.count + model.followedAuthors.count
            toolbar.configure(title: "Authors", sub: "\(count) followed")
            toolbar.setLeading([])
            let followButton = ToolButton(theme: theme, symbol: "plus", tooltip: "Follow an author") { [model] in
                model.showFollowAuthorField.toggle()
            }
            followButton.isOn = model.showFollowAuthorField
            let sourceFiltered = !(model.authorsIncludeFollowed && model.authorsIncludeSubscribed)
            toolbar.setTrailing([followButton,
                                 filterButton(key: "authors", active: sourceFiltered) { [theme, model] in
                AnyView(AuthorsSourceFilterView(theme: theme, model: model))
            }])
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
            if appState.subscriptionCheckTask.isReconnecting,
               let msg = appState.subscriptionCheckTask.statusMessage {
                message = msg
                active = true
            } else if appState.isCheckingSubscriptions {
                let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
                message = "Checking \(done) of \(appState.subscriptionCheckTotal)"
                active = true
            } else if let msg = appState.subscriptionCheckTask.statusMessage, !msg.isEmpty {
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
        case .browse:
            if appState.isBrowsing {
                message = "Fetching latest works…"
                active = true
            }
        default:
            break
        }

        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = theme.nsInk3
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
