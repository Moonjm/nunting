import XCTest
@testable import nunting

@MainActor
final class AlertBadgeTests: XCTestCase {
    private func item(id: Int, read: Bool) -> AlertHistoryItem {
        AlertHistoryItem(id: id, keyword: "k", postNo: "\(id)", title: "t", url: "u", sentAt: 0, read: read)
    }

    /// unread = read==false 인 항목 수.
    func testRefreshCountsUnread() async {
        let badge = AlertBadge(fetch: { [
            self.item(id: 1, read: false),
            self.item(id: 2, read: true),
            self.item(id: 3, read: false),
        ] })
        await badge.refresh()
        XCTAssertEqual(badge.unread, 2)
    }

    /// 전부 읽음이면 0.
    func testRefreshZeroWhenAllRead() async {
        let badge = AlertBadge(fetch: { [self.item(id: 1, read: true)] })
        await badge.refresh()
        XCTAssertEqual(badge.unread, 0)
    }

    /// fetch 실패 시 직전 값 유지(네트워크 일시 오류로 뱃지가 사라지지 않게).
    func testRefreshKeepsPreviousValueOnFailure() async {
        let fake = FakeHistoryFetch(.success([
            self.item(id: 1, read: false),
            self.item(id: 2, read: false),
        ]))
        let badge = AlertBadge(fetch: { try await fake.fetch() })
        await badge.refresh()
        XCTAssertEqual(badge.unread, 2)

        fake.result = .failure(URLError(.notConnectedToInternet))
        await badge.refresh()
        XCTAssertEqual(badge.unread, 2, "실패 시 직전 값 유지")
    }
}

/// 두 번째 refresh 에서 동작을 바꿔야 해서(성공 → 실패) 가변 상태를 담는 박스.
private final class FakeHistoryFetch: @unchecked Sendable {
    var result: Result<[AlertHistoryItem], Error>
    init(_ result: Result<[AlertHistoryItem], Error>) { self.result = result }
    func fetch() async throws -> [AlertHistoryItem] { try result.get() }
}
