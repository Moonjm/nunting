import XCTest
@testable import nunting

/// `HostRequestPacer` 계약 — 서버 rate limit 을 클라이언트에서 미리 지킨다.
///
/// 검증 대상은 "몇 개까지 즉시 나가고, 그 뒤 얼마나 벌어지는가"와 "동시 호출이
/// 같은 슬롯을 두 번 집지 않는가"다. 후자가 이 클래스의 존재 이유에 가깝다 —
/// 토큰을 세고 나서 자는 순진한 구현은 자는 동안 들어온 호출이 같은 토큰을
/// 다시 세서, 게이트를 달고도 버스트가 그대로 나간다.
final class HostRequestPacerTests: XCTestCase {

    /// 가짜 시계 + 대기 기록. 실제로 자지 않으므로 테스트가 즉시 끝난다.
    /// 요청된 대기만큼 시계를 앞으로 돌려 "기다렸다"를 재현한다.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 1_000
        private(set) var waits: [Double] = []

        var now: Double {
            lock.lock(); defer { lock.unlock() }
            return seconds
        }

        func read() -> Double { now }

        func sleep(_ duration: Double) {
            lock.lock(); defer { lock.unlock() }
            waits.append(duration)
            seconds += duration
        }

        func advance(_ duration: Double) {
            lock.lock(); defer { lock.unlock() }
            seconds += duration
        }

        var recordedWaits: [Double] {
            lock.lock(); defer { lock.unlock() }
            return waits
        }
    }

    private func makePacer(_ clock: FakeClock) -> HostRequestPacer {
        HostRequestPacer(clock: { clock.read() }, sleeper: { clock.sleep($0) })
    }

    // MARK: - 버스트와 정상 속도

    func testAllowsCapacityImmediatelyThenPacesAtSteadyRate() async throws {
        // 상수가 아니라 **동작**을 핀한다: capacity 만큼 즉시, 그 뒤로는 정확히
        // 한 간격씩. 값 자체의 타당성은 아래 실측 테스트가 따로 지킨다.
        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let capacity = Int(limit.capacity)
        let interval = 1 / limit.perSecond
        let clock = FakeClock()
        let pacer = makePacer(clock)

        for _ in 0..<(capacity + 3) { try await pacer.acquire(site: .ppomppu) }

        XCTAssertEqual(
            clock.recordedWaits.count, 3, "capacity(\(capacity))건은 대기 없이 나가야 함")
        for wait in clock.recordedWaits {
            XCTAssertEqual(wait, interval, accuracy: 0.001)
        }
    }

    /// 실측에 대한 안전 마진을 지킨다. 이 숫자를 올리는 변경은 곧 실기기
    /// 429 로 돌아온다 — 첫 판(2/s, Referer 없이)이 정확히 그래서 실패했고,
    /// 그때 로그가 "초당 1.4건만 보냈는데 거절"이었다.
    ///
    /// 기준선은 2026-08-28 재측정이다: `Site.defaultReferer` 로 Referer 를
    /// 실은 상태에서 **1초 간격 60건이 60초 연속 전부 200**. 그 값을 그대로
    /// 상한으로 쓴다. 더 촘촘하게 잡으려면 같은 길이의 지속 측정을 다시 해야
    /// 한다 — 짧은 부하는 버스트를 재는 것이지 rate 를 재는 게 아니다.
    func testPpomppuLimitStaysWithinMeasuredServerAllowance() throws {
        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let interval = 1 / limit.perSecond

        XCTAssertGreaterThanOrEqual(
            interval, 1.0, "지속 간격이 실증된 값(1초)보다 촘촘함")
        // 실측 버스트 ~19~20. 그보다 크면 첫 화면에서 바로 거절당한다.
        XCTAssertLessThanOrEqual(
            limit.capacity, 19, "버스트가 실측치를 넘음")
    }

    /// 게이트를 푼 근거가 Referer 라, 그 둘은 세트로 유지돼야 한다. Referer 를
    /// 빼면(= `defaultReferer` 가 nil 이 되면) 허용치가 3초에 1건으로 되돌아가는데
    /// 게이트만 1초로 남아 있으면 429 폭풍이 그대로 돌아온다.
    func testRateLimitedSiteAlsoSendsDefaultReferer() {
        XCTAssertNotNil(
            Site.ppomppu.defaultReferer,
            "요청률 게이트를 푼 근거가 Referer 다 — 둘은 같이 있어야 한다")
    }

    func testIdlePeriodRefillsBurstButDoesNotBankBeyondCapacity() async throws {
        // 오래 쉬었다고 무제한으로 몰아 쏘면 게이트가 없는 것과 같다.
        let clock = FakeClock()
        let pacer = makePacer(clock)

        let capacity = Int(HostRequestPacer.limit(for: .ppomppu)?.capacity ?? 0)
        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        XCTAssertTrue(clock.recordedWaits.isEmpty)

        clock.advance(600)  // 10분 유휴 — 이론상 토큰이 넘치도록

        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        XCTAssertTrue(
            clock.recordedWaits.isEmpty,
            "유휴 뒤엔 capacity 만큼 즉시 나가야 함")

        try await pacer.acquire(site: .ppomppu)
        XCTAssertEqual(
            clock.recordedWaits.count, 1,
            "capacity 를 넘긴 7번째는 적립분이 아무리 많아도 기다려야 함")
    }

    // MARK: - 동시 호출

    func testConcurrentAcquiresDoNotShareASlot() async throws {
        // 슬롯 예약이 원자적이지 않으면 동시 10건이 전부 "대기 0" 으로 통과해
        // 서버가 보는 버스트는 그대로다.
        let clock = FakeClock()
        let pacer = makePacer(clock)
        let start = clock.now

        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let capacity = Int(limit.capacity)
        let interval = 1 / limit.perSecond
        let excess = 4
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(capacity + excess) {
                group.addTask { try? await pacer.acquire(site: .ppomppu) }
            }
        }

        let waits = clock.recordedWaits
        XCTAssertEqual(waits.count, excess, "capacity 만큼만 즉시 — 나머지는 대기해야 함")
        // 판정 지표는 대기값의 다양성이 아니라 **소비한 총 시간**이다. 가짜 시계가
        // sleep 마다 전진하므로, 슬롯이 안 겹쳤다면 각 대기는 정확히 한 간격
        // (0.5초)이고 총 전진은 (10 - capacity) / rate = 2초가 된다. 같은 슬롯을
        // 두 번 집으면 그 호출의 대기가 0 이 돼 총합이 줄어든다.
        for wait in waits {
            XCTAssertEqual(wait, interval, accuracy: 0.001, "슬롯이 겹쳤음")
        }
        XCTAssertEqual(clock.now - start, Double(excess) * interval, accuracy: 0.001,
                       "초과분이 간격만큼 벌어져 나가야 함")
    }

    // MARK: - 제한 없는 사이트

    func testUnlimitedSitePassesThroughWithoutSleeping() async throws {
        // 제한이 관측되지 않은 사이트까지 늦추면 순전한 손해다.
        let clock = FakeClock()
        let pacer = makePacer(clock)

        for _ in 0..<50 { try await pacer.acquire(site: .clien) }

        XCTAssertTrue(clock.recordedWaits.isEmpty)
        XCTAssertNil(HostRequestPacer.limit(for: .clien))
        XCTAssertNotNil(HostRequestPacer.limit(for: .ppomppu))
    }

    func testNilSiteIsAPassThrough() async throws {
        // `Site.detect` 가 못 알아본 호스트(외부 링크 등)는 게이트 대상이 아니다.
        let clock = FakeClock()
        let pacer = makePacer(clock)

        try await pacer.acquire(site: nil)

        XCTAssertTrue(clock.recordedWaits.isEmpty)
    }

    // MARK: - 취소된 예약 반납

    func testCancelledWaiterReleasesItsSlot() async throws {
        // 게이트에서 자다 취소된 요청은 **아무것도 보내지 않는다**. 그런데도
        // 예약을 붙들고 있으면, 보드를 넘긴 뒤의 새 요청이 쓰이지도 않은
        // 슬롯을 기다린다 — 취소가 여러 건이면 그만큼 곱해진다.
        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let capacity = Int(limit.capacity)
        let interval = 1 / limit.perSecond
        let clock = FakeClock()
        // 첫 취소 1건만 던지고 이후는 정상 대기.
        let failNext = Flag()
        let pacer = HostRequestPacer(
            clock: { clock.read() },
            sleeper: { duration in
                if failNext.take() { throw CancellationError() }
                clock.sleep(duration)
            })

        // 버스트를 다 쓴 뒤 한 건이 대기에 들어가 취소된다.
        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        failNext.set()
        do {
            try await pacer.acquire(site: .ppomppu)
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        // 취소된 요청은 나가지 않았으므로 그 슬롯은 비어 있다 — 다음 요청이
        // 그 자리를 그대로 써야 한다(추가 대기 없이 한 간격만).
        try await pacer.acquire(site: .ppomppu)

        XCTAssertEqual(clock.recordedWaits.count, 1, "취소분만큼 더 기다리면 안 됨")
        XCTAssertEqual(clock.recordedWaits.first ?? -1, interval, accuracy: 0.001)
    }

    func testMultipleCancellationsDoNotStackPhantomDelay() async throws {
        // 보드 전환 한 번에 목록·댓글 여러 건이 동시에 취소되는 상황.
        // 반납이 없으면 새 보드의 첫 요청이 취소 건수 x 간격만큼 밀린다.
        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let capacity = Int(limit.capacity)
        let interval = 1 / limit.perSecond
        let clock = FakeClock()
        let failNext = Flag()
        let pacer = HostRequestPacer(
            clock: { clock.read() },
            sleeper: { duration in
                if failNext.take() { throw CancellationError() }
                clock.sleep(duration)
            })

        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        for _ in 0..<4 {
            failNext.set()
            do {
                try await pacer.acquire(site: .ppomppu)
                XCTFail("expected cancellation")
            } catch is CancellationError {}
        }

        try await pacer.acquire(site: .ppomppu)

        XCTAssertEqual(
            clock.recordedWaits.first ?? -1, interval, accuracy: 0.001,
            "취소 4건이 유령 예약으로 쌓여 다음 요청을 밀면 안 됨")
    }

    func testReleasedSlotIsReusedWhenLaterReservationsExist() async throws {
        // 꼬리 되돌리기로는 못 푸는 경우: 취소된 요청 **뒤에 이미 다른 예약이
        // 붙어** 있으면 `nextSlot` 을 물릴 수 없다(뒷 예약이 자기 시각을 지켜야
        // 한다). 그 시각은 자유 목록으로 가서 다음 요청이 집어가야 한다.
        let limit = try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu))
        let capacity = Int(limit.capacity)
        let clock = FakeClock()
        let box = PacerBox()
        let nested = Flag()

        let pacer = HostRequestPacer(
            clock: { clock.read() },
            sleeper: { duration in
                if nested.take() {
                    // A 가 자는 사이 B 가 예약을 붙인다 → A 는 더 이상 꼬리가 아니다.
                    try? await box.pacer?.acquire(site: .ppomppu)
                    throw CancellationError()
                }
                clock.sleep(duration)
            })
        box.pacer = pacer

        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        XCTAssertTrue(clock.recordedWaits.isEmpty)

        nested.set()
        do {
            try await pacer.acquire(site: .ppomppu)  // A — B 를 끼운 뒤 취소된다
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        let waitsBefore = clock.recordedWaits.count  // B 가 잔 것만
        try await pacer.acquire(site: .ppomppu)      // C — A 가 반납한 시각을 쓴다

        XCTAssertEqual(
            clock.recordedWaits.count, waitsBefore,
            "A 가 반납한 슬롯은 이미 지난 시각이라 C 는 기다리지 않아야 함")
    }

    /// sleeper 클로저 안에서 페이서 자신을 다시 부르기 위한 상자 —
    /// 클로저가 페이서보다 먼저 만들어져야 해서 직접 캡처가 안 된다.
    private final class PacerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: HostRequestPacer?

        var pacer: HostRequestPacer? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); defer { lock.unlock() }; storage = newValue }
        }
    }

    /// 한 번만 참을 돌려주는 플래그 — sleeper 클로저가 `@Sendable` 이라
    /// 캡처 가능한 참조 타입이 필요하다.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false

        func set() {
            lock.lock(); defer { lock.unlock() }
            armed = true
        }

        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            defer { armed = false }
            return armed
        }
    }

    func testAlreadyCancelledRequestDoesNotConsumeASlot() async throws {
        // 버스트 안이면 대기가 0 이라 잠들지 않고 통과한다 — 그래서 "자다
        // 취소" 반납 경로에 닿지 않는다. 그 사이 이미 취소된 요청이 슬롯만
        // 먹고 아무것도 안 보내면, 보드를 넘긴 뒤의 첫 요청이 빈 자리를
        // 기다린다.
        let capacity = Int(try XCTUnwrap(HostRequestPacer.limit(for: .ppomppu)).capacity)
        let clock = FakeClock()
        let pacer = makePacer(clock)

        // 취소가 확실히 관측된 뒤에 acquire 를 부른다(경합 없이 결정적).
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await pacer.acquire(site: .ppomppu)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("취소된 요청은 게이트를 그냥 통과하면 안 됨")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // 버스트가 온전히 남아 있어야 한다.
        for _ in 0..<capacity { try await pacer.acquire(site: .ppomppu) }
        XCTAssertTrue(
            clock.recordedWaits.isEmpty,
            "취소된 요청이 슬롯을 먹어 버스트가 줄었음")
    }

    // MARK: - 취소

    func testCancellationPropagatesInsteadOfSleeping() async {
        // 게이트에서 자는 동안 보드를 넘기면 그 요청은 더 보낼 이유가 없다 —
        // 취소를 삼키면 이미 버려진 화면을 위해 토큰을 쓴다.
        let clock = FakeClock()
        let pacer = HostRequestPacer(
            clock: { clock.read() },
            sleeper: { _ in throw CancellationError() })

        do {
            let capacity = Int(HostRequestPacer.limit(for: .ppomppu)?.capacity ?? 0)
            for _ in 0...(capacity + 1) { try await pacer.acquire(site: .ppomppu) }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // 기대 경로
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
