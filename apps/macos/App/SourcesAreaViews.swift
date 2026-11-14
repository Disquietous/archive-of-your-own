import SwiftUI

/// The Sources area's tab strip: one tab per source, across the top of
/// the two content panes.
struct SourceAreaTabBar: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    static let height: CGFloat = 44

    var body: some View {
        let _ = theme.uiFontScale
        HStack(spacing: 2) {
            ForEach(model.sourceTabs, id: \.id) { source in
                tab(source)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            theme.line.frame(height: 1)
        }
    }

    private func tab(_ source: SourceCapabilities) -> some View {
        let selected = model.sourceTab == source.id
        let ink = selected ? theme.ink : theme.ink3
        return Button {
            model.selectSourceTab(source.id)
        } label: {
            HStack(spacing: 6) {
                if let badge = SourceBadge.tinted(for: source.id, color: NSColor(ink), height: 13) {
                    Image(nsImage: badge)
                }
                Text(source.name)
                    .font(Font(MacFont.ui(13, weight: .semibold)))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(selected ? theme.bg : .clear)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
            .overlay(alignment: .bottom) {
                (selected ? theme.accent : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.host)
    }
}

/// The selected source's own sidebar: the options that source offers.
/// Choosing one shows its content in the panes beside it.
struct SourceSidebarView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    static let width: CGFloat = 196

    var body: some View {
        let _ = theme.uiFontScale
        ScrollView {
            VStack(spacing: 1) {
                ForEach(model.sourceOptions(for: model.sourceTab)) { option in
                    SidebarRow(theme: theme, icon: option.icon, label: option.label,
                               selected: model.section == option.section,
                               count: count(for: option.section),
                               badge: badge(for: option.section)) {
                        model.goSection(option.section)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.sidebarFill)
        .overlay(alignment: .trailing) {
            theme.line.frame(width: 1)
        }
    }

    private func count(for section: MacAppModel.Section) -> Int? {
        section == .fandoms ? model.follows.followedFandoms.count : nil
    }

    private func badge(for section: MacAppModel.Section) -> Int {
        section == .inbox ? appState.inboxUnreadCount : 0
    }
}

/// The content panel of a source that has no options yet.
struct SourceEmptyPanel: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        let name = model.sourceTabs.first { $0.id == model.sourceTab }?.name ?? "This source"
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.ink3)
            Text(name)
                .font(Font(MacFont.serif(18, weight: .semibold)))
                .foregroundStyle(theme.ink)
            Text("Nothing here yet.")
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}
