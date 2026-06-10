import SwiftUI
import XCTest
@testable import nunting

/// BoardListView / SideDrawer 의 Equatable 계약 — PostDetailView 와 동일한
/// 패턴. ContentView body 는 드래그 중 매 프레임 재평가되며(drawerProgress /
/// detail.offset 읽기) 그때마다 새 closure 를 만들어 두 뷰에 넘긴다. SwiftUI
/// 는 closure 를 비교할 수 없어 "바뀌었을 수도"로 취급 → 매 프레임 body
/// 재평가. `==` 가 diffable 입력만 비교해야 `.equatable()` 이 이 churn 을
/// 끊는다. (@Observable 인 readStore/favorites/catalog 는 property 단위
/// 추적으로 별도 무효화되므로 `==` 에서 제외 — PostDetailView 의 loader 와
/// 같은 근거.)
@MainActor
final class RenderEquatableTests: XCTestCase {

    func testBoardListViewEqualityIgnoresClosureIdentity() {
        let readStore = ReadStore()
        func make(
            board: Board = .clienNews,
            scrollLocked: Bool = false,
            searchQuery: String? = nil
        ) -> BoardListView {
            BoardListView(
                board: board,
                filter: nil,
                searchQuery: searchQuery,
                scrollLocked: scrollLocked,
                shouldSuppressRowTap: { false },
                readStore: readStore,
                onSelectPost: { _ in }
            )
        }
        XCTAssertEqual(make(), make(), "closure identity 차이만으로 불일치하면 매 프레임 재평가가 못 끊김")
        XCTAssertNotEqual(make(), make(scrollLocked: true), "scrollLocked 플립은 body 에 전파돼야 함 (.scrollDisabled)")
        XCTAssertNotEqual(make(), make(searchQuery: "검색어"))
    }

    func testSideDrawerEqualityIgnoresClosureIdentity() {
        let favorites = FavoritesStore()
        let catalog = BoardCatalogStore()
        func make(
            currentBoardID: String? = "clien-news",
            section: DrawerSection = .favorites
        ) -> SideDrawer {
            SideDrawer(
                favorites: favorites,
                catalog: catalog,
                currentBoardID: currentBoardID,
                selectedSection: .constant(section),
                onSelectBoard: { _ in },
                onClose: {}
            )
        }
        XCTAssertEqual(make(), make())
        XCTAssertNotEqual(make(), make(currentBoardID: "other"), "현재 보드 하이라이트는 body 에 전파돼야 함")
    }
}
