import XCTest
@testable import nunting

/// `NetworkImage.skipsPrefetch` — 본문 이미지 프리페치 제외 판정의 진리표 계약.
///
/// 제외는 poster-backed(웃대 직접첨부 짤방) 하나뿐이다 — 15MB 급이라
/// 다운로드 자체가 비싼데 blur-up 포스터가 대기 화면을 이미 채운다.
///
/// 한때 `.webp`/`.gif` 확장자도 전부 제외했다. 근거는 프리페처가
/// `animatedImageClass` 없이 디코드해 전 프레임을 즉시 실체화한다는 것
/// (287프레임/13.6MB 실측 9,032ms 가 `SDImageCache` 직렬 큐 점유 → #82 의
/// 14s 프리즈, Clien 본문 GIF footprint 1.4GB peak). 그건 컨텍스트를 안 채운
/// 탓이지 확장자 탓이 아니었고, `BodyImagePrefetcher.lazyAnimatedContext` 가
/// 워밍에도 인라인과 같은 lazy `SDAnimatedImage`(같은 파일 27ms)를 지정하며
/// 원천에서 사라졌다.
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

    func testAnimatedExtensionsPrefetchWithoutPoster() {
        // poster 없는 .webp/.gif 는 프리페치 대상 — 워밍이 lazy 디코드
        // 컨텍스트를 쓰므로 전-프레임 실체화가 일어나지 않는다.
        XCTAssertFalse(skips("https://cdn.clien.net/image/xx.webp"))
        XCTAssertFalse(skips("https://cdn.example.com/small.gif"))
        XCTAssertFalse(skips("https://cdn.example.com/IMG.WEBP"))
        XCTAssertFalse(skips("https://cdn.example.com/img.webp?type=w800"))
    }

    func testStaticFormatsPrefetch() {
        // 정지 포맷(jpg/png)은 프리페치 시 다운샘플 박스로 축소 디코드돼
        // 안전하므로 종전대로 프리페치 대상.
        XCTAssertFalse(skips("https://cdn.example.com/photo.jpg"))
        XCTAssertFalse(skips("https://cdn.example.com/photo.png"))
    }

    func testPosterBackedSkipIsIndependentOfExtension() {
        // 제외의 유일한 축이 poster 임을 못박는다 — 확장자는 무관.
        XCTAssertTrue(skips("https://cdn.example.com/heavy.webp",
                            poster: "https://cdn.example.com/thumb.php?id=1"))
        XCTAssertTrue(skips("https://cdn.example.com/heavy.gif",
                            poster: "https://cdn.example.com/thumb.php?id=2"))
    }

    func testExtensionlessURLPrefetches() {
        // 확장자 없는 CDN 경로는 판별 불가 — 종전 동작 유지(best-effort).
        XCTAssertFalse(skips("https://cdn.example.com/attach/12345"))
    }
}
