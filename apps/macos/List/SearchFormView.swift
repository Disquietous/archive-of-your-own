import SwiftUI

/// The Search section's full-width criteria form (the list pane is
/// collapsed while searching). Fields are AO3's own search form (scraped
/// and stored in the database), laid out to use the width: compact scalar
/// fields flow into an adaptive multi-column grid, and the chip groups
/// (ratings, warnings, categories, …) sit side by side beneath them.
struct SearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        @Bindable var search = model.search
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                queryField

                if search.isLoadingForm {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading criteria from the archive…")
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink3)
                    }
                } else if let error = search.formError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(Color(hex: "CE514D"))
                        Button("Retry") {
                            Task { await search.scrapeForm(appState) }
                        }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(11.5, weight: .bold)))
                        .foregroundStyle(theme.accent)
                    }
                } else if search.formFields.isEmpty {
                    Text("Search criteria haven’t been loaded yet. Use the ↻ button above to fetch them from AO3.")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if search.activeFilterCount > 0 {
                        HStack {
                            Text(search.activeFilterCount == 1
                                 ? "1 filter active"
                                 : "\(search.activeFilterCount) filters active")
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(theme.accent)
                            Spacer()
                            Button("Clear") { search.clearFilters() }
                                .buttonStyle(.plain)
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(theme.ink3)
                        }
                    }
                    let scalarFields = search.filterFields.filter { !Self.isChipGroup($0) }
                    let chipGroups = search.filterFields.filter { Self.isChipGroup($0) }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 420),
                                           spacing: 18, alignment: .topLeading)],
                        alignment: .leading, spacing: 14
                    ) {
                        ForEach(scalarFields, id: \.name) { field in
                            fieldControl(field)
                        }
                    }

                    if !chipGroups.isEmpty {
                        Divider().padding(.vertical, 4)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280, maximum: 520),
                                               spacing: 18, alignment: .topLeading)],
                            alignment: .leading, spacing: 20
                        ) {
                            ForEach(chipGroups, id: \.name) { field in
                                fieldControl(field)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// Chip-cloud groups get their own grid — they're tall and variable,
    /// and mixing them with 30-pt scalar controls leaves ragged holes.
    /// Radio groups (Completion status, Crossovers) render as dropdowns,
    /// so they live with the scalars.
    private static func isChipGroup(_ field: UFormField) -> Bool {
        field.fieldType == "checkboxes"
    }

    @ViewBuilder
    private func fieldControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        if let tagType = Self.tagType(for: field.name) {
            TagTokenField(theme: theme, appState: appState,
                          label: field.label, tagType: tagType,
                          value: Binding(
                              get: { search.fieldValues[field.name] ?? "" },
                              set: { search.fieldValues[field.name] = $0 }))
        } else {
            switch field.fieldType {
            case "select":
                selectControl(field)
            case "checkboxes":
                checkboxControl(field)
            case "radio":
                radioControl(field)
            default:
                textControl(field)
            }
        }
    }

    private var queryField: some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            Text("QUERY")
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Any field — title, author, tags…", text: $search.queryText)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .onSubmit { search.performSearch(appState) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
    }

    /// AO3's canonical-tag inputs get the token field with local-cache
    /// autocomplete; everything else renders as before.
    static func tagType(for fieldName: String) -> String? {
        switch fieldName {
        case "work_search[fandom_names]": "fandom"
        case "work_search[character_names]": "character"
        case "work_search[relationship_names]": "relationship"
        case "work_search[freeform_names]": "freeform"
        case "work_search[creators]": "creator"
        default: nil
        }
    }

    private func fieldLabel(_ field: UFormField) -> some View {
        Text(field.label.uppercased())
            .font(Font(MacFont.ui(10.5, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
    }

    /// AO3 selects mark their no-filter option with a blank label (the
    /// language select's is literally empty) — surface those as "Any" so the
    /// control always shows a value.
    private static func optionTitle(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Any" : trimmed
    }

    private func selectControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        let current = search.fieldValues[field.name] ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            dropdownMenu(field, current: current) {
                search.fieldValues[field.name] = $0
            }
        }
    }

    /// A themed control with NSPopUpButton's visual grammar: the value on
    /// a bordered field, chevrons on an accent thumb tab at the right edge.
    /// Clicking anywhere on the control pops a real NSMenu (native
    /// checkmarks, keyboard navigation, scrolling for long lists).
    private func dropdownMenu(_ field: UFormField, current: String,
                              onPick: @escaping (String) -> Void) -> some View {
        DropdownControl(
            theme: theme,
            title: Self.optionTitle(
                field.options.first { $0.value == current }?.label
                    ?? field.options.first?.label ?? ""),
            options: field.options.map {
                (label: Self.optionTitle($0.label), value: $0.value, checked: $0.value == current)
            },
            onPick: onPick)
    }

    /// AO3 radio groups (Completion status, Crossovers): exactly one choice
    /// active at a time, rendered as a dropdown like the selects. The
    /// scraped `selected` flag supplies the default (AO3 pre-checks the
    /// no-filter option), so the control always shows a value.
    private func radioControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        let defaultValue = field.options.first { $0.selected }?.value
            ?? field.options.first?.value ?? ""
        let current = search.fieldValues[field.name] ?? defaultValue
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            dropdownMenu(field, current: current) {
                search.fieldValues[field.name] = $0
            }
        }
    }

    private func checkboxControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            FlowLayout(spacing: 6) {
                ForEach(field.options, id: \.value) { option in
                    let on = search.checkboxValues[field.name]?.contains(option.value) ?? false
                    Button {
                        var set = search.checkboxValues[field.name] ?? []
                        if on { set.remove(option.value) } else { set.insert(option.value) }
                        search.checkboxValues[field.name] = set
                    } label: {
                        Text(option.label)
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(on ? theme.onAccent : theme.ink2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(on ? theme.accent : theme.surface2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func textControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            TextField(Self.placeholderHint(for: field), text: Binding(
                        get: { search.fieldValues[field.name] ?? "" },
                        set: { search.fieldValues[field.name] = $0 }
                      ))
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .onSubmit { search.performSearch(appState) }
                .help(Self.rangeHelp(for: field) ?? field.label)
        }
    }

    /// AO3's stat fields silently accept range syntax; the scraped form
    /// carries no placeholders, so surface the syntax here.
    private static let rangeFieldSuffixes = [
        "[word_count]", "[hits]", "[kudos_count]", "[comments_count]", "[bookmarks_count]",
    ]

    private static func placeholderHint(for field: UFormField) -> String {
        if !field.placeholder.isEmpty { return field.placeholder }
        if rangeFieldSuffixes.contains(where: { field.name.hasSuffix($0) }) {
            return ">1000 · <500 · 100-5000"
        }
        if field.name.hasSuffix("[revised_at]") {
            return "e.g. 2024, or < 2 weeks ago"
        }
        return field.label
    }

    private static func rangeHelp(for field: UFormField) -> String? {
        if rangeFieldSuffixes.contains(where: { field.name.hasSuffix($0) }) {
            return "Exact number, or a range: >1000 (more than), <500 (fewer than), 100-5000 (between)"
        }
        if field.name.hasSuffix("[revised_at]") {
            return "A date (2024-01), or relative: < 2 weeks ago, > 3 months ago"
        }
        return nil
    }
}

/// Themed dropdown: a plain SwiftUI Button (whole control is clickable,
/// custom chrome survives) that pops a native NSMenu anchored to itself.
private struct DropdownControl: View {
    @Bindable var theme: AppTheme
    let title: String
    let options: [(label: String, value: String, checked: Bool)]
    let onPick: (String) -> Void

    @State private var anchorView: NSView?
    @State private var picker = MenuPicker()

    var body: some View {
        Button {
            presentMenu()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(Font(MacFont.ui(12.5, weight: .medium)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.accent)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                    )
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(AnchorCapture(view: $anchorView))
    }

    private func presentMenu() {
        guard let anchor = anchorView else { return }
        picker.onPick = onPick
        let menu = NSMenu()
        var selectedItem: NSMenuItem?
        for option in options {
            let item = NSMenuItem(title: option.label,
                                  action: #selector(MenuPicker.pick(_:)),
                                  keyEquivalent: "")
            item.target = picker
            item.representedObject = option.value
            item.state = option.checked ? .on : .off
            if option.checked { selectedItem = item }
            menu.addItem(item)
        }
        menu.minimumWidth = anchor.bounds.width
        // NSPopUpButton behavior: open with the current selection over the control.
        menu.popUp(positioning: selectedItem ?? menu.items.first,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }
}

/// Retained menu target — NSMenuItem targets are weak.
private final class MenuPicker: NSObject {
    var onPick: ((String) -> Void)?
    @objc func pick(_ sender: NSMenuItem) {
        onPick?(sender.representedObject as? String ?? "")
    }
}

/// Grabs the backing NSView so the menu can anchor to the control's frame.
private struct AnchorCapture: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
