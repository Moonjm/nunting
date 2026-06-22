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

    func testPlainTextProducesSingleRichTextBlock() throws {
        let blocks = try walk("안녕 본문")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "안녕 본문")
    }

    func testBrAppendsNewlineInsideRichText() throws {
        let blocks = try walk("첫줄<br>둘째줄")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "첫줄\n둘째줄")
    }

    func testImageFlushesInlineAndAppendsImageBlock() throws {
        let blocks = try walk("앞 텍스트<img src='https://e.com/a.png'>뒷 텍스트")
        // 기대: richText("앞 텍스트") → image → richText("뒷 텍스트")
        XCTAssertEqual(blocks.count, 3)
        guard case .richText(let head) = blocks[0].kind,
              case .image(let url, _, _) = blocks[1].kind,
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

    func testImageBlockCarriesDeclaredAspectRatio() throws {
        // 인벤 본문 이미지 형식: style 에 aspect-ratio 선언. 워커가 이를
        // image 블록에 실어야 placeholder 높이 핀 + off-screen release 가 산다.
        let blocks = try walk("<img src='https://e.com/a.png' style='width: 800px; aspect-ratio: 1366 / 768; max-width: 100%;'>")
        XCTAssertEqual(blocks.count, 1)
        guard case .image(_, _, let aspect) = blocks[0].kind
        else { return XCTFail("image 블록 기대") }
        XCTAssertEqual(aspect ?? 0, 1366.0 / 768.0, accuracy: 0.001,
                       "워커가 선언된 aspect-ratio 를 image 블록에 실어야 함")
    }

    func testImageBlockAspectNilWhenNoDimensions() throws {
        // 크기 정보 없는 이미지는 aspect nil → NetworkImage fallback 이 처리.
        let blocks = try walk("<img src='https://e.com/a.png'>")
        XCTAssertEqual(blocks.count, 1)
        guard case .image(_, _, let aspect) = blocks[0].kind
        else { return XCTFail("image 블록 기대") }
        XCTAssertNil(aspect, "크기 정보 없으면 aspect nil")
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
        guard case .image(let url, _, _) = blocks[0].kind
        else { return XCTFail("이미지 블록 기대 (앵커 라벨 무시)") }
        XCTAssertEqual(url.absoluteString, "https://e.com/a.png")
    }

    func testShouldEmitAnchorFalseDropsLinkButKeepsTextFlow() throws {
        let blocks = try walk("앞<a href='https://e.com/skip'>무시</a>뒤") { rules in
            rules.shouldEmitAnchor = { url in url.absoluteString != "https://e.com/skip" }
        }
        // 기대: 앵커 누락, "앞" + "뒤" 만 텍스트로 흐름, .link segment 0
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "앞뒤")
        XCTAssertEqual(blocks.links.count, 0, ".link segment 가 누락되어야 함")
    }

    func testHiddenSubtreeProducesNoMediaBlocks() throws {
        let blocks = try walk("<div style='display:none'><img src='https://e.com/a.png'></div>본문")
        // 기대: hidden div 안 이미지 누락, "본문" 만 살아남음
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "본문")
    }

    func testScriptTagContentIsSkipped() throws {
        let blocks = try walk("앞<script>var x = 1;</script>뒤")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "앞뒤")
    }

    func testCustomImageBlockCanRouteToVideo() throws {
        // Simulate Ppomppu's "video bytes shipped inside <img>" quirk:
        // when the image URL ends in `.mov`, route to a `.video` block.
        let blocks = try walk("<img src='https://e.com/clip.mov'>") { rules in
            rules.imageBlock = { url, aspect in
                if url.pathExtension.lowercased() == "mov" {
                    return .video(url, posterURL: nil)
                }
                return .image(url, aspectRatio: aspect)
            }
        }
        XCTAssertEqual(blocks.count, 1)
        guard case .video(let url, _) = blocks[0].kind
        else { return XCTFail("video 블록 기대 (custom imageBlock)") }
        XCTAssertEqual(url.absoluteString, "https://e.com/clip.mov")
    }

    func testNilResolveImageURLDropsImageBlock() throws {
        let blocks = try walk("앞<img src='https://e.com/a.png'>뒤") { rules in
            rules.resolveImageURL = { _ in nil }
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "앞뒤")
    }

    func testBlockTagStampsNewlineBetweenSiblings() throws {
        let blocks = try walk("<p>첫 단락</p><p>둘째 단락</p>")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "첫 단락\n둘째 단락")
    }

    func testAnchorWrappingImageInsideContainerWithSiblingText() throws {
        // 가장 흔한 board 본문 모양: `<div>앞 <a><img></a> 뒤</div>`.
        // anchor-wraps-media 가지 + 앞뒤 형제 텍스트 흐름이 모두 깨지지
        // 않는지 핀.
        let blocks = try walk("<div>앞 <a href='https://e.com/x'><img src='https://e.com/a.png'></a> 뒤</div>")
        // 기대: richText("앞 ") → image → richText(" 뒤")
        XCTAssertEqual(blocks.count, 3, "richText / image / richText 순서 3 블록")
        guard blocks.count == 3 else { return }
        if case .richText(let head) = blocks[0].kind,
           case .text(let s0) = head.first {
            XCTAssertTrue(s0.contains("앞"), "첫 블록은 '앞' 포함 (image 직전 플러시)")
        } else {
            XCTFail("첫 블록은 richText('앞 ') 기대")
        }
        if case .image(let url, _, _) = blocks[1].kind {
            XCTAssertEqual(url.absoluteString, "https://e.com/a.png")
        } else {
            XCTFail("두 번째 블록은 image (anchor 라벨 무시)")
        }
        if case .richText(let tail) = blocks[2].kind,
           case .text(let s1) = tail.first {
            XCTAssertTrue(s1.contains("뒤"), "마지막 블록은 '뒤' 포함")
        } else {
            XCTFail("마지막 블록은 richText(' 뒤') 기대")
        }
    }

    func testStandardResolveVideoURLStripsMediaFragmentAndUsesDataSrc() throws {
        // standard(for:) 의 새 기본값 핀:
        // 1) `<video data-src=...>` 우선 (lazy-load), 2) `#t=…` strip.
        let blocks = try walk("<video data-src='https://e.com/v.mp4#t=0.05' src='https://e.com/poster.jpg'></video>")
        XCTAssertEqual(blocks.count, 1)
        guard case .video(let url, _) = blocks[0].kind
        else { return XCTFail("video 블록 기대") }
        XCTAssertEqual(url.absoluteString, "https://e.com/v.mp4", "data-src 우선 + #t= strip")
    }

    func testCustomElementHandlerClaimsElementAndEmitsBlocks() throws {
        // 사이트별 커스텀 wrapper 가 자식 텍스트(overlay 등)를 무시하고
        // 자기가 만든 블록만 emit 하는 경로.
        let blocks = try walk("앞<div class='custom-media'>overlay 텍스트</div>뒤") { rules in
            rules.customElement = { el in
                let cls = (try? el.attr("class")) ?? ""
                guard cls.split(whereSeparator: { $0.isWhitespace }).contains("custom-media") else {
                    return nil
                }
                return [.image(URL(string: "https://e.com/custom.png")!)]
            }
        }
        // 기대: richText("앞") → image (custom) → richText("뒤"). overlay 텍스트 누락.
        XCTAssertEqual(blocks.count, 3)
        guard blocks.count == 3 else { return }
        if case .richText(let head) = blocks[0].kind,
           case .text(let s) = head.first {
            XCTAssertTrue(s.contains("앞"))
        } else { XCTFail("첫 블록은 richText") }
        if case .image(let url, _, _) = blocks[1].kind {
            XCTAssertEqual(url.absoluteString, "https://e.com/custom.png")
        } else { XCTFail("두 번째 블록은 image (custom)") }
        if case .richText(let tail) = blocks[2].kind,
           case .text(let s) = tail.first {
            XCTAssertTrue(s.contains("뒤"))
        } else { XCTFail("마지막 블록은 richText") }
        // overlay 텍스트가 어디에도 안 새어야 함
        XCTAssertFalse(blocks.plainText.contains("overlay"), "custom 핸들러가 claim 한 자식 텍스트는 누락")
    }

    func testCustomElementHandlerReturningEmptyArrayDropsSubtree() throws {
        // 빈 배열 반환 = "이 element 와 자식들 통째로 drop" — 광고 슬롯 등.
        let blocks = try walk("앞<div class='ad'>광고</div>뒤") { rules in
            rules.customElement = { el in
                let cls = (try? el.attr("class")) ?? ""
                if cls.split(whereSeparator: { $0.isWhitespace }).contains("ad") {
                    return []
                }
                return nil
            }
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.plainText, "앞뒤")
    }

    func testCustomElementHandlerReturningNilFallsThroughToStandardDispatch() throws {
        // nil 반환 = "이 element 는 내 책임 아님" — 표준 dispatch 이어감.
        let blocks = try walk("<img src='https://e.com/a.png'>") { rules in
            rules.customElement = { _ in nil }
        }
        XCTAssertEqual(blocks.count, 1)
        guard case .image(let url, _, _) = blocks[0].kind
        else { return XCTFail("image 블록 (nil 반환 → 표준 dispatch)") }
        XCTAssertEqual(url.absoluteString, "https://e.com/a.png")
    }
}
