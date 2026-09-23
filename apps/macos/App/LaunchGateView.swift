import SwiftUI

/// Pre-main-UI gate, mirroring the iOS launch flow: database setup on first
/// launch (password / skip / later + recovery key) and the unlock screen for
/// password-protected libraries. Shown as the window's content until the
/// database is open.
struct LaunchGateView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        Group {
            switch appState.bridge.launchState {
            case .firstLaunch:
                MacDatabaseSetupView(theme: theme, appState: appState)
            case .locked:
                MacDatabaseUnlockView(theme: theme, appState: appState)
            case .autoUnlock:
                theme.bg.onAppear { _ = appState.bridge.open() }
            case .connectingTor, .ready:
                // Unlocked — the window is about to swap to the main UI;
                // render only the background so nothing flashes.
                theme.bg
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}

// MARK: - First launch: find an existing library, then protect it

/// No library file yet. Before creating an empty one, look for a library
/// the user already has — the iCloud copy, or backups still on disk — and
/// let them pick (LibraryBootstrap). Whatever the source, the last step is
/// the same Protect Your Library choice.
struct MacDatabaseSetupView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var bootstrap: LibraryBootstrap?

    var body: some View {
        Group {
            if let bootstrap {
                if let key = bootstrap.recoveryKey {
                    gatePage(theme: theme, symbol: "lock.shield", tint: theme.sage, title: "Protect Your Library",
                             subtitle: "Your library is protected with your password.") {
                        RecoveryKeyBlock(theme: theme, key: key) { bootstrap.dismissRecoveryKey() }
                    }
                } else {
                    switch bootstrap.step {
                    case .probing(let text), .working(let text):
                        gatePage(theme: theme, symbol: "icloud", tint: theme.sage, title: "Looking for Your Library", subtitle: text) {
                            ProgressView().controlSize(.regular).padding(.top, 4)
                            if case .probing = bootstrap.step {
                                Button("Start a new library") { bootstrap.choose(.new) }
                                    .buttonStyle(.plain)
                                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                                    .foregroundStyle(theme.ink3)
                                    .padding(.top, 24)
                            }
                        }
                    case .choose:
                        MacLibrarySourceChooser(theme: theme, bootstrap: bootstrap)
                    case .protect(let source):
                        MacProtectLibraryForm(theme: theme, bootstrap: bootstrap, source: source)
                    case .backupPassword:
                        MacBackupPasswordForm(theme: theme, bootstrap: bootstrap)
                    }
                }
            }
        }
        .onAppear {
            guard bootstrap == nil else { return }
            let b = LibraryBootstrap(bridge: appState.bridge)
            bootstrap = b
            b.start()
        }
        .onDisappear { bootstrap?.cancelProbe() }
    }
}

// MARK: Shared gate pieces

private func gatePage<Content: View>(theme: AppTheme, symbol: String, tint: Color, title: String, subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
    GatePage(theme: theme, symbol: symbol, tint: tint, title: title, subtitle: subtitle, content: content())
}

private struct GatePage<Content: View>: View {
    @Bindable var theme: AppTheme
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(tint)
                .padding(.bottom, 16)
            Text(title)
                .font(Font(MacFont.serif(32, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)
            Text(subtitle)
                .font(Font(MacFont.ui(14, weight: .medium)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)
            content
        }
        .padding(40)
    }
}

private func gateField(theme: AppTheme, @ViewBuilder content: () -> some View) -> some View {
    content()
        .textFieldStyle(.plain)
        .font(Font(MacFont.ui(15, weight: .medium)))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
}

private struct RecoveryKeyBlock: View {
    @Bindable var theme: AppTheme
    let key: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("RECOVERY KEY")
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.9)
                .foregroundStyle(theme.ink3)
            Text(key)
                .font(.system(size: 18, design: .monospaced).weight(.bold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Write this down and keep it safe. If you forget your password, this is the only way to recover your data. It will not be shown again.")
                .font(Font(MacFont.ui(12, weight: .medium)))
                .foregroundStyle(Color(hex: "CE514D"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            GateButton(theme: theme, label: "I've saved my recovery key", fill: theme.accent, action: done)
                .padding(.top, 8)
        }
        .frame(width: 340)
    }
}

private struct GateError: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Font(MacFont.ui(12, weight: .medium)))
            .foregroundStyle(Color(hex: "CE514D"))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GateLink: View {
    @Bindable var theme: AppTheme
    let label: String
    let action: () -> Void
    var body: some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(Font(MacFont.ui(12.5, weight: .semibold)))
            .foregroundStyle(theme.ink3)
    }
}

// MARK: Choose a source

private struct MacLibrarySourceChooser: View {
    @Bindable var theme: AppTheme
    let bootstrap: LibraryBootstrap

    var body: some View {
        gatePage(theme: theme, symbol: "books.vertical", tint: theme.sage, title: "Welcome Back",
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
                GateLink(theme: theme, label: "Start a new library") { bootstrap.choose(.new) }
                    .padding(.top, 12)
            }
            .frame(width: 380)
        }
    }

    private func sourceRow(symbol: String, title: String, detail: String, note: String?, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(enabled ? theme.sage : theme.ink3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(detail)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(theme.ink3)
                    if let note {
                        Text(note)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
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

// MARK: Protect Your Library

private struct MacProtectLibraryForm: View {
    @Bindable var theme: AppTheme
    let bootstrap: LibraryBootstrap
    let source: LibraryBootstrap.Source

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var useTor = UserDefaults.standard.bool(forKey: "useTorByDefault")

    private var subtitle: String {
        switch source {
        case .cloud: "The iCloud copy will be kept on this Mac in an\nencrypted database. Choose how to protect it."
        default: "Your reading history and bookmarks are stored\nin an encrypted database on this device."
        }
    }

    var body: some View {
        gatePage(theme: theme, symbol: "lock.shield", tint: theme.sage, title: "Protect Your Library", subtitle: subtitle) {
            VStack(spacing: 14) {
                gateField(theme: theme) { SecureField("Password", text: $password) }
                gateField(theme: theme) { SecureField("Confirm password", text: $confirmPassword).onSubmit { setPassword() } }
                if let error = error ?? bootstrap.error {
                    GateError(text: error)
                }
                GateButton(theme: theme, label: "Set Password", fill: theme.sage) { setPassword() }
            }
            .frame(width: 340)

            Toggle(isOn: $useTor) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(useTor ? theme.sage : theme.ink3)
                    Text("Connect via Tor on launch")
                        .font(Font(MacFont.ui(13.5, weight: .medium)))
                        .foregroundStyle(theme.ink)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.sage)
            .padding(.top, 18)
            .onChange(of: useTor) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "useTorByDefault")
            }

            VStack(spacing: 10) {
                GateLink(theme: theme, label: "Skip — no password") {
                    RustBridge.promptForPassword = false
                    Task { _ = await bootstrap.createLibrary(password: nil) }
                }
                GateLink(theme: theme, label: "Ask me later") {
                    Task { _ = await bootstrap.createLibrary(password: nil) }
                }
                if bootstrap.hasCandidates {
                    GateLink(theme: theme, label: "Back") { bootstrap.backToChoices() }
                }
            }
            .padding(.top, 24)
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

// MARK: A backup's own password

private struct MacBackupPasswordForm: View {
    @Bindable var theme: AppTheme
    let bootstrap: LibraryBootstrap

    @State private var password = ""

    var body: some View {
        gatePage(theme: theme, symbol: "lock.fill", tint: theme.accent, title: "Enter Password",
                 subtitle: "This backup is protected with the password\nit was made under. Enter it to restore.") {
            VStack(spacing: 14) {
                gateField(theme: theme) { SecureField("Password", text: $password).onSubmit { unlock() } }
                if let error = bootstrap.error {
                    GateError(text: error)
                }
                GateButton(theme: theme, label: "Restore", fill: theme.accent) { unlock() }
                GateLink(theme: theme, label: "Back") { bootstrap.backToChoices() }
            }
            .frame(width: 340)
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        Task { _ = await bootstrap.unlockBackup(password: password) }
    }
}

// MARK: - Locked: Enter Password

struct MacDatabaseUnlockView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var password = ""
    @State private var error: String?
    @State private var showRecovery = false
    @State private var recoveryKeyInput = ""
    @State private var showWipeConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.bottom, 16)
            Text("Enter Password")
                .font(Font(MacFont.serif(32, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)
            Text("Your library is encrypted.\nEnter your password to unlock it.")
                .font(Font(MacFont.ui(14, weight: .medium)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                if !showRecovery {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .font(Font(MacFont.ui(15, weight: .medium)))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
                        .onSubmit { unlock() }

                    if let error {
                        Text(error)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(Color(hex: "CE514D"))
                    }

                    GateButton(theme: theme, label: "Unlock", fill: theme.accent) { unlock() }

                    if RecoveryKey.hasRecoveryKey {
                        Button("Forgot password?") {
                            showRecovery = true
                            error = nil
                        }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(12.5, weight: .semibold)))
                        .foregroundStyle(theme.ink3)
                    }
                    Button("Reset database") {
                        showWipeConfirm = true
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(Color(hex: "CE514D"))
                } else {
                    Text("Enter your recovery key to unlock.")
                        .font(Font(MacFont.ui(12.5, weight: .medium)))
                        .foregroundStyle(theme.ink3)
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $recoveryKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
                        .onSubmit { recoverWithKey() }

                    if let error {
                        Text(error)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(Color(hex: "CE514D"))
                    }

                    GateButton(theme: theme, label: "Recover", fill: theme.sage) { recoverWithKey() }
                    Button("Back to password") {
                        showRecovery = false
                        error = nil
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
                }
            }
            .frame(width: 340)
        }
        .padding(40)
        .alert("Reset Database?", isPresented: $showWipeConfirm) {
            Button("Reset", role: .destructive) {
                RecoveryKey.wipeDatabase()
                appState.bridge.isInitialized = false
                appState.bridge.hasDbPassword = false
                RustBridge.persistDbPasswordFlag(false)
                RustBridge.promptForPassword = true
                UserDefaults.standard.set(false, forKey: "useTorByDefault")
                RecoveryKey.resetFailureCount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all your bookmarks, reading history, progress, and downloaded works. This cannot be undone.")
        }
    }

    private func unlock() {
        error = nil
        if appState.bridge.open(userPassword: password) {
            RecoveryKey.resetFailureCount()
        } else {
            // Only a rejected key is a password attempt. Anything else
            // (schema newer than this build, damaged file) shows its real
            // message and leaves the attempt counter and the typed
            // password alone.
            if let failure = appState.bridge.lastOpenFailure, failure != .wrongPassword {
                error = failure.message
                return
            }
            RecoveryKey.recordFailure()
            if RecoveryKey.shouldWipe() {
                RecoveryKey.wipeDatabase()
                appState.bridge.hasDbPassword = false
                RustBridge.persistDbPasswordFlag(false)
                _ = appState.bridge.createWithAutoKey()
                return
            }
            let remaining = RecoveryKey.wipeThreshold > 0
                ? " (\(RecoveryKey.wipeThreshold - RecoveryKey.failureCount) attempts remaining)"
                : ""
            error = "Wrong password.\(remaining)"
            password = ""
        }
    }

    private func recoverWithKey() {
        error = nil
        guard let blob = RecoveryKey.loadEncryptedBlob() else {
            error = "No recovery data found."
            return
        }
        let key = recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let recovered = RecoveryKey.decryptPassword(fromBlob: blob, withRecoveryKey: key) else {
            error = "Invalid recovery key."
            return
        }
        if appState.bridge.open(userPassword: recovered) {
            RecoveryKey.resetFailureCount()
        } else {
            error = appState.bridge.lastOpenFailure?.message ?? "Recovery failed — database may be corrupted."
        }
    }
}

struct GateButton: View {
    @Bindable var theme: AppTheme
    let label: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(14.5, weight: .bold)))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
