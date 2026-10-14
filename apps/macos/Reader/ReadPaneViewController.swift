import AppKit
import SwiftUI

/// Right pane shell: 52px toolbar + either the work detail or the in-place
/// reader, with the privacy dot, reading-settings popover, and the floating
/// immersive exit button.
final class ReadPaneViewController: NSViewController {
    let theme: AppTheme
    let appState: AppState
    let model: MacAppModel

    let toolbar: PaneToolbarView
    let container = NSView()
    let privacyDot = NSView()
    let immersiveExit = NSButton()

    var backButton: ToolButton!
    var settingsButton: ToolButton!
    var immersiveButton: ToolButton!
    var bookmarkButton: ToolButton!
    var commentsButton: ToolButton!
    var chaptersButton: ToolButton!
    var chaptersPopover: NSPopover?
    // Detail-mode work actions (the detail view's buttons live in this
    // header toolbar, not in the scroll body).
    var startReadingButton: ToolButton!
    var downloadButton: ToolButton!
    var readingListButton: ToolButton!
    var subscribeButton: ToolButton!
    var kudosButton: ToolButton!
    var workCommentsButton: ToolButton!
    var editBookmarkButton: ToolButton!
    /// The user's manual "finished reading" flag — never inferred.
    var finishedButton: ToolButton!
    /// Both modes: move the selected work into its own window.
    var detachButton: ToolButton!
    var readingListPopover: NSPopover?

    let readerController: ReaderViewController
    /// The Discussion panel beside the reader / work detail.
    let discussion: DiscussionHost
    var resultsController: SearchResultsViewController?
    /// The author profile's Bookmarks pane — bookmark hits (works and
    /// series), not a works list.
    var authorBookmarksController: BookmarkResultsViewController?
    var collectionSplitController: NSSplitViewController?
    var pagerHost: NSHostingView<SearchPagerView>?
    var resultsBackButton: ToolButton!
    var detailHost: NSHostingView<AnyView>?
    var emptyHost: NSHostingView<AnyView>?

    enum Mode: Equatable {
        case empty, searchForm, searchResults, subscriptionWorks(String), authorBookmarks(String),
             authorCollections(String), detail(String), reading(String, Int), inboxThread(UInt64),
             settings, scopeForm, scopeResults, collectionSplit
    }

    var renderedMode: Mode?

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        self.readerController = ReaderViewController(theme: theme, appState: appState, session: model.paneReader)
        self.discussion = DiscussionHost(theme: theme, appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        makeToolbarButtons()

        addChild(readerController)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let discussionView = discussion.view
        let slot = discussion.contentSlot
        discussionView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(discussionView)
        slot.addSubview(container)
        configureDiscussion()

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
            discussionView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            discussionView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            discussionView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            discussionView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.topAnchor.constraint(equalTo: slot.topAnchor),
            container.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
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

        installKeyMonitor()
    }

    /// Creates the toolbar buttons for both modes; called once from loadView.
    private func makeToolbarButtons() {
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
        commentsButton = ToolButton(theme: theme, symbol: "bubble.right", tooltip: "Discussion (⌥⌘C)") { [weak self] in
            self?.discussion.toggleOpen()
        }
        chaptersButton = ToolButton(theme: theme, symbol: "list.bullet", tooltip: "Chapters") { [weak self] in
            self?.toggleChaptersPopover()
        }
        resultsBackButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to results") { [weak self] in
            self?.model.backToResults()
        }
        startReadingButton = ToolButton(theme: theme, symbol: "book", tooltip: "Start reading") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            model.openReader(id, chapter: max(0, (appState.progressMap[id]?.chapter ?? 1) - 1))
        }
        downloadButton = ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Download for offline") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleDownload(id)
        }
        readingListButton = ToolButton(theme: theme, symbol: "books.vertical", tooltip: "Add to reading list") { [weak self] in
            self?.toggleReadingListPopover()
        }
        // The work's own follow bell: Followed / Subscribed menu.
        subscribeButton = ToolButton(theme: theme, symbol: "bell", tooltip: "Follow this work") { [weak self] in
            guard let self, let work = model.selectedWork else { return }
            FollowBellMenu.show(for: FollowModel.Target(kind: .work, id: work.id, name: work.title),
                                follows: model.follows, from: subscribeButton)
        }
        kudosButton = ToolButton(theme: theme, symbol: "heart", tooltip: "Leave kudos on AO3") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.giveKudos(id)
        }
        // Kudos-given disables the button, but the heart's color IS the
        // state display — AppKit's automatic disabled dim would wash the
        // full-red confirmation down to what reads as the faded state.
        (kudosButton.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        workCommentsButton = ToolButton(theme: theme, symbol: "bubble.right", tooltip: "Comments") { [weak self] in
            self?.discussion.toggleOpen()
        }
        editBookmarkButton = ToolButton(theme: theme, symbol: "square.and.pencil",
                                        tooltip: "Edit bookmark — notes, tags, sync to AO3") { [weak self] in
            self?.showBookmarkEditSheet()
        }
        finishedButton = ToolButton(theme: theme, symbol: "checkmark.circle",
                                    tooltip: "Mark as finished reading") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleFinished(id)
        }
        detachButton = ToolButton(theme: theme, symbol: "macwindow",
                                  tooltip: "Open in separate window") { [weak self] in
            self?.detachToWindow()
        }
    }

    private func installKeyMonitor() {
        // App-wide reading keys: ← / → change chapters while reading; Escape
        // backs out of the innermost context (immersive → reader → selection
        // → drill-in). Never fires while typing in an editable text control
        // or while a sheet is up.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = view.window,
                  event.window === window,
                  window.attachedSheet == nil
            else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                return event
            }
            // The discussion panel has its own arrow keys and Escape.
            if discussion.ownsResponder(window.firstResponder) { return event }
            let hasModifiers = !event.modifierFlags.isDisjoint(with: [.command, .option, .control])
            switch event.keyCode {
            case 123 where model.readerOpen && !hasModifiers: // ←
                readerController.goToAdjacentChapter(-1)
                return nil
            case 124 where model.readerOpen && !hasModifiers: // →
                readerController.goToAdjacentChapter(1)
                return nil
            case 53 where !hasModifiers: // Escape
                // Sheets (settings, comments, bookmark edit) and popovers
                // own Escape while they're up.
                if presentedViewControllers?.isEmpty == false { return event }
                if let popover = chaptersPopover, popover.isShown { return event }
                return model.escapeInnermost() ? nil : event
            default:
                return event
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    var keyMonitor: Any?
    var toolbarTop: NSLayoutConstraint!
    var subscriptionCloseBtn: ToolButton?
    var readingListCloseBtn: ToolButton?
    var fandomCloseBtn: ToolButton?
    var fandomSearchBtn: ToolButton?
    var fandomLibraryBackBtn: ToolButton?
    var filterButtons: [String: ToolButton] = [:]
    var filterPopover: NSPopover?

    var authorRefreshBtn: LabelToolButton?
    var subscriptionRefreshBtn: LabelToolButton?
    lazy var sortFilterMenu = SortFilterMenuController(theme: theme, model: model)
    var detailRefreshBtn: ToolButton?
    var inboxThreadRefreshBtn: ToolButton?
    var ao3Btn: LabelToolButton?
    var ao3ButtonURL: URL?

    /// The pane's request-progress banner, hosted as a sibling of
    /// `container` added after it so the content swaps `show(mode:)`
    /// performs inside the container can never cover it.
    let requestProgressOverlay = RequestProgressOverlay()

    /// The split collection view's per-half banners — one overlay instance
    /// per pane, each reading its own tracked operation (the halves fetch
    /// concurrently, so they can't share one). The view refs are captured
    /// when the halves are built; nil until then.
    let splitWorksOverlay = RequestProgressOverlay()
    let splitBookmarksOverlay = RequestProgressOverlay()
    var splitWorksHalf: (root: NSView, table: NSView)?
    var splitBookmarksHalf: (root: NSView, table: NSView)?

    var readerRefreshBtn: ToolButton?
    var detailCloseBtn: ToolButton?
    var inboxThreadCloseBtn: ToolButton?
    var authorProfileBtn: ToolButton?
    var authorSubscribeBtn: ToolButton?

    /// The author the drill-in toolbar buttons act on — set on every render
    /// pass so the cached buttons' closures always target the current author.
    var drillInAuthorUsername: String?

    var searchBackBtn: ToolButton?
    var searchGoBtn: ToolButton?
    var reloadCriteriaBtn: ToolButton?
    var scopeTabs: ScopeTabsView?
    var searchSourceBtn: ToolButton?
    var searchEyeBtn: ToolButton?
    var authorBookmarksMoreBtn: ToolButton?

    // The bookmarks/collections panes are local-first: these buttons are
    // their only network trigger.
    var authorBookmarksRefreshBtn: ToolButton?
    var authorCollectionsRefreshBtn: ToolButton?

    var markAllReadBtn: ToolButton?
    lazy var bulkDownload = BulkDownloadButton(theme: theme, appState: appState)

    /// The works the header toggle acts on — set each render pass so the
    /// cached button's closure always targets the list on screen.
    var markAllReadWorks: [Work] = []
}
