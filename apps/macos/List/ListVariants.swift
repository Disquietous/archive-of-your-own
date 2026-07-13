import SwiftUI

// SwiftUI content for the list pane's non-table variants, hosted from the
// AppKit ListPaneViewController.

// MARK: - Tag chips (browse/search)

struct ChipsBar: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(MacMockData.popularTags, id: \.self) { tag in
                chip(tag, on: model.activeTags.contains(tag))
            }
        }
        .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func chip(_ tag: String, on: Bool) -> some View {
        Button {
            if on { model.activeTags.remove(tag) } else { model.activeTags.insert(tag) }
        } label: {
            Text(tag)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(on ? theme.onAccent : theme.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(on ? theme.accent : theme.surface2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

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

// MARK: - Empty state

struct EmptyStateMac: View {
    @Bindable var theme: AppTheme
    let icon: String, title: String, message: String

    var body: some View {
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

// MARK: - Subscriptions

struct SubscriptionsList: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    @State private var view = "new"
    @State private var notify: [String: Bool] = {
        var m: [String: Bool] = [:]
        for group in MacMockData.subscriptions {
            for s in group.items { m[s.id] = s.notify }
        }
        return m
    }()

    var body: some View {
        VStack(spacing: 0) {
            segmented
            ScrollView {
                if view == "new" {
                    VStack(spacing: 0) {
                        ForEach(MacMockData.subUpdates) { u in
                            UpdateRowView(theme: theme, model: model, update: u)
                        }
                    }
                } else {
                    followingGroups
                }
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 3) {
            segButton("new", "What's new")
            segButton("following", "Following")
        }
        .padding(3)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.init(top: 10, leading: 16, bottom: 10, trailing: 16))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func segButton(_ key: String, _ label: String) -> some View {
        Button { view = key } label: {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(view == key ? theme.ink : theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(view == key ? theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var followingGroups: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MacMockData.subscriptions, id: \.label) { group in
                HStack(spacing: 7) {
                    Image(systemName: group.icon).font(.system(size: 10, weight: .semibold))
                    Text(group.label.uppercased()).kerning(0.6)
                    Spacer()
                    Text("\(group.items.count)").opacity(0.7)
                }
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .foregroundStyle(theme.ink3)
                .padding(.init(top: 12, leading: 16, bottom: 4, trailing: 16))

                ForEach(group.items) { s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name)
                                .font(Font(MacFont.ui(14, weight: .semibold)))
                                .foregroundStyle(theme.ink)
                            Text(s.by.map { "by \($0) · \(s.status)" } ?? s.status)
                                .font(Font(MacFont.ui(12)))
                                .foregroundStyle(theme.ink3)
                        }
                        Spacer()
                        NotifyButton(theme: theme, on: notify[s.id] ?? false) {
                            notify[s.id] = !(notify[s.id] ?? false)
                        }
                    }
                    .padding(.init(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.works.contains(where: { $0.id == s.id }) { model.selectWork(s.id) }
                    }
                }
            }
        }
    }
}

struct UpdateRowView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel
    let update: MacSubUpdate

    private var icon: String {
        switch update.type {
        case .work: "book.closed"
        case .author: "person"
        case .collection: "folder"
        case .series: "square.stack"
        }
    }

    var body: some View {
        Button {
            if let id = update.workID { model.selectWork(id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Fandom.spineColorForHue(update.hue, opacity: 0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Fandom.spineColorForHue(update.hue))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(update.type.rawValue.uppercased())
                            .font(Font(MacFont.ui(10, weight: .bold)))
                            .kerning(0.6)
                            .foregroundStyle(theme.ink3)
                        if update.unread && !model.notifsRead {
                            Circle().fill(theme.accent).frame(width: 7, height: 7)
                        }
                        Spacer()
                        Text(update.time)
                            .font(Font(MacFont.ui(11, weight: .medium)))
                            .foregroundStyle(theme.ink3)
                    }
                    Text(update.target)
                        .font(Font(MacFont.serif(15, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(update.action)
                        .font(Font(MacFont.ui(12.5, weight: .medium)))
                        .foregroundStyle(theme.ink2)
                    if let detail = update.detail {
                        Text(detail)
                            .font(Font(MacFont.ui(12)).italic())
                            .foregroundStyle(theme.ink3)
                    }
                }
            }
            .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}

struct NotifyButton: View {
    @Bindable var theme: AppTheme
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "bell" : "bell.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? theme.accent : theme.ink3)
                .frame(width: 34, height: 34)
                .background(on ? theme.accentSoft : theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? theme.accent.opacity(0.35) : theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fandoms

struct FandomsGrid: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                ForEach(MacMockData.fandoms) { fandom in
                    Button {
                        model.openFandom(fandom)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Fandom.spineColorForHue(fandom.hue))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: "flame")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(theme.onAccent)
                                }
                                .padding(.bottom, 10)
                            Text(fandom.short)
                                .font(Font(MacFont.serif(15, weight: .semibold)))
                                .foregroundStyle(theme.ink)
                                .multilineTextAlignment(.leading)
                                .padding(.bottom, 2)
                            Text("\(MacMockData.fmt(fandom.works)) works")
                                .font(Font(MacFont.ui(11.5, weight: .medium)))
                                .foregroundStyle(theme.ink3)
                        }
                        .padding(.init(top: 15, leading: 14, bottom: 15, trailing: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
                        .overlay(alignment: .topTrailing) {
                            if fandom.unread > 0 {
                                Text("\(fandom.unread) new")
                                    .font(Font(MacFont.ui(10, weight: .bold)))
                                    .foregroundStyle(theme.onAccent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(theme.accent)
                                    .clipShape(Capsule())
                                    .padding(13)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Authors

struct AuthorsList: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    @State private var notify = Dictionary(uniqueKeysWithValues: MacMockData.authors.map { ($0.id, $0.notify) })

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(MacMockData.authors) { author in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Fandom.spineColorForHue(author.hue))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Text(String(author.handle.prefix(1)).uppercased())
                                    .font(Font(MacFont.serif(18, weight: .semibold)))
                                    .foregroundStyle(theme.onAccent)
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(author.handle)
                                .font(Font(MacFont.ui(14.5, weight: .semibold)))
                                .foregroundStyle(theme.ink)
                            Text("\(author.works) works · \(author.subs) subscribers")
                                .font(Font(MacFont.ui(12)))
                                .foregroundStyle(theme.ink3)
                            Text(author.fandoms)
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(theme.accent)
                        }
                        Spacer()
                        NotifyButton(theme: theme, on: notify[author.id] ?? false) {
                            notify[author.id] = !(notify[author.id] ?? false)
                        }
                    }
                    .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                    .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
                }
            }
        }
    }
}

// MARK: - Stats

struct StatsView: View {
    @Bindable var theme: AppTheme

    private let days = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                    statCard(String(format: "%.2fM", Double(MacMockData.stats.wordsThisYear) / 1_000_000), "Words this year")
                    statCard("\(MacMockData.stats.worksFinished)", "Works finished")
                    statCard("\(MacMockData.stats.streakDays)", "Day streak")
                    statCard("\(MacMockData.stats.hoursThisMonth)h", "Read this month")
                }
                chart
            }
            .padding(20)
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Font(MacFont.serif(28, weight: .semibold)))
                .foregroundStyle(theme.accent)
            Text(label)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THIS WEEK · MINUTES PER DAY")
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.7)
                .foregroundStyle(theme.ink3)
            HStack(alignment: .bottom, spacing: 8) {
                let maxValue = MacMockData.stats.weekly.max() ?? 1
                ForEach(Array(MacMockData.stats.weekly.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 7) {
                        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 3,
                                               bottomTrailingRadius: 3, topTrailingRadius: 6)
                            .fill(LinearGradient(colors: [theme.accent, theme.accent2],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(maxWidth: 30)
                            .frame(height: max(6, 120 * CGFloat(value) / CGFloat(maxValue)))
                        Text(days[index])
                            .font(Font(MacFont.ui(11, weight: .semibold)))
                            .foregroundStyle(theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }
}
