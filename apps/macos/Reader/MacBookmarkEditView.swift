import SwiftUI

/// Editor for the full AO3 bookmark object — notes, your tags, collections,
/// private/rec flags — plus the per-bookmark sync opt-in. Saving is always
/// local; the ONLY network action is the explicit sync, which pushes the
/// bookmark to AO3 with the corrected form fields.
struct MacBookmarkEditView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let workID: String
    let workTitle: String
    let onClose: () -> Void

    @State private var note = ""
    @State private var tagString = ""
    @State private var collectionNames = ""
    @State private var isPrivate = true
    @State private var rec = false
    @State private var syncToAO3 = false
    @State private var isPushing = false
    @State private var pushError: String?
    @State private var pushSucceeded = false
    @State private var loaded = false

    private var isLoggedIn: Bool { appState.ao3Username != nil }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Notes") {
                        TextEditor(text: $note)
                            .font(Font(MacFont.ui(12.5)))
                            .foregroundStyle(theme.ink)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 90)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    TagTokenField(theme: theme, appState: appState,
                                  label: "Your Tags", tagType: "freeform",
                                  value: $tagString)

                    section("Collections") {
                        TextField("Collection names, comma separated", text: $collectionNames)
                            .textFieldStyle(.plain)
                            .font(Font(MacFont.ui(12.5)))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 16) {
                        Toggle("Private bookmark", isOn: $isPrivate)
                        Toggle("Rec", isOn: $rec)
                        Spacer()
                    }
                    .toggleStyle(.checkbox)
                    .font(Font(MacFont.ui(12.5, weight: .medium)))
                    .foregroundStyle(theme.ink2)

                    Divider().overlay(theme.line)

                    if isLoggedIn {
                        Toggle("Sync this bookmark to AO3", isOn: $syncToAO3)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(Font(MacFont.ui(12.5, weight: .medium)))
                            .foregroundStyle(theme.ink2)
                        Text("Off = the bookmark stays on this device only. On = saving also creates it on your AO3 account (as \(isPrivate ? "a private bookmark" : "a public bookmark")).")
                            .font(Font(MacFont.ui(11)))
                            .foregroundStyle(theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Sign in to AO3 in Settings to sync bookmarks to your account.")
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink3)
                    }

                    if let pushError {
                        Text(pushError)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(Color(hex: "CE514D"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if pushSucceeded {
                        Label("Synced to AO3", systemImage: "checkmark.circle.fill")
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.sage)
                    }
                }
                .padding(16)
            }
            Divider().overlay(theme.line)
            footerButtons
        }
        .frame(width: 460, height: 500)
        .background(theme.bg)
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit Bookmark")
                .font(Font(MacFont.serif(18, weight: .semibold)))
                .foregroundStyle(theme.ink)
            Text(workTitle)
                .font(Font(MacFont.ui(11.5)))
                .foregroundStyle(theme.ink3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 14, leading: 16, bottom: 12, trailing: 16))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            content()
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if isPushing { ProgressView().controlSize(.mini) }
                    Text(isPushing ? "Syncing…" : "Save")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isPushing)
        }
        .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    // MARK: - Data

    private func load() {
        guard !loaded, let workId = UInt64(workID) else { return }
        loaded = true
        if let details = appState.bridge.getBookmarkDetails(workId) {
            note = details.note
            tagString = details.tagString
            collectionNames = details.collectionNames
            isPrivate = details.private
            rec = details.rec
            syncToAO3 = details.syncToAo3
        }
    }

    private func save() async {
        guard let workId = UInt64(workID) else {
            onClose()
            return
        }
        // Ensure the bookmark row exists, then write the full object locally.
        if !appState.bookmarkedWorkIDs.contains(workID) {
            appState.bookmarkedWorkIDs.insert(workID)
            appState.bridge.addBookmark(workId, syncToAo3: false)
        }
        appState.bridge.updateBookmarkDetails(workId, note: note, tagString: tagString,
                                              collectionNames: collectionNames,
                                              private: isPrivate, rec: rec)
        appState.bridge.updateBookmarkSync(workId, sync: syncToAO3)

        guard syncToAO3 else {
            onClose()
            return
        }
        // Explicit network action: create/update the bookmark on AO3.
        isPushing = true
        pushError = nil
        pushSucceeded = false
        do {
            _ = try await appState.bridge.pushBookmark(workId: workId)
            pushSucceeded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onClose() }
        } catch {
            pushError = "Couldn’t sync to AO3: \(error.localizedDescription) The bookmark is saved locally — try syncing again later."
        }
        isPushing = false
    }
}
