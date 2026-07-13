import AppKit

/// The reading surface: a TextKit 2 NSTextView. This is deliberately AppKit —
/// continuous selection, ⌘F find, dictionary lookup, and VoiceOver continuity
/// come from NSTextView for free.
final class ReaderViewController: NSViewController {
    private let theme: AppTheme
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    /// Maximum width of the text column, keeps long lines readable on wide windows.
    private let maxColumnWidth: CGFloat = 680

    init(theme: AppTheme) {
        self.theme = theme
        self.textView = NSTextView(usingTextLayoutManager: true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 48, height: 40)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        applyThemeBackground()
        showPlaceholder()
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Center the readable column: grow horizontal insets past maxColumnWidth.
        let width = scrollView.contentSize.width
        let inset = max(48, (width - maxColumnWidth) / 2)
        textView.textContainerInset = NSSize(width: inset, height: 40)
    }

    func show(work: Work, chapterIndex: Int) {
        let chapter = MockData.buildChapter(for: work, index: chapterIndex)
        let blocks = ParsedContentBlock.fromParagraphs(chapter.paragraphs)
        let renderer = ContentBlockRenderer(theme: theme)
        let document = renderer.renderChapter(
            workTitle: work.title,
            author: work.author,
            chapterTitle: chapter.title,
            blocks: blocks
        )
        textView.textStorage?.setAttributedString(document)
        textView.scroll(.zero)
        view.window?.subtitle = "\(work.title) — \(chapter.title)"
    }

    private func showPlaceholder() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let placeholder = NSAttributedString(
            string: "\n\n\nSelect a work to begin reading.",
            attributes: [
                .font: ContentBlockRenderer.serifFont(size: 16),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        textView.textStorage?.setAttributedString(placeholder)
    }

    private func applyThemeBackground() {
        scrollView.backgroundColor = NSColor(theme.surface)
    }
}
