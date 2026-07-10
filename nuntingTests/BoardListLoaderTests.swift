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
// @MainActor: 검증 대상 스토어/로더가 main actor 소속 — Swift 6 모드에서
// nonisolated 테스트가 동기 접근할 수 없어 테스트 클래스를 main actor 로 올린다.
@MainActor
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
    /// 텔레메트리도 no-op 주입 — 기본값(.shared)은 실서버로 업로드한다.
    private func makeLoader(fetcher: @escaping BoardListLoader.Fetcher) -> BoardListLoader {
        BoardListLoader(
            fetcher: fetcher, snapshotStore: tempSnapshotStore(), telemetry: noopTelemetry())
    }

    private func noopTelemetry() -> ParserFailureTelemetry {
        ParserFailureTelemetry(sender: { _, _, _ in })
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

    // MARK: - 보드 전환 reload (목록 비움 + 스피너)

    func testReloadClearingListEmptiesPostsWhenFetchFails() async {
        // 보드 전환(clearingList: true)은 목록을 즉시 비운다 → 실패한 재요청은
        // 다시 채우지 않으므로 빈 채로 남는다(스피너/에러 상태). 먼 보드가
        // 헐렸다 새 loader 로 재생성되는 것과 동일한 "비웠다 채움" 피드백.
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            calls.increment()
            if calls.value == 1 { return clienHTML }
            throw URLError(.timedOut)
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(loader.posts.count, 2)

        await loader.reload(board: .clienNews, filter: nil, searchQuery: nil, clearingList: true)

        XCTAssertTrue(loader.posts.isEmpty,
                      "clearingList 는 목록을 비우고, 실패한 재요청은 다시 채우지 않음")
        XCTAssertNotNil(loader.errorMessage)
    }

    func testReloadWithoutClearingKeepsPostsWhenFetchFails() async {
        // 대조군: 기본 reload(pull-to-refresh)는 실패해도 이전 목록을 유지 —
        // 네이티브 새로고침 스피너가 있고 깜빡임을 피하기 위함.
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            calls.increment()
            if calls.value == 1 { return clienHTML }
            throw URLError(.timedOut)
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(loader.posts.count, 2)

        await loader.reload(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(loader.posts.count, 2,
                       "기본 reload 는 새로고침 중 이전 목록을 유지")
    }

    // MARK: - 보드 재방문 = 항상 fresh (사용자 선호: 최신글 우선)

    func testRevisitGoesColdAndShowsFreshPosts() async {
        // A→B→A 왕복: 재방문도 cold path 로 새로 불러온다. 한때 SWR 캐시
        // (이전 목록 즉시 표시 + 백그라운드 재검증)를 넣었다가, "전환 시
        // 이전 목록 유지보다 최신글을 새로 뿌리는 게 좋다"는 피드백으로
        // 의도적으로 되돌림 — 이 테스트가 그 결정을 핀한다. 판별 기준은
        // fetch 수가 아니라(SWR 도 재검증 fetch 를 돌림) "재방문 fetch 가
        // 진행되는 동안 이전 목록이 복원돼 있지 않은가".
        let gate = TestGate()
        let calls = TestCounter()
        let loader = makeLoader(fetcher: { [clienHTML] _, _, _, _ in
            calls.increment()
            if calls.value >= 3 { await gate.wait() }
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)   // A
        await loader.refresh(board: .clienJirum, filter: nil, searchQuery: nil)  // B

        let revisit = Task { await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil) }
        // 재방문 fetch 가 게이트에 도달 = cold path 의 posts=[] / isLoading=true
        // 가 이미 적용된 시점. 폴링 없이 그 시점을 결정적으로 잡는다.
        await gate.waitUntilEntered()
        XCTAssertEqual(calls.value, 3)
        XCTAssertTrue(loader.posts.isEmpty, "재방문은 이전 목록 복원 없이 cold path (스피너 + 최신글)")
        XCTAssertTrue(loader.isLoading)

        await gate.open()
        await revisit.value
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
        // fetch 가 게이트에 도달 = 디스크 복원(snapshotStore.load → posts)이
        // 끝나고 재검증 fetch 로 진입한 시점. 폴링 없이 그 시점을 잡는다.
        await gate.waitUntilEntered()
        XCTAssertEqual(loader.posts.first?.title, "디스크 글",
                       "세션 첫 refresh 는 디스크 스냅샷을 fetch 완료 전에 복원해야 함")

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

    // MARK: - 빈 목록 센티널 (structureChanged)

    /// 실질 페이지 크기(임계 이상)인데 목록 셀렉터가 0건 매칭되는 HTML —
    /// 사이트 목록 마크업 개편 시나리오.
    private var fullSizeRowlessHTML: String {
        "<html><body>"
            + String(repeating: "<div class=\"redesigned\">내용</div>\n", count: 600)
            + "</body></html>"
    }

    func testEmptyParseOnFullSizePageSurfacesStructureChanged() async {
        let store = tempSnapshotStore()
        let fetchCount = TestCounter()
        let loader = BoardListLoader(
            fetcher: { [fullSizeRowlessHTML] _, _, _, _ in
                fetchCount.increment()
                return fullSizeRowlessHTML
            },
            snapshotStore: store,
            telemetry: noopTelemetry()
        )

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(loader.errorMessage.map { $0.contains("구조가 바뀐") }, true,
                       "실질 크기 페이지의 0건 파싱은 빈 보드가 아니라 structureChanged 에러")
        XCTAssertTrue(loader.posts.isEmpty)

        let snap = await store.load()
        XCTAssertNil(snap, "structureChanged 는 멀쩡한 콜드 스타트 스냅샷을 덮어쓰면 안 됨")

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 2,
                       "structureChanged 는 loadedKey 미설정 — 재진입 시 재시도해야 함")
    }

    func testEmptyParseOnSmallPageIsGenuinelyEmptyBoard() async {
        let fetchCount = TestCounter()
        let loader = makeLoader(fetcher: { _, _, _, _ in
            fetchCount.increment()
            return "<html><body></body></html>"
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertNil(loader.errorMessage, "임계 미만 크기의 0건은 정상 빈 보드로 커밋")
        XCTAssertTrue(loader.posts.isEmpty)

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1, "정상 커밋이므로 loadedKey 가드로 재진입 noop")
    }

    func testStructureChangedSentinelReportsListTelemetry() async {
        let exp = expectation(description: "telemetry sent")
        nonisolated(unsafe) var recorded: (site: String, phase: String)?
        let telemetry = ParserFailureTelemetry(sender: { site, phase, _ in
            recorded = (site, phase)
            exp.fulfill()
        })
        let loader = BoardListLoader(
            fetcher: { [fullSizeRowlessHTML] _, _, _, _ in fullSizeRowlessHTML },
            snapshotStore: tempSnapshotStore(),
            telemetry: telemetry
        )

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(recorded?.site, "clien")
        XCTAssertEqual(recorded?.phase, "list")
    }

    func testEmptySearchResultOnFullSizePageIsNotStructureChanged() async {
        let loader = makeLoader(fetcher: { [fullSizeRowlessHTML] _, _, _, _ in
            fullSizeRowlessHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: "존재하지않는검색어")

        XCTAssertNil(loader.errorMessage,
                     "검색 0건은 실질 크기 페이지여도 정상 결과 — 센티널 제외")
        XCTAssertTrue(loader.posts.isEmpty)
    }
}

// MARK: - Test helpers (shared shapes)

/// fetcher 를 임의 시점까지 멈춰 세우는 게이트 — SWR 의 "캐시 복원이
/// 재검증 fetch 완료보다 먼저"를 결정적으로 검증하는 데 쓴다.
private actor TestGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        // 진입 신호 — `waitUntilEntered()` 가 폴링 없이 깨어나도록.
        hasEntered = true
        for w in entryWaiters { w.resume() }
        entryWaiters = []
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 누군가 `wait()` 에 진입할 때까지 결정적으로 대기. fetch 가 게이트에
    /// 걸린(=로딩 상태가 관찰 가능해진) 시점을 `Task.yield()` 폴링 없이
    /// 잡는다.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
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
