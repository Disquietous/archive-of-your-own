import UIKit
import SwiftUI

extension ReaderTextViewController {
    // MARK: - Render

    func scheduleRerender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renderPending = false
            render()
        }
    }

    func render() {
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
    static func dropCapAdjust(for body: String) -> Int {
        guard body.utf16.count > 1, let first = body.first else { return 0 }
        return first.isLetter || first == "\"" || first == "“" ? 1 : 0
    }

    /// Land where the reader left off once the chapter is in the document:
    /// hand the saved offset to the same anchor machinery that survives
    /// reflows.
    func consumePendingRestore() {
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

    static func globalOffset(for local: Int, in layout: SectionLayout) -> Int {
        guard local > 0 else { return layout.headerStart }
        return min(layout.bodyStart + layout.dropCapAdjust + local, max(layout.bodyStart, layout.bodyEnd - 1))
    }

    func layout(containing global: Int) -> SectionLayout? {
        layouts.last { $0.headerStart <= global }
    }

    /// The chapter-local position for a document offset, as persisted.
    func position(forGlobal global: Int?) -> (ReaderPosition, Int)? {
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

    func applyHighlight() {
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

    /// Show the system find bar over the text shown (the chapter, or the
    /// whole work in entire-work mode).
    func presentFind() {
        textView.becomeFirstResponder()
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Scroll a find match (text-view coordinates) into the middle third
    /// of the visible area.
    func reveal(_ rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite else { return }
        let inScroll = textView.convert(rect, to: scrollView)
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        guard !visible.insetBy(dx: 0, dy: visible.height / 3).contains(inScroll) else { return }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let targetY = inScroll.midY - scrollView.adjustedContentInset.top - visible.height / 2
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(targetY, minY), maxY)), animated: true)
    }

    func scrollToTop() {
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
    }

    // MARK: - Persist

    func refreshProgress(persist: Bool) {
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
    func schedulePersist() {
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingPersist = nil
            persistProgressNow()
        }
        pendingPersist = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func persistProgressNow() {
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

    func reportVisibleChapter() {
        guard let resolved = position(forGlobal: anchorOffset) else { return }
        if visibleChapter != resolved.0.chapter {
            let chapter = resolved.0.chapter
            visibleChapter = chapter
            DispatchQueue.main.async { [weak self] in self?.onVisibleChapter?(chapter) }
        }
    }
}
