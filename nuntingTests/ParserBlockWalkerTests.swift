import XCTest
import SwiftSoup
@testable import nunting

final class ParserBlockWalkerTests: XCTestCase {

    /// Minimal `BoardParser` host the walker can delegate baseURL-aware
    /// helpers to. Uses `.ppomppu` arbitrarily — only `site.baseURL`
    /// matters for the helpers the walker calls.
    private struct StubParser: BoardParser {
        let site: Site = .ppomppu
        func parseList(html: String, board: Board) throws -> [Post] { [] }
        func parseDetail(html: String, post: Post) throws -> PostDetail {
            PostDetail(post: post, blocks: [], fullDateText: nil, viewCount: nil, source: nil, comments: [])
        }
    }

    private func walk(_ html: String, customize: (inout WalkerRules) -> Void = { _ in }) throws -> [ContentBlock] {
        let doc = try SwiftSoup.parse("<div id=root>\(html)</div>")
        let root = try doc.select("#root").first()!
        let parser = StubParser()
        var rules = WalkerRules.standard(for: parser)
        customize(&rules)
        return try ParserBlockWalker(parser: parser, rules: rules).walk(root)
    }

    private func texts(in blocks: [ContentBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            if case .richText(let segs) = block.kind {
                return segs.compactMap { seg in
                    if case .text(let s) = seg { return s }
                    return nil
                }
            }
            return []
        }
    }

    func testPlainTextProducesSingleRichTextBlock() throws {
        let blocks = try walk("안녕 본문")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(texts(in: blocks).joined(), "안녕 본문")
    }

    func testBrAppendsNewlineInsideRichText() throws {
        let blocks = try walk("첫줄<br>둘째줄")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(texts(in: blocks).joined(), "첫줄\n둘째줄")
    }

    func testImageFlushesInlineAndAppendsImageBlock() throws {
        let blocks = try walk("앞 텍스트<img src='https://e.com/a.png'>뒷 텍스트")
        // 기대: richText("앞 텍스트") → image → richText("뒷 텍스트")
        XCTAssertEqual(blocks.count, 3)
        guard case .richText(let head) = blocks[0].kind,
              case .image(let url, _) = blocks[1].kind,
              case .richText(let tail) = blocks[2].kind
        else { return XCTFail("순서: richText → image → richText 기대") }
        XCTAssertEqual(head.first.map { seg -> String in
            if case .text(let s) = seg { s } else { "" }
        }, "앞 텍스트")
        XCTAssertEqual(url.absoluteString, "https://e.com/a.png")
        XCTAssertEqual(tail.first.map { seg -> String in
            if case .text(let s) = seg { s } else { "" }
        }, "뒷 텍스트")
    }

    func testVideoPromotedToVideoBlock() throws {
        let blocks = try walk("<video src='https://e.com/v.mp4'></video>")
        XCTAssertEqual(blocks.count, 1)
        guard case .video(let url, _) = blocks[0].kind
        else { return XCTFail("video 블록 기대") }
        XCTAssertEqual(url.absoluteString, "https://e.com/v.mp4")
    }

    func testYouTubeIframePromotedToEmbedBlock() throws {
        let blocks = try walk("<iframe src='https://www.youtube.com/embed/abcdefghijk'></iframe>")
        XCTAssertEqual(blocks.count, 1)
        guard case .embed(provider: .youtube, id: let id) = blocks[0].kind
        else { return XCTFail("embed(.youtube) 블록 기대") }
        XCTAssertEqual(id, "abcdefghijk")
    }

    func testNonYouTubeIframeIsDropped() throws {
        let blocks = try walk("<iframe src='https://vimeo.com/123'></iframe>")
        XCTAssertEqual(blocks.count, 0)
    }

    func testPlainAnchorEmitsInlineLink() throws {
        let blocks = try walk("<a href='https://e.com/x'>라벨</a>")
        XCTAssertEqual(blocks.count, 1)
        guard case .richText(let segs) = blocks[0].kind, segs.count == 1,
              case .link(let url, let label) = segs[0]
        else { return XCTFail("단일 inline 링크 기대") }
        XCTAssertEqual(url.absoluteString, "https://e.com/x")
        XCTAssertEqual(label, "라벨")
    }

    func testAnchorWrappingImageEmitsImageNotLink() throws {
        let blocks = try walk("<a href='https://e.com/x'><img src='https://e.com/a.png'></a>")
        XCTAssertEqual(blocks.count, 1)
        guard case .image(let url, _) = blocks[0].kind
        else { return XCTFail("이미지 블록 기대 (앵커 라벨 무시)") }
        XCTAssertEqual(url.absoluteString, "https://e.com/a.png")
    }

    func testShouldEmitAnchorFalseDropsLinkButKeepsTextFlow() throws {
        let blocks = try walk("앞<a href='https://e.com/skip'>무시</a>뒤") { rules in
            rules.shouldEmitAnchor = { url in url.absoluteString != "https://e.com/skip" }
        }
        // 기대: 앵커 누락, "앞" + "뒤" 만 텍스트로 흐름, .link segment 0
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(texts(in: blocks).joined(), "앞뒤")
        let linkSegments = blocks.flatMap { block -> [InlineSegment] in
            if case .richText(let segs) = block.kind {
                return segs.filter { if case .link = $0 { true } else { false } }
            }
            return []
        }
        XCTAssertEqual(linkSegments.count, 0, ".link segment 가 누락되어야 함")
    }
}
