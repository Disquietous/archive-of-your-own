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

    func selectInboxMessage(_ item: InboxItem) {
        selectedInboxItem = item
        inboxThread = []
        threadError = nil
        isLoadingThread = true
        Task { @MainActor in
            do {
                let json = try await retryOnTimeout(task: inboxTask, using: bridge) {
                    try await self.bridge.fetchCommentThread(workUrl: item.workUrl, commentId: item.commentId)
                }
                guard let data = json.data(using: .utf8),
                      let response = try? JSONDecoder().decode(InboxThreadResponse.self, from: data) else {
                    threadError = "Couldn't parse thread data"
                    isLoadingThread = false
                    return
                }
                if let thread = response.thread {
                    inboxThread = [thread]
                } else {
                    threadError = "Comment thread not found"
                }
            } catch {
                threadError = Self.readableError(error)
            }
            isLoadingThread = false
        }
    }

    func clearInboxSelection() {
        selectedInboxItem = nil
        inboxThread = []
        threadError = nil
    }
}
