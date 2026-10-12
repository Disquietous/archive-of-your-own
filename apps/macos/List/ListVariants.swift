import AppKit
import SwiftUI

// SwiftUI content for the list pane's non-table variants, hosted from the
// AppKit ListPaneViewController. All data comes from the shared AppState.

// MARK: - Author follow bell (list-item standard)

/// The follow bell for an author name in SwiftUI-hosted list items: filled
/// + accent while followed (or subscribed on AO3); clicking opens the
/// Followed / Subscribed menu.
struct AuthorFollowBell: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel
    let author: String
    var size: CGFloat = 12

    var body: some View {
        let target = FollowModel.Target.author(author)
        FollowBell(theme: theme, follows: model.follows, target: target,
                   shaded: model.follows.isShaded(target), size: size)
            .frame(width: size + 8, height: size + 8)
    }
}

/// Collection rows' "by maintainer" line: names open the author profile
/// and each carries the follow bell.
struct CollectionMaintainersLine: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel
    let maintainers: [String]

    var body: some View {
        HStack(spacing: 3) {
            Text("by")
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink3)
            ForEach(Array(maintainers.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 1) {
                    Button {
                        model.openAuthorProfile(name)
                    } label: {
                        Text(index < maintainers.count - 1 ? "\(name)," : name)
                            .font(Font(MacFont.ui(12, weight: .semibold)))
                            .foregroundStyle(theme.ink2)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("View \(name)’s profile")
                    AuthorFollowBell(theme: theme, model: model, author: name, size: 11)
                }
            }
        }
    }
}

// MARK: - Tag chips (browse/search)

/// Simple leading-aligned wrapping layout (no horizontal scrolling).
struct FlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, in: proposal.width ?? 384).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, in: bounds.width).frames
        for (frame, subview) in zip(frames, subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: width, height: y + rowHeight))
    }
}

/// The work-row tag treatment for SwiftUI lists: wrapping pill chips in the
/// standard tag styling, collapsed to two rows, click the block to
/// expand/collapse — mirrors WorkRowCellView's tags clip so tag lists look
/// and behave the same everywhere.
struct CollapsibleTagPills: View {
    @Bindable var theme: AppTheme
    let tags: [String]
    /// Accent styling marks the bookmarker's own tags apart from work tags.
    var accented = false

    @State private var expanded = false
    @State private var pillHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private let spacing: CGFloat = 5

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so pills refresh live
        let collapsedHeight = pillHeight * 2 + spacing
        let clamps = pillHeight > 0 && fullHeight > collapsedHeight + 1
        FlowLayout(spacing: spacing) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                pill(tag)
            }
        }
        .background(heightReader { fullHeight = $0 })
        .frame(height: clamps && !expanded ? collapsedHeight : nil, alignment: .topLeading)
        .clipped()
        .background(alignment: .topLeading) {
            // Hidden sample pill: one row's height, so the collapsed clamp
            // tracks the app text-size setting instead of a hardcoded height.
            pill("Ag").opacity(0).background(heightReader { pillHeight = $0 })
        }
        .contentShape(Rectangle())
        // Clicking the tag block toggles the reveal (never the row action),
        // matching the work list item.
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
    }

    private func pill(_ tag: String) -> some View {
        Text(tag)
            .font(Font(MacFont.ui(10.5, weight: .semibold)))
            .foregroundStyle(accented ? theme.accent : theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accented ? theme.accentSoft : theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in update(height) }
        }
    }
}

// MARK: - Empty / loading / error states

struct EmptyStateMac: View {
    @Bindable var theme: AppTheme
    let icon: String, title: String, message: String

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.line2)
                .padding(.bottom, 16)
            Text(title)
                .font(Font(MacFont.serif(21, weight: .semibold)))
                .foregroundStyle(theme.ink2)
                .padding(.bottom, 8)
            Text(message)
                .font(Font(MacFont.ui(14)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct LoadingStateMac: View {
    @Bindable var theme: AppTheme
    let message: String
    var detail: String?
    /// Other requests in flight, shown as a summary beneath the primary
    /// message so the user sees everything underway, not just this one.
    var otherActivity: [String] = []
    var onCancel: (() -> Void)?

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(Font(MacFont.ui(13.5, weight: .semibold)))
                .foregroundStyle(theme.ink2)
            if let detail {
                Text(detail)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
            }
            if !otherActivity.isEmpty {
                VStack(spacing: 5) {
                    Text("ALSO IN PROGRESS")
                        .font(Font(MacFont.ui(9.5, weight: .bold)))
                        .kerning(0.6)
                        .foregroundStyle(theme.ink3)
                    ForEach(otherActivity, id: \.self) { op in
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(op)
                                .font(Font(MacFont.ui(11.5)))
                                .foregroundStyle(theme.ink3)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(10)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
