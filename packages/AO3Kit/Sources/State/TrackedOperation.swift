import Foundation
import Observation

/// The caller half of the request-tracking standard, packaged: one of
/// these represents one kind of UI-initiated operation (a work refresh, a
/// chapter fetch, a works crawl). `run` mints an operation id, publishes
/// it observably so a pane's render pass can hand it to the progress
/// banner, and guard-clears it when the operation ends — the whole
/// mint → store → pass → clear dance in one place.
@Observable
final class TrackedOperation {
    /// The in-flight operation's id — nil when idle. Render passes read
    /// this to decide whether the pane's progress banner shows; reads are
    /// observation-tracked, so the banner appears and disappears with the
    /// operation.
    private(set) var opID: UInt64?

    /// Run one tracked operation. `body` receives the minted id and must
    /// pass it into a tracking-aware bridge fetch (`fetchWork(_:opID:)`,
    /// `fetchChapters(_:opID:)`, ...) — the core stamps it onto every
    /// request the operation makes, retries and crawl pages included. The
    /// id is published before the body starts, so the banner filters for
    /// the operation from its first request, and cleared on the way out —
    /// guarded, so a newer overlapping run keeps ownership of the banner.
    @MainActor
    func run<T>(_ bridge: RustBridge, _ body: (UInt64) async throws -> T) async rethrows -> T {
        let id = bridge.newOperationID()
        opID = id
        defer { if opID == id { opID = nil } }
        return try await body(id)
    }
}
