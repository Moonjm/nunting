import Hummingbird

/// `PUT /me/push-token` — iOS가 APNs device token 또는 NULL을 올린다.
/// 본문이 `{"token": null}` 또는 키 누락이면 알림 권한 회수 신호로 보고
/// users.push_token을 NULL로 비운다(폴러가 발송 대상에서 제외).
struct PushTokenRoutes {
    let store: Store
    /// APNs device token은 64 hex chars (~200 bytes). 여유를 두되 abuse 시
    /// DB row 비대를 막기 위한 sanity bound.
    static let maxTokenLength = 256

    struct PutTokenRequest: Decodable {
        let token: String?
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.put("/push-token") { @concurrent request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: PutTokenRequest.self, context: context)
            if let token = body.token, token.count > Self.maxTokenLength {
                throw HTTPError(.badRequest)
            }
            let uuid = try context.requireUUID()
            try await store.setPushToken(uuid: uuid, token: body.token)
            return .noContent
        }
    }
}
