import Foundation

/// 목록 상위 글의 detail HTML 을 미리 받아 두는 인메모리 창고 — 처음 여는
/// 글이 항상 RTT+파싱 전액을 내던 것에서 RTT 를 제거한다(재방문은
/// `PostDetailCache` 담당). URLCache 워밍이 아닌 직접 보관인 이유:
/// 게시판들의 HTML 응답은 대부분 no-cache 헤더라 URLCache 에 안 실린다.
///
/// 계약:
/// - `prefetch(posts:)` 는 `.utility` 우선순위로 동시 fetch, 실패는 조용히
///   건너뜀 (순수 최적화 계층 — 실패가 기능을 막으면 안 됨).
/// - aagag 제외: 미러 detail 은 301 리다이렉트 + 봇체크 인터스티셜 경로라
///   미리 받으면 인터스티셜을 캐시하거나 봇체크를 자극할 수 있다.
/// - `consume(id:)` 는 1회 소비(반환 후 제거) + TTL(기본 3분) — 댓글이
///   변하는 페이지라 오래된 HTML 을 재사용하지 않는다.
@MainActor
final class DetailPrefetcher {
    static let shared = DetailPrefetcher()

    typealias FetchHTML = @Sendable (URL, String.Encoding) async throws -> String

    private struct Entry {
        let html: String
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []

    private let capacity: Int
    private let ttl: TimeInterval
    private let fetchHTML: FetchHTML
    private let now: () -> Date

    init(
        capacity: Int = 10,
        ttl: TimeInterval = 180,
        fetchHTML: @escaping FetchHTML = { url, encoding in
            try await Networking.fetchHTML(url: url, encoding: encoding)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.capacity = capacity
        self.ttl = ttl
        self.fetchHTML = fetchHTML
        self.now = now
    }

    /// 목록 로드 직후 상위 글 몇 개를 warm. 이미 warm/진행 중인 글은 skip.
    /// 호출부는 `Task { await ... }` 로 fire-and-forget — 리스트 표시를
    /// 막지 않는다.
    func prefetch(posts: [Post], limit: Int = 3) async {
        let eligible = posts
            .filter { $0.site != .aagag }
            .filter { entries[$0.id] == nil && !inFlight.contains($0.id) }
            .prefix(limit)
        guard !eligible.isEmpty else { return }

        for p in eligible { inFlight.insert(p.id) }
        await withTaskGroup(of: (String, String?).self) { group in
            for p in eligible {
                let fetch = fetchHTML
                group.addTask(priority: .utility) {
                    ((p.id), try? await fetch(p.url, p.site.encoding))
                }
            }
            for await (id, html) in group {
                inFlight.remove(id)
                if let html { store(id: id, html: html) }
            }
        }
    }

    /// 신선한 warm HTML 을 1회 반환. TTL 경과분은 버린다.
    func consume(id: String) -> String? {
        guard let entry = entries[id] else { return nil }
        entries[id] = nil
        order.removeAll { $0 == id }
        guard now().timeIntervalSince(entry.fetchedAt) <= ttl else { return nil }
        return entry.html
    }

    private func store(id: String, html: String) {
        entries[id] = Entry(html: html, fetchedAt: now())
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }
}
