import Foundation

enum ScreenshotState {

    static func makePopulatedState() -> AppState {
        let state = AppState()

        state.cachedWorks = MockData.works
        state.browseResults = MockData.works

        state.bookmarkedWorkIDs = Set(["baker", "lamplight", "olive"])
        state.downloadedWorkIDs = Set(["baker", "lamplight"])
        state.history = ["baker", "olive", "wireframe", "moor"]
        state.progressMap = [
            "baker": ReadingProgress(chapter: 4, pct: 0.38),
            "olive": ReadingProgress(chapter: 17, pct: 0.71),
        ]
        state.lastReadID = "baker"

        state.ao3Username = "stardust_reader"

        state.subscriptions = [
            USubscription(subType: "author", id: "marblestaircase", name: "marblestaircase"),
            USubscription(subType: "author", id: "quietfeathers", name: "quietfeathers"),
            USubscription(subType: "work", id: "baker", name: "The Long Way Round to Baker Street"),
            USubscription(subType: "work", id: "olive", name: "What the Olive Branch Knew"),
            USubscription(subType: "work", id: "wireframe", name: "Wireframe Hearts"),
            USubscription(subType: "series", id: "1001", name: "The Seasons Cycle"),
        ]

        state.fetchedChapters = [
            "baker": makeMockChapters(from: MockData.bakerStreetChapters),
        ]

        state.unreadNotificationCount = 3

        cacheSearchForm()

        return state
    }

    // MARK: - Search Form Cache

    static func cacheSearchForm() {
        let fields: [[String: Any]] = [
            [
                "name": "work_search[query]",
                "label": "Any field",
                "fieldType": "text",
                "placeholder": "Search by keyword",
                "options": [] as [[String: Any]],
            ],
            [
                "name": "work_search[title]",
                "label": "Title",
                "fieldType": "text",
                "placeholder": "",
                "options": [] as [[String: Any]],
            ],
            [
                "name": "work_search[creators]",
                "label": "Author/Artist",
                "fieldType": "text",
                "placeholder": "",
                "options": [] as [[String: Any]],
            ],
            [
                "name": "work_search[fandom_names]",
                "label": "Fandom",
                "fieldType": "text",
                "placeholder": "",
                "options": [] as [[String: Any]],
            ],
            [
                "name": "work_search[rating_ids]",
                "label": "Rating",
                "fieldType": "select",
                "placeholder": "",
                "options": [
                    ["value": "", "label": "Any", "selected": true],
                    ["value": "10", "label": "General Audiences", "selected": false],
                    ["value": "11", "label": "Teen And Up Audiences", "selected": false],
                    ["value": "12", "label": "Mature", "selected": false],
                    ["value": "13", "label": "Explicit", "selected": false],
                ] as [[String: Any]],
            ],
            [
                "name": "work_search[complete]",
                "label": "Completion status",
                "fieldType": "select",
                "placeholder": "",
                "options": [
                    ["value": "", "label": "All works", "selected": true],
                    ["value": "T", "label": "Complete works only", "selected": false],
                    ["value": "F", "label": "Works in progress only", "selected": false],
                ] as [[String: Any]],
            ],
            [
                "name": "work_search[sort_column]",
                "label": "Sort by",
                "fieldType": "select",
                "placeholder": "",
                "options": [
                    ["value": "revised_at", "label": "Date Updated", "selected": true],
                    ["value": "kudos_count", "label": "Kudos", "selected": false],
                    ["value": "hits", "label": "Hits", "selected": false],
                    ["value": "word_count", "label": "Word Count", "selected": false],
                ] as [[String: Any]],
            ],
        ]
        if let json = try? JSONSerialization.data(withJSONObject: fields) {
            UserDefaults.standard.set(json, forKey: "cachedSearchForm")
        }
    }

    // MARK: - Mock Comments

    static let mockComments: [ParsedComment] = {
        let comment1Json = paragraphsToContentJSON([
            "I cannot stop thinking about the fog description in chapter one. \"A string of paper lanterns hung for some occasion the city had forgotten to attend\" — that is so beautiful it hurts.",
        ])
        let reply1Json = paragraphsToContentJSON([
            "That line stopped me in my tracks too. The whole first page reads like a love letter to London.",
        ])
        let reply2Json = paragraphsToContentJSON([
            "The way the prose slows down for Watson's observations and then speeds up the moment Holmes speaks — it's such a clever rhythm.",
        ])
        let comment2Json = paragraphsToContentJSON([
            "Twelve chapters of pure comfort reading. I rationed them out one a night like some kind of fic advent calendar and I have no regrets.",
        ])
        let comment3Json = paragraphsToContentJSON([
            "\"Suspense. They are not at all the same thing, and the difference between them is the whole of my profession.\" I am going to be thinking about this line for weeks.",
        ])

        return [
            ParsedComment(
                id: 100001, authorId: "u1", authorName: "lamplighter",
                authorProfileUrl: "", authorAvatarUrl: "",
                postedAt: "3 days ago", contentJson: comment1Json,
                replies: [
                    ParsedComment(
                        id: 100002, authorId: "u2", authorName: "cobblestones",
                        authorProfileUrl: "", authorAvatarUrl: "",
                        postedAt: "2 days ago", contentJson: reply1Json,
                        replies: []
                    ),
                    ParsedComment(
                        id: 100003, authorId: "u3", authorName: "inkandashes",
                        authorProfileUrl: "", authorAvatarUrl: "",
                        postedAt: "1 day ago", contentJson: reply2Json,
                        replies: []
                    ),
                ]
            ),
            ParsedComment(
                id: 100004, authorId: "u4", authorName: "gaslight_district",
                authorProfileUrl: "", authorAvatarUrl: "",
                postedAt: "5 days ago", contentJson: comment2Json,
                replies: []
            ),
            ParsedComment(
                id: 100005, authorId: "u5", authorName: "quietfeathers",
                authorProfileUrl: "", authorAvatarUrl: "",
                postedAt: "1 week ago", contentJson: comment3Json,
                replies: []
            ),
        ]
    }()

    // MARK: - Chapter JSON Generation

    private static func makeMockChapters(from chapters: [ChapterContent]) -> [UChapter] {
        chapters.enumerated().map { index, ch in
            UChapter(
                chapterId: Int64(index + 1),
                number: UInt32(index + 1),
                title: ch.title,
                contentJson: paragraphsToContentJSON(ch.paragraphs),
                notesBefore: "",
                notesAfter: ""
            )
        }
    }

    static func paragraphsToContentJSON(_ paragraphs: [String]) -> String {
        let blocks: [[String: Any]] = paragraphs.map { text in
            ["Paragraph": ["text": [["Text": ["value": text]]]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: blocks),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
