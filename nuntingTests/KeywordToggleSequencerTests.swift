import XCTest
@testable import nunting

/// `KeywordToggleSequencer` — 키워드별 토글 요청의 직렬화 + "최신 요청만
/// 복원" 판정 테스트.
///
/// 배경: KeywordListView 의 낙관적 토글은 실패 시 전이를 되돌리는데, 복원
/// 조건을 "현재 값 == 내가 쓴 값" 으로 비교하면 ON(A)→OFF(B)→ON(C) 연타에서
/// A 의 실패가 같은 값(true)인 C 의 낙관적 상태를 잘못 되돌린다. 이후 C 가
/// 성공해도 UI 를 다시 세우는 코드가 없어 서버=ON·UI=OFF 로 영구 불일치.
/// 그래서 복원 판정은 값이 아니라 세대(이 요청이 여전히 최신인가)로 한다.
@MainActor
final class KeywordToggleSequencerTests: XCTestCase {

    private struct StubError: Error {}

    /// onFailure 캡처용 — escaping @MainActor 클로저에서 지역 var 캡처 대신.
    private final class Capture {
        var isLatest: Bool?
        var failureCount = 0
    }

    func testSendsRunSeriallyPerID() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let log = Log()

        let first = seq.submit(
            id: "k",
            send: {
                await log.append("first:start")
                await gate.wait()
                await log.append("first:end")
            },
            onFailure: { _, _ in XCTFail("실패 경로 아님") }
        )
        let second = seq.submit(
            id: "k",
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

    func testFailureWhenStillLatestReportsIsLatestTrue() async {
        let seq = KeywordToggleSequencer()
        let capture = Capture()

        let task = seq.submit(
            id: "k",
            send: { throw StubError() },
            onFailure: { _, isLatest in
                capture.isLatest = isLatest
                capture.failureCount += 1
            }
        )
        await task.value

        XCTAssertEqual(capture.failureCount, 1)
        XCTAssertEqual(capture.isLatest, true,
                       "더 새 토글이 없으면 이 실패가 복원 주체")
    }

    func testFailureSupersededByNewerSubmitReportsIsLatestFalse() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let capture = Capture()

        // 첫 요청은 gate 에 매달렸다가 실패한다.
        let first = seq.submit(
            id: "k",
            send: {
                await gate.wait()
                throw StubError()
            },
            onFailure: { _, isLatest in capture.isLatest = isLatest }
        )
        // 매달린 사이 더 새 토글 제출 → 첫 실패는 더 이상 복원 주체가 아니다.
        let second = seq.submit(
            id: "k",
            send: {},
            onFailure: { _, _ in XCTFail("두 번째 send 는 성공해야 함") }
        )

        await gate.signal()
        await first.value
        await second.value

        XCTAssertEqual(capture.isLatest, false,
                       "더 새 submit 이 있으면 옛 실패는 낙관적 상태를 건드리면 안 됨")
    }

    func testIndependentIDsDoNotChain() async {
        let seq = KeywordToggleSequencer()
        let gate = AsyncGate()
        let log = Log()

        let blocked = seq.submit(
            id: "a",
            send: { await gate.wait() },
            onFailure: { _, _ in }
        )
        let other = seq.submit(
            id: "b",
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
