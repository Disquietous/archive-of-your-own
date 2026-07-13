import SwiftUI
import PhotosUI

struct ThemeEditorSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var customThemes: [ThemeDefinition] = []
    @State private var saveThemeName = ""
    @State private var showingSaveAlert = false
    @State private var showingDeleteAlert = false
    @State private var showingImportPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    // Local editing copy that drives live preview
    @State private var editingTheme: ThemeDefinition = PresetThemes.paper

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    themeSelectorSection
                    backgroundSection
                    colorsSection
                    typographySection
                    layoutSection
                    readerSection
                    actionsSection

                    if !editingTheme.isBuiltIn {
                        deleteSection
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
            }
            .background { ThemeBackgroundView() }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.accent)
                }
            }
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            editingTheme = theme.activeTheme
            loadCustomThemes()
        }
        .onChange(of: editingTheme) { _, newValue in
            theme.updateActiveTheme { $0 = newValue }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            handlePhotoPick(newItem)
        }
        .alert("Save Theme", isPresented: $showingSaveAlert) {
            TextField("Theme name", text: $saveThemeName)
            Button("Save") { saveCustomTheme() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a name for your custom theme.")
        }
        .alert("Delete Theme", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) { deleteCurrentTheme() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \"\(editingTheme.name)\"? This cannot be undone.")
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
    }

    // MARK: - Theme Selector

    private var themeSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("THEME")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(allThemes) { def in
                        themeCard(def)
                    }
                }
                .padding(.horizontal, theme.pad)
            }
        }
    }

    private var allThemes: [ThemeDefinition] {
        PresetThemes.all + customThemes
    }

    private func themeCard(_ def: ThemeDefinition) -> some View {
        let isSelected = def.id == editingTheme.id
        return Button {
            editingTheme = def
        } label: {
            VStack(spacing: 6) {
                // Color swatch preview
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: def.bgColor))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color(hex: def.accent))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color(hex: def.ink))
                        .frame(width: 14, height: 14)
                }

                Text(def.name)
                    .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: def.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background Section

    private var backgroundSection: some View {
        editorGroup(title: "Background") {
            SegmentedControlView(
                selection: Binding(
                    get: { editingTheme.backgroundType },
                    set: { editingTheme.backgroundType = $0 }
                ),
                items: [
                    (key: BackgroundType.solid, label: "Solid"),
                    (key: BackgroundType.image, label: "Image"),
                    (key: BackgroundType.tiledPattern, label: "Pattern"),
                ]
            )

            if editingTheme.backgroundType == .solid {
                ThemeColorWell(label: "Background Color", hexColor: $editingTheme.bgColor)
            } else {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack {
                        Text(editingTheme.backgroundImageName != nil ? "Change Image" : "Select Image")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.accent)
                        Spacer()
                        Image(systemName: "photo")
                            .foregroundStyle(theme.accent)
                    }
                }

                HStack {
                    Text("Dim Opacity")
                        .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text("\(Int(editingTheme.backgroundDimOpacity * 100))%")
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 40, alignment: .trailing)
                }

                Slider(
                    value: $editingTheme.backgroundDimOpacity,
                    in: 0...1,
                    step: 0.01
                )
                .tint(theme.accent)
            }
        }
    }

    // MARK: - Colors Section

    private var colorsSection: some View {
        editorGroup(title: "Colors") {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ], spacing: 14) {
                ThemeColorWell(label: "Background", hexColor: $editingTheme.bgColor)
                ThemeColorWell(label: "Text", hexColor: $editingTheme.ink)
                ThemeColorWell(label: "Secondary", hexColor: $editingTheme.ink2)
                ThemeColorWell(label: "Tertiary", hexColor: $editingTheme.ink3)
                ThemeColorWell(label: "Accent", hexColor: $editingTheme.accent)
                ThemeColorWell(label: "Surface", hexColor: $editingTheme.surface)
                ThemeColorWell(label: "Border", hexColor: $editingTheme.line)
                ThemeColorWell(label: "Status", hexColor: $editingTheme.sage)
            }
        }
    }

    // MARK: - Typography Section

    private var typographySection: some View {
        editorGroup(title: "Typography") {
            HStack {
                Text("UI Font")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Picker("", selection: $editingTheme.uiFontFamily) {
                    Text("Hanken Grotesk").tag("HankenGrotesk")
                    Text("System").tag("System")
                }
                .labelsHidden()
                .tint(theme.accent)
            }

            Divider().foregroundStyle(theme.line)

            HStack {
                Text("Title Font")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Picker("", selection: $editingTheme.titleFontFamily) {
                    Text("Newsreader").tag("Newsreader")
                    Text("System").tag("System")
                }
                .labelsHidden()
                .tint(theme.accent)
            }
        }
    }

    // MARK: - Layout Section

    private var layoutSection: some View {
        editorGroup(title: "Layout") {
            VStack(spacing: 4) {
                HStack {
                    Text("Card Corner Radius")
                        .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text("\(Int(editingTheme.cardCornerRadius))")
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.ink2)
                }

                Slider(
                    value: $editingTheme.cardCornerRadius,
                    in: 8...28,
                    step: 1
                )
                .tint(theme.accent)
            }

            Divider().foregroundStyle(theme.line)

            HStack {
                Text("Card Border")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink)
                Spacer()
            }

            SegmentedControlView(
                selection: Binding(
                    get: { editingTheme.cardBorderStyle },
                    set: { editingTheme.cardBorderStyle = $0 }
                ),
                items: [
                    (key: CardBorderStyle.bordered, label: "Bordered"),
                    (key: CardBorderStyle.borderless, label: "Borderless"),
                    (key: CardBorderStyle.shadow, label: "Shadow"),
                ]
            )
        }
    }

    // MARK: - Reader Section

    private var readerSection: some View {
        editorGroup(title: "Reader") {
            let hasCustomReader = editingTheme.readerBgColor != nil

            ToggleRowView(isOn: Binding(
                get: { hasCustomReader },
                set: { enabled in
                    if enabled {
                        editingTheme.readerBgColor = editingTheme.bgColor
                        editingTheme.readerInkColor = editingTheme.ink
                    } else {
                        editingTheme.readerBgColor = nil
                        editingTheme.readerInkColor = nil
                    }
                }
            )) {
                Text("Custom reader colors")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink)
            }

            if hasCustomReader {
                Divider().foregroundStyle(theme.line)

                ThemeColorWell(
                    label: "Reader Background",
                    hexColor: Binding(
                        get: { editingTheme.readerBgColor ?? editingTheme.bgColor },
                        set: { editingTheme.readerBgColor = $0 }
                    )
                )

                ThemeColorWell(
                    label: "Reader Text",
                    hexColor: Binding(
                        get: { editingTheme.readerInkColor ?? editingTheme.ink },
                        set: { editingTheme.readerInkColor = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        editorGroup(title: "Actions") {
            Button {
                saveThemeName = editingTheme.isBuiltIn ? "" : editingTheme.name
                showingSaveAlert = true
            } label: {
                HStack {
                    Text("Save as Custom Theme")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.accent)
                    Spacer()
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(.plain)

            Divider().foregroundStyle(theme.line)

            Button {
                exportTheme()
            } label: {
                HStack {
                    Text("Export Theme")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.accent)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(.plain)

            Divider().foregroundStyle(theme.line)

            Button {
                showingImportPicker = true
            } label: {
                HStack {
                    Text("Import Theme")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.accent)
                    Spacer()
                    Image(systemName: "square.and.arrow.down.on.square")
                        .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(.plain)

            Divider().foregroundStyle(theme.line)

            Button {
                editingTheme = PresetThemes.paper
            } label: {
                HStack {
                    Text("Reset to Default")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(theme.ink3)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        editorGroup(title: "") {
            Button {
                showingDeleteAlert = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Theme")
                        .font(Typography.uiBody())
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Typography.sectionHeader())
            .tracking(0.08 * 13)
            .foregroundStyle(theme.ink3)
            .padding(.horizontal, theme.pad)
    }

    private func editorGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                sectionLabel(title.uppercased())
            }

            VStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, theme.cardPad)
            .padding(.vertical, theme.cardPad + 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.settingsGroup)
                    .fill(theme.surface)
            )
            .padding(.horizontal, theme.pad)
        }
    }

    // MARK: - Data Operations

    private func loadCustomThemes() {
        let raw = state.bridge.getCustomThemes()
        customThemes = raw.compactMap { custom in
            guard let data = custom.themeJson.data(using: .utf8),
                  let def = try? JSONDecoder().decode(ThemeDefinition.self, from: data) else {
                return nil
            }
            return def
        }
    }

    private func saveCustomTheme() {
        guard !saveThemeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var themeToSave = editingTheme
        themeToSave.name = saveThemeName.trimmingCharacters(in: .whitespaces)
        themeToSave.isBuiltIn = false
        if editingTheme.isBuiltIn {
            themeToSave.id = UUID().uuidString
        }

        if let json = ThemeImportExport.exportTheme(themeToSave),
           let jsonString = String(data: json, encoding: .utf8) {
            state.bridge.saveCustomTheme(id: themeToSave.id, name: themeToSave.name, json: jsonString)
            editingTheme = themeToSave
            loadCustomThemes()
        }
    }

    private func deleteCurrentTheme() {
        let idToDelete = editingTheme.id
        state.bridge.deleteCustomTheme(id: idToDelete)
        editingTheme = PresetThemes.paper
        loadCustomThemes()
    }

    private func exportTheme() {
        guard let data = ThemeImportExport.exportTheme(editingTheme),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(editingTheme.name).json")
        try? jsonString.write(to: tempURL, atomically: true, encoding: .utf8)

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let rootVC = window.rootViewController else { return }

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        rootVC.present(activityVC, animated: true)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let imported = ThemeImportExport.importTheme(from: data) else { return }

        // Save to DB
        if let json = ThemeImportExport.exportTheme(imported),
           let jsonString = String(data: json, encoding: .utf8) {
            state.bridge.saveCustomTheme(id: imported.id, name: imported.name, json: jsonString)
            loadCustomThemes()
            editingTheme = imported
        }
    }

    private func handlePhotoPick(_ item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: Data.self) { result in
            guard case .success(let data) = result, let data,
                  let uiImage = UIImage(data: data) else { return }

            let imageName = "bg_\(UUID().uuidString)"
            if let savedName = BackgroundImageManager.saveImage(uiImage, name: imageName) {
                DispatchQueue.main.async {
                    editingTheme.backgroundImageName = savedName
                }
            }
        }
    }
}

#Preview {
    ThemeEditorSheet()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
