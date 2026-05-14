import Hummingbird
import Foundation

/// 즉시 푸시 발사용 e2e 검증 엔드포인트 두 가지.
///
/// `POST /me/test-push` — 인증된 본인 push_token으로 발사. iOS "테스트 알림 보내기"
/// 버튼이 호출.
///
/// `GET /test-push` — 인증 없이 DB의 첫 등록 사용자에게 발사. 1인 도구 dev 편의용
/// (브라우저/curl로 즉시 검증 가능). multi-user 배포 시 제거 필요.
struct TestPushRoutes {
    let store: Store
    let apns: APNsSender

    /// JSON `{"result": "..."}` 응답.
    struct Response: Encodable, ResponseEncodable {
        let result: String
    }

    func mount(
        authed: RouterGroup<UserRequestContext>,
        root: Router<UserRequestContext>
    ) {
        authed.post("/test-push") { @concurrent [self] _, context -> EditedResponse<Response> in
            let uuid = try context.requireUUID()
            let subs = try await store.usersWithKeywords()
            guard let sub = subs[uuid] else {
                throw HTTPError(.badRequest)
            }
            let result = try await sendTo(deviceToken: sub.pushToken)
            return EditedResponse(status: .ok, response: result)
        }

        root.get("/test-push") { @concurrent [self] _, _ -> EditedResponse<Response> in
            let subs = try await store.usersWithKeywords()
            guard let first = subs.first else {
                throw HTTPError(.notFound)
            }
            let result = try await sendTo(deviceToken: first.value.pushToken)
            return EditedResponse(status: .ok, response: result)
        }
    }

    private func sendTo(deviceToken: String) async throws -> Response {
        let payload = APNsPayload(
            title: "테스트 알림",
            body: "이 알림은 /test-push에서 발사됐습니다",
            url: URL(string: "https://www.ppomppu.co.kr")!
        )
        let result = try await apns.send(deviceToken: deviceToken, payload: payload)
        return Response(result: describe(result))
    }

    private func describe(_ r: APNsResult) -> String {
        switch r {
        case .ok: return "ok"
        case .unregistered: return "unregistered"
        case .retryExhausted: return "retryExhausted"
        case .fail(let status, let body): return "fail(status=\(status), body=\(body))"
        }
    }
}
