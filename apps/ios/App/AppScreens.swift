import SwiftUI

/// The app's destination and sheet routing, shared by every navigation
/// stack — the tab stacks, the iPad detail column, and each work window.
enum AppScreens {
    @ViewBuilder
    static func destination(for destination: AppDestination) -> some View {
        switch destination {
        case .workDetail(let workID):
            WorkDetailView(workID: workID)
        case .reader(let workID, let chapterIndex, let entireWork):
            ReaderView(workID: workID, chapterIndex: chapterIndex, entireWork: entireWork)
        case .collectionsBrowse:
            CollectionsBrowseView()
        case .collectionWorks(let name, let title):
            CollectionWorksView(name: name, title: title)
        case .readingList(let listID, let name):
            ReadingListView(listID: listID, listName: name)
        case .authorWorks(let username):
            AuthorProfileView(username: username)
        case .inbox:
            InboxView()
        case .inboxThread:
            InboxThreadView()
        case .accountManagement:
            AccountManagementView()
        case .routeTimeouts:
            RouteTimeoutsScreen()
        case .logRetention:
            LogRetentionScreen()
        case .libraryBackups:
            LibraryBackupsScreen()
        case .requestLog:
            RequestLogScreen()
        case .debugLog:
            DebugLogScreen()
        case .librarySection(let section):
            LibrarySectionScreen(section: section)
        case .fandomWorks(let tag):
            FandomWorksScreen(tag: tag)
        case .subscriptionWorks(let id, let name, let subType):
            SubscriptionWorksScreen(id: id, name: name, subType: subType)
        }
    }

    @ViewBuilder
    static func sheet(for sheet: SheetType) -> some View {
        switch sheet {
        case .privacy:
            PrivacySheetView()
        case .readingSettings:
            ReadingSettingsSheetView()
        case .databasePasswordReset:
            DatabasePasswordSheet(isReset: true)
        case .comment(let workID, let chapterID):
            CommentSheet(workID: workID, chapterID: chapterID)
        case .viewComments(let workID, let chapterID):
            CommentThreadView(workID: workID, chapterID: chapterID)
        case .bookmarkEdit(let workID):
            BookmarkEditSheet(workID: workID)
        case .readingListPicker(let workID):
            ReadingListPickerSheet(workID: workID)
        case .themeEditor:
            ThemeEditorSheet()
        case .reauth:
            ReauthSheet()
        }
    }
}

/// Presents `NavigationState.presentedSheet` and the re-auth prompt for
/// whatever root hosts it — the main window and each work window alike.
struct AppSheetsModifier: ViewModifier {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    func body(content: Content) -> some View {
        @Bindable var nav = nav
        content
            .sheet(item: $nav.presentedSheet) { sheet in
                AppScreens.sheet(for: sheet)
                    .environment(theme)
                    .environment(state)
                    .environment(nav)
            }
            .onChange(of: state.needsReauth) {
                if state.needsReauth && nav.presentedSheet == nil {
                    nav.presentedSheet = .reauth
                }
            }
    }
}

extension View {
    func appSheets() -> some View {
        modifier(AppSheetsModifier())
    }
}
