import SwiftUI

struct RatingBadgeView: View {
    let rating: Rating

    var body: some View {
        Text(rating.letter)
            .font(.custom("HankenGrotesk", size: 11.5).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(rating.badgeColor)
            )
    }
}

#Preview {
    HStack(spacing: 8) {
        RatingBadgeView(rating: .general)
        RatingBadgeView(rating: .teen)
        RatingBadgeView(rating: .mature)
        RatingBadgeView(rating: .explicit)
    }
    .padding()
}
