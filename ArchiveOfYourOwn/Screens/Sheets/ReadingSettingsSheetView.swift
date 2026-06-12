import SwiftUI

struct ReadingSettingsSheetView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(PresetThemes.all) { preset in
                        themeSwatch(preset)
                    }
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
