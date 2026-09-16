import SwiftUI

/// Filter sheet for the bookmark search results — the work-list fields
/// plus the bookmark's own (bookmarked by, note, date). A client-side
/// sieve over the fetched rows, never a server-side refinement. Mirrors
/// the macOS `BookmarkListFilterView`; the filter lives in `SearchModel`.
struct BookmarkListFilterSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SearchModel.self) private var search
    @Environment(\.dismiss) private var dismiss

    private var filter: Binding<SearchModel.BookmarkListFilter> {
        Binding(get: { search.bookmarkListFilter },
                set: { search.bookmarkListFilter = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FilterTextField(placeholder: "Title, author, or summary", text: filter.text)
                    HStack(spacing: 8) {
                        FilterTextField(placeholder: "Kudos (e.g. >1000)", text: filter.kudos)
                            .keyboardType(.numbersAndPunctuation)
                        FilterTextField(placeholder: "Words (e.g. <50000)", text: filter.words)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    TokenFilterSection(label: "Fandom", placeholder: "Type to add a fandom…",
                                       selected: filter.fandoms, allOptions: search.bookmarkFilterFandomPool)
                    TokenFilterSection(label: "Tags (work or bookmark)", placeholder: "Type to add a tag…",
                                       selected: filter.tags, allOptions: search.bookmarkFilterTagPool)

                    Text("BOOKMARK")
                        .font(Typography.sectionHeader())
                        .tracking(0.08 * 13)
                        .foregroundStyle(theme.ink3)
                        .padding(.top, 2)
                    FilterTextField(placeholder: "Bookmarked by", text: filter.bookmarker)
                    FilterTextField(placeholder: "Note text", text: filter.note)
                    FilterTextField(placeholder: "Date bookmarked (e.g. Aug 2026)", text: filter.date)
                    FilterRetentionToggle()
                }
                .padding(theme.pad)
            }
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filter Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { search.bookmarkListFilter = SearchModel.BookmarkListFilter() }
                        .disabled(!filter.wrappedValue.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
