import Hummingbird

/// Build the HTTP application.
///
/// 테스트는 in-memory store로 이걸 호출하고, main.swift는 디스크 path를
/// 가진 store로 호출한다. 라우트는 task 5~6에서 채워진다.
public func buildApp() -> some ApplicationProtocol {
    let router = Router()
    router.get("/health") { _, _ in "ok" }
    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080))
    )
}
