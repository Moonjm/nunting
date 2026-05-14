import Foundation
import NuntingCore

/// 뽐뿌 게시판 폴러. 3분 주기로 tick.
///
/// 동작:
///  1) lastSeenPostId == nil이면 page=1만 페치해 top post.id를 sentinel로 저장하고 종료.
///  2) lastSeenPostId가 있으면 page=1부터 sentinel을 만날 때까지 또는 maxPages 까지 walk.
///  3) sentinel을 만나기 전까지의 글을 reverse(=시간순)로 매칭 + APNs send.
///  4) APNs 응답이 .unregistered면 store.setPushToken(uuid, nil)로 self-heal.
///  5) sentinel을 새 최신 글 id로 갱신.
///
/// 종속성은 외부 주입:
///  - fetcher: HTML fetch (테스트는 stub, 프로덕션은 ServerNetworking.fetchHTML)
///  - store: Store actor (구독자 스냅샷 + 410 처리)
///  - apns: APNsSender (테스트는 stub, 프로덕션은 APNsClient)
public actor PpomppuPoller {
    public typealias Fetcher = @Sendable (URL, String.Encoding) async throws -> String

    private let board: Board
    private let store: Store
    private let apns: APNsSender
    private let fetcher: Fetcher
    private let maxPages: Int

    private var lastSeenPostId: String?

    public init(
        board: Board,
        store: Store,
        apns: APNsSender,
        fetcher: @escaping Fetcher,
        maxPages: Int = 10
    ) {
        self.board = board
        self.store = store
        self.apns = apns
        self.fetcher = fetcher
        self.maxPages = maxPages
    }

    public func tick() async {
        do {
            try await tickThrowing()
        } catch {
            // 네트워크/파서 실패는 다음 tick에 다시 — 로깅만.
            // 운영에서는 stderr로 흐르고, 다중 연속 실패는 PR E의 health check가 잡는다.
            print("[PpomppuPoller] tick error: \(error)")
        }
    }

    private func tickThrowing() async throws {
        // 1) 첫 실행 — sentinel만 잡고 종료
        guard let sentinel = lastSeenPostId else {
            let posts = try await fetchAndParse(page: 1)
            lastSeenPostId = posts.first?.id
            return
        }

        // 2) sentinel walk
        var newPosts: [Post] = []
        outer: for page in 1...maxPages {
            let posts = try await fetchAndParse(page: page)
            if posts.isEmpty { break outer }
            for post in posts {
                if post.id == sentinel { break outer }
                newPosts.append(post)
            }
        }
        if newPosts.isEmpty { return }

        // 3) 오래된 것부터 send (push 도착 순서 정렬)
        newPosts.reverse()

        // 4) 구독자 스냅샷 + 매칭
        let subscriptions = try await store.usersWithKeywords()
        let userKeywords = subscriptions.mapValues { $0.keywords }
        let matches = KeywordMatcher.match(posts: newPosts, subscriptions: userKeywords)

        for m in matches {
            guard let sub = subscriptions[m.uuid] else { continue }
            let payload = APNsPayload(
                title: "뽐뿌 — \(m.keyword)",
                body: m.post.title,
                url: m.post.url
            )
            do {
                let result = try await apns.send(deviceToken: sub.pushToken, payload: payload)
                if case .unregistered = result {
                    try? await store.setPushToken(uuid: m.uuid, token: nil)
                }
            } catch {
                print("[PpomppuPoller] APNs send error for uuid=\(m.uuid): \(error)")
            }
        }

        // 5) sentinel 갱신 — newPosts.last가 newest (reverse 후)
        lastSeenPostId = newPosts.last?.id
    }

    private func fetchAndParse(page: Int) async throws -> [Post] {
        // `board.site.baseURL`(`https://m.ppomppu.co.kr`)에 `board.path`(`/new/bbs_list.php?id=ppomppu`)
        // 를 붙여 모바일 리스트 페이지를 fetch. 데스크탑(`www.ppomppu.co.kr/zboard/zboard.php`)
        // 은 DOM 구조가 달라 `PpomppuParser.parseList`가 0건을 반환한다(Task 8 스모크에서 발견).
        var components = URLComponents(url: board.site.baseURL, resolvingAgainstBaseURL: false)!
        if let pathComps = URLComponents(string: board.path) {
            components.path = pathComps.path
            components.queryItems = pathComps.queryItems
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        components.queryItems = queryItems
        let url = components.url!
        let html = try await fetcher(url, board.site.encoding)
        return try PpomppuParser().parseList(html: html, board: board)
    }
}
