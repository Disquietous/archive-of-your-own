import SwiftUI

/// One generic list of works driven by `LibraryListModel`: the section's
/// membership (`rawWorks`) ordered and filtered by the Rust engine under the
/// section's persisted sort/filter prefs and session list filter. Chrome
/// carries the Sort & Filter menu, the filter sheet button, and the host's
/// own menu items; rows get the shared context menu and a leading-edge
/// swipe action where the section has one.
struct WorkListScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists
    @Environment(OperationsModel.self) private var ops

    struct SwipeAction {
        let label: String
        let systemImage: String
        let action: (Work) -> Void
    }

    struct EmptyState {
        let systemImage: String
        let title: String
        let subtitle: String
    }

    let section: LibrarySection
    let title: String
    var subtitle: String? = nil
    /// The section's membership; evaluated on every render pass (cheap —
    /// the engine's ordering is memoized per section).
    let rawWorks: () -> [Work]
    let empty: EmptyState
    /// Section prefs (sort, completion, rating) apply; false runs only the
    /// session list filter in natural order (drill-ins).
    var usesSectionPrefs = true
    /// What's New marks unseen rows.
    var marksNew = false
    var swipe: SwipeAction? = nil
    /// Row tap; defaults to opening the work detail.
    var onOpen: ((Work) -> Void)? = nil
    /// Content above the rows (a crawl-age line, a hand-off button).
    var header: AnyView? = nil
    /// The host's ellipsis-menu items.
    var menuItems: AnyView? = nil

    @State private var showFilterSheet = false
    @State private var newListFor: Work?
    @State private var newListName = ""
    @State private var exportedEpub: EpubExporter.Exported?
    @State private var exportError: String?

    private var works: [Work] {
        let raw = rawWorks()
        return usesSectionPrefs ? lists.works(for: section, raw: raw)
                                : lists.listFiltered(raw, section: section)
    }

    private var filterActive: Bool {
        lists.workListFilter(for: section).isActive
    }

    var body: some View {
        let works = works
        ZStack(alignment: .top) {
            List {
                if let header {
                    header
                        .listRowInsets(EdgeInsets(top: 4, leading: theme.pad, bottom: 8, trailing: theme.pad))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                let inFlight = ops.inFlightOperations
                if !inFlight.isEmpty {
                    statusLine(inFlight)
                        .listRowInsets(EdgeInsets(top: 0, leading: theme.pad, bottom: 8, trailing: theme.pad))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if works.isEmpty {
                    emptyView
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(works) { work in
                        row(work)
                            .listRowInsets(EdgeInsets(top: theme.rowGap / 2, leading: theme.pad,
                                                      bottom: theme.rowGap / 2, trailing: theme.pad))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                Color.clear
                    .frame(height: 24)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: title, subtitle: subtitle ?? countLine(works.count)) {
                SortFilterMenu(section: section)
                ChromeIconButton(symbol: filterActive ? "line.3.horizontal.decrease.circle.fill"
                                                       : "line.3.horizontal.decrease.circle",
                                 tint: filterActive ? theme.accent : nil) {
                    showFilterSheet = true
                }
                if let menuItems {
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 36, height: 36)
                    }
                }
            }
        }
        .libraryScreen()
        .sheet(isPresented: $showFilterSheet) {
            WorkListFilterSheet(section: section,
                                availableTags: lists.availableTags(for: section, raw: rawWorks()),
                                availableFandoms: lists.availableFandoms(for: section, raw: rawWorks()))
                .environment(theme)
                .environment(lists)
        }
        .sheet(item: $exportedEpub) { exported in
            ShareSheet(items: [exported.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn’t export EPUB", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("New Reading List", isPresented: Binding(
            get: { newListFor != nil },
            set: { if !$0 { newListFor = nil; newListName = "" } })) {
            TextField("List name", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                if let work = newListFor, !name.isEmpty {
                    let listId = state.createReadingList(name)
                    if listId >= 0 { state.addToReadingList(listId, workId: work.id) }
                }
                newListFor = nil
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListFor = nil; newListName = "" }
        } message: {
            if let work = newListFor {
                Text("“\(work.title)” will be added to the new list.")
            }
        }
    }

    private func countLine(_ count: Int) -> String {
        let base = count == 1 ? "1 work" : "\(count) works"
        return filterActive ? "\(base) · filtered" : base
    }

    private func row(_ work: Work) -> some View {
        WorkCardView(
            work: work,
            blurExplicit: state.hideExplicit && work.rating == .explicit,
            isNew: marksNew && state.unseenNewWorkIDs.contains(work.id),
            isRemoved: state.goneWorkIDs.contains(work.id),
            onAuthorTap: UInt64(work.id) != nil ? {
                nav.libraryPath.append(AppDestination.authorWorks(
                    username: AppState.canonicalAuthorUsername(work.author)))
            } : nil,
            onTap: { open(work) }
        )
        .contextMenu {
            WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                        onExportEpub: { exportEpub($0) }) {
                if let swipe {
                    Divider()
                    Button(role: .destructive) {
                        swipe.action(work)
                    } label: {
                        Label(swipe.label, systemImage: swipe.systemImage)
                    }
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let swipe {
                Button(role: .destructive) {
                    swipe.action(work)
                } label: {
                    Label(swipe.label, systemImage: swipe.systemImage)
                }
            }
        }
    }

    private func exportEpub(_ work: Work) {
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func open(_ work: Work) {
        if let onOpen {
            onOpen(work)
        } else {
            nav.openWork(work.id)
        }
    }

    private func statusLine(_ lines: [String]) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(theme.ink3)
            Text(lines.joined(separator: " · "))
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if filterActive {
            VStack(spacing: 12) {
                EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                               title: "Nothing matches",
                               subtitle: "No works in this list match the current filter.")
                Button("Clear Filter") { lists.workListFilters[section] = nil }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .buttonStyle(ButtonPressStyle())
            }
            .padding(.top, 40)
        } else {
            EmptyStateView(systemImage: empty.systemImage, title: empty.title, subtitle: empty.subtitle)
                .padding(.top, 40)
                .padding(.horizontal, theme.pad)
        }
    }
}
