import SwiftUI

struct SegmentedControlView<Key: Hashable>: View {
    @Environment(AppTheme.self) private var theme

    @Binding var selection: Key
    let items: [(key: Key, label: String)]

    @Namespace private var segmentNamespace

    var body: some View {
        CenteredFlowLayout(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = item.key == selection

                HStack(spacing: 0) {
                    if index > 0 {
                        Rectangle()
                            .fill(theme.line)
                            .frame(width: 1, height: 14)
                    }

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
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(3)
    }
}

struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = buildRows(in: proposal.width ?? 0, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { sum, row in
            sum + row.height + (sum > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = buildRows(in: bounds.width, subviews: subviews)
        var y: CGFloat = 0

        for row in rows {
            let rowWidth = row.sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(row.sizes.count - 1)
            var x = (bounds.width - rowWidth) / 2

            for i in 0..<row.indices.count {
                let idx = row.indices[i]
                let size = row.sizes[i]
                subviews[idx].place(
                    at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int]
        var sizes: [CGSize]
        var height: CGFloat
    }

    private func buildRows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row(indices: [], sizes: [], height: 0)
        var x: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !currentRow.indices.isEmpty {
                rows.append(currentRow)
                currentRow = Row(indices: [], sizes: [], height: 0)
                x = 0
            }
            currentRow.indices.append(i)
            currentRow.sizes.append(size)
            currentRow.height = max(currentRow.height, size.height)
            x += size.width + spacing
        }
        if !currentRow.indices.isEmpty {
            rows.append(currentRow)
        }
        return rows
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
                    (key: "subscriptions", label: "Subscriptions"),
                    (key: "history", label: "History"),
                    (key: "downloads", label: "Downloads"),
                ]
            )
            .padding()
            .environment(AppTheme())
        }
    }
    return Preview()
}
