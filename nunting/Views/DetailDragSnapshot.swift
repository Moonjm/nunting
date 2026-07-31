import SwiftUI
import UIKit

/// 백드래그 동안 살아있는 상세 계층 대신 움직일 스냅샷 한 장.
///
/// 왜: 상세를 `.offset(x:)` 로 끌면 프레임마다 그 아래 계층 전체가 다시 커밋된다.
/// 비용은 실체화된 뷰/레이어 수에 비례하고, 기기 계측(FrameHitchRecorder)이
/// 그 상관을 그대로 보여줬다 — 백드래그 16회 전수 기록, 기대 프레임 16ms 기준:
///   댓글 30행: 4프레임 드랍(최악 59ms) · 70행: 15 · 110행: 15 · 151행: 28(최악 200ms)
/// 151행이면 도착한 프레임 26장 중 28장을 놓쳐 절반 가까이가 화면에 못 나갔다.
///
/// 스냅샷은 이미 렌더된 결과를 재사용하는 UIKit `snapshotView(afterScreenUpdates:)`
/// 다 — 비트맵을 새로 그리지 않으므로(`drawHierarchy` 와 달리) 드래그 시작
/// 프레임에 얹히는 비용이 작다. 드래그 중엔 이 한 장만 움직이고 살아있는
/// 계층은 제자리에 멈춘 채 그려지지 않는다(`opacity 0`). **언마운트하지 않는
/// 것이 핵심** — 상세는 keep-alive 라 스크롤 위치·이미지·영상 상태를 잃으면 안 되고,
/// 댓글 행이 사라졌다 되살아나면 #160 의 높이 복원 실패가 그대로 재발한다.
@Observable @MainActor
final class DetailDragSnapshot {
    static let shared = DetailDragSnapshot()

    /// 지금 화면에서 상세를 대신하고 있는 스냅샷. nil 이면 평소처럼 살아있는
    /// 계층이 직접 움직인다.
    private(set) var view: UIView?

    /// 스프링(0.32s) + 애니메이션 락(350ms)이 끝나고도 남는 여유. 이보다 일찍
    /// 스냅샷을 걷으면 정착 중인 화면이 살아있는 계층으로 갈아끼워지며 튄다.
    static let settleWindow: Duration = .milliseconds(400)

    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    /// 드래그 시작 시점의 화면을 뜬다. 실패하면(스냅샷 불가) nil 로 남아
    /// 종전처럼 살아있는 계층이 움직인다 — 기능은 그대로고 히치만 남는다.
    ///
    /// `offset` 이 이미 0 이 아니면(애니메이션 도중 손가락이 다시 잡은 경우)
    /// 스냅샷에 그 이동량이 이미 찍혀 있어, 다시 offset 을 걸면 두 번 밀린다.
    /// 그 경우는 뜨지 않는다.
    func capture(from source: UIView?, currentOffset: CGFloat) {
        releaseTask?.cancel()
        releaseTask = nil
        guard view == nil, abs(currentOffset) < 0.5 else { return }
        guard let source, source.bounds.width > 0, source.bounds.height > 0 else { return }
        guard let snapshot = Self.makeSnapshot(of: source) else { return }
        snapshot.isUserInteractionEnabled = false
        view = snapshot
    }

    /// 기기에서는 `snapshotView(afterScreenUpdates:)` 가 잡힌다 — 이미 렌더된
    /// 결과를 재사용해 가장 싸다. 다만 화면에 실제로 그려지는 렌더 세션이 없는
    /// 환경(유닛 테스트 프로세스)에서는 그 API 도, `drawHierarchy` 도 빈손이라
    /// (계측으로 확인) 캡처 경로 자체를 검증할 수 없다. 그래서 레이어를 직접
    /// 그리는 폴백을 둔다 — 느리고 UIVisualEffectView 같은 합성 효과를
    /// 재현하지 못하지만, 캡처가 nil 이면 이 최적화가 통째로 무력화되므로
    /// (스냅샷 없이 종전대로 살아있는 계층이 움직임) 빈손보다 낫다.
    private static func makeSnapshot(of source: UIView) -> UIView? {
        if let snapshot = source.snapshotView(afterScreenUpdates: false) { return snapshot }

        let renderer = UIGraphicsImageRenderer(bounds: source.bounds)
        let image = renderer.image { ctx in source.layer.render(in: ctx.cgContext) }
        let imageView = UIImageView(image: image)
        imageView.frame = source.bounds
        return imageView
    }

    /// 키 윈도우 기준 캡처. 백드래그가 걸리는 시점의 상세는 화면 전체를 덮고
    /// 있으므로(불투명 배경 + safe area 무시) 윈도우 스냅샷이 곧 상세의 모습이다.
    func captureKeyWindow(currentOffset: CGFloat) {
        capture(from: Self.keyWindow, currentOffset: currentOffset)
    }

    /// 손을 뗀 뒤 — 닫기 슬라이드/스프링 복귀가 끝날 때까지 스냅샷을 유지하다 걷는다.
    func releaseAfterSettle() {
        guard view != nil, releaseTask == nil else { return }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled else { return }
            self?.releaseNow()
        }
    }

    /// 즉시 걷는다. 다른 글을 여는 경로(`DetailOverlayController.show`)가
    /// 부른다 — 정착 대기 중에 새 상세가 뜨면 지난 글의 스냅샷이 그 위를
    /// 덮어버린다.
    func releaseNow() {
        releaseTask?.cancel()
        releaseTask = nil
        view = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

/// UIKit 스냅샷 뷰를 SwiftUI 계층에 얹는다. 스냅샷은 이미 만들어진 뷰라
/// 여기서는 컨테이너에 붙이고 크기만 맞춘다.
struct DetailDragSnapshotView: UIViewRepresentable {
    let snapshot: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard snapshot.superview !== container else { return }
        snapshot.removeFromSuperview()
        snapshot.frame = container.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(snapshot)
    }
}
