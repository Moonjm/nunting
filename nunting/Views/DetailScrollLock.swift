import SwiftUI
import UIKit

/// 백드래그가 진행되는 동안 상세의 내부 스크롤을 잠그는 스위치.
///
/// 왜 SwiftUI `.scrollDisabled` 이 아닌가 — 그 값은 `PostDetailView` 의
/// Equatable 입력이었고, 드래그가 시작/끝날 때마다 뒤집히면서 상세 body 를
/// 통째로 다시 평가시켰다. 그러면 댓글 149행의 높이 측정
/// (`SelectableRichText.sizeThatFits` → TextKit 레이아웃)이 그 자리에서 다시
/// 돌아간다. 기기에서 뜬 정체 구간 스택에 그 프레임이 그대로 찍혔다:
///   16  nunting.debug.dylib  nunting.SelectableRichText.sizeThatFits
///
/// 그래서 잠금 상태는 이 관찰 가능한 객체에만 두고, 그것을 읽는 뷰는 화면에
/// 아무것도 그리지 않는 0 크기 리프 하나로 제한한다. 상태가 뒤집혀도 다시
/// 평가되는 건 그 리프뿐이고, 실제 잠금은 UIScrollView 에 직접 건다.
@Observable @MainActor
final class DetailScrollLock {
    static let shared = DetailScrollLock()

    /// true 인 동안 상세 내부 스크롤이 잠긴다. 백드래그가 가로로 잠기는 순간
    /// 켜지고, 손을 뗀 뒤 정착(애니메이션 락)이 끝날 때 꺼진다.
    var isLocked = false
}

/// 잠금 상태를 읽는 **유일한** 뷰. 상세 `ScrollView` 안에 0 크기로 심는다.
struct DetailScrollLockGate: View {
    var lock = DetailScrollLock.shared

    var body: some View {
        DetailScrollLockApplier(isLocked: lock.isLocked)
            .frame(width: 0, height: 0)
    }
}

/// 감싸고 있는 `UIScrollView` 를 찾아 `isScrollEnabled` 을 직접 토글한다.
/// 잠금을 풀 때는 원래 값으로 되돌린다 — 스크롤이 원래 꺼져 있던 화면을
/// 우리가 켜 주는 일이 없도록.
private struct DetailScrollLockApplier: UIViewRepresentable {
    let isLocked: Bool

    func makeUIView(context: Context) -> GateView {
        let view = GateView()
        view.isLocked = isLocked
        return view
    }

    func updateUIView(_ view: GateView, context: Context) {
        // 값이 실제로 바뀔 때만 스크롤 뷰를 찾아 손댄다 — `updateUIView` 는
        // 부모 재평가마다 불린다(StatusBarTapScrollClaimer 와 같은 이유).
        guard view.isLocked != isLocked else { return }
        view.isLocked = isLocked
        view.apply()
    }

    final class GateView: UIView {
        var isLocked = false
        private weak var managed: UIScrollView?
        private var originalScrollEnabled = true

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            if isLocked {
                guard managed == nil, let scrollView = enclosingScrollView() else { return }
                managed = scrollView
                originalScrollEnabled = scrollView.isScrollEnabled
                scrollView.isScrollEnabled = false
            } else {
                managed?.isScrollEnabled = originalScrollEnabled
                managed = nil
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView { return scrollView }
                candidate = view.superview
            }
            return nil
        }
    }
}
