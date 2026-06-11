import Foundation

/// 키워드별 알림 토글 요청의 직렬화 + 실패 복원 판정.
///
/// 토글은 절대 상태(on/off)를 보내는데 HTTP 도달 순서가 보장되지 않으므로,
/// 키워드별로 직전 요청 완료 후 다음 요청을 보내 발행 순서대로 도달하게
/// 한다 — 마지막 토글이 서버 최종 상태가 된다.
///
/// 실패 복원은 두 가지로 판정한다:
/// - **누가**: 세대(generation) 비교 — 이 요청보다 새 submit 이 있으면
///   그쪽이 상태의 주인이라 복원하지 않는다(restoreTo nil). "현재 값 ==
///   내가 쓴 값" 비교는 ON(A)→OFF(B)→ON(C) 연타에서 A 의 실패가 같은
///   값인 C 의 낙관적 상태를 잘못 되돌린다.
/// - **무엇으로**: 마지막 ack(성공)된 서버 값 — `!value` 고정 복원은 직전
///   요청도 실패한 경우(연속 실패) 서버에 반영된 적 없는 값으로 되돌려
///   서버/UI 가 갈라진다. 첫 submit 직전의 UI 값은 loadAll 로 동기된
///   서버 값이므로 그걸로 시드한다(호출부의 "값이 실제로 바뀔 때만 submit"
///   가드가 직전 값 = `!value` 를 보장).
@MainActor
final class KeywordToggleSequencer {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    /// 키워드별 서버가 마지막으로 ack 한 enabled 값. 첫 submit 시 토글
    /// 직전 값으로 시드, 이후 send 성공마다 갱신.
    private var lastAcknowledged: [String: Bool] = [:]

    /// `send` 는 같은 id 의 직전 요청이 끝난 뒤 호출된다. throw 시
    /// `onFailure(error, restoreTo)` 가 불린다 — `restoreTo` 는 이 요청이
    /// 여전히 최신일 때 마지막 ack 된 서버 값(낙관적 전이를 되돌릴 목표),
    /// 더 새 submit 이 있으면 nil(복원 금지).
    @discardableResult
    func submit(
        id: String,
        value: Bool,
        send: @escaping @Sendable () async throws -> Void,
        onFailure: @escaping @MainActor (_ error: Error, _ restoreTo: Bool?) -> Void
    ) -> Task<Void, Never> {
        if lastAcknowledged[id] == nil {
            lastAcknowledged[id] = !value
        }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation

        let prior = tasks[id]
        let task = Task { @MainActor [weak self] in
            await prior?.value
            do {
                try await send()
                self?.lastAcknowledged[id] = value
            } catch {
                // self 가 사라졌으면(화면 dismiss) 복원할 UI 도 없다 → nil.
                let isLatest = self?.generations[id] == generation
                onFailure(error, isLatest ? self?.lastAcknowledged[id] : nil)
            }
            // 체인 꼬리(최신 요청)가 끝나면 완료 Task 참조를 정리한다.
            if let self, self.generations[id] == generation {
                self.tasks[id] = nil
            }
        }
        tasks[id] = task
        return task
    }
}
