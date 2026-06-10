import XCTest
@testable import nunting

/// `DetailPrefetcher` — 목록 상위 글의 detail HTML 을 미리 받아 두는
/// 인메모리 창고. URLCache 는 게시판들의 no-cache 헤더에 막히므로 직접
/// 보관한다. 탭 시 `PostDetailLoader` 가 fetch 대신 소비(1회) → 처음
/// 여는 글의 RTT 제거.
@MainActor
final class DetailPrefetcherTests: XCTestCase {
    private func post(_ id: String, site: Site = .clien) -> Post {
        Post.fixture(
            id: id, site: site, boardID: "b", title: id,
            url: URL(string: "https://example.com/\(id)")!
        )
    }

    func testPrefetchStoresAndConsumeReturnsOnce() async {
        let calls = TestCounter()
        let prefetcher = DetailPrefetcher(fetchHTML: { url, _ in
            calls.increment()
            return "html:\(url.lastPathComponent)"
        })

        await prefetcher.prefetch(posts: [post("a"), post("b")])

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(prefetcher.consume(id: "a"), "html:a")
        XCTAssertNil(prefetcher.consume(id: "a"), "소비는 1회 — 재오픈 신선도는 PostDetailCache 가 담당")
        XCTAssertEqual(prefetcher.consume(id: "b"), "html:b")
    }

    func testAlreadyWarmPostIsNotRefetched() async {
        let calls = TestCounter()
        let prefetcher = DetailPrefetcher(fetchHTML: { _, _ in
            calls.increment()
            return "html"
        })

        await prefetcher.prefetch(posts: [post("a")])
        await prefetcher.prefetch(posts: [post("a")])

        XCTAssertEqual(calls.value, 1, "이미 warm 인 글은 재fetch 안 함")
    }

    func testAagagPostsAreSkipped() async {
        let calls = TestCounter()
        let prefetcher = DetailPrefetcher(fetchHTML: { _, _ in
            calls.increment()
            return "html"
        })

        await prefetcher.prefetch(posts: [post("m", site: .aagag), post("a")])

        XCTAssertEqual(calls.value, 1, "aagag 은 봇체크 인터스티셜/미러 리다이렉트 때문에 prefetch 제외")
        XCTAssertNil(prefetcher.consume(id: "m"))
        XCTAssertNotNil(prefetcher.consume(id: "a"))
    }

    func testExpiredEntryIsNotServed() async {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let prefetcher = DetailPrefetcher(
            ttl: 180,
            fetchHTML: { _, _ in "html" },
            now: { fakeNow }
        )

        await prefetcher.prefetch(posts: [post("a")])
        fakeNow = fakeNow.addingTimeInterval(181)

        XCTAssertNil(prefetcher.consume(id: "a"), "TTL 지난 HTML 은 stale 댓글을 보여주므로 버림")
    }

    func testFetchFailureIsSilentlySkipped() async {
        struct StubError: Error {}
        let prefetcher = DetailPrefetcher(fetchHTML: { url, _ in
            if url.lastPathComponent == "bad" { throw StubError() }
            return "html"
        })

        await prefetcher.prefetch(posts: [post("bad"), post("good")])

        XCTAssertNil(prefetcher.consume(id: "bad"))
        XCTAssertEqual(prefetcher.consume(id: "good"), "html", "한 글 실패가 나머지 prefetch 를 막으면 안 됨")
    }

    func testCapacityEvictsOldest() async {
        let prefetcher = DetailPrefetcher(capacity: 2, fetchHTML: { url, _ in
            "html:\(url.lastPathComponent)"
        })

        // 한 번에 넘기면 taskGroup 완료 순서가 비결정적이라 "가장 오래된"
        // 이 흔들린다 — 순차 prefetch 로 저장 순서를 고정.
        await prefetcher.prefetch(posts: [post("a")])
        await prefetcher.prefetch(posts: [post("b")])
        await prefetcher.prefetch(posts: [post("c")])

        XCTAssertNil(prefetcher.consume(id: "a"), "cap 초과 시 가장 오래된 항목부터 evict")
        XCTAssertNotNil(prefetcher.consume(id: "b"))
        XCTAssertNotNil(prefetcher.consume(id: "c"))
    }
}

private final class TestCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        n += 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
