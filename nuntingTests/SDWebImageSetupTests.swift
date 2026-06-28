import XCTest
import SDWebImage
@testable import nunting

final class SDWebImageSetupTests: XCTestCase {
    func testConfigureRegistersSingleSignpostWebPCoderAtHighestPriority() {
        let manager = SDImageCodersManager.shared
        let originalCoders = manager.coders ?? []
        manager.coders = originalCoders.filter { !($0 is SignpostWebPCoder) }
        defer { manager.coders = originalCoders }

        SDWebImageSetup.configure()
        SDWebImageSetup.configure()

        let signpostCoders = (manager.coders ?? []).filter { $0 is SignpostWebPCoder }
        XCTAssertEqual(signpostCoders.count, 1)
        XCTAssertTrue(manager.coders?.last is SignpostWebPCoder)
    }
}
