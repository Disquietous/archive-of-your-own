import AppKit
import SwiftUI

// MARK: - Render

extension ReaderViewController {
    var currentChapterContent: (title: String, blocks: [ParsedContentBlock])? {
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

    var postedChapterCount: Int {
        // Metadata can know about chapters our cached copy predates (the
        // work updated since the last fetch) — trust whichever is larger,
        // so "Next chapter" appears and navigation triggers the fetch.
        max(chapters?.count ?? 0, max(work?.chapterCount ?? 0, 1))
    }

    func renderChapter() {
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
}
