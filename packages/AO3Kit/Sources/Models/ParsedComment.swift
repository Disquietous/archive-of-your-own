import Foundation

/// One comment in a work/chapter comments page, decoded from the Rust
/// layer's comments JSON (UCommentsPage.commentsJson). Shared by the iOS
/// comment sheets and the macOS comments view.
struct ParsedComment: Identifiable, Codable {
    let id: UInt64
    let authorId: String
    let authorName: String
    let authorProfileUrl: String
    let authorAvatarUrl: String
    let postedAt: String
    let contentJson: String
    let replies: [ParsedComment]

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case authorName = "author_name"
        case authorProfileUrl = "author_profile_url"
        case authorAvatarUrl = "author_avatar_url"
        case postedAt = "posted_at"
        case contentJson = "content_json"
        case replies
    }

    static func fromJSON(_ json: String) -> [ParsedComment] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParsedComment].self, from: data)) ?? []
    }
}
