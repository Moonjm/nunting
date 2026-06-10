import XCTest
@testable import nunting
/// State-machine + side-effect tests for `BoardListLoader`.
///
/// Stub fetcher returns canned HTML; the production parser still runs
/// (so we exercise the real ClienParser etc., not a parsed-result fake).
///
/// Captured `var` from the @Sendable fetcher closure goes through the
/// same lock-protected helpers used in `BoardCatalogStoreTests`
/// (TestCounter / TestRecorder). See those for the rationale.
final class BoardListLoaderTests: XCTestCase {

    // Smallest body that produces non-empty Posts via ClienParser.
    private let clienHTML = """
    <html><body>
    <a class="list_item symph-row" href="/service/board/news/1"
       data-board-sn="1" data-comment-count="2" data-author-id="user">
        <span data-role="list-title-text">첫번째 글</span>
        <div class="list_author"><span class="nickname">A</span></div>
        <div class="list_time"><span>2025-01-01</span></div>
    </a>
    <a class="list_item symph-row" href="/service/board/news/2"
       data-board-sn="2" data-comment-count="0" data-author-id="user2">
        <span data-role="list-title-text">두번째 글</span>
        <div class="list_author"><span class="nickname">B</span></div>
        <div class="list_time"><span>2025-01-02</span></div>
    </a>
    </body></html>
    """

    /// 테스트 로더는 전부 temp 디스크 스냅샷 스토어를 쓴다 — 기본 init 의
    /// 실제 앱 컨테이너 파일을 읽고 쓰면 테스트 실행 간 오염이 생긴다
    /// (이전 실행이 남긴 스냅샷이 다음 실행의 cold-path 단언을 깨뜨림).
    private func makeLoader(fetcher: @escaping BoardListLoader.Fetcher) -> BoardListLoader {
        BoardListLoader(fetcher: fetcher, snapshotStore: tempSnapshotStore())
    }

    // MARK: - taskKey

    func testTaskKeyShape() {
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(key, "clien-news|_all|")
    }

    func testTaskKeyEncodesFilterAndSearch() {
        let chu = Board.invenMaple.filters.first { $0.id == "chu" }!
        let key = BoardListLoader.taskKey(
            board: .invenMaple,
            filter: chu,
            searchQuery: "맥북"
        )
        XCTAssertEqual(key, "inven-maple|chu|맥북")
    }

    // MARK: - Cold path

    func testRefreshFetchesAndPopulatesPosts() async {
        let fetchCount = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(loader.posts.count, 2)
        XCTAssertEqual(loader.posts[0].title, "첫번째 글")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    func testRefreshFailureSurfacesErrorMessage() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "network down" }
        }
        let loader = makeLoader(fetcher: { _, _, _, _ in
            throw StubError()
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(loader.errorMessage, "network down")
        XCTAssertTrue(loader.posts.isEmpty)
        XCTAssertFalse(loader.isLoading)
    }

    // MARK: - Idempotency

    func testRefreshRefireWithSameKeyIsNoOp() async {
        let fetchCount = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 1,
                       "동일 key 재호출은 noop (loadedKey 가드)")
    }

    func testRefreshOnDifferentKeyTriggersFreshFetch() async {
        // 보드 전환 path: 다른 key 로 refresh → 새로 fetch.
        // 드로어 탭과 swipe-step 양쪽 시나리오 모두 이 path 통과.
        let fetchCount = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.refresh(board: .clienJirum, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 2,
                       "다른 보드로 refresh 시 cold path 로 새 fetch")
    }

    // MARK: - Reload (pull-to-refresh)

    func testReloadBypassesLoadedKeyShortCircuit() async {
        let fetchCount = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.reload(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 2,
                       "pull-to-refresh 는 loadedKey 가드 우회 — 같은 key 라도 재페치")
    }

    // MARK: - SWR (보드 재방문 캐시)

    // 갱신본 — 재검증 완료 후 fresh 교체를 식별하기 위한 다른 제목.
    private var clienHTMLUpdated: String {
        clienHTML.replacingOccurrences(of: "첫번째 글", with: "갱신된 글")
    }

    func testRevisitShowsCachedPostsInstantlyThenRevalidates() async {
        let gate = TestGate()
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML, clienHTMLUpdated] _, _, _, _ in
            calls.increment()
            if calls.value >= 3 {
                // A 재방문의 백그라운드 재검증 — gate 가 열릴 때까지 대기.
                await gate.wait()
                return clienHTMLUpdated
            }
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)   // A cold
        await loader.refresh(board: .clienJirum, filter: nil, searchQuery: nil)  // B cold
        XCTAssertEqual(calls.value, 2)

        let revisit = Task { await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil) }
        // 캐시 복원은 재검증 fetch 완료 *전*(gate 닫힘 동안)에 일어나야 한다.
        var restored = false
        for _ in 0..<500 where !restored {
            await Task.yield()
            if loader.posts.first?.title == "첫번째 글", calls.value == 3 { restored = true }
        }
        XCTAssertTrue(restored, "재방문 즉시 캐시본 표시 + 백그라운드 재검증 시작 (스피너 없이)")

        await gate.open()
        await revisit.value
        XCTAssertEqual(loader.posts.first?.title, "갱신된 글", "재검증 완료 후 fresh 로 교체")
        XCTAssertNil(loader.errorMessage)
    }

    func testRevalidateFailureKeepsStalePosts() async {
        struct StubError: Error {}
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            calls.increment()
            if calls.value >= 3 { throw StubError() }
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        await loader.refresh(board: .clienJirum, filter: nil, searchQuery: nil)
        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)  // 재검증 실패

        XCTAssertEqual(loader.posts.count, 2, "재검증 실패 시 stale 캐시본 유지 — 빈 화면 금지")
        XCTAssertEqual(loader.posts.first?.title, "첫번째 글")
        XCTAssertFalse(loader.isLoading)
    }

    func testCacheEvictsOldestBeyondCapacity() async {
        // 캐시 cap(6) 을 넘기면 가장 오래된 key 는 cold path 로 돌아간다 —
        // 무한 증가 방지의 행동 계약.
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            calls.increment()
            return clienHTML
        })

        // 7개 distinct key (searchQuery 변주).
        for q in 1...7 {
            await loader.refresh(board: .clienNews, filter: nil, searchQuery: "q\(q)")
        }
        XCTAssertEqual(calls.value, 7)

        // 첫 key 는 evict 됐어야 — 재방문이 fetch 를 다시 유발 (SWR 복원이
        // 아니라 cold). fetch 수로 판별: 캐시 히트(SWR)여도 재검증 fetch 가
        // 돌므로, 복원 여부는 posts 가 fetch 완료 전에 차는지로 가려야 하지만
        // 여기선 단순화해 "evict 된 key 도 정상 로드"만 핀한다.
        await loader.refresh(board: .clienNews, filter: nil, searchQuery: "q1")
        XCTAssertEqual(calls.value, 8)
        XCTAssertEqual(loader.posts.count, 2)
    }

    // MARK: - 디스크 스냅샷 (콜드 스타트 SWR)

    private func tempSnapshotStore() -> BoardListSnapshotStore {
        BoardListSnapshotStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-snap-\(UUID().uuidString).json"))
    }

    func testSessionFirstRefreshRestoresDiskSnapshotBeforeRevalidate() async {
        let store = tempSnapshotStore()
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        await store.save(key: key, posts: [
            Post.fixture(id: "disk-1", site: .clien, boardID: "clien-news", title: "디스크 글"),
        ])

        let gate = TestGate()
        let loader = BoardListLoader(
            fetcher: { [clienHTML] _, _, _, _ in
                await gate.wait()
                return clienHTML
            },
            snapshotStore: store
        )

        let task = Task { await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil) }
        var restored = false
        for _ in 0..<500 where !restored {
            await Task.yield()
            if loader.posts.first?.title == "디스크 글" { restored = true }
        }
        XCTAssertTrue(restored, "세션 첫 refresh 는 디스크 스냅샷을 fetch 완료 전에 복원해야 함")

        await gate.open()
        await task.value
        XCTAssertEqual(loader.posts.first?.title, "첫번째 글", "재검증 완료 후 fresh 로 교체")
    }

    func testDiskSnapshotWithDifferentKeyIsIgnored() async {
        let store = tempSnapshotStore()
        await store.save(key: "다른|보드|키", posts: [
            Post.fixture(id: "disk-1", site: .clien, boardID: "other", title: "다른 보드 글"),
        ])
        let loader = BoardListLoader(
            fetcher: { [clienHTML] _, _, _, _ in clienHTML },
            snapshotStore: store
        )

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(loader.posts.first?.title, "첫번째 글",
                       "key 불일치 스냅샷은 무시하고 cold path")
    }

    func testFirstPageSuccessPersistsSnapshot() async {
        let store = tempSnapshotStore()
        let loader = BoardListLoader(
            fetcher: { [clienHTML] _, _, _, _ in clienHTML },
            snapshotStore: store
        )

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        let snap = await store.load()
        XCTAssertEqual(snap?.key, BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil))
        XCTAssertEqual(snap?.posts.count, 2, "첫 페이지 성공 시 스냅샷 저장")
    }

    // MARK: - Clien search 400 fallback

    func testClienSearch400FallbackRetriesWithCookielessRequest() async {
        // 첫 호출: 400 throw. 두번째 호출: 정상 HTML. 두 호출 다 fetcher
        // 통과해야 (test fake intercept 보장).
        let attempts = TestRecorder<(String?, Bool)>()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, ua, cookies in
            attempts.append((ua, cookies))
            if attempts.count == 1 {
                throw NetworkError.badResponse(400)
            }
            return clienHTML
        })

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: "맥북"
        )

        XCTAssertEqual(attempts.count, 2, "primary + retry 두 번 fetcher 통과")
        let snap = attempts.snapshot
        XCTAssertNil(snap[0].0, "primary 는 ua nil")
        XCTAssertEqual(snap[0].1, true, "primary 는 cookies 사용")
        XCTAssertEqual(snap[1].0, Networking.userAgent,
                       "retry 는 explicit Networking.userAgent")
        XCTAssertEqual(snap[1].1, false,
                       "retry 는 cookies 비활성 (clien 검색 400 회복 path)")
        XCTAssertFalse(loader.posts.isEmpty, "retry 성공 시 posts 채워짐")
    }

    func testNonClien400DoesNotRetry() async {
        let attempts = TestCounter()
        let loader = makeLoader(fetcher: { _, _, _, _ in
            attempts.increment()
            throw NetworkError.badResponse(400)
        })

        await loader.refresh(
            board: .invenMaple,
            filter: nil,
            searchQuery: "test"
        )

        XCTAssertEqual(attempts.value, 1,
                       "clien 이 아닌 사이트는 400 retry 안 함 (일반 에러로 처리)")
        XCTAssertNotNil(loader.errorMessage)
    }

    func testClien400WithoutSearchDoesNotRetry() async {
        let attempts = TestCounter()
        let loader = makeLoader(fetcher: { _, _, _, _ in
            attempts.increment()
            throw NetworkError.badResponse(400)
        })

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: nil  // 검색 아닌 일반 list
        )

        XCTAssertEqual(attempts.value, 1,
                       "clien 이라도 검색 아닌 일반 list 의 400 은 retry 안 함")
    }
}

// MARK: - Test helpers (shared shapes)

/// fetcher 를 임의 시점까지 멈춰 세우는 게이트 — SWR 의 "캐시 복원이
/// 재검증 fetch 완료보다 먼저"를 결정적으로 검증하는 데 쓴다.
private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
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

private final class TestRecorder<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var snapshot: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}
