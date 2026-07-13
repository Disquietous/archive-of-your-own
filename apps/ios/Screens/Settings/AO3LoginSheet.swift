import SwiftUI

struct AO3LoginSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var isLoggedIn = false

    private var hasAccount: Bool {
        state.ao3Username != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 20)

            Image(systemName: "person.crop.circle")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(isLoggedIn ? theme.sage : theme.accent)
                .padding(.bottom, 12)

            Text(isLoggedIn ? "Logged in to AO3" : "AO3 Account")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            if isLoggedIn, let username = state.ao3Username {
                loggedInView(username: username)
            } else {
                loginFormView
            }

            Spacer()

            buttonsView
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .task {
            if let existing = state.ao3Username {
                isLoggedIn = true
                username = existing
            }
        }
    }

    // MARK: - Logged In

    private func loggedInView(username: String) -> some View {
        VStack(spacing: 8) {
            Text("Signed in as")
                .font(.custom("HankenGrotesk", size: 13.5).weight(.medium))
                .foregroundStyle(theme.ink3)

            Text(username)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.surface2)
                )

            Text("Kudos, comments, and bookmarks can sync to AO3.")
                .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
        .padding(.top, 4)
    }

    // MARK: - Login Form

    private var loginFormView: some View {
        VStack(spacing: 12) {
            Text("Sign in to leave kudos, comments, and sync bookmarks.")
                .font(.custom("HankenGrotesk", size: 13.5).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            TextField("Username", text: $username)
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 12))

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
    }

    // MARK: - Buttons

    private var buttonsView: some View {
        VStack(spacing: 10) {
            if isLoggedIn {
                Button {
                    logOut()
                } label: {
                    Group {
                        if isLoggingOut {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(Color(hex: "CE514D"))
                                Text("Logging out...")
                                    .font(Typography.buttonLabel())
                                    .foregroundStyle(Color(hex: "CE514D"))
                            }
                        } else {
                            Text("Log out")
                                .font(Typography.buttonLabel())
                                .foregroundStyle(Color(hex: "CE514D"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .stroke(Color(hex: "CE514D").opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(ButtonPressStyle())
                .disabled(isLoggingOut)
            } else {
                Button {
                    Task { await logIn() }
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
                .disabled(isLoading || username.isEmpty || password.isEmpty)
                .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)
            }

            Button { dismiss() } label: {
                Text("Close")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - Actions

    private func logIn() async {
        isLoading = true
        error = nil

        do {
            let success = try await state.bridge.login(username: username, password: password)
            if success {
                try state.bridge.saveAccount(username: username)
                state.bridge.saveSessionCookies()
                state.refreshAO3Username()
                isLoggedIn = true
                password = ""
            } else {
                error = "Login failed. Check your username and password."
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    @State private var isLoggingOut = false

    private func logOut() {
        isLoggingOut = true
        Task {
            await state.bridge.logoutAccount()
            state.refreshAO3Username()
            isLoggedIn = false
            username = ""
            password = ""
            error = nil
            isLoggingOut = false
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AO3LoginSheet()
                .environment(AppTheme())
                .environment(AppState())
        }
}
