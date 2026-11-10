import AppKit

// MARK: - Table

extension ListPaneViewController {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if isShowingSubscriptionList { return displayedSubscriptions.count }
        if isShowingReadingLists { return displayedReadingLists.count }
        return works.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isShowingReadingLists {
            guard row < displayedReadingLists.count else { return nil }
            let cell: ReadingListRowCellView
            if let reused = tableView.makeView(withIdentifier: ReadingListRowCellView.reuseID, owner: self) as? ReadingListRowCellView {
                cell = reused
            } else {
                cell = ReadingListRowCellView(theme: theme)
                cell.identifier = ReadingListRowCellView.reuseID
            }
            let list = displayedReadingLists[row]
            cell.configure(name: list.name,
                           workCount: Int(list.workCount),
                           isActive: model.selectedReadingListID == list.id)
            return cell
        }
        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return nil }
            let cell: SubscriptionRowCellView
            if let reused = tableView.makeView(withIdentifier: SubscriptionRowCellView.reuseID, owner: self) as? SubscriptionRowCellView {
                cell = reused
            } else {
                cell = SubscriptionRowCellView(theme: theme)
                cell.identifier = SubscriptionRowCellView.reuseID
            }
            let sub = displayedSubscriptions[row]
            cell.configure(with: sub,
                           isLoading: model.subscriptionWorks.loadingSubscriptionID == sub.id,
                           isActive: model.subscriptionWorks.subId == sub.id
                               && model.subscriptionWorks.subType == normalizedSubType(sub),
                           followShaded: model.follows.isShaded(followTarget(for: sub)))
            cell.onFollowBell = { [weak self] bell in
                guard let self else { return }
                FollowBellMenu.show(for: followTarget(for: sub), follows: model.follows, from: bell)
            }
            return cell
        }

        let cell: WorkRowCellView
        if let reused = tableView.makeView(withIdentifier: WorkRowCellView.reuseID, owner: self) as? WorkRowCellView {
            cell = reused
        } else {
            cell = WorkRowCellView(theme: theme)
            cell.identifier = WorkRowCellView.reuseID
        }
        let work = works[row]
        let textWidth = max(100, tableView.bounds.width - 45)
        cell.configure(with: work,
                       progress: model.appState.progress(for: work),
                       downloaded: appState.downloadedWorkIDs.contains(work.id),
                       selected: model.selectedWorkID == work.id,
                       bookmarked: appState.bookmarkedWorkIDs.contains(work.id),
                       kudosGiven: appState.kudosGivenWorkIDs.contains(work.id),
                       showsKudos: {
                           if case .kudos = appState.workControls(work.id)?.reaction ?? .kudos(given: false, gate: .enabled) { return true }
                           return false
                       }(),
                       followShaded: model.isAuthorBellShaded(for: work),
                       isNew: model.section == .whatsNew && appState.unseenNewWorkIDs.contains(work.id),
                       isRemoved: appState.goneWorkIDs.contains(work.id),
                       finished: appState.finishedWorkIDs.contains(work.id),
                       summaryExpanded: expandedSummaries.contains(work.id),
                       tagsExpanded: expandedTags.contains(work.id),
                       availableTextWidth: textWidth)
        cell.onToggleSummary = { [weak self] in
            self?.toggleSummary(workID: work.id)
        }
        cell.onToggleTags = { [weak self] in
            self?.toggleTags(workID: work.id)
        }
        cell.onToggleBookmark = { [weak self] in
            self?.appState.toggleBookmark(work.id)
        }
        cell.onAuthorClick = { [weak self] in
            self?.model.openAuthorProfile(of: work)
        }
        cell.onFollowBell = { [weak self] bell in
            guard let self else { return }
            model.showAuthorBellMenu(for: work, from: bell)
        }
        return cell
    }

    private func toggleSummary(workID: String) {
        if expandedSummaries.contains(workID) {
            expandedSummaries.remove(workID)
        } else {
            expandedSummaries.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        // Expanding a summary is also an act of focusing that work — select it
        // (fires tableViewSelectionDidChange → model.selectWork).
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Real in-place expand/collapse: the summary's clip-height constraint
        // and the row height animate in the same transaction, so the text
        // reveals/conceals progressively while the row grows or shrinks —
        // no reload, no cell replacement, no snapping.
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
        let expanded = expandedSummaries.contains(workID)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            cell?.setSummaryExpanded(expanded)
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.layoutSubtreeIfNeeded()
        }
    }

    private func toggleTags(workID: String) {
        if expandedTags.contains(workID) {
            expandedTags.remove(workID)
        } else {
            expandedTags.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
        let expanded = expandedTags.contains(workID)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            cell?.setTagsExpanded(expanded)
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.layoutSubtreeIfNeeded()
        }
    }

    /// Row heights come from the cells' own measurement. The automatic
    /// row-height engine was measured (see git history) applying height
    /// changes on reload only upward — a collapsed summary's shorter,
    /// correctly-measured height was silently discarded, so rows never shrank.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return 52 }
            // Measure so the centered text block keeps its padding at any
            // app text size / density instead of clipping against a fixed 52.
            subscriptionSizingCell.configure(with: displayedSubscriptions[row],
                                             isLoading: false, isActive: false, followShaded: false)
            return max(44, subscriptionSizingCell.fittingSize.height)
        }
        if isShowingReadingLists {
            guard row < displayedReadingLists.count else { return 52 }
            let list = displayedReadingLists[row]
            readingListSizingCell.configure(name: list.name, workCount: 0, isActive: false)
            return max(44, readingListSizingCell.fittingSize.height)
        }
        guard row < works.count else { return 52 }
        // Always measure via the sizing cell — querying live row views from
        // inside heightOfRow is illegal reentrancy (AppKit throws while the
        // table is mid-tiling), and the sizing cell computes identical layout.
        let work = works[row]
        let width = max(320, tableView.bounds.width)
        let isNew = model.section == .whatsNew && appState.unseenNewWorkIDs.contains(work.id)
        let isRemoved = appState.goneWorkIDs.contains(work.id)
        let finished = appState.finishedWorkIDs.contains(work.id)
        let summaryExpanded = expandedSummaries.contains(work.id)
        let tagsExpanded = expandedTags.contains(work.id)
        // Measuring is a full cell configure (TextKit layout of the summary
        // and tags), and a reload asks for every row's height. Keyed on
        // everything the height depends on, so a changed work, flag, density
        // or text scale measures again and nothing else does.
        if rowHeightCacheWidth != width {
            rowHeightCache.removeAll(keepingCapacity: true)
            rowHeightCacheWidth = width
        }
        let key = rowHeightKey(for: work, isNew: isNew, isRemoved: isRemoved, finished: finished,
                               summaryExpanded: summaryExpanded, tagsExpanded: tagsExpanded)
        if let cached = rowHeightCache[key] { return cached }
        sizingCell.configure(with: work,
                             progress: model.appState.progress(for: work),
                             downloaded: appState.downloadedWorkIDs.contains(work.id),
                             selected: false,
                             isNew: isNew,
                             isRemoved: isRemoved,
                             finished: finished,
                             summaryExpanded: summaryExpanded,
                             tagsExpanded: tagsExpanded,
                             availableTextWidth: max(100, width - 45))
        sizingCell.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        sizingCell.layoutSubtreeIfNeeded()
        let height = max(52, sizingCell.fittingSize.height)
        if rowHeightCache.count > 4096 { rowHeightCache.removeAll(keepingCapacity: true) }
        rowHeightCache[key] = height
        return height
    }

    /// Everything `WorkRowCellView.configure` lays text out from. Not the
    /// whole `Work` hash: that would walk cached chapter content per row.
    private func rowHeightKey(for work: Work, isNew: Bool, isRemoved: Bool, finished: Bool,
                              summaryExpanded: Bool, tagsExpanded: Bool) -> Int {
        var h = Hasher()
        h.combine(work.id)
        h.combine(work.title)
        h.combine(work.author)
        h.combine(work.fandomList)
        h.combine(work.summary)
        h.combine(work.tags)
        h.combine(work.rating)
        h.combine(work.published)
        h.combine(work.updated)
        h.combine(work.chapterCount)
        h.combine(work.totalChapters)
        h.combine(work.complete)
        h.combine(work.words)
        h.combine(work.kudos)
        h.combine(isNew)
        h.combine(isRemoved)
        h.combine(finished)
        h.combine(summaryExpanded)
        h.combine(tagsExpanded)
        h.combine(theme.density.rawValue)
        h.combine(MacFont.scale)
        return h.finalize()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return }
            model.openSubscriptionTarget(displayedSubscriptions[row])
            tableView.deselectAll(nil)
            return
        }

        if isShowingReadingLists {
            guard row < displayedReadingLists.count else { return }
            model.goReadingList(displayedReadingLists[row].id)
            tableView.deselectAll(nil)
            return
        }

        guard row < works.count else { return }
        let id = works[row].id
        if model.selectedWorkID != id {
            model.selectWork(id)
        }
    }

    @objc func rowClicked() {
        guard !isShowingSubscriptionList else { return }
        let row = tableView.clickedRow
        if isShowingReadingLists {
            // Re-click on the already-open list (no selection change) must
            // still restore the drill-in over a detail/reader view.
            guard row >= 0, row < displayedReadingLists.count else { return }
            model.goReadingList(displayedReadingLists[row].id)
            return
        }
        guard row >= 0, row < works.count else { return }
        let id = works[row].id
        // selectionDidChange already handled a changed selection; this covers
        // the stale-selection re-click and refocusing the detail over a reader.
        if model.selectedWorkID != id || model.readerOpen {
            model.selectWork(id)
        }
    }

    // The full text belongs in the expanded row, not in the hover overlay.
    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    // Swipe right on a row → Remove. Currently Reading clears the saved
    // progress; Offline deletes the download (cached chapters purge later).
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .leading, row < works.count else { return [] }
        let workID = works[row].id
        switch model.section {
        case .reading:
            let remove = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
                self?.model.removeFromCurrentlyReading(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        case .downloads:
            let remove = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, _ in
                guard let self, appState.downloadedWorkIDs.contains(workID) else { return }
                appState.toggleDownload(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        case .whatsNew:
            let remove = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
                self?.appState.removeNewWork(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        default:
            return []
        }
    }
}
