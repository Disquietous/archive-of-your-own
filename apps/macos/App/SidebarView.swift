import SwiftUI

/// The navigation source list — SwiftUI hosted inside the AppKit split view.
/// Layout, colors, and grouping follow the Hush macOS handoff.
struct SidebarView: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Bindable var model: MacAppModel

    @State private var searchFocused = false
    @State private var privacyShown = false
    @FocusState private var searchFieldFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            ScrollView {
                VStack(spacing: 6) {
                    topGroup
                    group("Following") {
                        item(.subscriptions, "bell", "Subscriptions", badge: model.unreadCount)
                        item(.fandoms, "flame", "Fandoms", count: MacMockData.fandoms.count)
                        item(.authors, "person", "Authors", count: MacMockData.authors.count)
                    }
                    group("Saved") {
                        item(.bookmarks, "bookmark", "Bookmarks", count: model.bookmarks.count)
                        item(.downloads, "arrow.down.circle", "Offline", count: model.downloaded.count)
                        item(.stats, "chart.bar", "Reading Stats")
                    }
                    group("Collections") {
                        ForEach(MacMockData.collections) { c in
                            collectionRow(c)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            footer
        }
        .background(theme.sidebarFill)
        .overlay(alignment: .trailing) {
            theme.line.frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            // Leading space clears the system traffic lights.
            Spacer().frame(width: 62)
            (Text("AoYO").foregroundStyle(theme.ink) + Text(".").foregroundStyle(theme.accent))
                .font(Font(MacFont.serif(21, weight: .semibold)))
            Spacer()
        }
        .frame(height: 52)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink3)
            TextField("Search the archive", text: $model.query)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(13)))
                .foregroundStyle(theme.ink)
                .focused($searchFieldFocus)
                .onSubmit { model.goSection(.search) }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(searchFieldFocus ? theme.surface : theme.surface3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchFieldFocus ? theme.accent : .clear, lineWidth: 1)
        )
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private var topGroup: some View {
        VStack(spacing: 1) {
            item(.browse, "safari", "Browse")
            item(.reading, "book", "Currently Reading", count: model.currentlyReading.count)
            item(.later, "pin", "Want to Read", count: 8)
            item(.history, "clock", "History")
        }
        .padding(.top, 6)
    }

    private func group(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(label.uppercased())
                    .font(Font(MacFont.ui(10.5, weight: .bold)))
                    .kerning(0.6)
                    .foregroundStyle(theme.ink3)
                Spacer()
            }
            .padding(.init(top: 8, leading: 18, bottom: 4, trailing: 18))
            content()
        }
    }

    private func item(_ section: MacAppModel.Section, _ icon: String, _ label: String,
                      count: Int? = nil, badge: Int = 0) -> some View {
        let selected = model.section == section
        return Button {
            model.goSection(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                Text(label)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(selected ? theme.onAccent : theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(Font(MacFont.ui(10.5, weight: .bold)))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(selected ? Color.white.opacity(0.3) : theme.accent)
                        .clipShape(Capsule())
                } else if let count {
                    Text("\(count)")
                        .font(Font(MacFont.ui(11, weight: .bold)))
                        .foregroundStyle(selected ? theme.onAccent : theme.ink3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : theme.ink.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? theme.accent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
        .padding(.horizontal, 8)
    }

    private func collectionRow(_ c: MacCollection) -> some View {
        Button {
            model.goSection(.bookmarks)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Fandom.spineColorForHue(c.hue))
                    .frame(width: 9, height: 9)
                Text(c.name)
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(c.count)")
                    .font(Font(MacFont.ui(11, weight: .bold)))
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(theme.ink.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                privacyShown = true
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(torConnected ? theme.sage : theme.ink3)
                        .frame(width: 8, height: 8)
                        .shadow(color: (torConnected ? theme.sage : theme.ink3).opacity(0.4), radius: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(torConnected ? "Private · Tor" : "Not connected")
                            .font(Font(MacFont.ui(12.5, weight: .bold)))
                            .foregroundStyle(theme.ink)
                        Text(torConnected ? "Connected · 3-hop circuit" : appState.torStatus.displayText)
                            .font(Font(MacFont.ui(11)))
                            .foregroundStyle(theme.ink3)
                    }
                    Spacer()
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.sage)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.sage.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $privacyShown, arrowEdge: .top) {
                PrivacyPopoverView(theme: theme, appState: appState, model: model)
            }
        }
        .padding(.init(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) {
            theme.line.frame(height: 1)
        }
    }

    private var torConnected: Bool {
        appState.torStatus.isConnected
    }
}

private struct SidebarItemStyle: ButtonStyle {
    let hover: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? hover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}
