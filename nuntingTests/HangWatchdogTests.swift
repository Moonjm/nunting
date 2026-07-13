import XCTest
import os
@testable import nunting

/// ThreadBacktrace — 지정한 mach thread 의 콜스택 캡처.
final class ThreadBacktraceTests: XCTestCase {

    /// 잠들어 있는 워커 스레드의 스택을 밖에서 캡처할 수 있어야 한다.
    /// (워치독이 hang 중인 메인 스레드에 하는 일과 동일한 경로)
    func testCapturesFramesOfSleepingThread() {
        let portBox = OSAllocatedUnfairLock<thread_t?>(initialState: nil)
        let worker = Thread {
            portBox.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
            Thread.sleep(forTimeInterval: 3)
        }
        worker.start()

        var port: thread_t?
        for _ in 0..<100 {
            port = portBox.withLock { $0 }
            if port != nil { break }
            usleep(10_000)
        }
        guard let port else { return XCTFail("worker port 미수신") }
        // 스레드가 sleep 에 진입할 시간을 준다.
        usleep(50_000)

        let frames = ThreadBacktrace.capture(thread: port)
        XCTAssertGreaterThan(frames.count, 2, "sleep 중인 스레드 스택이 비어 있음: \(frames)")
    }

    /// 자기 자신 캡처는 suspend 자살 방지를 위해 빈 배열.
    func testCapturingSelfReturnsEmpty() {
        let selfPort = pthread_mach_thread_np(pthread_self())
        XCTAssertTrue(ThreadBacktrace.capture(thread: selfPort).isEmpty)
    }
}

@MainActor
final class HangWatchdogTests: XCTestCase {

    /// 메인 스레드를 임계 이상 막으면 지속시간 + 스택 샘플이 리포트돼야 한다.
    func testReportsHangWithStackSamples() {
        let reportBox = OSAllocatedUnfairLock<HangReportDTO?>(initialState: nil)
        let exp = expectation(description: "hang report")
        let watchdog = HangWatchdog(
            pingInterval: 0.05,
            threshold: 0.2,
            onReport: { report in
                reportBox.withLock { $0 = report }
                exp.fulfill()
            }
        )
        watchdog.noteEvent("test:block")
        watchdog.start()
        defer { watchdog.stop() }

        // 첫 ping/pong 사이클이 돌 시간.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        // 메인 스레드 0.6초 블록 — 임계(0.2s) 초과.
        Thread.sleep(forTimeInterval: 0.6)

        wait(for: [exp], timeout: 3)
        guard let report = reportBox.withLock({ $0 }) else { return XCTFail("리포트 없음") }
        XCTAssertGreaterThanOrEqual(report.durationMs, 400, "블록 0.6s 대비 duration 과소")
        XCTAssertEqual(report.label, "test:block")
        XCTAssertFalse(report.samples.isEmpty, "스택 샘플이 없음")
        XCTAssertFalse(report.samples[0].frames.isEmpty, "샘플 프레임이 빔")
    }

    /// 메인 스레드가 정상 응답하면 리포트가 없어야 한다.
    func testNoReportWhenResponsive() {
        let reported = OSAllocatedUnfairLock<Bool>(initialState: false)
        let watchdog = HangWatchdog(
            pingInterval: 0.05,
            threshold: 0.2,
            onReport: { _ in reported.withLock { $0 = true } }
        )
        watchdog.start()
        defer { watchdog.stop() }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertFalse(reported.withLock { $0 })
    }

    /// pause 중에는 메인을 막아도 리포트가 없어야 한다(백그라운드 suspend 오탐 방지).
    func testNoReportWhilePaused() {
        let reported = OSAllocatedUnfairLock<Bool>(initialState: false)
        let watchdog = HangWatchdog(
            pingInterval: 0.05,
            threshold: 0.2,
            onReport: { _ in reported.withLock { $0 = true } }
        )
        watchdog.start()
        defer { watchdog.stop() }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        watchdog.pause()
        Thread.sleep(forTimeInterval: 0.5)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertFalse(reported.withLock { $0 })

        // resume 후에는 다시 감지해야 한다.
        let exp = expectation(description: "resumed hang report")
        let resumedReport = OSAllocatedUnfairLock<Bool>(initialState: false)
        watchdog.onReportForTesting { _ in
            if !resumedReport.withLock({ let was = $0; $0 = true; return was }) { exp.fulfill() }
        }
        watchdog.resume()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        Thread.sleep(forTimeInterval: 0.6)
        wait(for: [exp], timeout: 3)
    }

    /// 서버 DTO 인코딩 계약 — Go 쪽 파싱 키와 합의된 형태.
    func testReportDTOEncoding() throws {
        let report = HangReportDTO(
            ts: 1_752_000_000,
            durationMs: 1234,
            label: "post:open",
            samples: [HangSampleDTO(atMs: 1000, frames: ["0 nunting foo + 12"])]
        )
        let data = try JSONEncoder().encode(report)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["durationMs"] as? Int, 1234)
        XCTAssertEqual(obj["label"] as? String, "post:open")
        let samples = try XCTUnwrap(obj["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.first?["atMs"] as? Int, 1000)
    }
}
