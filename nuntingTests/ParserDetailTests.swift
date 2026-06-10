import XCTest
import SwiftSoup
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
        let post = Post.fixture(
            id: "clien-park-19184976",
            site: .clien,
            boardID: "clien-park",
            url: URL(string: "https://m.clien.net/service/board/park/19184976")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        // 1) 정확히 하나의 video 블록
        let videos = detail.blocks.videos
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
        let textPieces = detail.blocks.richTextSegments.textSegments
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
        let post = Post.fixture(
            id: "clien-test",
            site: .clien,
            boardID: "clien-news",
            url: URL(string: "https://m.clien.net/service/board/news/0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.absoluteString, "https://example.com/clip.mp4")
    }

    func testClienImageSrcsetFallbackPreservesAspectRatio() throws {
        let html = """
        <html><body>
        <div class="post_article">
            <p>
              <img src="https://www.carscoops.com/2026/04/not-image-page/"
                   srcset="https://cdn.example.com/photo-640.jpg 640w, https://cdn.example.com/photo-1024.jpg 1024w, https://cdn.example.com/photo-1600.jpg 1600w"
                   data-img-width="1600"
                   data-img-height="900">
            </p>
        </div>
        <div class="post_date">2026-05-15 11:30</div>
        </body></html>
        """
        let parser = ClienParser()
        let post = Post.fixture(
            id: "clien-image-srcset",
            site: .clien,
            boardID: "clien-news",
            url: URL(string: "https://m.clien.net/service/board/news/1")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let images = detail.blocks.images

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.0.absoluteString, "https://cdn.example.com/photo-1024.jpg")
        XCTAssertNotNil(images.first?.1)
        XCTAssertEqual(images.first?.1 ?? 0, CGFloat(1600.0 / 900.0), accuracy: CGFloat(0.0001))
    }

    func testClienWalkerCompositionPreservesSourceMediaEmbedAndBlankLines() throws {
        let html = """
        <html><body>
        <div class="post_article">
            <p><a href="https://example.com/original">원문</a> | Example Source</p>
            <p>위 문단</p>
            <p><br></p>
            <p>중간 문단</p>
            <p><a href="https://example.com/open"><img src="https://cdn.example.com/inside.jpg"></a></p>
            <p><iframe src="https://www.youtube.com/embed/abcDEF12345"></iframe></p>
            <p>아래 문단</p>
        </div>
        <div class="post_date">2026-05-15 11:30</div>
        </body></html>
        """
        let parser = ClienParser()
        let post = Post.fixture(
            id: "clien-composition",
            site: .clien,
            boardID: "clien-news",
            url: URL(string: "https://m.clien.net/service/board/news/2")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        XCTAssertEqual(detail.source?.name, "Example Source")
        XCTAssertEqual(detail.source?.url.absoluteString, "https://example.com/original")
        XCTAssertFalse(detail.blocks.plainText.contains("Example Source"), "source paragraph should be removed from body")

        XCTAssertEqual(detail.blocks.count, 4)
        guard case .richText(let head) = detail.blocks[0].kind,
              case .image(let imageURL, _, _) = detail.blocks[1].kind,
              case .embed(.youtube, let id) = detail.blocks[2].kind,
              case .richText(let tail) = detail.blocks[3].kind
        else { return XCTFail("expected text -> image -> youtube embed -> text block order") }

        XCTAssertEqual(imageURL.absoluteString, "https://cdn.example.com/inside.jpg")
        XCTAssertEqual(id, "abcDEF12345")
        XCTAssertEqual(head.plainText, "위 문단\n\n\n중간 문단")
        XCTAssertEqual(tail.plainText, "아래 문단")
    }

    // MARK: - Ppomppu

    func testPpomppuImgPointingAtMovEmitsVideoBlockNotImage() throws {
        // Real shape from m.ppomppu.co.kr/new/bbs_view.php?id=car&no=968820 —
        // user-uploaded `.mov` is shipped as `<img src="...mov">` and the
        // desktop-only JS shim that swaps it to `<video>` doesn't run on
        // mobile. Without this routing the parser emits an `.image` block,
        // SDWebImage downloads the mov bytes, the decoder rejects them,
        // and the slot flips to "다시 시도".
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
        let post = Post.fixture(
            id: "ppomppu-car-968820",
            site: .ppomppu,
            boardID: "ppomppu-car",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=car&no=968820")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.videoURLs
        let images = detail.blocks.imageURLs
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
        let post = Post.fixture(
            id: "ppomppu-test",
            site: .ppomppu,
            boardID: "ppomppu-car",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=car&no=0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let images = detail.blocks.imageURLs
        let videos = detail.blocks.videoURLs
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
        let post = Post.fixture(
            id: "aagag-1065713",
            site: .aagag,
            boardID: "aagag-issue",
            url: URL(string: "https://aagag.com/issue/?idx=1065713")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.videoURLs
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
        let post = Post.fixture(
            id: "aagag-vid",
            site: .aagag,
            boardID: "aagag-issue",
            url: URL(string: "https://aagag.com/issue/?idx=0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(
            videos.first?.absoluteString,
            "https://cdn.example.com/clip.mp4",
            "without mp4_seq, mp4_url remains the source of truth"
        )
    }

    func testAagagStillImageWithoutOptimizedVariantUsesBucketRootNotOFolder() throws {
        // Real shape from aagag.com/issue/?idx=1633288: a still `m == "img"`
        // payload carries an `o` map describing the byte size of each
        // available encoding (ori / webp / jpg). aagag's own renderer
        // (AAGAG_AA.js) only points at the `/o/{q}.{type}` optimized folder
        // when a *smaller* webp/jpg variant exists; when the original is
        // already the smallest it serves the bucket root `i.aagag.com/{q}.jpg`.
        // The previous parser hard-coded `/o/{q}.jpg`, which 520s for these
        // posts and surfaced as the endless "다시 시도" placeholder while the
        // mp4-backed (animated) block above it played fine.
        //
        // Here ori (25108) ties jpg and beats webp only if webp were larger —
        // but webp (15354) is smaller, so the renderer picks `/o/{q}.webp`.
        let html = #"""
        <html><body>
        <h1 class="title">still image</h1>
        <script>
        AAGAG_AA.content = "<p>[sTag]{\"m\":\"img\",\"q\":\"KeW2Q\",\"width\":421,\"height\":586,\"byte\":25108,\"o\":{\"ori\":{\"byte\":25108},\"webp\":{\"byte\":15354},\"jpg\":{\"byte\":25108}},\"max_size\":25108}[/sTag]</p>";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post.fixture(
            id: "aagag-1633288",
            site: .aagag,
            boardID: "aagag-issue",
            url: URL(string: "https://aagag.com/issue/?idx=1633288")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://i.aagag.com/o/KeW2Q.webp"],
            "smaller webp variant present → /o/{q}.webp, matching aagag's renderer"
        )
    }

    func testAagagStillImageWhereOriginalIsSmallestServesBucketRootJpg() throws {
        // `o` present but the original is the smallest encoding (no webp, jpg
        // == ori): aagag's renderer leaves `/o/` untouched and serves the
        // bucket root. Hard-coding `/o/{q}.jpg` would 520 here.
        let html = #"""
        <html><body>
        <h1 class="title">smallest original</h1>
        <script>
        AAGAG_AA.content = "[sTag]{\"m\":\"img\",\"q\":\"OnlyOri\",\"byte\":900,\"o\":{\"ori\":{\"byte\":900},\"jpg\":{\"byte\":900}}}[/sTag]";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post.fixture(site: .aagag, url: URL(string: "https://aagag.com/issue/?idx=1")!)

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://i.aagag.com/OnlyOri.jpg"],
            "original is smallest → bucket root, no /o/ prefix"
        )
    }

    func testAagagStillImageWithoutOptimizationMapUsesBucketRootJpg() throws {
        // Legacy payloads ship no `o` map at all and no explicit `url`. The
        // renderer's final fallback is the bucket root `i.aagag.com/{q}.jpg`,
        // never the `/o/` folder.
        let html = #"""
        <html><body>
        <h1 class="title">no o map</h1>
        <script>
        AAGAG_AA.content = "[sTag]{\"m\":\"img\",\"q\":\"BareImg\"}[/sTag]";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post.fixture(site: .aagag, url: URL(string: "https://aagag.com/issue/?idx=2")!)

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://i.aagag.com/BareImg.jpg"],
            "no optimization map → bucket root jpg fallback"
        )
    }

    func testAagagStillImagePicksOptimizedJpgWhenWebpIsLarger() throws {
        // webp present but *larger* than the original (poor webp encoding of an
        // already-compressed source) while the optimized jpg is smaller: the
        // renderer rejects webp and serves `/o/{q}.jpg`. Locks the jpg-wins
        // branch that the webp-smaller cases never exercise.
        let html = #"""
        <html><body>
        <h1 class="title">jpg wins</h1>
        <script>
        AAGAG_AA.content = "[sTag]{\"m\":\"img\",\"q\":\"JpgWin\",\"byte\":5000,\"o\":{\"ori\":{\"byte\":5000},\"webp\":{\"byte\":6000},\"jpg\":{\"byte\":4000}}}[/sTag]";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post.fixture(site: .aagag, url: URL(string: "https://aagag.com/issue/?idx=3")!)

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://i.aagag.com/o/JpgWin.jpg"],
            "webp larger than original is rejected; smaller jpg → /o/{q}.jpg"
        )
    }

    func testAagagStillImageWithExplicitURLAndAllOriginalMapFallsThroughToURL() throws {
        // An explicit `url` (external-hosted image) alongside an `o` map whose
        // original is smallest: aagag's renderer evaluates optimized → url →
        // bucket root sequentially, so the all-original `o` map falls through
        // to `url`. Mirrors that fall-through rather than short-circuiting to
        // the bucket root.
        let html = #"""
        <html><body>
        <h1 class="title">external url</h1>
        <script>
        AAGAG_AA.content = "[sTag]{\"m\":\"img\",\"q\":\"ExtImg\",\"byte\":700,\"url\":\"https:\/\/cdn.example.com\/pic.png\",\"o\":{\"ori\":{\"byte\":700},\"jpg\":{\"byte\":700}}}[/sTag]";
        </script>
        </body></html>
        """#
        let parser = AagagParser()
        let post = Post.fixture(site: .aagag, url: URL(string: "https://aagag.com/issue/?idx=4")!)

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://cdn.example.com/pic.png"],
            "all-original o map falls through to explicit url, matching renderer order"
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
        let post = Post.fixture(
            id: "aagag-eto-1",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-9022643")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.post.title, "에토 본문 제목", "h1 span.truncate, badge img stripped")
        XCTAssertEqual(detail.post.author, "아라크드")
        XCTAssertEqual(detail.fullDateText, "2026-05-06 20:22:24")
        XCTAssertEqual(detail.viewCount, 2580, "조회 N — comma stripped via filter(\\.isNumber)")
        XCTAssertEqual(detail.post.recommendCount, 19)
        XCTAssertEqual(detail.post.commentCount, 17)

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(
            images.first?.absoluteString,
            "https://cdn.etoland.co.kr/raw.jpg",
            "data-src (original) wins over the optimize/ WebP src"
        )
    }

    func testEtolandDetailSuppressesCustomVideoPlayerOverlayText() throws {
        // Etoland wraps `<video>` in a React custom player; sibling overlays
        // (`Play video` button label, time readout `0:00/0:00`, speed `1x`)
        // are visible only via CSS positioning. SwiftSoup's text walker
        // treats them as prose and leaks them into the rendered body.
        // Detect the `board-video-player` wrapper class and extract only
        // the inner `<video>`.
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-06 20:22</time></div></div>
          <div class="view-content">
            <p>본문 위</p>
            <div class="some-utility board-video-player" style="width:450px">
              <div class="relative">
                <video src="https://btcdn.etoland.co.kr/clip.mp4" muted="" loop="">
                  <source src="https://btcdn.etoland.co.kr/clip.mp4" />
                </video>
                <button aria-label="Play video">Play video</button>
                <div class="peer/controls">0:00 / 0:00 1x</div>
              </div>
            </div>
            <p>본문 아래</p>
          </div>
        </article>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-v",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.absoluteString, "https://btcdn.etoland.co.kr/clip.mp4")

        let prose = detail.blocks.blockTexts.joined(separator: "\n")
        XCTAssertFalse(prose.contains("0:00"), "time readout from custom-player overlay leaked into body text")
        XCTAssertFalse(prose.contains("1x"), "speed selector label from overlay leaked into body text")
        XCTAssertFalse(prose.contains("Play video"), "play button label leaked into body text")
        XCTAssertTrue(prose.contains("본문 위"))
        XCTAssertTrue(prose.contains("본문 아래"))
    }

    func testEtolandDetailExtractsLazyLoadedVideoFromDataSrc() throws {
        // Real etoland markup ships `<video>` with `data-src=` only — `src=`
        // is empty until the user taps play. A previous version of the
        // parser checked `src` first and bailed when it was missing,
        // dropping the video block entirely. Mirror the production shape
        // (no `src`, no `<source>` children, only `data-src`) and assert
        // we still surface the mp4.
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-07 13:51</time></div></div>
          <div class="view-content">
            <div class="board-video-player">
              <div class="relative">
                <video data-src="https://btcdn.etoland.co.kr/static/media/etohumor07/2026/0507/optimized/abc.mp4#t=0.05" muted="" loop="" playsInline="" preload="none"></video>
              </div>
            </div>
          </div>
        </article>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-v2",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(
            videos.first?.absoluteString,
            "https://btcdn.etoland.co.kr/static/media/etohumor07/2026/0507/optimized/abc.mp4"
        )
    }

    func testEtolandDetailDropsCustomVideoPlayerOverlayWhenVideoURLMissing() throws {
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-07 13:51</time></div></div>
          <div class="view-content">
            <p>본문 위</p>
            <div class="board-video-player">
              <video muted="" loop=""></video>
              <button aria-label="Play video">Play video</button>
              <div class="peer/controls">0:00 / 0:00 1x</div>
            </div>
            <p>본문 아래</p>
          </div>
        </article>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-v-missing",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let prose = detail.blocks.blockTexts.joined(separator: "\n")

        XCTAssertFalse(prose.contains("0:00"), "time readout from custom-player overlay leaked into body text")
        XCTAssertFalse(prose.contains("1x"), "speed selector label from overlay leaked into body text")
        XCTAssertFalse(prose.contains("Play video"), "play button label leaked into body text")
        XCTAssertTrue(prose.contains("본문 위"))
        XCTAssertTrue(prose.contains("본문 아래"))
        XCTAssertTrue(detail.blocks.compactMap { if case .video(let url, _) = $0.kind { return url } else { return nil } }.isEmpty)
    }

    func testEtolandDetailExtractsUnwrappedVideoFromLaterSource() throws {
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-07 13:51</time></div></div>
          <div class="view-content">
            <video>
              <source src="javascript:void(0)" />
              <source src="https://btcdn.etoland.co.kr/fallback.mp4#t=0.05" />
            </video>
          </div>
        </article>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-v-source",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.absoluteString, "https://btcdn.etoland.co.kr/fallback.mp4")
    }

    func testEtolandCommentsURLDerivedFromPostPath() throws {
        // Public API: /api/v1/board/{boTable}/article/slug/{slug}/comments
        // boTable + slug pulled from the post URL's `/b/{boTable}/view/{slug}`
        // segments. Slug stays URL-encoded — etoland's API wants it that way.
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-9022769")!
        )
        let url = parser.commentsURL(for: post)
        XCTAssertEqual(url?.host, "etoland.co.kr")
        XCTAssertEqual(url?.path, "/api/v1/board/etohumor07/article/slug/-9022769/comments")
        let items = (URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(items["comment_page"], "0")
        XCTAssertEqual(items["comm_page_size"], "50")

        // Non-etoland URL must return nil so the loader doesn't try to
        // reach the etoland API for an aagag-mirror redirect target that
        // wasn't actually etoland.
        let other = Post(
            id: "y",
            site: .etoland,
            boardID: "aagag",
            title: "t",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://example.com/b/x/view/y")!
        )
        XCTAssertNil(parser.commentsURL(for: other))
    }

    func testEtolandFetchAllCommentsSkipsAPIWhenSSRHasInline() async throws {
        // Inline SSR comments path — `fetchAllComments` must return []
        // so the loader keeps `parsed.comments` (already filled by
        // parseDetail) instead of overriding with a parallel API call.
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        // Marker matches the wire envelope `"data":{"comments":[…]}`,
        // not the bare `"comments":[` substring (which would false-positive
        // on any user comment whose body literally contains that string).
        let inlineHTML = #"<script>self.__next_f.push([1,"...\"data\":{\"comments\":[{}]}..."])</script>"#

        var fetched = false
        let comments = try await parser.fetchAllComments(
            for: post,
            detailHTML: inlineHTML
        ) { _ in
            fetched = true
            return ""
        }
        XCTAssertTrue(comments.isEmpty)
        XCTAssertFalse(fetched, "inline path must short-circuit before the network round-trip")
    }

    func testEtolandFetchAllCommentsParsesAPIResponseWhenSSRBailedOut() async throws {
        // Bailout SSR path — detailHTML lacks `"comments":[`, so
        // `fetchAllComments` must hit the API URL and decode the JSON.
        // Fixture mirrors etoland's actual API envelope shape.
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-9022769")!
        )
        let bailoutHTML = "<html><template data-dgst=\"BAILOUT_TO_CLIENT_SIDE_RENDERING\"></template></html>"
        let apiBody = """
        {"status":"ETOCD200000","data":{"comments":[{"commentId":1,"parentId":null,"writeDateTimestamp":1,"recommendCount":2,"content":"테스트","isAnonymous":false,"member":{"nickname":"a","image":null},"file":null,"childrenComments":[]}]}}
        """

        var hitURL: URL?
        let comments = try await parser.fetchAllComments(
            for: post,
            detailHTML: bailoutHTML
        ) { url in
            hitURL = url
            return apiBody
        }
        XCTAssertEqual(
            hitURL?.path,
            "/api/v1/board/etohumor07/article/slug/-9022769/comments",
            "bailout path must call the public comments API"
        )
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].content, "테스트")
        XCTAssertEqual(comments[0].likeCount, 2)
    }

    func testEtolandCommentsPreserveEmojiViaSurrogatePairs() throws {
        // JS-string-encoded JSON inside __next_f.push escapes supplementary-
        // plane characters (emoji like 🐶 = U+1F436) as a UTF-16 surrogate
        // pair: `🐶`. A naive `\u` decoder that only handles
        // 4-hex Basic-Multilingual-Plane escapes silently drops both halves
        // because `UnicodeScalar(0xD83D)` is nil for surrogate code points.
        // Pin the pair-aware decoder so emoji-laden Korean comments survive.
        // 가족 ❤️ = `가족 ❤️` (BMP, single \u each)
        // 🐶 = `🐶` (surrogate pair)
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-06 20:22</time></div></div>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"commentId\\":1,\\"parentId\\":null,\\"writeDateTimestamp\\":1,\\"recommendCount\\":0,\\"content\\":\\"\\\\uAC00\\\\uC871 \\\\u2764\\\\uFE0F \\\\uD83D\\\\uDC36\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"u\\"},\\"file\\":null,\\"childrenComments\\":[]}]}}]"])</script>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments[0].content, "가족 ❤\u{FE0F} 🐶")
    }

    func testEtolandEmojiStampSurfacesAsSticker() throws {
        // Etocon (etoland's own sticker pack) comments ship with an empty
        // `content` and an `emojiItem.path` pointing at the GIF. Without
        // this branch the bubble would render as blank text. Real-world
        // shape from post 9022801's second comment.
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-06 20:22</time></div></div>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"commentId\\":99,\\"parentId\\":null,\\"writeDateTimestamp\\":1,\\"recommendCount\\":0,\\"content\\":\\"\\",\\"emojiId\\":570,\\"emojiItem\\":{\\"id\\":570,\\"etoconId\\":23,\\"path\\":\\"https://btcdn.etoland.co.kr/static/media/images/etocon/23/22.gif\\",\\"order\\":22},\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"u\\"},\\"file\\":null,\\"childrenComments\\":[]}]}}]"])</script>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments[0].content, "")
        XCTAssertEqual(
            detail.comments[0].stickerURL?.absoluteString,
            "https://btcdn.etoland.co.kr/static/media/images/etocon/23/22.gif",
            "emoji-only comment should surface emojiItem.path as stickerURL"
        )
    }

    func testEtolandCommentsSurfaceImageAndVideoAttachments() throws {
        // Three comments with attachments + one plain text:
        // 1) `file: { bfType: "image", bfFile: "/media/.../x.jpg" }` → stickerURL
        // 2) `file: { bfType: "video", bfMp4File: "/media/.../y.mp4" }` → videoURL
        // 3) content is just an image URL (user pasted) → stickerURL + content cleared
        // 4) plain text comment, no attachment
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">x</span><time>2026-05-06 20:22</time></div></div>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"commentId\\":1,\\"parentId\\":null,\\"writeDateTimestamp\\":1,\\"recommendCount\\":0,\\"content\\":\\"이미지 첨부\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"a\\"},\\"file\\":{\\"bfFile\\":\\"/media/etohumor07/test/img.jpg\\",\\"bfType\\":\\"image\\",\\"bfMp4File\\":null},\\"childrenComments\\":[]},{\\"commentId\\":2,\\"parentId\\":null,\\"writeDateTimestamp\\":2,\\"recommendCount\\":0,\\"content\\":\\"비디오 첨부\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"b\\"},\\"file\\":{\\"bfFile\\":\\"/media/etohumor07/test/orig.mov\\",\\"bfType\\":\\"video\\",\\"bfMp4File\\":\\"/media/etohumor07/test/clip.mp4\\"},\\"childrenComments\\":[]},{\\"commentId\\":3,\\"parentId\\":null,\\"writeDateTimestamp\\":3,\\"recommendCount\\":0,\\"content\\":\\"https://btcdn.etoland.co.kr/static/media/etc/meme.jpg\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"c\\"},\\"file\\":null,\\"childrenComments\\":[]},{\\"commentId\\":4,\\"parentId\\":null,\\"writeDateTimestamp\\":4,\\"recommendCount\\":0,\\"content\\":\\"그냥 텍스트\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"d\\"},\\"file\\":null,\\"childrenComments\\":[]}]}}]"])</script>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-img",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 4)

        XCTAssertEqual(
            detail.comments[0].stickerURL?.absoluteString,
            "https://btcdn.etoland.co.kr/static/media/etohumor07/test/img.jpg",
            "image attachment resolves bfFile under the CDN /static base"
        )
        XCTAssertEqual(detail.comments[0].content, "이미지 첨부")

        XCTAssertNil(detail.comments[1].stickerURL)
        XCTAssertEqual(
            detail.comments[1].videoURL?.absoluteString,
            "https://btcdn.etoland.co.kr/static/media/etohumor07/test/clip.mp4",
            "video attachment prefers bfMp4File (transcoded) over bfFile"
        )

        XCTAssertEqual(
            detail.comments[2].stickerURL?.absoluteString,
            "https://btcdn.etoland.co.kr/static/media/etc/meme.jpg",
            "content-as-image-URL gets promoted to stickerURL"
        )
        XCTAssertEqual(
            detail.comments[2].content,
            "",
            "promoted-URL content is cleared so the URL doesn't render under the image"
        )

        XCTAssertNil(detail.comments[3].stickerURL)
        XCTAssertNil(detail.comments[3].videoURL)
        XCTAssertEqual(detail.comments[3].content, "그냥 텍스트")
    }

    func testEtolandDetailExtractsCommentsFromSSRPayload() throws {
        // Etoland comments live inside a __next_f.push([1,"...\"comments\":[...]..."])
        // script tag — a JS-escaped JSON blob. Fixture mimics the real shape:
        // two top-level comments where the second has a reply (childrenComments).
        // The walker has to track `\"` quote toggles and ignore brackets inside
        // string content (e.g. content with literal `]` characters).
        let html = """
        <html><body>
        <article>
          <h1 class="body-m"><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">작성자</span><time>2026-05-06 20:22</time></div></div>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"wrId\\":1,\\"commentId\\":100,\\"parentId\\":null,\\"writeDateTimestamp\\":1778066655000,\\"recommendCount\\":8,\\"content\\":\\"첫 댓글 [대괄호 포함]\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"갑\\",\\"image\\":\\"https://etoland.co.kr/avatar1\\"},\\"childrenComments\\":[]},{\\"wrId\\":1,\\"commentId\\":200,\\"parentId\\":null,\\"writeDateTimestamp\\":1778067000000,\\"recommendCount\\":3,\\"content\\":\\"두번째\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"을\\",\\"image\\":null},\\"childrenComments\\":[{\\"wrId\\":1,\\"commentId\\":201,\\"parentId\\":200,\\"writeDateTimestamp\\":1778067100000,\\"recommendCount\\":0,\\"content\\":\\"답글\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"병\\",\\"image\\":null},\\"childrenComments\\":[]}]}]}}]"])</script>
        </body></html>
        """
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "aagag-eto-c",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 3, "2 top-level + 1 nested reply, flattened")
        XCTAssertEqual(detail.comments[0].id, "etoland-c-100")
        XCTAssertEqual(detail.comments[0].author, "갑")
        XCTAssertEqual(detail.comments[0].content, "첫 댓글 [대괄호 포함]", "literal `[` inside string content must not derail bracket-walker")
        XCTAssertEqual(detail.comments[0].likeCount, 8)
        XCTAssertFalse(detail.comments[0].isReply)
        XCTAssertEqual(detail.comments[0].authIconURL?.absoluteString, "https://etoland.co.kr/avatar1")

        XCTAssertEqual(detail.comments[1].id, "etoland-c-200")
        XCTAssertEqual(detail.comments[1].author, "을")
        XCTAssertFalse(detail.comments[1].isReply)

        XCTAssertEqual(detail.comments[2].id, "etoland-c-201")
        XCTAssertEqual(detail.comments[2].author, "병")
        XCTAssertTrue(detail.comments[2].isReply, "childrenComments entry surfaces with isReply=true")
    }

    // MARK: - Inven

    func testInvenYoutubeIframePromotedToEmbedBlock() throws {
        // Real shape from inven.co.kr/board/maple/5974/6548994 — Inven's
        // editor wraps YouTube in `<figure><iframe src=".../embed/{id}">`.
        // Earlier `collectBlocks` early-returned on every iframe, so the
        // body ended up with only surrounding prose/images and the user
        // saw no video at all. Mirror the production shape (two iframes
        // interleaved with prose + an image) and assert each iframe
        // surfaces as `.embed(.youtube, id:)` while the rest of the body
        // is preserved in order.
        let html = """
        <html><body>
        <section class="mo-board-view">
          <div class="date">2026-05-07 12:00</div>
          <div class="hit"><span>1234</span></div>
          <div class="bbs-con">
            <div id="imageCollectDiv" class="contentBody">
              <div id="powerbbsContent">
                <div>입장컷신</div>
                <figure>
                  <iframe src="https://www.youtube.com/embed/4QQedW1BDB4" width="740" height="416" frameborder="0" allowfullscreen="true"></iframe>
                </figure>
                <div><br></div>
                <div>격파영상</div>
                <figure>
                  <iframe src="https://www.youtube.com/embed/S0aDEI54jRs" width="740" height="416" frameborder="0" allowfullscreen="true"></iframe>
                </figure>
                <div><img src="https://upload3.inven.co.kr/upload/2026/05/07/bbs/i1179489176.png" /></div>
                <div>보상: 기운 2개 다조 20개</div>
              </div>
            </div>
          </div>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let post = Post.fixture(
            id: "inven-maple-5974-6548994",
            site: .inven,
            boardID: "inven-maple",
            url: URL(string: "https://www.inven.co.kr/board/maple/5974/6548994")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let embeds = detail.blocks.embeds
        XCTAssertEqual(embeds.count, 2, "두 개의 youtube iframe이 모두 embed 블록으로 emit")
        XCTAssertEqual(embeds.first?.0, .youtube)
        XCTAssertEqual(embeds.first?.1, "4QQedW1BDB4")
        XCTAssertEqual(embeds.last?.0, .youtube)
        XCTAssertEqual(embeds.last?.1, "S0aDEI54jRs")

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.count, 1, "iframe 처리가 기존 image 블록을 가로채면 안 됨")

        let prose = detail.blocks.blockTexts.joined(separator: "\n")
        XCTAssertTrue(prose.contains("입장컷신"))
        XCTAssertTrue(prose.contains("격파영상"))
        XCTAssertTrue(prose.contains("보상"))
    }

    func testInvenNonYoutubeIframeIsDropped() throws {
        // Only YouTube iframes promote to an embed block — generic third-party
        // iframes (ad slots, twitter widgets, anything we don't know how to
        // render natively) should still be silently dropped, same as before.
        // Sanity: prose around them stays intact and no embed leaks through.
        let html = """
        <html><body>
        <section class="mo-board-view">
          <div class="bbs-con">
            <div id="imageCollectDiv">
              <p>위 본문</p>
              <iframe src="https://ad.example.com/banner.html" width="300" height="250"></iframe>
              <p>아래 본문</p>
            </div>
          </div>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let post = Post.fixture(
            id: "inven-test",
            site: .inven,
            boardID: "inven-maple",
            url: URL(string: "https://www.inven.co.kr/board/maple/0/0")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let embeds = detail.blocks.embeds
        XCTAssertTrue(embeds.isEmpty, "youtube가 아닌 iframe은 embed 블록을 만들면 안 됨")

        let prose = detail.blocks.blockTexts.joined(separator: "\n")
        XCTAssertTrue(prose.contains("위 본문"))
        XCTAssertTrue(prose.contains("아래 본문"))
    }

    func testInvenWalkerPreservesCollectorMediaAndLinks() throws {
        let html = """
        <html><body>
        <section class="mo-board-view">
          <div class="bbs-con">
            <p>collector 밖 본문은 무시</p>
            <div id="imageCollectDiv">
              <p>위 본문 <a href="https://example.com/link">참고 링크</a></p>
              <div style="display:none"><img src="https://upload3.inven.co.kr/upload/hidden.png"></div>
              <p><a href="https://example.com/full"><img src="https://upload3.inven.co.kr/upload/visible.png"></a></p>
              <p><video data-src="https://upload3.inven.co.kr/upload/clip.mp4" poster="https://upload3.inven.co.kr/upload/poster.jpg"></video></p>
              <p>아래 본문</p>
            </div>
          </div>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let post = Post.fixture(
            id: "inven-walker",
            site: .inven,
            boardID: "inven-maple",
            url: URL(string: "https://www.inven.co.kr/board/maple/0/1")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://upload3.inven.co.kr/upload/visible.png"])

        let videos = detail.blocks.videos
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.0.absoluteString, "https://upload3.inven.co.kr/upload/clip.mp4")
        XCTAssertEqual(videos.first?.1?.absoluteString, "https://upload3.inven.co.kr/upload/poster.jpg")

        let prose = detail.blocks.plainText
        XCTAssertTrue(prose.contains("위 본문"))
        XCTAssertTrue(prose.contains("아래 본문"))
        XCTAssertFalse(prose.contains("collector 밖 본문은 무시"), "imageCollectDiv 바깥 bbs-con 본문은 walk 대상이 아님")

        let links = detail.blocks.links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0.absoluteString, "https://example.com/link")
        XCTAssertEqual(links.first?.1, "참고 링크")
    }

    // MARK: - Humor

    func testHumorBodyImageFileURLPriorityAndSkipMarkers() throws {
        // Humor `<img img_file_url=원본 src=WebP>` 우선순위 + skipImageMarkers
        // (icon-, loading_bar2.gif 등) 가 차단되는지 핀.
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy">
          <div class="body_editor">
            <p>위 본문</p>
            <img img_file_url="https://image.humoruniv.com/orig.jpg" src="https://down-webp.humoruniv.com/compressed.webp">
            <img src="https://example.com/images/ic_chrome.png">
            <img src="https://example.com/images/loading_bar2.gif">
            <p>아래 본문</p>
          </div>
        </div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-1",
            site: .humor,
            boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://image.humoruniv.com/orig.jpg"],
                       "img_file_url 우선 + skipImageMarkers 차단")
    }

    func testHumorBodyDirectWebPGetsBlurUpPosterButJPGDoesNot() throws {
        // `simple_attach_img` 직접 첨부 webp(움짤)는 원본만 있고 정적 대체본이
        // 없어 다운로드+디코드에 수 초 걸린다 → thumb.php blur-up 포스터를 단다.
        // 반면 `img_compress` 는 위 우선순위 규칙이 `img_file_url` JPG 로 갈아타
        // resolve 결과가 webp 가 아니므로 포스터가 붙지 않아야 (가벼운 이미지에
        // 불필요한 썸네일 요청을 막는 게 핵심). pds#1412160 회귀 핀.
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy">
          <div class="body_editor">
            <img class="simple_attach_img" src="https://down.humoruniv.com//data/anim.webp">
            <img class="img_compress" img_file_url="https://down.humoruniv.com//data/orig.jpg" src="https://down-webp.humoruniv.com/c.webp">
          </div>
        </div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-poster",
            site: .humor,
            boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=1412160")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let images: [(url: URL, poster: URL?)] = detail.blocks.compactMap { block in
            if case .image(let url, let poster, _) = block.kind { (url, poster) } else { nil }
        }
        XCTAssertEqual(images.count, 2)

        // 직접 첨부 webp → 원본 src 그대로 + thumb.php 포스터.
        XCTAssertEqual(images[0].url.absoluteString, "https://down.humoruniv.com//data/anim.webp")
        XCTAssertEqual(
            images[0].poster?.absoluteString,
            "https://timg.humoruniv.com/thumb.php?url=https://down.humoruniv.com//data/anim.webp&SIZE=120x90",
            "직접 첨부 webp 에는 blur-up 포스터가 붙어야"
        )

        // img_compress → img_file_url JPG 로 resolve → webp 아님 → 포스터 nil.
        XCTAssertEqual(images[1].url.absoluteString, "https://down.humoruniv.com//data/orig.jpg")
        XCTAssertNil(images[1].poster, "JPG 로 갈아탄 가벼운 이미지엔 포스터 미부착")
    }

    func testHumorPosterEncodesQueryBreakingCharsInSourceURL() throws {
        // 방어적: src 에 자체 쿼리(`&`)가 있으면 thumb.php 의 바깥 쿼리를 깨
        // SIZE 가 url 값으로 빨려든다. `&` 는 %26 로 인코딩돼 SIZE 가 보존돼야.
        // (`://`,`/` 는 서버가 raw 를 요구하므로 그대로 유지.)
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy"><div class="body_editor">
          <img class="simple_attach_img" src="https://down.humoruniv.com//data/anim.webp?v=1&t=2">
        </div></div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-poster-q", site: .humor, boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        guard case .image(_, let poster, _)? = detail.blocks.first(where: {
            if case .image = $0.kind { return true }; return false
        })?.kind, let poster else {
            return XCTFail("webp 이미지 + 포스터 기대")
        }
        let s = poster.absoluteString
        XCTAssertTrue(s.contains("%26t=2"), "src 의 & 는 %26 로 인코딩: \(s)")
        XCTAssertTrue(s.hasSuffix("&SIZE=120x90"), "바깥 SIZE 파라미터 보존: \(s)")
        XCTAssertTrue(s.contains("://down.humoruniv.com//data"), ":/ 는 raw 유지: \(s)")
    }

    func testHumorBodyOnclickMp4PromotesToVideoBlock() throws {
        // Humor 비디오는 `<div onclick="comment_mp4_expand('id', 'url.mp4')">`
        // 형태로 옴 — onclick handler 파싱이 표준 dispatch 전에 동작해야 함.
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy">
          <div class="body_editor">
            <p>비디오 위</p>
            <div onclick="comment_mp4_expand('clip123', 'https://video.humoruniv.com/clip.mp4')">
              <img src="https://image.humoruniv.com/thumb.jpg">
            </div>
            <p>비디오 아래</p>
          </div>
        </div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-2",
            site: .humor,
            boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=2")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.map(\.absoluteString), ["https://video.humoruniv.com/clip.mp4"])
        // 썸네일 img 는 onclick wrapper 가 claim 했으므로 image 블록 0
        let images = detail.blocks.imageURLs
        XCTAssertTrue(images.isEmpty, "onclick wrapper 가 claim 한 자식 썸네일은 image 블록 안 만들어야")
    }

    func testHumorBodyYouTubeIframeAndHiddenSubtree() throws {
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy">
          <div class="body_editor">
            <p>위 본문</p>
            <iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe>
            <div style="display:none"><img src="https://image.humoruniv.com/hidden.jpg"></div>
            <p>아래 본문</p>
          </div>
        </div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-3",
            site: .humor,
            boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=3")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let embeds = detail.blocks.youtubeIDs
        XCTAssertEqual(embeds, ["abcdefghijk"])
        let hasHidden = detail.blocks.contains { block in
            if case .image(let url, _, _) = block.kind { return url.absoluteString.contains("hidden") }
            return false
        }
        XCTAssertFalse(hasHidden, "display:none 안 이미지 누락")
    }

    func testHumorBodyPreservesInlineLinksAndBlockOrder() throws {
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="wrap_copy">
          <div class="body_editor">
            <p>시작 <a href="https://example.com/ref">참고 링크</a></p>
            <img src="https://image.humoruniv.com/body.jpg">
            <p>끝 본문</p>
          </div>
        </div>
        </body></html>
        """
        let parser = HumorParser()
        let post = Post.fixture(
            id: "humor-4",
            site: .humor,
            boardID: "pds",
            url: URL(string: "https://m.humoruniv.com/board/humor/read.html?table=pds&number=4")!
        )

        let detail = try parser.parseDetail(html: html, post: post)

        XCTAssertEqual(detail.blocks.count, 3)
        guard case .richText(let head) = detail.blocks[0].kind,
              case .image(let imageURL, _, _) = detail.blocks[1].kind,
              case .richText(let tail) = detail.blocks[2].kind
        else {
            return XCTFail("expected richText, image, richText; got \(detail.blocks.map(\.kind))")
        }

        XCTAssertEqual(head.count, 2)
        if case .text(let text) = head[0] {
            XCTAssertTrue(text.contains("시작"))
        } else {
            XCTFail("head[0] should be text")
        }
        if case .link(let url, let label) = head[1] {
            XCTAssertEqual(url.absoluteString, "https://example.com/ref")
            XCTAssertEqual(label, "참고 링크")
        } else {
            XCTFail("head[1] should be link")
        }
        XCTAssertEqual(imageURL.absoluteString, "https://image.humoruniv.com/body.jpg")
        XCTAssertEqual(tail.plainText.trimmingCharacters(in: .whitespacesAndNewlines), "끝 본문")
    }

    // MARK: - SLR

    func testSLRBodyExtractsTextImageVideoYouTubeAndAnchor() throws {
        // SLR 본문 fixture (parser-level baseline 0개였음 → 마이그 전 ground truth).
        // userct 선택 / standard 이미지 우선순위(src→data-src→data-original) /
        // <video><source mp4> / YouTube iframe / 일반 <a href> 인라인 링크
        // 한 번에 검증.
        let html = """
        <html><body>
        <div class="subject">제목</div>
        <div id="userct">
          <p>위 본문 <a href="https://example.com/ref">참고</a></p>
          <p><img src="https://image.slrclub.com/body.jpg"></p>
          <p><video><source src="https://video.slrclub.com/clip.mp4#t=0.05"></video></p>
          <p><iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe></p>
          <p>아래 본문</p>
        </div>
        </body></html>
        """
        let parser = SLRParser()
        let post = Post.fixture(
            id: "slr-1",
            site: .slr,
            boardID: "free",
            url: URL(string: "https://m.slrclub.com/m_view.php?id=free&no=1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)

        XCTAssertEqual(detail.blocks.count, 5)
        guard case .richText(let head) = detail.blocks[0].kind,
              case .image(let imageURL, _, _) = detail.blocks[1].kind,
              case .video(let videoURL, _) = detail.blocks[2].kind,
              case .embed(.youtube, let embedID) = detail.blocks[3].kind,
              case .richText(let tail) = detail.blocks[4].kind
        else {
            return XCTFail("expected richText, image, video, embed, richText; got \(detail.blocks.map(\.kind))")
        }

        XCTAssertEqual(head.count, 2)
        if case .text(let text) = head[0] {
            XCTAssertTrue(text.contains("위 본문"))
        } else {
            XCTFail("head[0] should be text")
        }
        if case .link(let url, let label) = head[1] {
            XCTAssertEqual(url.absoluteString, "https://example.com/ref")
            XCTAssertEqual(label, "참고")
        } else {
            XCTFail("head[1] should be link")
        }
        XCTAssertEqual(imageURL.absoluteString, "https://image.slrclub.com/body.jpg")
        XCTAssertEqual(videoURL.absoluteString, "https://video.slrclub.com/clip.mp4", "<source src> + #t= strip")
        XCTAssertEqual(embedID, "abcdefghijk")
        XCTAssertEqual(tail.plainText.trimmingCharacters(in: .whitespacesAndNewlines), "아래 본문")
    }

    func testBodyDropsHiddenSubtreeAndScriptTagsAcrossSites() {
        // Matrix: parser × wrapper HTML × URL. 4 사이트가 동일 assertion 통과해야 함.
        // 각 사이트 본문 wrapper 가 다르지만 (`<div id=userct>`, `xe_content`, ...)
        // hidden subtree + script drop 동작은 통일.
        struct Case {
            let name: String
            let parser: any BoardParser
            let bodyHTML: String
            let url: URL
            let site: Site
        }
        let cases: [Case] = [
            Case(
                name: "SLR",
                parser: SLRParser(),
                bodyHTML: """
                <div class="subject">제목</div>
                <div id="userct">
                  <p>앞</p>
                  <div style="display:none"><img src="https://image.slrclub.com/hidden.jpg"></div>
                  <script>var x = 1;</script>
                  <p>뒤</p>
                </div>
                """,
                url: URL(string: "https://m.slrclub.com/m_view.php?id=free&no=2")!,
                site: .slr
            ),
            Case(
                name: "Ddanzi",
                parser: DdanziParser(),
                bodyHTML: """
                <div class="boardR">
                  <div class="read_content">
                    <div class="xe_content">
                      <p>앞</p>
                      <div style="display:none"><img src="https://image.ddanzi.com/hidden.jpg"></div>
                      <script>var x = 1;</script>
                      <p>뒤</p>
                    </div>
                  </div>
                </div>
                """,
                url: URL(string: "https://www.ddanzi.com/free/2")!,
                site: .ddanzi
            ),
            Case(
                name: "Coolenjoy",
                parser: CoolenjoyParser(),
                bodyHTML: """
                <article id="bo_v">
                  <div class="view-content">
                    <p>앞</p>
                    <div style="display:none"><img src="https://image.coolenjoy.net/hidden.jpg"></div>
                    <script>var x = 1;</script>
                    <p>뒤</p>
                  </div>
                </article>
                """,
                url: URL(string: "https://coolenjoy.net/bbs/free/2")!,
                site: .coolenjoy
            ),
            Case(
                name: "Cook82",
                parser: Cook82Parser(),
                bodyHTML: """
                <div id="articleBody">
                  <p>앞</p>
                  <div style="display:none"><img src="https://image.82cook.com/hidden.jpg"></div>
                  <script>var x = 1;</script>
                  <p>뒤</p>
                </div>
                """,
                url: URL(string: "https://www.82cook.com/entiz/read.php?bn=15&num=2")!,
                site: .cook82
            ),
        ]
        for c in cases {
            XCTContext.runActivity(named: c.name) { _ in
                // do/catch wrap — `try parseDetail` 가 throw 해도 다른 case 가 멈추지
                // 않도록. runActivity rethrows 라 throw 가 for-loop 밖으로 propagate
                // 되면 후속 case 가 silent-skip 되는 회귀가 일어남.
                do {
                    let html = "<html><body>\(c.bodyHTML)</body></html>"
                    let post = Post.fixture(site: c.site, url: c.url)
                    let detail = try c.parser.parseDetail(html: html, post: post)
                    XCTAssertTrue(detail.blocks.imageURLs.isEmpty, "\(c.name): display:none 안 이미지 누락")
                    let prose = detail.blocks.plainText
                    XCTAssertTrue(prose.contains("앞"), "\(c.name): 앞 본문 보존")
                    XCTAssertTrue(prose.contains("뒤"), "\(c.name): 뒤 본문 보존")
                    XCTAssertFalse(prose.contains("var x = 1"), "\(c.name): <script> 안 본문 누락")
                } catch {
                    XCTFail("\(c.name): parseDetail threw \(error)")
                }
            }
        }
    }

    func testSLRBodyKeepsLegacyVideoPrecedenceAndAnchorMediaRules() throws {
        let html = """
        <html><body>
        <div class="subject">제목</div>
        <div id="userct">
          <video data-src="https://video.slrclub.com/lazy.mp4" src="https://video.slrclub.com/canonical.mp4"></video>
          <a href="https://example.com/full"><img src="https://image.slrclub.com/wrapped.jpg"></a>
          <a href="https://example.com/embed"><iframe src="https://www.youtube.com/embed/zzzzzzzzzzz"></iframe>iframe 링크</a>
        </div>
        </body></html>
        """
        let parser = SLRParser()
        let post = Post.fixture(
            id: "slr-3",
            site: .slr,
            boardID: "free",
            url: URL(string: "https://m.slrclub.com/m_view.php?id=free&no=3")!
        )
        let detail = try parser.parseDetail(html: html, post: post)

        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.map(\.absoluteString), ["https://video.slrclub.com/canonical.mp4"])

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://image.slrclub.com/wrapped.jpg"])

        let embeds = detail.blocks.youtubeIDs
        XCTAssertTrue(embeds.isEmpty, "SLR legacy mediaTags only unwrap img/video inside anchors")

        let links = detail.blocks.links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0.absoluteString, "https://example.com/embed")
        XCTAssertEqual(links.first?.1, "iframe 링크")
    }

    // MARK: - Ddanzi

    func testDdanziBodyExtractsTextImageVideoYouTubeAndAnchor() throws {
        let html = """
        <html><body>
        <div class="boardR">
          <div class="read_content">
            <div class="xe_content">
              <p>위 본문 <a href="https://example.com/ref">참고</a></p>
              <p><img src="https://image.ddanzi.com/body.jpg"></p>
              <p><video><source src="https://video.ddanzi.com/clip.mp4#t=0.05"></video></p>
              <p><iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe></p>
              <p>아래 본문</p>
            </div>
          </div>
        </div>
        </body></html>
        """
        let parser = DdanziParser()
        let post = Post.fixture(
            id: "ddanzi-1",
            site: .ddanzi,
            boardID: "free",
            url: URL(string: "https://www.ddanzi.com/free/1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://image.ddanzi.com/body.jpg"])

        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.map(\.absoluteString), ["https://video.ddanzi.com/clip.mp4"])

        let embeds = detail.blocks.youtubeIDs
        XCTAssertEqual(embeds, ["abcdefghijk"])

        let links = detail.blocks.links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0.absoluteString, "https://example.com/ref")
        XCTAssertEqual(links.first?.1, "참고")
    }

    // MARK: - Coolenjoy

    func testCoolenjoyBodyExtractsImageAndAnchor() throws {
        let html = """
        <html><body>
        <article id="bo_v">
          <div class="view-content">
            <p>위 본문 <a href="https://example.com/ref">참고</a></p>
            <p><a href="https://example.com/full"><img src="https://image.coolenjoy.net/wrap.jpg"></a></p>
            <p>아래 본문</p>
          </div>
        </article>
        </body></html>
        """
        let parser = CoolenjoyParser()
        let post = Post.fixture(
            id: "coolenjoy-1",
            site: .coolenjoy,
            boardID: "free",
            url: URL(string: "https://coolenjoy.net/bbs/free/1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://image.coolenjoy.net/wrap.jpg"])

        let links = detail.blocks.links
        XCTAssertEqual(links.count, 1, "anchor-wrap-image 안쪽 라벨 무시, 평문 anchor 만 link 로")
        XCTAssertEqual(links.first?.0.absoluteString, "https://example.com/ref")
    }

    func testCoolenjoyBodyDropsVideoAndIframeLegacy() throws {
        // 옛 CoolenjoyParser 는 `<video>`/`<iframe>` 케이스가 없어 본문에
        // 표시 안 함 (default recurse → 자식 없음 → 빈 output). walker
        // 마이그 후에도 같은 legacy 동작 유지 (skipTags 에 추가).
        let html = """
        <html><body>
        <article id="bo_v">
          <div class="view-content">
            <p>위</p>
            <iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe>
            <video src="https://video.example.com/clip.mp4"></video>
            <p>아래</p>
          </div>
        </article>
        </body></html>
        """
        let parser = CoolenjoyParser()
        let post = Post.fixture(
            id: "coolenjoy-3",
            site: .coolenjoy,
            boardID: "free",
            url: URL(string: "https://coolenjoy.net/bbs/free/3")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let nonText = detail.blocks.contains { block in
            switch block.kind {
            case .video, .embed: return true
            default: return false
            }
        }
        XCTAssertFalse(nonText, "Coolenjoy 는 video/iframe 본문 블록 생성 안 함 (legacy parity)")
    }

    func testCoolenjoyAnchorWrappingVideoOrIframeStaysInlineLink() throws {
        // `mediaTags = ["img"]` override 의 실제 안전망 — `<a><iframe></a>`
        // 가 media-wrap 으로 인식되어 YouTube embed 로 promote 되지 않고
        // anchor 라벨이 inline link 로 보존되는지 핀. 이 fixture 가 있어야
        // mediaTags override 가 향후 누군가 redundant 라 판단해 제거할 때
        // 명시적으로 깨짐.
        let html = """
        <html><body>
        <article id="bo_v">
          <div class="view-content">
            <p><a href="https://example.com/embed-link"><iframe src="https://www.youtube.com/embed/zzzzzzzzzzz"></iframe>iframe 라벨</a></p>
            <p><a href="https://example.com/video-link"><video src="https://video.example.com/inside.mp4"></video>video 라벨</a></p>
          </div>
        </article>
        </body></html>
        """
        let parser = CoolenjoyParser()
        let post = Post.fixture(
            id: "coolenjoy-4",
            site: .coolenjoy,
            boardID: "free",
            url: URL(string: "https://coolenjoy.net/bbs/free/4")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let embeds = detail.blocks.youtubeIDs
        XCTAssertTrue(embeds.isEmpty, "anchor-wrap iframe 은 embed 블록 생성 안 함")
        let videos = detail.blocks.videoURLs
        XCTAssertTrue(videos.isEmpty, "anchor-wrap video 도 video 블록 생성 안 함")
        let links = detail.blocks.links
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map(\.0.absoluteString).sorted(),
                       ["https://example.com/embed-link", "https://example.com/video-link"])
    }

    // MARK: - Cook82

    func testCook82BodyExtractsTextImageVideoYouTubeAndAnchor() throws {
        let html = """
        <html><body>
        <div id="articleBody">
          <p>위 본문 <a href="https://example.com/ref">참고</a></p>
          <p><img src="https://image.82cook.com/body.jpg"></p>
          <p><video><source src="https://video.82cook.com/clip.mp4#t=0.05"></video></p>
          <p><iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe></p>
          <p>아래 본문</p>
        </div>
        </body></html>
        """
        let parser = Cook82Parser()
        let post = Post.fixture(
            id: "cook82-1",
            site: .cook82,
            boardID: "free",
            url: URL(string: "https://www.82cook.com/entiz/read.php?bn=15&num=1")!
        )
        let detail = try parser.parseDetail(html: html, post: post)

        let images = detail.blocks.imageURLs
        XCTAssertEqual(images.map(\.absoluteString), ["https://image.82cook.com/body.jpg"])

        let videos = detail.blocks.videoURLs
        XCTAssertEqual(videos.map(\.absoluteString), ["https://video.82cook.com/clip.mp4"])

        let embeds = detail.blocks.youtubeIDs
        XCTAssertEqual(embeds, ["abcdefghijk"])

        let links = detail.blocks.links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0.absoluteString, "https://example.com/ref")
        XCTAssertEqual(links.first?.1, "참고")
    }

    // MARK: - Bobae

    func testBobaeBodyExtractsTextImageAndYouTube() throws {
        // Minimal `.article-body` shape: text intro, inline image,
        // YouTube embed, closing text. Pins the walker output so the
        // upcoming `ParserBlockWalker` migration must produce the same
        // blocks in the same order.
        let html = """
        <html><body>
        <article class="article">
          <h3 class="subject">테스트 제목</h3>
          <div class="util2"><div class="info"><span>닉네임</span></div></div>
          <div class="util"><time datetime="2026-05-20">10:00</time></div>
          <div class="article-body">
            <p>위 본문</p>
            <p><img src="https://e.com/bobae-a.png"></p>
            <p><iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe></p>
            <p>아래 본문</p>
          </div>
        </article>
        </body></html>
        """
        let parser = BobaeParser()
        let post = Post.fixture(
            id: "bobae-1",
            site: .bobae,
            boardID: "freeb",
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/1")!
        )

        let detail = try parser.parseDetail(html: html, post: post)
        let kinds = detail.blocks.map { $0.kind }

        // 기대 시퀀스: richText("위 본문") → image → embed(.youtube) → richText("아래 본문")
        XCTAssertEqual(kinds.count, 4, "블록 4개 (텍스트, 이미지, 유튜브, 텍스트)")

        guard kinds.count == 4 else { return }
        if case .richText(let segs0) = kinds[0],
           case .text(let s0) = segs0.first {
            XCTAssertTrue(s0.contains("위 본문"), "첫 블록은 '위 본문' 포함")
        } else {
            XCTFail("첫 블록은 richText 이어야 함")
        }
        if case .image(let url, _, _) = kinds[1] {
            XCTAssertEqual(url.absoluteString, "https://e.com/bobae-a.png")
        } else {
            XCTFail("두 번째 블록은 image 이어야 함")
        }
        if case .embed(.youtube, let id) = kinds[2] {
            XCTAssertEqual(id, "abcdefghijk")
        } else {
            XCTFail("세 번째 블록은 embed(.youtube)")
        }
        if case .richText(let segs3) = kinds[3],
           case .text(let s3) = segs3.first {
            XCTAssertTrue(s3.contains("아래 본문"), "마지막 블록은 '아래 본문' 포함")
        } else {
            XCTFail("마지막 블록은 richText 이어야 함")
        }
    }

    func testBobaeBodyDropsHiddenSubtree() throws {
        let html = """
        <html><body><article class="article">
          <div class="article-body">
            <div style="display:none"><img src="https://e.com/hidden.png"></div>
            <p>보이는 본문</p>
          </div>
        </article></body></html>
        """
        let parser = BobaeParser()
        let post = Post.fixture(
            id: "bobae-2",
            site: .bobae,
            boardID: "freeb",
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/2")!
        )
        let detail = try parser.parseDetail(html: html, post: post)
        let hasHidden = detail.blocks.contains { block in
            if case .image(let url, _, _) = block.kind {
                return url.absoluteString.contains("hidden")
            }
            return false
        }
        XCTAssertFalse(hasHidden, "display:none 안 이미지 누락")
    }

    // MARK: - convertAnchorsToMarkdown (comment anchor handling)

    /// Repro for the SLR/Bobae/Ddanzi/Humor/Ppomppu comment bug: those
    /// parsers strip `<img>` *before* calling `convertAnchorsToMarkdown`, so
    /// an image wrapped in a link — `<a href="x.gif"><img src="x.gif"></a>`
    /// (the image is rendered separately as a sticker) — arrives here as a
    /// bare `<a href="x.gif"></a>`. The href must NOT leak into the rendered
    /// text as a markdown link; the image URL was showing up as visible text
    /// next to the rendered sticker. (real case: m.slrclub.com/v/free/41637430)
    func testConvertAnchorsDropsLabellessAnchorInsteadOfLeakingURL() throws {
        let parser = SLRParser()
        let body = try SwiftSoup.parseBodyFragment(
            #"<a href="https://i.pinimg.com/originals/73/x.gif" target="_blank"></a>"#
        ).body()!
        parser.convertAnchorsToMarkdown(in: body)
        let text = try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.contains("pinimg"), "label 없는 앵커가 URL을 텍스트로 흘림: \(text)")
        XCTAssertTrue(text.isEmpty, "label 없는 앵커는 드롭돼야 함, got: \(text)")
    }

    /// When the `<img>` is still present (parsers that convert anchors before
    /// stripping media), the anchor unwraps to leave the image — still no URL
    /// text leak.
    func testConvertAnchorsUnwrapsAnchorStillWrappingImage() throws {
        let parser = SLRParser()
        let body = try SwiftSoup.parseBodyFragment(
            #"<a href="https://x/y.gif"><img src="https://x/y.gif"></a>"#
        ).body()!
        parser.convertAnchorsToMarkdown(in: body)
        let text = try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.contains("https://"), "이미지 래퍼 앵커가 URL 흘림: \(text)")
    }

    /// A genuine text link must still become a tappable markdown link.
    func testConvertAnchorsKeepsTextLinkAsMarkdown() throws {
        let parser = SLRParser()
        let body = try SwiftSoup.parseBodyFragment(
            #"<a href="https://example.com">예시</a>"#
        ).body()!
        parser.convertAnchorsToMarkdown(in: body)
        XCTAssertEqual(try body.text(), "[예시](<https://example.com>)")
    }

    /// A bare-URL link (label == its own href text) keeps showing the URL —
    /// the drop rule only targets *labelless* anchors.
    func testConvertAnchorsKeepsBareURLTextLink() throws {
        let parser = SLRParser()
        let body = try SwiftSoup.parseBodyFragment(
            #"<a href="https://example.com/x">https://example.com/x</a>"#
        ).body()!
        parser.convertAnchorsToMarkdown(in: body)
        XCTAssertEqual(try body.text(), "[https://example.com/x](<https://example.com/x>)")
    }
}
