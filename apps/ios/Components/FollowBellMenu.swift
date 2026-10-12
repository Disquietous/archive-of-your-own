import SwiftUI

/// The follow bell for an author, work or series: tapping opens a two-item
/// menu — Followed and Subscribed — with checkmarks like the reading-list
/// menu. Following is local and silent; anything that touches AO3 asks
/// first (FollowModel builds the wording, which names both effects).
/// Subscribed implies Followed. Fandoms keep a plain toggle elsewhere.
struct FollowBellMenu: View {
    @Environment(AppTheme.self) private var theme
    @Environment(FollowModel.self) private var follows

    let target: FollowModel.Target
    var glyphSize: CGFloat = 13
    var weight: Font.Weight = .semibold
    var hitSize: CGFloat = 28

    @State private var pending: FollowModel.Confirmation?

    var body: some View {
        let state = follows.state(target)
        let shaded = follows.isShaded(target)
        Menu {
            Button {
                handle(.followed)
            } label: {
                if state.followed {
                    Label("Followed", systemImage: "checkmark")
                } else {
                    Text("Followed")
                }
            }
            Button {
                handle(.subscribed)
            } label: {
                if state.subscribed {
                    Label("Subscribed", systemImage: "checkmark")
                } else {
                    Text("Subscribed")
                }
                if !follows.canSubscribe(target) {
                    Text("Sign in to subscribe on AO3")
                }
            }
            .disabled(!follows.canSubscribe(target) || follows.isBusy(target))
        } label: {
            Group {
                if follows.isBusy(target) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: shaded ? "bell.fill" : "bell")
                        .font(.system(size: glyphSize, weight: weight))
                        .foregroundStyle(shaded ? theme.accent : theme.ink3)
                }
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("Follow options for \(target.name)")
        .confirmationDialog(pending?.title ?? "", isPresented: pendingBinding,
                            titleVisibility: .visible, presenting: pending) { confirmation in
            ForEach(confirmation.options) { option in
                Button(option.label, role: option.isDestructive ? .destructive : nil) {
                    follows.apply(option, to: confirmation.target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private func handle(_ item: FollowModel.MenuItem) {
        if case .confirm(let confirmation) = follows.toggle(item, for: target) {
            pending = confirmation
        }
    }
}

/// The transient notice FollowModel posts after a bell-menu change —
/// shown at the app root, gone after a few seconds.
struct FollowNoticeBanner: View {
    @Environment(AppTheme.self) private var theme
    @Environment(FollowModel.self) private var follows

    var body: some View {
        if let notice = follows.notice {
            HStack(spacing: 8) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(notice.isError ? theme.onAccent : theme.accent)
                Text(notice.message)
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(notice.isError ? theme.onAccent : theme.ink)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(notice.isError ? Color.red.opacity(0.85) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: notice.isError ? 0 : 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .onTapGesture { follows.clearNotice() }
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.isError ? 6 : 4))
                if follows.notice?.id == notice.id { follows.clearNotice() }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension FollowModel {
    /// Follows the What's New check covers (authors, works, series) — the
    /// Following screen's count.
    var checkedFollowCount: Int {
        follows.filter { $0.kind != Kind.fandom.rawValue }.count
    }
}
