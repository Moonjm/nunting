import UIKit

/// 업로드가 끝날 때까지 앱이 suspend 되지 않게 잡아 두는 창.
///
/// 왜 필요했나 — `FootprintLogger.onBackground()` 는 백그라운드 진입 순간의
/// 샘플을 남기고 곧바로 `flush()` 한다. 그런데 flush 는 fire-and-forget 이라,
/// iOS 가 그 직후 프로세스를 suspend 하면 POST 가 출발도 못 하고 배치가
/// 통째로 사라진다. 하필 메모리 진단에서 제일 중요한 순간(백그라운드 직전의
/// footprint, 그리고 그 뒤 백그라운드에서 죽었는지 여부를 가르는 마지막 점)이
/// 그 배치에 실려 있다.
///
/// 카운팅이 필요한 이유: flush 는 버퍼가 찰 때(`flushThreshold`)도 불려서 두
/// 업로드가 겹칠 수 있다. 창을 단순 열기/닫기로 두면 먼저 끝난 쪽이 아직
/// 날고 있는 쪽의 창까지 닫는다. 들어온 수를 세어 **마지막 하나**가 끝날 때만
/// 닫는다.
///
/// 세대(`Ticket`)가 필요한 이유: 만료로 창이 강제로 닫히면 그때 날고 있던
/// 업로드들은 나중에 각자 `leave()` 를 부른다. 세대 없이 수만 세면 그 뒤늦은
/// 완료가 **그 사이 새로 열린 창**의 카운터를 깎아, 아직 보내는 중인데 창이
/// 조기에 닫힌다(= 이 타입이 막으려던 바로 그 유실). 창이 닫힐 때마다 세대를
/// 올려 이전 세대의 완료를 무시한다.
///
/// primitive 를 주입으로 뺀 이유는 `UIApplication` 없이 이 규칙들을
/// 검증하기 위해서다(`MemoryPressureResponder` 와 같은 seam 패턴).
@MainActor
final class BackgroundFlushWindow {
    /// `enter()` 가 돌려주는 영수증. 같은 세대의 `leave()` 만 카운터를 깎는다.
    /// 호출부가 값을 지어낼 수 없게 이니셜라이저를 감춘다.
    struct Ticket: Equatable {
        fileprivate let generation: Int
    }

    /// 창을 연다. 만료 콜백을 받아 식별자를 돌려준다.
    /// 기본값은 실제 `UIApplication` 배선.
    var beginTask: (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier = { expire in
        UIApplication.shared.beginBackgroundTask(withName: "footprint-flush") {
            expire()
        }
    }

    /// 창을 닫는다. 기본값은 실제 `UIApplication` 배선.
    var endTask: (UIBackgroundTaskIdentifier) -> Void = { id in
        UIApplication.shared.endBackgroundTask(id)
    }

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var pending = 0
    private var generation = 0

    /// 테스트용 — 지금 창이 열려 있는지.
    var isOpenForTesting: Bool { taskID != .invalid }
    /// 테스트용 — 아직 끝나지 않은 업로드 수.
    var pendingForTesting: Int { pending }

    /// 업로드 하나가 시작됐다. 창이 닫혀 있으면 연다.
    func enter() -> Ticket {
        pending += 1
        if taskID == .invalid {
            taskID = beginTask { [weak self] in
                // 만료 = OS 가 시간을 회수했다. 남은 업로드가 있든 없든 창은
                // 반드시 닫아야 한다(안 닫으면 앱이 강제 종료된다).
                self?.close()
            }
        }
        return Ticket(generation: generation)
    }

    /// 업로드 하나가 끝났다. 마지막 하나였으면 창을 닫는다.
    /// 이미 닫힌 세대의 영수증은 무시한다.
    func leave(_ ticket: Ticket) {
        guard ticket.generation == generation, pending > 0 else { return }
        pending -= 1
        guard pending == 0 else { return }
        close()
    }

    /// 창을 닫고 세대를 올린다 — 지금 날고 있는 업로드들의 영수증을 한꺼번에
    /// 무효화한다.
    private func close() {
        pending = 0
        generation &+= 1
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        endTask(id)
    }
}
