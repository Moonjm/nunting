import XCTest
@testable import nunting

/// `PostDetailLoader.mediaLabel(for:site:)` — 파싱 직후 남기는 footprint
/// 샘플의 미디어 구성 태그 계약.
///
/// 배경: 2026-07-20 1.4GB 스파이크 조사가 스모킹건 직전에서 멈췄다 —
/// 스파이크 순간 label 이 `post-open` 뿐이라 **어떤 글이 어떤 미디어를
/// 담았는지** 못 붙였고, "Clien GIF 글이었을 것"까지만 추정했다. 파싱
/// 후 블록이 확정된 순간(`detail = parsed`)에 미디어 구성을 태그하면,
/// 같은 스파이크가 다시 나도 타임라인에서 "gif=3짜리 clien 글 열자마자
/// 급증"이 추정이 아니라 확증으로 읽힌다. gif/webp 는 프리페치가 전
/// 프레임을 실체화하는 애니메이션 포맷이라(#82·이번 스파이크의 진범)
/// `.image` 총계와 별도로 센다 — 이 수정(프리페치 차단)의 효과 검증
/// 지표이기도 하다.
final class PostDetailLoaderMediaLabelTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testLabelCountsEachMediaKind() {
        let blocks: [ContentBlock] = [
            .text("본문"),
            .image(url("https://cdn.clien.net/a.jpg")),
            .image(url("https://cdn.clien.net/b.png")),
            .image(url("https://cdn.clien.net/c.gif")),
            .video(url("https://cdn.clien.net/d.mp4")),
        ]
        let label = PostDetailLoader.mediaLabel(for: blocks, site: .clien, postID: "18234567")
        // 카테고리:사이트/카운트,id — 기존 label 어휘(board:모음/전체)와 같은 결.
        XCTAssertEqual(label, "media:clien/img=3,gif=1,webp=0,vid=1,id=18234567")
    }

    func testGifAndWebpAreCountedAsImageSubset() {
        // gif/webp 는 .image 블록이므로 img 총계에도 포함된다(부분집합).
        let blocks: [ContentBlock] = [
            .image(url("https://cdn.example.com/x.gif")),
            .image(url("https://cdn.example.com/y.webp")),
        ]
        let label = PostDetailLoader.mediaLabel(for: blocks, site: .clien, postID: "1")
        XCTAssertEqual(label, "media:clien/img=2,gif=1,webp=1,vid=0,id=1")
    }

    func testExtensionMatchIsCaseInsensitiveAndIgnoresQuery() {
        let blocks: [ContentBlock] = [
            .image(url("https://cdn.example.com/A.GIF")),
            .image(url("https://cdn.example.com/b.webp?type=w800")),
        ]
        let label = PostDetailLoader.mediaLabel(for: blocks, site: .ppomppu, postID: "42")
        XCTAssertEqual(label, "media:ppomppu/img=2,gif=1,webp=1,vid=0,id=42")
    }

    func testTextOnlyPostReportsAllZeros() {
        let blocks: [ContentBlock] = [.text("본문만"), .text("둘째 문단")]
        let label = PostDetailLoader.mediaLabel(for: blocks, site: .aagag, postID: "mirror-7")
        XCTAssertEqual(label, "media:aagag/img=0,gif=0,webp=0,vid=0,id=mirror-7")
    }

    /// 같은 사이트·같은 미디어 카운트라도 글 식별자로 구분돼야 한다 —
    /// 식별자가 없으면 스파이크를 "어느 글"로 귀속 못 한다(Codex P2).
    func testSameCountsDifferentPostsAreDistinguishedByID() {
        let blocks: [ContentBlock] = [.image(url("https://cdn.example.com/x.gif"))]
        let a = PostDetailLoader.mediaLabel(for: blocks, site: .clien, postID: "111")
        let b = PostDetailLoader.mediaLabel(for: blocks, site: .clien, postID: "222")
        XCTAssertNotEqual(a, b)
    }

    // 애객 미러 글은 원본 URL 을 통째로 담은 긴 id 를 쓴다
    // (`issue-…/issue/?idx=123456`). 서버가 label 을 80 runes 로 뒤에서
    // 자르므로(maxFootprintLabelRunes) id 가 맨 끝이면 구분용 idx 숫자가
    // 통째로 잘려나가 귀속이 무너진다 — 고엔트로피 tail 을 살려야 한다.
    private let longAagagID = "issue-https://aagag.com/issue/?idx=123456"

    /// label 은 서버 캡(80 runes) 안에 들어와, 서버 절단으로 id 가
    /// 잘려나가는 일이 없어야 한다 — 카운트가 3자리로 커져도.
    func testLabelStaysWithinServerRuneCap() {
        let blocks: [ContentBlock] = Array(
            repeating: .image(url("https://cdn.example.com/x.gif")), count: 250)
        let label = PostDetailLoader.mediaLabel(for: blocks, site: .coolenjoy, postID: longAagagID)
        XCTAssertLessThanOrEqual(label.count, 80, "서버가 뒤에서 자르기 전에 예산 안에 들어와야")
    }

    /// 긴 id 는 앞 보일러플레이트를 버리고 tail(고엔트로피)을 남긴다 —
    /// idx 숫자만 다른 두 애객 글이 label 상에서 구분돼야 한다.
    func testLongIDsAreDistinguishedByTail() {
        let blocks: [ContentBlock] = [.image(url("https://cdn.example.com/x.gif"))]
        let a = PostDetailLoader.mediaLabel(
            for: blocks, site: .aagag, postID: "issue-https://aagag.com/issue/?idx=123456")
        let b = PostDetailLoader.mediaLabel(
            for: blocks, site: .aagag, postID: "issue-https://aagag.com/issue/?idx=999999")
        XCTAssertNotEqual(a, b, "idx 만 다른 두 글이 tail 로 구분돼야")
        XCTAssertTrue(a.contains("123456"), "구분용 idx tail 이 살아있어야")
    }
}
