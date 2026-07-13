import SwiftUI

struct ToggleRowView<Label: View>: View {
    @Environment(AppTheme.self) private var theme

    @Binding var isOn: Bool
    @ViewBuilder var label: () -> Label

    private let trackWidth: CGFloat = 46
    private let trackHeight: CGFloat = 28
    private let knobSize: CGFloat = 22
    private let knobPadding: CGFloat = 3

    var body: some View {
        HStack {
            label()
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: Radius.toggle)
                        .fill(isOn ? theme.sage : theme.surface3)
                        .frame(width: trackWidth, height: trackHeight)

                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
                        .padding(knobPadding)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    struct Preview: View {
        @State private var isOn = false
        @State private var isOn2 = true
        var body: some View {
            VStack(spacing: 20) {
                ToggleRowView(isOn: $isOn) {
                    Text("Off toggle")
                }
                ToggleRowView(isOn: $isOn2) {
                    Text("On toggle")
                }
            }
            .padding()
            .environment(AppTheme())
        }
    }
    return Preview()
}
