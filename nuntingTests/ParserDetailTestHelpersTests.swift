import CoreGraphics
import Foundation
import XCTest
@testable import nunting

/// Sanity tests for the test-target-only helpers in
/// `ParserDetailTestHelpers.swift`. If these break, every test that uses
/// the helpers becomes untrustworthy — keep the surface small and the
/// fixtures synthetic (no parser involvement).
final class ParserDetailTestHelpersTests: XCTestCase {

    // MARK: - Fixture builder

    private func blocks() -> [ContentBlock] {
        let videoURL = URL(string: "https://cdn.example.com/v.mp4")!
        let posterURL = URL(string: "https://cdn.example.com/v.jpg")!
        let img1 = URL(string: "https://cdn.example.com/a.png")!
        let img2 = URL(string: "https://cdn.example.com/b.png")!
        let link1 = URL(string: "https://example.com/link1")!
        let deal = URL(string: "https://shop.example.com/item")!
        return [
            .richText([
                .text("앞 본문"),
                .link(url: link1, label: "링크"),
                .text(" 뒤"),
            ]),
            .image(img1, aspectRatio: 1.5),
            .video(videoURL, posterURL: posterURL),
            .image(img2),
            .embed(.youtube, id: "abc123"),
            .dealLink(deal, label: "특가"),
            .richText([
                .text("두번째 블록"),
            ]),
        ]
    }

    // MARK: - ContentBlock extraction

    func testVideosExtractsURLAndPoster() {
        let v = blocks().videos
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].0.absoluteString, "https://cdn.example.com/v.mp4")
        XCTAssertEqual(v[0].1?.absoluteString, "https://cdn.example.com/v.jpg")
    }

    func testVideoURLsDropsPoster() {
        XCTAssertEqual(blocks().videoURLs.map(\.absoluteString),
                       ["https://cdn.example.com/v.mp4"])
    }

    func testImagesExtractsURLAndAspect() {
        let i = blocks().images
        XCTAssertEqual(i.count, 2)
        XCTAssertEqual(i[0].0.absoluteString, "https://cdn.example.com/a.png")
        XCTAssertEqual(i[0].1, 1.5)
        XCTAssertEqual(i[1].0.absoluteString, "https://cdn.example.com/b.png")
        XCTAssertNil(i[1].1, "aspectRatio default nil 보존")
    }

    func testImageURLsDropsAspect() {
        XCTAssertEqual(blocks().imageURLs.map(\.absoluteString),
                       ["https://cdn.example.com/a.png", "https://cdn.example.com/b.png"])
    }

    func testEmbedsExtractsProviderAndID() {
        let e = blocks().embeds
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].0, .youtube)
        XCTAssertEqual(e[0].1, "abc123")
    }

    func testDealLinksExtractsURLAndLabel() {
        let d = blocks().dealLinks
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].0.absoluteString, "https://shop.example.com/item")
        XCTAssertEqual(d[0].1, "특가")
    }

    func testRichTextSegmentsFlattensAcrossBlocks() {
        let segs = blocks().richTextSegments
        XCTAssertEqual(segs.count, 4, "block1 (3 segs) + block2 (1 seg)")
        if case .text(let s) = segs[0] { XCTAssertEqual(s, "앞 본문") } else { XCTFail() }
        if case .link(_, let l) = segs[1] { XCTAssertEqual(l, "링크") } else { XCTFail() }
        if case .text(let s) = segs[2] { XCTAssertEqual(s, " 뒤") } else { XCTFail() }
        if case .text(let s) = segs[3] { XCTAssertEqual(s, "두번째 블록") } else { XCTFail() }
    }

    func testPlainTextJoinsAcrossBlocksAndSkipsLinks() {
        XCTAssertEqual(blocks().plainText, "앞 본문 뒤두번째 블록",
                       "link 세그먼트 제외, 블록 사이 separator 없음")
    }

    func testBlockTextsGroupsByBlock() {
        XCTAssertEqual(blocks().blockTexts, ["앞 본문 뒤", "두번째 블록"],
                       "두 richText 블록 각각 별도 entry")
    }

    func testLinksExtractsAcrossBlocks() {
        let links = blocks().links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].0.absoluteString, "https://example.com/link1")
        XCTAssertEqual(links[0].1, "링크")
    }

    // MARK: - InlineSegment extraction

    func testInlineSegmentPlainTextDropsLinks() {
        let segs: [InlineSegment] = [
            .text("앞"),
            .link(url: URL(string: "https://x.com")!, label: "L"),
            .text(" 뒤"),
        ]
        XCTAssertEqual(segs.plainText, "앞 뒤")
        XCTAssertEqual(segs.textSegments, ["앞", " 뒤"])
        XCTAssertEqual(segs.links.count, 1)
        XCTAssertEqual(segs.links[0].1, "L")
    }

    // MARK: - Empty edge case

    func testAllExtractionsAreEmptyForEmptyArray() {
        let empty: [ContentBlock] = []
        XCTAssertTrue(empty.videos.isEmpty)
        XCTAssertTrue(empty.videoURLs.isEmpty)
        XCTAssertTrue(empty.images.isEmpty)
        XCTAssertTrue(empty.imageURLs.isEmpty)
        XCTAssertTrue(empty.embeds.isEmpty)
        XCTAssertTrue(empty.dealLinks.isEmpty)
        XCTAssertTrue(empty.richTextSegments.isEmpty)
        XCTAssertEqual(empty.plainText, "")
        XCTAssertTrue(empty.blockTexts.isEmpty)
        XCTAssertTrue(empty.links.isEmpty)
    }

    // MARK: - Post.fixture

    func testPostFixtureDefaultsAreValid() {
        let p = Post.fixture()
        XCTAssertEqual(p.id, "test-post-id")
        XCTAssertEqual(p.site, .clien)
        XCTAssertEqual(p.url.absoluteString, "https://example.com/test")
        XCTAssertEqual(p.commentCount, 0)
        XCTAssertFalse(p.hasAuthIcon)
    }

    func testPostFixtureOverrideOnlyChangedFields() {
        let url = URL(string: "https://m.clien.net/service/board/park/1")!
        let p = Post.fixture(site: .ppomppu, url: url)
        XCTAssertEqual(p.site, .ppomppu)
        XCTAssertEqual(p.url, url)
        XCTAssertEqual(p.id, "test-post-id", "다른 필드는 default 유지")
    }
}
