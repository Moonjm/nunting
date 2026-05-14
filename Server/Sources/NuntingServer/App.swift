import Hummingbird
import ServiceLifecycle

/// 테스트는 `:memory:` Store + 빈 services를 주입한다.
/// main.swift는 디스크 Store + PollerService를 주입.
public func buildApp(
    store: Store,
    additionalServices: [any Service] = []
) -> some ApplicationProtocol {
    let router = Router(context: UserRequestContext.self)

    router.get("/health") { _, _ in "ok" }

    let authed = router.group("/me")
        .add(middleware: BearerMiddleware(store: store))
    authed.get("/_echo") { _, context in
        try context.requireUUID()
    }
    PushTokenRoutes(store: store).add(to: authed)
    KeywordRoutes(store: store).add(to: authed)

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080)),
        services: additionalServices
    )
}
