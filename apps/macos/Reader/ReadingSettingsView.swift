import SwiftUI

/// The "Tt" popover: theme swatches, typeface list, text-size stepper,
/// spacing segmented control. Writes straight to the shared AppTheme.
struct ReadingSettingsView: View {
    @Bindable var theme: AppTheme
    /// True in the reader popover (themed surface); false when hosted in the
    /// system-styled Settings window.
    var themedBackground = true

    private let presets = [PresetThemes.paper, PresetThemes.sepia, PresetThemes.night]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reading")
                .font(Font(MacFont.ui(14, weight: .bold)))
                .foregroundStyle(theme.ink)

            group("Theme") {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        themeSwatch(preset)
                    }
                }
            }

            group("Typeface") {
                VStack(spacing: 7) {
                    ForEach(ReadingFont.allCases, id: \.self) { font in
                        fontOption(font)
                    }
                }
            }

            group("Text size") {
                HStack {
                    stepButton("minus") { theme.fontSize = max(15, theme.fontSize - 1) }
                    Spacer()
                    Text("\(theme.fontSize) pt")
                        .font(Font(MacFont.ui(14, weight: .bold)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    stepButton("plus") { theme.fontSize = min(26, theme.fontSize + 1) }
                }
                .padding(5)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            }

            group("Column width") {
                HStack {
                    stepButton("minus") { theme.measure = max(560, theme.measure - 20) }
                    Spacer()
                    Text("\(theme.measure) pt")
                        .font(Font(MacFont.ui(14, weight: .bold)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    stepButton("plus") { theme.measure = min(860, theme.measure + 20) }
                }
                .padding(5)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            }

            group("Spacing") {
                HStack(spacing: 3) {
                    segButton(.compact, "Compact")
                    segButton(.regular, "Regular")
                    segButton(.comfy, "Comfortable")
                }
                .padding(3)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            group("Layout") {
                HStack(spacing: 14) {
                    Toggle("Hyphenation", isOn: $theme.readHyphenation)
                    Toggle("Justify text", isOn: $theme.readJustified)
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(Font(MacFont.ui(12.5, weight: .medium)))
                .foregroundStyle(theme.ink2)
            }

            group("App text size") {
                HStack {
                    stepButton("minus") { setUIScale(theme.uiFontScale - 0.05) }
                    Spacer()
                    Text("\(Int((theme.uiFontScale * 100).rounded())) %")
                        .font(Font(MacFont.ui(14, weight: .bold)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    stepButton("plus") { setUIScale(theme.uiFontScale + 0.05) }
                }
                .padding(5)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(themedBackground ? theme.surface : .clear)
    }

    /// Update the chrome font scale before the observable write so every
    /// re-render triggered by the change already sees the new scale.
    private func setUIScale(_ raw: Double) {
        let clamped = min(1.3, max(0.9, (raw * 20).rounded() / 20))
        MacFont.scale = CGFloat(clamped)
        theme.uiFontScale = clamped
    }

    private func group(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.8)
                .foregroundStyle(theme.ink3)
            content()
        }
    }

    private func themeSwatch(_ preset: ThemeDefinition) -> some View {
        let on = theme.activeTheme.id == preset.id
        return Button {
            theme.switchTheme(preset)
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: preset.bgColor))
                    .frame(height: 30)
                    .overlay {
                        Text("Aa")
                            .font(Font(MacFont.serif(16)))
                            .foregroundStyle(Color(hex: preset.ink))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.06), lineWidth: 1))
                Text(preset.name)
                    .font(Font(MacFont.ui(11.5, weight: .semibold)))
                    .foregroundStyle(theme.ink2)
            }
            .padding(.init(top: 10, leading: 6, bottom: 8, trailing: 6))
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? theme.accent : theme.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fontOption(_ font: ReadingFont) -> some View {
        let on = theme.readingFont == font
        return Button {
            theme.readingFont = font
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(font.displayName)
                        .font(Font(MacFont.ui(13.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(font.kind)
                        .font(Font(MacFont.ui(11, weight: .semibold)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Text("Aa")
                    .font(Font(MacFont.reading(named: font.fontName, size: 19)))
                    .foregroundStyle(theme.ink2)
            }
            .padding(.init(top: 10, leading: 13, bottom: 10, trailing: 13))
            .background(on ? theme.accentSoft : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? theme.accent : theme.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 40, height: 34)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func segButton(_ value: Density, _ label: String) -> some View {
        let on = theme.density == value
        return Button {
            theme.density = value
        } label: {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(on ? theme.ink : theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
