import SwiftUI

extension AuthorProfileView {
    // MARK: - Panes

    var paneSwitcher: some View {
        SegmentedControlView(
            selection: Binding(
                get: { isCurrent ? author.pane : .works },
                set: { author.showPane($0) }
            ),
            items: [
                (key: AuthorProfileModel.Pane.works, label: paneLabel("Works", profile?.worksCount)),
                (key: AuthorProfileModel.Pane.bookmarks, label: paneLabel("Bookmarks", profile?.bookmarksCount)),
                (key: AuthorProfileModel.Pane.collections, label: paneLabel("Collections", profile?.collectionsCount)),
            ]
        )
    }

    func paneLabel(_ name: String, _ count: UInt32?) -> String {
        guard let count, count > 0 else { return name }
        return "\(name) · \(count)"
    }

    @ViewBuilder
    var paneContent: some View {
        if isCurrent {
            switch author.pane {
            case .works: worksPane
            case .bookmarks: bookmarksPane
            case .collections: collectionsPane
            }
        }
    }

    // MARK: Works

    @ViewBuilder
    var worksPane: some View {
        if author.isLoadingWorks {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text(author.worksFetchStatus ?? "Fetching works from AO3…")
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                Spacer()
                Button("Cancel") {
                    author.cancelWorksRefresh()
                    if let opID = author.worksRefreshOp.opID { state.bridge.cancelOperation(opID) }
                }
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.accent)
                .buttonStyle(ButtonPressStyle())
            }
        } else if let error = author.worksError {
            NetworkErrorView(message: error, onRetry: { author.refreshWorks(resume: author.worksCrawlStop != nil) })
        } else if let stop = author.worksCrawlStop {
            CrawlStoppedRow(stop: stop) { author.refreshWorks(resume: true) }
        } else if author.worksCrawledAt == nil || author.worksCrawledAt?.isEmpty == true {
            fetchButton("Fetch complete works list from AO3") { author.refreshWorks() }
        }

        if works.isEmpty {
            if !author.isLoadingWorks && author.worksError == nil {
                EmptyStateView(systemImage: "doc.text",
                               title: "No stored works",
                               subtitle: "Refresh to fetch \(username)’s complete works list from AO3.")
                    .padding(.top, 24)
            }
        } else {
            markAllReadToggle
            LazyVStack(spacing: theme.rowGap) {
                ForEach(works) { work in
                    WorkCardView(
                        work: work,
                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                        isRemoved: state.goneWorkIDs.contains(work.id),
                        onTap: { nav.openWork(work.id) }
                    )
                    .contextMenu {
                        WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                    }
                }
            }
        }
    }

    // MARK: Bookmarks

    @ViewBuilder
    var bookmarksPane: some View {
        if bookmarks.isEmpty {
            if author.isLoadingBookmarks {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                    Text("Fetching bookmarks from AO3…")
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink3)
                    Spacer()
                }
            } else if let error = author.bookmarksError {
                NetworkErrorView(message: error, onRetry: { author.loadMoreBookmarks() })
            } else {
                EmptyStateView(systemImage: "bookmark",
                               title: "No bookmarks in your library",
                               subtitle: "Refresh to fetch \(username)’s public bookmarks from AO3.")
                    .padding(.top, 24)
            }
        } else {
            LazyVStack(spacing: theme.rowGap) {
                ForEach(bookmarks, id: \.targetKey) { hit in
                    BookmarkHitCard(hit: hit, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                }
            }
            listFooter(isLoading: author.isLoadingBookmarks, error: author.bookmarksError,
                       hasNext: author.bookmarksHasNext) { author.loadMoreBookmarks() }
        }
    }

    // MARK: Collections

    @ViewBuilder
    var collectionsPane: some View {
        if collections.isEmpty {
            if author.isLoadingCollections {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                    Text("Fetching collections from AO3…")
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink3)
                    Spacer()
                }
            } else if let error = author.collectionsError {
                NetworkErrorView(message: error, onRetry: { author.loadMoreCollections() })
            } else {
                EmptyStateView(systemImage: "square.grid.2x2",
                               title: "No collections in your library",
                               subtitle: "Refresh to fetch \(username)’s collections from AO3.")
                    .padding(.top, 24)
            }
        } else {
            LazyVStack(spacing: theme.rowGap) {
                ForEach(collections, id: \.name) { collection in
                    CollectionCardView(collection: collection) {
                        nav.openCollection(name: collection.name,
                                           title: collection.title.isEmpty ? collection.name : collection.title)
                    }
                }
            }
            listFooter(isLoading: author.isLoadingCollections, error: author.collectionsError,
                       hasNext: author.collectionsHasNext) { author.loadMoreCollections() }
        }
    }

    // MARK: Shared pieces

    @ViewBuilder
    func listFooter(isLoading: Bool, error: String?, hasNext: Bool,
                    loadMore: @escaping () -> Void) -> some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text("Loading more…")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if let error {
            NetworkErrorView(message: error, onRetry: loadMore)
        } else if hasNext {
            Button(action: loadMore) {
                Text("Load more")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .stroke(theme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(ButtonPressStyle())
        }
    }

    /// Toggle above the works list: mark every listed work as finished, or
    /// unmark them all once they are. Both directions confirm first.
    var markAllReadToggle: some View {
        let all = allWorksFinished
        return Button {
            pendingMarkAllRead = !all
        } label: {
            HStack(spacing: 8) {
                Image(systemName: all ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(all ? "All marked as read" : "Mark all as read")
                    .font(Typography.smallButtonLabel())
                Spacer()
            }
            .foregroundStyle(all ? theme.sage : theme.ink2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ButtonPressStyle())
    }

    func fetchButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(Typography.smallButtonLabel())
                Spacer()
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Radius.smallButton)
                    .stroke(theme.accent, lineWidth: 1)
            )
        }
        .buttonStyle(ButtonPressStyle())
    }

    func exportEpub(_ work: Work) {
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
