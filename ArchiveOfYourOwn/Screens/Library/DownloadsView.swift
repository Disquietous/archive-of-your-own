import SwiftUI

struct DownloadsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var showFilters = false
    @State private var filterTitle = ""
    @State private var filterTag = ""
    @State private var filterAuthor = ""
    @State private var filterWordCount = ""
    @State private var filterRating: Rating? = nil
    @State private var filterKudos = ""
    @State private var filterPublishDate = ""
    @State private var filterUpdatedDate = ""

    private var allWorks: [Work] {
        state.allKnownWorks.filter { state.downloadedWorkIDs.contains($0.id) }
    }

    private var filteredWorks: [Work] {
        allWorks.filter { work in
            if !filterTitle.isEmpty && !work.title.localizedCaseInsensitiveContains(filterTitle) {
                return false
            }
            if !filterTag.isEmpty && !work.tags.contains(where: { $0.localizedCaseInsensitiveContains(filterTag) }) {
                return false
            }
            if !filterAuthor.isEmpty && !work.author.localizedCaseInsensitiveContains(filterAuthor) {
                return false
            }
            if let rating = filterRating, work.rating != rating {
                return false
            }
            if !filterWordCount.isEmpty && !matchesRange(filterWordCount, value: work.words) {
                return false
            }
            if !filterKudos.isEmpty && !matchesRange(filterKudos, value: work.kudos) {
                return false
            }
            return true
        }
    }

    private var hasActiveFilters: Bool {
        !filterTitle.isEmpty || !filterTag.isEmpty || !filterAuthor.isEmpty ||
        !filterWordCount.isEmpty || filterRating != nil || !filterKudos.isEmpty ||
        !filterPublishDate.isEmpty || !filterUpdatedDate.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    Spacer()
                        .frame(height: 56)

                    if filteredWorks.isEmpty {
                        EmptyStateView(
                            systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle" : "arrow.down.circle",
                            title: hasActiveFilters ? "No matches" : "No downloads",
                            subtitle: hasActiveFilters ? "Try changing your filters." : "Works you download will appear here for offline reading."
                        )
                        .padding(.top, 40)
                    } else {
                        if hasActiveFilters {
                            Text("\(filteredWorks.count) of \(allWorks.count) works")
                                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                                .foregroundStyle(theme.ink3)
                                .padding(.horizontal, theme.pad)
                        }

                        LazyVStack(spacing: theme.rowGap) {
                            ForEach(filteredWorks) { work in
                                WorkCardView(
                                    work: work,
                                    blurExplicit: state.hideExplicit && work.rating == .explicit,
                                    onTap: { nav.openWork(work.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
            }

            VStack(spacing: 0) {
                topChrome

                if showFilters {
                    filterForm
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
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

            Text("Downloaded Works")
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFilters.toggle()
                }
            } label: {
                Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(hasActiveFilters ? theme.accent : theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

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

    private var filterForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterField("Title", text: $filterTitle, placeholder: "Search titles...")
            filterField("Author", text: $filterAuthor, placeholder: "Search authors...")
            filterField("Tags", text: $filterTag, placeholder: "Search tags...")

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Words")
                        .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                    TextField(">1000, <50000, 1000-5000", text: $filterWordCount)
                        .font(.custom("HankenGrotesk", size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Kudos")
                        .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                    TextField(">100, <1000", text: $filterKudos)
                        .font(.custom("HankenGrotesk", size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rating")
                        .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                    Picker("", selection: $filterRating) {
                        Text("Any").tag(nil as Rating?)
                        Text("General").tag(Rating.general as Rating?)
                        Text("Teen").tag(Rating.teen as Rating?)
                        Text("Mature").tag(Rating.mature as Rating?)
                        Text("Explicit").tag(Rating.explicit as Rating?)
                    }
                    .pickerStyle(.menu)
                    .tint(theme.ink)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                }

                if hasActiveFilters {
                    Button {
                        clearFilters()
                    } label: {
                        Text("Clear All")
                            .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .frame(height: 34)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.accent, lineWidth: 1)
                            )
                    }
                    .padding(.top, 15)
                }
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.vertical, 12)
        .background(
            theme.bg.opacity(0.98)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }

    private func filterField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                .foregroundStyle(theme.ink3)
            TextField(placeholder, text: text)
                .font(.custom("HankenGrotesk", size: 13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        }
    }

    private func clearFilters() {
        filterTitle = ""
        filterTag = ""
        filterAuthor = ""
        filterWordCount = ""
        filterRating = nil
        filterKudos = ""
        filterPublishDate = ""
        filterUpdatedDate = ""
    }

    private func matchesRange(_ input: String, value: Int) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            guard let threshold = Int(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else { return true }
            return value > threshold
        }
        if trimmed.hasPrefix("<") {
            guard let threshold = Int(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else { return true }
            return value < threshold
        }
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
                return value >= low && value <= high
            }
        }
        if let exact = Int(trimmed) {
            return value == exact
        }
        return true
    }
}
