import SwiftUI

/// The Sort & Filter menu shared by every work list: per-section sort,
/// completion and rating choices, all persisted by `LibraryListModel`.
struct SortFilterMenu: View {
    @Environment(AppTheme.self) private var theme
    @Environment(LibraryListModel.self) private var lists

    let section: LibrarySection

    var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { lists.workSort(for: section) },
                set: { lists.setWorkSort($0, for: section) })) {
                ForEach(LibraryListModel.WorkSort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)

            Picker("Show", selection: Binding(
                get: { lists.completionFilter(for: section) },
                set: { lists.setCompletionFilter($0, for: section) })) {
                ForEach(LibraryListModel.CompletionFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)

            Picker("Rating", selection: Binding<Rating?>(
                get: { lists.ratingFilter(for: section) },
                set: { lists.setRatingFilter($0, for: section) })) {
                Text("All Ratings").tag(Rating?.none)
                ForEach(Rating.allCases, id: \.self) { rating in
                    Text(rating.rawValue).tag(Optional(rating))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isNonDefault ? theme.accent : theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    private var isNonDefault: Bool {
        lists.workSort(for: section) != .natural
            || lists.completionFilter(for: section) != .all
            || lists.ratingFilter(for: section) != nil
    }
}
