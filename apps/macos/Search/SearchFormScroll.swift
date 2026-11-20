import SwiftUI

/// The scrolling body every search form sits in. A form grows while it
/// is used — suggestion lists open under a field, a disclosure unfolds,
/// a condition is added — and what grows is often at the bottom edge, so
/// the scroll view hands its position control down to the content:
/// anything marked `revealedInForm` scrolls itself into view when it
/// appears or changes. Room is kept under the last control so it is never
/// flush against the pane's edge.
struct SearchFormScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 48)
            }
            .environment(\.formScroll, proxy)
        }
    }
}

private struct FormScrollKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    /// The enclosing search form's scroll position control; nil outside one.
    var formScroll: ScrollViewProxy? {
        get { self[FormScrollKey.self] }
        set { self[FormScrollKey.self] = newValue }
    }
}

private struct RevealedInForm<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let onAppear: Bool
    let anchor: UnitPoint?
    @State private var id = UUID()
    @Environment(\.formScroll) private var scroll

    func body(content: Content) -> some View {
        content
            .id(id)
            .onAppear { if onAppear { reveal() } }
            .onChange(of: trigger) { reveal() }
    }

    /// Scroll the least distance that brings the whole view on screen,
    /// once the layout pass that grew it has run.
    private func reveal() {
        guard let scroll else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(id, anchor: anchor) }
        }
    }
}

extension View {
    /// Inside a `SearchFormScroll`, keep this view on screen: it scrolls
    /// into view whenever `trigger` changes, and when it first appears if
    /// `onAppear`. With no `anchor` it moves the least distance that
    /// shows it; a block that may be taller than the pane (an unfolded
    /// disclosure) asks for `.top` so its start is what shows. Outside a
    /// form it does nothing.
    func revealedInForm<Trigger: Equatable>(when trigger: Trigger, onAppear: Bool = false,
                                            anchor: UnitPoint? = nil) -> some View {
        modifier(RevealedInForm(trigger: trigger, onAppear: onAppear, anchor: anchor))
    }
}

/// AO3's kinds of search (works, collections, bookmarks, tags, users) as
/// a row of its own at the top of the AO3 tab's forms — they belong to
/// that source, under its tab, not beside the source tabs.
struct ArchiveScopeBar: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        let search = model.search
        HStack(spacing: 2) {
            ForEach(Array(SearchModel.SearchScope.allCases.enumerated()), id: \.element) { index, scope in
                if index > 0 {
                    Rectangle().fill(theme.line).frame(width: 1, height: 12)
                }
                let active = scope == search.scope
                Button { search.setScope(scope) } label: {
                    Text(scope.rawValue)
                        .font(Font(MacFont.ui(12, weight: .semibold)))
                        .foregroundStyle(active ? theme.ink : theme.ink3)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(active ? theme.surface : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}
