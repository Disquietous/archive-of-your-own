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
    private let footer: ReadFooterView
    private var overlayHost: NSHostingView<AnyView>?

    private var columnWidth: NSLayoutConstraint!
    private var work: Work?
    private var chapters: [UChapter]?
    private var chapterIndex = 0
    private var chapterPct: Double = 0
    private var isLoading = false
    private var loadError: String?
    private let chapterTask = NetworkTask()

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
        titleRule.wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
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

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 46, left: 0, bottom: 120, right: 0)
        [metaLabel, titleLabel, titleRule, bodyContainer, endRule, ornamentLabel,
         nextChapterButton, endNoteBig, endNoteSub].forEach { column.addArrangedSubview($0) }
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
        columnWidth = column.widthAnchor.constraint(equalToConstant: 680)
        columnWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnWidth,
            column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -80),
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

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            // Reading settings that require re-render.
            _ = (theme.activeTheme.id, theme.fontSize, theme.readingFont, theme.density, theme.measure)
            DispatchQueue.main.async { self.renderChapter() }
        }
    }

    func show(work: Work, chapterIndex: Int) {
        self.work = work
        self.chapterIndex = chapterIndex
        self.chapters = nil
        self.loadError = nil
        renderChapter()
        scrollToTop()
        Task { await loadChapters() }
    }

    // MARK: - Chapter acquisition (cache-first, then Tor)

    private func loadChapters() async {
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

        // Already fetched this session?
        if let fetched = appState.chaptersForWork(work.id), !fetched.isEmpty {
            chapters = fetched
            renderChapter()
            return
        }

        // Local database cache (downloaded / recently read works).
        let cached = appState.bridge.getCachedChapters(workId)
        if !cached.isEmpty {
            appState.fetchedChapters[work.id] = cached
            chapters = cached
            renderChapter()
            return
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
        chapters?.count ?? work?.chapterCount ?? 1
    }

    private func renderChapter() {
        guard let work else { return }
        let bodySize = CGFloat(theme.fontSize)
        columnWidth.constant = CGFloat(theme.measure)
        view.layer?.backgroundColor = theme.nsBg.cgColor

        let totalLabel = work.complete ? String(work.totalChapters) : "?"
        metaLabel.attributedStringValue = NSAttributedString(
            string: "\(work.fandom) · Chapter \(chapterIndex + 1) of \(totalLabel)".uppercased(),
            attributes: [.font: MacFont.ui(12, weight: .semibold), .kern: 0.8, .foregroundColor: theme.nsInk3])
        titleRule.layer?.backgroundColor = theme.nsLine.cgColor
        titleLabel.textColor = theme.nsInk

        updateOverlay()

        guard let content = currentChapterContent else {
            // Loading, error, or no content — clear the body.
            titleLabel.stringValue = isLoading || loadError != nil ? "" : "Chapter \(chapterIndex + 1)"
            textView.textStorage?.setAttributedString(NSAttributedString())
            dropCapLabel.isHidden = true
            [endRule, ornamentLabel, nextChapterButton, endNoteBig, endNoteSub].forEach { $0.isHidden = true }
            footer.applyTheme()
            updateProgress()
            return
        }

        titleLabel.stringValue = content.title
        let renderer = ContentBlockRenderer(theme: theme, paragraphStyle: .macReading)
        let body = NSMutableAttributedString(attributedString: renderer.render(blocks: content.blocks))
        applyDropCap(to: body, bodySize: bodySize)
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
        if isLastChapter {
            endNoteBig.stringValue = work.complete ? "The end" : "You’re all caught up"
            endNoteBig.textColor = theme.nsInk2
            endNoteSub.stringValue = work.complete ? "Thanks for reading." : "Updated \(work.updated)"
            endNoteSub.textColor = theme.nsInk3
        } else {
            nextChapterButton.layer?.backgroundColor = theme.nsAccent.cgColor
            nextChapterButton.attributedTitle = NSAttributedString(
                string: "Next chapter  ›",
                attributes: [.font: MacFont.ui(14.5, weight: .bold), .foregroundColor: theme.nsOnAccent])
        }

        footer.applyTheme()
        updateProgress()
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

    private func goChapter(_ delta: Int) {
        guard let work else { return }
        let target = chapterIndex + delta
        guard target >= 0, target < postedChapterCount else { return }
        chapterIndex = target
        chapterPct = 0
        model.readerChapter = target
        appState.pushHistory(work.id)
        renderChapter()
        scrollToTop()
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func scrolled() {
        guard let documentHeight = scrollView.documentView?.bounds.height else { return }
        let visible = scrollView.contentView.bounds
        let max = documentHeight - visible.height
        chapterPct = max > 0 ? min(1, Swift.max(0, visible.origin.y / max)) : 0
        updateProgress()
        if let work, currentChapterContent != nil {
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
