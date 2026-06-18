import XCTest
@testable import nunting

/// `NetworkImage` 표시 게이트(`shouldShowHeavyImage`)의 진리표 계약.
///
/// 이 게이트가 메모리-안전 불변식의 핵심이라 4-corner 를 핀한다:
///  - 로드 게이트: gated 이미지는 뷰포트 진입(`hasBeenVisible`) 전엔 안 뜬다.
///  - 디코드 게이트: `releasesWhenOffscreen` 이미지는 off-screen 에서 비트맵을
///    폐기(placeholder)해 긴 글의 라이브 디코드를 ~뷰포트분으로 상한.
final class NetworkImageVisibilityTests: XCTestCase {
    private func shows(
        gated: Bool, visible: Bool, releases: Bool, onscreen: Bool, appActive: Bool = true
    ) -> Bool {
        NetworkImage.shouldShowHeavyImage(
            visibilityGated: gated,
            hasBeenVisible: visible,
            releasesWhenOffscreen: releases,
            isOnscreen: onscreen,
            appActive: appActive
        )
    }

    // MARK: 로드 게이트 (releasesWhenOffscreen 무관)

    func testGatedImageHiddenUntilVisible() {
        // 가장 중요한 불변식: gated + 미진입 이미지는 isOnscreen 기본값(true)
        // 이어도 절대 안 뜬다 — off-screen gated 누출 방지.
        XCTAssertFalse(shows(gated: true, visible: false, releases: false, onscreen: true))
        XCTAssertFalse(shows(gated: true, visible: false, releases: true, onscreen: true))
    }

    func testGatedImageShownOnceVisible() {
        XCTAssertTrue(shows(gated: true, visible: true, releases: false, onscreen: true))
    }

    func testEagerImageShownImmediately() {
        // non-gated(image-0/아이콘/스티커): hasBeenVisible 무관하게 로드 가능.
        XCTAssertTrue(shows(gated: false, visible: false, releases: false, onscreen: true))
    }

    // MARK: 디코드 게이트 (releasesWhenOffscreen == true)

    func testReleasesWhenOffscreenDropsDecodeOffscreen() {
        // 로드는 됐지만(visible) 화면 밖(!onscreen) → 폐기(placeholder).
        XCTAssertFalse(shows(gated: true, visible: true, releases: true, onscreen: false))
        XCTAssertFalse(shows(gated: false, visible: false, releases: true, onscreen: false))
    }

    func testReleasesWhenOffscreenRestoresOnReturn() {
        XCTAssertTrue(shows(gated: true, visible: true, releases: true, onscreen: true))
    }

    // MARK: 비-release 호출부(아이콘/스티커/포스터) 회귀 방지

    func testNonReleasingCallerIgnoresOnscreenFlag() {
        // releases=false 면 isOnscreen 은 결과에 영향 없음 — 기존 동작 보존.
        XCTAssertEqual(
            shows(gated: false, visible: true, releases: false, onscreen: true),
            shows(gated: false, visible: true, releases: false, onscreen: false),
            "release 미사용 호출부는 off-screen 플래그와 무관해야 함"
        )
    }

    // MARK: 백그라운드 teardown (appActive == false, phase-3)

    func testBackgroundDropsResidentDecode() {
        // 화면에 떠 있던(on-screen) release 이미지도 백그라운드(appActive=false)면
        // 디코드 폐기 — suspend 중 keep-alive 본문 비트맵을 떨군다.
        XCTAssertFalse(shows(gated: true, visible: true, releases: true, onscreen: true, appActive: false))
        XCTAssertFalse(shows(gated: false, visible: false, releases: true, onscreen: true, appActive: false))
    }

    func testForegroundRestoresVisibleDecode() {
        // 복귀(appActive=true) 시 보이던(onscreen) 것은 다시 뜨고, 안 보이던 건 계속 폐기.
        XCTAssertTrue(shows(gated: true, visible: true, releases: true, onscreen: true, appActive: true))
        XCTAssertFalse(shows(gated: true, visible: true, releases: true, onscreen: false, appActive: true))
    }

    func testBackgroundDoesNotAffectNonReleasingImages() {
        // appActive 는 release 이미지에만 작용 — 일반 이미지(아이콘/본문-0 등)는
        // 백그라운드여도 게이트에 영향 없음(불필요한 리로드 방지).
        XCTAssertTrue(shows(gated: false, visible: true, releases: false, onscreen: true, appActive: false))
        XCTAssertTrue(shows(gated: true, visible: true, releases: false, onscreen: true, appActive: false))
    }
}
