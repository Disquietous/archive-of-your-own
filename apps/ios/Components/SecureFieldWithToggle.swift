import SwiftUI

struct SecureFieldWithToggle: View {
    let placeholder: String
    @Binding var text: String

    @State private var showPassword = false

    var body: some View {
        HStack(spacing: 0) {
            if showPassword {
                TextField(placeholder, text: $text)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                SecureField(placeholder, text: $text)
                    .textContentType(.password)
            }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }
}
