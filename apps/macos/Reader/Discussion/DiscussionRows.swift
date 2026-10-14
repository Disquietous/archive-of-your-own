import Foundation

/// One comment as the thread table shows it: its place in the flattened
/// tree plus everything the cell needs precomputed.
struct DiscussionCommentItem: Equatable {
    let comment: ParsedComment
    /// Indent level, capped at `DiscussionRows.maxIndent`.
    let indent: Int
    /// Ancestors whose thread lines run past this row, one per indent level.
    let guides: [UInt64]
    /// Draws its own thread line under its avatar (expanded, has children).
    let ownsLine: Bool
    /// Set when the thread is too deep to indent: who this replies to.
    let replyingTo: String?
    let isCreator: Bool
    /// "Ch. N" when the scope mixes chapters; empty otherwise.
    let chapterChip: String
}

/// The thread list flattened into table rows. Built once per change to
/// its inputs (comments, collapse, sort, filters, pending posts) — never
/// per frame.
enum DiscussionRow: Equatable {
    case comment(DiscussionCommentItem)
    case pending(DiscussionModel.Pending, indent: Int, guides: [UInt64])
    case collapsed(parent: UInt64, count: Int, indent: Int, guides: [UInt64])
    case moreReplies(parent: UInt64, count: UInt32, loading: Bool, indent: Int, guides: [UInt64])
    case separator
    case footer

    var commentID: UInt64? {
        if case .comment(let item) = self { return item.comment.id }
        return nil
    }
}

enum DiscussionRows {
    /// Levels that indent; deeper replies sit at the last level with a
    /// "replying to" line instead.
    static let maxIndent = 2
}

extension DiscussionModel {
    /// Reads every input the rows depend on, so an observation of this call
    /// fires exactly when the list must change.
    func buildRows() -> [DiscussionRow] {
        let creators = creatorAccounts
        let showChips = scope == .work || effectiveChapterID == 0
        var rows: [DiscussionRow] = []

        func walk(_ c: ParsedComment, depth: Int, guides: [UInt64], replyingTo: ParsedComment?) {
            let pendingKids = pending(under: c.id)
            let hasChildren = !c.replies.isEmpty || !pendingKids.isEmpty || c.moreReplies > 0
            let isCollapsed = collapsed.contains(c.id)
            let indent = min(depth, DiscussionRows.maxIndent)
            let ownsLine = hasChildren && !isCollapsed && depth < DiscussionRows.maxIndent
            rows.append(.comment(DiscussionCommentItem(
                comment: c, indent: indent, guides: guides, ownsLine: ownsLine,
                replyingTo: replyingTo?.displayName,
                isCreator: !c.isGuest && creators.contains(c.authorId.lowercased()),
                chapterChip: showChips ? c.chapterChip : "")))
            guard hasChildren else { return }
            if isCollapsed {
                let count = Self.descendantCount(c) + Int(c.moreReplies)
                rows.append(.collapsed(parent: c.id, count: count, indent: indent, guides: guides))
                return
            }
            let flatten = depth >= DiscussionRows.maxIndent
            let childGuides = ownsLine ? guides + [c.id] : guides
            let childIndent = min(depth + 1, DiscussionRows.maxIndent)
            for reply in c.replies {
                walk(reply, depth: depth + 1, guides: childGuides, replyingTo: flatten ? c : nil)
            }
            for item in pendingKids {
                rows.append(.pending(item, indent: childIndent, guides: childGuides))
            }
            if c.moreReplies > 0 {
                rows.append(.moreReplies(parent: c.id, count: c.moreReplies,
                                         loading: expandingReplies.contains(c.id),
                                         indent: childIndent, guides: childGuides))
            }
        }

        for thread in visibleThreads {
            walk(thread, depth: 0, guides: [], replyingTo: nil)
            rows.append(.separator)
        }
        for item in pending(under: nil) {
            rows.append(.pending(item, indent: 0, guides: []))
        }
        if !comments.isEmpty { rows.append(.footer) }
        return rows
    }

    static func descendantCount(_ c: ParsedComment) -> Int {
        c.replies.reduce(0) { $0 + 1 + descendantCount($1) }
    }
}
