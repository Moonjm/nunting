import XCTest
import CryptoKit
import NuntingCore
@testable import NuntingServer

final class PpomppuPollerTests: XCTestCase {
    /// `Board.ppomppuMain`과 동일 canonical path. 데스크탑 path
    /// (`/zboard/zboard.php`)는 모바일 파서가 silent하게 0건 반환(Task 8 스모크가
    /// 잡은 prod 버그)이라 테스트도 같은 mobile path를 쓴다.
    /// `Board`가 의도적으로 non-Sendable이라 `nonisolated(unsafe)`로 명시.
    nonisolated(unsafe) private static let board = Board(
        id: "ppomppu",
        site: .ppomppu,
        name: "뽐뿌게시판",
        path: "/new/bbs_list.php?id=ppomppu"
    )

    /// page=1 fixture에 글 2건. 첫 tick은 sentinel만 잡고 push 발송 안 함.
    /// 첫 실행에서 마지막 N개 글을 spam 푸시하면 사용자 경험 나쁨.
    func testFirstTickSetsSentinelWithoutSending() async throws {
        let html = Self.minimalListHTML(rows: [
            (no: "200", title: "두번째 글"),
            (no: "100", title: "첫번째 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": html])
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok")
        try await store.addKeyword(uuid: "nnt_a", keyword: "첫번째")

        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()

        let count = await apns.sentCount
        XCTAssertEqual(count, 0, "첫 tick은 sentinel만 잡고 push 안 보냄")
    }

    /// 두 번째 tick에 새 글 등장 → 매칭 사용자에게 push 1회. 410 응답이면 store에서
    /// push_token NULL로 처리.
    func testSecondTickPushesMatchingPostThenHandles410() async throws {
        // 1차 페이지: 글 1건 (id=100)
        let firstHTML = Self.minimalListHTML(rows: [
            (no: "100", title: "기존 글"),
        ])
        // 2차 페이지: 새 글 2건 (id=300, 200), 그 다음 sentinel (id=100)
        let secondHTML = Self.minimalListHTML(rows: [
            (no: "300", title: "갤럭시 S25 핫딜"),
            (no: "200", title: "다른 글"),
            (no: "100", title: "기존 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": firstHTML])

        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok-a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")

        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()  // 첫 tick — sentinel 설정

        // page=1을 두 번째 페이지로 교체 (sentinel walk가 page=1부터 다시 fetch)
        await fetcher.replace(page: "1", html: secondHTML)
        // 410을 반환하도록 stub 변경
        await apns.setNextResult(.unregistered)

        await poller.tick()  // 두 번째 tick — 새 글 매칭 + push + 410 → NULL

        let sent = await apns.sentSnapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].deviceToken, "tok-a")
        XCTAssertTrue(sent[0].payload.aps.alert.body.contains("갤럭시 S25"))

        let storedToken = try await store.pushToken(uuid: "nnt_a")
        XCTAssertNil(storedToken, "410 응답이면 push_token=NULL")
    }

    /// 매칭 안 되는 새 글만 있으면 push 0건.
    func testNonMatchingPostsDoNotPush() async throws {
        let firstHTML = Self.minimalListHTML(rows: [(no: "100", title: "기존 글")])
        let secondHTML = Self.minimalListHTML(rows: [
            (no: "200", title: "키워드와 무관한 글"),
            (no: "100", title: "기존 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": firstHTML])
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok-a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")
        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()
        await fetcher.replace(page: "1", html: secondHTML)
        await poller.tick()
        let count = await apns.sentCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Fixtures

    /// PpomppuParser가 받아들이는 minimal HTML. 글 행 N개를 위에서 아래로(=신→구) 출력.
    private static func minimalListHTML(rows: [(no: String, title: String)]) -> String {
        var html = #"<html><body><ul class="bbsList_new">"#
        for row in rows {
            html += #"""
            <li class="">
                <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=\#(row.no)"><strong>\#(row.title)</strong></a>
                <span class="rp">0</span>
                <time>10:00:00</time>
            </li>
            """#
        }
        html += "</ul></body></html>"
        return html
    }
}

// MARK: - Test-only actors / stubs

private actor StubFetcher {
    private var pages: [String: String]

    init(pages: [String: String]) { self.pages = pages }

    func replace(page: String, html: String) { pages[page] = html }

    /// `URLQueryItem` "page=N"에서 N을 키로 lookup. 첫 페이지(page param 없음)는 "1".
    nonisolated func fetch(url: URL, encoding: String.Encoding) async throws -> String {
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "page" })?
            .value ?? "1"
        return await self.lookup(page: page)
    }

    private func lookup(page: String) -> String {
        pages[page] ?? ""
    }
}

private actor StubAPNs: APNsSender {
    struct Sent {
        let deviceToken: String
        let payload: APNsPayload
    }
    private var sent: [Sent] = []
    private var nextResult: APNsResult = .ok

    func setNextResult(_ r: APNsResult) { nextResult = r }
    var sentCount: Int { sent.count }
    func sentSnapshot() -> [Sent] { sent }

    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult {
        sent.append(Sent(deviceToken: deviceToken, payload: payload))
        return nextResult
    }
}
