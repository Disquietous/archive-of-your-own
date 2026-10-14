import Foundation

/// One comment in a work/chapter comments page, decoded from the Rust
/// layer's comments JSON (UCommentsPage.commentsJson). Shared by the iOS
/// comment sheets and the macOS discussion panel.
struct ParsedComment: Identifiable, Codable, Equatable {
    let id: UInt64
    let authorId: String
    let authorName: String
    let authorProfileUrl: String
    let authorAvatarUrl: String
    let postedAt: String
    let contentJson: String
    var replies: [ParsedComment]
    /// Posted without an AO3 account.
    let isGuest: Bool
    /// "on Chapter N" on whole-work pages; empty otherwise.
    let chapterLabel: String
    /// AO3's message for a bodiless comment (deleted/hidden); empty otherwise.
    let notice: String
    /// Replies AO3 cut off behind "N more comments in this thread".
    var moreReplies: UInt32

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case authorName = "author_name"
        case authorProfileUrl = "author_profile_url"
        case authorAvatarUrl = "author_avatar_url"
        case postedAt = "posted_at"
        case contentJson = "content_json"
        case replies
        case isGuest = "is_guest"
        case chapterLabel = "chapter_label"
        case notice
        case moreReplies = "more_replies"
    }

    init(id: UInt64, authorId: String, authorName: String, authorProfileUrl: String,
         authorAvatarUrl: String, postedAt: String, contentJson: String, replies: [ParsedComment],
         isGuest: Bool = false, chapterLabel: String = "", notice: String = "", moreReplies: UInt32 = 0) {
        self.id = id
        self.authorId = authorId
        self.authorName = authorName
        self.authorProfileUrl = authorProfileUrl
        self.authorAvatarUrl = authorAvatarUrl
        self.postedAt = postedAt
        self.contentJson = contentJson
        self.replies = replies
        self.isGuest = isGuest
        self.chapterLabel = chapterLabel
        self.notice = notice
        self.moreReplies = moreReplies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        authorId = try c.decode(String.self, forKey: .authorId)
        authorName = try c.decode(String.self, forKey: .authorName)
        authorProfileUrl = try c.decode(String.self, forKey: .authorProfileUrl)
        authorAvatarUrl = try c.decode(String.self, forKey: .authorAvatarUrl)
        postedAt = try c.decode(String.self, forKey: .postedAt)
        contentJson = try c.decode(String.self, forKey: .contentJson)
        replies = try c.decodeIfPresent([ParsedComment].self, forKey: .replies) ?? []
        isGuest = try c.decodeIfPresent(Bool.self, forKey: .isGuest) ?? false
        chapterLabel = try c.decodeIfPresent(String.self, forKey: .chapterLabel) ?? ""
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        moreReplies = try c.decodeIfPresent(UInt32.self, forKey: .moreReplies) ?? 0
    }

    /// The name to show: guest bylines carry AO3's "(Guest)" role suffix,
    /// which the guest badge replaces.
    var displayName: String {
        guard isGuest, authorName.hasSuffix("(Guest)") else { return authorName }
        return String(authorName.dropLast("(Guest)".count)).trimmingCharacters(in: .whitespaces)
    }

    /// "Chapter N" from AO3's "on Chapter N"; empty when unlabelled.
    var chapterChip: String {
        let trimmed = chapterLabel.hasPrefix("on ") ? String(chapterLabel.dropFirst(3)) : chapterLabel
        return trimmed.replacingOccurrences(of: "Chapter ", with: "Ch. ")
    }

    static func fromJSON(_ json: String) -> [ParsedComment] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParsedComment].self, from: data)) ?? []
    }

    /// One comment from a single CommentJson object; nil for empty/invalid.
    static func single(fromJSON json: String) -> ParsedComment? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParsedComment.self, from: data)
    }
}
