import SwiftUI

/// Editor for the active account's AO3 bookmark of a work or series —
/// notes, your tags, collections, private/rec flags — plus the
/// per-bookmark sync opt-in. It creates the record when there is none and
/// has nothing to do with the app bookmark flag. Saving is always local;
/// the only network actions are the explicit sync, which sends the
/// bookmark to AO3, and Delete, which removes it there.
struct BookmarkEditSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// nil only for a work id that is not a library row (a sample row).
    let target: AO3BookmarkTarget?
    let title: String?

    init(target: AO3BookmarkTarget, title: String?) {
        self.target = target
        self.title = title
    }

    /// The work form; the title comes from the library.
    init(workID: String) {
        self.target = UInt64(workID).map { .work($0) }
        self.title = nil
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

    private var isLoggedIn: Bool { state.ao3Username != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let heading {
                        Text(heading)
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                            .lineLimit(1)
                    }

                    section("Notes") {
                        TextEditor(text: $note)
                            .font(.custom("HankenGrotesk", size: 15))
                            .foregroundStyle(theme.ink)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 100, maxHeight: 160)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    TagTokenField(label: "Your Tags", tagType: "freeform", value: $tagString)

                    section("Collections") {
                        TextField("Collection names, comma separated", text: $collectionNames)
                            .textFieldStyle(.plain)
                            .font(.custom("HankenGrotesk", size: 14))
                            .foregroundStyle(theme.ink)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(spacing: 0) {
                        Toggle("Private bookmark", isOn: $isPrivate)
                            .padding(.vertical, 10)
                        Divider()
                        Toggle("Rec", isOn: $rec)
                            .padding(.vertical, 10)
                    }
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)

                    Divider()

                    if isLoggedIn {
                        Toggle("Sync this bookmark to AO3", isOn: $syncToAO3)
                            .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                            .foregroundStyle(theme.ink)
                            .tint(theme.accent)
                        Text("""
                            Off = the bookmark is kept in this app only. On = saving also creates or updates it on \
                            your AO3 account (as \(isPrivate ? "a private bookmark" : "a public bookmark")).
                            """)
                            .font(.custom("HankenGrotesk", size: 12))
                            .foregroundStyle(theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Sign in to AO3 in Settings to sync bookmarks to your account.")
                            .font(.custom("HankenGrotesk", size: 12.5))
                            .foregroundStyle(theme.ink3)
                    }

                    if let pushError {
                        Text(pushError)
                            .font(.custom("HankenGrotesk", size: 12.5))
                            .foregroundStyle(Color(hex: "CE514D"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if pushSucceeded {
                        Label("Synced to AO3", systemImage: "checkmark.circle.fill")
                            .font(.custom("HankenGrotesk", size: 12.5).weight(.semibold))
                            .foregroundStyle(theme.sage)
                    }
                    if exists {
                        Divider()
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete AO3 Bookmark…", systemImage: "trash")
                                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                        }
                        .disabled(isPushing)
                    }
                }
                .padding(theme.pad)
                .padding(.bottom, 24)
            }
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(exists ? "Edit AO3 Bookmark" : "New AO3 Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isPushing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isPushing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(isPushing)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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

    private var heading: String? {
        if let title { return title }
        if case .work(let id) = target { return state.work(byID: String(id))?.title }
        return nil
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)
            content()
        }
    }

    // MARK: - Data

    private func load() {
        guard !loaded, let target else { return }
        loaded = true
        if let details = state.ao3BookmarkDetails(target) {
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
        guard let target else {
            dismiss()
            return
        }
        state.saveAO3Bookmark(target, note: note, tagString: tagString,
                              collectionNames: collectionNames,
                              isPrivate: isPrivate, rec: rec, sync: syncToAO3)
        exists = true

        guard syncToAO3 else {
            dismiss()
            return
        }
        // Explicit network action: create/update the bookmark on AO3.
        isPushing = true
        pushError = nil
        pushSucceeded = false
        do {
            try await state.pushAO3Bookmark(target)
            pushSucceeded = true
            onAO3 = true
            try? await Task.sleep(for: .milliseconds(800))
            dismiss()
        } catch {
            pushError = "Couldn’t sync to AO3: \(RustBridge.errorMessage(error)) The bookmark is saved in the app — try syncing again later."
        }
        isPushing = false
    }

    private func delete() async {
        guard let target else { return }
        isPushing = true
        pushError = nil
        let failure = await state.deleteAO3Bookmark(target)
        isPushing = false
        if let failure {
            pushError = "Couldn’t delete the bookmark: \(failure)"
        } else {
            dismiss()
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            BookmarkEditSheet(workID: "12345")
                .environment(AppTheme())
                .environment(AppState())
        }
}
