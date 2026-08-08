import SwiftUI

// MARK: - Browse & Search

extension AppState {
    func browseLatestWorks(force: Bool = false) async {
        if bridge.networkBlocked {
            guard await ensureTorConnected() else { return }
        }
        guard !isBrowsing else { return }

        // Load from cache on first page if not forcing. The cache holds ids
        // only — the Rust core hydrates them from its works table.
        if browseCurrentPage == 0 && !force {
            if let cached = bridge.getCachedWorkList(key: "browse", sessionId: sessionId) {
                browseResults = cached.map(Self.workFromSummary)
                browseCurrentPage = UInt32(max(1, browseResults.count / 20))
                return
            }
        }

        isBrowsing = true
        searchError = nil
        let page = force ? 1 : browseCurrentPage + 1
        do {
            let results = try await retryOnTimeout(task: browseTask, using: bridge) {
                try await self.bridge.browseWorks(page: page)
            }
            let newWorks = results.map(Self.workFromSummary)
            if page == 1 {
                browseResults = newWorks
            } else {
                let existingIDs = Set(browseResults.map(\.id))
                let unique = newWorks.filter { !existingIDs.contains($0.id) }
                if !unique.isEmpty {
                    browseResults.append(contentsOf: unique)
                }
            }
            browseCurrentPage = page
            bridge.setCachedWorkList(key: "browse", sessionId: sessionId,
                                     ids: browseResults.compactMap { UInt64($0.id) })
        } catch {
            if !browseTask.isCancelled && !error.isCancellation { searchError = error.localizedDescription }
        }
        isBrowsing = false
    }

    private var searchCacheKey: String {
        let paramStr = zip(lastSearchKeys, lastSearchValues).map { "\($0)=\($1)" }.sorted().joined(separator: "&")
        return "search_\(paramStr.hashValue)"
    }

    func searchAO3Raw(keys: [String], values: [String]) async {
        isSearching = true
        searchError = nil
        searchCurrentPage = 1
        lastSearchKeys = keys
        lastSearchValues = values
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorksRaw(keys: keys, values: values, page: 1)
            }
            searchResults = results.map(Self.workFromSummary)
            bridge.setCachedWorkList(key: searchCacheKey, sessionId: sessionId,
                                     ids: searchResults.compactMap { UInt64($0.id) })
        } catch {
            if !searchTask.isCancelled && !error.isCancellation { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3More() async {
        guard !isSearching else { return }
        isSearching = true
        let page = searchCurrentPage + 1
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorksRaw(keys: self.lastSearchKeys, values: self.lastSearchValues, page: UInt32(page))
            }
            let newWorks = results.map(Self.workFromSummary)
            let existingIDs = Set(searchResults.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            searchResults.append(contentsOf: unique)
            searchCurrentPage = page
            bridge.setCachedWorkList(key: searchCacheKey, sessionId: sessionId,
                                     ids: searchResults.compactMap { UInt64($0.id) })
        } catch {
            if !searchTask.isCancelled && !error.isCancellation { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3(params: USearchParams) async {
        isSearching = true
        searchError = nil
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorks(params)
            }
            searchResults = results.map(Self.workFromSummary)
        } catch {
            if !searchTask.isCancelled && !error.isCancellation { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3(tag: String) async {
        isSearching = true
        searchError = nil
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchByTag(tag)
            }
            searchResults = results.map(Self.workFromSummary)
        } catch {
            if !searchTask.isCancelled && !error.isCancellation { searchError = error.localizedDescription }
        }
        isSearching = false
    }
}
