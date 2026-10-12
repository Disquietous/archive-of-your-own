import SwiftUI

extension MacCommentsView {
    // MARK: - Data

    func loadInitial() async {
        // Cached comments first — instant content while the live fetch runs.
        let cachedJson: String
        if let cid = chapterID, cid > 0 {
            cachedJson = appState.bridge.getCachedComments(workId: 0, chapterId: cid)
        } else if let wid = UInt64(workID) {
            cachedJson = appState.bridge.getCachedComments(workId: wid, chapterId: 0)
        } else {
            cachedJson = "[]"
        }
        let cached = ParsedComment.fromJSON(cachedJson)
        if !cached.isEmpty {
            comments = cached
        }
        await loadPage(1, replace: true)
    }

    func fetchPage(_ page: UInt32) async throws -> UCommentsPage {
        guard let wid = UInt64(workID) else {
            throw Ao3Error.Network(message: "Comments aren’t available for sample works.")
        }
        if let cid = chapterID, cid > 0 {
            return try await appState.bridge.fetchChapterComments(workId: wid, chapterId: cid, page: page)
        }
        return try await appState.bridge.fetchWorkComments(workId: wid, page: page)
    }

    func loadPage(_ page: UInt32, replace: Bool) async {
        isLoading = true
        loadError = nil
        do {
            let result = try await appState.retryOnTimeout(task: commentTask, using: appState.bridge) {
                try await self.fetchPage(page)
            }
            let newComments = ParsedComment.fromJSON(result.commentsJson)
            if replace {
                comments = newComments
            } else {
                appendUnique(newComments)
            }
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            if !commentTask.isCancelled && !error.isCancellation {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadNextPage() async {
        guard currentPage < totalPages else { return }
        await loadPage(currentPage + 1, replace: false)
    }

    func loadAllPages() async {
        guard currentPage < totalPages else { return }
        isLoadingAll = true
        var nextPage = currentPage + 1
        while nextPage <= totalPages {
            loadAllProgress = nextPage
            do {
                let result = try await appState.retryOnTimeout(task: commentTask, using: appState.bridge) {
                    try await self.fetchPage(nextPage)
                }
                appendUnique(ParsedComment.fromJSON(result.commentsJson))
                currentPage = result.currentPage
                totalPages = result.totalPages
                nextPage += 1
            } catch {
                if !commentTask.isCancelled && !error.isCancellation {
                    loadError = error.localizedDescription
                }
                break
            }
        }
        isLoadingAll = false
    }

    func submitComment() async {
        guard let wid = UInt64(workID) else {
            postError = "Comments aren’t available for sample works."
            return
        }
        isPosting = true
        postError = nil
        do {
            let posted = try await appState.bridge.postComment(
                workId: wid,
                chapterId: chapterID ?? 0,
                comment: newComment.trimmingCharacters(in: .whitespacesAndNewlines))
            if posted {
                postSuccess = true
                newComment = ""
            } else {
                postError = "Failed to post comment. Please try again."
            }
        } catch {
            postError = error.localizedDescription
        }
        isPosting = false
    }

    func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        do {
            let posted = try await appState.bridge.postReply(parentCommentId: parentId, comment: trimmed)
            if posted {
                replySuccess = true
                replyText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    replyingTo = nil
                    replySuccess = false
                }
            } else {
                replyError = "Failed to post reply."
            }
        } catch {
            replyError = error.localizedDescription
        }
        isSubmittingReply = false
    }
}
