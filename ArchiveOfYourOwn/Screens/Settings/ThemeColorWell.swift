import SwiftUI

struct ThemeColorWell: View {
    let label: String
    @Binding var hexColor: String
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack {
            Text(label)
                .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                .foregroundStyle(theme.ink)
            Spacer()
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: hexColor) },
            set: { newColor in hexColor = newColor.toHex() }
        )
    }
}
