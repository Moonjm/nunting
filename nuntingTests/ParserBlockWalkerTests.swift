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
}
