import SwiftUI

struct CommentSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let workID: String
    let chapterID: UInt64?

    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var success = false

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

            Text("Leave a Comment")
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

            if !isLoggedIn {
                notLoggedInView
            } else if success {
                successView
            } else {
                commentFormView
            }

            Spacer(minLength: 12)

            buttonsView
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Not Logged In

    private var notLoggedInView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(theme.ink3)
                .padding(.top, 8)

            Text("You need to be signed in to your AO3 account to leave comments.")
                .font(.custom("HankenGrotesk", size: 13.5).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(theme.sage)
                .padding(.top, 8)

            Text("Comment posted!")
                .font(Typography.uiBody())
                .foregroundStyle(theme.sage)
        }
    }

    // MARK: - Comment Form

    private var commentFormView: some View {
        VStack(spacing: 12) {
            TextEditor(text: $commentText)
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 120, maxHeight: 200)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if commentText.isEmpty {
                        Text("Write your comment...")
                            .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                            .foregroundStyle(theme.ink3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }

            if let error {
                Text(error)
                    .font(Typography.uiSmall())
                    .foregroundStyle(Color(hex: "CE514D"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Buttons

    private var buttonsView: some View {
        VStack(spacing: 10) {
            if !isLoggedIn {
                Button {
                    dismiss()
                } label: {
                    Text("Sign in from Settings")
                        .font(Typography.buttonLabel())
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.accent))
                }
                .buttonStyle(ButtonPressStyle())
            } else if success {
                Button { dismiss() } label: {
                    Text("Done")
                        .font(Typography.buttonLabel())
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                }
                .buttonStyle(ButtonPressStyle())
            } else {
                Button {
                    Task { await submitComment() }
                } label: {
                    Group {
                        if isSubmitting {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(theme.onAccent)
                                Text("Posting...")
                                    .font(Typography.buttonLabel())
                                    .foregroundStyle(theme.onAccent)
                            }
                        } else {
                            Text("Post Comment")
                                .font(Typography.buttonLabel())
                                .foregroundStyle(theme.onAccent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .fill(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.ink3 : theme.accent)
                    )
                }
                .buttonStyle(ButtonPressStyle())
                .disabled(isSubmitting || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !success {
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
            }
        }
    }

    // MARK: - Actions

    private func submitComment() async {
        guard let workId = UInt64(workID) else {
            error = "Invalid work ID."
            return
        }

        isSubmitting = true
        error = nil

        do {
            let posted = try await state.bridge.postComment(
                workId: workId,
                chapterId: chapterID ?? 0,
                comment: commentText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if posted {
                success = true
            } else {
                error = "Failed to post comment. Please try again."
            }
        } catch {
            self.error = error.localizedDescription
        }

        isSubmitting = false
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CommentSheet(workID: "12345", chapterID: nil)
                .environment(AppTheme())
                .environment(AppState())
        }
}
