import Foundation
import Observation

extension MacAppModel {
    // MARK: - Sample data (testing/demo)

    var sampleDataLoaded: Bool { appState.sampleDataLoaded }

    func loadSampleData() { appState.loadSampleData() }

    func clearSampleData() {
        let removed = appState.clearSampleData()
        if let selected = selectedWorkID, removed.contains(selected) {
            clearSelection()
        }
    }

    // MARK: - Subscription drill-in (stays inside Subscriptions)

    var filteredSubscriptionWorks: [Work] {
        works(for: .subscriptions)
    }

    /// Show a subscription's locally stored works in the reading pane.
    func openSubscriptionAuthorWorks(subscriptionID: String, author: String, subType: String = "author") {
        if subscriptionWorks.subId != subscriptionID { listEmptied(.subscriptions) }
        subscriptionWorks.open(subscriptionID: subscriptionID, author: author, subType: subType)
        selectedWorkID = nil
        readerOpen = false
    }

    func closeSubscriptionWorks() {
        subscriptionWorks.close()
        listEmptied(.subscriptions)
        selectedWorkID = nil
    }
}
