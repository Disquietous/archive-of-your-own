import AppKit
import Foundation
import Observation

extension MacAppModel {
    // MARK: - Author profile (two-pane author view)

    var filteredAuthorWorks: [Work] {
        works(for: .authors)
    }

    /// Open the two-pane author view on a user: their profile in the list
    /// pane, one of their lists in the reading pane. The users row id is
    /// the only identity authors are opened with (design/users-model-plan.md).
    func openAuthor(userID: UInt64) {
        authorDetailReturnSection = nil
        if author.userID != userID { listEmptied(.authors, .authorWorks) }
        author.open(userID: userID)
        selectedWorkID = nil
        readerOpen = false
    }

    /// AO3-keyed surfaces (the Following list, subscriptions, pasted
    /// links, comment bylines on AO3 works) name an AO3 account; its
    /// users row is resolved (created when never seen) and opened.
    func openAuthor(_ username: String) {
        guard let id = appState.userID(forAO3Username: username) else { return }
        openAuthor(userID: id)
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

    /// Clicking an author anywhere outside the Authors list lands here:
    /// open the two-pane author view, remembering the origin so the
    /// profile's back button can return to it.
    func openAuthorProfile(userID: UInt64) {
        let origin = section
        goSection(.authors)
        openAuthor(userID: userID)
        authorDetailReturnSection = origin == .authors ? nil : origin
    }

    /// An AO3 account by name (see `openAuthor(_:)`).
    func openAuthorProfile(_ author: String) {
        guard let id = appState.userID(forAO3Username: author) else { return }
        openAuthorProfile(userID: id)
    }

    /// A work's byline: the linked users row when the library has one,
    /// else (an AO3 work saved before links existed) the AO3 account name.
    func openAuthorProfile(of work: Work) {
        if let id = work.authorIDs.first, id != 0 {
            openAuthorProfile(userID: id)
        } else if work.source.isEmpty || work.source == "ao3" {
            openAuthorProfile(work.author)
        }
    }

    /// The follow target for a work's first author: the linked users row.
    /// nil for a work the library has not linked (its bell stays plain).
    func authorTarget(for work: Work) -> FollowModel.Target? {
        FollowModel.Target.author(for: work)
    }

    /// The bell menu for a work's author, resolving the users row from the
    /// AO3 byline when the work is not linked (a click, so a row may be
    /// created).
    func showAuthorBellMenu(for work: Work, from view: NSView) {
        let target = authorTarget(for: work)
            ?? ((work.source.isEmpty || work.source == "ao3") ? follows.ao3AuthorTarget(work.author, ensure: true) : nil)
        guard let target else { return }
        FollowBellMenu.show(for: target, follows: follows, from: view)
    }

    /// Shading for a work row's author bell.
    func isAuthorBellShaded(for work: Work) -> Bool {
        authorTarget(for: work).map { follows.isShaded($0) } ?? false
    }

    /// A comment byline on a work: AO3 comments name AO3 accounts; a
    /// second source's commenters are guest rows with no profile to open.
    func openCommentAuthor(_ name: String, onWorkID workID: String?) {
        let source = workID.flatMap { appState.work(byID: $0)?.source } ?? "ao3"
        guard source.isEmpty || source == "ao3" else { return }
        openAuthorProfile(name)
    }

    /// Profile buttons land here: swap the reading pane to one of the
    /// user's lists.
    func showAuthorPane(userID: UInt64, _ pane: AuthorPane) {
        if section != .authors || author.userID != userID {
            openAuthorProfile(userID: userID)
        }
        selectedWorkID = nil
        readerOpen = false
        author.showPane(pane)
    }

    /// AO3 link routing (/users/{name}/works etc.).
    func showAuthorPane(_ username: String, _ pane: AuthorPane) {
        guard let id = appState.userID(forAO3Username: username) else { return }
        showAuthorPane(userID: id, pane)
    }
}
