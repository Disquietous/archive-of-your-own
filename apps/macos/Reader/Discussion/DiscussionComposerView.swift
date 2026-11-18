import AppKit
import SwiftUI

/// The docked composer: one per scope. Reply targets ride on a chip; the
/// box grows 1→8 lines while the host is in auto-height mode, and fills
/// whatever height the user dragged it to otherwise. Whatever height it
/// ends up with — the host may give it less than it asks for — the box
/// stays inside it and scrolls its text. ⌘↩ posts. Esc only leaves the
/// box — it never discards text (drafts persist in Rust).
struct DiscussionComposerView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: DiscussionModel
    /// Host-owned: true until the user drags the thread/composer divider.
    let autoHeight: Bool
    /// Reports the composer's natural height (auto mode) to the host.
    let onPreferredHeight: (CGFloat) -> Void
    let onSignIn: () -> Void

    @State private var editorFocused = false
    /// The text's laid-out height at the box's width, from the text view.
    @State private var textHeight: CGFloat = 18
    /// The heights actually on screen: the whole composer and its box.
    @State private var composerActual: CGFloat = 0
    @State private var editorActual: CGFloat = 0

    private static let lineHeight: CGFloat = 17
    private static let maxAutoLines: CGFloat = 8
    private static let counterThreshold = 9_000

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        Group {
            switch model.postGate {
            case .enabled: composer
            case .disabled: signedOut
            case .hidden: EmptyView()  // the source takes no posts
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(ComposerHeightKey.self) { height in
            composerActual = height
            reportPreferredHeight()
        }
        .onChange(of: editorActual) { _, _ in reportPreferredHeight() }
        .onChange(of: textHeight) { _, _ in reportPreferredHeight() }
    }

    /// The height the composer would like: what is on screen, with the
    /// box at its natural height instead of the one it was squeezed to.
    private func reportPreferredHeight() {
        guard autoHeight, composerActual > 0 else { return }
        let chrome = model.postGate == .enabled ? composerActual - editorActual : composerActual
        onPreferredHeight(model.postGate == .enabled ? chrome + autoEditorHeight : chrome)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let targetID = model.replyTargetID {
                replyChip(targetID)
            }
            // Never taller than the space it is given: it shrinks to one
            // line before anything is pushed out of the pane.
            editor
                .frame(minHeight: Self.lineHeight + 16,
                       idealHeight: autoEditorHeight,
                       maxHeight: autoHeight ? autoEditorHeight : .infinity)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { editorActual = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in editorActual = h }
                })
            HStack(spacing: 10) {
                if model.draft.count >= Self.counterThreshold {
                    Text("\(model.draft.count.formatted()) / \(DiscussionModel.maxLength.formatted())")
                        .font(Font(MacFont.ui(11, weight: .medium)).monospacedDigit())
                        .foregroundStyle(model.draft.count > DiscussionModel.maxLength ? theme.danger : theme.ink3)
                }
                Spacer()
                Text("⌘↩")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                Button(action: model.post) {
                    Text(model.replyTargetID == nil ? "Post" : "Reply")
                        .font(Font(MacFont.ui(12.5, weight: .bold)))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.canPost ? theme.accent : theme.ink3))
                }
                .buttonStyle(.plain)
                .disabled(!model.canPost)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 14))
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(text: $model.draft, font: MacFont.ui(13), textColor: theme.nsInk,
                             focusRequest: model.focusRequest,
                             onHeight: { textHeight = $0 },
                             onFocus: { editorFocused = $0 })
            if model.draft.isEmpty {
                Text(model.composerPlaceholder)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(editorFocused ? theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private var autoEditorHeight: CGFloat {
        min(max(textHeight, Self.lineHeight), Self.lineHeight * Self.maxAutoLines) + 16
    }

    private func replyChip(_ targetID: UInt64) -> some View {
        let target = model.replyTarget
        return HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.accent)
            Text(target.map { "Replying to \($0.displayName)" } ?? "Replying to a comment")
                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                .foregroundStyle(theme.ink2)
            if let target {
                Text("— " + DiscussionText.snippet(target, limit: 60))
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: model.clearReplyTarget) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Make this a top-level comment")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentSoft.opacity(0.6)))
    }

    private var signedOut: some View {
        HStack(spacing: 10) {
            Text(model.signInPrompt)
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink3)
            Button("Sign In…", action: onSignIn)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The composer's text box: a plain-text NSTextView in its own scroll view,
/// so the text always scrolls inside whatever frame it is given. It
/// reports the text's laid-out height (for auto-height) and its focus.
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    /// Changes when the composer should take keyboard focus.
    let focusRequest: Int
    let onHeight: (CGFloat) -> Void
    let onFocus: (Bool) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusRequest: Int
        var lastHeight: CGFloat = 0
        weak var textView: ComposerNSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            measure()
        }

        /// The width changed (pane resize, scroller appearing): re-wrap.
        @objc func frameChanged(_ notification: Notification) { measure() }

        func measure() {
            guard let textView, let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + textView.textContainerInset.height * 2
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            // Never during a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in self?.parent.onHeight(height) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.string = text
        textView.onFocus = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.onFocus(focused) }
        }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: textView)
        context.coordinator.textView = textView
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            // The draft was replaced from outside (posted, scope changed).
            textView.string = text
            coordinator.measure()
        }
        if textView.font != font { textView.font = font; coordinator.measure() }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

/// Reports focus, and gives focus up on Esc without touching the text.
private final class ComposerNSTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }
}
