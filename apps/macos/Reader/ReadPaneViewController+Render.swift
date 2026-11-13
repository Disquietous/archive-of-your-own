import AppKit
import SwiftUI

extension ReadPaneViewController {
    // MARK: - Render

    func render() {
        // Track the app text-size setting so toolbar fonts refresh with it.
        _ = theme.uiFontScale
        // Request-progress banner: hidden unless a branch below hands it a
        // tracked operation id (work-detail refresh, the works crawls, and
        // the reader's chapter fetch). The defer runs on every early
        // return, so no branch has to remember to hide it.
        var requestOverlayOpID: UInt64?
        defer { requestProgressOverlay.update(opID: requestOverlayOpID, over: container, in: view,
                                              theme: theme, appState: appState) }
        // The split collection view's halves each carry their own banner,
        // set only by the split branch — same defer discipline.
        var splitWorksOpID: UInt64?
        var splitBookmarksOpID: UInt64?
        defer {
            if let half = splitWorksHalf {
                splitWorksOverlay.update(opID: splitWorksOpID, over: half.table, in: half.root,
                                         theme: theme, appState: appState)
            }
            if let half = splitBookmarksHalf {
                splitBookmarksOverlay.update(opID: splitBookmarksOpID, over: half.table, in: half.root,
                                             theme: theme, appState: appState)
            }
        }
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()
        toolbarTop.constant = model.immersive ? 20 : 0
        privacyDot.layer?.backgroundColor = theme.nsSage.cgColor
        immersiveExit.layer?.backgroundColor = theme.nsSurface.cgColor
        immersiveExit.layer?.borderColor = theme.nsLine.cgColor
        immersiveExit.contentTintColor = theme.nsInk2
        immersiveExit.isHidden = !model.immersive

        // Only the work-detail branch places an after-title view; clearing
        // here keeps the list branches from inheriting the detail pane's
        // Start Reading button.
        toolbar.setAfterTitle([])

        // Subscriptions drill-in: an author subscription's works, without
        // ever leaving the Subscriptions section.
        if renderSubscriptionWorks(requestOverlayOpID: &requestOverlayOpID) { return }

        // Authors drill-in: one of the author's lists (works, bookmarks,
        // or collections) in this pane — their profile sits in the list
        // pane, and its buttons pick which list shows here.
        if renderAuthorPane(requestOverlayOpID: &requestOverlayOpID) { return }

        // Fandoms drill-in, without leaving the Fandoms section. Local-first:
        // the library's works for the fandom, with an explicit Search AO3
        // action that swaps the pane to the archive's paged tag results.
        if renderFandomWorks() { return }

        // Reading Lists drill-in: the selected list's works, mirroring the
        // Subscriptions → works flow.
        if renderReadingList() { return }

        // Settings spans this pane full-width (the list pane is collapsed),
        // hosting the same SwiftUI panes the standalone window used to.
        if model.section == .settings {
            toolbar.configure(title: "Settings", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .settings)
            return
        }

        // Search section with no selection: the list pane is collapsed, so
        // this pane holds the whole flow — scope tabs in place of the title,
        // the scope's form, flipping to results once a query runs (back
        // button returns). Works/Bookmarks results use the works table;
        // Tags/Users/Collections render their own hit lists.
        if renderSearch(requestOverlayOpID: &requestOverlayOpID, splitWorksOpID: &splitWorksOpID,
                        splitBookmarksOpID: &splitBookmarksOpID) { return }

        if renderInboxThread() { return }

        renderWork(requestOverlayOpID: &requestOverlayOpID)
    }

    private func renderSubscriptionWorks(requestOverlayOpID: inout UInt64?) -> Bool {
        guard model.section == .subscriptions, let title = model.subscriptionWorks.title,
              model.selectedWork == nil else { return false }
        let isAuthor = model.subscriptionWorks.subType == "author"
        let author = model.subscriptionWorks.subId ?? title
        let sub = model.subscriptionWorks.isLoading
            ? (model.subscriptionWorks.fetchStatus ?? "Fetching works from AO3…")
            : storedWorksSubtitle(count: model.filteredSubscriptionWorks.count,
                                  crawledAt: model.subscriptionWorks.crawledAt)
        toolbar.configure(title: title, sub: sub)
        requestOverlayOpID = model.subscriptionWorks.refreshOp.opID
        toolbar.setLeading([subscriptionCloseButton()])
        var trailing: [NSView] = [sortFilterMenu.makeButton(for: .subscriptions),
                                  worksFilterButton(for: .subscriptions),
                                  refreshWorksButton(forAuthor: false)]
        if isAuthor {
            trailing = authorHeaderButtons(username: author)
                + [markAllReadButton(works: model.filteredSubscriptionWorks)] + trailing
        }
        toolbar.setTrailing(trailing)
        show(mode: .subscriptionWorks(title))
        return true
    }

    private func renderAuthorPane(requestOverlayOpID: inout UInt64?) -> Bool {
        guard model.section == .authors, let userID = model.author.userID,
              model.selectedWork == nil else { return false }
        let author = model.author.username ?? ""
        switch model.author.pane {
        case .works:
            let canCrawl = appState.userCapabilities(userID)?.authorListings ?? true
            let sub = model.author.isLoadingWorks
                ? (model.author.worksFetchStatus ?? "Fetching works from \(appState.userSourceName(userID))…")
                : canCrawl
                    ? storedWorksSubtitle(count: model.filteredAuthorWorks.count,
                                          crawledAt: model.author.worksCrawledAt)
                    : "\(model.filteredAuthorWorks.count) works in your library"
            toolbar.configure(title: "Works", sub: sub)
            requestOverlayOpID = model.author.worksRefreshOp.opID
            toolbar.setLeading([])
            var trailing: [NSView] = [markAllReadButton(works: model.filteredAuthorWorks),
                                      sortFilterMenu.makeButton(for: .authors),
                                      worksFilterButton(for: .authors)]
            if canCrawl { trailing.append(refreshWorksButton(forAuthor: true)) }
            toolbar.setTrailing(trailing)
            show(mode: .subscriptionWorks(author))
        case .bookmarks:
            let count = model.author.bookmarks.count
            let sub = model.author.isLoadingBookmarks
                ? (count == 0 ? "Fetching bookmarks from AO3…"
                              : "Fetching bookmarks from AO3… \(count) so far")
                : count == 1 ? "1 bookmark" : "\(count) bookmarks"
            // The signed-in account's own list is its AO3 Bookmarks
            // screen (edit / delete from each row's menu).
            toolbar.configure(title: model.author.isOwnAccount ? "My AO3 Bookmarks" : "Bookmarks", sub: sub)
            requestOverlayOpID = model.author.bookmarksRefreshOp.opID
            toolbar.setLeading([])
            var trailing: [NSView] = []
            if model.author.bookmarksHasNext {
                trailing.append(authorBookmarksMoreButton())
            }
            trailing.append(authorBookmarksRefreshButton())
            toolbar.setTrailing(trailing)
            show(mode: .authorBookmarks(author))
        case .collections:
            let count = model.author.collections.count
            let sub = model.author.isLoadingCollections
                ? "Fetching collections from AO3…"
                : count == 1 ? "1 collection" : "\(count) collections"
            toolbar.configure(title: "Collections", sub: sub)
            toolbar.setLeading([])
            toolbar.setTrailing([authorCollectionsRefreshButton()])
            show(mode: .authorCollections(author))
        }
        return true
    }

    private func renderFandomWorks() -> Bool {
        guard model.section == .fandoms, let tag = model.fandomWorksTag,
              model.selectedWork == nil else { return false }
        // Tag pages belong to the source with tag listings; its adapter
        // builds the URL (Area 10.2), the UI never does.
        let tagSource = appState.bridge.listSources().first { $0.tagListings }
        let tagControls = tagSource.flatMap { appState.bridge.tagControls(source: $0.id, tag: tag) }
        let tagSite = siteButton(url: tagControls?.siteUrl.flatMap { URL(string: $0) },
                                 caption: tagControls?.vocabulary.siteShort ?? "Site",
                                 tooltip: "Open this tag's works on \(tagSource?.name ?? "the site") in your browser")
        let tagAO3: [NSView] = tagControls?.siteUrl == nil ? [] : [tagSite]
        if model.fandomSearchActive {
            let search = model.search
            toolbar.configure(title: tag, sub: search.resultsSubtitle)
            toolbar.setLeading([fandomLibraryBackButton()])
            toolbar.setTrailing(tagAO3 + (search.hasSearched
                ? [makePagerHost(), worksFilterButton(for: .search)] : []))
        } else {
            let count = model.fandomLibraryWorks.count
            toolbar.configure(title: tag,
                              sub: count == 1 ? "1 work in library" : "\(count) works in library")
            toolbar.setLeading([fandomCloseButton()])
            toolbar.setTrailing(tagAO3 + [fandomSearchButton(), worksFilterButton(for: .fandoms)])
        }
        show(mode: .searchResults)
        return true
    }

    private func renderReadingList() -> Bool {
        guard model.section == .readingLists, let listID = model.selectedReadingListID,
              model.selectedWork == nil else { return false }
        let name = appState.readingLists.first { $0.id == listID }?.name ?? "Reading List"
        let summary = appState.readingListSummary(listID)
        let sub = summary.totalCount == 0
            ? "Reading list"
            : "\(Fmt.k(summary.totalWords)) words · \(summary.readCount) of \(summary.totalCount) read"
        toolbar.configure(title: name, sub: sub + bulkDownload.statusSuffix)
        toolbar.setLeading([readingListCloseButton()])
        let listWorkIDs = appState.worksInReadingList(listID).map(\.id)
        toolbar.setTrailing([bulkDownload.update(ids: listWorkIDs),
                             sortFilterMenu.makeButton(for: .readingLists),
                             worksFilterButton(for: .readingLists)])
        show(mode: .searchResults)
        return true
    }

    private func renderSearch(requestOverlayOpID: inout UInt64?, splitWorksOpID: inout UInt64?,
                              splitBookmarksOpID: inout UInt64?) -> Bool {
        guard model.section == .search, model.selectedWork == nil else { return false }
        let search = model.search
        if search.showingResults, let collectionName = search.splitCollectionName {
            // Split collection view: the pane toolbar names the
            // collection; the back arrow and both pagers live in the
            // halves' own header bars.
            toolbar.configure(title: search.splitCollectionTitle ?? "Collection",
                              sub: splitCollectionSubtitle(search))
            // Each half's fetch runs tracked under its own operation;
            // each half's banner follows its own opID.
            splitWorksOpID = search.searchFetchOp.opID
            splitBookmarksOpID = search.bookmarksFetchOp.opID
            toolbar.setLeading([])
            let tabCaps = appState.bridge.sourceCapabilities(search.sourceTab)
            toolbar.setTrailing([siteButton(url: search.splitCollectionURL,
                                            caption: tabCaps?.vocabulary.siteShort ?? "Site",
                                            tooltip: "Open this collection on \(tabCaps?.name ?? "the site") in your browser"),
                                 searchSourceButton()])
            show(mode: .collectionSplit)
            return true
        }
        if search.showingResults {
            let worksStyle = search.scope == .works
            // AO3-side Works/Bookmarks/Collections queries run tracked —
            // the banner shows while their fetch is in flight.
            requestOverlayOpID = search.searchFetchOp.opID
            toolbar.configure(title: "", sub: scopeResultsSubtitle(search))
            let back = searchFormBackButton()
            // The same arrow pops one level: to the collections hit
            // list behind a drill-in, to the screen that triggered the
            // search when it came from outside the Search section, to
            // the form otherwise.
            back.toolTip = search.canReturnToCollectionHits
                ? "Back to collections results"
                : model.searchReturnSection != nil ? "Back"
                : "Back to search criteria"
            toolbar.setLeading([back])
            if worksStyle {
                var trailing: [NSView] = search.hasSearched
                    ? [makePagerHost(), worksFilterButton(for: .search)] : []
                // Server-side sort — AO3 form queries carry the scraped
                // sort params; source queries carry the adapter's sort.
                if search.hasSearched, case .form = search.activeQuery,
                   searchSortField() != nil {
                    trailing.insert(searchSortButton(), at: 0)
                } else if search.hasSearched, case .source = search.activeQuery,
                          sourceSortSpec() != nil {
                    trailing.insert(searchSortButton(), at: 0)
                }
                if search.usesArchiveForm { trailing.append(searchSourceButton()) }
                toolbar.setTrailing(trailing)
                show(mode: .searchResults)
            } else {
                // AO3 collections and bookmark results are paged like
                // works results.
                var trailing: [NSView] = []
                switch search.activeQuery {
                case .collectionsIndex, .bookmarkSearch:
                    trailing.append(makePagerHost())
                default:
                    break
                }
                if search.scope == .bookmarks, search.hasSearched {
                    trailing.append(bookmarksFilterButton())
                }
                trailing.append(searchSourceButton())
                toolbar.setTrailing(trailing)
                show(mode: .scopeResults)
            }
        } else {
            // The source tabs (AO3, ScribbleHub, …) live where the title
            // would be, with AO3's scope tabs beside them while its forms
            // show; results keep a plain header.
            let sources = sourceTabsView()
            sources.configure(selected: search.sourceTab)
            toolbar.configure(title: "", sub: nil)
            toolbar.setLeading([])
            if !search.usesArchiveForm {
                toolbar.setAfterTitle(sources.segmentCount > 1 ? [sources] : [])
                toolbar.setTrailing([searchGoButton(), searchEyeButton()])
                show(mode: .sourceForm(search.sourceTab))
            } else {
                let tabs = scopeTabsView()
                tabs.configure(selected: search.scope)
                toolbar.setAfterTitle(sources.segmentCount > 1 ? [sources, tabs] : [tabs])
                if search.scope == .works {
                    toolbar.setTrailing([searchGoButton(), reloadCriteriaButton(),
                                         searchEyeButton(), searchSourceButton()])
                    show(mode: .searchForm)
                } else {
                    toolbar.setTrailing([searchGoButton(), searchSourceButton()])
                    show(mode: .scopeForm)
                }
            }
        }
        return true
    }

    private func renderInboxThread() -> Bool {
        guard model.section == .inbox, let item = appState.selectedInboxItem else { return false }
        toolbar.configure(title: item.workReference, sub: "Comment by \(item.author)")
        toolbar.setLeading([inboxThreadCloseButton()])
        toolbar.setTrailing([inboxThreadRefreshButton()])
        let mode = Mode.inboxThread(item.commentId)
        show(mode: mode)
        if case .inboxThread = renderedMode, let host = detailHost {
            host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
        }
        return true
    }

    private func renderWork(requestOverlayOpID: inout UInt64?) {
        guard let work = model.selectedWork else {
            toolbar.configure(title: "", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .empty)
            return
        }

        let reading = model.readerOpen
        let cameFromResults = model.section == .search
            || (model.section == .subscriptions && model.subscriptionWorks.title != nil)
            || (model.section == .authors && model.author.userID != nil)
            || (model.section == .fandoms && model.fandomWorksTag != nil)
        // Which controls this row offers — shapes, gates and words from
        // its source (design/source-controls-plan.md).
        let controls = appState.workControls(work.id)
        let siteName = appState.bridge.sourceCapabilities(work.source)?.name ?? "the site"
        toolbar.configure(title: reading ? work.title : "Details",
                          sub: !reading && appState.isRefreshingWork ? "Refreshing from \(siteName)…" : nil)
        // Kudos posts from either mode's toolbar, so its op shows in both.
        requestOverlayOpID = appState.kudosOp.opID
            ?? (reading ? model.paneReader.chapterFetchOp.opID : appState.workRefreshOp.opID)
        toolbar.setLeading(reading ? [backButton]
                           : cameFromResults ? [resultsBackButton] : [detailCloseButton()])
        immersiveButton.isOn = model.immersive
        let bookmarked = appState.bookmarkedWorkIDs.contains(work.id)
        bookmarkButton.setSymbol(bookmarked ? "bookmark.fill" : "bookmark")
        bookmarkButton.tintOverride = bookmarked ? theme.nsAccent : nil
        let refreshLabel = controls?.vocabulary.refresh ?? "Refresh"
        let hasDiscussion = controls.map { $0.discussion != .none } ?? true
        let remoteBookmark = controls?.remoteBookmark ?? .enabled
        if reading {
            // Chapter comments ride the discussion panel only where the
            // source has them (or a threaded work discussion to show).
            let showComments = hasDiscussion && (controls?.chapterComments ?? true || controls?.discussion == .threaded)
            var trailing: [NSView] = [detachButton, settingsButton, immersiveButton, chaptersButton,
                                      readerRefreshButton(label: refreshLabel)]
            if showComments { trailing.append(commentsButton) }
            // The app bookmark: any source.
            trailing.append(bookmarkButton)
            toolbar.setTrailing(trailing)
        } else {
            refreshDetailActionButtons(for: work, bookmarked: bookmarked, controls: controls)
            toolbar.setAfterTitle([startReadingButton])
            var trailing: [NSView] = []
            if let site = controls?.siteUrl, let url = URL(string: site) {
                trailing.append(siteButton(url: url, caption: controls?.vocabulary.siteShort ?? "Site",
                                           tooltip: controls?.vocabulary.openOnSite ?? "Open on site"))
            }
            trailing += [detachButton, settingsButton, detailRefreshButton(label: refreshLabel),
                         downloadButton, readingListButton]
            if controls?.subscribe != .hidden { trailing.append(subscribeButton) }
            switch controls?.reaction ?? .kudos(given: false, gate: .enabled) {
            case .kudos: trailing.append(kudosButton)
            case .starRating: trailing.append(ratingControl)
            case .none: break
            }
            if hasDiscussion { trailing.append(workCommentsButton) }
            trailing.append(finishedButton)
            // The source's own bookmark record, where it keeps them;
            // the app bookmark for every source.
            if remoteBookmark != .hidden { trailing.append(editBookmarkButton) }
            trailing.append(bookmarkButton)
            toolbar.setTrailing(trailing)
        }

        show(mode: reading ? .reading(work.id, model.readerChapter) : .detail(work.id))

        // Detail is SwiftUI and re-renders itself; only rebuild on identity change.
        if case .detail = renderedMode, let host = detailHost {
            host.rootView = AnyView(DetailView(theme: theme, appState: appState, model: model, work: work))
        }
    }
}
