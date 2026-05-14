import Hummingbird
import ServiceLifecycle

/// 테스트는 `:memory:` Store + 빈 services를 주입한다.
/// main.swift는 디스크 Store + PollerService를 주입.
///
/// `bindHost`/`bindPort`: 기본 `127.0.0.1:8080` (loopback only).
/// LAN의 iOS 디바이스가 hit하려면 `0.0.0.0`으로 bind 필요 — main.swift가
/// `NUNTING_BIND_HOST` env로 override.
public func buildApp(
    store: Store,
    additionalServices: [any Service] = [],
    bindHost: String = "127.0.0.1",
    bindPort: Int = 8080
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
        configuration: .init(address: .hostname(bindHost, port: bindPort)),
        services: additionalServices
    )
}
