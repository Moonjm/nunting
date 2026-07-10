import XCTest
@testable import nunting

/// `BoardListView.isActive` — 페이저 비활성 페이지(센티널/이웃)의 fetch 게이트.
///
/// §3.2: TabView(.page)가 페이지를 materialize 하면 `.task` 가 목록 fetch +
/// 상세 3건 프리페치를 돌린다. 센티널/이웃 페이지는 보이기 전에 materialize
/// 될 수 있어(스와이프 드래그 중 등) 안 볼 보드의 fetch 가 낭비되고, 도착 시
/// reloadToken 리로드와 이중 fetch 가 된다. `isActive == false` 면 `.task` 가
/// fetch 를 건너뛰고, 실제 도착(활성화)은 기존 reloadToken 경로가 fresh 로드를
/// 담당한다(fresh-우선 정책 그대로).
@MainActor
final class BoardListViewActiveGateTests: XCTestCase {
    private func view(isActive: Bool) -> BoardListView {
        BoardListView(
            board: .clienNews,
            isActive: isActive,
            readStore: ReadStore(defaults: UserDefaults(suiteName: "test-active-gate")!),
            onSelectPost: { _ in }
        )
    }

    /// 가장 중요한 핀: `isActive` 는 `==` 에 포함되어야 한다. `.equatable()` 이
    /// body 재평가를 끊는 뷰라, `==` 에서 빠지면 활성화 플립(false→true)이
    /// 전파되지 않아 페이지가 영영 placeholder 에 갇힌다.
    func testEquatableIncludesIsActive() {
        XCTAssertFalse(view(isActive: false) == view(isActive: true),
                       "isActive 가 == 에서 빠지면 활성화가 뷰에 전파되지 않는다")
        XCTAssertTrue(view(isActive: true) == view(isActive: true))
    }

    /// 활성화(false→true)는 `.task(id:)` 를 재시작시켜야 한다 — id 에 활성
    /// 상태가 빠지면, 비활성으로 materialize 된 페이지가 토큰 bump 없이
    /// 활성화되는 경로(페이저 분기 재생성 등)에서 영영 미로드로 갇힌다
    /// (Codex P2). refresh 가 loadedKey 멱등이라 재시작 자체는 로드된
    /// 보드에서 no-op.
    func testTaskIDChangesOnActivation() {
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertNotEqual(BoardListView.taskID(key: key, isActive: false),
                          BoardListView.taskID(key: key, isActive: true),
                          "활성 상태가 task id 에 반영되지 않으면 활성화가 로드를 못 깨운다")
        XCTAssertEqual(BoardListView.taskID(key: key, isActive: true),
                       BoardListView.taskID(key: key, isActive: true))
    }

    /// 파라미터 기본값은 true — 페이저 밖 호출부(둘러보기/단일 보드)는 종전처럼
    /// materialize 즉시 로드해야 한다.
    func testDefaultIsActive() {
        let v = BoardListView(
            board: .clienNews,
            readStore: ReadStore(defaults: UserDefaults(suiteName: "test-active-gate")!),
            onSelectPost: { _ in }
        )
        XCTAssertTrue(v == view(isActive: true))
    }
}
