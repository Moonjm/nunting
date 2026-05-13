import Hummingbird

/// BearerMiddleware가 검증 통과 후 uuid를 싣고, 라우트 핸들러가 읽는다.
/// `userUUID`가 nil인 경로에 라우트 도달하면 미들웨어가 빠진 것 = 라우터
/// 설정 버그. 라우트 핸들러는 force-unwrap이 아닌 require()로 401을 던진다.
struct UserRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    var userUUID: String?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.userUUID = nil
    }
}

extension UserRequestContext {
    func requireUUID() throws -> String {
        guard let userUUID else {
            throw HTTPError(.unauthorized)
        }
        return userUUID
    }
}
