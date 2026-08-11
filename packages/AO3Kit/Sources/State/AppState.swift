import SwiftUI

@Observable
final class AppState {
    let bridge = RustBridge()
    let sessionId = UUID().uuidString

    var bookmarkedWorkIDs: Set<String> = []
    var kudosGivenWorkIDs: Set<String> = []
    var downloadedWorkIDs: Set<String> = []
    var history: [String] = []
    var progressMap: [String: ReadingProgress] = [:]
    /// works.last_read_dt per work ("YYYY-MM-DD HH:MM:SS" UTC, sortable) —
    /// stamped on every chapter open; Currently Reading sorts by it.
    var lastReadMap: [String: String] = [:]
    var lastReadID: String?
    var hideExplicit: Bool = UserDefaults.standard.bool(forKey: "hideExplicit") {
        didSet { UserDefaults.standard.set(hideExplicit, forKey: "hideExplicit") }
    }

    /// How reading history is handled. `persisted` keeps it in the encrypted
    /// library; `clearOnClose` wipes it at every app quit (plus a launch-time
    /// sweep in case the quit hook never ran); `disabled` records nothing new.
    enum HistoryMode: String, CaseIterable {
        case persisted, clearOnClose, disabled
    }

    var historyMode: HistoryMode = HistoryMode(
        rawValue: UserDefaults.standard.string(forKey: "historyMode") ?? "") ?? .persisted {
        didSet { UserDefaults.standard.set(historyMode.rawValue, forKey: "historyMode") }
    }

    func clearHistory() {
        bridge.clearHistory()
        history = []
        lastReadID = nil
    }

    /// Idle minutes before the library auto-locks; 0 disables. Only applies
    /// when a library password is set (an auto-key DB reopens itself).
    var autoLockMinutes: Int = UserDefaults.standard.object(forKey: "autoLockMinutes") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "autoLockMinutes") }
    }

    func lockNow() {
        bridge.lock()
    }

    // Live search results from Rust backend
    var searchResults: [Work] = []
    var isSearching = false
    var searchError: String?

    // Cached works from SQLCipher (previously browsed/fetched)
    var cachedWorks: [Work] = []
    var readingLists: [UReadingList] = []

    // Account tracking for per-account data freshness
    var subscriptionsLoadedForAccount: String?
    var bookmarksLoadedForAccount: String?

    // Inbox
    var inboxUnreadCount: Int = 0
    var inboxMessages: [InboxItem] = []
    var isLoadingInbox = false
    var inboxError: String?
    var inboxPage: UInt32 = 1
    var inboxHasMore = false
    let inboxTask = NetworkTask()
    var isCheckingInbox = false
    let inboxCheckTask = NetworkTask()
    var inboxCheckTotal: Int = 0

    // Inbox thread (3rd pane)
    var selectedInboxItem: InboxItem?
    var inboxThread: [InboxThreadComment] = []
    var isLoadingThread = false
    var threadError: String?

    // Subscriptions
    var subscriptions: [USubscription] = []
    var isLoadingSubscriptions = false
    var subscriptionError: String?
    let subscriptionLoadTask = NetworkTask()
    var unreadNotificationCount: Int = 0
    var notifications: [UNotification] = []
    var newWorkIDs: [String] = []
    /// Works whose detail view has been opened at least once (persisted as
    /// works.detail_viewed_at). The What's New badge counts only works the
    /// user hasn't looked at yet.
    var detailViewedWorkIDs: Set<String> = []
    /// What's New badge: new works whose details the user has yet to view.
    var newUnviewedWorkCount: Int {
        newWorkIDs.filter { !detailViewedWorkIDs.contains($0) }.count
    }
    /// Works a census confirmed are no longer listed on AO3 — cached copies
    /// are retained everywhere; views may badge them.
    var goneWorkIDs: Set<String> = []
    var isCheckingSubscriptions = false
    let subscriptionCheckTask = NetworkTask()
    var subscriptionCheckTotal: Int = 0
    var subscriptionCheckRemaining: Int = 0
    /// Per-subscription last-completed-check stamps ("subType:subId" →
    /// DB datetime), mirrored from subscription_snapshots for row labels.
    var subscriptionLastChecked: [String: String] = [:]

    init() {
        bridge.recoveryObserver = RecoveryObserver(state: self)
        bridge.recoveryCapabilities = RecoveryCapabilities()
        if bridge.launchState == .autoUnlock {
            _ = bridge.open()
        }
    }

    var torStatus: TorStatus { bridge.torStatus }

    // Connection state
    var isTestingCircuit = false
    var circuitAttempt = 0
    /// Count of user-initiated fetches currently in flight (retryOnTimeout
    /// wraps them all). The subscription checker yields between items while
    /// this is non-zero so background traffic never crowds out the user.
    var activeUserFetches = 0
    /// True while a circuit rotation is running — concurrent rotation
    /// requests coalesce into one instead of thrashing the transport.
    var isRotatingCircuit = false
    var isResolvingCloudflare = false
    var cloudflareResolved = false
    var cloudflareError: String?
    var torConnectCancelled = false
    var torConnectFailed = false
    var showTorConnectOverlay = false
    var needsReauth = false

    // Connection-recovery projection (AppState+Recovery.swift) — Swift never
    // decides whether to rotate/retry; this only reflects what the Rust
    // recovery engine is doing right now.
    var currentRecovery: RecoveryStatus?
    @ObservationIgnored var recoveringOperationID: UInt64?
    var currentProgress: ProgressStatus?
    @ObservationIgnored var progressOperationID: UInt64?
    @ObservationIgnored var operationKinds: [UInt64: OpKind] = [:]

    // Fetched work details from live data
    var fetchedWorks: [String: Work] = [:]
    var fetchedChapters: [String: [UChapter]] = [:]
    let browseTask = NetworkTask()
    let searchTask = NetworkTask()
    let metadataTask = NetworkTask()
    let downloadTask = NetworkTask()
    let bookmarkSyncTask = NetworkTask()

    var isRefreshingWork = false

    /// Work IDs with a subscription toggle in flight (disables the button).
    var subscriptionTogglingWorkIDs: Set<String> = []

    /// Fetched profiles keyed by lowercased username.
    var userProfiles: [String: UUserProfile] = [:]
    /// Usernames with a profile fetch in flight.
    var userProfileLoading: Set<String> = []
    /// Last fetch error per lowercased username — shown in the profile UI
    /// so a failed load never silently masquerades as "not loaded yet".
    var userProfileErrors: [String: String] = [:]
    /// Action keys ("sub:name", "block:name", "mute:name") with a toggle
    /// in flight — disables the corresponding button.
    var userProfileToggling: Set<String> = []

    /// Session cache of avatar bytes by username.
    var authorAvatars: [String: Data] = [:]
    @ObservationIgnored var avatarFetchesInFlight: Set<String> = []
    @ObservationIgnored var avatarFailures: Set<String> = []

    /// Work ID of the last kudos POST that failed, for inline error display.
    var kudosFailedWorkID: String?
    /// True when that failure was a transport fault (offer Retry) rather
    /// than AO3 genuinely rejecting the kudos (retrying would just repeat
    /// the rejection).
    var kudosFailedIsRetryable = false
    /// Kudos POSTs in flight — the heart shows faded until AO3 confirms.
    var kudosPendingWorkIDs: Set<String> = []

    var pendingBookmarkRemoval: String?

    var ao3Username: String?
    var ao3AccountCount = 0

    var downloadingWorkIDs: Set<String> = []

    /// The user's per-image size cap (AppTheme persists it in UserDefaults;
    /// read directly here to keep AppState theme-independent). 0 = no limit.
    static var imageMaxBytesSetting: UInt64 {
        let mb = UserDefaults.standard.object(forKey: "imageMaxMB") as? Int ?? 2
        return UInt64(max(0, mb)) * 1_048_576
    }

    var subscriptionCheckFailed: Int = 0

    /// Platform hook: called with the number of works newly added to What's
    /// New by a completed check. macOS posts a system notification from it.
    @ObservationIgnored var onNewWorksFound: ((Int) -> Void)?

    // MARK: - Browse & Search state

    var browseResults: [Work] = []
    var browseCurrentPage: UInt32 = 0
    var isBrowsing = false
    var searchCurrentPage: UInt32 = 0
    var lastSearchKeys: [String] = []
    var lastSearchValues: [String] = []

    func loadPersistedState() {
        guard bridge.isInitialized else { return }

        // Load cached works
        let works = bridge.getAllCachedWorks()
        cachedWorks = works.map(Self.workFromSummary)

        // Load bookmarks
        let bookmarkIDs = bridge.getBookmarkedWorkIds()
        bookmarkedWorkIDs = Set(bookmarkIDs.map { String($0) })

        // Load history (deduplicated, most recent first)
        let historyEntries = bridge.getHistory()
        var seen = Set<String>()
        history = historyEntries.compactMap { entry in
            let id = String(entry.workId)
            return seen.insert(id).inserted ? id : nil
        }
        lastReadID = history.first

        // Load progress
        let progressEntries = bridge.getAllProgress()
        progressMap = [:]
        for p in progressEntries {
            progressMap[String(p.workId)] = ReadingProgress(chapter: Int(p.chapter), pct: p.position)
        }

        // Last-read datetimes (Currently Reading sort)
        lastReadMap = Dictionary(uniqueKeysWithValues:
            bridge.getWorkLastReadTimes().map { (String($0.workId), $0.lastReadDt) })

        // Intentionally downloaded works
        downloadedWorkIDs = Set(bridge.getDownloadedIds().map { String($0) })

        // Kudos already left on AO3 (permanent — keeps the heart truthful)
        kudosGivenWorkIDs = Set(bridge.getKudosGiven().map { String($0) })

        // Purge chapters for works that aren't downloaded or in currently reading
        bridge.purgeStaleChapters()

        // Load reading lists
        readingLists = bridge.getReadingLists()

        // Restore AO3 session. Login state is whatever the stored account
        // says — never probed. If AO3 rejects a request later, the Rust
        // layer purges the token and needsReauth surfaces the sign-in prompt.
        bridge.restoreSessionCookies()
        refreshAO3Username()

        // Load notifications and What's New works
        loadNotifications()
        loadNewWorks()
        loadSubscriptionLastChecked()

        // Load persisted subscriptions (no network needed)
        if ao3Username != nil {
            let persisted = bridge.getPersistedSubscriptions()
            if !persisted.isEmpty {
                subscriptions = persisted
                subscriptionsLoadedForAccount = ao3Username
            }
        }

        // Auto-check subscriptions when due. Rust decides per row: any
        // subscription whose own last-checked stamp is missing or stale
        // (or a leftover queue from an interrupted round) makes the check
        // due — the old single global date claimed round-end freshness for
        // rows actually checked much earlier.
        if ao3Username != nil {
            let follows = bridge.getFollowed(kind: "author")
            if bridge.isSubscriptionCheckDue(extraAuthors: follows) {
                Task { await checkSubscriptions() }
            }
        }
    }

    // All known works — cached from DB + fetched this session + from browse/search
    var allKnownWorks: [Work] {
        var seen = Set<String>()
        var result: [Work] = []
        for w in cachedWorks + fetchedWorks.values + browseResults + searchResults {
            if seen.insert(w.id).inserted { result.append(w) }
        }
        return result
    }

    var resumeWork: Work? {
        guard let id = lastReadID else { return nil }
        return work(byID: id)
    }

    var shelfWorks: [Work] {
        allKnownWorks.filter { w in
            downloadedWorkIDs.contains(w.id) || (progressMap[w.id]?.pct ?? 0) > 0
        }
    }

    var bookmarkedWorks: [Work] {
        allKnownWorks.filter { bookmarkedWorkIDs.contains($0.id) }
    }

    var historyWorks: [Work] {
        var seen = Set<String>()
        return history.compactMap { id -> Work? in
            guard seen.insert(id).inserted else { return nil }
            return work(byID: id)
        }
    }

    func work(byID id: String) -> Work? {
        // fetchedWorks first: it holds whatever this session most recently
        // fetched or read, while cachedWorks is a launch-time snapshot —
        // consulting the snapshot first showed stale data (e.g. an author's
        // old name) even after a refresh had written the new copy.
        fetchedWorks[id]
        ?? cachedWorks.first { $0.id == id }
        ?? browseResults.first { $0.id == id }
        ?? searchResults.first { $0.id == id }
    }

    static func readableError(_ error: Error) -> String {
        if let ao3 = error as? Ao3Error {
            switch ao3 {
            case .Network(let message), .Parse(let message),
                 .Storage(let message), .NotFound(let message):
                return message
            case .Http(_, let message):
                return message
            case .Cancelled:
                return "Cancelled."
            case .PasswordNeeded, .SessionExpired:
                return "Session expired. Please re-enter your password."
            }
        }
        return error.localizedDescription
    }
}
