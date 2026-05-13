import Foundation
import Hummingbird

/// `GET/POST/DELETE /me/keywords` — 사용자별 키워드 구독 CRUD.
/// 정규화(trim+lowercase)와 길이 제한(50)은 라우트 layer에서 처리하고
/// Store에는 이미 정규화된 값을 넘긴다(Store doc contract).
struct KeywordRoutes {
    let store: Store
    static let maxKeywordLength = 50

    struct PostKeywordRequest: Decodable {
        let keyword: String
    }

    /// Hummingbird의 `String: ResponseGenerator`는 text/plain으로 응답한다.
    /// POST의 echo body는 JSON 문자열(따옴표 포함)이 스펙이라 이 wrapper로
    /// 단일 값 컨테이너에 인코딩 → `"galaxy s25"` 형태 보장.
    struct JSONStringBody: ResponseEncodable {
        let value: String
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.get("/keywords") { @concurrent _, context -> [String] in
            try await store.listKeywords(uuid: try context.requireUUID())
        }

        router.post("/keywords") { @concurrent request, context -> EditedResponse<JSONStringBody> in
            let body = try await request.decode(as: PostKeywordRequest.self, context: context)
            let normalized = Store.normalizedKeyword(body.keyword)
            guard !normalized.isEmpty else { throw HTTPError(.badRequest) }
            guard normalized.count <= Self.maxKeywordLength else { throw HTTPError(.badRequest) }
            let uuid = try context.requireUUID()
            try await store.addKeyword(uuid: uuid, keyword: normalized)
            return EditedResponse(status: .created, response: JSONStringBody(value: normalized))
        }

        router.delete("/keywords/{keyword}") { @concurrent _, context -> HTTPResponse.Status in
            let raw = try context.parameters.require("keyword")
            // Hummingbird는 path parameter를 raw로 보관(URL-decode 안 함). 한글 등
            // 비-ASCII 키워드 round-trip 위해 직접 percent-decode 후 정규화.
            let decoded = raw.removingPercentEncoding ?? raw
            let normalized = Store.normalizedKeyword(decoded)
            let uuid = try context.requireUUID()
            try await store.removeKeyword(uuid: uuid, keyword: normalized)
            return .noContent
        }
    }
}
