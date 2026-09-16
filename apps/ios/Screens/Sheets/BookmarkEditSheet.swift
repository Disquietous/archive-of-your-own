import SwiftUI

/// Editor for the full AO3 bookmark object — notes, your tags, collections,
/// private/rec flags — plus the per-bookmark sync opt-in. Saving is always
/// local; the ONLY network action is the explicit sync, which pushes the
/// bookmark to AO3 with the corrected form fields.
struct BookmarkEditSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let workID: String

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
                    if let work = state.work(byID: workID) {
                        Text(work.title)
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
                        Text("Off = the bookmark stays on this device only. On = saving also creates it on your AO3 account (as \(isPrivate ? "a private bookmark" : "a public bookmark")).")
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
                }
                .padding(theme.pad)
                .padding(.bottom, 24)
            }
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Bookmark")
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
        guard !loaded, let workId = UInt64(workID) else { return }
        loaded = true
        if let details = state.bridge.getBookmarkDetails(workId) {
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
            dismiss()
            return
        }
        // Ensure the bookmark row exists, then write the full object locally.
        if !state.bookmarkedWorkIDs.contains(workID) {
            state.bookmarkedWorkIDs.insert(workID)
            state.bridge.addBookmark(workId, syncToAo3: false)
        }
        state.bridge.updateBookmarkDetails(workId, note: note, tagString: tagString,
                                           collectionNames: collectionNames,
                                           private: isPrivate, rec: rec)
        state.bridge.updateBookmarkSync(workId, sync: syncToAO3)

        guard syncToAO3 else {
            dismiss()
            return
        }
        // Explicit network action: create/update the bookmark on AO3.
        isPushing = true
        pushError = nil
        pushSucceeded = false
        do {
            _ = try await state.bridge.pushBookmark(workId: workId)
            pushSucceeded = true
            try? await Task.sleep(for: .milliseconds(800))
            dismiss()
        } catch {
            pushError = "Couldn’t sync to AO3: \(error.localizedDescription) The bookmark is saved locally — try syncing again later."
        }
        isPushing = false
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
