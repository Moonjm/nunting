import XCTest
@testable import nunting

/// `MediaLoadEventDTO.network` — URLSession 타이밍 → 서버 이벤트 변환.
final class MediaLoadNetworkEventTests: XCTestCase {

    /// 기준 시각. 각 단계를 ms 단위로 얹어 만든다.
    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    private func at(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

    /// 새 커넥션: DNS·connect·TLS·TTFB 가 각각 분리돼 실려야 한다.
    /// 이 분해가 있어야 "느린 게 서버냐 핸드셰이크냐"를 가른다.
    func testSplitsHandshakePhasesOnFreshConnection() {
        let phases = MediaLoadNetworkPhases(
            fetchStart: at(0),
            domainLookupStart: at(10), domainLookupEnd: at(40),
            connectStart: at(40), connectEnd: at(160),
            secureConnectionStart: at(70), secureConnectionEnd: at(160),
            requestStart: at(160), responseStart: at(400), responseEnd: at(950),
            reusedConnection: false, networkProtocol: "h2", statusCode: 200, bytes: 812_345)

        let e = MediaLoadEventDTO.network(host: "img.fmkorea.com", phases: phases, ts: 1_753_000_000)

        XCTAssertEqual(e?.t, "net")
        XCTAssertEqual(e?.host, "img.fmkorea.com")
        XCTAssertEqual(e?.ms, 950, "총 소요 = fetchStart→responseEnd")
        XCTAssertEqual(e?.dns, 30)
        XCTAssertEqual(e?.conn, 120, "connect 구간은 TLS 를 포함한 URLSession 원값 그대로")
        XCTAssertEqual(e?.tls, 90)
        XCTAssertEqual(e?.ttfb, 240, "requestStart→responseStart")
        XCTAssertEqual(e?.bytes, 812_345)
        XCTAssertEqual(e?.proto, "h2")
        XCTAssertEqual(e?.status, 200)
        XCTAssertEqual(e?.reused, false)
    }

    /// 재사용 커넥션은 핸드셰이크 단계 자체가 없다(URLSession 이 nil 로 준다).
    /// 그 자리에 0 을 채우면 "핸드셰이크가 0ms" 로 읽혀 분포가 오염되므로 생략해야 한다.
    func testOmitsHandshakePhasesOnReusedConnection() {
        let phases = MediaLoadNetworkPhases(
            fetchStart: at(0),
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: at(2), responseStart: at(120), responseEnd: at(300),
            reusedConnection: true, networkProtocol: "h2", statusCode: 200, bytes: 20_000)

        let e = MediaLoadEventDTO.network(host: "i.namu.wiki", phases: phases, ts: 1_753_000_000)

        XCTAssertNil(e?.dns)
        XCTAssertNil(e?.conn)
        XCTAssertNil(e?.tls)
        XCTAssertEqual(e?.ttfb, 118)
        XCTAssertEqual(e?.ms, 300)
        XCTAssertEqual(e?.reused, true)
    }

    /// 취소·실패로 responseEnd 가 안 잡힌 트랜잭션은 총 시간이 없다 —
    /// 0ms 로 실으면 p50 을 끌어내리므로 이벤트를 만들지 않는다.
    func testReturnsNilWhenTotalDurationUnknown() {
        let phases = MediaLoadNetworkPhases(
            fetchStart: at(0),
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: at(2), responseStart: nil, responseEnd: nil,
            reusedConnection: true, networkProtocol: nil, statusCode: nil, bytes: 0)

        XCTAssertNil(MediaLoadEventDTO.network(host: "x.example.com", phases: phases, ts: 1))
    }

    /// nil 필드는 JSON 에서 빠져야 한다 — 이벤트 수가 많아 키 하나가 배치 크기에 곱해진다.
    func testEncodingOmitsAbsentFields() throws {
        let e = MediaLoadEventDTO.show(host: "img.clien.net", ms: 12, src: "mem",
                                       ctx: "body", ok: true, ts: 1_753_000_000)
        let json = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"src\":\"mem\""))
        XCTAssertFalse(json.contains("dns"), "네트워크 분해 필드는 show 이벤트에 없어야 함: \(json)")
        XCTAssertFalse(json.contains("bytes"), json)
        XCTAssertFalse(json.contains("\"ok\""), "성공은 기본값이라 생략: \(json)")
    }

    /// 실패는 반드시 실려야 한다 — "느리다"의 상당수가 사실 실패 후 재시도다.
    func testFailedShowEventCarriesOkFalse() throws {
        let e = MediaLoadEventDTO.show(host: "img.clien.net", ms: 8_000, src: "net",
                                       ctx: "body", ok: false, ts: 1)
        let json = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"ok\":false"), json)
    }
}

/// `MediaLinkMonitor` — NWPath 상태 → 링크 라벨 분류.
/// (NWPath 는 테스트에서 만들 수 없어 분류 로직만 순수 함수로 떼어 검증한다.)
final class MediaLinkLabelTests: XCTestCase {

    func testWifiWins() {
        XCTAssertEqual(MediaLinkMonitor.label(satisfied: true, wifi: true, cellular: false, wired: false),
                       "wifi")
    }

    func testCellularWhenNoWifi() {
        XCTAssertEqual(MediaLinkMonitor.label(satisfied: true, wifi: false, cellular: true, wired: false),
                       "cell")
    }

    /// Wi-Fi 인터페이스가 붙어 있어도 실제 경로가 셀룰러면 셀룰러다
    /// (핫스팟·Wi-Fi Assist). 두 플래그가 같이 서는 경우가 있어 우선순위를 못 박는다.
    func testCellularBeatsWifiWhenBothInterfacesPresent() {
        XCTAssertEqual(MediaLinkMonitor.label(satisfied: true, wifi: true, cellular: true, wired: false),
                       "cell")
    }

    func testUnsatisfiedPathIsNone() {
        XCTAssertEqual(MediaLinkMonitor.label(satisfied: false, wifi: true, cellular: false, wired: false),
                       "none")
    }

    func testWiredIsItsOwnLabel() {
        XCTAssertEqual(MediaLinkMonitor.label(satisfied: true, wifi: false, cellular: false, wired: true),
                       "wired")
    }
}

/// `MediaLoadTelemetry` — 버퍼링/flush 규칙.
@MainActor
final class MediaLoadTelemetryTests: XCTestCase {

    private func event(_ ms: Int) -> MediaLoadEventDTO {
        MediaLoadEventDTO.show(host: "h", ms: ms, src: "net", ctx: "body", ok: true, ts: 1)
    }

    /// 같은 이미지도 LTE 냐 Wi-Fi 냐로 체감이 갈린다 — 링크 종류는 기록 시점에
    /// 한 번 찍는다(호출부마다 넘기면 다운로더 스레드/메인 두 경로가 어긋난다).
    func testStampsCurrentLinkTypeOnRecordedEvents() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 1, linkProvider: { "cell" },
                                   onFlush: { batches.append($0) })

        t.record(event(1))

        XCTAssertEqual(batches.first?.first?.link, "cell")
    }

    /// 임계 미만에서는 안 보낸다 — 이벤트 한 건마다 POST 하면 이미지 한 글에 수십 번이 된다.
    func testDoesNotFlushBelowThreshold() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 3, onFlush: { batches.append($0) })

        t.record(event(1))
        t.record(event(2))

        XCTAssertTrue(batches.isEmpty)
    }

    /// 임계에 닿으면 한 번에 묶어 보낸다.
    func testFlushesWhenBufferReachesThreshold() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 3, onFlush: { batches.append($0) })

        t.record(event(1))
        t.record(event(2))
        t.record(event(3))

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.map(\.ms), [1, 2, 3])
    }

    /// flush 는 버퍼를 비운다 — 안 비우면 같은 이벤트가 배치마다 다시 실려 분포가 왜곡된다.
    func testFlushClearsBufferSoEventsAreNotResent() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 2, onFlush: { batches.append($0) })

        t.record(event(1))
        t.record(event(2))   // flush #1
        t.record(event(3))
        t.record(event(4))   // flush #2

        XCTAssertEqual(batches.map { $0.map(\.ms) }, [[1, 2], [3, 4]])
    }

    /// 백그라운드 진입 시 임계 미만이라도 내보낸다 — 안 그러면 세션 끝의 이벤트가 증발한다.
    func testOnBackgroundFlushesPartialBatch() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 60, onFlush: { batches.append($0) })

        t.record(event(7))
        t.onBackground()

        XCTAssertEqual(batches.map { $0.map(\.ms) }, [[7]])
    }

    /// 빈 flush 는 빈 POST 를 만들지 않는다.
    func testEmptyFlushSendsNothing() {
        var batches: [[MediaLoadEventDTO]] = []
        let t = MediaLoadTelemetry(flushThreshold: 60, onFlush: { batches.append($0) })

        t.flush()
        t.onBackground()

        XCTAssertTrue(batches.isEmpty)
    }
}

/// 파이프라인 구간 분해 이벤트 — 지연이 큐 대기냐 디코드냐를 가른다.
final class MediaPipelineEventTests: XCTestCase {

    /// 디코드 이벤트는 소요 시간과 함께 **출력 픽셀 수**를 실어야 한다.
    /// 디코드 비용은 픽셀에 비례하므로, ms 만으로는 "무거운 이미지였다"와
    /// "큐가 막혔다"를 구분할 수 없다.
    func testDecodeEventCarriesPixelsAndBytes() throws {
        let e = MediaLoadEventDTO.decode(kind: "webpStatic", ms: 180,
                                         pixels: 3_110_400, bytes: 214_003, ts: 1)
        let json = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? ""

        XCTAssertEqual(e.t, "decode")
        XCTAssertEqual(e.ms, 180)
        XCTAssertEqual(e.kind, "webpStatic")
        XCTAssertTrue(json.contains("\"px\":3110400"), json)
        XCTAssertTrue(json.contains("\"bytes\":214003"), json)
    }

    /// net 이벤트는 **슬롯 대기 시간**을 함께 싣는다. 다운로드 자체가 60ms 인데
    /// 화면엔 5초 뒤 뜨는 상황에서, 대기가 다운로더 큐에서 생겼는지를 이 값이 가른다.
    func testNetworkEventCarriesQueueWait() {
        let t0 = Date(timeIntervalSince1970: 1_753_000_000)
        let phases = MediaLoadNetworkPhases(
            fetchStart: t0.addingTimeInterval(2.5),
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: t0.addingTimeInterval(2.5),
            responseStart: t0.addingTimeInterval(2.56),
            responseEnd: t0.addingTimeInterval(2.62),
            reusedConnection: true, networkProtocol: "h2", statusCode: 200, bytes: 100)

        let e = MediaLoadEventDTO.network(host: "h", phases: phases,
                                          enqueuedAt: t0, ts: 1)

        XCTAssertEqual(e?.ms, 120, "다운로드 자체는 120ms")
        XCTAssertEqual(e?.queued, 2500, "요청 생성 → 실제 전송 시작까지 2.5s 대기")
    }

    /// 5초를 기다린 요청이 **프리페치인지 표시용인지** 갈라야 한다. 다운로드 자체가
    /// 52ms, 디코드가 10ms 인데 대기가 p90 5초라면, 큐에 줄 서 있는 게 무엇인지가
    /// 유일하게 남은 미지수다. 프리페치는 `.lowPriority` 로 나가므로 그걸로 가른다.
    func testNetworkEventMarksPrefetchRequests() {
        let t0 = Date(timeIntervalSince1970: 1_753_000_000)
        let phases = MediaLoadNetworkPhases(
            fetchStart: t0, domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: t0, responseStart: t0.addingTimeInterval(0.02),
            responseEnd: t0.addingTimeInterval(0.05),
            reusedConnection: true, networkProtocol: "h2", statusCode: 200, bytes: 100)

        let prefetch = MediaLoadEventDTO.network(host: "h", phases: phases, prefetch: true, ts: 1)
        let display = MediaLoadEventDTO.network(host: "h", phases: phases, prefetch: false, ts: 1)

        XCTAssertEqual(prefetch?.pf, true)
        XCTAssertNil(display?.pf, "표시 요청이 기본값이라 생략된다(배치 크기)")
    }

    /// 대기 기산점을 모르면(레거시 호출) 필드를 비운다 — 0 을 넣으면
    /// "대기 없음" 과 구분이 안 된다.
    func testQueueWaitOmittedWhenEnqueueTimeUnknown() {
        let t0 = Date(timeIntervalSince1970: 1_753_000_000)
        let phases = MediaLoadNetworkPhases(
            fetchStart: t0, domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: t0, responseStart: t0.addingTimeInterval(0.05),
            responseEnd: t0.addingTimeInterval(0.1),
            reusedConnection: true, networkProtocol: "h2", statusCode: 200, bytes: 100)

        XCTAssertNil(MediaLoadEventDTO.network(host: "h", phases: phases, ts: 1)?.queued)
    }
}

/// 배치에 실리는 실행 설정 라벨 — 어느 빌드/설정에서 나온 숫자인지 못 박는다.
final class MediaRunConfigTests: XCTestCase {

    /// 슬롯 폭 실험(4→8)의 결과를 판정할 때, 어느 세션이 어느 빌드였는지 알 방법이
    /// 없어 귀속이 막혔다. 배치마다 설정을 같이 실어 그 구멍을 닫는다.
    func testLabelCarriesSlotsAndBuild() {
        XCTAssertEqual(MediaRunConfig.label(slots: 4, build: "137"), "slots=4 build=137")
    }

    /// 빌드 스탬프를 못 읽어도 나머지는 남아야 한다.
    func testLabelSurvivesMissingBuild() {
        XCTAssertEqual(MediaRunConfig.label(slots: 8, build: ""), "slots=8")
    }

    /// **CFBundleVersion 은 못 쓴다** — 이 프로젝트에선 항상 "1" 이라 재빌드해도
    /// 그대로다(실제로 중복 디코드 수정을 판정하려다 여기서 막혔다). 실행 파일의
    /// 수정 시각을 쓰면 빌드마다 값이 바뀐다.
    func testBuildStampChangesWithExecutableTimestamp() {
        let a = MediaRunConfig.buildStamp(executableModified: Date(timeIntervalSince1970: 1_753_000_000))
        let b = MediaRunConfig.buildStamp(executableModified: Date(timeIntervalSince1970: 1_753_000_060))

        XCTAssertNotEqual(a, b, "빌드 시각이 다르면 스탬프도 달라야 한다")
        XCTAssertFalse(a.isEmpty)
    }

    /// 읽을 수 없으면 빈 문자열 — 라벨에서 통째로 빠진다.
    func testBuildStampEmptyWhenUnknown() {
        XCTAssertEqual(MediaRunConfig.buildStamp(executableModified: nil), "")
    }
}
