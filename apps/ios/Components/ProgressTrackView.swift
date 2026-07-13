import SwiftUI

struct ProgressTrackView: View {
    @Environment(AppTheme.self) private var theme

    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(theme.surface3)
                    .frame(height: 6)

                // Fill
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(theme.accent)
                    .frame(width: max(0, geo.size.width * min(progress, 1.0)), height: 6)
            }
        }
        .frame(height: 6)
    }
}

#Preview {
    VStack(spacing: 16) {
        ProgressTrackView(progress: 0.0)
        ProgressTrackView(progress: 0.38)
        ProgressTrackView(progress: 0.71)
        ProgressTrackView(progress: 1.0)
    }
    .padding()
    .environment(AppTheme())
}
