import Foundation

enum MockData {
    static let bakerStreetChapters: [ChapterContent] = [
        ChapterContent(
            title: "I. A Note in the Fog",
            paragraphs: [
                "The fog had come up off the river before noon, and by four o'clock it had swallowed Baker Street whole. From the window I could no longer see the lamplighter at his rounds, only the soft amber blooms where the gas caught the mist, one after another, like a string of paper lanterns hung for some occasion the city had forgotten to attend.",
                "Holmes had not spoken in three hours. He sat with his knees drawn up in the basket chair, the morning's correspondence unopened at his elbow, watching the fire as though it owed him an explanation. I had learned, in our years of sharing those rooms, that such silences were not to be disturbed. They were the visible portion of a great deal of invisible work.",
                "\"You are going to ask me,\" he said at last, without turning, \"why I have not touched the letters.\"",
                "\"I had resolved not to.\"",
                "\"A resolution you abandoned the moment I spoke, which is its own kind of answer.\" He unfolded himself from the chair in a single motion and crossed to the table, and for the first time that day there was colour in his face. \"The truth, Watson, is that one of those letters is a request for help, one is a threat, and one is a confession — and I cannot yet tell you which is which. That is the only problem in London worth my attention this week, and it has been sitting unopened since breakfast purely so that I might enjoy not knowing.\"",
                "I confess I laughed. \"You are the only man alive who would call ignorance a luxury.\"",
                "\"Ignorance, no. Suspense.\" He slit the first envelope with the paper-knife. \"They are not at all the same thing, and the difference between them is the whole of my profession.\"",
            ]
        ),
        ChapterContent(
            title: "II. The Visitor Who Did Not Knock",
            paragraphs: [
                "We were not, as it turned out, to enjoy the suspense for very long. There came upon the stair a tread that was careful in the way that only frightened people are careful — too even, too quiet, a person trying to make themselves weigh less than they did.",
                "Holmes set down the letter. \"A woman,\" he murmured, \"young, recently out of mourning, and she has walked a considerable distance rather than take a cab, though she can plainly afford one. Note the hesitation on the seventh stair. She is deciding, even now, whether to come up at all.\"",
                "\"You cannot possibly know she is in mourning.\"",
                "\"I cannot. I deduce it, which is a great deal more reliable.\" The footsteps resolved at last into a knock — three soft raps, then a fourth, as if the fourth had escaped before she could prevent it. \"Come in,\" Holmes called, in the gentlest voice I had ever heard him use, \"the door is not locked, and you have come too far to turn back now.\"",
                "She entered the way a candle enters a dark room: all at once, and changing everything. I rose. Holmes did not — he only watched her with that terrible patient attention, and I knew that the quiet afternoon was over, and that something had begun which none of us would be able to stop.",
            ]
        ),
    ]

    static let lamplightChapters: [ChapterContent] = [
        ChapterContent(
            title: "I. Correspondence",
            paragraphs: [
                "My dear Jane, — You will laugh at me, and you will be right to, but I find I have begun three letters to you this evening and burned each one before the second line. There is a particular kind of foolishness that comes over a sensible woman when she has nothing to report and a great deal to feel, and I am afraid I am presently its most willing victim.",
                "The truth is only this: he came to dinner, he was civil, he said almost nothing, and I have thought of little else for two days. You will say this is hardly news. You will say I have spent the better part of a year being certain I disliked him. To which I can only reply that certainty, in my experience, is the surest sign that one has not yet finished thinking.",
            ]
        ),
    ]

    static let prosePool: [String] = [
        "The morning arrived the way mornings do in that part of the country — reluctantly, and all at once, as though the light had been arguing with itself about whether to come at all.",
        "She had learned long ago that the things worth saying were rarely the things one planned to say, and so she had stopped planning, and started simply waiting to see what she would do.",
        "There is a particular silence that falls between two people who have known each other a long time, and it is not empty at all; it is the most crowded silence in the world.",
        "He turned the letter over in his hands twice, three times, as if the answer might be written on the side he had not yet examined, and was disappointed each time to find it was not.",
        "Outside, the rain had settled into the steady, companionable rhythm of a rain that intends to stay, and the windows had gone soft and grey, and the whole house seemed to lean inward toward the fire.",
        "It was not that she had forgotten him. It was that she had remembered him so often, and so carefully, that the remembering had become a kind of habit, and habits are the hardest things of all to break.",
        "\"You always do this,\" he said, though there was no heat in it, only the worn-smooth fondness of an accusation made too many times to mean anything but affection.",
        "The path forked, as paths in stories always do, and she stood for a long moment at the dividing of it, and understood that whichever way she chose she would spend the rest of her life wondering about the other.",
        "They did not speak of it again for many years, and when at last they did, it was in the offhand way of people setting down something they had been carrying so long they had forgotten its weight.",
        "And so the season turned, as seasons will, indifferent to the small human dramas being conducted beneath it, and the apples came ripe on the bough whether anyone was there to gather them or not.",
    ]

    static func buildChapter(for work: Work, index: Int) -> ChapterContent {
        if let content = work.content, index < content.count {
            return content[index]
        }
        let start = (index * 3) % prosePool.count
        let paras = (0..<5).map { k in prosePool[(start + k) % prosePool.count] }
        return ChapterContent(title: "Chapter \(index + 1)", paragraphs: paras)
    }

    static let works: [Work] = [
        Work(
            id: "baker", title: "The Long Way Round to Baker Street",
            author: "marblestaircase", fandom: "Sherlock Holmes — A.C. Doyle",
            relationship: "Holmes & Watson", rating: .teen,
            warnings: "No Archive Warnings Apply", category: "Gen",
            tags: ["Slow Burn", "Hurt/Comfort", "Case Fic", "Victorian", "Pining", "Fireside Conversations", "Foggy London"],
            words: 47213, chapterCount: 12, totalChapters: 12, complete: true,
            kudos: 8421, hits: 96230, bookmarks: 1204, comments: 612,
            published: "Aug 2025", updated: "May 2026", summary: "Three letters arrive at 221B on a foggy afternoon, and Holmes refuses to open any of them — until a frightened young woman climbs the stair and makes the choice for him. A casefic told mostly in the quiet between the danger.",
            initialProgress: 0.38, lastChapter: 4, downloaded: true,
            content: bakerStreetChapters
        ),
        Work(
            id: "lamplight", title: "Lamplight",
            author: "quietfeathers", fandom: "Pride and Prejudice — Austen",
            relationship: "Elizabeth Bennet/Fitzwilliam Darcy", rating: .general,
            warnings: "No Archive Warnings Apply", category: "F/M",
            tags: ["Epistolary", "Fluff", "Pining", "Letters", "Slow Burn", "Period Typical"],
            words: 8902, chapterCount: 3, totalChapters: 3, complete: true,
            kudos: 5310, hits: 41008, bookmarks: 802, comments: 240,
            published: "Apr 2026", updated: "Apr 2026", summary: "A courtship conducted almost entirely by letter, in which both parties are far braver on paper than they could ever be across a drawing room.",
            initialProgress: 0, lastChapter: nil, downloaded: true,
            content: lamplightChapters
        ),
        Work(
            id: "olive", title: "What the Olive Branch Knew",
            author: "sixpomegranateseeds", fandom: "Greek Mythology",
            relationship: "Persephone/Hades", rating: .mature,
            warnings: "No Archive Warnings Apply", category: "F/M",
            tags: ["Mythology Retelling", "The Seasons", "Angst with a Happy Ending", "Slow Burn", "Found Family", "Pomegranates"],
            words: 122540, chapterCount: 24, totalChapters: 30, complete: false,
            kudos: 19840, hits: 312400, bookmarks: 4102, comments: 2210,
            published: "Oct 2024", updated: "3 days ago", summary: "Six months above, six below, and a marriage negotiated one season at a time. A retelling that takes the long view — geological, even — of two people learning to share a year.",
            initialProgress: 0.71, lastChapter: 17, downloaded: false,
            content: nil
        ),
        Work(
            id: "wireframe", title: "Wireframe Hearts",
            author: "tidalmoth", fandom: "Original Work",
            relationship: "F/F", rating: .teen,
            warnings: "No Archive Warnings Apply", category: "F/F",
            tags: ["Science Fiction", "Found Family", "Slow Burn", "Generation Ship", "Soft", "Engineers in Love"],
            words: 63118, chapterCount: 18, totalChapters: 18, complete: true,
            kudos: 7044, hits: 88120, bookmarks: 1530, comments: 489,
            published: "Jun 2025", updated: "Feb 2026", summary: "Two engineers, one failing life-support array, and forty years of travel left before landfall. They have all the time in the world and absolutely none of it to waste.",
            initialProgress: 0, lastChapter: nil, downloaded: false,
            content: nil
        ),
        Work(
            id: "moor", title: "The Moor at Midnight",
            author: "thornfieldlight", fandom: "Jane Eyre — Brontë",
            relationship: "Jane Eyre/Edward Rochester", rating: .mature,
            warnings: "Choose Not To Use Archive Warnings", category: "F/M",
            tags: ["Gothic", "Second Chances", "Slow Burn", "Atmospheric", "Yorkshire"],
            words: 31455, chapterCount: 9, totalChapters: 9, complete: true,
            kudos: 4120, hits: 52300, bookmarks: 690, comments: 188,
            published: "Nov 2025", updated: "Jan 2026", summary: "Years after the fire, a letter brings her back to the ruin of Thornfield — and to the man who has been waiting there in the dark, certain she would never come.",
            initialProgress: 0, lastChapter: nil, downloaded: false,
            content: nil
        ),
        Work(
            id: "letters", title: "Ten Letters Never Sent",
            author: "roundtableghost", fandom: "Arthurian Legend",
            relationship: "Lancelot/Guinevere/Arthur", rating: .teen,
            warnings: "No Archive Warnings Apply", category: "Multi",
            tags: ["Polyamory", "Angst", "Pining", "Camelot", "Letters", "Bittersweet"],
            words: 19004, chapterCount: 7, totalChapters: 7, complete: true,
            kudos: 3380, hits: 38940, bookmarks: 540, comments: 142,
            published: "Sep 2025", updated: "Dec 2025", summary: "Three people who love one another more than they can say, and the letters none of them ever found the courage to deliver.",
            initialProgress: 0, lastChapter: nil, downloaded: false,
            content: nil
        ),
        Work(
            id: "salt", title: "Salt and Static",
            author: "harborlights", fandom: "Original Work",
            relationship: "M/M", rating: .explicit,
            warnings: "No Archive Warnings Apply", category: "M/M",
            tags: ["Enemies to Lovers", "Modern AU", "Rivals", "Slow Burn", "Coastal Town"],
            words: 88760, chapterCount: 22, totalChapters: 22, complete: true,
            kudos: 12300, hits: 198400, bookmarks: 2890, comments: 980,
            published: "May 2025", updated: "Mar 2026", summary: "Two rival radio hosts share a frequency, a coastline, and a grudge that neither can quite remember the origin of. Static makes for poor reception and excellent tension.",
            initialProgress: 0, lastChapter: nil, downloaded: false,
            content: nil
        ),
        Work(
            id: "garden", title: "The Secret Garden Grows Back",
            author: "robinandwren", fandom: "The Secret Garden — Burnett",
            relationship: "Gen", rating: .general,
            warnings: "No Archive Warnings Apply", category: "Gen",
            tags: ["Cottagecore", "Healing", "Found Family", "Fluff", "Yorkshire", "Soft"],
            words: 14500, chapterCount: 5, totalChapters: 5, complete: true,
            kudos: 2980, hits: 31200, bookmarks: 470, comments: 96,
            published: "Oct 2025", updated: "Nov 2025", summary: "Twenty springs on, the garden is overgrown again — and three children who have never met decide, quite independently, that it belongs to them.",
            initialProgress: 0, lastChapter: nil, downloaded: false,
            content: nil
        ),
    ]

}
