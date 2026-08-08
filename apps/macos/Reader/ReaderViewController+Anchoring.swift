import AppKit

// MARK: - Text-anchored position

extension ReaderViewController {
    /// Any viewport width change (window or pane resize, immersive collapse
    /// animation frames) reflows the column; snap the scroll offset back to
    /// the anchored text rather than letting the raw point offset drift.
    @objc func liveScrollBegan() {
        isLiveScrolling = true
    }

    @objc func liveScrollEnded() {
        isLiveScrolling = false
    }

    /// Coalesces width-driven re-renders onto the next runloop turn, same
    /// rationale as scheduleAnchorRestore.
    func scheduleRerender() {
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
    func scheduleAnchorRestore() {
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
    func remapAnchor(toNewText newText: String) {
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

    @objc func scrolled() {
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
}
