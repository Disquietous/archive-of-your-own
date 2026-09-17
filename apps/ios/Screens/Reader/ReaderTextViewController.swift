import UIKit
import SwiftUI

/// Diagnostic trail for the reading position, mirroring the macOS
/// [ReaderPos] log.
func aoyoPosLog(_ message: String) {
    NSLog("[ReaderPos] %@", message)
}

/// A reading position as the library stores it: a 0-based chapter and a
/// character offset into that chapter's rendered body — the same unit the
/// macOS reader persists, so positions travel between devices.
struct ReaderPosition: Equatable {
    var chapter: Int
    var offset: Int
}

/// One chapter in the reader column.
struct ReaderTextSection: Equatable {
    let chapterIndex: Int
    /// "Ch 3 of 12".
    let meta: String
    let title: String
    let blocks: [ParsedContentBlock]
}

/// What the column shows. Equality is by `key` only — the SwiftUI side
/// rebuilds this on every render, and comparing whole block trees on each
/// scroll tick would be waste; the key changes whenever the sections do.
struct ReaderTextContent: Equatable {
    let key: String
    let workID: String
    let sections: [ReaderTextSection]

    static func == (lhs: ReaderTextContent, rhs: ReaderTextContent) -> Bool {
        lhs.key == rhs.key
    }
}

/// Visual inputs read off the theme by the SwiftUI side (so changes flow
/// through updateUIViewController) plus the chrome insets.
struct ReaderTextStyle: Equatable {
    let themeID: String
    let fontName: String
    let fontSize: Int
    let readLeading: CGFloat
    let hyphenation: Bool
    let justified: Bool
    /// Column cap; nil lets the column fill the width (phones).
    let measure: CGFloat?
    let readMargin: CGFloat
    let chromeTop: CGFloat
    let chromeBottom: CGFloat
}

/// A top-level block of one chapter, for the TTS highlight.
struct ReaderBlockRef: Equatable {
    let chapter: Int
    let block: Int
}

/// Land the reader on `position`. A new `id` is a new request; the
/// controller consumes it once the chapter's content is rendered.
struct ReaderRestoreRequest: Equatable {
    let id: Int
    let position: ReaderPosition
}

/// UITextView that reports its laid-out height as intrinsic size so it can
/// live inside a stack view without its own scrolling.
/// Sizing is UITextView's own (a non-scrolling text view reports its
/// content height as intrinsic size). Asking the TextKit 2 layout manager
/// for usage bounds returns estimates on iOS, not laid-out geometry.
final class ReaderBodyTextView: UITextView {
    /// Fired after every layout pass of the text view itself — the only
    /// moment its width (and so the column's real geometry) is known.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The reading column: one TextKit 2 text view holding every chapter the
/// reader shows (one, or the entire work), in a scroll view, followed by
/// the SwiftUI end-of-chapter content. Owns the text-anchored position —
/// the character offset of the first visible line — exactly as the macOS
/// reader does, so the position survives reflows and is persisted in the
/// unit the synced library expects.
final class ReaderTextViewController: UIViewController {
    let theme: AppTheme

    let scrollView = UIScrollView()
    private let column = UIStackView()
    let textView = ReaderBodyTextView(usingTextLayoutManager: true)
    private let endHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var columnCap: NSLayoutConstraint!
    private var columnFill: NSLayoutConstraint!

    // MARK: Inputs

    private(set) var content: ReaderTextContent?
    private var style: ReaderTextStyle?
    private var loadedImages: [String: UIImage] = [:]
    private var imageStatus: [String: String] = [:]
    private var highlight: ReaderBlockRef?
    private var highlightedRange: NSRange?
    private var lastRestoreID: Int?

    // MARK: Outputs

    /// The settled position and the rendered length of its chapter body.
    var onPersist: ((ReaderPosition, Int) -> Void)?
    /// Reader movement: offset delta (positive = down) and overall progress.
    var onScroll: ((CGFloat, Double) -> Void)?
    var onVisibleChapter: ((Int) -> Void)?
    var onTap: (() -> Void)?
    var onImageTap: ((String) -> Void)?
    var onLink: ((URL) -> Void)?

    // MARK: Document layout

    /// Where each section landed in the rendered document.
    private struct SectionLayout {
        let chapterIndex: Int
        let headerStart: Int
        let bodyStart: Int
        let bodyEnd: Int
        /// The macOS reader lifts the chapter's first letter out of the
        /// body as a drop cap, so its offsets run one short of ours for
        /// chapters that start with a letter. Persist and restore correct
        /// by this so both devices mean the same character.
        let dropCapAdjust: Int
        let blockRanges: [NSRange]
    }

    private var layouts: [SectionLayout] = []

    // MARK: Anchor state (see the macOS ReaderViewController)

    /// Saved position to restore once its chapter's content renders.
    private var pendingRestore: ReaderPosition?
    /// Character offset (document-wide) of the first visible line.
    private(set) var anchorOffset: Int?
    private var suppressTracking = false
    private var lastLayoutWidth: CGFloat = 0
    private var lastDocumentHeight: CGFloat = 0
    private var isLiveScrolling = false
    private var expectedTopLine: Int?
    private var lastScrollY: CGFloat = 0
    private var verifyGeneration = 0
    private var renderPending = false
    private var restorePending = false
    private var pendingPersist: DispatchWorkItem?
    private var visibleChapter: Int?
    private var lastReportedY: CGFloat = 0

    init(theme: AppTheme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View

    override func loadView() {
        let root = UIView()

        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]
        textView.delegate = self
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.onLayout = { [weak self] in self?.geometryDidChange() }

        endHost.view.backgroundColor = .clear
        endHost.sizingOptions = [.intrinsicContentSize]
        addChild(endHost)

        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 32
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(textView)
        column.addArrangedSubview(endHost.view)
        scrollView.addSubview(column)
        endHost.didMove(toParent: self)

        columnFill = column.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        columnFill.priority = UILayoutPriority(490)
        columnCap = column.widthAnchor.constraint(lessThanOrEqualToConstant: 680)
        columnCap.isActive = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -40),
            column.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            columnFill,
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)

        view = root
    }

    /// The column has real geometry to anchor against. Until it is in a
    /// window with a laid-out width (SwiftUI creates the controller inside
    /// its own update, before that), a restore would read empty frames,
    /// land at the top and release tracking — so restores wait here.
    private var hasLayout: Bool {
        view.window != nil && textView.bounds.width > 0
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        geometryDidChange()
    }

    /// Runs after the controller's view and after the text view lay out.
    /// The view controller callback alone fires before the text view has
    /// its width (children lay out after their parent), so the text view
    /// reports its own passes too.
    private func geometryDidChange() {
        if pendingRestore != nil, hasLayout {
            consumePendingRestore()
        }
        let width = textView.bounds.width
        let height = scrollView.contentSize.height
        let widthChanged = width != lastLayoutWidth
        guard widthChanged || abs(height - lastDocumentHeight) > 0.5 else { return }
        aoyoPosLog("geometry width \(Int(lastLayoutWidth))->\(Int(width)) height \(Int(lastDocumentHeight))->\(Int(height)) anchor=\(anchorOffset ?? -1) pending=\(pendingRestore != nil)")
        lastLayoutWidth = width
        lastDocumentHeight = height
        // Width changes resize the fixed-width attachments (images, rules),
        // which requires a re-render, not just a re-wrap. render() is
        // anchor-preserving, so the reader stays on the same words.
        if widthChanged, content != nil {
            scheduleRerender()
        }
        if anchorOffset != nil, pendingRestore == nil, !isLiveScrolling {
            scheduleAnchorRestore()
        }
    }

    // MARK: - Inputs

    func apply(content newContent: ReaderTextContent?, style newStyle: ReaderTextStyle,
               images: [String: UIImage], imageStatus newStatus: [String: String],
               highlight newHighlight: ReaderBlockRef?, restore: ReaderRestoreRequest?,
               endView: AnyView) {
        var needsRender = false
        if content != newContent {
            if content?.workID != newContent?.workID {
                anchorOffset = nil
                expectedTopLine = nil
            }
            content = newContent
            needsRender = true
        }
        if style != newStyle {
            let insetsOnly = style.map { Self.differsOnlyInChrome($0, newStyle) } ?? false
            style = newStyle
            view.backgroundColor = .clear
            columnCap.constant = newStyle.measure ?? 680
            columnCap.isActive = newStyle.measure != nil
            columnFill.constant = -2 * newStyle.readMargin
            scrollView.contentInset = UIEdgeInsets(top: newStyle.chromeTop, left: 0, bottom: newStyle.chromeBottom, right: 0)
            scrollView.verticalScrollIndicatorInsets = scrollView.contentInset
            if !insetsOnly { needsRender = true }
        }
        if loadedImages != images || imageStatus != newStatus {
            loadedImages = images
            imageStatus = newStatus
            needsRender = true
        }
        if let restore, restore.id != lastRestoreID {
            lastRestoreID = restore.id
            pendingRestore = restore.position
            aoyoPosLog("restore request ch=\(restore.position.chapter) pos=\(restore.position.offset)")
            // A fresh landing: the current anchor is where the reader WAS.
            anchorOffset = nil
            expectedTopLine = nil
            verifyGeneration += 1
            if !needsRender { consumePendingRestore() }
        }
        endHost.rootView = endView
        if needsRender {
            render()
        }
        if highlight != newHighlight {
            highlight = newHighlight
            applyHighlight()
        }
    }

    private static func differsOnlyInChrome(_ a: ReaderTextStyle, _ b: ReaderTextStyle) -> Bool {
        a.themeID == b.themeID && a.fontName == b.fontName && a.fontSize == b.fontSize
            && a.readLeading == b.readLeading && a.hyphenation == b.hyphenation
            && a.justified == b.justified && a.measure == b.measure && a.readMargin == b.readMargin
    }

    // MARK: - Render

    private func scheduleRerender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renderPending = false
            render()
        }
    }

    private func render() {
        guard let content, style != nil else {
            textView.attributedText = NSAttributedString()
            layouts = []
            highlightedRange = nil
            return
        }
        // Re-render of content the reader is already inside (font, measure,
        // theme changes, image arrivals): freeze the text anchor now and
        // re-apply it once the new layout exists.
        let restoreAfterRender = anchorOffset != nil && pendingRestore == nil
        if restoreAfterRender { scheduleAnchorRestore() }

        var renderer = ContentBlockRenderer(theme: theme, paragraphStyle: .indented)
        renderer.loadedImages = loadedImages
        renderer.imageStatus = imageStatus
        let liveColumn = textView.bounds.width > 0
            ? textView.bounds.width
            : view.bounds.width - 2 * (style?.readMargin ?? 20)
        renderer.imageDisplayWidth = max(160, liveColumn)

        let document = NSMutableAttributedString()
        var newLayouts: [SectionLayout] = []
        for (index, section) in content.sections.enumerated() {
            let headerStart = document.length
            document.append(renderer.renderHeader(meta: section.meta, title: section.title,
                                                  leadingDivider: index > 0))
            let bodyStart = document.length
            var ranges: [NSRange] = []
            let body = renderer.render(blocks: section.blocks, blockRanges: &ranges)
            document.append(body)
            newLayouts.append(SectionLayout(
                chapterIndex: section.chapterIndex,
                headerStart: headerStart,
                bodyStart: bodyStart,
                bodyEnd: document.length,
                dropCapAdjust: Self.dropCapAdjust(for: body.string),
                blockRanges: ranges.map { NSRange(location: $0.location + bodyStart, length: $0.length) }))
        }

        remapAnchor(toNewText: document.string)
        textView.attributedText = document
        layouts = newLayouts
        highlightedRange = nil
        textView.invalidateIntrinsicContentSize()
        applyHighlight()
        aoyoPosLog("render sections=\(content.sections.count) anchor=\(anchorOffset ?? -1) restoreAfter=\(restoreAfterRender)")
        consumePendingRestore()
    }

    /// The macOS reader deletes the chapter's first character to float it
    /// as a drop cap when it is a letter or an opening quote.
    private static func dropCapAdjust(for body: String) -> Int {
        guard body.utf16.count > 1, let first = body.first else { return 0 }
        return first.isLetter || first == "\"" || first == "“" ? 1 : 0
    }

    /// Land where the reader left off once the chapter is in the document:
    /// hand the saved offset to the same anchor machinery that survives
    /// reflows.
    private func consumePendingRestore() {
        guard let pending = pendingRestore,
              let layout = layouts.first(where: { $0.chapterIndex == pending.chapter }) else { return }
        guard hasLayout else {
            aoyoPosLog("restore ch=\(pending.chapter) pos=\(pending.offset) waits for layout")
            return
        }
        pendingRestore = nil
        let global = Self.globalOffset(for: pending.offset, in: layout)
        aoyoPosLog("consume restore ch=\(pending.chapter) pos=\(pending.offset) -> global \(global)")
        expectedTopLine = nil
        if global > 0 {
            anchorOffset = global
            scheduleAnchorRestore()
        } else {
            anchorOffset = nil
            scrollToTop()
            reportVisibleChapter()
            refreshProgress(persist: true)
        }
    }

    private static func globalOffset(for local: Int, in layout: SectionLayout) -> Int {
        guard local > 0 else { return layout.headerStart }
        return min(layout.bodyStart + layout.dropCapAdjust + local, max(layout.bodyStart, layout.bodyEnd - 1))
    }

    private func layout(containing global: Int) -> SectionLayout? {
        layouts.last { $0.headerStart <= global }
    }

    /// The chapter-local position for a document offset, as persisted.
    private func position(forGlobal global: Int?) -> (ReaderPosition, Int)? {
        guard let first = layouts.first else { return nil }
        guard let global, let layout = layout(containing: global) else {
            return (ReaderPosition(chapter: first.chapterIndex, offset: 0), first.bodyEnd - first.bodyStart)
        }
        let local = max(0, global - layout.bodyStart - layout.dropCapAdjust)
        return (ReaderPosition(chapter: layout.chapterIndex, offset: local), layout.bodyEnd - layout.bodyStart)
    }

    /// Where the reader is right now, for the return control and moving
    /// the work to a window.
    var currentPosition: ReaderPosition? {
        position(forGlobal: anchorOffset)?.0
    }

    private func applyHighlight() {
        let storage = textView.textStorage
        if let old = highlightedRange, NSMaxRange(old) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old)
        }
        highlightedRange = nil
        guard let highlight,
              let layout = layouts.first(where: { $0.chapterIndex == highlight.chapter }),
              highlight.block < layout.blockRanges.count else { return }
        let range = layout.blockRanges[highlight.block]
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.backgroundColor, value: UIColor(theme.accentSoft), range: range)
        highlightedRange = range
    }

    func scrollToTop() {
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
    }

    // MARK: - Persist

    private func refreshProgress(persist: Bool) {
        let inset = scrollView.adjustedContentInset
        let span = scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height
        let y = scrollView.contentOffset.y + inset.top
        let progress = span > 0 ? min(1, max(0, y / span)) : 0
        // Only the reader's own movement drives the chrome; a restore's
        // jump is not a gesture. Delivered on the next turn so state on the
        // SwiftUI side never changes inside its own update.
        let delta = isLiveScrolling ? y - lastReportedY : 0
        lastReportedY = y
        DispatchQueue.main.async { [weak self] in self?.onScroll?(delta, progress) }
        // Persist only when the geometry is trustworthy: a pending or
        // in-flight restore means the viewport is mid-churn and a captured
        // offset could be layout noise, not the reader's place.
        if persist, content != nil, pendingRestore == nil, !restorePending, !suppressTracking {
            schedulePersist()
        }
    }

    /// Each qualifying scroll tick pushes the deadline out; the write
    /// happens once the reader has been still for a second.
    private func schedulePersist() {
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingPersist = nil
            persistProgressNow()
        }
        pendingPersist = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func persistProgressNow() {
        guard content != nil, pendingRestore == nil, !restorePending, !suppressTracking,
              let resolved = position(forGlobal: anchorOffset) else { return }
        aoyoPosLog("persist ch=\(resolved.0.chapter + 1) pos=\(resolved.0.offset) anchor=\(anchorOffset ?? -1)")
        onPersist?(resolved.0, resolved.1)
    }

    /// Run any pending debounced persist immediately — before the reader is
    /// repointed or left so the last position isn't lost.
    func flushPendingPersist() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        persistProgressNow()
    }

    /// Drop the pending debounced persist without writing it — the library
    /// was replaced and the position it holds is no longer true.
    func cancelPendingPersist() {
        pendingPersist?.cancel()
        pendingPersist = nil
    }

    private func reportVisibleChapter() {
        guard let resolved = position(forGlobal: anchorOffset) else { return }
        if visibleChapter != resolved.0.chapter {
            let chapter = resolved.0.chapter
            visibleChapter = chapter
            DispatchQueue.main.async { [weak self] in self?.onVisibleChapter?(chapter) }
        }
    }

    // MARK: - Text-anchored position

    /// Coalesces restore requests onto the next runloop turn: restoring from
    /// inside a layout pass reads half-updated frames, and a burst of
    /// animation frames needs one restore after each turn's layout settles.
    /// Tracking is suppressed immediately so the layout churn in between
    /// can't be mistaken for the reader moving.
    private func scheduleAnchorRestore() {
        suppressTracking = true
        guard !restorePending else { return }
        restorePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            restorePending = false
            restoreAnchor()
        }
    }

    /// Re-rendering replaces the whole text storage, and the rendered string
    /// changes length around image blocks. Re-locate the anchor's actual
    /// words in the new string before the swap so the reader lands back on
    /// what they were reading.
    private func remapAnchor(toNewText newText: String) {
        guard let offset = anchorOffset,
              let oldText = textView.attributedText?.string,
              oldText != newText, !oldText.isEmpty, !newText.isEmpty else { return }
        let old = oldText as NSString
        let new = newText as NSString
        guard offset > 0, offset < old.length else { return }
        let snippetLen = min(96, old.length - offset)
        let snippet = old.substring(with: NSRange(location: offset, length: snippetLen))
        let drift = abs(new.length - old.length) + 256
        let windowStart = max(0, offset - drift)
        let windowLen = min(new.length - windowStart, snippetLen + 2 * drift)
        var found = windowLen > 0
            ? new.range(of: snippet, options: [], range: NSRange(location: windowStart, length: windowLen))
            : NSRange(location: NSNotFound, length: 0)
        if found.location == NSNotFound {
            found = new.range(of: snippet)
        }
        guard found.location != NSNotFound, found.location != offset else { return }
        aoyoPosLog("anchor remap \(offset) -> \(found.location) after re-render")
        anchorOffset = found.location
        expectedTopLine = nil
    }

    /// Y of the viewport's top edge in text-view coordinates.
    private var viewportTopInText: CGFloat {
        let y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        return textView.convert(CGPoint(x: 0, y: y), from: scrollView).y
    }

    /// Start of the visual line holding `position`. The tokenizer returns
    /// nil for a position already at the line's leading boundary.
    private func lineStart(of position: UITextPosition) -> UITextPosition {
        let tokenizer = textView.tokenizer
        if let range = tokenizer.rangeEnclosingPosition(position, with: .line, inDirection: .layout(.left)) {
            return range.start
        }
        if tokenizer.isPosition(position, atBoundary: .line, inDirection: .layout(.left)) {
            return position
        }
        return tokenizer.rangeEnclosingPosition(position, with: .line, inDirection: .layout(.right))?.start ?? position
    }

    private func offset(of position: UITextPosition) -> Int {
        textView.offset(from: textView.beginningOfDocument, to: position)
    }

    /// Character offset of the first text line at the top of the viewport,
    /// or nil while the space above the text is showing. Goes through the
    /// text view's UITextInput geometry, which UIKit answers for any
    /// position; the layout manager's fragment frames are not populated
    /// away from the viewport on iOS.
    private func captureAnchor() -> Int? {
        let topY = viewportTopInText
        guard topY > 0 else { return nil }
        guard let hit = textView.closestPosition(to: CGPoint(x: 0, y: topY)) else { return nil }
        var start = lineStart(of: hit)
        let rect = textView.caretRect(for: start)
        if rect.maxY <= topY, rect.height > 0,
           let below = textView.closestPosition(to: CGPoint(x: 0, y: rect.maxY + 1)) {
            // The hit line ends above the viewport top: the first line
            // actually showing is the next one.
            start = lineStart(of: below)
        }
        return offset(of: start)
    }

    /// Scrolls so the line holding `anchorOffset` sits back at the top of
    /// the viewport, then republishes progress from the new geometry.
    private func restoreAnchor() {
        guard let offset = anchorOffset else {
            suppressTracking = false
            aoyoPosLog("restore skipped: no anchor — tracking released")
            return
        }
        guard hasLayout else {
            // Tracking stays suppressed; the layout pass that gives the
            // column its width re-renders and schedules this again.
            aoyoPosLog("restore anchor=\(offset) deferred: no layout yet")
            return
        }
        suppressTracking = true
        defer {
            suppressTracking = false
            reportVisibleChapter()
            refreshProgress(persist: true)
        }
        view.layoutIfNeeded()
        let length = textView.attributedText?.length ?? 0
        guard length > 0 else {
            aoyoPosLog("restore anchor=\(offset) bailed: empty doc")
            return
        }
        let clamped = min(offset, length - 1)
        aoyoPosLog("restore start: offset=\(offset) docLen=\(length) scroll bounds=\(Int(scrollView.bounds.height)) content=\(Int(scrollView.contentSize.height)) inset top=\(Int(scrollView.adjustedContentInset.top)) bottom=\(Int(scrollView.adjustedContentInset.bottom)) y=\(Int(scrollView.contentOffset.y)) textView y=\(Int(textView.frame.minY)) h=\(Int(textView.bounds.height))")

        // Converge on VISUAL truth: compare the line at the top of the
        // screen against the anchor's line, and when they differ, move by
        // the difference of their enumerated positions (see the macOS
        // reader for why enumeration and the viewport hit-test disagree).
        var passes = 0
        while passes < 10 {
            passes += 1
            view.layoutIfNeeded()
            guard let target = linePosition(of: clamped) else {
                aoyoPosLog("restore anchor=\(offset) bailed: no target line")
                break
            }
            let currentY = scrollView.contentOffset.y
            let viewportTop = viewportTopInText
            let currentTop = captureAnchor()

            let delta: CGFloat
            if let currentTop, currentTop == target.start {
                delta = target.y - viewportTop
                if abs(delta) < 1 { break }
            } else if let currentTop, let current = linePosition(of: currentTop) {
                delta = target.y - current.y
            } else {
                delta = target.y - viewportTop
            }

            let inset = scrollView.adjustedContentInset
            let maxOffset = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height
            let minOffset = -inset.top
            guard maxOffset > minOffset else {
                aoyoPosLog("pass \(passes): nothing to scroll (content \(Int(scrollView.contentSize.height)) bounds \(Int(scrollView.bounds.height)))")
                break
            }
            let newY = min(max(minOffset, currentY + delta), maxOffset)
            aoyoPosLog("pass \(passes): target start=\(target.start) y=\(Int(target.y)) viewportTop=\(Int(viewportTop)) currentTop=\(currentTop ?? -1) currentY=\(Int(currentY)) delta=\(Int(delta)) range=[\(Int(minOffset)),\(Int(maxOffset))] newY=\(Int(newY))")
            if abs(newY - currentY) < 0.5 { break }
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(CGPoint(x: 0, y: newY), animated: false)
            }
            // Materialize layout at the new position before re-checking.
            view.layoutIfNeeded()
        }
        lastLayoutWidth = textView.bounds.width
        lastDocumentHeight = scrollView.contentSize.height
        lastScrollY = scrollView.contentOffset.y
        expectedTopLine = captureAnchor()
        aoyoPosLog("restore anchor=\(offset) passes=\(passes) landed \(Int(lastScrollY)) top=\(expectedTopLine ?? -1)")
        scheduleAnchorVerify()
    }

    private struct LinePosition {
        let start: Int
        let y: CGFloat
    }

    /// Start offset and y (text-view coordinates) of the visual line
    /// containing the given character offset.
    private func linePosition(of offset: Int) -> LinePosition? {
        guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else {
            aoyoPosLog("linePosition(\(offset)): no position in document")
            return nil
        }
        let start = lineStart(of: position)
        let rect = textView.caretRect(for: start)
        guard rect.origin.y.isFinite, rect.height > 0 else {
            aoyoPosLog("linePosition(\(offset)): caret rect \(rect) unusable")
            return nil
        }
        return LinePosition(start: self.offset(of: start), y: rect.minY)
    }

    /// The first real draw after a restore can materialize true layout and
    /// silently shift fragment origins: verify after display and re-pin if
    /// the top line drifted off the anchor while the viewport sat still.
    private func scheduleAnchorVerify() {
        verifyGeneration += 1
        let generation = verifyGeneration
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, verifyGeneration == generation else { return }
                verifyAnchor()
            }
        }
    }

    private func verifyAnchor() {
        guard anchorOffset != nil, !suppressTracking, !restorePending, !isLiveScrolling,
              content != nil, let expected = expectedTopLine else { return }
        guard let current = captureAnchor(), current != expected else { return }
        aoyoPosLog("verify drift: top \(current) expected \(expected) — repin")
        scheduleAnchorRestore()
    }

    private func scrolled() {
        guard !suppressTracking, pendingRestore == nil, textView.bounds.width == lastLayoutWidth else { return }
        guard content != nil else {
            refreshProgress(persist: false)
            return
        }
        let y = scrollView.contentOffset.y
        let captured = captureAnchor()
        // Top text changed while the viewport barely moved: the ground
        // moved (TextKit materializing real layout), not the reader.
        if !isLiveScrolling, abs(y - lastScrollY) < 3,
           let captured, let expected = expectedTopLine, captured != expected {
            aoyoPosLog("shift under viewport: top \(captured) expected \(expected) at y \(Int(y))")
            scheduleAnchorRestore()
            return
        }
        let height = scrollView.contentSize.height
        if isLiveScrolling || abs(height - lastDocumentHeight) <= 0.5 {
            if let old = anchorOffset, let new = captured, abs(new - old) > 400 {
                aoyoPosLog("track jump \(old) -> \(new) at y \(Int(y))")
            } else if anchorOffset != nil, captured == nil {
                aoyoPosLog("track to top from \(anchorOffset ?? -1) at y \(Int(y))")
            }
            anchorOffset = captured
            expectedTopLine = captured
            lastScrollY = y
            lastDocumentHeight = height
            reportVisibleChapter()
            // The anchor just adopted real reader movement — safe to persist.
            refreshProgress(persist: true)
        } else {
            refreshProgress(persist: false)
        }
    }

    // MARK: - Tap

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: textView)
        if textView.bounds.contains(point), let position = textView.closestPosition(to: point) {
            let index = textView.offset(from: textView.beginningOfDocument, to: position)
            let text = textView.attributedText ?? NSAttributedString()
            if index < text.length, text.attribute(.link, at: index, effectiveRange: nil) != nil {
                return  // the text view opens the link
            }
        }
        onTap?()
    }
}

// MARK: - Scroll view delegate

extension ReaderTextViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrolled()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isLiveScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isLiveScrolling = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isLiveScrolling = false
    }

    /// The safe area (or the chrome inset) changed under the content: the
    /// viewport's top edge moved without the reader moving. Re-pin the
    /// anchor rather than adopting the shifted line.
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard anchorOffset != nil, pendingRestore == nil, !isLiveScrolling, hasLayout else { return }
        scheduleAnchorRestore()
    }
}

// MARK: - Links (tap-to-load images, external links)

extension ReaderTextViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self else { return }
            if let src = ContentBlockRenderer.imageSrc(from: url) {
                onImageTap?(src)
            } else {
                onLink?(url)
            }
        }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        if case .link(let url) = textItem.content, ContentBlockRenderer.imageSrc(from: url) != nil {
            return nil
        }
        return .init(menu: defaultMenu)
    }
}

extension ReaderTextViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
