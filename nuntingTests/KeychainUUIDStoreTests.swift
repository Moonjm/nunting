import XCTest
@testable import nunting

// @MainActor: 검증 대상 스토어/로더가 main actor 소속 — Swift 6 모드에서
// nonisolated 테스트가 동기 접근할 수 없어 테스트 클래스를 main actor 로 올린다.
@MainActor
final class KeychainUUIDStoreTests: XCTestCase {
    /// 같은 service+account 키로 두 번 호출하면 같은 UUID 반환(멱등).
    /// 실제 Keychain에 쓰므로 service 이름에 random suffix를 두고 tearDown에서 삭제.
    private let testService = "com.moonjm.nunting.test.\(UUID().uuidString)"

    override func tearDown() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
        ]
        SecItemDelete(q as CFDictionary)
        super.tearDown()
    }

    func testGetOrCreateReturnsSameValueOnRepeatedCalls() throws {
        let store = KeychainUUIDStore(service: testService, account: "uuid")
        let first = try store.getOrCreate()
        let second = try store.getOrCreate()
        XCTAssertEqual(first, second, "Keychain에 한 번 저장된 UUID는 멱등 조회돼야 함")
        XCTAssertTrue(first.hasPrefix("nnt_"))
    }

    func testGeneratedValueHasNNTPrefixAndUUIDBody() throws {
        let store = KeychainUUIDStore(service: testService, account: "uuid")
        let value = try store.getOrCreate()
        XCTAssertTrue(value.hasPrefix("nnt_"))
        let body = String(value.dropFirst("nnt_".count))
        XCTAssertNotNil(UUID(uuidString: body), "prefix 뒤는 UUID() 문자열")
    }
}
