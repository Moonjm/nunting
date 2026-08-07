import XCTest
@testable import nunting

/// 보드 전환 스위처(⌄ 보드명 헤더)는 목록 상태와 무관하게 항상 보여야 한다.
///
/// 회귀: 스위처가 `listView` 의 첫 List 행으로만 존재해, 글을 못 불러온 보드
/// (쿨엔조이 파서 실패 등)에선 `ContentUnavailableView` 만 남고 보드 목록이
/// 통째로 사라졌다. 맨 앞 보드가 그 상태면 좌우 스와이프 말곤 다른 보드로
/// 갈 방법이 없다. 목록이 없는 상태에선 스위처를 상태 뷰 위에 따로 얹는다.
final class BoardListHeaderVisibilityTests: XCTestCase {
    private let query = "그래픽카드"

    // MARK: - contentState

    func testInactivePageIsLoadingEvenWithoutFetch() {
        // 비활성 페이지는 fetch 를 안 했으므로 빈 목록이 정상 — "글이 없습니다"
        // 로 오표시하지 않고 스피너.
        XCTAssertEqual(
            BoardListView.contentState(isActive: false, isLoading: false, errorMessage: nil,
                                       postCount: 0, searchQuery: nil),
            .loading
        )
    }

    func testColdLoadIsLoading() {
        XCTAssertEqual(
            BoardListView.contentState(isActive: true, isLoading: true, errorMessage: nil,
                                       postCount: 0, searchQuery: nil),
            .loading
        )
    }

    func testErrorWithNoPosts() {
        XCTAssertEqual(
            BoardListView.contentState(isActive: true, isLoading: false, errorMessage: "목록 0건",
                                       postCount: 0, searchQuery: nil),
            .failed("목록 0건")
        )
    }

    func testSearchEmptyCarriesTrimmedQuery() {
        XCTAssertEqual(
            BoardListView.contentState(isActive: true, isLoading: false, errorMessage: nil,
                                       postCount: 0, searchQuery: "  \(query) "),
            .searchEmpty(query)
        )
        // 공백뿐인 질의는 검색이 아니다.
        XCTAssertEqual(
            BoardListView.contentState(isActive: true, isLoading: false, errorMessage: nil,
                                       postCount: 0, searchQuery: "   "),
            .empty
        )
    }

    /// 글이 하나라도 있으면 로딩·에러 여부와 무관하게 목록을 그린다 —
    /// 리로드 스피너나 페이징 실패가 이미 보이는 목록을 덮으면 안 된다.
    func testAnyPostWins() {
        for (loading, error) in [(true, nil), (false, "실패"), (true, "실패")] as [(Bool, String?)] {
            XCTAssertEqual(
                BoardListView.contentState(isActive: true, isLoading: loading, errorMessage: error,
                                           postCount: 1, searchQuery: nil),
                .list
            )
        }
    }

    // MARK: - 스위처 노출

    /// 핵심 핀: 목록이 없는 **모든** 상태에서 스위처를 따로 얹어야 한다.
    func testSwitcherShownAboveEveryPlaceholder() {
        for state: BoardListView.ContentState in [.loading, .failed("실패"), .searchEmpty(query), .empty] {
            XCTAssertTrue(
                BoardListView.showsStandaloneSwitcher(showsBoardNameHeader: true, state: state),
                "\(state) 에서 보드 스위처가 사라지면 그 보드에 갇힌다"
            )
        }
    }

    /// 목록이 있으면 스크롤어웨이 첫 행(List 안)이 담당하므로 따로 얹지 않는다
    /// — 둘 다 그리면 보드명이 두 번 나온다.
    func testSwitcherNotDuplicatedOverList() {
        XCTAssertFalse(BoardListView.showsStandaloneSwitcher(showsBoardNameHeader: true, state: .list))
    }

    /// 내비바 타이틀이 있는 둘러보기 목록(showsBoardNameHeader == false)에는
    /// 종전대로 헤더가 없다.
    func testSwitcherOffWhenHeaderDisabled() {
        for state: BoardListView.ContentState in [.loading, .failed("실패"), .empty, .list] {
            XCTAssertFalse(BoardListView.showsStandaloneSwitcher(showsBoardNameHeader: false, state: state))
        }
    }
}
