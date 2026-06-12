import SwiftUI

struct SegmentedControlView<Key: Hashable>: View {
    @Environment(AppTheme.self) private var theme

    @Binding var selection: Key
    let items: [(key: Key, label: String)]

    @Namespace private var segmentNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let isSelected = item.key == selection

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = item.key
                        }
                    } label: {
                        Text(item.label)
                            .font(Typography.segControl())
                            .foregroundStyle(isSelected ? theme.ink : theme.ink3)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(theme.surface)
                                        .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
                                        .matchedGeometryEffect(id: "segment", in: segmentNamespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(theme.surface2)
            )
        }
    }
}

#Preview {
    struct Preview: View {
        @State private var selection = "all"
        var body: some View {
            SegmentedControlView(
                selection: $selection,
                items: [
                    (key: "all", label: "All"),
                    (key: "reading", label: "Reading"),
                    (key: "bookmarks", label: "Bookmarks"),
                ]
            )
            .padding()
            .environment(AppTheme())
        }
    }
    return Preview()
}
