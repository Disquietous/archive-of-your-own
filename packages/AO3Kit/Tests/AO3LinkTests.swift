import Foundation

// Host-run checks for the pure AO3 link classifier (AO3Link.swift).
// Synthetic URLs only. Run: scripts/test-swift.sh

var failures = 0

func check(_ input: String, _ expected: Result<AO3Link, AO3Link.Rejection>,
           line: Int = #line) {
    let got = AO3Link.classify(input)
    if got != expected {
        failures += 1
        print("FAIL line \(line): \(input)\n  expected \(expected)\n  got      \(got)")
    }
}

let base = "https://archiveofourown.org"

// Works, chapters, full work
check("\(base)/works/111", .success(.work(id: "111")))
check("archiveofourown.org/works/111", .success(.work(id: "111")))
check("\(base)/works/111?view_adult=true#main", .success(.work(id: "111")))
check("\(base)/works/111/navigate", .success(.work(id: "111")))
check("\(base)/works/111/chapters/222#workskin", .success(.chapter(workID: "111", chapterID: "222")))
check("\(base)/works/111?view_full_work=true", .success(.entireWork(id: "111")))
check("\(base)/works/111/chapters/222?view_full_work=true", .success(.entireWork(id: "111")))
check("\(base)/collections/Some_Fest/works/111", .success(.work(id: "111")))
check("https://www.archiveofourown.org/works/111", .success(.work(id: "111")))
check("Read this! \(base)/works/111 so good", .success(.work(id: "111")))

// Users
check("\(base)/users/sample_user", .success(.user(name: "sample_user", pseud: nil, pane: .profile)))
check("\(base)/users/sample_user/profile", .success(.user(name: "sample_user", pseud: nil, pane: .profile)))
check("\(base)/users/sample_user/works", .success(.user(name: "sample_user", pseud: nil, pane: .works)))
check("\(base)/users/sample_user/bookmarks", .success(.user(name: "sample_user", pseud: nil, pane: .bookmarks)))
check("\(base)/users/sample_user/collections", .success(.user(name: "sample_user", pseud: nil, pane: .collections)))
check("\(base)/users/sample_user/pseuds/alt", .success(.user(name: "sample_user", pseud: "alt", pane: .profile)))
check("\(base)/users/sample_user/pseuds/alt/works", .success(.user(name: "sample_user", pseud: "alt", pane: .works)))

// Series, collections, tags
check("\(base)/series/333", .success(.series(id: "333")))
check("\(base)/collections/Some_Fest", .success(.collection(name: "Some_Fest")))
check("\(base)/collections/Some_Fest/bookmarks", .success(.collection(name: "Some_Fest")))
check("\(base)/tags/Fluff/works", .success(.tag(name: "Fluff")))
check("\(base)/tags/Alpha*s*Beta%20Pair/works", .success(.tag(name: "Alpha/Beta Pair")))
check("\(base)/tags/Q*a*A", .success(.tag(name: "Q&A")))

// Unsupported AO3 pages
check("\(base)/", .failure(.unsupported))
check("\(base)/works/search?work_search%5Bquery%5D=x", .failure(.unsupported))
check("\(base)/works/111/comments", .failure(.unsupported))
check("\(base)/chapters/222", .failure(.unsupported))
check("\(base)/users/sample_user/inbox", .failure(.unsupported))
check("\(base)/series/abc", .failure(.unsupported))
check("\(base)/tags/Fluff/bookmarks", .failure(.unsupported))
check("\(base)/admin_posts/5", .failure(.unsupported))

// Not AO3
check("https://notarchiveofourown.org/works/111", .failure(.notAO3))
check("https://example.com/works/111", .failure(.notAO3))
check("ftp://archiveofourown.org/works/111", .failure(.notAO3))
check("just some words", .failure(.notAO3))
check("", .failure(.notAO3))

if failures == 0 {
    print("AO3LinkTests: all passed")
} else {
    print("AO3LinkTests: \(failures) failed")
    exit(1)
}
