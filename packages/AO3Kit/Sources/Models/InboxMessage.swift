import Foundation

struct InboxItem: Identifiable, Codable {
    let commentId: UInt64
    let author: String
    let authorUrl: String
    let avatarUrl: String
    let workReference: String
    let workUrl: String
    let postedAt: String
    let isUnread: Bool
    let contentJson: String

    var id: UInt64 { commentId }

    enum CodingKeys: String, CodingKey {
        case commentId = "comment_id"
        case author
        case authorUrl = "author_url"
        case avatarUrl = "avatar_url"
        case workReference = "work_reference"
        case workUrl = "work_url"
        case postedAt = "posted_at"
        case isUnread = "is_unread"
        case contentJson = "content_json"
    }
}

struct InboxThreadComment: Identifiable, Codable {
    let id: UInt64
    let author: String
    let authorUrl: String
    let avatarUrl: String
    let postedAt: String
    let contentJson: String
    let replies: [InboxThreadComment]

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case authorUrl = "author_url"
        case avatarUrl = "avatar_url"
        case postedAt = "posted_at"
        case contentJson = "content_json"
        case replies
    }
}

struct InboxThreadResponse: Codable {
    let thread: InboxThreadComment?
    let targetCommentId: UInt64

    enum CodingKeys: String, CodingKey {
        case thread
        case targetCommentId = "target_comment_id"
    }
}

struct InboxResponse: Codable {
    let items: [InboxItem]
    let unreadCount: UInt32
    let hasNextPage: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case unreadCount = "unread_count"
        case hasNextPage = "has_next_page"
    }
}
