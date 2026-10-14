import SwiftUI

/// The docked composer: one per scope. Reply targets ride on a chip; the
/// box grows 1→8 lines while the host is in auto-height mode, and fills
/// whatever height the user dragged it to otherwise. ⌘↩ posts. Esc only
/// leaves the box — it never discards text (drafts persist in Rust).
struct DiscussionComposerView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: DiscussionModel
    /// Host-owned: true until the user drags the thread/composer divider.
    let autoHeight: Bool
    /// Reports the composer's natural height (auto mode) to the host.
    let onPreferredHeight: (CGFloat) -> Void
    let onSignIn: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var textHeight: CGFloat = 18

    private static let lineHeight: CGFloat = 17
    private static let maxAutoLines: CGFloat = 8
    private static let counterThreshold = 9_000

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        Group {
            if model.isLoggedIn {
                composer
            } else {
                signedOut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: autoHeight ? nil : .infinity, alignment: .top)
        .background(theme.surface)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(ComposerHeightKey.self) { height in
            if autoHeight { onPreferredHeight(height) }
        }
        .onChange(of: model.focusRequest) { _, _ in editorFocused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let targetID = model.replyTargetID {
                replyChip(targetID)
            }
            editor
                .frame(height: autoHeight ? autoEditorHeight : nil)
                .frame(maxHeight: autoHeight ? nil : .infinity)
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
            // Measures the text at the editor's width so auto mode can grow.
            Text(model.draft.isEmpty ? " " : model.draft + " ")
                .font(Font(MacFont.ui(13)))
                .padding(.horizontal, 5)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.onAppear { textHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in textHeight = h }
                })
            TextEditor(text: $model.draft)
                .font(Font(MacFont.ui(13)))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .onExitCommand { editorFocused = false }
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
            Text("Sign in to AO3 to leave comments.")
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
