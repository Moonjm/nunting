import XCTest
@testable import nunting

/// `NetworkImage.rendersFirstFrameOnly` — 인라인 first-frame-only 디코드
/// 게이트의 진리표 계약.
///
/// 배경: 대형 애니메이션 WebP(354프레임/15MB 급)를 `AnimatedImage` 로 열면
/// 전 프레임 직렬 디코드(~14s)가 `SDImageCache` 직렬 큐를 점유해 아래
/// 이미지 전부가 blank 로 멈춘다(#82). 종전 게이트는 `posterURL != nil`
/// (= HumorParser 전용)이라 다른 보드의 대형 WebP 는 그대로 프리즈 재발
/// (improvement-review §3.1). URL 확장자 `.webp` 로 일반화한다:
/// 정적 webp 는 first-frame-only 로 그려도 시각 결과가 동일하고(1프레임),
/// 애니메이션 webp 는 인라인 정지컷 + 탭 → 전체화면 재생으로 강등된다.
/// GIF 는 프리즈 실측이 없어 인라인 애니메이션을 유지한다.
final class NetworkImageFirstFrameGateTests: XCTestCase {
    private func gate(_ urlString: String, poster: String? = nil) -> Bool {
        NetworkImage.rendersFirstFrameOnly(
            url: URL(string: urlString)!,
            posterURL: poster.map { URL(string: $0)! }
        )
    }

    func testPosterBackedImageStaysGated() {
        // 기존 humoruniv 경로 보존 — poster 가 있으면 확장자 무관 first-frame.
        XCTAssertTrue(gate("https://cdn.example.com/heavy.jpg",
                           poster: "https://cdn.example.com/thumb.php?id=1"))
    }

    func testWebpGatedWithoutPoster() {
        // §3.1 핵심 — poster 없는 .webp(다른 보드의 대형 짤방)도 first-frame.
        XCTAssertTrue(gate("https://cdn.clien.net/image/xx.webp"))
    }

    func testWebpExtensionCaseInsensitive() {
        XCTAssertTrue(gate("https://cdn.example.com/IMG.WEBP"))
    }

    func testWebpWithQueryString() {
        // pathExtension 은 query 앞의 path 기준이어야 한다.
        XCTAssertTrue(gate("https://cdn.example.com/img.webp?type=w800"))
    }

    func testNonWebpStaysAnimated() {
        // GIF/정지 포맷은 종전대로 AnimatedImage 인라인 재생.
        XCTAssertFalse(gate("https://cdn.example.com/small.gif"))
        XCTAssertFalse(gate("https://cdn.example.com/photo.jpg"))
        XCTAssertFalse(gate("https://cdn.example.com/photo.png"))
    }

    func testExtensionlessURLStaysAnimated() {
        // 확장자 없는 CDN 경로는 판별 불가 — 종전 동작 유지(best-effort 게이트).
        XCTAssertFalse(gate("https://cdn.example.com/attach/12345"))
    }
}
