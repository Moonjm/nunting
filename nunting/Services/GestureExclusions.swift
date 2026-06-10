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

// MARK: - UIKit 계층 프로브 (GestureCoordinator 분리 파일)
//
// 팬 상태기계(GestureCoordinator.swift)와 별개로 묶인 "키 윈도우 계층을
// 직접 들여다보는" 코드 — 제외 분류 프로브 2종과 선택 해제 액션.
// 메서드들은 cross-file extension 이라 `private` 일 수 없다(internal);
// coordinator 외부에서 부를 일은 없다.

extension GestureCoordinator {
    /// Walk the key window's view hierarchy to find the (at most one)
    /// UITextView that currently has a non-empty selection, then
    /// return `true` if `point` lies within an asymmetric box around
    /// either of its selection-handle anchors. UITextView's own
    /// handle hit-area is tight (~22pt), so a touch landing slightly
    /// off the visible blue circle isn't recognized as a handle drag
    /// and falls into back-swipe classification. Inflate the
    /// effective hit zone — but as a wide-but-short box, not a
    /// 44pt-radius circle:
    ///   * Horizontal `±28pt`: generous slop for users aiming
    ///     sideways of the handle.
    ///   * Vertical `±16pt`: tight enough that handles on adjacent
    ///     text lines don't bleed into each other across every
    ///     Dynamic Type size. The smallest body line height (xSmall,
    ///     ~18pt) puts the adjacent line's top 18pt from the anchor —
    ///     just outside 16pt — so an above-line back-swipe still
    ///     routes to back-drag, not to a phantom handle grab. (A
    ///     circular 44pt radius reached up to 2 lines above/below at
    ///     default line height, which produced the "3-line body,
    ///     bottom-line selection, back-drag from line 1 freezes" bug.
    ///     A tighter 15pt extent worked too but barely covers the
    ///     handle dot's center; 16pt picks up a touch more handle
    ///     slop while still excluding xSmall's adjacent line.)
    ///
    /// `point` is in key-window coordinates (panGesture uses
    /// `coordinateSpace: .global`).
    func touchStartedNearSelectionHandle(at point: CGPoint) -> Bool {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        guard let tv = findTextViewWithActiveSelection(in: window) else { return false }
        return tv.selectionHandleAnchorsInWindow().contains { anchor in
            abs(point.x - anchor.x) <= 28 && abs(point.y - anchor.y) <= 16
        }
    }

    /// True when the back-drag's starting touch landed inside an
    /// inline video's scrub strip. `VideoScrubBarView` conforms to
    /// `InlineVideoScrubBarMarking`; hit-testing the key window at
    /// `point` and walking the superview chain catches every active
    /// strip without exposing the otherwise-private class. Bailing
    /// here keeps a rightward scrub drag from also driving the
    /// detail-screen back-slide: the scrub UIKit pan starts at 10pt
    /// of horizontal motion while this SwiftUI DragGesture begins
    /// at 6pt, so without the skip the back-drag would have a 4pt
    /// head start and lock direction to horizontal before the scrub
    /// had a chance to take over.
    func touchStartedOnScrubBar(at point: CGPoint) -> Bool {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        var view = window.hitTest(point, with: nil)
        while let v = view {
            if v is InlineVideoScrubBarMarking { return true }
            view = v.superview
        }
        return false
    }

    /// Resign first responder ONLY on the UITextView that currently
    /// holds a non-empty selection — leaving any other editable
    /// view in the hierarchy (search bar, future comment compose
    /// field) untouched. Used at detail-dismissal time so the iOS
    /// edit menu (Copy / Look Up / Translate) doesn't strand on top
    /// of the list after the overlay slides off-screen. The detail
    /// view is kept mounted on dismiss (it's a `.offset()` slide-
    /// out, not a SwiftUI removal), so without explicit teardown
    /// the text view stays first responder forever and UIKit keeps
    /// its menu visible.
    ///
    /// Scoped to foreground-active scenes only — background scenes
    /// on iPad multi-window may legitimately hold their own
    /// selections that an unrelated dismiss shouldn't clear.
    func resignSelectedTextResponder() {
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let tv = findTextViewWithActiveSelection(in: window) {
                    tv.resignFirstResponder()
                }
            }
        }
    }

    /// Recurse the view tree and stop at the first UITextView with a
    /// non-empty selection. Across the app at most one text view can
    /// hold the system selection at any moment (selecting in one
    /// clears the prior selection), so we don't have to enumerate the
    /// entire tree — first match wins.
    private func findTextViewWithActiveSelection(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView,
           let range = tv.selectedTextRange,
           !range.isEmpty {
            return tv
        }
        for sub in view.subviews {
            if let hit = findTextViewWithActiveSelection(in: sub) {
                return hit
            }
        }
        return nil
    }
}

private extension UITextView {
    /// Window-coordinate positions of the two selection handles for
    /// the current `selectedTextRange`. Uses `selectionRects(for:)`
    /// (rather than `caretRect(for:)` of the range endpoints) so
    /// selections ending on a soft line-wrap return the visual end
    /// of the previous line rather than a zero-width rect at x=0 on
    /// the next line — handles sit at the trailing glyph position,
    /// not at the start of the next line. Returns `[]` when no
    /// selection rects are available.
    func selectionHandleAnchorsInWindow() -> [CGPoint] {
        guard let range = selectedTextRange, !range.isEmpty else { return [] }
        let rects = selectionRects(for: range)
        guard !rects.isEmpty else { return [] }
        // Start handle sits at the top-left of the rect that contains
        // the selection start; end handle at the bottom-right of the
        // rect that contains the selection end (assumes LTR layout —
        // for RTL the visual-left/right relationship to start/end
        // flips; the parsers in this app only emit Korean / Latin
        // text so LTR is safe). `containsStart` / `containsEnd` flag
        // those rects directly.
        let startRect = rects.first(where: { $0.containsStart })?.rect
            ?? rects.first?.rect
        let endRect = rects.first(where: { $0.containsEnd })?.rect
            ?? rects.last?.rect
        var anchors: [CGPoint] = []
        if let r = startRect {
            anchors.append(convert(CGPoint(x: r.minX, y: r.minY), to: nil))
        }
        if let r = endRect {
            anchors.append(convert(CGPoint(x: r.maxX, y: r.maxY), to: nil))
        }
        return anchors
    }
}
