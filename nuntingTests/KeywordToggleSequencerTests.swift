import XCTest
@testable import nunting

/// `KeywordToggleSequencer` — 키워드별 토글 요청의 직렬화 + 실패 복원 판정.
///
/// 배경: KeywordListView 의 낙관적 토글은 실패 시 전이를 되돌리는데,
/// (1) "현재 값 == 내가 쓴 값" 비교는 ON(A)→OFF(B)→ON(C) 연타에서 A 의
/// 실패가 같은 값(true)인 C 의 낙관적 상태를 잘못 되돌리고, (2) `!enabled`
/// 고정 복원은 직전 요청도 실패한 경우(연속 실패) 서버에 없는 값으로
/// 되돌린다. 그래서 복원은 "이 요청이 여전히 최신일 때만", 값은 "마지막
/// ack(성공)된 서버 값"으로 한다 — onFailure 의 restoreTo 가 그 값이고,
/// nil 이면 더 새 submit 이 상태의 주인이라 복원하지 않는다.
@MainActor
final class KeywordToggleSequencerTests: XCTestCase {

    private struct StubError: Error {}

    /// onFailure 캡처용 — escaping @MainActor 클로저에서 지역 var 캡처 대신.
    private final class Capture {
        var restores: [Bool?] = []
    }

    func testSendsRunSeriallyPerID() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let log = Log()

        let first = seq.submit(
            id: "k",
            value: true,
            send: {
                await log.append("first:start")
                await gate.wait()
                await log.append("first:end")
            },
            onFailure: { _, _ in XCTFail("실패 경로 아님") }
        )
        let second = seq.submit(
            id: "k",
            value: false,
            send: { await log.append("second:start") },
            onFailure: { _, _ in XCTFail("실패 경로 아님") }
        )

        // 첫 send 가 gate 에 매달릴 때까지 대기.
        await waitUntil { await log.contains("first:start") }
        // 직렬화가 깨졌으면 이 사이 second:start 가 끼어든다.
        for _ in 0..<50 { await Task.yield() }
        let premature = await log.contains("second:start")
        XCTAssertFalse(premature, "직전 요청이 끝나기 전에 다음 send 가 시작되면 안 됨")

        await gate.signal()
        await first.value
        await second.value
        let entries = await log.entries
        XCTAssertEqual(entries, ["first:start", "first:end", "second:start"],
                       "send 는 제출 순서대로 직렬 실행")
    }

    func testLatestFailureRestoresPreToggleServerValue() async {
        // 서버 false 동기 상태에서 ON 토글이 실패 → 복원값은 서버 값 false.
        let seq = KeywordToggleSequencer()
        let capture = Capture()

        let task = seq.submit(
            id: "k",
            value: true,
            send: { throw StubError() },
            onFailure: { _, restoreTo in capture.restores.append(restoreTo) }
        )
        await task.value

        XCTAssertEqual(capture.restores, [false],
                       "최신 실패의 복원값은 첫 토글 직전(=서버 동기) 값")
    }

    func testSupersededFailureReportsNilRestore() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let capture = Capture()

        // 첫 요청은 gate 에 매달렸다가 실패한다.
        let first = seq.submit(
            id: "k",
            value: true,
            send: {
                await gate.wait()
                throw StubError()
            },
            onFailure: { _, restoreTo in capture.restores.append(restoreTo) }
        )
        // 매달린 사이 더 새 토글 제출 → 첫 실패는 더 이상 복원 주체가 아니다.
        let second = seq.submit(
            id: "k",
            value: false,
            send: {},
            onFailure: { _, _ in XCTFail("두 번째 send 는 성공해야 함") }
        )

        await gate.signal()
        await first.value
        await second.value

        XCTAssertEqual(capture.restores, [nil],
                       "더 새 submit 이 있으면 옛 실패는 낙관적 상태를 건드리면 안 됨 (restoreTo nil)")
    }

    func testConsecutiveFailuresRestoreToLastAcknowledgedValue() async {
        // 서버 ON 동기 상태에서 OFF(gen1)→ON(gen2) 연타, 둘 다 실패.
        // gen2 의 복원값이 `!value = false` 면 서버(ON)와 갈라진다 —
        // ack 된 적 없는 전이는 건너뛰고 서버 값 ON 으로 복원해야 한다.
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let firstCapture = Capture()
        let secondCapture = Capture()

        let first = seq.submit(
            id: "k",
            value: false,
            send: {
                await gate.wait()
                throw StubError()
            },
            onFailure: { _, restoreTo in firstCapture.restores.append(restoreTo) }
        )
        let second = seq.submit(
            id: "k",
            value: true,
            send: { throw StubError() },
            onFailure: { _, restoreTo in secondCapture.restores.append(restoreTo) }
        )

        await gate.signal()
        await first.value
        await second.value

        XCTAssertEqual(firstCapture.restores, [nil], "옛 실패는 no-op")
        XCTAssertEqual(secondCapture.restores, [true],
                       "최신 실패는 마지막 ack 된 서버 값(초기 동기값 ON)으로 복원")
    }

    func testSuccessUpdatesAcknowledgedValue() async {
        // OFF 성공으로 서버가 false 가 된 뒤 ON 이 실패하면 복원값은 false.
        let seq = KeywordToggleSequencer()
        let capture = Capture()

        let first = seq.submit(
            id: "k",
            value: false,
            send: {},
            onFailure: { _, _ in XCTFail("첫 send 는 성공해야 함") }
        )
        await first.value

        let second = seq.submit(
            id: "k",
            value: true,
            send: { throw StubError() },
            onFailure: { _, restoreTo in capture.restores.append(restoreTo) }
        )
        await second.value

        XCTAssertEqual(capture.restores, [false],
                       "성공한 전이가 ack 값을 갱신 — 이후 실패는 거기로 복원")
    }

    func testIndependentIDsDoNotChain() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let log = Log()

        let blocked = seq.submit(
            id: "a",
            value: true,
            send: { await gate.wait() },
            onFailure: { _, _ in }
        )
        let other = seq.submit(
            id: "b",
            value: true,
            send: { await log.append("b:done") },
            onFailure: { _, _ in }
        )

        // id 가 다르면 a 가 매달려 있어도 b 는 즉시 진행돼야 한다.
        await waitUntil { await log.contains("b:done") }
        let done = await log.contains("b:done")
        XCTAssertTrue(done, "다른 키워드의 토글이 서로를 막으면 안 됨")

        await gate.signal()
        await blocked.value
        await other.value
    }

    /// 조건이 참이 될 때까지 yield 로 양보 — 유한 횟수라 hang 없이 실패한다.
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

// MARK: - Test helpers

/// signal 전까지 wait 호출자를 매달아 두는 1회용 게이트.
private actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// 실행 순서 기록용.
private actor Log {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    func contains(_ entry: String) -> Bool { entries.contains(entry) }
}
