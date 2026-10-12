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

/// Find target for the reading column: the text view does the searching
/// and match highlighting; revealing a match is redirected to the
/// enclosing scroll view, since the text view itself never scrolls.
final class ReaderFindTarget: NSObject, UITextSearching {
    let textView: UITextView
    let reveal: (CGRect) -> Void

    init(textView: UITextView, reveal: @escaping (CGRect) -> Void) {
        self.textView = textView
        self.reveal = reveal
    }

    typealias DocumentIdentifier = UITextView.DocumentIdentifier

    var selectedTextRange: UITextRange? { textView.selectedTextRange }

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: DocumentIdentifier?) -> ComparisonResult {
        textView.compare(foundRange, toRange: toRange, document: document)
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions,
                           resultAggregator: UITextSearchAggregator<DocumentIdentifier>) {
        textView.performTextSearch(queryString: queryString, options: options, resultAggregator: resultAggregator)
    }

    func decorate(foundTextRange: UITextRange, document: DocumentIdentifier?, usingStyle style: UITextSearchFoundTextStyle) {
        textView.decorate(foundTextRange: foundTextRange, document: document, usingStyle: style)
    }

    func clearAllDecoratedFoundText() {
        textView.clearAllDecoratedFoundText()
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: DocumentIdentifier?) {
        reveal(textView.firstRect(for: range))
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
    let column = UIStackView()
    let textView = ReaderBodyTextView(usingTextLayoutManager: true)
    let endHost = UIHostingController(rootView: AnyView(EmptyView()))
    var columnCap: NSLayoutConstraint!
    var columnFill: NSLayoutConstraint!

    // MARK: Inputs

    private(set) var content: ReaderTextContent?
    var style: ReaderTextStyle?
    var loadedImages: [String: UIImage] = [:]
    var imageStatus: [String: String] = [:]
    var highlight: ReaderBlockRef?
    var highlightedRange: NSRange?
    var lastRestoreID: Int?

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
    struct SectionLayout {
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

    var layouts: [SectionLayout] = []

    // MARK: Anchor state (see the macOS ReaderViewController)

    /// Saved position to restore once its chapter's content renders.
    var pendingRestore: ReaderPosition?
    /// Character offset (document-wide) of the first visible line.
    var anchorOffset: Int?
    var suppressTracking = false
    var lastLayoutWidth: CGFloat = 0
    var lastDocumentHeight: CGFloat = 0
    var isLiveScrolling = false
    var expectedTopLine: Int?
    var lastScrollY: CGFloat = 0
    var verifyGeneration = 0
    var renderPending = false
    var restorePending = false
    var pendingPersist: DispatchWorkItem?
    var visibleChapter: Int?
    var lastReportedY: CGFloat = 0
    var findTarget: ReaderFindTarget?
    var findInteraction: UIFindInteraction?

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
        findTarget = ReaderFindTarget(textView: textView) { [weak self] rect in self?.reveal(rect) }
        let find = UIFindInteraction(sessionDelegate: self)
        textView.addInteraction(find)
        findInteraction = find

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
    var hasLayout: Bool {
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
    func geometryDidChange() {
        if pendingRestore != nil, hasLayout {
            consumePendingRestore()
        }
        let width = textView.bounds.width
        let height = scrollView.contentSize.height
        let widthChanged = width != lastLayoutWidth
        guard widthChanged || abs(height - lastDocumentHeight) > 0.5 else { return }
        aoyoPosLog("""
            geometry width \(Int(lastLayoutWidth))->\(Int(width)) height \(Int(lastDocumentHeight))->\(Int(height)) \
            anchor=\(anchorOffset ?? -1) pending=\(pendingRestore != nil)
            """)
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

    static func differsOnlyInChrome(_ a: ReaderTextStyle, _ b: ReaderTextStyle) -> Bool {
        a.themeID == b.themeID && a.fontName == b.fontName && a.fontSize == b.fontSize
            && a.readLeading == b.readLeading && a.hyphenation == b.hyphenation
            && a.justified == b.justified && a.measure == b.measure && a.readMargin == b.readMargin
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

extension ReaderTextViewController: UIFindInteractionDelegate {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        findTarget.map { UITextSearchingFindSession(searchableObject: $0) }
    }
}

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
