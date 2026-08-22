import Foundation
import SwiftUI

/// 마운트 한 번의 표시 계측 기산점.
///
/// 클래스인 이유는 하나다: `.onSuccess` 클로저는 **뷰를 만들 때** 캡처되고 콜백은
/// 그 뒤에 온다. 값을 캡처하면 항상 그 시점의 스냅샷(대개 nil = 0ms)으로 굳어
/// 계측이 통째로 죽는다. 참조를 넘겨야 콜백이 도는 시점의 값을 읽는다.
final class LoadClock {
    var startedAt: Date?
}

/// 표시 계측의 기산점을 **마운트 수명에 묶어** 소유하는 래퍼.
///
/// 왜 필요한가 — 기산점을 부모 `@State` 로 두면 자식만 리마운트될 때 값이 남는다.
/// `NetworkImage` 는 그 리마운트가 잦다: 디코드 박스가 바뀌면 `.id(loadIdentity)`
/// 가 갈리고, 뷰포트를 벗어나면 이미지가 통째로 해제됐다 다시 붙는다. 남은
/// 기산점을 다음 마운트가 그대로 쓰면 표시 시간에 "최초 등장 이후 전부" 가
/// 섞여 백분위가 오염된다 — 우리가 그 백분위로 성능 판정을 하고 있으므로
/// 조용히 틀린 결론을 내게 된다(Codex 리뷰 2026-08-22 지적).
///
/// `@State` 는 뷰 identity 단위로 새로 만들어지므로, 시계를 이 래퍼 안에 두면
/// 마운트마다 정확히 하나가 생기고 그 마운트와 함께 사라진다.
///
/// 내용 클로저가 `@ViewBuilder` 가 **아닌** 것도 의도다 — 시계를 인자로 받아
/// `.onSuccess` 안에서 읽어야 하므로 평범한 클로저여야 한다.
struct MountClock<Content: View>: View {
    @State private var clock = LoadClock()
    let content: (LoadClock) -> Content

    init(@_implicitSelfCapture content: @escaping (LoadClock) -> Content) {
        self.content = content
    }

    var body: some View {
        content(clock)
            // 마운트 시각 = 무거운 이미지 뷰가 실제로 붙은 순간(=로드 시작).
            .onAppear { clock.startedAt = Date() }
    }
}
