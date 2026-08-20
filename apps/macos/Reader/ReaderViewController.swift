import AppKit

/// Diagnostic trail readable outside Xcode. Mirrors the [ReaderPos] NSLogs.
func aoyoPosLog(_ message: String) {
    NSLog("[ReaderPos] %@", message)
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8),
       let handle = FileHandle(forWritingAtPath: "/tmp/aoyo-readerpos.log") {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? (line as NSString).write(toFile: "/tmp/aoyo-readerpos.log",
                                      atomically: false, encoding: String.Encoding.utf8.rawValue)
    }
}
import SwiftUI

/// In-place reading view: a TextKit 2 text view in a centered column at the
/// user's measure width. Chapters come from the local cache when available
/// and are fetched over Tor otherwise, mirroring the iOS reader.
final class ReaderViewController: NSViewController {
    let theme: AppTheme
    let appState: AppState
    let model: MacAppModel

    let scrollView = NSScrollView()
    private let column = NSStackView()
    let metaLabel = NSTextField(labelWithString: "")
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let titleRule = NSView()
    private let bodyContainer = NSView()
    let textView: SelfSizingTextView
    let dropCapLabel = NSTextField(labelWithString: "")
    let endRule = NSView()
    let ornamentLabel = NSTextField(labelWithString: "· · ·")
    let nextChapterButton = NSButton(title: "Next chapter", target: nil, action: nil)
    let endNoteBig = NSTextField(labelWithString: "")
    let endNoteSub = NSTextField(labelWithString: "")
    let nextWorkButton = NSButton(title: "Next work in series", target: nil, action: nil)
    let footer: ReadFooterView
    var overlayHost: NSHostingView<AnyView>?

    var columnCap: NSLayoutConstraint!
    private var columnFill: NSLayoutConstraint!
    var work: Work?
    var chapters: [UChapter]?
    var chapterIndex = 0
    var chapterPct: Double = 0
    var isLoading = false
    var loadError: String?
    let chapterTask = NetworkTask()
    /// Chapter-embedded images fetched this work (src → image), the fetches
    /// in flight, and per-image failure messages for the placeholder.
    var loadedChapterImages: [String: NSImage] = [:]
    var chapterImageStatus: [String: String] = [:]
    var loadingChapterImages: Set<String> = []

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.textView = SelfSizingTextView(usingTextLayoutManager: true)
        self.footer = ReadFooterView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        metaLabel.font = MacFont.ui(12, weight: .semibold)
        titleLabel.font = MacFont.serif(30, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        titleRule.wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.usesFindBar = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        dropCapLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(textView)
        bodyContainer.addSubview(dropCapLabel)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            textView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            textView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            dropCapLabel.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            dropCapLabel.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: -4),
        ])

        endRule.wantsLayer = true
        ornamentLabel.font = MacFont.ui(20)
        ornamentLabel.alignment = .center
        nextChapterButton.isBordered = false
        nextChapterButton.wantsLayer = true
        nextChapterButton.layer?.cornerRadius = 11
        nextChapterButton.target = self
        nextChapterButton.action = #selector(nextChapter)
        nextChapterButton.translatesAutoresizingMaskIntoConstraints = false
        nextChapterButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        nextChapterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        endNoteBig.font = MacFont.serif(19)
        endNoteBig.alignment = .center
        endNoteSub.font = MacFont.ui(14)
        endNoteSub.alignment = .center
        nextWorkButton.isBordered = false
        nextWorkButton.wantsLayer = true
        nextWorkButton.layer?.cornerRadius = 11
        nextWorkButton.target = self
        nextWorkButton.action = #selector(openNextWorkInSeries)
        nextWorkButton.translatesAutoresizingMaskIntoConstraints = false
        nextWorkButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        nextWorkButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        column.edgeInsets = NSEdgeInsets(top: 46, left: 0, bottom: 120, right: 0)
        [metaLabel, titleLabel, titleRule, bodyContainer, endRule, ornamentLabel,
         nextChapterButton, endNoteBig, endNoteSub, nextWorkButton].forEach { column.addArrangedSubview($0) }
        column.setCustomSpacing(18, after: endNoteSub)
        column.setCustomSpacing(10, after: metaLabel)
        column.setCustomSpacing(22, after: titleLabel)
        column.setCustomSpacing(28, after: titleRule)
        column.setCustomSpacing(46, after: bodyContainer)
        column.setCustomSpacing(30, after: endRule)
        column.setCustomSpacing(20, after: ornamentLabel)
        column.setCustomSpacing(4, after: endNoteBig)

        titleRule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        titleRule.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        endRule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        endRule.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bodyContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        ornamentLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        endNoteBig.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        endNoteSub.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let document = FlippedView()
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        columnFill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -80)
        // Below windowSizeStayPut (500): with the fill required, fill + cap +
        // the required chain up through the split view demanded
        // window ≤ sidebar + list + measure + 80, and re-activating the cap on
        // immersive exit resolved that by shrinking the window. Sub-500, the
        // cap narrows the column instead and can never touch the window frame.
        columnFill.priority = NSLayoutConstraint.Priority(490)
        columnCap = column.widthAnchor.constraint(lessThanOrEqualToConstant: 680)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnFill,
            columnCap,
        ])

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        footer.onPrevious = { [weak self] in self?.goChapter(-1) }
        footer.onNext = { [weak self] in self?.goChapter(1) }
        footer.onReturn = { [weak self] in self?.model.returnToPreviousPosition() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollBegan),
                                               name: NSScrollView.willStartLiveScrollNotification,
                                               object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
                                               name: NSScrollView.didEndLiveScrollNotification,
                                               object: scrollView)

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            // Reading settings that require re-render.
            _ = (theme.activeTheme.id, theme.fontSize, theme.readingFont, theme.density, theme.measure,
                 theme.readHyphenation, theme.readJustified, model.immersive)
            DispatchQueue.main.async { self.renderChapter() }
        }
    }

    /// Saved position (character offset) to restore once the chapter
    /// content renders.
    var pendingRestorePos: Int?

    /// Character offset (from the document start) of the first body-text line
    /// visible at the top of the viewport. Unlike the scroll fraction, this
    /// survives reflows — immersive toggles, window/pane resizes, font and
    /// measure changes — so the reader stays on the same words.
    var anchorOffset: Int?
    /// True while a reflow or programmatic restore is rewriting scroll
    /// geometry; scroll notifications in that window are echoes of layout,
    /// not reader movement, and must not retrack the anchor or persist.
    var suppressTracking = false
    /// Viewport width the current text layout was produced for; a change
    /// means the text reflowed and the anchor must be re-applied.
    var lastLayoutWidth: CGFloat = 0
    /// Document height the anchor was last placed against. TextKit 2 keeps
    /// refining estimated heights after a reflow; when the document grows or
    /// shrinks without the user scrolling, the text has shifted under the
    /// viewport and the anchor must be re-applied.
    var lastDocumentHeight: CGFloat = 0
    /// True while the user is gesture-scrolling — their movement is always
    /// authoritative, so geometry shifts never trigger restores mid-gesture.
    var isLiveScrolling = false
    /// Line-start offset that should be at the viewport top after the last
    /// restore or user movement. When the top line diverges from this while
    /// the scroll offset is (nearly) unmoved, the text shifted underneath the
    /// viewport — re-pin instead of adopting the shifted position.
    var expectedTopLine: Int?
    var lastScrollY: CGFloat = 0
    /// Invalidates in-flight verification passes (new restore, new chapter).
    var verifyGeneration = 0
    /// Coalesces width-driven re-renders onto the next runloop turn, same
    /// rationale as scheduleAnchorRestore.
    var renderPending = false
    /// Coalesces restore requests onto the next runloop turn (see
    /// scheduleAnchorRestore).
    var restorePending = false
    /// Last persisted pct that was logged — keeps the diagnostic trail from
    /// recording every scroll tick.
    var lastPersistLogPct: Double = -1
    /// Debounce for scroll-driven progress persists: scroll ticks arrive
    /// continuously, so the write waits until the reader has been still
    /// for a second (see schedulePersist).
    var pendingPersist: DispatchWorkItem?

    /// Diagnostic trail readable outside Xcode. Mirrors the [ReaderPos] NSLogs.
    func posLog(_ message: String) {
        aoyoPosLog(message)
    }

    func show(work: Work, chapterIndex: Int) {
        // The debounced persist rides on state about to be repointed —
        // write the outgoing position now rather than lose it.
        flushPendingPersist()
        // Bound memory: decoded images don't outlive their work.
        if work.id != self.work?.id {
            loadedChapterImages = [:]
            chapterImageStatus = [:]
            loadingChapterImages = []
        }
        self.work = work
        self.chapterIndex = chapterIndex
        self.chapters = nil
        self.loadError = nil
        anchorOffset = nil
        expectedTopLine = nil
        verifyGeneration += 1
        pendingRestorePos = model.readerResumePos > 0 ? model.readerResumePos : nil
        posLog("show work=\(work.id) ch=\(chapterIndex) resumePos=\(model.readerResumePos)")
        model.readerResumePos = 0
        renderChapter()
        scrollToTop()
        Task { await loadChapters() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        let height = scrollView.documentView?.bounds.height ?? 0
        let widthChanged = width != lastLayoutWidth
        guard widthChanged || abs(height - lastDocumentHeight) > 0.5 else { return }
        lastLayoutWidth = width
        lastDocumentHeight = height
        // Width changes resize the fixed-width attachments (images, rules),
        // which requires a re-render, not just a re-wrap. renderChapter is
        // anchor-preserving, so the reader stays on the same words.
        if widthChanged, currentChapterContent != nil {
            scheduleRerender()
        }
        if anchorOffset != nil, pendingRestorePos == nil, !isLiveScrolling {
            scheduleAnchorRestore()
        }
    }
}
