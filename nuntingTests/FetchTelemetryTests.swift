import XCTest
@testable import nunting

/// `FetchTelemetry` 계약 — HTML fetch 시도 계측.
///
/// 이 계측이 생긴 이유는 뽐뿌 "다시 시도"의 원인(429 즉시 거절 vs. 8초 타임아웃)을
/// 기기 밖에서 가를 수단이 없었기 때문이다. 그래서 여기서 지키는 것은 두 가지:
/// 라벨이 집계 가능한 모양인지, 그리고 정상 취소가 실패로 새지 않는지.
@MainActor
final class FetchTelemetryTests: XCTestCase {

    // MARK: - 라벨

    func testLabelKeepsBoardAndPageValuesButOnlyNamesOfTheRest() {
        // 쿼리 값을 전부 실으면 글 번호마다 다른 문자열이 돼 집계가 안 되고,
        // 경로만 실으면 보드가 안 갈린다. 집계 축(id/page)만 값째 남긴다.
        let url = URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu&page=3&divpage=99")!
        XCTAssertEqual(FetchEventDTO.label(for: url), "/new/bbs_list.php?id=ppomppu&page=3&divpage")
    }

    func testLabelSplitsListFromDetailThatSharesThePath() {
        // aagag 이슈모음은 목록과 상세가 같은 경로를 쓰고 글 번호만 쿼리로 단다.
        // 여기가 접히면 상세 30건이 "같은 목록 URL 30건"으로 보인다(2026-08-28 오진).
        let list = URL(string: "https://aagag.com/issue/")!
        let detail = URL(string: "https://aagag.com/issue/?idx=1633837")!

        XCTAssertEqual(FetchEventDTO.label(for: list), "/issue/")
        XCTAssertEqual(FetchEventDTO.label(for: detail), "/issue/?idx")
    }

    func testLabelIsStableAcrossQueryOrderAndDuplicates() {
        // 순서·중복 때문에 같은 요청이 두 라벨로 갈리면 집계가 쪼개진다.
        let a = URL(string: "https://aagag.com/issue/?idx=1&v=2&idx=3")!
        let b = URL(string: "https://aagag.com/issue/?v=2&idx=1")!
        XCTAssertEqual(FetchEventDTO.label(for: a), "/issue/?idx&v")
        XCTAssertEqual(FetchEventDTO.label(for: b), "/issue/?idx&v")
    }

    func testLabelFallsBackToPathWhenNoQuery() {
        let url = URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php")!
        XCTAssertEqual(FetchEventDTO.label(for: url), "/new/bbs_view.php")
    }

    func testErrorLabelUsesURLErrorCodeNumber() {
        XCTAssertEqual(FetchEventDTO.errorLabel(URLError(.timedOut)), "urlerror -1001")
    }

    // MARK: - 취소는 실패가 아니다

    func testCancellationProducesNoEvent() {
        // 보드 전환·뷰 교체가 쏟아내는 정상 취소가 실패 분포를 뒤덮으면
        // 계측이 도리어 판단을 흐린다.
        let url = URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu")!
        for error in [URLError(.cancelled) as Error, CancellationError()] {
            let outcome = FetchAttemptOutcome(
                url: url, attempt: 1, prefetch: false, elapsedMs: 12,
                status: nil, error: error)
            XCTAssertNil(outcome.event(), "취소는 이벤트를 만들면 안 됨: \(error)")
        }
    }

    func testTimeoutProducesEventWithErrorLabel() {
        let url = URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu&page=2")!
        let event = FetchAttemptOutcome(
            url: url, attempt: 2, prefetch: true, elapsedMs: 8_012,
            status: nil, error: URLError(.timedOut)
        ).event(ts: 100)

        XCTAssertEqual(event?.err, "urlerror -1001")
        XCTAssertEqual(event?.ms, 8_012)
        XCTAssertEqual(event?.attempt, 2)
        XCTAssertEqual(event?.pf, true)
        XCTAssertEqual(event?.host, "m.ppomppu.co.kr")
        XCTAssertNil(event?.status)
    }

    func testFirstAttemptOmitsAttemptFieldAndNonPrefetchOmitsFlag() {
        // 배치 크기가 이벤트 수에 곱해지므로 기본값은 싣지 않는다
        // (미디어 DTO 의 `ok` 와 같은 규칙).
        let url = URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu")!
        let event = FetchAttemptOutcome(
            url: url, attempt: 1, prefetch: false, elapsedMs: 130,
            status: 200, error: nil
        ).event()

        XCTAssertNil(event?.attempt)
        XCTAssertNil(event?.pf)
        XCTAssertEqual(event?.status, 200)
    }

    // MARK: - 요청 사유

    func testViaIsCarriedOntoTheEvent() {
        let url = URL(string: "https://aagag.com/issue/")!
        let event = FetchAttemptOutcome(
            url: url, attempt: 1, prefetch: false, elapsedMs: 60,
            status: 200, error: nil, via: FetchReason.refresh
        ).event()

        XCTAssertEqual(event?.via, "refresh")
    }

    func testViaIsOmittedWhenUnknown() {
        // 사유를 모르는 경로(상세·댓글 등)는 키를 안 싣는다 — 배치 크기가
        // 이벤트 수에 곱해진다.
        let url = URL(string: "https://aagag.com/issue/")!
        let event = FetchAttemptOutcome(
            url: url, attempt: 1, prefetch: false, elapsedMs: 60,
            status: 200, error: nil
        ).event()

        XCTAssertNil(event?.via)
    }

    // MARK: - 버퍼

    func testFlushesWhenThresholdReached() {
        var batches: [[FetchEventDTO]] = []
        let telemetry = FetchTelemetry(
            flushThreshold: 3,
            linkProvider: { "wifi" },
            onFlush: { batches.append($0) })

        for _ in 0..<3 { telemetry.record(Self.sample) }

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 3)
        XCTAssertEqual(batches.first?.first?.link, "wifi", "링크는 record 시점에 찍힌다")
    }

    func testBackgroundFlushesPartialBufferOnce() {
        // 세션 끝의 이벤트가 증발하면 "마지막에 뭐가 실패했나"를 못 본다.
        var batches: [[FetchEventDTO]] = []
        let telemetry = FetchTelemetry(
            flushThreshold: 30,
            linkProvider: { "cell" },
            onFlush: { batches.append($0) })

        telemetry.record(Self.sample)
        telemetry.onBackground()
        telemetry.onBackground()

        XCTAssertEqual(batches.count, 1, "빈 버퍼 flush 는 배치를 만들지 않아야 함")
        XCTAssertEqual(batches.first?.count, 1)
    }

    // MARK: - 테스트 격리

    func testTestRunIsDetectedFromEnvironment() {
        // 이 계측은 기본 인자로 실 텔레메트리에 물려 있어, 막지 않으면
        // `xcodebuild test` 가 프로덕션 대시보드에 가짜 세션을 올린다
        // (실제로 example.com 21건이 실기기 데이터에 섞였다).
        XCTAssertTrue(
            FetchTelemetry.isTestRun(),
            "테스트 프로세스는 스스로를 테스트 실행으로 인식해야 함")
        XCTAssertFalse(
            FetchTelemetry.isTestRun(environment: [:]),
            "실기기 환경은 업로드해야 함")
    }

    func testBackgroundFlushCatchesEventsThatArriveAfterIt() async {
        // 이벤트는 `Task { @MainActor in ... }` 로 건너온다. 백그라운드 직전에
        // 끝난 시도의 hop 은 onBackground 가 도는 시점에 아직 큐에 있을 수
        // 있고, 그러면 유일한 flush 를 놓친 채 프로세스가 정지한다 — 하필
        // "마지막에 무엇이 실패했나"가 거기 있다.
        var batches: [[FetchEventDTO]] = []
        let telemetry = FetchTelemetry(
            flushThreshold: 30,
            linkProvider: { "wifi" },
            onFlush: { batches.append($0) })

        telemetry.onBackground()          // 버퍼가 비어 있어 아직 배치 없음
        XCTAssertTrue(batches.isEmpty)

        telemetry.record(Self.sample)     // 늦게 도착한 hop
        // 예약된 두 번째 flush 가 돌 기회를 준다.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(batches.count, 1, "뒤늦게 도착한 이벤트도 실려야 함")
        XCTAssertEqual(batches.first?.count, 1)
    }

    private static let sample = FetchEventDTO(
        ts: 1, ms: 100, host: "m.ppomppu.co.kr", path: "/new/bbs_list.php?id=ppomppu",
        status: 200, err: nil, attempt: nil, pf: nil, link: nil)
}
