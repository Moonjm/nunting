import XCTest
import UIKit
@testable import nunting

@MainActor
final class MemoryPressureResponderTests: XCTestCase {

    /// Tracks invocation counts on the responder's clear hooks so the
    /// test can verify the notification observer routed correctly without
    /// actually touching the SDImageCache / URLCache singletons.
    private final class CallCounter {
        var imageClearCalls = 0
        var urlClearCalls = 0
    }

    private var counter: CallCounter!
    private var responder: MemoryPressureResponder!

    override func setUp() async throws {
        try await super.setUp()
        counter = CallCounter()
        responder = MemoryPressureResponder.shared
        // Reset any production wiring from prior tests / app launch so each
        // test starts from a known seam state.
        responder.clearImageMemoryCache = { [counter] in
            counter?.imageClearCalls += 1
        }
        responder.clearURLMemoryCache = { [counter] in
            counter?.urlClearCalls += 1
        }
        responder.start()
    }

    override func tearDown() async throws {
        // Restore no-op handlers so a later test that drives the singleton
        // doesn't accidentally increment our (out-of-scope) counter.
        responder.clearImageMemoryCache = {}
        responder.clearURLMemoryCache = {}
        try await super.tearDown()
    }

    func testRespondInvokesBothClearHooks() {
        responder.respond()
        XCTAssertEqual(counter.imageClearCalls, 1)
        XCTAssertEqual(counter.urlClearCalls, 1)
    }

    func testRespondIsIdempotent() {
        responder.respond()
        responder.respond()
        responder.respond()
        XCTAssertEqual(counter.imageClearCalls, 3)
        XCTAssertEqual(counter.urlClearCalls, 3)
    }

    func testMemoryWarningNotificationTriggersRespond() {
        let expectation = expectation(description: "respond observed")
        responder.clearImageMemoryCache = { [counter] in
            counter?.imageClearCalls += 1
            expectation.fulfill()
        }
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(counter.imageClearCalls, 1)
        XCTAssertEqual(counter.urlClearCalls, 1)
    }

    func testStartReplacesPriorObserver() {
        // Calling start() twice should not result in respond() being
        // invoked twice per notification.
        responder.start()
        responder.start()
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        // Give the notification one runloop tick to dispatch.
        let exp = expectation(description: "tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(counter.imageClearCalls, 1, "single observer after re-start()")
        XCTAssertEqual(counter.urlClearCalls, 1)
    }
}
