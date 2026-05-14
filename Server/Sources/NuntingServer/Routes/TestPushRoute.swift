import Hummingbird
import Foundation

/// `POST /me/test-push` — 폴러 매칭과 무관하게 본인 사용자에게 즉시 푸시 한 발 발사.
/// e2e 검증용. 본인 push_token이 NULL이면 400.
struct TestPushRoutes {
    let store: Store
    let apns: APNsSender

    /// JSON `{"result": "..."}` 형태로 응답. iOS 테스트 버튼이 그대로 파싱해 표시.
    struct Response: Encodable, ResponseEncodable {
        let result: String
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.post("/test-push") { @concurrent _, context -> EditedResponse<Response> in
            let uuid = try context.requireUUID()
            let subs = try await store.usersWithKeywords()
            guard let sub = subs[uuid] else {
                throw HTTPError(.badRequest)
            }
            let payload = APNsPayload(
                title: "테스트 알림",
                body: "이 알림은 /me/test-push에서 발사됐습니다",
                url: URL(string: "https://www.ppomppu.co.kr")!
            )
            let result = try await apns.send(deviceToken: sub.pushToken, payload: payload)
            return EditedResponse(status: .ok, response: Response(result: describe(result)))
        }
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
