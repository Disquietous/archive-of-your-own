import AppKit
import SwiftUI

/// In-place reading view: a TextKit 2 text view in a centered column at the
/// user's measure width. Chapters come from the local cache when available
/// and are fetched over Tor otherwise, mirroring the iOS reader.
final class ReaderViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let scrollView = NSScrollView()
    private let column = NSStackView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let titleRule = NSView()
    private let bodyContainer = NSView()
    private let textView: SelfSizingTextView
    private let dropCapLabel = NSTextField(labelWithString: "")
    private let endRule = NSView()
    private let ornamentLabel = NSTextField(labelWithString: "· · ·")
    private let nextChapterButton = NSButton(title: "Next chapter", target: nil, action: nil)
    private let endNoteBig = NSTextField(labelWithString: "")
    private let endNoteSub = NSTextField(labelWithString: "")
    private let nextWorkButton = NSButton(title: "Next work in series", target: nil, action: nil)
    private let footer: ReadFooterView
    private var overlayHost: NSHostingView<AnyView>?

    private var columnCap: NSLayoutConstraint!
    private var columnFill: NSLayoutConstraint!
    private var work: Work?
    private var chapters: [UChapter]?
    private var chapterIndex = 0
    private var chapterPct: Double = 0
    private var isLoading = false
    private var loadError: String?
    private let chapterTask = NetworkTask()
    /// Chapter-embedded images fetched this work (src → image), the fetches
    /// in flight, and per-image failure messages for the placeholder.
    private var loadedChapterImages: [String: NSImage] = [:]
    private var chapterImageStatus: [String: String] = [:]
    private var loadingChapterImages: Set<String> = []

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

    /// Saved scroll fraction to restore once the chapter content renders.
    private var pendingRestorePct: Double?

    /// Character offset (from the document start) of the first body-text line
    /// visible at the top of the viewport. Unlike the scroll fraction, this
    /// survives reflows — immersive toggles, window/pane resizes, font and
    /// measure changes — so the reader stays on the same words.
    private var anchorOffset: Int?
    /// True while a reflow or programmatic restore is rewriting scroll
    /// geometry; scroll notifications in that window are echoes of layout,
    /// not reader movement, and must not retrack the anchor or persist.
    private var suppressTracking = false
    /// Viewport width the current text layout was produced for; a change
    /// means the text reflowed and the anchor must be re-applied.
    private var lastLayoutWidth: CGFloat = 0
    /// Document height the anchor was last placed against. TextKit 2 keeps
    /// refining estimated heights after a reflow; when the document grows or
    /// shrinks without the user scrolling, the text has shifted under the
    /// viewport and the anchor must be re-applied.
    private var lastDocumentHeight: CGFloat = 0
    /// True while the user is gesture-scrolling — their movement is always
    /// authoritative, so geometry shifts never trigger restores mid-gesture.
    private var isLiveScrolling = false
    /// Line-start offset that should be at the viewport top after the last
    /// restore or user movement. When the top line diverges from this while
    /// the scroll offset is (nearly) unmoved, the text shifted underneath the
    /// viewport — re-pin instead of adopting the shifted position.
    private var expectedTopLine: Int?
    private var lastScrollY: CGFloat = 0
    /// Invalidates in-flight verification passes (new restore, new chapter).
    private var verifyGeneration = 0

    /// Diagnostic trail readable outside Xcode. Mirrors the [ReaderPos] NSLogs.
    private func posLog(_ message: String) {
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

    func show(work: Work, chapterIndex: Int) {
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
        pendingRestorePct = model.readerResumePct > 0.02 ? model.readerResumePct : nil
        model.readerResumePct = 0
        renderChapter()
        scrollToTop()
        Task { await loadChapters() }
    }

    // MARK: - Chapter acquisition (cache-first, then Tor)

    private func loadChapters(force: Bool = false) async {
        guard let work else { return }

        // Mock/preview works carry their content inline.
        if UInt64(work.id) == nil {
            if let content = work.content {
                chapters = content.enumerated().map { index, chapter in
                    UChapter(chapterId: Int64(index), number: UInt32(index + 1), title: chapter.title,
                             contentJson: "", notesBefore: "", notesAfter: "")
                }
            }
            renderChapter()
            return
        }
        guard let workId = UInt64(work.id) else { return }

        // A cached copy only satisfies the request if it reaches the chapter
        // being opened — a work updated since the last fetch falls through
        // to the network for the new chapter.
        if !force {
            // Already fetched this session?
            if let fetched = appState.chaptersForWork(work.id), !fetched.isEmpty,
               chapterIndex < fetched.count {
                chapters = fetched
                renderChapter()
                return
            }

            // Local database cache (downloaded / recently read works).
            let cached = appState.bridge.getCachedChapters(workId)
            if !cached.isEmpty, chapterIndex < cached.count {
                appState.fetchedChapters[work.id] = cached
                chapters = cached
                renderChapter()
                return
            }
        }

        // Fetch over the network (Tor-gated inside retryOnTimeout).
        isLoading = true
        loadError = nil
        renderChapter()
        do {
            let fetched = try await appState.retryOnTimeout(task: chapterTask, using: appState.bridge) {
                try await self.appState.bridge.fetchChapters(workId)
            }
            appState.fetchedChapters[work.id] = fetched
            chapters = fetched
            // Stale metadata promised a chapter AO3 doesn't have — land on
            // the last real one rather than an empty page.
            if !fetched.isEmpty, chapterIndex >= fetched.count {
                chapterIndex = fetched.count - 1
                model.readerChapter = chapterIndex
            }
        } catch {
            if !chapterTask.isCancelled && !"\(error)".contains("cancelled") {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
        renderChapter()
    }

    private func retryLoad() {
        loadError = nil
        Task { await loadChapters() }
    }

    /// Toolbar refresh: refetch the work's chapters from AO3, bypassing the
    /// session and database caches — the fetch rewrites the cached rows, so
    /// chapters whose text changed (or arrived) since the original fetch
    /// show their current content.
    func refreshChaptersFromAO3() {
        guard let work, UInt64(work.id) != nil, !isLoading else { return }
        appState.fetchedChapters[work.id] = nil
        chapters = nil
        loadError = nil
        Task { await loadChapters(force: true) }
    }

    private func cancelLoad() {
        chapterTask.cancel()
        appState.bridge.cancelRequest()
        model.closeReader()
    }

    // MARK: - Render

    private var currentChapterContent: (title: String, blocks: [ParsedContentBlock])? {
        guard let work else { return nil }
        // Inline mock content for preview works.
        if UInt64(work.id) == nil, let content = work.content, chapterIndex < content.count {
            let chapter = content[chapterIndex]
            return (chapter.title, ParsedContentBlock.fromParagraphs(chapter.paragraphs))
        }
        guard let chapters, chapterIndex < chapters.count else { return nil }
        let chapter = chapters[chapterIndex]
        guard !chapter.contentJson.isEmpty, chapter.contentJson != "[]" else { return nil }
        let title = chapter.title.isEmpty ? "Chapter \(chapterIndex + 1)" : chapter.title
        return (title, ParsedContentBlock.fromJSON(chapter.contentJson))
    }

    private var postedChapterCount: Int {
        // Metadata can know about chapters our cached copy predates (the
        // work updated since the last fetch) — trust whichever is larger,
        // so "Next chapter" appears and navigation triggers the fetch.
        max(chapters?.count ?? 0, max(work?.chapterCount ?? 0, 1))
    }

    private func renderChapter() {
        guard let work else { return }
        // Re-render of content the reader is already inside (immersive, font,
        // measure, theme changes): freeze the text anchor now and re-apply it
        // once the new layout exists.
        let restoreAfterRender = anchorOffset != nil && pendingRestorePct == nil
        if restoreAfterRender { scheduleAnchorRestore() }
        posLog("render immersive=\(model.immersive) anchor=\(anchorOffset ?? -1) restoreAfter=\(restoreAfterRender)")
        let bodySize = CGFloat(theme.fontSize)
        columnCap.isActive = !model.immersive
        columnCap.constant = CGFloat(theme.measure)
        view.layer?.backgroundColor = theme.nsBg.cgColor

        let totalLabel = work.complete ? String(work.totalChapters) : "?"
        metaLabel.attributedStringValue = NSAttributedString(
            string: "Chapter \(chapterIndex + 1) of \(totalLabel)".uppercased(),
            attributes: [.font: MacFont.ui(12, weight: .semibold), .kern: 0.8, .foregroundColor: theme.nsInk3])
        titleRule.layer?.backgroundColor = theme.nsLine.cgColor
        titleLabel.textColor = theme.nsInk

        updateOverlay()

        guard let content = currentChapterContent else {
            // Loading, error, or no content — clear the body.
            titleLabel.stringValue = isLoading || loadError != nil ? "" : "Chapter \(chapterIndex + 1)"
            textView.textStorage?.setAttributedString(NSAttributedString())
            dropCapLabel.isHidden = true
            [endRule, ornamentLabel, nextChapterButton, endNoteBig, endNoteSub, nextWorkButton].forEach { $0.isHidden = true }
            footer.applyTheme()
            updateProgress()
            // A scheduled restore bails on the now-empty document and lifts
            // the tracking suppression itself.
            return
        }

        titleLabel.stringValue = content.title
        primeAndLoadImages(in: content.blocks)
        var renderer = ContentBlockRenderer(theme: theme, paragraphStyle: .macReading)
        renderer.loadedImages = loadedChapterImages
        renderer.imageStatus = chapterImageStatus
        // Cap fixed-width elements (images, the hr rule) at the column the
        // text is ACTUALLY laid out in — the measure setting, or less when
        // the pane is narrower. An attachment wider than the container
        // can't wrap and distorts line layout.
        let liveColumn = min(CGFloat(theme.measure), scrollView.contentView.bounds.width - 80)
        renderer.imageDisplayWidth = max(240, liveColumn - 60)
        let body = NSMutableAttributedString(attributedString: renderer.render(blocks: content.blocks))
        applyDropCap(to: body, bodySize: bodySize)
        remapAnchor(toNewText: body.string)
        textView.textStorage?.setAttributedString(body)
        textView.invalidateIntrinsicContentSize()

        endRule.isHidden = false
        ornamentLabel.isHidden = false
        endRule.layer?.backgroundColor = theme.nsLine.cgColor
        ornamentLabel.textColor = theme.nsAccent

        let isLastChapter = chapterIndex >= postedChapterCount - 1
        nextChapterButton.isHidden = isLastChapter
        endNoteBig.isHidden = !isLastChapter
        endNoteSub.isHidden = !isLastChapter
        nextWorkButton.isHidden = !(isLastChapter && work.nextInSeries?.nextWorkID != nil)
        if isLastChapter {
            endNoteBig.stringValue = work.complete ? "The end" : "You’re all caught up"
            endNoteBig.textColor = theme.nsInk2
            endNoteSub.stringValue = work.complete ? "Thanks for reading." : "Updated \(work.updated)"
            endNoteSub.textColor = theme.nsInk3
            if !nextWorkButton.isHidden {
                nextWorkButton.layer?.backgroundColor = theme.nsAccent.cgColor
                nextWorkButton.attributedTitle = NSAttributedString(
                    string: "Next work in series  ›",
                    attributes: [.font: MacFont.ui(14.5, weight: .bold), .foregroundColor: theme.nsOnAccent])
            }
        } else {
            nextChapterButton.layer?.backgroundColor = theme.nsAccent.cgColor
            nextChapterButton.attributedTitle = NSAttributedString(
                string: "Next chapter  ›",
                attributes: [.font: MacFont.ui(14.5, weight: .bold), .foregroundColor: theme.nsOnAccent])
        }

        footer.applyTheme()
        updateProgress()

        // Land where the reader left off (Continue, chapter list, relaunch).
        if let pct = pendingRestorePct {
            pendingRestorePct = nil
            DispatchQueue.main.async { [weak self] in
                self?.restoreScroll(to: pct)
            }
        }
        // restoreAfterRender: the restore scheduled at the top of this pass
        // runs on the next turn, once this render's layout settles.
    }

    private func restoreScroll(to pct: Double) {
        view.layoutSubtreeIfNeeded()
        guard let documentHeight = scrollView.documentView?.bounds.height else { return }
        let maxOffset = documentHeight - scrollView.contentView.bounds.height
        guard maxOffset > 0 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset * pct))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Text-anchored position

    /// Any viewport width change (window or pane resize, immersive collapse
    /// animation frames) reflows the column; snap the scroll offset back to
    /// the anchored text rather than letting the raw point offset drift.
    @objc private func liveScrollBegan() {
        isLiveScrolling = true
    }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
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
        if anchorOffset != nil, pendingRestorePct == nil, !isLiveScrolling {
            scheduleAnchorRestore()
        }
    }

    /// Coalesces width-driven re-renders onto the next runloop turn, same
    /// rationale as scheduleAnchorRestore.
    private var renderPending = false

    private func scheduleRerender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renderPending = false
            renderChapter()
        }
    }

    /// Coalesces restore requests onto the next runloop turn: restoring from
    /// inside viewDidLayout reads half-updated frames (layoutSubtreeIfNeeded
    /// is a reentrant no-op there), and a burst of animation frames needs one
    /// restore after each turn's layout settles, not one per frame. Tracking
    /// is suppressed immediately so the layout churn in between can't be
    /// mistaken for the reader moving.
    private var restorePending = false

    private func scheduleAnchorRestore() {
        suppressTracking = true
        guard !restorePending else { return }
        restorePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restorePending = false
            self.restoreAnchor()
        }
    }

    /// Re-rendering replaces the whole text storage, and the rendered string
    /// changes length around image blocks (a tap-to-load placeholder line
    /// becomes attachment + caption, and its status text varies). A raw
    /// character-offset anchor below any such block would then point at
    /// different TEXT, and the restore would faithfully pin the wrong lines.
    /// Re-locate the anchor's actual words in the new string before the swap
    /// so the reader lands back on what they were reading.
    private func remapAnchor(toNewText newText: String) {
        guard let offset = anchorOffset,
              let oldText = textView.textStorage?.string,
              oldText != newText, !oldText.isEmpty, !newText.isEmpty else { return }
        let old = oldText as NSString
        let new = newText as NSString
        guard offset > 0, offset < old.length else { return }
        let snippetLen = min(96, old.length - offset)
        let snippet = old.substring(with: NSRange(location: offset, length: snippetLen))
        // ~96 chars of prose is unique in practice, but search a window
        // around the old offset first so a repeated phrase resolves to the
        // nearest occurrence.
        let drift = abs(new.length - old.length) + 256
        let windowStart = max(0, offset - drift)
        let windowLen = min(new.length - windowStart, snippetLen + 2 * drift)
        var found = windowLen > 0
            ? new.range(of: snippet, options: [], range: NSRange(location: windowStart, length: windowLen))
            : NSRange(location: NSNotFound, length: 0)
        if found.location == NSNotFound {
            found = new.range(of: snippet)
        }
        // Not found: the anchor line itself was swapped (it WAS the image
        // placeholder). Content before the block is unchanged, so the old
        // offset already points at the block's start — keep it.
        guard found.location != NSNotFound, found.location != offset else { return }
        posLog("anchor remap \(offset) -> \(found.location) after re-render")
        anchorOffset = found.location
        // Line starts moved with the text; restore recomputes this after
        // landing, and a stale value would read as drift in the meantime.
        expectedTopLine = nil
    }

    /// Character offset of the first body-text line at the top of the
    /// viewport, or nil while the header above the body is showing (there the
    /// raw offset is stable enough and there is no line to anchor to).
    private func captureAnchor() -> Int? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let document = scrollView.documentView else { return nil }
        let top = textView.convert(NSPoint(x: 0, y: scrollView.contentView.bounds.minY), from: document)
        guard top.y > 0 else { return nil }
        guard let fragment = layoutManager.textLayoutFragment(for: NSPoint(x: 0, y: top.y)) else { return nil }
        var location = fragment.rangeInElement.location
        let yInFragment = top.y - fragment.layoutFragmentFrame.minY
        for line in fragment.textLineFragments where line.typographicBounds.maxY > yInFragment {
            location = contentManager.location(fragment.rangeInElement.location,
                                               offsetBy: line.characterRange.location) ?? location
            break
        }
        return contentManager.offset(from: contentManager.documentRange.location, to: location)
    }

    /// Scrolls so the line holding `anchorOffset` sits back at the top of the
    /// viewport, then republishes progress from the new geometry.
    private func restoreAnchor() {
        guard let offset = anchorOffset else { return }
        suppressTracking = true
        defer {
            suppressTracking = false
            refreshProgress(persist: true)
        }
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let document = scrollView.documentView else { return }
        view.layoutSubtreeIfNeeded()
        let start = contentManager.documentRange.location
        let length = contentManager.offset(from: start, to: contentManager.documentRange.endLocation)
        guard length > 0 else {
            posLog("restore anchor=\(offset) bailed: empty doc")
            return
        }
        let clamped = min(offset, length - 1)

        // TextKit 2 gives two answers that can disagree: fragment enumeration
        // reports positions built on estimated heights for content it hasn't
        // materialized, while the viewport hit-test reflects what's actually
        // drawn. So converge on VISUAL truth: compare the line at the top of
        // the screen against the anchor's line, and when they differ, move by
        // the *difference* of their enumerated positions — the shared
        // estimation error above them cancels. Never accept "the scroll
        // offset stopped moving" as done; only "the anchor's line is what's
        // at the top".
        var passes = 0
        var finalPass = false
        while passes < 10 {
            passes += 1
            view.layoutSubtreeIfNeeded()
            guard let target = linePosition(of: clamped) else {
                posLog("restore anchor=\(offset) bailed: no target line")
                break
            }
            let currentY = scrollView.contentView.bounds.minY
            let viewportTop = textView.convert(NSPoint(x: 0, y: currentY), from: document).y
            let currentTop = captureAnchor()

            let delta: CGFloat
            let dropCapMaxY = textView.textContainer?.exclusionPaths.first?.bounds.maxY ?? 0
            if dropCapMaxY > 0, target.y <= dropCapMaxY {
                // Opening lines: the drop-cap exclusion makes fragment
                // enumeration and the viewport hit-test disagree by a
                // constant few points, so converging on "the anchor's line
                // is what's at the top" ping-pongs between the first two
                // lines until the pass budget runs out. This close to the
                // document top everything above the anchor is materialized,
                // so the enumerated position IS visual truth — pin it once
                // and accept.
                delta = target.y - viewportTop
                if abs(delta) < 1 { break }
                finalPass = true
            } else if let currentTop, currentTop == target.start {
                // Right line is on top — pin its top edge exactly, using
                // now-local (real) geometry.
                delta = target.y - viewportTop
                if abs(delta) < 1 { break }
            } else if let currentTop, let current = linePosition(of: currentTop) {
                // Wrong line — relative jump between the two lines' positions
                // within the same coordinate answer.
                delta = target.y - current.y
            } else {
                // Header above the body is showing; aim absolutely.
                delta = target.y - viewportTop
            }

            let maxOffset = document.bounds.height - scrollView.contentView.bounds.height
            guard maxOffset > 0 else { break }
            let newY = min(Swift.max(0, currentY + delta), maxOffset)
            // Clamped into place and can't improve further.
            if abs(newY - currentY) < 0.5 { break }
            // Instant jump: an implicitly animated scroll (inside the
            // immersive split-collapse animation) would keep emitting bounds
            // changes after suppression lifts, corrupting the anchor.
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            NSAnimationContext.endGrouping()
            // Materialize real layout at the new position before re-checking.
            layoutManager.textViewportLayoutController.layoutViewport()
            if finalPass { break }
        }
        lastLayoutWidth = scrollView.contentView.bounds.width
        lastDocumentHeight = document.bounds.height
        lastScrollY = scrollView.contentView.bounds.minY
        expectedTopLine = captureAnchor()
        posLog("restore anchor=\(offset) passes=\(passes) landed \(Int(lastScrollY)) top=\(expectedTopLine ?? -1)")
        scheduleAnchorVerify()
    }

    private struct LinePosition {
        let start: Int
        let y: CGFloat
    }

    /// Start offset and y (text-view coordinates) of the line containing the
    /// given character offset, per fragment enumeration. The y inherits
    /// whatever estimation error the layout above still carries — callers
    /// difference two of these so the shared error cancels.
    private func linePosition(of offset: Int) -> LinePosition? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let start = contentManager.documentRange.location
        guard let target = contentManager.location(start, offsetBy: offset) else { return nil }
        var fragment: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(from: target, options: [.ensuresLayout]) { found in
            fragment = found
            return false
        }
        guard let fragment else { return nil }
        let fragmentStart = contentManager.offset(from: start, to: fragment.rangeInElement.location)
        let within = offset - fragmentStart
        for line in fragment.textLineFragments where NSLocationInRange(within, line.characterRange) {
            return LinePosition(start: fragmentStart + line.characterRange.location,
                                y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
        }
        return LinePosition(start: fragmentStart, y: fragment.layoutFragmentFrame.minY)
    }

    /// The restores above run before the exit/enter transition ever paints;
    /// the first real draw then materializes true layout for the new column
    /// width, silently shifting fragment origins inside an unchanged frame —
    /// no layout pass, no bounds change, nothing to observe. So verify after
    /// display: staggered checks that re-pin if the top line drifted off the
    /// anchor while the viewport sat still.
    private func scheduleAnchorVerify() {
        verifyGeneration += 1
        let generation = verifyGeneration
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.verifyGeneration == generation else { return }
                self.verifyAnchor()
            }
        }
    }

    private func verifyAnchor() {
        guard anchorOffset != nil, !suppressTracking, !restorePending, !isLiveScrolling,
              currentChapterContent != nil, let expected = expectedTopLine else { return }
        guard let current = captureAnchor(), current != expected else { return }
        posLog("verify drift: top \(current) expected \(expected) — repin")
        scheduleAnchorRestore()
    }

    private func updateOverlay() {
        overlayHost?.removeFromSuperview()
        overlayHost = nil
        let overlay: AnyView?
        if isLoading {
            overlay = AnyView(LoadingStateMac(theme: theme, message: "Fetching chapter…",
                                              detail: chapterTask.statusMessage ?? "Loading over your private connection.",
                                              onCancel: { [weak self] in self?.cancelLoad() }))
        } else if let loadError {
            overlay = AnyView(VStack(spacing: 12) {
                EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                              title: "Couldn’t load chapter", message: loadError)
                Button("Try Again") { [weak self] in self?.retryLoad() }
                    .keyboardShortcut(.defaultAction)
            })
        } else {
            overlay = nil
        }
        if let overlay {
            let host = NSHostingView(rootView: overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            ])
            overlayHost = host
        }
    }

    /// Accent-colored drop cap: strip the first letter from the body and float
    /// it in an overlay label, pushing the opening lines right with an
    /// exclusion path (the TextKit equivalent of the CSS ::first-letter float).
    private func applyDropCap(to body: NSMutableAttributedString, bodySize: CGFloat) {
        dropCapLabel.isHidden = true
        textView.textContainer?.exclusionPaths = []
        guard body.length > 1 else { return }

        let firstChar = body.string[body.string.startIndex]
        guard firstChar.isLetter || firstChar == "\"" || firstChar == "“" else { return }

        let capFont = MacFont.reading(named: theme.readingFont.fontName, size: bodySize * 3.2)
        let cap = String(firstChar)
        body.deleteCharacters(in: NSRange(location: 0, length: cap.utf16.count))

        dropCapLabel.attributedStringValue = NSAttributedString(
            string: cap,
            attributes: [.font: MacFont.withWeight(capFont, .semibold), .foregroundColor: theme.nsAccent])
        dropCapLabel.isHidden = false
        dropCapLabel.sizeToFit()

        let capSize = dropCapLabel.frame.size
        let exclusion = NSRect(x: 0, y: 0,
                               width: capSize.width + bodySize * 0.35,
                               height: capSize.height - bodySize * 0.55)
        textView.textContainer?.exclusionPaths = [NSBezierPath(rect: exclusion)]
    }

    // MARK: - Chapter navigation & progress

    @objc private func nextChapter() {
        goChapter(1)
    }

    @objc private func openNextWorkInSeries() {
        guard let next = work?.nextInSeries?.nextWorkID else { return }
        model.openNextWorkInSeries(next)
    }

    /// Keyboard navigation entry point (← / → in the reading pane).
    func goToAdjacentChapter(_ delta: Int) {
        goChapter(delta)
    }

    private func goChapter(_ delta: Int) {
        guard let work else { return }
        let target = chapterIndex + delta
        guard target >= 0, target < postedChapterCount else { return }
        chapterIndex = target
        chapterPct = 0
        anchorOffset = nil
        expectedTopLine = nil
        verifyGeneration += 1
        model.readerChapter = target
        appState.pushHistory(work.id)
        appState.markWorkRead(work.id)
        // Reaching a chapter records it even if the reader never scrolls.
        appState.setProgress(work.id, chapter: target + 1, pct: 0)
        scrollToTop()
        // Stepping into a chapter the cached copy doesn't have yet (the
        // work updated since the last fetch): refetch past the caches —
        // the loading overlay renders until the new chapter arrives.
        if let chapters, target >= chapters.count {
            refreshChaptersFromAO3()
            return
        }
        renderChapter()
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func scrolled() {
        // Layout churn (reflow in flight, or a width the current layout wasn't
        // produced for) is not reader movement: viewDidLayout / restoreAnchor
        // will republish once the geometry settles.
        guard !suppressTracking, scrollView.contentView.bounds.width == lastLayoutWidth else { return }
        refreshProgress(persist: true)
        guard currentChapterContent != nil else { return }
        let y = scrollView.contentView.bounds.minY
        let captured = captureAnchor()
        // Top text changed while the viewport barely moved: the ground moved
        // (TextKit materializing real layout at paint time), not the reader.
        // Re-pin to the anchor rather than adopting the shifted position.
        if !isLiveScrolling, abs(y - lastScrollY) < 3,
           let captured, let expected = expectedTopLine, captured != expected {
            posLog("shift under viewport: top \(captured) expected \(expected) at y \(Int(y))")
            scheduleAnchorRestore()
            return
        }
        // A document-height change without a user gesture also means shifted
        // geometry — hold the anchor; viewDidLayout schedules the re-pin.
        let height = scrollView.documentView?.bounds.height ?? 0
        if isLiveScrolling || abs(height - lastDocumentHeight) <= 0.5 {
            if let old = anchorOffset, let new = captured, abs(new - old) > 400 {
                posLog("track jump \(old) -> \(new) at y \(Int(y))")
            }
            anchorOffset = captured
            expectedTopLine = captured
            lastScrollY = y
            lastDocumentHeight = height
        }
    }

    private func refreshProgress(persist: Bool) {
        guard let documentHeight = scrollView.documentView?.bounds.height else { return }
        let visible = scrollView.contentView.bounds
        let max = documentHeight - visible.height
        chapterPct = max > 0 ? min(1, Swift.max(0, visible.origin.y / max)) : 0
        updateProgress()
        if persist, let work, currentChapterContent != nil {
            // 1-based chapter; AppState keeps progress monotonic.
            appState.setProgress(work.id, chapter: chapterIndex + 1, pct: chapterPct)
        }
    }

    private func updateProgress() {
        guard let work else { return }
        let total = Double(Swift.max(1, work.complete ? work.totalChapters : postedChapterCount))
        let bookPct = (Double(chapterIndex) + chapterPct) / total
        footer.update(chapterPct: chapterPct, bookPct: bookPct,
                      canGoBack: chapterIndex > 0,
                      canGoForward: chapterIndex < postedChapterCount - 1)
    }

    // MARK: - Chapter-embedded images

    private static func imageSrcs(in blocks: [ParsedContentBlock]) -> [String] {
        var srcs: [String] = []
        func walk(_ blocks: [ParsedContentBlock]) {
            for block in blocks {
                switch block {
                case .image(let src, _):
                    if !srcs.contains(src) { srcs.append(src) }
                case .blockquote(let inner):
                    walk(inner)
                case .list(_, let items):
                    items.forEach(walk)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return srcs
    }

    /// Synchronously adopt already-cached images (downloaded works, earlier
    /// taps this session), and start fetches for the rest when auto-load is
    /// on. Tap-to-load is the default: uncached images stay placeholders.
    private func primeAndLoadImages(in blocks: [ParsedContentBlock]) {
        for src in Self.imageSrcs(in: blocks) where loadedChapterImages[src] == nil {
            if let data = appState.bridge.cachedChapterImage(url: src),
               let image = NSImage(data: data) {
                loadedChapterImages[src] = image
            } else if theme.imageAutoLoad {
                loadChapterImage(src)
            }
        }
    }

    private func loadChapterImage(_ src: String) {
        guard !loadingChapterImages.contains(src), loadedChapterImages[src] == nil else { return }
        loadingChapterImages.insert(src)
        chapterImageStatus[src] = "Loading image…"
        renderChapter()
        Task { @MainActor in
            do {
                let data = try await appState.bridge.fetchChapterImage(url: src, maxBytes: theme.imageMaxBytes)
                if let image = NSImage(data: data) {
                    loadedChapterImages[src] = image
                    chapterImageStatus[src] = nil
                    appState.bridge.writeLog(level: "INFO", tag: "image",
                        message: "Decoded \(data.count) bytes into \(Int(image.size.width))×\(Int(image.size.height)) for \(src)")
                } else {
                    let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    appState.bridge.writeLog(level: "ERROR", tag: "image",
                        message: "NSImage decode failed for \(src): \(data.count) bytes, head [\(head)]")
                    chapterImageStatus[src] = "Couldn’t decode image — tap to retry"
                }
            } catch {
                appState.bridge.writeLog(level: "ERROR", tag: "image",
                    message: "Fetch failed for \(src): \(error.localizedDescription)")
                chapterImageStatus[src] = "\(error.localizedDescription) — tap to retry"
            }
            loadingChapterImages.remove(src)
            renderChapter()
        }
    }
}

// MARK: - Link handling (tap-to-load images)

extension ReaderViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let src = ContentBlockRenderer.imageSrc(from: link) else {
            return false  // regular hyperlink — default handling
        }
        chapterImageStatus[src] = nil  // clear a stale error before retrying
        loadChapterImage(src)
        return true
    }
}

/// Bottom navigation bar: Previous · chapter progress line · running % · Next.
final class ReadFooterView: NSView {
    private let theme: AppTheme
    private let previousButton = NSButton(title: "‹ Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next ›", target: nil, action: nil)
    private let track = NSView()
    private let fill = NSView()
    private let pctLabel = NSTextField(labelWithString: "0%")
    private let topLine = NSView()
    private var fillWidth: NSLayoutConstraint!

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        for (button, selector) in [(previousButton, #selector(prev)), (nextButton, #selector(next))] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = 1
            button.target = self
            button.action = selector
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        }

        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 2
        track.addSubview(fill)
        pctLabel.font = MacFont.ui(12, weight: .bold)
        pctLabel.alignment = .right

        topLine.wantsLayer = true

        let bar = NSStackView(views: [previousButton, track, pctLabel, nextButton])
        bar.orientation = .horizontal
        bar.spacing = 14
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)
        addSubview(bar)
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 50),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 4),
            pctLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func prev() {
        onPrevious?()
    }

    @objc private func next() {
        onNext?()
    }

    func update(chapterPct: Double, bookPct: Double, canGoBack: Bool, canGoForward: Bool) {
        layoutSubtreeIfNeeded()
        fillWidth.constant = track.bounds.width * chapterPct
        pctLabel.stringValue = "\(Int((bookPct * 100).rounded()))%"
        previousButton.isEnabled = canGoBack
        previousButton.alphaValue = canGoBack ? 1 : 0.4
        nextButton.isEnabled = canGoForward
        nextButton.alphaValue = canGoForward ? 1 : 0.4
    }

    func applyTheme() {
        layer?.backgroundColor = theme.nsBg.cgColor
        topLine.layer?.backgroundColor = theme.nsLine.cgColor
        track.layer?.backgroundColor = theme.nsSurface3.cgColor
        fill.layer?.backgroundColor = theme.nsAccent.cgColor
        pctLabel.textColor = theme.nsAccent
        for (button, title) in [(previousButton, "‹ Previous"), (nextButton, "Next ›")] {
            button.layer?.backgroundColor = theme.nsSurface.cgColor
            button.layer?.borderColor = theme.nsLine.cgColor
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: MacFont.ui(13, weight: .semibold), .foregroundColor: theme.nsInk2])
        }
    }
}

/// NSTextView that reports its laid-out height as intrinsic size so it can
/// live inside a stack view without its own scroll view.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = textLayoutManager else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let height = layoutManager.usageBoundsForTextContainer.height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

/// Flipped container so stacked reading content lays out top-down in a scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
