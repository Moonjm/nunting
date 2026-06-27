import SwiftUI
import XCTest
@testable import nunting

/// BoardListView 의 Equatable 계약 — PostDetailView 와 동일한 패턴. 셸 body
/// 는 보드 전환/스크롤 상태 변화마다 재평가되며 그때마다 새 closure 를 만들어
/// 뷰에 넘긴다. SwiftUI 는 closure 를 비교할 수 없어 "바뀌었을 수도"로 취급
/// → 매 프레임 body 재평가. `==` 가 diffable 입력만 비교해야 `.equatable()`
/// 이 이 churn 을 끊는다. (@Observable 인 readStore 는 property 단위 추적으로
/// 별도 무효화되므로 `==` 에서 제외 — PostDetailView 의 loader 와 같은 근거.)
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
}
