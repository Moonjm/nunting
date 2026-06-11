import Foundation

/// 키워드별 알림 토글 요청의 직렬화 + 실패 복원 판정.
///
/// 토글은 절대 상태(on/off)를 보내는데 HTTP 도달 순서가 보장되지 않으므로,
/// 키워드별로 직전 요청 완료 후 다음 요청을 보내 발행 순서대로 도달하게
/// 한다 — 마지막 토글이 서버 최종 상태가 된다.
///
/// 실패 복원은 세대(generation)로 판정한다. "현재 값 == 내가 쓴 값" 비교는
/// ON(A)→OFF(B)→ON(C) 연타에서 A 의 실패가 같은 값인 C 의 낙관적 상태를
/// 잘못 되돌리고, 이후 C 가 성공해도 UI 를 다시 세우지 않아 서버=ON·UI=OFF
/// 영구 불일치를 만든다. 세대 비교면 옛 실패는 no-op 이고, 최신 요청의
/// 실패만 직전 상태로 복원한다 — 직전 요청들은 직렬화 덕에 이미 끝났으므로
/// 복원된 값이 곧 서버에 반영된 값이다.
@MainActor
final class KeywordToggleSequencer {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]

    /// `send` 는 같은 id 의 직전 요청이 끝난 뒤 호출된다. throw 시
    /// `onFailure(error, isLatest)` 가 불리고, `isLatest` 는 이 요청보다
    /// 새 submit 이 없을 때만 true — 그때만 호출부가 낙관적 전이를 되돌린다.
    @discardableResult
    func submit(
        id: String,
        send: @escaping @Sendable () async throws -> Void,
        onFailure: @escaping @MainActor (_ error: Error, _ isLatest: Bool) -> Void
    ) -> Task<Void, Never> {
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation

        let prior = tasks[id]
        let task = Task { @MainActor [weak self] in
            await prior?.value
            do {
                try await send()
            } catch {
                // self 가 사라졌으면(화면 dismiss) 복원할 UI 도 없다 → false.
                onFailure(error, self?.generations[id] == generation)
            }
        }
        tasks[id] = task
        return task
    }
}
