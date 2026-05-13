import Hummingbird

/// 테스트는 `:memory:` Store를, main.swift는 디스크 Store를 주입한다.
/// 라우트는 후속 task에서 채워진다. 지금은 /health(인증 없이)와 /me/_echo
/// (인증 통과 후 uuid echo) 두 개만 둔다.
public func buildApp(store: Store) -> some ApplicationProtocol {
    let router = Router(context: UserRequestContext.self)

    router.get("/health") { _, _ in "ok" }

    let authed = router.group("/me")
        .add(middleware: BearerMiddleware(store: store))
    authed.get("/_echo") { _, context in
        try context.requireUUID()
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080))
    )
}
