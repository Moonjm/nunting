import XCTest
@testable import nunting

// @MainActor: AlertSubscriptionService 가 main actor 소속(앱 서비스).
@MainActor
final class AlertSubscriptionServiceTests: XCTestCase {
    /// upsertKeyword → POST {keyword, exclude} + 정규화된 KeywordSub echo.
    func testUpsertKeywordReturnsNormalizedFromServer() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 201, body: #"{"keyword":"galaxy s25","exclude":"중고"}"#)
        let uuidStore = InMemoryUUIDStore(value: "nnt_test")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: uuidStore
        )
        let sub = try await service.upsertKeyword(keyword: "  Galaxy S25  ", exclude: "중고")
        XCTAssertEqual(sub.keyword, "galaxy s25")
        XCTAssertEqual(sub.exclude, "중고")

        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.url?.absoluteString, "http://example.com/me/keywords")
        XCTAssertEqual(recorded?.httpMethod, "POST")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Authorization"), "Bearer nnt_test")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8)
        XCTAssertTrue(body?.contains("Galaxy S25") == true)
        XCTAssertTrue(body?.contains("중고") == true)
    }

    /// listKeywords → GET → [KeywordSub] (keyword/exclude 객체 배열).
    func testListKeywordsParsesJSONArray() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 200,
            body: #"[{"keyword":"apple","exclude":""},{"keyword":"banana","exclude":"used,중고"}]"#)
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let listed = try await service.listKeywords()
        XCTAssertEqual(listed.map(\.keyword), ["apple", "banana"])
        XCTAssertEqual(listed.map(\.exclude), ["", "used,중고"])
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

    /// removeKeyword 의 keyword 에 "/" 가 있어도 한 세그먼트로 유지(%2F).
    /// urlPathAllowed 는 "/" 를 안 막아 "a/b" 가 다중 세그먼트로 새던 버그 방지.
    func testRemoveKeywordEncodesSlashAsSingleSegment() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.removeKeyword("a/b")
        let recorded = await stub.lastRequest()
        let urlStr = recorded?.url?.absoluteString ?? ""
        XCTAssertTrue(urlStr.contains("/me/keywords/a%2Fb"),
                      "'/' 가 %2F 로 인코딩돼 단일 세그먼트여야 함: \(urlStr)")
        XCTAssertFalse(urlStr.contains("/me/keywords/a/b"))
    }

    /// listKeywords 가 enabled 를 파싱하고, 누락 시 true(켜짐)로 기본 처리.
    func testListKeywordsParsesEnabledWithDefault() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 200,
            body: #"[{"keyword":"a","exclude":"","enabled":false},{"keyword":"b","exclude":""}]"#)
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let listed = try await service.listKeywords()
        XCTAssertEqual(listed.map(\.enabled), [false, true],
                       "enabled 명시 false 는 false, 누락은 true(구버전 호환)")
    }

    /// setKeywordEnabled → POST /me/keywords/{encoded}/enabled, body {"enabled":bool}.
    func testSetKeywordEnabledPostsToggle() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 200, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.setKeywordEnabled(keyword: "갤럭시", enabled: false)
        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.httpMethod, "POST")
        let urlStr = recorded?.url?.absoluteString ?? ""
        XCTAssertTrue(urlStr.contains("/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C/enabled"),
                      "한글 keyword segment percent-encoded + /enabled: \(urlStr)")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"enabled\":false"), "body: \(body)")
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
            _ = try await service.upsertKeyword(keyword: "x", exclude: "")
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
        } catch AlertSubscriptionError.nonHTTPResponse {
            // ok — 다른 AlertSubscriptionError로 떨어지면 의도 어긋남
        }
    }

    /// reportParserFailure → POST /me/metrics?kind=parser + {site, phase, detail}.
    /// 서버는 kind 를 검증 없이 저장하므로(admin 뷰가 해석) 서버 수정 없이
    /// 기존 metrics 채널에 파서 실패 집계를 싣는다.
    func testReportParserFailurePostsToMetricsWithParserKind() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )

        try await service.reportParserFailure(site: "clien", phase: "list", detail: "목록 0건")

        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.url?.absoluteString, "http://example.com/me/metrics?kind=parser")
        XCTAssertEqual(recorded?.httpMethod, "POST")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""site":"clien""#), "body: \(body)")
        XCTAssertTrue(body.contains(#""phase":"list""#), "body: \(body)")
        XCTAssertTrue(body.contains("목록 0건"), "body: \(body)")
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
