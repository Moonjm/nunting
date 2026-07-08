import XCTest
@testable import nunting

// @MainActor: 검증 대상 스토어/로더가 main actor 소속 — Swift 6 모드에서
// nonisolated 테스트가 동기 접근할 수 없어 테스트 클래스를 main actor 로 올린다.
@MainActor
final class RootTabSelectionStateTests: XCTestCase {
    func testDefaultSelectionStartsAtArchiveTab() {
        let state = RootTabSelectionState()

        XCTAssertEqual(state.selectedTab, 0)
    }

    func testSelectingNormalTabChangesSelection() {
        var state = RootTabSelectionState(selectedTab: 0)

        state.selectTab(2)

        XCTAssertEqual(state.selectedTab, 2)
    }

    func testSelectionStateStoresCallerProvidedTab() {
        var state = RootTabSelectionState(selectedTab: 1)

        state.selectTab(4)

        XCTAssertEqual(state.selectedTab, 4)
    }

    func testNormalizesMissingCurrentBoardToFirstFavorite() {
        XCTAssertEqual(
            RootTabSelectionState.normalizedBoardID(
                currentBoardID: "removed",
                favoriteBoardIDs: ["first", "second"]
            ),
            "first"
        )
    }

    func testNormalizesNilCurrentBoardToFirstFavorite() {
        XCTAssertEqual(
            RootTabSelectionState.normalizedBoardID(
                currentBoardID: nil,
                favoriteBoardIDs: ["first", "second"]
            ),
            "first"
        )
    }

    func testKeepsCurrentBoardWhenStillFavorite() {
        XCTAssertEqual(
            RootTabSelectionState.normalizedBoardID(
                currentBoardID: "second",
                favoriteBoardIDs: ["first", "second"]
            ),
            "second"
        )
    }

    func testNormalizesToNilWhenFavoritesAreEmpty() {
        XCTAssertNil(
            RootTabSelectionState.normalizedBoardID(
                currentBoardID: "removed",
                favoriteBoardIDs: []
            )
        )
    }
}
