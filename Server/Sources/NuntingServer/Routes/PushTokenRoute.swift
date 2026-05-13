import Hummingbird

/// `PUT /me/push-token` — iOS가 APNs device token 또는 NULL을 올린다.
/// 본문이 `{"token": null}` 또는 키 누락이면 알림 권한 회수 신호로 보고
/// users.push_token을 NULL로 비운다(폴러가 발송 대상에서 제외).
struct PushTokenRoutes {
    let store: Store

    struct PutTokenRequest: Decodable {
        let token: String?
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.put("/push-token") { @concurrent request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: PutTokenRequest.self, context: context)
            let uuid = try context.requireUUID()
            try await store.setPushToken(uuid: uuid, token: body.token)
            return .noContent
        }
    }
}
