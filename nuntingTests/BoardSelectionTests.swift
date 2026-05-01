import XCTest
@testable import nunting

/// State-transition tests for `BoardSelection`. The state machine itself
/// is tiny but the *invariants* (atomic batches that change exactly once
/// per user action, scope-pool wrap-around, default-filter application)
/// are exactly what an earlier bug tried to violate (`taskKey`
/// double-fire on invenMaple entry). These tests pin those invariants.
final class BoardSelectionTests: XCTestCase {

    // MARK: - Construction

    func testInitAppliesDefaultFilterForBoard() {
        let selection = BoardSelection(initialBoard: .invenMaple, initialNavScope: .favorites)
        XCTAssertEqual(selection.board.id, Board.invenMaple.id)
        XCTAssertEqual(selection.filter?.id, "chu", "invenMaple 의 디폴트 필터 (10추) 자동 적용")
        XCTAssertNil(selection.searchQuery)
        XCTAssertEqual(selection.navScope, .favorites)
        XCTAssertEqual(selection.reloadToken, 0)
    }

    func testInitWithBoardWithoutDefaultFilterLeavesFilterNil() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .site(.clien))
        XCTAssertNil(selection.filter, "clienNews 는 defaultListFilter 없음")
        XCTAssertEqual(selection.navScope, .site(.clien))
    }

    // MARK: - select(_:navScope:)

    func testSelectAppliesNewBoardDefaultFilterAndClearsSearch() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .site(.clien))
        selection.searchQuery = "맥북"
        selection.filter = nil

        selection.select(.invenMaple, navScope: .favorites)

        XCTAssertEqual(selection.board.id, Board.invenMaple.id)
        XCTAssertEqual(selection.filter?.id, "chu",
                       "select 은 새 보드의 defaultListFilter 자동 적용")
        XCTAssertNil(selection.searchQuery, "select 은 검색어 클리어")
        XCTAssertEqual(selection.navScope, .favorites)
    }

    func testSelectSameBoardStillClearsSearchQuery() {
        // 같은 보드 재선택도 search 를 클리어 — 미래에 "동일 보드면
        // search 유지" 같은 최적화로 silently 회귀하지 않도록 못 박음.
        // 사용자 동선상 드로어에서 같은 보드 다시 탭하는 건 "검색
        // 그만 보고 메인 리스트로 돌아가고 싶다" 의도가 자연스러움.
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .site(.clien))
        selection.searchQuery = "딜"

        selection.select(.clienNews, navScope: .site(.clien))

        XCTAssertNil(selection.searchQuery, "동일 보드 select 도 search 클리어")
    }

    func testSelectFromInvenMapleToClienClearsFilter() {
        let selection = BoardSelection(initialBoard: .invenMaple, initialNavScope: .favorites)
        XCTAssertNotNil(selection.filter, "invenMaple → 디폴트 'chu' 가 set")

        selection.select(.clienNews, navScope: .site(.clien))

        XCTAssertNil(selection.filter,
                     "clienNews 는 defaultListFilter 가 없으니 nil 로 리셋되어야 함 — 이전 chu 가 stuck 되면 잘못된 URL")
    }

    // MARK: - step(by:within:)

    func testStepNoOpOnSinglePool() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        selection.step(by: 1, within: [.clienNews])
        XCTAssertEqual(selection.board.id, Board.clienNews.id, "1개짜리 pool 에선 step 이 noop")
    }

    func testStepNoOpWhenCurrentBoardNotInPool() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        // 현재 보드가 pool 에 없으면 idx 못 찾아 noop. drawerSection 이
        // .favorites 인데 즐겨찾기엔 다른 보드만 들어있을 때.
        selection.step(by: 1, within: [.invenMaple, .aagag])
        XCTAssertEqual(selection.board.id, Board.clienNews.id)
    }

    func testStepForwardWraps() {
        let pool: [Board] = [.clienNews, .invenMaple, .aagag]
        let selection = BoardSelection(initialBoard: .aagag, initialNavScope: .favorites)
        selection.step(by: 1, within: pool)
        XCTAssertEqual(selection.board.id, Board.clienNews.id, "끝에서 +1 → 처음으로 wrap")
    }

    func testStepBackwardWraps() {
        let pool: [Board] = [.clienNews, .invenMaple, .aagag]
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        selection.step(by: -1, within: pool)
        XCTAssertEqual(selection.board.id, Board.aagag.id, "처음에서 -1 → 끝으로 wrap")
    }

    func testStepAppliesDestinationDefaultFilter() {
        let pool: [Board] = [.clienNews, .invenMaple]
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        XCTAssertNil(selection.filter)

        selection.step(by: 1, within: pool)

        XCTAssertEqual(selection.board.id, Board.invenMaple.id)
        XCTAssertEqual(selection.filter?.id, "chu",
                       "swipe-step 도 select 과 동일하게 디폴트 필터 자동 적용")
    }

    func testStepClearsSearchQuery() {
        let pool: [Board] = [.clienNews, .invenMaple]
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        selection.searchQuery = "딜"

        selection.step(by: 1, within: pool)

        XCTAssertNil(selection.searchQuery, "step 도 검색어 클리어")
    }

    // MARK: - requestReload

    func testRequestReloadBumpsTokenAndClearsSearch() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        selection.searchQuery = "맥북"

        selection.requestReload()

        XCTAssertEqual(selection.reloadToken, 1)
        XCTAssertNil(selection.searchQuery)
    }

    func testRequestReloadAccumulates() {
        let selection = BoardSelection(initialBoard: .clienNews, initialNavScope: .favorites)
        selection.requestReload()
        selection.requestReload()
        selection.requestReload()
        XCTAssertEqual(selection.reloadToken, 3, "토큰은 호출마다 누적")
    }

    func testRequestReloadDoesNotChangeBoardOrFilter() {
        let selection = BoardSelection(initialBoard: .invenMaple, initialNavScope: .favorites)
        let originalBoard = selection.board.id
        let originalFilter = selection.filter?.id

        selection.requestReload()

        XCTAssertEqual(selection.board.id, originalBoard)
        XCTAssertEqual(selection.filter?.id, originalFilter,
                       "더블탭 reload 는 토큰만 갱신 — 보드/필터 자체는 그대로")
    }
}
