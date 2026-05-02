import XCTest
@testable import nunting

/// Fixture-based regression tests for parser `parseDetail` body
/// extraction. Same rationale as `ParserListTests` — pin the smallest
/// legal DOM against the parser's expected output so selector drift
/// fails loudly.
final class ParserDetailTests: XCTestCase {

    // MARK: - Clien

    func testClienGIFWrapperEmitsVideoBlockNotGIFText() throws {
        // Real shape from clien.net Froala-rendered GIFs: a
        // `<span class="fr-video">` wrapper around an inline-autoplay
        // `<video>` with the mp4 as a `<source>` and the gif as the
        // `poster` attribute. The trailing `<button>...GIF</button>` is
        // a desktop "download GIF" affordance — must not leak into
        // body prose.
        let html = """
        <html><body>
        <div class="post_article">
            <p>위 본문 텍스트</p>
            <p>
              <span class="fr-video fr-fvc fr-dvi fr-draggable" data-file-sn="15721736" data-role="image-mp4">
                <video id="3295777d52812" poster="https://edgio.clien.net/F01/2026/5/15721738/3295777d52812.gif?scale=width:480" autoplay loop="loop" playsinline muted preload="auto">
                  <source src="https://edgio.clien.net/F01/2026/5/15721736/3295777d52812.mp4" type="video/mp4">
                </video>
                <img src="https://edgio.clien.net/F01/2026/5/15721736/3295777d52812.mp4" style="display: none;">
                <button class="search_link" onclick="app.gifDownConfirm(...)"><i class="fa fa-download"></i>GIF</button>
              </span>
            </p>
            <p>아래 본문 텍스트</p>
        </div>
        <div class="post_date">2026-05-15 11:30</div>
        </body></html>
        """
        let parser = ClienParser()
        let post = Post(
            id: "clien-park-19184976",
            site: .clien,
            boardID: "clien-park",
            title: "테스트",
            author: "작성자",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://m.clien.net/service/board/park/19184976")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        // 1) 정확히 하나의 video 블록
        let videos = detail.blocks.compactMap { block -> (URL, URL?)? in
            if case .video(let url, let posterURL) = block.kind {
                return (url, posterURL)
            }
            return nil
        }
        XCTAssertEqual(videos.count, 1, "<video> 가 video 블록 1건으로 emit")
        if let (url, posterURL) = videos.first {
            XCTAssertEqual(url.absoluteString,
                           "https://edgio.clien.net/F01/2026/5/15721736/3295777d52812.mp4",
                           "<source src> 의 mp4 가 비디오 URL 로")
            XCTAssertEqual(posterURL?.absoluteString,
                           "https://edgio.clien.net/F01/2026/5/15721738/3295777d52812.gif?scale=width:480",
                           "<video poster> 의 gif 가 포스터로 (scale 쿼리 보존)")
        }

        // 2) 어떤 richText 블록도 'GIF' 라는 단독 텍스트를 포함하지 않아야 함
        let textPieces = detail.blocks.flatMap { block -> [String] in
            if case .richText(let segs) = block.kind {
                return segs.compactMap { seg -> String? in
                    if case .text(let s) = seg { return s }
                    return nil
                }
            }
            return []
        }
        for piece in textPieces {
            // 본문에는 "위 본문 텍스트" / "아래 본문 텍스트" 만 있어야 함.
            XCTAssertFalse(piece.contains("GIF"),
                           "<button>GIF</button> 의 'GIF' 텍스트가 본문에 누수: '\(piece)'")
        }

        // 3) 본문 위/아래 텍스트는 잘 살아있어야 함
        let combined = textPieces.joined()
        XCTAssertTrue(combined.contains("위 본문 텍스트"))
        XCTAssertTrue(combined.contains("아래 본문 텍스트"))
    }

    func testClienVideoWithoutPosterStillEmitsVideoBlock() throws {
        // <video> 가 poster 속성 없는 케이스 — InlineVideoPlayer 가
        // posterURL nil 도 정상 처리하므로 video 블록은 그대로 emit.
        let html = """
        <html><body>
        <div class="post_article">
            <p><video><source src="https://example.com/clip.mp4"></video></p>
        </div>
        </body></html>
        """
        let parser = ClienParser()
        let post = Post(
            id: "clien-test",
            site: .clien,
            boardID: "clien-news",
            title: "x",
            author: "y",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://m.clien.net/service/board/news/0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.compactMap { block -> URL? in
            if case .video(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.absoluteString, "https://example.com/clip.mp4")
    }

    // MARK: - Ppomppu

    func testPpomppuImgPointingAtMovEmitsVideoBlockNotImage() throws {
        // Real shape from m.ppomppu.co.kr/new/bbs_view.php?id=car&no=968820 —
        // user-uploaded `.mov` is shipped as `<img src="...mov">` and the
        // desktop-only JS shim that swaps it to `<video>` doesn't run on
        // mobile. Without this routing the parser emits an `.image` block,
        // `CachedAsyncImage` downloads the mov bytes, `CGImageSource`
        // returns nil, and the slot flips to "다시 시도".
        let html = """
        <html><body>
        <div class="bbs view">
            <div class="cont" id="KH_Content">
                <p>위 본문 텍스트</p>
                <p>
                  <img name="zb_target_resize"
                       src="//cdn2.ppomppu.co.kr/zboard/data3/2026/0502/foo.mov"
                       alt="IMG_6118.mov" />
                </p>
                <p>아래 본문 텍스트</p>
            </div>
        </div>
        </body></html>
        """
        let parser = PpomppuParser()
        let post = Post(
            id: "ppomppu-car-968820",
            site: .ppomppu,
            boardID: "ppomppu-car",
            title: "테스트",
            author: "작성자",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=car&no=968820")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.compactMap { block -> URL? in
            if case .video(let url, _) = block.kind { return url }
            return nil
        }
        let images = detail.blocks.compactMap { block -> URL? in
            if case .image(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(
            videos.first?.absoluteString,
            "https://cdn2.ppomppu.co.kr/zboard/data3/2026/0502/foo.mov"
        )
        XCTAssertTrue(images.isEmpty)
    }

    func testPpomppuImgPointingAtJpgStillEmitsImageBlock() throws {
        // Sanity counterpart — the video extension routing must not steal
        // ordinary still images. Same outer shape, just a `.jpg` src.
        let html = """
        <html><body>
        <div class="bbs view">
            <div class="cont" id="KH_Content">
                <p><img src="//cdn2.ppomppu.co.kr/zboard/data3/2026/0502/foo.jpg" /></p>
            </div>
        </div>
        </body></html>
        """
        let parser = PpomppuParser()
        let post = Post(
            id: "ppomppu-test",
            site: .ppomppu,
            boardID: "ppomppu-car",
            title: "x",
            author: "y",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=car&no=0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let images = detail.blocks.compactMap { block -> URL? in
            if case .image(let url, _) = block.kind { return url }
            return nil
        }
        let videos = detail.blocks.compactMap { block -> URL? in
            if case .video(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(
            images.first?.absoluteString,
            "https://cdn2.ppomppu.co.kr/zboard/data3/2026/0502/foo.jpg"
        )
        XCTAssertTrue(videos.isEmpty)
    }
}
