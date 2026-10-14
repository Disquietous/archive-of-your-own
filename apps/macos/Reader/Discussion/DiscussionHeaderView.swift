import SwiftUI

/// The panel's top bar: title + count, scope (this chapter / whole work),
/// sort, author-replies filter, find, expand-to-fill and close. The find
/// field drops in under it while finding.
struct DiscussionHeaderView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: DiscussionModel
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onClose: () -> Void

    @FocusState private var findFocused: Bool

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Discussion")
                        .font(Font(MacFont.serif(16, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(countText)
                        .font(Font(MacFont.ui(11)))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                toggle("arrow.up.arrow.down", on: model.sortNewestFirst,
                       help: model.sortNewestFirst ? "Newest first — show oldest first" : "Oldest first — show newest first") {
                    model.sortNewestFirst.toggle()
                }
                toggle("person.crop.circle.badge.checkmark", on: model.authorRepliesOnly,
                       help: "Only threads with replies from the author") {
                    model.authorRepliesOnly.toggle()
                }
                toggle("magnifyingglass", on: model.isFinding, help: "Find in comments (⌥⌘F)") {
                    model.isFinding.toggle()
                    findFocused = model.isFinding
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                toggle(isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       on: false, help: isExpanded ? "Show the reader (⇧⌥⌘C)" : "Fill the reader (⇧⌥⌘C)",
                       action: onToggleExpand)
                toggle("xmark", on: false, help: "Close discussion (⌥⌘C)", action: onClose)
            }
            Picker("", selection: $model.scope) {
                Text(model.chapterID == nil ? "This chapter" : "Chapter \(model.chapterIndex + 1)")
                    .tag(DiscussionModel.Scope.chapter)
                Text("Whole work").tag(DiscussionModel.Scope.work)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.hasReaderChapter || model.chapterID == nil)
            .help(!model.hasReaderChapter ? "Open the reader to see a chapter’s comments"
                  : model.chapterID == nil ? "This work’s comments aren’t split by chapter" : "")
            if model.isFinding {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.ink3)
                    TextField("Find in loaded comments", text: $model.findText)
                        .textFieldStyle(.plain)
                        .font(Font(MacFont.ui(12.5)))
                        .focused($findFocused)
                        .onExitCommand {
                            model.findText = ""
                            model.isFinding = false
                        }
                    if !model.findText.isEmpty {
                        Button {
                            model.findText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.ink3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.surface2))
            }
        }
        .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity)
        .background(theme.bg)
    }

    private var countText: String {
        let loaded = model.loadedCount
        if let total = model.workTotal {
            return "\(total) comment\(total == 1 ? "" : "s") on this work"
        }
        if model.isLoading && loaded == 0 { return model.scopeTitle }
        let more = model.hasMorePages ? "+" : ""
        return "\(loaded)\(more) comment\(loaded == 1 && more.isEmpty ? "" : "s") · \(model.scopeTitle)"
    }

    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? theme.accent : theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? theme.accentSoft : theme.surface2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
