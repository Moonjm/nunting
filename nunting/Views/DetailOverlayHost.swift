import SwiftUI
import UIKit

/// 상세 오버레이의 위치를 **UIKit 레이어 변환으로** 소유하는 상자.
///
/// 왜 이렇게 하나 — 기기에서 뜬 백드래그 정체 구간의 메인 스레드 스택이 원인을
/// 확정했다:
///   12  CoreGraphics  CGGlyphBuilderLockBitmaps
///   18  CoreGraphics  CGDisplayListDrawInContextDelegate
/// 드래그 중 메인 스레드가 100~150ms 씩 **글리프를 다시 래스터화**하고 있었다.
/// SwiftUI 는 호스팅 뷰의 콘텐츠를 하나의 디스플레이 리스트로 그리는데, 그
/// 안의 `offset` 값이 프레임마다 바뀌면 리스트 전체가 무효화된다 — 화면에
/// 보이는 몇 줄이 아니라 실체화된 댓글 116~148줄의 텍스트가 매 프레임 다시
/// 그려졌다. 비용이 댓글 수에 비례한 것도, 스냅샷·투명도·창 밖 이동·셸 격리가
/// 전부 무관했던 것도(모두 같은 디스플레이 리스트 안의 일이다) 이걸로 설명된다.
///
/// 그래서 상세를 **자기 `UIHostingController`** 에 담아 셸과 분리된 디스플레이
/// 리스트를 갖게 하고, 이동은 그 뷰의 `transform` 으로만 한다. 레이어 변환은
/// 이미 래스터화된 결과를 합성만 옮기므로 다시 그리지 않는다 —
/// UINavigationController 의 인터랙티브 pop 이 큰 화면에서도 부드러운 이유가
/// 이 구조다.
///
/// 히스토리 버튼으로 여는 경로가 원래 부드러웠던 것도 같은 원리였다(SwiftUI 가
/// 애니메이션을 레이어 애니메이션으로 처리해 매 프레임 다시 그리지 않았다).
/// 이제 그 경로도 여기로 합류한다.
@MainActor
final class DetailOverlayTransform {
    static let shared = DetailOverlayTransform()

    /// 실제로 움직이는 뷰 — `DetailOverlayHost` 가 심어 준다. weak 인 이유:
    /// 오버레이가 사라져도 이 싱글톤이 뷰를 붙들고 있으면 안 된다.
    weak var target: UIView?

    /// 진단 계측 — 드래그 한 번 동안 호스팅 트리가 업데이트 패스를 몇 번
    /// 받았는지. 레이아웃이 도는 계기를 찾는 축이다(0 이면 레이아웃은 다른
    /// 데서 촉발된 것이고, 1 이상이면 셸 재평가가 여전히 새고 있다는 뜻).
    var hostUpdates = 0

    /// 논리적 위치(0 = 완전히 보임, containerWidth = 오른쪽으로 완전히 숨음).
    /// 드래그 중에는 이 값만 바뀌고 SwiftUI 상태는 건드리지 않는다.
    private(set) var offset: CGFloat = 0

    /// 손가락을 따라가는 즉시 반영 — 애니메이션 없이 변환만 갈아끼운다.
    func track(_ newOffset: CGFloat) {
        offset = newOffset
        guard let target else { return }
        // 진행 중인 애니메이션이 있으면 걷어낸다(드래그가 스프링을 가로챌 때).
        target.layer.removeAnimation(forKey: "position")
        target.transform = CGAffineTransform(translationX: newOffset, y: 0)
    }

    /// 스프링으로 이동 — 손을 뗀 뒤의 복귀/닫기. `DetailOverlayController` 의
    /// 스프링 파라미터와 맞춘다.
    func animate(to newOffset: CGFloat, completion: (() -> Void)? = nil) {
        offset = newOffset
        guard let target else {
            completion?()
            return
        }
        let transform = CGAffineTransform(translationX: newOffset, y: 0)
        UIView.animate(
            withDuration: 0.32,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            target.transform = transform
        } completion: { _ in
            completion?()
        }
    }

    /// 애니메이션 없이 즉시 자리 잡기 — 첫 표시처럼 "그 자리에서 시작" 이
    /// 필요한 경우.
    func snap(to newOffset: CGFloat) {
        offset = newOffset
        target?.transform = CGAffineTransform(translationX: newOffset, y: 0)
    }
}

/// 상세 콘텐츠를 자기 `UIHostingController` 에 담아 셸의 디스플레이 리스트와
/// 분리한다. 컨테이너(대표 뷰)는 SwiftUI 가 배치하고, 그 안의 호스팅 뷰만
/// `DetailOverlayTransform` 이 옮긴다 — SwiftUI 가 프레임을 다시 잡아도
/// 변환이 덮어써지지 않게 두 층으로 나눈 것이다.
struct DetailOverlayHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> DetailOverlayContainerController<Content> {
        let controller = DetailOverlayContainerController(rootView: content)
        DetailOverlayTransform.shared.target = controller.movableView
        // 새로 심은 뷰에 현재 위치를 즉시 반영 — 오버레이가 숨겨진 상태에서
        // 다시 만들어지면(다른 글로 교체 등) 0 에서 시작해 잠깐 보인다.
        DetailOverlayTransform.shared.snap(to: DetailOverlayTransform.shared.offset)
        return controller
    }

    func updateUIViewController(
        _ controller: DetailOverlayContainerController<Content>,
        context: Context
    ) {
        DetailOverlayTransform.shared.hostUpdates += 1
        controller.update(rootView: content)
        if DetailOverlayTransform.shared.target !== controller.movableView {
            DetailOverlayTransform.shared.target = controller.movableView
            DetailOverlayTransform.shared.snap(to: DetailOverlayTransform.shared.offset)
        }
    }
}

/// 호스팅 컨트롤러를 자식으로 품는 컨테이너. 자식으로 붙이는 이유는 생명주기
/// (appearance/trait/safe area 전파)를 UIKit 이 정상적으로 굴리게 하기 위해서다
/// — 호스팅 뷰만 떼어 붙이면 그 배선이 끊긴다.
@MainActor
final class DetailOverlayContainerController<Content: View>: UIViewController {
    private let hosting: UIHostingController<Content>

    /// 변환이 걸리는 뷰 — 컨테이너가 아니라 이 뷰를 옮긴다.
    var movableView: UIView { hosting.view }

    init(rootView: Content) {
        hosting = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 컨테이너 뷰를 직접 만든다 — 옮겨진 자식 밖의 터치를 통과시켜야 하므로
    /// (`PassthroughView` 주석 참고) 기본 UIView 로는 안 된다.
    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // 오버레이가 화면 밖으로 나가는 동안 뒤(보드 목록)가 비쳐야 하므로
        // 컨테이너는 투명하고, 실제 배경은 상세 콘텐츠가 그린다.
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        // 프레임 + autoresizingMask 가 아니라 제약으로 붙이는 이유: 컨테이너가
        // 아직 레이아웃되지 않은 시점(bounds 가 .zero)에 프레임을 잡으면
        // autoresizing 이 그 zero 기준으로 비율을 잡아 자식이 엉뚱한 크기·위치로
        // 남는다. 제약은 변환(transform)과 독립적으로 "변환 전 레이아웃" 을
        // 정의하므로 둘을 같이 써도 안전하다.
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    func update(rootView: Content) {
        hosting.rootView = rootView
    }
}

/// 컨테이너는 화면 전체를 덮지만, 그 안의 상세는 변환으로 화면 밖에 나가 있을
/// 수 있다. 기본 UIView 는 배경이 투명해도 자기 영역의 터치를 먹으므로, 상세가
/// 옆으로 비켜난 동안 뒤(보드 목록)가 통째로 먹통이 된다 — 실제로 그렇게 됐다.
/// 자식(옮겨진 상세)에 실제로 닿는 터치만 받고 나머지는 통과시킨다.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 자기 자신이 걸렸다 = 자식 어디에도 안 닿았다는 뜻이므로 통과.
        return hit === self ? nil : hit
    }
}
