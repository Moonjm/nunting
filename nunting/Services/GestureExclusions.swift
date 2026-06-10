import UIKit

/// 팬 제스처 제외 분류(터치 시작점이 텍스트 선택 핸들 / 인라인 영상 스크럽바
/// 위인가)의 드래그당 1회 메모이즈.
///
/// 분류 입력인 `DragGesture.Value.startLocation` 은 드래그 내내 불변이므로
/// 답도 불변인데, 분류 자체는 비싸다 — 키 윈도우 전체 서브뷰 트리 재귀
/// (`findTextViewWithActiveSelection`) + `hitTest` 가 매 틱(60~120Hz) 돌면
/// 긴 본문(이미지·댓글 수백 뷰)의 백드래그에서 메인 스레드 비용이 누적된다.
/// 시작점을 키로 캐시해 드래그당 1회로 줄인다.
///
/// 키가 시작점이라서 stale 안전: 제스처가 취소돼 `.onEnded` 가 안 불려도
/// 다음 드래그는 (서브픽셀 정밀도의) 다른 시작점으로 들어와 재분류된다.
/// 정상 종료 경로는 `GestureCoordinator.resetDragState()` 가 `reset()` 을
/// 불러, 같은 좌표의 새 드래그도 바뀐 뷰 계층(선택 해제 등)을 다시 본다.
@MainActor
final class DragExclusionCache {
    enum Kind {
        /// 선택 핸들 그랩 — UITextView 의 핸들 팬이 동작하도록 백드래그가 양보.
        case selectionHandle
        /// 인라인 영상 스크럽 스트립 — 플레이어의 UIKit 팬이 소유.
        case scrubBar
        /// 제외 대상 아님 — 팬 상태기계가 정상 처리.
        case none
    }

    private let probe: @MainActor (CGPoint) -> Kind
    private var cached: (start: CGPoint, kind: Kind)?

    init(probe: @escaping @MainActor (CGPoint) -> Kind) {
        self.probe = probe
    }

    func kind(at start: CGPoint) -> Kind {
        if let cached, cached.start == start { return cached.kind }
        let kind = probe(start)
        cached = (start, kind)
        return kind
    }

    func reset() {
        cached = nil
    }
}
