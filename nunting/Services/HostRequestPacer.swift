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

    /// 뽐뿌 실측(2026-08-27, 90초 완전 유휴 후 간격을 바꿔가며):
    ///
    ///     1초 간격 x40 → 앞 19건 연속 200, 이후 200=25 / 429=15
    ///     2초 간격 x20 → 20/20 전부 200
    ///     3초 간격 x20 → 20/20 전부 200
    ///
    /// 즉 **버스트 ~19~20, 지속 허용치는 초당 0.3건(≈3초에 1건)** 이다.
    /// nginx `limit_req rate=20r/m burst=20` 의 모양과 정확히 맞는다.
    ///
    /// 첫 판에서 이 값을 `capacity 6, perSecond 2` 로 잡았던 건 **오측이었다**.
    /// 근거로 삼은 게 8건짜리 짧은 테스트였는데, 그건 버스트 안에서만 놀다
    /// 끝나 지속 속도를 전혀 건드리지 못했다 — 그래서 게이트를 달고도 실기기
    /// 로그에서 429 가 34% 남았다(초당 1.4건만 보냈는데도 거절). 짧은 부하로
    /// 잰 속도는 버스트를 재는 것이지 rate 를 재는 게 아니다.
    ///
    /// **2026-08-28 갱신**: 위 수치는 `Referer` 없이 잰 것이었다. Referer 를
    /// 실으면(`Site.defaultReferer`) 같은 조건에서 60초 연속 60건이 전부 통과한다
    /// — 즉 "3초에 1건"은 사이트가 건 천장이 아니라 **헤더 하나를 빠뜨려 받던
    /// 대우**였다. 그래서 간격을 1초로 푼다(60초 지속으로 실증된 값). 2/s 도
    /// 40건 통과했지만 20초짜리라 근거가 얇아 올리지 않는다.
    ///
    /// 그럼에도 **게이트를 없애지는 않는다.** Referer 로 뚫린 게 rate limit zone
    /// 이 갈린 것인지 봇 휴리스틱을 통과한 것인지는 밖에서 확정할 수 없다.
    /// 후자라면 저쪽이 기준을 조이는 순간 원위치인데, 그때 게이트가 없으면
    /// 429 폭풍이 그대로 돌아온다. 헤더 하나에 기대는 것보다 요청률을 스스로
    /// 지키는 쪽이 정책 변화에 안 흔들린다.
    ///
    /// 다른 사이트는 제한이 관측되지 않아 게이트하지 않는다(nil) — 제한 없는
    /// 사이트까지 늦추면 순전한 손해다.
    static func limit(for site: Site) -> Limit? {
        switch site {
        case .ppomppu:
            Limit(capacity: 12, perSecond: 1)
        case .clien, .coolenjoy, .inven, .aagag, .humor, .bobae, .slr,
             .ddanzi, .cook82, .etoland, .damoang:
            nil
        }
    }

    /// 다음 요청이 나갈 수 있는 가장 이른 시각(단조 시계 초). 슬롯을 미리
    /// 예약하는 방식이라 동시 호출이 같은 슬롯을 두 번 집지 않는다 —
    /// 토큰을 세고 나서 자면, 자는 동안 들어온 호출이 같은 토큰을 또 센다.
    private var nextSlot: [Site: Double] = [:]

    /// 예약해 놓고 **쓰지 않은** 슬롯. 게이트에서 자다 취소된 요청은 아무것도
    /// 보내지 않았으므로 그 시각은 여전히 비어 있다 — 다음 요청이 재사용한다.
    ///
    /// 반납이 없으면 취소가 그대로 유령 예약이 된다: 보드를 넘기면 그 보드의
    /// 목록·댓글 대기 건이 한꺼번에 취소되는데, 새 보드의 첫 요청이 쓰이지도
    /// 않은 슬롯을 취소 건수만큼 기다린다(실측 재현: 취소 1건 → 3.5초가
    /// 7.0초, 4건 → 17.5초). Codex 리뷰 P1.
    private var releasedSlots: [Site: [Double]] = [:]

    private let clock: @Sendable () -> Double
    private let sleeper: @Sendable (Double) async throws -> Void

    init(clock: @escaping @Sendable () -> Double = HostRequestPacer.monotonicSeconds,
         sleeper: @escaping @Sendable (Double) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.clock = clock
        self.sleeper = sleeper
    }

    /// 슬롯 시각의 기준 시계.
    ///
    /// 두 성질이 **동시에** 필요하다:
    /// - 벽시계 조정에 안 흔들려야 한다. `Date()` 를 쓰면 시각 보정 한 번에
    ///   슬롯이 과거로 밀려 버스트가 통째로 열린다.
    /// - **기기 슬립 시간을 포함해야 한다.** 서버 버킷은 화면이 꺼져 있는
    ///   동안에도 채워지므로, 우리 시계만 멈추면 깨어났을 때 "쉰 적 없다"고
    ///   판단해 이미 지난 슬롯을 계속 기다린다(폰을 다시 들었을 때 첫 목록이
    ///   몇 초씩 멎는 모습으로 나온다).
    ///
    /// 종전의 `DispatchTime.now().uptimeNanoseconds` 는 두 번째를 어겼다.
    /// man 3 clock_gettime 이 그걸 못박아 둔다 — `CLOCK_UPTIME_RAW` 는
    /// "does not increment while the system is asleep. The returned value is
    /// identical to the result of mach_absolute_time()" 이고, `DispatchTime`
    /// 이 바로 그 `mach_absolute_time()` 기반이다. `CLOCK_MONOTONIC_RAW` 는
    /// 같은 단조성에 슬립까지 센다(Codex 리뷰 P2).
    ///
    /// 이 성질은 단위 테스트로 못 잡는다 — 시뮬레이터를 재우지 못한다. 그래서
    /// 근거를 여기 남긴다.
    nonisolated static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    /// 이 사이트로 요청을 보내도 되는 시점까지 기다린다. 제한이 없는 사이트는
    /// 즉시 반환. 취소는 그대로 던진다 — 게이트에서 자는 동안 보드를 넘기면
    /// 그 요청은 더 보낼 이유가 없다.
    func acquire(site: Site?) async throws {
        guard let site, let limit = Self.limit(for: site), limit.perSecond > 0 else { return }
        // 이미 취소된 요청은 **예약조차 하지 않는다.** 잡아 놓고 아무것도 보내지
        // 않으면 뒤 요청이 빈 자리를 기다린다 — 자다 취소된 경우와 같은 손해인데,
        // 이쪽은 버스트 안이라 안 자고 통과해서 반납 경로에 닿지도 않았다
        // (Codex 리뷰 P2).
        try Task.checkCancellation()
        let reservation = reserveSlot(site: site, limit: limit)
        guard reservation.wait > 0 else {
            // 예약과 반환 사이에 취소가 들어온 경우. 이 요청도 안 나가므로
            // (URLSession 이 아무것도 보내지 않고 실패한다) 슬롯을 돌려준다.
            if Task.isCancelled {
                release(slot: reservation.slot, site: site, limit: limit)
                throw CancellationError()
            }
            return
        }
        do {
            try await sleeper(reservation.wait)
        } catch {
            // 이 요청은 나가지 않는다 — 잡고 있던 시각을 돌려놓지 않으면
            // 뒤 요청이 빈 슬롯을 기다린다.
            release(slot: reservation.slot, site: site, limit: limit)
            throw error
        }
    }

    /// 쓰지 않은 예약을 되돌린다.
    ///
    /// 꼬리(가장 늦게 예약된 슬롯)면 `nextSlot` 을 그대로 물린다 — 자유 목록을
    /// 키우지 않는 가장 깔끔한 경우고, 연속 취소가 대개 이 모양이다. 뒤에 이미
    /// 다른 예약이 붙었으면 그 예약들은 자기 시각을 지켜야 하므로 되돌릴 수
    /// 없다 — 대신 이 시각을 자유 목록에 넣어 다음 요청이 집어가게 한다.
    private func release(slot: Double, site: Site, limit: Limit) {
        let interval = 1 / limit.perSecond
        // Double 비교라 정확히 같기를 기대하지 않는다 — 한 간격의 천분의 일이면
        // 같은 예약으로 본다.
        if let next = nextSlot[site], abs(next - (slot + interval)) < interval / 1000 {
            nextSlot[site] = slot
        } else {
            releasedSlots[site, default: []].append(slot)
        }
    }

    /// 슬롯 예약 + 대기 시간 계산. `await` 없이 끝나므로 액터 안에서 원자적이다.
    ///
    /// 유휴 구간은 `capacity` 개까지 "적립"된다: 마지막 슬롯이 아무리 오래
    /// 전이어도 `now - burstWindow` 아래로는 안 내려가므로, 오래 쉬었다고
    /// 무제한으로 몰아 쏘지는 않는다.
    private func reserveSlot(site: Site, limit: Limit) -> (slot: Double, wait: Double) {
        let now = clock()
        let interval = 1 / limit.perSecond
        let burstWindow = (limit.capacity - 1) * interval

        // 반납된 슬롯을 먼저 쓴다(가장 이른 것부터). 이미 지난 시각이면 즉시
        // 나간다 — 그 시각에 보내도 됐던 요청을 안 보냈을 뿐이라 서버 버킷엔
        // 그만큼 토큰이 차 있다. 다만 버스트 창보다 오래된 것은 버린다.
        // 안 그러면 오래 전 취소가 무제한으로 적립돼 한꺼번에 터진다.
        if var free = releasedSlots[site], !free.isEmpty {
            free.removeAll { $0 < now - burstWindow }
            if let earliest = free.min() {
                free.removeAll { $0 == earliest }
                releasedSlots[site] = free.isEmpty ? nil : free
                return (earliest, max(earliest - now, 0))
            }
            releasedSlots[site] = nil
        }

        let base = max(nextSlot[site] ?? (now - burstWindow), now - burstWindow)
        nextSlot[site] = base + interval
        return (base, max(base - now, 0))
    }
}
