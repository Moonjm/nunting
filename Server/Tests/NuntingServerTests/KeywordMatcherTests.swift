import XCTest
import NuntingCore
@testable import NuntingServer

final class KeywordMatcherTests: XCTestCase {
    private static func makePost(id: String, title: String) -> Post {
        // `Board` is intentionally non-Sendable in NuntingCore, so we avoid
        // storing one as a static and just hard-code the boardID here. The
        // value mirrors `Board(id: "ppomppu", site: .ppomppu, ...)`.
        Post(
            id: id,
            site: .ppomppu,
            boardID: "ppomppu",
            title: title,
            author: "a",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=\(id)")!
        )
    }

    /// 단일 사용자, 단일 키워드, 1건 매칭.
    func testSingleUserSingleKeywordMatches() {
        let post = Self.makePost(id: "1", title: "갤럭시 S25 핫딜 19만원")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_alice": ["갤럭시"]]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].uuid, "nnt_alice")
        XCTAssertEqual(result[0].keyword, "갤럭시")
        XCTAssertEqual(result[0].post.id, "1")
    }

    /// 두 사용자, 한 명만 매칭.
    func testOnlyMatchingUserGetsResult() {
        let post = Self.makePost(id: "1", title: "RTX5090 핫딜")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: [
                "nnt_a": ["rtx5090"],
                "nnt_b": ["맥북"],
            ]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].uuid, "nnt_a")
    }

    /// 매칭은 title.lowercased().contains(keyword) — keyword는 이미 normalize됨 가정.
    /// 대소문자/공백 정규화는 호출자 책임(Store.normalizedKeyword + KeywordMatcher
    /// 내부의 title.lowercased()).
    func testMatchingIsCaseInsensitiveForLatinKeywords() {
        let post = Self.makePost(id: "1", title: "Galaxy S25 hot deal")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["galaxy"]]
        )
        XCTAssertEqual(result.count, 1)
    }

    /// 한 글에 여러 키워드 매칭되면 각각 emit.
    /// 사용자가 "갤럭시", "S25"를 둘 다 구독했고 글이 "갤럭시 S25"면 2건.
    func testMultipleKeywordsMatchEmitsEachSeparately() {
        let post = Self.makePost(id: "1", title: "갤럭시 s25 핫딜")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["갤럭시", "s25"]]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.keyword)), ["갤럭시", "s25"])
    }

    /// 매칭 없는 글은 결과에 안 들어감.
    func testNonMatchingPostYieldsEmpty() {
        let post = Self.makePost(id: "1", title: "전혀 관련 없는 내용")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["갤럭시"]]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// posts 순서는 보존, 같은 글의 여러 매칭은 keyword 정렬로 안정화.
    /// ForEach 안정성 / 푸시 발송 순서 일관성을 위해.
    func testResultIsDeterministicWhenMultipleMatchesPerPost() {
        let post = Self.makePost(id: "1", title: "a b c")
        let result1 = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["c", "a", "b"]]
        )
        let result2 = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["b", "c", "a"]]
        )
        XCTAssertEqual(result1.map(\.keyword), result2.map(\.keyword))
    }
}
