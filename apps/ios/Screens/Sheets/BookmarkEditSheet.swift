import SwiftUI

struct BookmarkEditSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let workID: String

    @State private var noteText = ""
    @State private var syncToAO3 = false
    @State private var isSaving = false
    @State private var isPushing = false
    @State private var error: String?
    @State private var pushSuccess = false

    private var isLoggedIn: Bool {
        state.bridge.getCredentials() != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            Text("Edit Bookmark")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 4)

            if let work = state.work(byID: workID) {
                Text(work.title)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .padding(.bottom, 12)
            }

            formView

            Spacer(minLength: 12)

            buttonsView
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear(perform: loadBookmark)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(spacing: 12) {
            TextEditor(text: $noteText)
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 100, maxHeight: 180)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if noteText.isEmpty {
                        Text("Add a note...")
                            .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                            .foregroundStyle(theme.ink3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }

            // Sync toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync to AO3")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    if syncToAO3 && !isLoggedIn {
                        Text("Requires AO3 login")
                            .font(Typography.uiSmall())
                            .foregroundStyle(Color(hex: "CE514D"))
                    }
                }
                Spacer()
                Toggle("", isOn: $syncToAO3)
                    .labelsHidden()
                    .tint(theme.accent)
            }
            .padding(.horizontal, 4)

            if let error {
                Text(error)
                    .font(Typography.uiSmall())
                    .foregroundStyle(Color(hex: "CE514D"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pushSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.sage)
                    Text("Pushed to AO3")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.sage)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Buttons

    private var buttonsView: some View {
        VStack(spacing: 10) {
            // Push to AO3 button (only if sync enabled and logged in)
            if syncToAO3 && isLoggedIn {
                Button {
                    Task { await pushToAO3() }
                } label: {
                    Group {
                        if isPushing {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(theme.onAccent)
                                Text("Pushing...")
                                    .font(Typography.buttonLabel())
                                    .foregroundStyle(theme.onAccent)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Push to AO3")
                                    .font(Typography.buttonLabel())
                            }
                            .foregroundStyle(theme.onAccent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .fill(theme.sage)
                    )
                }
                .buttonStyle(ButtonPressStyle())
                .disabled(isPushing || isSaving)
            }

            // Save button
            Button {
                Task { await saveBookmark() }
            } label: {
                Group {
                    if isSaving {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(theme.onAccent)
                            Text("Saving...")
                                .font(Typography.buttonLabel())
                                .foregroundStyle(theme.onAccent)
                        }
                    } else {
                        Text("Save")
                            .font(Typography.buttonLabel())
                            .foregroundStyle(theme.onAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button)
                        .fill(theme.accent)
                )
            }
            .buttonStyle(ButtonPressStyle())
            .disabled(isSaving || isPushing)

            Button { dismiss() } label: {
                Text("Cancel")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - Actions

    private func loadBookmark() {
        guard let workId = UInt64(workID) else { return }
        if let bookmark = state.bridge.getBookmark(workId) {
            noteText = bookmark.note
            syncToAO3 = bookmark.syncToAo3
        }
    }

    private func saveBookmark() async {
        guard let workId = UInt64(workID) else {
            error = "Invalid work ID."
            return
        }

        isSaving = true
        error = nil

        state.bridge.updateBookmarkNote(workId, note: noteText.trimmingCharacters(in: .whitespacesAndNewlines))
        state.bridge.updateBookmarkSync(workId, sync: syncToAO3)

        isSaving = false
        dismiss()
    }

    private func pushToAO3() async {
        guard let workId = UInt64(workID) else {
            error = "Invalid work ID."
            return
        }

        isPushing = true
        error = nil
        pushSuccess = false

        do {
            let success = try await state.bridge.pushBookmark(workId: workId)
            if success {
                pushSuccess = true
            } else {
                error = "Failed to push bookmark to AO3."
            }
        } catch {
            self.error = error.localizedDescription
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
