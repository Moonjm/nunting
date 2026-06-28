import XCTest
@testable import nunting

final class HistoryTabSelectionStateTests: XCTestCase {
    func testSelectingHistoryPresentsCoverAndRestoresPreviousTabOnDismiss() {
        var state = HistoryTabSelectionState(selectedTab: 1)

        state.selectTab(4)

        XCTAssertEqual(state.selectedTab, 4)
        XCTAssertTrue(state.showingHistory)
        XCTAssertEqual(state.tabBeforeHistory, 1)

        state.setHistoryShowing(false)

        XCTAssertEqual(state.selectedTab, 1)
        XCTAssertFalse(state.showingHistory)
    }

    func testRepeatedHistorySelectionKeepsOriginalPreviousTab() {
        var state = HistoryTabSelectionState(selectedTab: 2)

        state.selectTab(4)
        state.selectTab(4)

        XCTAssertEqual(state.tabBeforeHistory, 2)
        XCTAssertTrue(state.showingHistory)
    }

    func testOpeningHistoryFromNormalTabUpdatesPreviousTab() {
        var state = HistoryTabSelectionState(selectedTab: 0)

        state.selectTab(1)
        state.selectTab(4)

        XCTAssertEqual(state.tabBeforeHistory, 1)
        XCTAssertTrue(state.showingHistory)
    }
}
