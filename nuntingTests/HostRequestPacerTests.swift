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
        // 뽐뿌 = capacity 6, 2/s. 유휴 상태에서 6건은 즉시, 7건째부터 0.5초 간격.
        let clock = FakeClock()
        let pacer = makePacer(clock)

        for _ in 0..<9 { try await pacer.acquire(site: .ppomppu) }

        XCTAssertEqual(clock.recordedWaits.count, 3, "6건은 대기 없이 나가야 함")
        for wait in clock.recordedWaits {
            XCTAssertEqual(wait, 0.5, accuracy: 0.001, "정상 속도는 2/s = 0.5초 간격")
        }
    }

    func testIdlePeriodRefillsBurstButDoesNotBankBeyondCapacity() async throws {
        // 오래 쉬었다고 무제한으로 몰아 쏘면 게이트가 없는 것과 같다.
        let clock = FakeClock()
        let pacer = makePacer(clock)

        for _ in 0..<6 { try await pacer.acquire(site: .ppomppu) }
        XCTAssertTrue(clock.recordedWaits.isEmpty)

        clock.advance(60)  // 1분 유휴 — 이론상 120 토큰

        for _ in 0..<6 { try await pacer.acquire(site: .ppomppu) }
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

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { try? await pacer.acquire(site: .ppomppu) }
            }
        }

        let waits = clock.recordedWaits
        XCTAssertEqual(waits.count, 4, "10건 중 6건만 즉시 — 나머지는 대기해야 함")
        // 판정 지표는 대기값의 다양성이 아니라 **소비한 총 시간**이다. 가짜 시계가
        // sleep 마다 전진하므로, 슬롯이 안 겹쳤다면 각 대기는 정확히 한 간격
        // (0.5초)이고 총 전진은 (10 - capacity) / rate = 2초가 된다. 같은 슬롯을
        // 두 번 집으면 그 호출의 대기가 0 이 돼 총합이 줄어든다.
        for wait in waits {
            XCTAssertEqual(wait, 0.5, accuracy: 0.001, "슬롯이 겹쳤음")
        }
        XCTAssertEqual(clock.now - start, 2.0, accuracy: 0.001,
                       "10건이 최소 2초에 걸쳐 나가야 함")
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

    // MARK: - 취소

    func testCancellationPropagatesInsteadOfSleeping() async {
        // 게이트에서 자는 동안 보드를 넘기면 그 요청은 더 보낼 이유가 없다 —
        // 취소를 삼키면 이미 버려진 화면을 위해 토큰을 쓴다.
        let clock = FakeClock()
        let pacer = HostRequestPacer(
            clock: { clock.read() },
            sleeper: { _ in throw CancellationError() })

        do {
            for _ in 0..<8 { try await pacer.acquire(site: .ppomppu) }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // 기대 경로
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
