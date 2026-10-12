import AppKit
import SwiftUI

extension ReadPaneViewController {
    // MARK: - Pane modes

    func show(mode: Mode) {
        guard mode != renderedMode else { return }

        // The split collection view only appears in its own mode; every
        // other mode clears it here rather than case by case.
        if mode != .collectionSplit {
            collectionSplitController?.view.removeFromSuperview()
        }
        if case .authorBookmarks = mode {} else {
            authorBookmarksController?.view.removeFromSuperview()
        }

        if !showControllerMode(mode) {
            showHostedMode(mode)
        }
        renderedMode = mode
    }

    /// `show(mode:)` for the modes backed by an AppKit controller, the
    /// empty state, or the reader. Returns false for the SwiftUI-hosted
    /// modes, which `showHostedMode(_:)` handles.
    private func showControllerMode(_ mode: Mode) -> Bool {
        switch mode {
        case .authorBookmarks:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            if authorBookmarksController == nil {
                let controller = BookmarkResultsViewController(
                    theme: theme, appState: appState, model: model, source: .authorBookmarks)
                addChild(controller)
                authorBookmarksController = controller
            }
            pin(authorBookmarksController!.view)

        case .collectionSplit:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            pin(collectionSplit().view)

        case .searchResults, .subscriptionWorks:
            readerController.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            if resultsController == nil {
                let controller = SearchResultsViewController(theme: theme, appState: appState, model: model)
                addChild(controller)
                resultsController = controller
            }
            pin(resultsController!.view)

        case .empty:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            if emptyHost == nil {
                let host = NSHostingView(rootView: AnyView(
                    EmptyStateMac(theme: theme, icon: "book",
                                  title: "Select a work to begin",
                                  message: "Choose something from the list, or browse the archive. Everything you read stays private.")))
                emptyHost = host
            }
            pin(emptyHost!)

        case .detail(let workID):
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            if let work = appState.work(byID: workID) {
                let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
                host.rootView = AnyView(DetailView(theme: theme, appState: appState, model: model, work: work))
                detailHost = host
                pin(host)
            }

        case .reading(let workID, let chapter):
            detailHost?.removeFromSuperview()
            detailHost = nil
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            if let work = appState.work(byID: workID) {
                pin(readerController.view)
                readerController.show(work: work, chapterIndex: chapter)
            }

        default:
            return false
        }
        return true
    }

    /// `show(mode:)` for the modes that host a SwiftUI view in `detailHost`.
    private func showHostedMode(_ mode: Mode) {
        switch mode {
        case .searchForm:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(SearchFormView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .settings:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(SettingsRootView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .scopeForm:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(ScopeSearchFormView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .scopeResults:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(ScopeResultsView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .authorCollections:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(AuthorCollectionsView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .inboxThread:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
            detailHost = host
            pin(host)

        default:
            break
        }
    }

    /// The split collection view: works half (back arrow + its own pager)
    /// and bookmarked-items half (its own pager), independently paged,
    /// divided by a draggable thin divider.
    func collectionSplit() -> NSSplitViewController {
        if let collectionSplitController { return collectionSplitController }
        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin
        let worksItem = NSSplitViewItem(viewController: splitHalf(isWorks: true))
        worksItem.minimumThickness = 320
        split.addSplitViewItem(worksItem)
        let bookmarksItem = NSSplitViewItem(viewController: splitHalf(isWorks: false))
        bookmarksItem.minimumThickness = 320
        split.addSplitViewItem(bookmarksItem)
        addChild(split)
        collectionSplitController = split
        return split
    }

    /// One half of the split: a compact header bar over a works table.
    func splitHalf(isWorks: Bool) -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        root.wantsLayer = true
        controller.view = root

        let header = NSHostingView(rootView: CollectionSplitPaneHeader(
            theme: theme, appState: appState, model: model, isWorks: isWorks))
        header.translatesAutoresizingMaskIntoConstraints = false
        let results = SearchResultsViewController(
            theme: theme, appState: appState, model: model,
            fixedContext: isWorks ? .search : .collectionBookmarks)
        controller.addChild(results)
        let table = results.view
        table.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(table)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // Record the half's views so the render pass can float its
        // request-progress banner over the table (below the header).
        if isWorks {
            splitWorksHalf = (root: root, table: table)
        } else {
            splitBookmarksHalf = (root: root, table: table)
        }
        return controller
    }

    func pin(_ subview: NSView) {
        guard subview.superview != container else { return }
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Symbols, tints, and enabled states for the detail-mode work action
    /// buttons — re-run on every render, like the bookmark button.
    func refreshDetailActionButtons(for work: Work, bookmarked: Bool) {
        let started = model.appState.progress(for: work) > 0
        let currentChapter = appState.progressMap[work.id]?.chapter ?? 1
        startReadingButton.isOn = true
        startReadingButton.toolTip = started
            ? "Continue reading · Chapter \(currentChapter)" : "Start reading"

        let downloaded = appState.downloadedWorkIDs.contains(work.id)
        downloadButton.setSymbol(appState.isDownloading(work.id) ? "arrow.down.circle.dotted"
                                 : downloaded ? "checkmark.circle" : "arrow.down.circle")
        downloadButton.tintOverride = downloaded ? theme.nsSage : nil
        downloadButton.toolTip = downloaded ? "Downloaded" : "Download for offline"

        let workId = UInt64(work.id)
        let inList = workId.map { !appState.readingListIDs(forWork: $0).isEmpty } ?? false
        readingListButton.setSymbol(inList ? "books.vertical.fill" : "books.vertical")
        readingListButton.tintOverride = inList ? theme.nsAccent : nil
        readingListButton.isEnabled = workId != nil

        let workTarget = FollowModel.Target(kind: .work, id: work.id, name: work.title)
        let workShaded = model.follows.isShaded(workTarget)
        subscribeButton.setSymbol(workShaded ? "bell.fill" : "bell")
        subscribeButton.tintOverride = workShaded ? theme.nsAccent : nil
        subscribeButton.isEnabled = UInt64(work.id) != nil && !model.follows.isBusy(workTarget)
        subscribeButton.toolTip = "Followed / Subscribed — choose how to track this work"

        // Heart states: empty = no kudos (or the POST failed), faded red =
        // request in flight, full red = AO3 confirmed.
        let hasKudos = appState.kudosGivenWorkIDs.contains(work.id)
        let kudosPending = appState.kudosPendingWorkIDs.contains(work.id)
        let kudosRed = NSColor(Color(hex: "CE514D"))
        kudosButton.setSymbol(hasKudos || kudosPending ? "heart.fill" : "heart")
        kudosButton.tintOverride = hasKudos ? kudosRed
            : kudosPending ? kudosRed.withAlphaComponent(0.45) : nil
        kudosButton.isEnabled = !hasKudos && !kudosPending
        kudosButton.toolTip = hasKudos ? "Kudos left — kudos are permanent on AO3"
            : kudosPending ? "Leaving kudos…" : "Leave kudos on AO3"

        workCommentsButton.toolTip = work.comments > 0
            ? "Comments · \(Fmt.k(work.comments))" : "Comments"

        let finished = appState.finishedWorkIDs.contains(work.id)
        finishedButton.setSymbol(finished ? "checkmark.circle.fill" : "checkmark.circle")
        finishedButton.tintOverride = finished ? theme.nsSage : nil
        finishedButton.toolTip = finished ? "Finished reading — click to unmark" : "Mark as finished reading"
    }
}
