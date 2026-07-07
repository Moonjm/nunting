import XCTest
@testable import nunting

// @MainActor: 검증 대상 스토어/로더가 main actor 소속 — Swift 6 모드에서
// nonisolated 테스트가 동기 접근할 수 없어 테스트 클래스를 main actor 로 올린다.
@MainActor
final class HistoryTabSelectionStateTests: XCTestCase {
    // 히스토리(4)는 탭 전환이 아니라 순수 재노출 버튼 — 선택 탭을 바꾸지 않는다.
    // (바꾸면 tab4 의 빈 화면이 한 프레임 노출돼 상세 슬라이드-인 중 깜빡인다.)
    func testHistorySelectionDoesNotChangeSelectedTab() {
        var state = HistoryTabSelectionState(selectedTab: 1)

        state.selectTab(4)

        XCTAssertEqual(state.selectedTab, 1)
    }

    func testSelectingNormalTabChangesSelection() {
        var state = HistoryTabSelectionState(selectedTab: 0)

        state.selectTab(2)

        XCTAssertEqual(state.selectedTab, 2)
    }

    func testHistorySelectionFromAnyTabKeepsThatTab() {
        var state = HistoryTabSelectionState(selectedTab: 0)

        state.selectTab(1)
        state.selectTab(4)

        XCTAssertEqual(state.selectedTab, 1)
    }
}
