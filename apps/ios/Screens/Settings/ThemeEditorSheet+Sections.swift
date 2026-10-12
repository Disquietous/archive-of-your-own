import SwiftUI
import PhotosUI

extension ThemeEditorSheet {
    // MARK: - Theme Selector

    var themeSelectorSection: some View {
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

    var allThemes: [ThemeDefinition] {
        PresetThemes.all + customThemes
    }

    func themeCard(_ def: ThemeDefinition) -> some View {
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

    var backgroundSection: some View {
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

    var colorsSection: some View {
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

    var typographySection: some View {
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

    var layoutSection: some View {
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
}
