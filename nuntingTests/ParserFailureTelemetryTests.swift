import XCTest
@testable import nunting

/// `ParserFailureTelemetry` — structureChanged 발생을 서버로 집계하는 세션
/// 단위 리포터. 같은 (site, phase) 는 세션당 1회만 전송(같은 파손이 스크롤/
/// 재시도마다 중복 업로드되는 것 방지), 전송 실패 시엔 다음 발생 때 재시도.
// @MainActor: 검증 대상이 main actor 소속(앱 서비스 계층과 동일).
@MainActor
final class ParserFailureTelemetryTests: XCTestCase {

    private final class SentRecorder {
        var items: [(site: String, phase: String, detail: String)] = []
    }

    func testReportSendsSitePhaseDetail() async {
        let sent = SentRecorder()
        let telemetry = ParserFailureTelemetry(sender: { site, phase, detail in
            sent.items.append((site, phase, detail))
        })

        await telemetry.report(site: .clien, phase: .list, detail: "목록 0건")?.value

        XCTAssertEqual(sent.items.count, 1)
        XCTAssertEqual(sent.items.first?.site, "clien")
        XCTAssertEqual(sent.items.first?.phase, "list")
        XCTAssertEqual(sent.items.first?.detail, "목록 0건")
    }

    func testDuplicateSitePhaseSentOncePerSession() async {
        let sent = SentRecorder()
        let telemetry = ParserFailureTelemetry(sender: { site, phase, detail in
            sent.items.append((site, phase, detail))
        })

        await telemetry.report(site: .clien, phase: .list, detail: "첫 발생")?.value
        let second = telemetry.report(site: .clien, phase: .list, detail: "중복 발생")
        await second?.value

        XCTAssertNil(second, "같은 (site, phase) 재보고는 세션 내 전송 생략")
        XCTAssertEqual(sent.items.count, 1)

        // phase 가 다르면 별건 — detail 파손과 list 파손은 구분해 집계.
        await telemetry.report(site: .clien, phase: .detail, detail: "본문 컨테이너 누락")?.value
        XCTAssertEqual(sent.items.count, 2)
    }

    func testFailedSendRetriesOnNextOccurrence() async {
        struct SendError: Error {}
        let sent = SentRecorder()
        var failFirst = true
        let telemetry = ParserFailureTelemetry(sender: { site, phase, detail in
            if failFirst {
                failFirst = false
                throw SendError()
            }
            sent.items.append((site, phase, detail))
        })

        await telemetry.report(site: .ppomppu, phase: .list, detail: "목록 0건")?.value
        XCTAssertEqual(sent.items.count, 0, "첫 전송은 실패")

        await telemetry.report(site: .ppomppu, phase: .list, detail: "목록 0건")?.value
        XCTAssertEqual(sent.items.count, 1, "전송 실패한 (site, phase) 는 다음 발생 때 재시도")
    }

    // MARK: - 본문 지문

    /// 일시적 이상 응답(순간 인터스티셜·에러 페이지)은 리포트 시점의 본문을
    /// 남기지 않으면 사후 판별이 불가능하다(2026-07-18 쿨엔 단발 케이스).
    /// 길이 + 앞부분 프리픽스만으로 "봇체크/삭제 안내/구조 변경"을 구분한다.
    func testBodyFingerprintCollapsesWhitespaceAndCaps() {
        let html = "<html>\n  <head>\t<script>  challenge page </script>\n" + String(repeating: "x", count: 500)
        let fp = ParserFailureTelemetry.bodyFingerprint(html)
        XCTAssertTrue(fp.hasPrefix("len=\(html.count)"), "원문 길이 포함 (got: \(fp))")
        XCTAssertTrue(fp.contains("<html> <head> <script> challenge page"),
                      "공백 run 은 한 칸으로 접힘 (got: \(fp.prefix(80)))")
        XCTAssertLessThan(fp.count, 260, "head 는 200자 안팎으로 캡")
    }

    func testBodyFingerprintEmptyBody() {
        XCTAssertEqual(ParserFailureTelemetry.bodyFingerprint(""), "len=0, head=")
    }
}
