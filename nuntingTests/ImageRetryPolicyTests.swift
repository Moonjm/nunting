import SDWebImage
import XCTest
@testable import nunting

/// `ImageRetryPolicy` — 이미지 실패에서 회복하는 규칙의 계약.
///
/// 배경(시뮬레이터 실측): `SDWebImageManager` 는 실패 URL 을 `failedURLs` 에
/// 넣고 이후 로드를 네트워크 없이 즉시 끊는다.
///
///   1차 로드        → BadImageData (1001)  0.58s
///   2차 "다시 시도"  → BlackListed  (1003)  0.00s
///   3차 .retryFailed → 정상 재시도          0.06s
///
/// 그래서 재시도 버튼은 **블랙리스트를 먼저 풀어야** 재시도가 된다. 아래
/// 테스트는 SDK 싱글턴 대신 seam 을 검사한다 — 확인해야 하는 건 SDWebImage 의
/// 동작(위에서 확인함)이 아니라 **우리 배선**이고, 그 배선의 유일한 함정이
/// URL 정규화이기 때문이다.
@MainActor
final class ImageRetryPolicyTests: XCTestCase {

    private var clearedURLs: [URL] = []
    private var clearAllCount = 0

    override func setUp() {
        super.setUp()
        clearedURLs = []
        clearAllCount = 0
        ImageRetryPolicy.clearFailedURL = { [self] in clearedURLs.append($0) }
        ImageRetryPolicy.clearAllFailedURLs = { [self] in clearAllCount += 1 }
    }

    override func tearDown() {
        ImageRetryPolicy.clearFailedURL = { SDWebImageManager.shared.removeFailedURL($0) }
        ImageRetryPolicy.clearAllFailedURLs = { SDWebImageManager.shared.removeAllFailedURLs() }
        super.tearDown()
    }

    /// 이 계약이 이 수정의 전부다 — 누르면 블랙리스트가 풀려야 한다.
    func testPrepareRetryClearsTheURL() {
        ImageRetryPolicy.prepareRetry(for: URL(string: "https://cdn.example.com/a.jpg")!)
        XCTAssertEqual(clearedURLs.map(\.absoluteString), ["https://cdn.example.com/a.jpg"])
    }

    /// 함정: 블랙리스트의 키는 **실제로 로드한** URL 이다. 본문 이미지는
    /// `url.atsSafe`(http→https 승격)로 로드하므로, 원본 `http://` URL 로
    /// 지우면 키가 어긋나 아무 일도 일어나지 않는다 — 버튼은 여전히 먹통.
    func testPrepareRetryNormalizesToTheLoadedURL() {
        ImageRetryPolicy.prepareRetry(for: URL(string: "http://cdn.example.com/a.jpg")!)
        XCTAssertEqual(clearedURLs.map(\.absoluteString), ["https://cdn.example.com/a.jpg"],
                       "atsSafe 로 승격된 URL 이 실제 로드/블랙리스트 키")
    }

    /// 포그라운드 복귀는 실패 이력을 통째로 비운다 — 흔한 방아쇠가
    /// "다운로드 중 백그라운드 전환" 이라 복귀 시점엔 그 이력이 현재 조건을
    /// 반영하지 않는다.
    func testForegroundClearsAllFailures() {
        ImageRetryPolicy.onForeground()
        ImageRetryPolicy.onForeground()
        XCTAssertEqual(clearAllCount, 2)
        XCTAssertTrue(clearedURLs.isEmpty, "전체 비움은 개별 경로를 타지 않는다")
    }
}
