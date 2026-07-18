import AppKit

/// Builds and presents the sort & filter menu shared by every work list —
/// the middle-pane sections and the reading-pane drill-ins. Sort choice is
/// per-section; the completion/rating filters are global.
final class SortFilterMenuController: NSObject {
    private let theme: AppTheme
    private let model: MacAppModel
    /// The section the currently open menu is acting on.
    private var section: MacAppModel.Section = .reading

    init(theme: AppTheme, model: MacAppModel) {
        self.theme = theme
        self.model = model
    }

    /// A toolbar button that pops this menu, anchored to itself.
    func makeButton(for section: MacAppModel.Section) -> ToolButton {
        var anchor: ToolButton!
        let button = ToolButton(theme: theme, symbol: "arrow.up.arrow.down", tooltip: "Sort & filter") { [weak self] in
            guard let self, let anchor else { return }
            show(for: section, from: anchor)
        }
        anchor = button
        return button
    }

    func show(for section: MacAppModel.Section, from anchor: NSView) {
        self.section = section
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(header("Sort By"))
        let currentSort = model.workSort(for: section)
        for sort in MacAppModel.WorkSort.allCases {
            let item = NSMenuItem(title: sort.label, action: #selector(sortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = sort == currentSort ? .on : .off
            item.representedObject = sort.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("Show"))
        for filter in MacAppModel.CompletionFilter.allCases {
            let item = NSMenuItem(title: filter.label, action: #selector(completionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = filter == model.completionFilter ? .on : .off
            item.representedObject = filter.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("Rating"))
        let anyRating = NSMenuItem(title: "All Ratings", action: #selector(ratingChosen(_:)), keyEquivalent: "")
        anyRating.target = self
        anyRating.isEnabled = true
        anyRating.state = model.ratingFilter == nil ? .on : .off
        menu.addItem(anyRating)
        for rating in Rating.allCases {
            let item = NSMenuItem(title: rating.rawValue, action: #selector(ratingChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = model.ratingFilter == rating ? .on : .off
            item.representedObject = rating.rawValue
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func sortChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sort = MacAppModel.WorkSort(rawValue: raw) else { return }
        model.setWorkSort(sort, for: section)
    }

    @objc private func completionChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let filter = MacAppModel.CompletionFilter(rawValue: raw) else { return }
        model.completionFilter = filter
    }

    @objc private func ratingChosen(_ sender: NSMenuItem) {
        model.ratingFilter = (sender.representedObject as? String).flatMap(Rating.init(rawValue:))
    }
}
