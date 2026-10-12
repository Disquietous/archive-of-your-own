import Foundation
import Observation

extension MacAppModel {
    // MARK: - Author profile (two-pane author view)

    var filteredAuthorWorks: [Work] {
        works(for: .authors)
    }

    /// Open the two-pane author view on an author: their profile in the
    /// list pane, one of their lists in the reading pane.
    func openAuthor(_ username: String) {
        authorDetailReturnSection = nil
        if author.username != username { listEmptied(.authors, .authorWorks) }
        author.open(username)
        selectedWorkID = nil
        readerOpen = false
    }

    func closeAuthorWorks() {
        author.close()
        listEmptied(.authors, .authorWorks)
        selectedWorkID = nil
        // Back returns to wherever the author was opened from (a work
        // detail, search results, the Following drill-in) — the Authors
        // list when they were opened from there.
        if let origin = authorDetailReturnSection {
            authorDetailReturnSection = nil
            goSection(origin)
        }
    }

    /// Clicking an author anywhere outside the Authors list (a work
    /// detail's byline, a search user hit, the Following drill-in's person
    /// button) lands here: open the two-pane author view, remembering the
    /// origin so the profile's back button can return to it.
    func openAuthorProfile(_ author: String) {
        let origin = section
        let username = AppState.canonicalAuthorUsername(author)
        goSection(.authors)
        openAuthor(username)
        authorDetailReturnSection = origin == .authors ? nil : origin
    }

    /// Profile buttons land here: swap the reading pane to one of the
    /// user's lists.
    func showAuthorPane(_ username: String, _ pane: AuthorPane) {
        if section != .authors || author.username != username {
            openAuthorProfile(username)
        }
        selectedWorkID = nil
        readerOpen = false
        author.showPane(pane)
    }
}
