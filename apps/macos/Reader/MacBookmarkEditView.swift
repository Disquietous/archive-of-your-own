import SwiftUI

/// Editor for the active account's AO3 bookmark of a work or series —
/// notes, your tags, collections, private/rec flags — plus the
/// per-bookmark sync opt-in. It creates the record when there is none and
/// has nothing to do with the app bookmark flag. Saving is always local;
/// the only network actions are the explicit sync, which sends the
/// bookmark to AO3, and Delete, which removes it there.
struct MacBookmarkEditView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let target: AO3BookmarkTarget
    let title: String
    let onClose: () -> Void

    init(theme: AppTheme, appState: AppState, target: AO3BookmarkTarget, title: String,
         onClose: @escaping () -> Void) {
        self.theme = theme
        self.appState = appState
        self.target = target
        self.title = title
        self.onClose = onClose
    }

    /// Whether the account already has this bookmark (on AO3 or not).
    @State private var exists = false
    @State private var onAO3 = false
    @State private var confirmingDelete = false

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
                        Text("""
                            Off = the bookmark is kept in this app only. On = saving also creates or updates it on \
                            your AO3 account (as \(isPrivate ? "a private bookmark" : "a public bookmark")).
                            """)
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
        .alert("Delete AO3 Bookmark?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(onAO3
                 ? "This deletes the bookmark from your AO3 account and from this app. It can’t be undone."
                 : "This bookmark was never sent to AO3. Its notes and tags are deleted from this app.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exists ? "Edit AO3 Bookmark" : "New AO3 Bookmark")
                .font(Font(MacFont.serif(18, weight: .semibold)))
                .foregroundStyle(theme.ink)
            Text(title)
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
            if exists {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(isPushing)
            }
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
        guard !loaded else { return }
        loaded = true
        if let details = appState.ao3BookmarkDetails(target) {
            exists = true
            onAO3 = details.ao3BookmarkId != nil
            note = details.note
            tagString = details.tagString
            collectionNames = details.collectionNames
            isPrivate = details.private
            rec = details.rec
            syncToAO3 = details.syncToAo3
        } else {
            // A new AO3 bookmark is meant for AO3 unless switched off.
            syncToAO3 = isLoggedIn
        }
    }

    private func save() async {
        appState.saveAO3Bookmark(target, note: note, tagString: tagString,
                                 collectionNames: collectionNames,
                                 isPrivate: isPrivate, rec: rec, sync: syncToAO3)
        exists = true

        guard syncToAO3 else {
            onClose()
            return
        }
        // Explicit network action: create/update the bookmark on AO3.
        isPushing = true
        pushError = nil
        pushSucceeded = false
        do {
            try await appState.pushAO3Bookmark(target)
            pushSucceeded = true
            onAO3 = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onClose() }
        } catch {
            pushError = "Couldn’t sync to AO3: \(RustBridge.errorMessage(error)) The bookmark is saved in the app — try syncing again later."
        }
        isPushing = false
    }

    private func delete() async {
        isPushing = true
        pushError = nil
        let failure = await appState.deleteAO3Bookmark(target)
        isPushing = false
        if let failure {
            pushError = "Couldn’t delete the bookmark: \(failure)"
        } else {
            onClose()
        }
    }
}
