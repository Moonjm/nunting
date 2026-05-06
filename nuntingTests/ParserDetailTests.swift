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

    // MARK: - Aagag

    func testAagagMp4SeqPayloadRoutesToOwnMirrorNotGfycat() throws {
        // Real shape from aagag.com/issue/?idx=1065713 (and most pre-2024
        // GIF-as-video posts): the sTag JSON ships `mp4_url` pointing at
        // gfycat (`giant.gfycat.com/*.mp4` or `thumbs.gfycat.com/*-mobile.mp4`),
        // which has been dead since Snap shut gfycat down in Sep 2023. Aagag
        // mirrors the file at `i.aagag.com/{q}.mp4` and signals that mirror
        // by stamping `mp4_seq`. Without this routing the parser hands the
        // dead gfycat URL to AVPlayer, which sits on a connection forever
        // and the user sees a black slot that never plays.
        //
        // The fixture below escapes the JSON the same way the live page
        // does — the parser unescapes JS string escapes from
        // `AAGAG_AA.content = "..."` before splitting on `[sTag]` markers.
        let html = #"""
        <html><body>
        <h1 class="title">테스트</h1>
        <span class="t odate">2026-05-05 12:00</span>
        <script>
        AAGAG_AA.content = "<p>[sTag]{\"m\":\"img\",\"q\":\"KXuWQ\",\"mp4_seq\":\"303608818\",\"mp4_url\":\"https:\/\/giant.gfycat.com\/Dead.mp4\",\"mp4m_url\":\"https:\/\/thumbs.gfycat.com\/Dead-mobile.mp4\",\"url\":\"https:\/\/thumbs.gfycat.com\/Dead-size_restricted.gif\"}[/sTag]</p>";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post(
            id: "aagag-1065713",
            site: .aagag,
            boardID: "aagag-issue",
            title: "테스트",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://aagag.com/issue/?idx=1065713")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.compactMap { block -> URL? in
            if case .video(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(
            videos.first?.absoluteString,
            "https://i.aagag.com/KXuWQ.mp4",
            "mp4_seq present should route to aagag's own mirror, not the dead gfycat mp4_url"
        )
    }

    func testAagagPayloadWithoutMp4SeqStillFallsBackToMp4URL() throws {
        // Sanity counterpart — the mirror routing must not steal external
        // embeds where aagag never ingested the file. `m == "vid"` payloads
        // without `mp4_seq` (typically twitter / discord direct links) need
        // to keep using `mp4_url`; routing them to `i.aagag.com/{q}.mp4`
        // would 404 because aagag has no mirror to serve.
        let html = #"""
        <html><body>
        <h1 class="title">vid embed</h1>
        <script>
        AAGAG_AA.content = "[sTag]{\"m\":\"vid\",\"q\":\"externalQ\",\"mp4_url\":\"https:\/\/cdn.example.com\/clip.mp4\"}[/sTag]";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post(
            id: "aagag-vid",
            site: .aagag,
            boardID: "aagag-issue",
            title: "x",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://aagag.com/issue/?idx=0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.compactMap { block -> URL? in
            if case .video(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(
            videos.first?.absoluteString,
            "https://cdn.example.com/clip.mp4",
            "without mp4_seq, mp4_url remains the source of truth"
        )
    }

    // MARK: - Etoland

    func testEtolandDetailExtractsTitleMetaAndImageBody() throws {
        // Mirrors etoland.co.kr's Next.js SSR shape: <article> with the post
        // <h1> (icon + truncate-span title), a meta line carrying author /
        // <time> / 조회 / 추천 / 댓글, then div.view-content with inline
        // images that ship `data-src` (raw original) alongside the optimised
        // CDN `src`. Assertion targets: title strips the badge img, meta
        // numbers are pulled by Korean keyword (not position), the image
        // block resolves to the original (data-src), not the WebP-960 src.
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><img src="hit.svg" alt="인기"/><span class="truncate">에토 본문 제목</span></h1>
          <div>
            <div class="caption-s">
              <a href="/member/1"><span class="nickname">아라크드</span></a>
              <time>2026-05-06 20:22:24</time>
              <span>조회 2,580</span>
              <span>추천 19</span>
              <span>댓글 17</span>
            </div>
          </div>
          <div class="view-content">
            <p>본문 첫 줄</p>
            <p><img class="image-content" src="https://cdn.etoland.co.kr/optimize/w_920,format_webp/raw.jpg" data-src="https://cdn.etoland.co.kr/raw.jpg" /></p>
            <p>본문 마지막 줄</p>
          </div>
        </article>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post(
            id: "aagag-eto-1",
            site: .etoland,
            boardID: "aagag",
            title: "fallback",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-9022643")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.post.title, "에토 본문 제목", "h1 span.truncate, badge img stripped")
        XCTAssertEqual(detail.post.author, "아라크드")
        XCTAssertEqual(detail.fullDateText, "2026-05-06 20:22:24")
        XCTAssertEqual(detail.viewCount, 2580, "조회 N — comma stripped via filter(\\.isNumber)")
        XCTAssertEqual(detail.post.recommendCount, 19)
        XCTAssertEqual(detail.post.commentCount, 17)

        let images = detail.blocks.compactMap { block -> URL? in
            if case .image(let url, _) = block.kind { return url }
            return nil
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(
            images.first?.absoluteString,
            "https://cdn.etoland.co.kr/raw.jpg",
            "data-src (original) wins over the optimize/ WebP src"
        )
    }
}
