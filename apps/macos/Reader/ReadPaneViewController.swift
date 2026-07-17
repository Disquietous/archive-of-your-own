import AppKit
import SwiftUI

/// Right pane shell: 52px toolbar + either the work detail or the in-place
/// reader, with the privacy dot, reading-settings popover, and the floating
/// immersive exit button.
final class ReadPaneViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let toolbar: PaneToolbarView
    private let container = NSView()
    private let privacyDot = NSView()
    private let immersiveExit = NSButton()

    private var backButton: ToolButton!
    private var settingsButton: ToolButton!
    private var immersiveButton: ToolButton!
    private var bookmarkButton: ToolButton!

    private let readerController: ReaderViewController
    private var resultsController: SearchResultsViewController?
    private var pagerHost: NSHostingView<SearchPagerView>?
    private var resultsBackButton: ToolButton!
    private var detailHost: NSHostingView<AnyView>?
    private var emptyHost: NSHostingView<AnyView>?
    private var settingsPopover: NSPopover?

    private enum Mode: Equatable {
        case empty, searchResults, subscriptionWorks(String), detail(String), reading(String, Int), inboxThread(UInt64)
    }

    private var renderedMode: Mode?

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        self.readerController = ReaderViewController(theme: theme, appState: appState, model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        backButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to details") { [weak self] in
            self?.model.closeReader()
        }
        settingsButton = ToolButton(theme: theme, symbol: "textformat.size", tooltip: "Reading settings") { [weak self] in
            self?.toggleSettingsPopover()
        }
        immersiveButton = ToolButton(theme: theme, symbol: "safari", tooltip: "Immersive reading") { [weak self] in
            self?.model.immersive.toggle()
        }
        bookmarkButton = ToolButton(theme: theme, symbol: "bookmark", tooltip: "Bookmark") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleBookmark(id)
        }
        resultsBackButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to results") { [weak self] in
            self?.model.backToResults()
        }

        addChild(readerController)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(container)

        privacyDot.wantsLayer = true
        privacyDot.layer?.cornerRadius = 4
        privacyDot.toolTip = "Private connection"
        privacyDot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(privacyDot)

        immersiveExit.isBordered = false
        immersiveExit.wantsLayer = true
        immersiveExit.layer?.cornerRadius = 9
        immersiveExit.layer?.borderWidth = 1
        immersiveExit.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Exit immersive")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        immersiveExit.toolTip = "Exit immersive (Esc)"
        immersiveExit.target = self
        immersiveExit.action = #selector(exitImmersive)
        immersiveExit.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(immersiveExit)

        toolbarTop = toolbar.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            toolbarTop,
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            privacyDot.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            privacyDot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            privacyDot.widthAnchor.constraint(equalToConstant: 8),
            privacyDot.heightAnchor.constraint(equalToConstant: 8),
            immersiveExit.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 9),
            immersiveExit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            immersiveExit.widthAnchor.constraint(equalToConstant: 34),
            immersiveExit.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    private var toolbarTop: NSLayoutConstraint!
    private var subscriptionCloseBtn: ToolButton?
    private var authorCloseBtn: ToolButton?
    private var authorRefreshBtn: LabelToolButton?
    private var subscriptionRefreshBtn: LabelToolButton?

    private func subscriptionCloseButton() -> ToolButton {
        let button = subscriptionCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeSubscriptionWorks()
        }
        subscriptionCloseBtn = button
        return button
    }

    private func authorCloseButton() -> ToolButton {
        let button = authorCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeAuthorWorks()
        }
        authorCloseBtn = button
        return button
    }

    /// The drill-in header button: "Refresh Works" idle, "Cancel" while a
    /// crawl runs. render() re-invokes this every pass, so the label always
    /// tracks the current state.
    private func refreshWorksButton(forAuthor: Bool) -> LabelToolButton {
        let button: LabelToolButton
        if forAuthor {
            button = authorRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                model.isLoadingAuthor ? model.cancelAuthorWorksRefresh() : model.refreshAuthorWorks()
            }
            authorRefreshBtn = button
        } else {
            button = subscriptionRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                model.isLoadingSubscriptionWorks ? model.cancelSubscriptionWorksRefresh() : model.refreshSubscriptionWorks()
            }
            subscriptionRefreshBtn = button
        }
        let loading = forAuthor ? model.isLoadingAuthor : model.isLoadingSubscriptionWorks
        button.configure(title: loading ? "Cancel" : "Refresh Works",
                         symbol: loading ? "xmark" : "arrow.clockwise",
                         tooltip: loading
                            ? "Stop fetching — works fetched so far are kept"
                            : "Fetch this author’s complete works list from AO3, page by page")
        return button
    }

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()
        toolbarTop.constant = model.immersive ? 20 : 0
        privacyDot.layer?.backgroundColor = theme.nsSage.cgColor
        immersiveExit.layer?.backgroundColor = theme.nsSurface.cgColor
        immersiveExit.layer?.borderColor = theme.nsLine.cgColor
        immersiveExit.contentTintColor = theme.nsInk2
        immersiveExit.isHidden = !model.immersive

        // Subscriptions drill-in: an author subscription's works, without
        // ever leaving the Subscriptions section.
        if model.section == .subscriptions, let title = model.subscriptionWorksTitle, model.selectedWork == nil {
            let sub = model.isLoadingSubscriptionWorks
                ? (model.subscriptionWorksFetchStatus ?? "Fetching works from AO3…")
                : "\(model.filteredSubscriptionWorks.count) works stored"
            toolbar.configure(title: title, sub: sub)
            toolbar.setLeading([subscriptionCloseButton()])
            toolbar.setTrailing([refreshWorksButton(forAuthor: false)])
            show(mode: .subscriptionWorks(title))
            return
        }

        // Authors drill-in: an author's works shown in the reading pane.
        if model.section == .authors, let author = model.authorUsername, model.selectedWork == nil {
            let sub = model.isLoadingAuthor
                ? (model.authorFetchStatus ?? "Fetching works from AO3…")
                : "\(model.authorWorksList.count) works stored"
            toolbar.configure(title: author, sub: sub)
            toolbar.setLeading([authorCloseButton()])
            toolbar.setTrailing([refreshWorksButton(forAuthor: true)])
            show(mode: .subscriptionWorks(author))
            return
        }

        // Search section with no selection: the pane shows paged results.
        if model.section == .search, model.selectedWork == nil {
            let search = model.search
            toolbar.configure(title: model.searchDisplayTitle ?? "Results",
                              sub: search.hasSearched ? "Page \(search.currentPage)" : nil)
            toolbar.setLeading([])
            if pagerHost == nil {
                pagerHost = NSHostingView(rootView: SearchPagerView(theme: theme, appState: appState, model: model))
            }
            toolbar.setTrailing(search.hasSearched ? [pagerHost!] : [])
            show(mode: .searchResults)
            return
        }

        if model.section == .inbox, let item = appState.selectedInboxItem {
            toolbar.configure(title: item.workReference, sub: "Comment by \(item.author)")
            toolbar.setLeading([])
            toolbar.setTrailing([])
            let mode = Mode.inboxThread(item.commentId)
            show(mode: mode)
            if case .inboxThread = renderedMode, let host = detailHost {
                host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
            }
            return
        }

        guard let work = model.selectedWork else {
            toolbar.configure(title: "", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .empty)
            return
        }

        let reading = model.readerOpen
        let cameFromResults = model.section == .search
            || (model.section == .subscriptions && model.subscriptionWorksTitle != nil)
            || (model.section == .authors && model.authorUsername != nil)
        toolbar.configure(title: reading ? work.title : "Details", sub: nil)
        toolbar.setLeading(reading ? [backButton] : (cameFromResults ? [resultsBackButton] : []))
        immersiveButton.isOn = model.immersive
        let bookmarked = appState.bookmarkedWorkIDs.contains(work.id)
        bookmarkButton.setSymbol(bookmarked ? "bookmark.fill" : "bookmark")
        bookmarkButton.tintOverride = bookmarked ? theme.nsAccent : nil
        toolbar.setTrailing(reading ? [settingsButton, immersiveButton, bookmarkButton]
                                    : [settingsButton, bookmarkButton])

        show(mode: reading ? .reading(work.id, model.readerChapter) : .detail(work.id))

        // Detail is SwiftUI and re-renders itself; only rebuild on identity change.
        if case .detail = renderedMode, let host = detailHost {
            host.rootView = AnyView(DetailView(theme: theme, appState: appState, model: model, work: work))
        }
    }

    private func show(mode: Mode) {
        guard mode != renderedMode else { return }

        switch mode {
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

        case .inboxThread:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
            detailHost = host
            pin(host)
        }
        renderedMode = mode
    }

    private func pin(_ subview: NSView) {
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

    // MARK: - Actions

    private func toggleSettingsPopover() {
        if let popover = settingsPopover, popover.isShown {
            popover.close()
            settingsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ReadingSettingsView(theme: theme))
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    @objc private func exitImmersive() {
        model.immersive = false
    }
}

