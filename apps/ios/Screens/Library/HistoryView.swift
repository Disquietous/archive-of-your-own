import SwiftUI

struct HistoryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirmation = false

    private var todayWorks: [Work] {
        Array(state.historyWorks.prefix(1))
    }

    private var earlierWorks: [Work] {
        Array(state.historyWorks.dropFirst())
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    Spacer()
                        .frame(height: 56)

                    if state.historyWorks.isEmpty {
                        EmptyStateView(
                            systemImage: "clock",
                            title: "Nothing read yet",
                            subtitle: "Your reading history stays on this device, encrypted."
                        )
                        .padding(.top, 40)
                    } else {
                        if !todayWorks.isEmpty {
                            SectionHeaderView(title: "Today")
                                .padding(.horizontal, theme.pad)

                            LazyVStack(spacing: theme.rowGap) {
                                ForEach(todayWorks) { work in
                                    WorkCardView(
                                        work: work,
                                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                                        onTap: { nav.openWork(work.id) }
                                    )
                                }
                            }
                            .padding(.horizontal, theme.pad)
                        }

                        if !earlierWorks.isEmpty {
                            SectionHeaderView(title: "Earlier This Week")
                                .padding(.horizontal, theme.pad)

                            LazyVStack(spacing: theme.rowGap) {
                                ForEach(earlierWorks) { work in
                                    WorkCardView(
                                        work: work,
                                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                                        onTap: { nav.openWork(work.id) }
                                    )
                                }
                            }
                            .padding(.horizontal, theme.pad)
                        }

                        Button {
                            showClearConfirmation = true
                        } label: {
                            Text("Clear history")
                                .font(Typography.smallButtonLabel())
                                .foregroundStyle(theme.ink2)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.button)
                                        .stroke(theme.line, lineWidth: 1)
                                )
                        }
                        .buttonStyle(ButtonPressStyle())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, theme.pad)
            }

            topChrome
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Clear History", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                state.history.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear your reading history? This cannot be undone.")
        }
    }

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Text("History")
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)

            Spacer()

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }
}
