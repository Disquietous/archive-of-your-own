import AppKit
import SwiftUI

/// A user avatar backed by the shared username-keyed cache (session memory →
/// encrypted DB → one-time AO3 fetch). Shows a letter disc until — or unless
/// — bytes arrive. Pass `urlHint` when the data source already carries the
/// avatar URL (inbox, comments) so a fetch never needs the profile page.
/// Set `fetchable: false` for guests/unknown users to avoid doomed requests.
struct AuthorAvatarView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let username: String
    var urlHint: String? = nil
    var size: CGFloat = 28
    var fetchable = true

    var body: some View {
        Group {
            if let data = appState.authorAvatars[username], let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(theme.surface2)
                    .overlay {
                        Text(String(username.prefix(1)).uppercased())
                            .font(Font(MacFont.ui(size * 0.45, weight: .bold)))
                            .foregroundStyle(theme.ink3)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            if fetchable {
                appState.loadAuthorAvatar(username, urlHint: urlHint)
            }
        }
    }
}
