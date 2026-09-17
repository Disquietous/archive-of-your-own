import SwiftUI
import UIKit

/// The SwiftUI reader's handle on its UIKit column, for the imperative
/// calls that aren't inputs: flushing or dropping the debounced persist,
/// and reading the current position.
final class ReaderTextHandle {
    weak var controller: ReaderTextViewController?
}

/// Hosts `ReaderTextViewController` in the SwiftUI reader. Everything the
/// column shows arrives as inputs each update; events come back as
/// closures.
struct ReaderTextView: UIViewControllerRepresentable {
    let theme: AppTheme
    let content: ReaderTextContent?
    let style: ReaderTextStyle
    let images: [String: UIImage]
    let imageStatus: [String: String]
    let highlight: ReaderBlockRef?
    let restore: ReaderRestoreRequest?
    let endView: AnyView
    let handle: ReaderTextHandle
    let onPersist: (ReaderPosition, Int) -> Void
    let onScroll: (CGFloat, Double) -> Void
    let onVisibleChapter: (Int) -> Void
    let onTap: () -> Void
    let onImageTap: (String) -> Void
    let onLink: (URL) -> Void

    func makeUIViewController(context: Context) -> ReaderTextViewController {
        let controller = ReaderTextViewController(theme: theme)
        handle.controller = controller
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: ReaderTextViewController, context: Context) {
        configure(controller)
    }

    static func dismantleUIViewController(_ controller: ReaderTextViewController, coordinator: ()) {
        controller.flushPendingPersist()
    }

    private func configure(_ controller: ReaderTextViewController) {
        controller.onPersist = onPersist
        controller.onScroll = onScroll
        controller.onVisibleChapter = onVisibleChapter
        controller.onTap = onTap
        controller.onImageTap = onImageTap
        controller.onLink = onLink
        controller.apply(content: content, style: style, images: images, imageStatus: imageStatus,
                         highlight: highlight, restore: restore, endView: endView)
    }
}
