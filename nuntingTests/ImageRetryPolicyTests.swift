import SDWebImage
import SDWebImageSwiftUI
import SwiftUI
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
/// 그래서 재시도 버튼은 **블랙리스트를 먼저 풀어야** 재시도가 된다. 그리고
/// 블랙리스트를 푸는 것만으로는 화면이 안 바뀐다 — 실패 슬롯은 `NetworkImage`
/// 의 `failed` @State 로 굳어 있다. 두 축을 각각 핀한다.
@MainActor
final class ImageRetryPolicyTests: XCTestCase {

    private var clearedURLs: [URL] = []
    private var clearAllCount = 0

    override func setUp() {
        super.setUp()
        clearedURLs = []
        clearAllCount = 0
        ImageRetryPolicy.shared.clearFailedURL = { [self] in clearedURLs.append($0) }
        ImageRetryPolicy.shared.clearAllFailedURLs = { [self] in clearAllCount += 1 }
    }

    override func tearDown() {
        ImageRetryPolicy.shared.clearFailedURL = { SDWebImageManager.shared.removeFailedURL($0) }
        ImageRetryPolicy.shared.clearAllFailedURLs = { SDWebImageManager.shared.removeAllFailedURLs() }
        super.tearDown()
    }

    /// 누르면 블랙리스트가 풀려야 한다 — 이 계약이 없으면 버튼이 거짓말이다.
    func testPrepareRetryClearsTheURL() {
        ImageRetryPolicy.shared.prepareRetry(for: URL(string: "https://cdn.example.com/a.jpg")!)
        XCTAssertEqual(clearedURLs.map(\.absoluteString), ["https://cdn.example.com/a.jpg"])
    }

    /// 함정: 블랙리스트의 키는 **실제로 로드한** URL 이다. 본문 이미지는
    /// `url.atsSafe`(http→https 승격)로 로드하므로, 원본 `http://` URL 로
    /// 지우면 키가 어긋나 아무 일도 일어나지 않는다 — 버튼은 여전히 먹통.
    func testPrepareRetryNormalizesToTheLoadedURL() {
        ImageRetryPolicy.shared.prepareRetry(for: URL(string: "http://cdn.example.com/a.jpg")!)
        XCTAssertEqual(clearedURLs.map(\.absoluteString), ["https://cdn.example.com/a.jpg"],
                       "atsSafe 로 승격된 URL 이 실제 로드/블랙리스트 키")
    }

    /// 백그라운드를 지나온 복귀는 실패 이력을 통째로 비우고 **방송한다**.
    /// 방송이 없으면 블랙리스트만 비고 화면은 그대로 "다시 시도" 다.
    func testForegroundAfterBackgroundClearsAllFailuresAndBroadcasts() {
        var broadcasts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ImageRetryPolicy.failuresClearedNotification,
            object: nil, queue: .main) { _ in broadcasts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        ImageRetryPolicy.shared.noteBackground()
        XCTAssertTrue(ImageRetryPolicy.shared.onForeground())

        XCTAssertEqual(clearAllCount, 1)
        XCTAssertEqual(broadcasts, 1)
        XCTAssertTrue(clearedURLs.isEmpty, "전체 비움은 개별 경로를 타지 않는다")
    }

    /// `.active` 는 백그라운드 복귀 말고도 **`.inactive` 다음에** 온다 —
    /// 제어센터, 알림 배너, 시스템 프롬프트. 그 바운스마다 비우면 죽은 URL 을
    /// 매번 다시 두드려 블랙리스트의 보호가 무력해진다.
    func testForegroundWithoutBackgroundDoesNothing() {
        var broadcasts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ImageRetryPolicy.failuresClearedNotification,
            object: nil, queue: .main) { _ in broadcasts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertFalse(ImageRetryPolicy.shared.onForeground())
        XCTAssertEqual(clearAllCount, 0)
        XCTAssertEqual(broadcasts, 0)
    }

    /// 표시는 복귀 **한 번**만 소비한다 — 이어지는 바운스는 다시 게이트에
    /// 걸려야 한다.
    func testBackgroundFlagIsConsumedOnce() {
        ImageRetryPolicy.shared.noteBackground()
        XCTAssertTrue(ImageRetryPolicy.shared.onForeground())
        XCTAssertFalse(ImageRetryPolicy.shared.onForeground())
        XCTAssertEqual(clearAllCount, 1)
    }

    /// 개별 재시도는 다른 슬롯까지 흔들지 않는다 — 누른 슬롯은 자기 상태를
    /// 스스로 푼다.
    func testPrepareRetryDoesNotBroadcast() {
        var broadcasts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ImageRetryPolicy.failuresClearedNotification,
            object: nil, queue: .main) { _ in broadcasts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        ImageRetryPolicy.shared.prepareRetry(for: URL(string: "https://cdn.example.com/a.jpg")!)
        XCTAssertEqual(broadcasts, 0)
    }
}

/// 배선 검증: `NetworkImage` 가 "실패 이력 비움" 방송을 **구독하고 있는지**.
/// Codex 리뷰 P2 가 지적한 결함이 정확히 "받는 쪽이 없어서 화면이 안 바뀐다"
/// 였고, 이 테스트가 그 회귀를 막는다.
///
/// 화면 상태(재시도 버튼 → 로딩)로 판정하지 않는 이유: SwiftUI 는 `Text` /
/// `Button` 을 호스팅 뷰의 레이어에 직접 그려 UIView 도 접근성 요소도 남기지
/// 않는다(계층 덤프로 확인 — `_UIHostingView` 아래가 비어 있다). 실패 상태를
/// 외부에서 관측할 방법이 이 하네스엔 없어, 수신 여부만 센다. 실패 → 복구의
/// 눈으로 보는 확인은 기기에서 한다.
@MainActor
final class NetworkImageFailureBroadcastTests: XCTestCase {

    func testMountedImageSubscribesToFailuresCleared() {
        let before = NetworkImage.failuresClearedReceiptsForTests

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let host = UIHostingController(rootView: NetworkImage(
            url: URL(string: "https://cdn.example.com/\(UUID().uuidString).jpg")!,
            aspectRatio: 1.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        ImageRetryPolicy.shared.noteBackground()
        ImageRetryPolicy.shared.onForeground()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertGreaterThan(
            NetworkImage.failuresClearedReceiptsForTests, before,
            "마운트된 이미지 슬롯이 실패 비움 방송을 받아야 한다 — 안 받으면 "
            + "블랙리스트만 비고 화면은 그대로 \"다시 시도\" 다")
    }

    /// 되살아나는 로드는 블랙리스트 검사를 건너뛴다. 이게 없으면, 백그라운드로
    /// 중단된 다운로드가 복귀 **뒤에** 실패 콜백을 전달하며 URL 을 다시
    /// 블랙리스트에 올려, 우리가 띄운 재로드가 곧바로 `BlackListed` 로 죽는다
    /// (Codex 리뷰 P2 2차). 평상시 로드는 보호막을 그대로 둔다.
    func testRevivedLoadBypassesBlacklistButNormalLoadDoesNot() {
        XCTAssertTrue(NetworkImage.loadOptions(forceRetry: true).contains(.retryFailed))
        XCTAssertFalse(NetworkImage.loadOptions(forceRetry: false).contains(.retryFailed))
    }
}
