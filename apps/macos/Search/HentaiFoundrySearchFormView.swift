import SwiftUI

/// The Hentai Foundry tab: the site's story search, laid out for that
/// site. Query and scope, the form's limits (length, completion,
/// category, username), and its "Limit Rating" block behind a disclosure:
/// a direction and level for each graded content kind, and chips for the
/// yes/no kinds (click once to require, twice to block). Go packs it into
/// the generic query the core hands to the adapter.
struct HentaiFoundrySearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        @Bindable var form = model.hentaiFoundrySearch
        SearchFormScroll {
            VStack(alignment: .leading, spacing: 16) {
                queryField

                if form.activeFilterCount > 0 {
                    HStack {
                        Text(form.activeFilterCount == 1 ? "1 limit active" : "\(form.activeFilterCount) limits active")
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.accent)
                        Spacer()
                        Button("Clear") { form.clear() }
                            .buttonStyle(.plain)
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.ink3)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18, alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    labelled("Search In") {
                        dropdown("search_in", value: form.searchIn, any: nil) { form.searchIn = $0 }
                    }
                    labelled("Limit Length") {
                        HStack(spacing: 6) {
                            dropdown("length_compare", value: form.lengthCompare, any: nil) { form.lengthCompare = $0 }
                                .frame(maxWidth: 120)
                            textBox("any", $form.length)
                            dropdown("length_unit", value: form.lengthUnit, any: nil) { form.lengthUnit = $0 }
                                .frame(maxWidth: 90)
                        }
                    }
                    labelled("Completion Status") {
                        dropdown("status", value: form.status, any: "Any") { form.status = $0 }
                    }
                    labelled("Category") {
                        VStack(alignment: .leading, spacing: 6) {
                            dropdown("category", value: form.category, any: "Any") { form.category = $0 }
                            Toggle("Include subcategories", isOn: $form.includeSubcategories)
                                .toggleStyle(.checkbox)
                                .font(Font(MacFont.ui(11.5)))
                                .foregroundStyle(theme.ink2)
                                .disabled(form.category.isEmpty)
                        }
                    }
                    labelled("Username") {
                        VStack(alignment: .leading, spacing: 4) {
                            textBox("stories by this user", $form.username)
                                .onChange(of: form.username) { form.usernameChanged(appState) }
                            if !form.usernameSuggestions.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(form.usernameSuggestions, id: \.self) { name in
                                        Button { form.pickUsername(name) } label: {
                                            Text(name)
                                                .font(Font(MacFont.ui(12.5)))
                                                .foregroundStyle(theme.ink)
                                                .lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 3)
                                .background(theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                                .revealedInForm(when: form.usernameSuggestions, onAppear: true)
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { form.showRating.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: form.showRating ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("LIMIT RATING")
                            .font(Font(MacFont.ui(11, weight: .bold)))
                            .kerning(0.8)
                    }
                    .foregroundStyle(theme.ink2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if form.showRating {
                    rating
                        .revealedInForm(when: true, onAppear: true, anchor: .top)
                }

                Text("Results follow the content filters and order saved in your Hentai Foundry account.")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .task { form.loadIfNeeded(appState) }
    }

    // MARK: Pieces

    private var queryField: some View {
        @Bindable var form = model.hentaiFoundrySearch
        return VStack(alignment: .leading, spacing: 5) {
            caption("Search Query")
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Search stories…", text: $form.text)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .onSubmit { form.run(model.search, appState: appState) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
    }

    private var rating: some View {
        let form = model.hentaiFoundrySearch
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 18, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                ForEach(HentaiFoundrySearchModel.gradedKinds, id: \.self) { kind in
                    let current = form.levels[kind] ?? HentaiFoundrySearchModel.Level()
                    labelled(form.kindLabel(kind)) {
                        HStack(spacing: 6) {
                            dropdown("\(kind)_limit", value: current.limit, any: "Ignore") { picked in
                                var next = current
                                next.limit = picked
                                form.levels[kind] = next
                            }
                            .frame(maxWidth: 120)
                            dropdown("\(kind)_level", value: current.level, any: nil) { picked in
                                var next = current
                                next.level = picked
                                form.levels[kind] = next
                            }
                            .disabled(current.limit.isEmpty)
                            .opacity(current.limit.isEmpty ? 0.5 : 1)
                        }
                    }
                }
            }

            labelled("Content") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Click once to require, twice to block")
                        .font(Font(MacFont.ui(10.5)))
                        .foregroundStyle(theme.ink3)
                    FlowLayout(spacing: 6) {
                        ForEach(form.options("flags"), id: \.value) { option in
                            let required = form.required.contains(option.value)
                            let blocked = form.blocked.contains(option.value)
                            Button { form.cycle(option.value) } label: {
                                HStack(spacing: 3) {
                                    if blocked { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
                                    Text(option.label).strikethrough(blocked)
                                }
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(required ? theme.onAccent : (blocked ? theme.ink3 : theme.ink2))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(required ? theme.accent : theme.surface2)
                                .overlay(Capsule().stroke(blocked ? theme.ink3 : .clear, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(required ? "Required — click to block" : (blocked ? "Blocked — click to allow" : "Allowed — click to require"))
                        }
                    }
                }
            }
        }
    }

    /// One of the form's fixed lists. `any` names the empty choice when
    /// the field has one.
    private func dropdown(_ key: String, value: String, any: String?, onPick: @escaping (String) -> Void) -> some View {
        let form = model.hentaiFoundrySearch
        var options: [(label: String, value: String, checked: Bool)] = form.options(key).map { ($0.label, $0.value, $0.value == value) }
        if let any { options.insert((any, "", value.isEmpty), at: 0) }
        let title = value.isEmpty ? (any ?? "") : form.label(key, value)
        return DropdownControl(theme: theme, title: title, options: options, onPick: onPick)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Font(MacFont.ui(10.5, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(title)
            content()
        }
    }

    private func textBox(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Font(MacFont.ui(12.5)))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .onSubmit { model.hentaiFoundrySearch.run(model.search, appState: appState) }
    }
}
