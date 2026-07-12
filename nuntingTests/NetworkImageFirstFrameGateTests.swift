import XCTest
@testable import nunting

/// `NetworkImage.skipsPrefetch` — 본문 이미지 프리페치 제외 판정의 진리표 계약.
///
/// 배경: `SDWebImagePrefetcher` 는 `animatedImageClass` 없이 디코드하므로
/// 애니메이션 WebP 의 전 프레임을 즉시 실체화한다 — 287프레임/13.6MB 실측
/// 9,032ms(시뮬레이터)가 `SDImageCache` 직렬 큐를 점유해 아래 이미지 전부가
/// blank 로 멈춘다(#82의 14s 프리즈 진범). 인라인 렌더는 `AnimatedImage`
/// 가 lazy `SDAnimatedImage`(같은 파일 27ms)로 열어 재생까지 안전하므로
/// 게이트하지 않는다 — 이 판정은 **프리페치 제외 전용**이다.
/// GIF 는 프리페치 프리즈 실측이 없어 종전대로 프리페치에 포함한다.
final class NetworkImagePrefetchSkipTests: XCTestCase {
    private func skips(_ urlString: String, poster: String? = nil) -> Bool {
        NetworkImage.skipsPrefetch(
            url: URL(string: urlString)!,
            posterURL: poster.map { URL(string: $0)! }
        )
    }

    func testPosterBackedImageSkipsPrefetch() {
        // 기존 humoruniv 경로 보존 — poster 가 있으면 확장자 무관 스킵.
        XCTAssertTrue(skips("https://cdn.example.com/heavy.jpg",
                            poster: "https://cdn.example.com/thumb.php?id=1"))
    }

    func testWebpSkipsPrefetchWithoutPoster() {
        // poster 없는 .webp(다른 보드의 대형 짤방)도 스킵 — 프리페처의
        // 전-프레임 실체화 경로에 태우지 않는다.
        XCTAssertTrue(skips("https://cdn.clien.net/image/xx.webp"))
    }

    func testWebpExtensionCaseInsensitive() {
        XCTAssertTrue(skips("https://cdn.example.com/IMG.WEBP"))
    }

    func testWebpWithQueryString() {
        // pathExtension 은 query 앞의 path 기준이어야 한다.
        XCTAssertTrue(skips("https://cdn.example.com/img.webp?type=w800"))
    }

    func testNonWebpPrefetches() {
        // GIF/정지 포맷은 종전대로 프리페치 대상.
        XCTAssertFalse(skips("https://cdn.example.com/small.gif"))
        XCTAssertFalse(skips("https://cdn.example.com/photo.jpg"))
        XCTAssertFalse(skips("https://cdn.example.com/photo.png"))
    }

    func testExtensionlessURLPrefetches() {
        // 확장자 없는 CDN 경로는 판별 불가 — 종전 동작 유지(best-effort).
        XCTAssertFalse(skips("https://cdn.example.com/attach/12345"))
    }
}
