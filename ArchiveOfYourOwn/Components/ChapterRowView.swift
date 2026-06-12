import SwiftUI

struct ChapterRowView: View {
    @Environment(AppTheme.self) private var theme

    let number: Int
    let title: String
    var isRead: Bool = false
    var isUnwritten: Bool = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Chapter number badge
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.chapterNum)
                        .fill(isRead ? theme.accent : theme.surface2)
                        .frame(width: 28, height: 28)

                    if isRead {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                    } else {
                        Text("\(number)")
                            .font(.custom("HankenGrotesk", size: 13).weight(.bold))
                            .foregroundStyle(theme.ink2)
                    }
                }

                // Title
                if isUnwritten {
                    Text("Not posted")
                        .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                        .foregroundStyle(theme.ink3)
                } else {
                    Text(title)
                        .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                        .foregroundStyle(isRead ? theme.ink3 : theme.ink)
                        .lineLimit(1)
                }

                Spacer()

                if !isUnwritten {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
            }
            .opacity(isUnwritten ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isUnwritten)
    }
}

#Preview {
    VStack(spacing: 0) {
        ChapterRowView(number: 1, title: "The Empty House", isRead: true, onTap: {})
            .padding(.vertical, 10)
        Divider()
        ChapterRowView(number: 2, title: "The Norwood Builder", isRead: true, onTap: {})
            .padding(.vertical, 10)
        Divider()
        ChapterRowView(number: 3, title: "The Dancing Men", onTap: {})
            .padding(.vertical, 10)
        Divider()
        ChapterRowView(number: 4, title: "", isUnwritten: true, onTap: {})
            .padding(.vertical, 10)
    }
    .padding(.horizontal, 16)
    .environment(AppTheme())
}
