import Hummingbird

/// `Authorization: Bearer nnt_<uuid>` 검증 + users.upsert.
///
/// 스펙 §인증 정확히 그대로:
///  - 헤더 없거나 prefix가 "nnt_"가 아니면 401.
///  - 통과한 토큰을 그대로 users.uuid로 upsert.
///  - users.uuid를 context에 싣고 next.
struct BearerMiddleware: MiddlewareProtocol {
    typealias Context = UserRequestContext

    let store: Store
    private static let bearerPrefix = "Bearer "
    private static let uuidPrefix = "nnt_"

    @concurrent
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization],
              header.hasPrefix(Self.bearerPrefix)
        else {
            throw HTTPError(.unauthorized)
        }
        let token = String(header.dropFirst(Self.bearerPrefix.count))
        guard token.hasPrefix(Self.uuidPrefix), token.count > Self.uuidPrefix.count else {
            throw HTTPError(.unauthorized)
        }
        try await store.upsertUser(uuid: token)
        var context = context
        context.userUUID = token
        return try await next(request, context)
    }
}
