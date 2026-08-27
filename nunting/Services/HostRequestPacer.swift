import Foundation

/// 사이트가 서버측에서 거는 요청률 제한을, **클라이언트에서 미리 지켜** 거절
/// 자체를 없애는 게이트.
///
/// 왜 필요했나 — 뽐뿌(`nginx limit_req`)에 429 재시도를 붙였더니 "다시 시도"는
/// 줄었지만 요청의 47%가 여전히 거절이었고(계측 3배치 68건 중 429 32건),
/// 성공한 요청도 백오프를 물어 5초씩 걸렸다. 재시도는 **가끔 튀는** 429 를
/// 흡수하는 장치지, 평균 요청률이 서버 허용치를 넘는 상태의 답이 아니다.
/// 오히려 429 하나가 요청 4개로 불어나 리필된 토큰을 먹고, 그게 다음 요청의
/// 429 를 만드는 증폭 고리가 됐다(실측 타임라인에 그대로 찍혔다).
///
/// 그래서 초과분을 **거절당하는 대신 기다리게** 한다. 같은 요청이 0.5초 뒤에
/// 나가면 200 을 받는다 — 지금처럼 429 를 맞고 최대 5초를 무는 것보다 짧다.
/// 429 재시도는 안전망으로 남지만 실제로는 거의 타지 않게 된다.
///
/// 버킷은 **사이트 단위**다(호스트 단위가 아니라) — `m.` 과 `www.` 는 같은
/// nginx 뒤에 있어 한 버킷을 공유한다. 이미지(cdn2)는 이 경로를 안 탄다
/// (SDWebImage 가 따로 받는다).
actor HostRequestPacer {
    static let shared = HostRequestPacer()

    /// 사이트별 허용치. `capacity` 는 유휴 상태에서 즉시 나갈 수 있는 요청 수,
    /// `perSecond` 는 그 뒤의 정상 속도.
    struct Limit: Sendable {
        let capacity: Double
        let perSecond: Double
    }

    /// 서버 실측치(2026-08-27)보다 **일부러 낮게** 잡는다. 뽐뿌 nginx 는
    /// 버스트 ~10, 리필 ~2/s 였는데 여기서 10 을 그대로 쓰면 우리 계산과
    /// 서버 계산이 조금만 어긋나도 바로 429 다. 6 이면 여유가 남는다.
    /// 다른 사이트는 제한이 관측되지 않아 게이트하지 않는다(nil).
    static func limit(for site: Site) -> Limit? {
        switch site {
        case .ppomppu:
            Limit(capacity: 6, perSecond: 2)
        case .clien, .coolenjoy, .inven, .aagag, .humor, .bobae, .slr,
             .ddanzi, .cook82, .etoland, .damoang:
            nil
        }
    }

    /// 다음 요청이 나갈 수 있는 가장 이른 시각(단조 시계 초). 슬롯을 미리
    /// 예약하는 방식이라 동시 호출이 같은 슬롯을 두 번 집지 않는다 —
    /// 토큰을 세고 나서 자면, 자는 동안 들어온 호출이 같은 토큰을 또 센다.
    private var nextSlot: [Site: Double] = [:]

    private let clock: @Sendable () -> Double
    private let sleeper: @Sendable (Double) async throws -> Void

    init(clock: @escaping @Sendable () -> Double = HostRequestPacer.monotonicSeconds,
         sleeper: @escaping @Sendable (Double) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.clock = clock
        self.sleeper = sleeper
    }

    /// 시스템 시계 조정에 영향받지 않는 단조 시계 — 백그라운드 복귀 때 시계가
    /// 튀면 슬롯이 과거로 밀려 버스트가 통째로 열린다.
    nonisolated static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// 이 사이트로 요청을 보내도 되는 시점까지 기다린다. 제한이 없는 사이트는
    /// 즉시 반환. 취소는 그대로 던진다 — 게이트에서 자는 동안 보드를 넘기면
    /// 그 요청은 더 보낼 이유가 없다.
    func acquire(site: Site?) async throws {
        guard let site, let limit = Self.limit(for: site), limit.perSecond > 0 else { return }
        let wait = reserveSlot(site: site, limit: limit)
        guard wait > 0 else { return }
        try await sleeper(wait)
    }

    /// 슬롯 예약 + 대기 시간 계산. `await` 없이 끝나므로 액터 안에서 원자적이다.
    ///
    /// 유휴 구간은 `capacity` 개까지 "적립"된다: 마지막 슬롯이 아무리 오래
    /// 전이어도 `now - burstWindow` 아래로는 안 내려가므로, 오래 쉬었다고
    /// 무제한으로 몰아 쏘지는 않는다.
    private func reserveSlot(site: Site, limit: Limit) -> Double {
        let now = clock()
        let interval = 1 / limit.perSecond
        let burstWindow = (limit.capacity - 1) * interval
        let base = max(nextSlot[site] ?? (now - burstWindow), now - burstWindow)
        nextSlot[site] = base + interval
        return max(base - now, 0)
    }
}
