import SwiftUI

enum AppTab: String, Hashable {
    case library, browse, search, settings
}

enum AppDestination: Hashable {
    case workDetail(workID: String)
    case reader(workID: String, chapterIndex: Int, entireWork: Bool = false)
    case tagBrowse(tag: String)
    case readingList(listID: Int64, name: String)
    case authorWorks(username: String)
    case downloads
    case history
    case inbox
    case accountManagement
}

enum SheetType: Identifiable, Hashable {
    case privacy
    case readingSettings
    case databasePasswordReset
    case ao3Login
    case comment(workID: String, chapterID: UInt64?)
    case viewComments(workID: String, chapterID: UInt64?)
    case bookmarkEdit(workID: String)
    case themeEditor

    var id: String {
        switch self {
        case .privacy: "privacy"
        case .readingSettings: "readingSettings"
        case .databasePasswordReset: "databasePasswordReset"
        case .ao3Login: "ao3Login"
        case .comment(let workID, let chapterID): "comment-\(workID)-\(chapterID ?? 0)"
        case .viewComments(let workID, let chapterID): "viewComments-\(workID)-\(chapterID ?? 0)"
        case .bookmarkEdit(let workID): "bookmarkEdit-\(workID)"
        case .themeEditor: "themeEditor"
        }
    }
}

@Observable
final class NavigationState {
    var selectedTab: AppTab = .library
    var libraryPath = NavigationPath()
    var browsePath = NavigationPath()
    var searchPath = NavigationPath()
    var settingsPath = NavigationPath()
    var presentedSheet: SheetType?
    var goHomeRequested = false

    func openWork(_ id: String) {
        let dest = AppDestination.workDetail(workID: id)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openReader(_ workID: String, chapterIndex: Int) {
        let dest = AppDestination.reader(workID: workID, chapterIndex: chapterIndex)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openEntireWork(_ workID: String) {
        let dest = AppDestination.reader(workID: workID, chapterIndex: 0, entireWork: true)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openReadingList(_ listId: Int64, name: String) {
        let dest = AppDestination.readingList(listID: listId, name: name)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func openTag(_ tag: String) {
        let dest = AppDestination.tagBrowse(tag: tag)
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
    }

    func goHome() {
        libraryPath = NavigationPath()
        browsePath = NavigationPath()
        searchPath = NavigationPath()
        settingsPath = NavigationPath()
        presentedSheet = nil
        selectedTab = .library
        goHomeRequested = true
    }

    func openInbox() {
        let dest = AppDestination.inbox
        switch selectedTab {
        case .library: libraryPath.append(dest)
        case .browse: browsePath.append(dest)
        case .search: searchPath.append(dest)
        case .settings: settingsPath.append(dest)
        }
        presentedSheet = nil
    }

    func goBack() {
        switch selectedTab {
        case .library: if !libraryPath.isEmpty { libraryPath.removeLast() }
        case .browse: if !browsePath.isEmpty { browsePath.removeLast() }
        case .search: if !searchPath.isEmpty { searchPath.removeLast() }
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }
        }
    }
}
