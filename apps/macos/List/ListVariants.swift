import SwiftUI

// SwiftUI content for the list pane's non-table variants, hosted from the
// AppKit ListPaneViewController. All data comes from the shared AppState.

// MARK: - Tag chips (browse/search)

struct ChipsBar: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(model.availableTags, id: \.self) { tag in
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

// MARK: - Empty / loading / error states

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

struct LoadingStateMac: View {
    @Bindable var theme: AppTheme
    let message: String
    var detail: String? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
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

// MARK: - Subscriptions

struct SubscriptionsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var view = "new"

    var body: some View {
        VStack(spacing: 0) {
            segmented
            if appState.ao3Username == nil {
                EmptyStateMac(theme: theme, icon: "person.crop.circle.badge.questionmark",
                              title: "Sign in to follow",
                              message: "Add your AO3 account in Settings to see subscription updates here.")
            } else {
                ScrollView {
                    if view == "new" {
                        notificationsFeed
                    } else {
                        followingGroups
                    }
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

    @ViewBuilder
    private var notificationsFeed: some View {
        if appState.notifications.isEmpty {
            EmptyStateMac(theme: theme, icon: "bell",
                          title: "Nothing new",
                          message: appState.isCheckingSubscriptions
                            ? "Checking your subscriptions…"
                            : "Updates from works and authors you follow appear here.")
                .frame(minHeight: 300)
        } else {
            VStack(spacing: 0) {
                ForEach(appState.notifications, id: \.id) { notification in
                    NotificationRowView(theme: theme, appState: appState, model: model,
                                        notification: notification)
                }
            }
        }
    }

    @ViewBuilder
    private var followingGroups: some View {
        let groups: [(label: String, icon: String, type: String)] = [
            ("Works", "book.closed", "work"),
            ("Series", "square.stack", "series"),
            ("Authors", "person", "author"),
        ]
        if appState.subscriptions.isEmpty {
            EmptyStateMac(theme: theme, icon: "bell",
                          title: appState.isLoadingSubscriptions ? "Loading…" : "No subscriptions",
                          message: appState.subscriptionError ?? "Works, series, and authors you subscribe to on AO3 appear here.")
                .frame(minHeight: 300)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.type) { group in
                    let items = appState.subscriptions.filter { $0.subType.lowercased().contains(group.type) }
                    if !items.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: group.icon).font(.system(size: 10, weight: .semibold))
                            Text(group.label.uppercased()).kerning(0.6)
                            Spacer()
                            Text("\(items.count)").opacity(0.7)
                        }
                        .font(Font(MacFont.ui(10.5, weight: .bold)))
                        .foregroundStyle(theme.ink3)
                        .padding(.init(top: 12, leading: 16, bottom: 4, trailing: 16))

                        ForEach(items, id: \.id) { sub in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sub.name)
                                        .font(Font(MacFont.ui(14, weight: .semibold)))
                                        .foregroundStyle(theme.ink)
                                    Text(group.label.dropLast(group.label.hasSuffix("s") ? 1 : 0))
                                        .font(Font(MacFont.ui(12)))
                                        .foregroundStyle(theme.ink3)
                                }
                                Spacer()
                            }
                            .padding(.init(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if group.type == "work" { model.selectWork(sub.id) }
                                if group.type == "author" {
                                    model.query = sub.name
                                    model.submitSearch()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NotificationRowView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel
    let notification: UNotification

    private var icon: String {
        switch notification.notifType.lowercased() {
        case let t where t.contains("chapter") || t.contains("work"): "book.closed"
        case let t where t.contains("inbox") || t.contains("comment"): "envelope"
        case let t where t.contains("author") || t.contains("user"): "person"
        default: "bell"
        }
    }

    var body: some View {
        Button {
            appState.markNotificationRead(notification.id)
            if notification.workId > 0 {
                model.selectWork(String(notification.workId))
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.accentSoft)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(notification.notifType.uppercased())
                            .font(Font(MacFont.ui(10, weight: .bold)))
                            .kerning(0.6)
                            .foregroundStyle(theme.ink3)
                        if !notification.read {
                            Circle().fill(theme.accent).frame(width: 7, height: 7)
                        }
                        Spacer()
                        Text(Fmt.relativeTime(notification.createdAt))
                            .font(Font(MacFont.ui(11, weight: .medium)))
                            .foregroundStyle(theme.ink3)
                    }
                    Text(notification.title)
                        .font(Font(MacFont.serif(15, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                    if !notification.author.isEmpty {
                        Text("by \(notification.author)")
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink3)
                    }
                    if !notification.message.isEmpty {
                        Text(notification.message)
                            .font(Font(MacFont.ui(12.5, weight: .medium)))
                            .foregroundStyle(theme.ink2)
                            .multilineTextAlignment(.leading)
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

// MARK: - Followed fandoms

struct FollowedFandomsView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    @State private var newFandom = ""

    private var suggestions: [MacAppModel.FandomEntry] {
        model.libraryFandoms.filter { !model.followedFandoms.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                followField

                if model.followedFandoms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "flame")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(theme.line2)
                        Text("Follow your fandoms")
                            .font(Font(MacFont.serif(19, weight: .semibold)))
                            .foregroundStyle(theme.ink2)
                        Text("Followed fandoms live here — one click opens that fandom's works on the archive.")
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                        ForEach(model.followedFandoms, id: \.self) { name in
                            fandomCard(name)
                        }
                    }
                }

                if !suggestions.isEmpty {
                    Text("FROM YOUR LIBRARY")
                        .font(Font(MacFont.ui(10.5, weight: .bold)))
                        .kerning(0.6)
                        .foregroundStyle(theme.ink3)
                        .padding(.top, 4)
                    ForEach(suggestions.prefix(8)) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }
            .padding(16)
        }
    }

    private var followField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Follow a fandom (exact AO3 tag)", text: $newFandom)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .onSubmit {
                    model.followFandom(newFandom)
                    newFandom = ""
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    private func fandomCard(_ name: String) -> some View {
        Button {
            model.searchTag(name)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Fandom.spineColor(for: name))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: "flame")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.onAccent)
                        }
                    Spacer()
                    Button {
                        model.unfollowFandom(name)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unfollow")
                }
                .padding(.bottom, 10)
                Text(name)
                    .font(Font(MacFont.serif(15, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 2)
                Text("View works")
                    .font(Font(MacFont.ui(11.5, weight: .medium)))
                    .foregroundStyle(theme.accent)
            }
            .padding(.init(top: 15, leading: 14, bottom: 15, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func suggestionRow(_ suggestion: MacAppModel.FandomEntry) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Fandom.spineColor(for: suggestion.name))
                .frame(width: 9, height: 9)
            Text(suggestion.name)
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Spacer()
            Text("\(suggestion.count) in library")
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
            Button {
                model.followFandom(suggestion.name)
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .help("Follow")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Authors (followed locally + AO3 subscriptions)

struct AuthorsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var newAuthor = ""

    /// Local follows first, then AO3 subscription authors not already followed.
    private var authors: [(name: String, source: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for name in model.followedAuthorNames where seen.insert(name).inserted {
            result.append((name, "Followed"))
        }
        for sub in model.followedAuthors where seen.insert(sub.name).inserted {
            result.append((sub.name, "Subscribed on AO3"))
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                followField
                    .padding(.init(top: 12, leading: 16, bottom: 2, trailing: 16))

                if authors.isEmpty {
                    EmptyStateMac(theme: theme, icon: "person",
                                  title: "No authors yet",
                                  message: "Follow an author by username, or sign in to see your AO3 author subscriptions.")
                        .frame(minHeight: 260)
                } else {
                    VStack(spacing: 0) {
                        ForEach(authors, id: \.name) { author in
                            authorRow(author.name, source: author.source)
                        }
                    }
                }
            }
        }
    }

    private var followField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Follow an author (AO3 username)", text: $newAuthor)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .onSubmit {
                    model.followAuthor(newAuthor)
                    newAuthor = ""
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    private func authorRow(_ name: String, source: String) -> some View {
        Button {
            model.openAuthor(name)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Fandom.spineColorForHue(abs(name.hashValue % 360)))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(Font(MacFont.serif(18, weight: .semibold)))
                            .foregroundStyle(theme.onAccent)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Font(MacFont.ui(14.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(source)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                if model.followedAuthorNames.contains(name) {
                    Button {
                        model.unfollowAuthor(name)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unfollow")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}

// MARK: - Stats (computed on device)

struct StatsView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        let stats = model.localStats
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                    statCard(Fmt.k(stats.wordsRead), "Words read")
                    statCard("\(stats.worksFinished)", "Works finished")
                    statCard("\(stats.inLibrary)", "In library")
                    statCard("\(stats.downloaded)", "Downloaded")
                }
                Text("Counted on this device from your reading progress. Nothing leaves your library.")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}
