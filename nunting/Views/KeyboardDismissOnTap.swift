import SwiftUI
import UIKit

/// 키보드가 올라온 상태에서 **입력 필드/버튼이 아닌** 다른 영역을 탭하면 키보드를
/// 내린다. List/Form 은 SwiftUI 의 `onTapGesture` 로 빈 영역 탭을 못 잡으므로,
/// key window 에 탭 인식기를 달아 처리한다.
///
/// - `cancelsTouchesInView = false`: 탭이 아래 뷰(행/버튼)에도 그대로 전달돼
///   기존 동작(스와이프, 버튼)을 막지 않는다.
/// - delegate 가 UIControl(텍스트필드/버튼) 서브트리 위 탭은 무시 → 필드 포커스와
///   버튼 탭이 정상 동작.
@MainActor
final class KeyboardDismissTapCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissTapCoordinator()

    private weak var window: UIWindow?
    private var recognizer: UITapGestureRecognizer?
    /// 설치 참조 수. 여러 화면이 동시에 쓰거나 화면 전환 시 install/remove 가
    /// 겹쳐도(새 화면 install 후 옛 화면 remove) 0 이 될 때까지 인식기를 유지.
    private var installCount = 0

    func install() {
        installCount += 1
        // 이미 살아있는 window 에 부착돼 있으면 카운트만 증가.
        if recognizer != nil, window != nil { return }
        // 미설치 or weak window 가 해제된 경우 → 현재 key window 에 (재)부착.
        // (window 가 아직 없으면 다음 install 때 재시도)
        guard let window = Self.keyWindow else { return }
        recognizer = nil  // 죽은 window 의 stale 참조 정리
        let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        self.recognizer = tap
        self.window = window
    }

    func remove() {
        installCount = max(0, installCount - 1)
        guard installCount == 0 else { return }
        if let recognizer, let window {
            window.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        window = nil
    }

    // 텍스트필드/버튼 등 UIControl 서브트리 위 탭은 무시(포커스·버튼 동작 보존).
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // 제스처 델리게이트 콜백은 메인스레드 터치 루프에서 동기 호출됨 → 메인액터
        // 격리 UI 프로퍼티 접근 허용. (전제 위반 시 assumeIsolated 가 trap)
        MainActor.assumeIsolated {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }

    // 다른 제스처(스크롤/스와이프)와 동시 인식 허용 — 가로채지 않음.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

extension View {
    /// 입력 필드 밖 영역 탭 시 키보드를 내린다. 화면 등장/퇴장에 맞춰 인식기를
    /// 설치/해제해 전역 누적을 막는다.
    func dismissKeyboardOnBackgroundTap() -> some View {
        onAppear { KeyboardDismissTapCoordinator.shared.install() }
            .onDisappear { KeyboardDismissTapCoordinator.shared.remove() }
    }
}
