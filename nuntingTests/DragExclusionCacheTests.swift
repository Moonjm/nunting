import XCTest
@testable import nunting

/// `DragExclusionCache` — 팬 제스처의 제외 분류(선택 핸들/스크럽바 위에서
/// 시작한 터치인가)를 드래그당 1회로 묶는 메모이즈. 분류 입력인
/// `value.startLocation` 은 드래그 내내 불변인데, 기존 코드는 매 틱(60~120Hz)
/// 전체 뷰 트리 재귀 + hitTest 를 반복했다.
@MainActor
final class DragExclusionCacheTests: XCTestCase {
    func testProbeRunsOncePerStartLocation() {
        var probeCalls = 0
        let cache = DragExclusionCache { _ in
            probeCalls += 1
            return .none
        }
        let start = CGPoint(x: 10, y: 20)
        XCTAssertEqual(cache.kind(at: start), .none)
        XCTAssertEqual(cache.kind(at: start), .none)
        XCTAssertEqual(cache.kind(at: start), .none)
        XCTAssertEqual(probeCalls, 1, "같은 드래그(동일 startLocation) 동안 프로브는 1회만 실행돼야 함")
    }

    func testNewStartLocationReclassifies() {
        // onEnded 가 안 불린 채(제스처 취소) 다음 드래그가 시작돼도, 시작점이
        // 다르면 stale 분류를 재사용하지 않아야 한다.
        var answers: [DragExclusionCache.Kind] = [.selectionHandle, .scrubBar]
        let cache = DragExclusionCache { _ in answers.removeFirst() }
        XCTAssertEqual(cache.kind(at: CGPoint(x: 1, y: 1)), .selectionHandle)
        XCTAssertEqual(cache.kind(at: CGPoint(x: 2, y: 2)), .scrubBar, "다른 시작점 = 새 드래그 — 재분류")
    }

    func testResetForcesReclassificationAtSameStart() {
        // 드래그 종료(resetDragState) 후엔 같은 좌표에서 새 드래그가 시작돼도
        // 뷰 계층이 바뀌었을 수 있으므로(선택 해제 등) 다시 분류해야 한다.
        var probeCalls = 0
        let cache = DragExclusionCache { _ in
            probeCalls += 1
            return .scrubBar
        }
        let start = CGPoint(x: 5, y: 5)
        XCTAssertEqual(cache.kind(at: start), .scrubBar)
        cache.reset()
        XCTAssertEqual(cache.kind(at: start), .scrubBar)
        XCTAssertEqual(probeCalls, 2, "reset 후엔 같은 시작점도 재분류")
    }
}
