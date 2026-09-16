import SwiftUI

struct ReadingSettingsSheetView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 20) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            Text("Reading Settings")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Theme swatches
                    themeSection

                    Divider()
                        .foregroundStyle(theme.line)

                    // Font picker
                    fontSection

                    Divider()
                        .foregroundStyle(theme.line)

                    // Text size stepper
                    sizeSection

                    Divider()
                        .foregroundStyle(theme.line)

                    // Spacing
                    spacingSection

                    // Column width — iPad / wide layouts only; a phone's
                    // width is the measure (D7).
                    if sizeClass == .regular {
                        Divider()
                            .foregroundStyle(theme.line)

                        measureSection
                    }

                    Divider()
                        .foregroundStyle(theme.line)

                    // Layout
                    layoutSection

                    Divider()
                        .foregroundStyle(theme.line)

                    // Images
                    imagesSection
                }
                .padding(.horizontal, theme.pad)
            }

            // Close button
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(Typography.buttonLabel())
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .fill(theme.accent)
                    )
            }
            .buttonStyle(ButtonPressStyle())
            .padding(.horizontal, theme.pad)
            .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THEME")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            FlowLayout(spacing: 12) {
                ForEach(PresetThemes.all) { preset in
                    themeSwatch(preset)
                }
            }
        }
    }

    private func themeSwatch(_ preset: ThemeDefinition) -> some View {
        let isSelected = theme.activeTheme.id == preset.id

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                theme.switchTheme(preset)
            }
        } label: {
            VStack(spacing: 8) {
                // Aa preview
                Text("Aa")
                    .font(.custom("Newsreader", size: 22).weight(.medium))
                    .foregroundStyle(Color(hex: preset.ink))
                    .frame(width: 72)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.themeOpt)
                            .fill(Color(hex: preset.bgColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.themeOpt)
                            .stroke(isSelected ? theme.accent : theme.line, lineWidth: isSelected ? 2 : 1)
                    )

                Text(preset.name)
                    .font(Typography.uiSmall())
                    .foregroundStyle(isSelected ? theme.ink : theme.ink3)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Font Section

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FONT")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            VStack(spacing: 0) {
                ForEach(ReadingFont.allCases, id: \.self) { font in
                    fontRow(font)

                    if font != ReadingFont.allCases.last {
                        Divider()
                            .foregroundStyle(theme.line)
                    }
                }
            }
        }
    }

    private func fontRow(_ font: ReadingFont) -> some View {
        let isSelected = theme.readingFont == font

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                theme.readingFont = font
            }
        } label: {
            HStack(spacing: 12) {
                // Font preview
                Text("Aa")
                    .font(.custom(font.fontName, size: 20))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(font.displayName)
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)

                    Text(font.kind)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Size Section

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TEXT SIZE")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            HStack(spacing: 16) {
                // Decrease button
                Button {
                    if theme.fontSize > 15 {
                        theme.fontSize -= 1
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.fontSize <= 15 ? theme.ink3.opacity(0.4) : theme.ink2)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.iconButton)
                                .fill(theme.surface2)
                        )
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(theme.fontSize <= 15)

                // Size display
                VStack(spacing: 2) {
                    Text("\(theme.fontSize)")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink)
                    Text("pt")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)

                // Increase button
                Button {
                    if theme.fontSize < 26 {
                        theme.fontSize += 1
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.fontSize >= 26 ? theme.ink3.opacity(0.4) : theme.ink2)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.iconButton)
                                .fill(theme.surface2)
                        )
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(theme.fontSize >= 26)
            }

            // Preview text
            Text("The fog had come up off the river before noon.")
                .font(theme.readingBodyFont)
                .foregroundStyle(theme.ink)
                .lineSpacing(theme.readingLineSpacing)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
    }

    // MARK: - Measure Section (iPad)

    private var measureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COLUMN WIDTH")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            HStack(spacing: 16) {
                stepButton("minus", enabled: theme.measure > 560) {
                    theme.measure = max(560, theme.measure - 20)
                }

                VStack(spacing: 2) {
                    Text("\(theme.measure)")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink)
                    Text("pt")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)

                stepButton("plus", enabled: theme.measure < 860) {
                    theme.measure = min(860, theme.measure + 20)
                }
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? theme.ink2 : theme.ink3.opacity(0.4))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Radius.iconButton)
                        .fill(theme.surface2)
                )
        }
        .buttonStyle(IconButtonPressStyle())
        .disabled(!enabled)
    }

    // MARK: - Layout Section

    private var layoutSection: some View {
        @Bindable var theme = theme
        return VStack(alignment: .leading, spacing: 12) {
            Text("LAYOUT")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            Toggle(isOn: $theme.fullscreenReading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open reader with chrome hidden")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Text("Start/Continue Reading opens chapters immersively; tap the page to show the controls.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
            }
            .tint(theme.accent)

            if WorkWindowValue.isSupported {
                Toggle(isOn: $theme.openWorksInWindow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open works in a new window")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink)
                        Text("Start/Continue Reading opens works in their own windows instead of the reading column.")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                    }
                }
                .tint(theme.accent)
            }
        }
    }

    // MARK: - Images Section

    private var imagesSection: some View {
        @Bindable var theme = theme
        return VStack(alignment: .leading, spacing: 12) {
            Text("IMAGES")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            Toggle(isOn: $theme.imageAutoLoad) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load images automatically")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Text("Off = images show as tap-to-load placeholders. Every image is fetched over your private connection either way.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
            }
            .tint(theme.accent)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Size limit")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Text("Images over the limit aren’t downloaded — the placeholder stays.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Picker("Size limit", selection: $theme.imageMaxMB) {
                    Text("1 MB").tag(1)
                    Text("2 MB").tag(2)
                    Text("5 MB").tag(5)
                    Text("10 MB").tag(10)
                    Text("No limit").tag(0)
                }
                .labelsHidden()
                .tint(theme.accent)
            }
        }
    }

    // MARK: - Spacing Section

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SPACING")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            SegmentedControlView(
                selection: Binding(
                    get: { theme.density },
                    set: { theme.density = $0 }
                ),
                items: [
                    (key: Density.compact, label: "Compact"),
                    (key: Density.regular, label: "Regular"),
                    (key: Density.comfy, label: "Comfortable"),
                ]
            )
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReadingSettingsSheetView()
                .environment(AppTheme())
        }
}
