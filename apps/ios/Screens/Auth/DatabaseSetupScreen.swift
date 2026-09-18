import SwiftUI

/// No library file yet. Before creating an empty one, look for a library
/// the user already has — the iCloud copy, or backups still on disk — and
/// let them pick (LibraryBootstrap). Whatever the source, the last step is
/// the same Protect Your Library choice.
struct DatabaseSetupScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var bootstrap: LibraryBootstrap?

    var body: some View {
        ScrollView {
            if let bootstrap {
                if let key = bootstrap.recoveryKey {
                    GatePage(symbol: "lock.shield", tint: theme.sage, title: "Protect Your Library",
                             subtitle: "Your library is protected with your password.") {
                        RecoveryKeyBlock(key: key) { bootstrap.dismissRecoveryKey() }
                    }
                } else {
                    switch bootstrap.step {
                    case .probing(let text), .working(let text):
                        GatePage(symbol: "icloud", tint: theme.sage, title: "Looking for Your Library", subtitle: text) {
                            ProgressView().padding(.top, 4)
                            if case .probing = bootstrap.step {
                                GateLink(label: "Start a new library") { bootstrap.choose(.new) }
                                    .padding(.top, 28)
                            }
                        }
                    case .choose:
                        LibrarySourceChooser(bootstrap: bootstrap)
                    case .protect(let source):
                        ProtectLibraryForm(bootstrap: bootstrap, source: source)
                    case .backupPassword:
                        BackupPasswordForm(bootstrap: bootstrap)
                    }
                }
            }
        }
        .background(theme.bg)
        .onAppear {
            guard bootstrap == nil else { return }
            let b = LibraryBootstrap(bridge: state.bridge)
            bootstrap = b
            b.start()
        }
        .onDisappear { bootstrap?.cancelProbe() }
    }
}

// MARK: - Shared gate pieces

private struct GatePage<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(tint)
                .padding(.bottom, 16)
            Text(title)
                .font(Typography.pageTitle())
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text(subtitle)
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            content()
            Spacer().frame(height: 40)
        }
    }
}

private struct GateField<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.custom("HankenGrotesk", size: 16).weight(.medium))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }
}

private struct GateButton: View {
    @Environment(AppTheme.self) private var theme
    let label: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typography.buttonLabel())
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: Radius.button).fill(fill))
        }
        .buttonStyle(ButtonPressStyle())
    }
}

private struct GateLink: View {
    @Environment(AppTheme.self) private var theme
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.ink3)
        }
    }
}

private struct GateError: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.uiSmall())
            .foregroundStyle(Color(hex: "CE514D"))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecoveryKeyBlock: View {
    @Environment(AppTheme.self) private var theme
    let key: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("RECOVERY KEY")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
            Text(key)
                .font(.system(size: 20, design: .monospaced).weight(.bold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Write this down and keep it safe. If you forget your password, this is the only way to recover your data. It will not be shown again.")
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(Color(hex: "CE514D"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            GateButton(label: "I've saved my recovery key", fill: theme.accent, action: done)
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Choose a source

private struct LibrarySourceChooser: View {
    @Environment(AppTheme.self) private var theme
    let bootstrap: LibraryBootstrap

    var body: some View {
        GatePage(symbol: "books.vertical", tint: theme.sage, title: "Welcome Back",
                 subtitle: "A library you already have was found.\nStart from it, or begin with an empty one.") {
            VStack(spacing: 12) {
                if let cloud = bootstrap.cloud {
                    sourceRow(symbol: "icloud", title: "Use the iCloud copy",
                              detail: "From \(cloud.deviceName) · \(Self.when(cloud.writtenAt)) · \(Self.size(cloud.sizeBytes))",
                              note: cloud.note, enabled: cloud.availability == .ready) {
                        bootstrap.choose(.cloud)
                    }
                }
                ForEach(bootstrap.backups) { backup in
                    sourceRow(symbol: "clock.arrow.circlepath", title: "Restore backup from \(Self.when(backup.createdAt))",
                              detail: Self.backupDetail(backup), note: nil, enabled: true) {
                        bootstrap.choose(.backup(id: backup.id))
                    }
                }
                if let error = bootstrap.error {
                    GateError(text: error)
                }
                GateLink(label: "Start a new library") { bootstrap.choose(.new) }
                    .padding(.top, 16)
            }
            .padding(.horizontal, 32)
        }
    }

    private func sourceRow(symbol: String, title: String, detail: String, note: String?, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(enabled ? theme.sage : theme.ink3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Typography.uiBody().weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.leading)
                    if let note {
                        Text(note)
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.accent)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(ButtonPressStyle())
        .disabled(!enabled)
    }

    static func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func backupDetail(_ backup: CloudLibrarySync.Backup) -> String {
        var parts: [String] = []
        if !backup.reason.isEmpty { parts.append(backup.reason) }
        if !backup.sourceDevice.isEmpty { parts.append("from \(backup.sourceDevice)") }
        parts.append(size(backup.sizeBytes))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Protect Your Library

private struct ProtectLibraryForm: View {
    @Environment(AppTheme.self) private var theme
    let bootstrap: LibraryBootstrap
    let source: LibraryBootstrap.Source

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var useTor = UserDefaults.standard.bool(forKey: "useTorByDefault")

    private var subtitle: String {
        switch source {
        case .cloud: "The iCloud copy will be kept on this device in an\nencrypted database. Choose how to protect it."
        default: "Your reading history and bookmarks are stored\nin an encrypted database on this device."
        }
    }

    var body: some View {
        GatePage(symbol: "lock.shield", tint: theme.sage, title: "Protect Your Library", subtitle: subtitle) {
            VStack(spacing: 14) {
                GateField { SecureFieldWithToggle(placeholder: "Password", text: $password) }
                GateField { SecureFieldWithToggle(placeholder: "Confirm password", text: $confirmPassword) }
                if let error = error ?? bootstrap.error {
                    GateError(text: error)
                }
                GateButton(label: "Set Password", fill: theme.sage) { setPassword() }
            }
            .padding(.horizontal, 32)

            Toggle(isOn: $useTor) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(useTor ? theme.sage : theme.ink3)
                    Text("Connect via Tor on launch")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                }
            }
            .tint(theme.sage)
            .padding(.top, 16)
            .padding(.horizontal, 32)
            .onChange(of: useTor) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "useTorByDefault")
            }

            VStack(spacing: 12) {
                GateLink(label: "Skip — no password") {
                    RustBridge.promptForPassword = false
                    Task { _ = await bootstrap.createLibrary(password: nil) }
                }
                GateLink(label: "Ask me later") {
                    Task { _ = await bootstrap.createLibrary(password: nil) }
                }
                if bootstrap.hasCandidates {
                    GateLink(label: "Back") { bootstrap.backToChoices() }
                }
            }
            .padding(.top, 28)
        }
    }

    private func setPassword() {
        error = nil
        guard !password.isEmpty else { error = "Password cannot be empty."; return }
        guard password == confirmPassword else { error = "Passwords don't match."; return }
        guard password.count >= 4 else { error = "Password must be at least 4 characters."; return }
        Task { _ = await bootstrap.createLibrary(password: password) }
    }
}

// MARK: - A backup's own password

private struct BackupPasswordForm: View {
    @Environment(AppTheme.self) private var theme
    let bootstrap: LibraryBootstrap

    @State private var password = ""

    var body: some View {
        GatePage(symbol: "lock.fill", tint: theme.accent, title: "Enter Password",
                 subtitle: "This backup is protected with the password\nit was made under. Enter it to restore.") {
            VStack(spacing: 14) {
                GateField { SecureFieldWithToggle(placeholder: "Password", text: $password) }
                if let error = bootstrap.error {
                    GateError(text: error)
                }
                GateButton(label: "Restore", fill: theme.accent) { unlock() }
                GateLink(label: "Back") { bootstrap.backToChoices() }
            }
            .padding(.horizontal, 32)
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        Task { _ = await bootstrap.unlockBackup(password: password) }
    }
}
