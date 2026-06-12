import SwiftUI

struct SearchFieldView: View {
    @Environment(AppTheme.self) private var theme

    @Binding var text: String
    var placeholder: String = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.ink3)

            TextField(placeholder, text: $text)
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .foregroundStyle(theme.ink)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(IconButtonPressStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(isFocused ? theme.surface : theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Radius.searchField))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.searchField)
                .stroke(isFocused ? theme.line2 : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    struct Preview: View {
        @State private var text = ""
        var body: some View {
            SearchFieldView(text: $text, placeholder: "Search works...")
                .padding()
                .environment(AppTheme())
        }
    }
    return Preview()
}
