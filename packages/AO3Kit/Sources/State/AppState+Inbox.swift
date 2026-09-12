import SwiftUI

// MARK: - Inbox

extension AppState {
    func loadCachedInbox(page: UInt32 = 1) {
        let json = bridge.getCachedInbox(page: page)
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(InboxResponse.self, from: data) else { return }
        inboxMessages = response.items
        inboxUnreadCount = Int(response.unreadCount)
        inboxHasMore = response.hasNextPage
        inboxPage = page
    }

    func loadInbox(page: UInt32 = 1) async {
        guard let username = ao3Username else {
            inboxError = "Sign in to AO3 first"
            return
        }
        guard !isLoadingInbox else { return }

        if bridge.networkBlocked {
            guard await ensureTorConnected() else { return }
        }

        isLoadingInbox = true
        inboxError = nil
        do {
            let json = try await retryOnTimeout(task: inboxTask, using: bridge) {
                try await self.bridge.fetchInbox(username: username, page: page)
            }
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(InboxResponse.self, from: data) else {
                inboxError = "Couldn't parse inbox data"
                isLoadingInbox = false
                return
            }
            inboxMessages = response.items
            inboxUnreadCount = Int(response.unreadCount)
            inboxHasMore = response.hasNextPage
            inboxPage = page
        } catch {
            if !inboxTask.isCancelled {
                inboxError = Self.readableError(error)
            }
        }
        isLoadingInbox = false
    }

    func checkInbox() async {
        guard let username = ao3Username else { return }
        guard !isCheckingInbox else { return }

        if bridge.networkBlocked {
            guard await ensureTorConnected() else { return }
        }

        isCheckingInbox = true
        inboxCheckTask.reset()
        do {
            _ = try await retryOnTimeout(task: inboxCheckTask, using: bridge) {
                try await self.bridge.checkInbox(username: username)
            }
            loadCachedInbox(page: inboxPage)
        } catch {
            if !inboxCheckTask.isCancelled {
                inboxCheckTask.statusMessage = "Inbox check failed: \(Self.readableError(error))"
            }
        }
        isCheckingInbox = false
    }

    /// Show a message's thread. Threads are cached forever once fetched:
    /// a thread already in the library renders with no request, and only a
    /// never-fetched one goes to AO3. The header's refresh control is the
    /// way to fetch again.
    func selectInboxMessage(_ item: InboxItem) {
        selectedInboxItem = item
        inboxThread = []
        threadError = nil
        if loadCachedInboxThread(for: item) { return }
        Task { @MainActor in await refreshInboxThread() }
    }

    /// Reload the selected message's thread from the library. False when
    /// the thread has never been fetched.
    @discardableResult
    func loadCachedInboxThread(for item: InboxItem? = nil) -> Bool {
        guard let item = item ?? selectedInboxItem else { return false }
        let json = bridge.getCachedCommentThread(commentId: item.commentId)
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(InboxThreadResponse.self, from: data),
              let thread = response.thread else { return false }
        inboxThread = [thread]
        return true
    }

    /// Fetch the selected message's thread from AO3 and replace the cached
    /// copy. The thread already on screen stays up while this runs.
    func refreshInboxThread() async {
        guard let item = selectedInboxItem, !isLoadingThread else { return }
        isLoadingThread = true
        threadError = nil
        do {
            let json = try await retryOnTimeout(task: inboxTask, using: bridge) {
                try await self.bridge.fetchCommentThread(workUrl: item.workUrl, commentId: item.commentId)
            }
            // The selection may have moved on while the request was out.
            guard selectedInboxItem?.commentId == item.commentId else {
                isLoadingThread = false
                return
            }
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(InboxThreadResponse.self, from: data) else {
                threadError = "Couldn't parse thread data"
                isLoadingThread = false
                return
            }
            if let thread = response.thread {
                inboxThread = [thread]
            } else if inboxThread.isEmpty {
                threadError = "Comment thread not found"
            }
        } catch {
            if selectedInboxItem?.commentId == item.commentId {
                threadError = Self.readableError(error)
            }
        }
        isLoadingThread = false
    }

    /// Post a reply under a comment in the selected thread. On success the
    /// core has already folded the reply into the cached thread, so the
    /// view re-reads the library rather than fetching again.
    func postInboxReply(parentId: UInt64, text: String) async throws -> Bool {
        let posted = try await bridge.postReply(parentCommentId: parentId, comment: text)
        if posted { loadCachedInboxThread() }
        return posted
    }

    func clearInboxSelection() {
        selectedInboxItem = nil
        inboxThread = []
        threadError = nil
    }
}
