import SwiftUI

struct ReauthSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?

    private var username: String {
        state.ao3Username ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 20)

            Image(systemName: "lock.rotation")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.bottom, 12)

            Text("Session Expired")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            VStack(spacing: 12) {
                Text("Enter your password for **\(username)** to continue.")
                    .font(.custom("HankenGrotesk", size: 13.5).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                SecureFieldWithToggle(placeholder: "Password", text: $password)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let error {
                    Text(error)
                        .font(Typography.uiSmall())
                        .foregroundStyle(Color(hex: "CE514D"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await reauthenticate() }
                } label: {
                    Group {
                        if isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(theme.onAccent)
                                Text("Signing in...")
                                    .font(Typography.buttonLabel())
                                    .foregroundStyle(theme.onAccent)
                            }
                        } else {
                            Text("Sign in")
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
                .disabled(isLoading || password.isEmpty)
                .opacity(password.isEmpty ? 0.5 : 1)

                Button { dismiss() } label: {
                    Text("Later")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private func reauthenticate() async {
        isLoading = true
        error = nil

        do {
            let success = try await state.bridge.reauthenticate(password: password)
            if success {
                state.needsReauth = false
                password = ""
                dismiss()
            } else {
                error = "Login failed. Check your password."
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
