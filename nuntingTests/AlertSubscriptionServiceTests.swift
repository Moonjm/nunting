import XCTest
@testable import nunting

final class AlertSubscriptionServiceTests: XCTestCase {
    /// addKeyword → POST + 정규화 결과 echo. 서버 Plan 2가 `"galaxy s25"` 형태로 200 반환.
    func testAddKeywordReturnsNormalizedFromServer() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 201, body: #""galaxy s25""#)
        let uuidStore = InMemoryUUIDStore(value: "nnt_test")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: uuidStore
        )
        let normalized = try await service.addKeyword("  Galaxy S25  ")
        XCTAssertEqual(normalized, "galaxy s25")

        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.url?.absoluteString, "http://example.com/me/keywords")
        XCTAssertEqual(recorded?.httpMethod, "POST")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Authorization"), "Bearer nnt_test")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8)
        XCTAssertTrue(body?.contains("Galaxy S25") == true)
    }

    /// listKeywords → GET → JSON array.
    func testListKeywordsParsesJSONArray() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 200, body: #"["apple","banana"]"#)
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let listed = try await service.listKeywords()
        XCTAssertEqual(listed, ["apple", "banana"])
    }

    /// removeKeyword → DELETE /me/keywords/{encoded}.
    /// 한글 keyword가 URL-encoded되는지 검증.
    func testRemoveKeywordURLEncodesKeywordSegment() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.removeKeyword("갤럭시")
        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.httpMethod, "DELETE")
        XCTAssertTrue(
            recorded?.url?.absoluteString.contains("/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C") == true,
            "한글 keyword segment가 percent-encoded돼야 함"
        )
    }

    /// registerPushToken → PUT body `{"token": "<hex>"}`.
    func testRegisterPushTokenSendsHexBody() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let tokenData = Data([0xAA, 0xBB, 0xCC, 0xDD])
        try await service.registerPushToken(tokenData)
        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.httpMethod, "PUT")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"token\":\"aabbccdd\""), "hex lowercased 4바이트")
    }

    /// clearPushToken → PUT body `{"token": null}`.
    /// iOS가 권한 회수 후 onAppear 등에서 호출. 서버는 push_token NULL 저장.
    func testClearPushTokenSendsNullBody() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.clearPushToken()
        let recorded = await stub.lastRequest()
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertEqual(body, #"{"token":null}"#)
    }

    /// 4xx 응답 시 throw — 호출자가 retry/UI 처리.
    func testNon2xxResponseThrows() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 400, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        do {
            _ = try await service.addKeyword("x")
            XCTFail("400 응답에서 throw해야 함")
        } catch is AlertSubscriptionError {
            // ok
        }
    }

    /// HTTPURLResponse가 아닌 응답이 와도 force-cast crash 대신 throw해야 함.
    /// (file:// scheme 등 비정상 경로에서 발생 가능)
    func testNonHTTPResponseThrowsInsteadOfCrashing() async throws {
        let stub = NonHTTPResponseRequester()
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        do {
            _ = try await service.listKeywords()
            XCTFail("non-HTTP response에서 throw해야 함")
        } catch is AlertSubscriptionError {
            // ok
        }
    }
}

// MARK: - Test stubs

actor StubHTTPRequester: HTTPRequester {
    private var nextStatus: Int = 200
    private var nextBody: Data = Data()
    private(set) var recorded: URLRequest?

    func setNext(status: Int, body: String) {
        self.nextStatus = status
        self.nextBody = body.data(using: .utf8) ?? Data()
    }
    func lastRequest() -> URLRequest? { recorded }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        recorded = request
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: nextStatus,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (nextBody, resp)
    }
}

struct InMemoryUUIDStore: UUIDStore {
    let value: String
    func getOrCreate() throws -> String { value }
}

/// HTTPURLResponse가 아닌 평범한 URLResponse를 반환.
/// 안전 캐스트 경로 검증용.
struct NonHTTPResponseRequester: HTTPRequester {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let resp = URLResponse(
            url: request.url!,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        return (Data(), resp)
    }
}
