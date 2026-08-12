import AppKit

/// Bottom navigation bar: Return · Previous · chapter progress line ·
/// running % · Next. The return button shows only while a previous
/// chapter/position is stashed to go back to.
final class ReadFooterView: NSView {
    private let theme: AppTheme
    private let returnButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "‹ Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next ›", target: nil, action: nil)
    private let track = NSView()
    private let fill = NSView()
    private let pctLabel = NSTextField(labelWithString: "0%")
    private let topLine = NSView()
    private var fillWidth: NSLayoutConstraint!
    private var returnChapter: Int?

    var onReturn: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        for (button, selector) in [(returnButton, #selector(goBack)),
                                   (previousButton, #selector(prev)), (nextButton, #selector(next))] {
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

        returnButton.isHidden = true
        returnButton.toolTip = "Return to where you were before the last chapter change"

        let bar = NSStackView(views: [returnButton, previousButton, track, pctLabel, nextButton])
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

    @objc private func goBack() {
        onReturn?()
    }

    @objc private func prev() {
        onPrevious?()
    }

    @objc private func next() {
        onNext?()
    }

    func update(chapterPct: Double, bookPct: Double, canGoBack: Bool, canGoForward: Bool,
                returnChapter: Int?) {
        layoutSubtreeIfNeeded()
        fillWidth.constant = track.bounds.width * chapterPct
        pctLabel.stringValue = "\(Int((bookPct * 100).rounded()))%"
        previousButton.isEnabled = canGoBack
        previousButton.alphaValue = canGoBack ? 1 : 0.4
        nextButton.isEnabled = canGoForward
        nextButton.alphaValue = canGoForward ? 1 : 0.4
        self.returnChapter = returnChapter
        returnButton.isHidden = returnChapter == nil
        if returnChapter != nil { styleReturnButton() }
    }

    private func styleReturnButton() {
        guard let chapter = returnChapter else { return }
        returnButton.attributedTitle = NSAttributedString(
            string: "↩ Ch. \(chapter)",
            attributes: [.font: MacFont.ui(13, weight: .semibold), .foregroundColor: theme.nsAccent])
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
        returnButton.layer?.backgroundColor = theme.nsSurface.cgColor
        returnButton.layer?.borderColor = theme.nsLine.cgColor
        styleReturnButton()
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
