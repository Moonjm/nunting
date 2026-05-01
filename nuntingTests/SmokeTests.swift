import XCTest
@testable import nunting

/// Sanity check that the test bundle loads, links against the app target,
/// and `@testable import nunting` resolves. Real assertion suites live in
/// the per-area test files alongside this one.
final class SmokeTests: XCTestCase {
    func testBundleLoadsAndAppSymbolsResolve() {
        XCTAssertEqual(Site.clien.rawValue, "clien")
    }
}
