import UIKit
import SwiftUI

extension ReaderTextViewController {
    // MARK: - Text-anchored position

    /// Coalesces restore requests onto the next runloop turn: restoring from
    /// inside a layout pass reads half-updated frames, and a burst of
    /// animation frames needs one restore after each turn's layout settles.
    /// Tracking is suppressed immediately so the layout churn in between
    /// can't be mistaken for the reader moving.
    func scheduleAnchorRestore() {
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
    func remapAnchor(toNewText newText: String) {
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
    var viewportTopInText: CGFloat {
        let y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        return textView.convert(CGPoint(x: 0, y: y), from: scrollView).y
    }

    /// Start of the visual line holding `position`. The tokenizer returns
    /// nil for a position already at the line's leading boundary.
    func lineStart(of position: UITextPosition) -> UITextPosition {
        let tokenizer = textView.tokenizer
        if let range = tokenizer.rangeEnclosingPosition(position, with: .line, inDirection: .layout(.left)) {
            return range.start
        }
        if tokenizer.isPosition(position, atBoundary: .line, inDirection: .layout(.left)) {
            return position
        }
        return tokenizer.rangeEnclosingPosition(position, with: .line, inDirection: .layout(.right))?.start ?? position
    }

    func offset(of position: UITextPosition) -> Int {
        textView.offset(from: textView.beginningOfDocument, to: position)
    }

    /// Character offset of the first text line at the top of the viewport,
    /// or nil while the space above the text is showing. Goes through the
    /// text view's UITextInput geometry, which UIKit answers for any
    /// position; the layout manager's fragment frames are not populated
    /// away from the viewport on iOS.
    func captureAnchor() -> Int? {
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
    func restoreAnchor() {
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
        aoyoPosLog("""
            restore start: offset=\(offset) docLen=\(length) scroll bounds=\(Int(scrollView.bounds.height)) \
            content=\(Int(scrollView.contentSize.height)) inset top=\(Int(scrollView.adjustedContentInset.top)) \
            bottom=\(Int(scrollView.adjustedContentInset.bottom)) y=\(Int(scrollView.contentOffset.y)) textView \
            y=\(Int(textView.frame.minY)) h=\(Int(textView.bounds.height))
            """)

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
            aoyoPosLog("""
                pass \(passes): target start=\(target.start) y=\(Int(target.y)) viewportTop=\(Int(viewportTop)) \
                currentTop=\(currentTop ?? -1) currentY=\(Int(currentY)) delta=\(Int(delta)) \
                range=[\(Int(minOffset)),\(Int(maxOffset))] newY=\(Int(newY))
                """)
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

    struct LinePosition {
        let start: Int
        let y: CGFloat
    }

    /// Start offset and y (text-view coordinates) of the visual line
    /// containing the given character offset.
    func linePosition(of offset: Int) -> LinePosition? {
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
    func scheduleAnchorVerify() {
        verifyGeneration += 1
        let generation = verifyGeneration
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, verifyGeneration == generation else { return }
                verifyAnchor()
            }
        }
    }

    func verifyAnchor() {
        guard anchorOffset != nil, !suppressTracking, !restorePending, !isLiveScrolling,
              content != nil, let expected = expectedTopLine else { return }
        guard let current = captureAnchor(), current != expected else { return }
        aoyoPosLog("verify drift: top \(current) expected \(expected) — repin")
        scheduleAnchorRestore()
    }

    func scrolled() {
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

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
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
