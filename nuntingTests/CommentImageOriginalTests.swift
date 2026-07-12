import XCTest
@testable import nunting

/// 회귀 가드: 댓글 이미지는 **원본 해상도 URL** 로 추출돼야 한다. 각 사이트가
/// 서버 리사이즈 썸네일을 마크업에 실어 보내는데(전부 라이브 실측으로 규칙 검증,
/// 2026-07-02), 그걸 그대로 뽑으면 전체화면 뷰어에서 확대해도 저해상도다.
///   - 인벤: `?MW=360` 쿼리 = 폭 360 리사이즈. 제거 시 원본(실측 360→1080px).
///   - 뽐뿌: `/zboard/data3/comment/**` 의 `_550w` 접미사 = 폭 690 변형.
///     제거 시 원본(실측 7/7 성공, 958~1200px).
///   - 클리앙: `?scale=width:480` 고정. CDN 허용값은 480/740 뿐(쿼리 제거는
///     302 차단)이라 740 치환이 무왕복 최대(원본이 740 이하면 원본 그대로 옴).
///   - 웃대: 움짤(GIF) 첨부는 img_file_url 없이 timg 썸네일 프록시(정지
///     JPEG)만 img 에 실림 — 원본은 comment_thumb_expand href 둘째 인자
///     (실측 2026-07-12, 무보호 200).
final class CommentImageOriginalTests: XCTestCase {

    func testInvenStripsResizeQueryFromCommentImage() throws {
        // 실측 마크업: 업로드 사진 댓글의 src 에 `?MW=360` 리사이즈 파라미터.
        // (entity-encoded HTML — 인벤 o_comment 원형 그대로)
        let json = """
        {"commentlist":[{"__attr__":{"titlenum":0},"list":[
          {"__attr__":{"cmtidx":1,"cmtpidx":1},"o_date":"방금","o_name":"민수",
           "o_comment":"&lt;div class=&quot;cmtimager ready&quot;&gt;&lt;img class=&quot;cmtimage&quot; src=&quot;https://upload3.inven.co.kr/upload/2026/07/02/bbs/i1342593670.jpg?MW=360&quot;&gt;&lt;/div&gt;",
           "o_recommend":0}
        ]}]}
        """
        let comments = try InvenParser().comments(fromResponseData: Data(json.utf8))
        XCTAssertEqual(
            comments.first?.stickerURL?.absoluteString,
            "https://upload3.inven.co.kr/upload/2026/07/02/bbs/i1342593670.jpg",
            "MW 리사이즈 파라미터를 벗겨 원본 URL 이어야 함"
        )
    }

    func testInvenStripsOnlyResizeParamKeepingOthers() throws {
        // MW 만 제거하고 나머지 쿼리 아이템은 보존해야 한다 — URL 전체를
        // 통째로 자르는 회귀(쿼리 전부 유실)를 막는 가드.
        let url = URL(string: "https://upload3.inven.co.kr/upload/2026/07/02/bbs/i1.jpg?MW=360&foo=bar")!
        XCTAssertEqual(
            InvenParser.strippingResizeParam(url).absoluteString,
            "https://upload3.inven.co.kr/upload/2026/07/02/bbs/i1.jpg?foo=bar"
        )
    }

    func testInvenStickerWithoutQueryUnchanged() throws {
        // 스티커는 쿼리 없이 옴 — 변형 없이 그대로 통과해야 한다.
        let json = """
        {"commentlist":[{"__attr__":{"titlenum":0},"list":[
          {"__attr__":{"cmtidx":2,"cmtpidx":2},"o_date":"방금","o_name":"영희",
           "o_comment":"&lt;img class=&quot;cmtimage&quot; src=&quot;https://upload3.inven.co.kr/upload/2026/01/09/sticker/i1538360893.jpg&quot;&gt;",
           "o_recommend":0}
        ]}]}
        """
        let comments = try InvenParser().comments(fromResponseData: Data(json.utf8))
        XCTAssertEqual(
            comments.first?.stickerURL?.absoluteString,
            "https://upload3.inven.co.kr/upload/2026/01/09/sticker/i1538360893.jpg"
        )
    }

    func testPpomppuStripsWidthSuffixFromCommentImage() throws {
        // 실측 마크업: data-original 이 `_550w` 폭 변형을 가리킴(+캐시버스터 쿼리).
        let json = #"""
        {"comments":[
          {"no":10,"depth":0,"name":"<b>A</b>",
           "memo":"<p><img class=\"lazy\" src=\"//cdn2.ppomppu.co.kr/images/lazyloading.jpg\" data-original=\"//cdn2.ppomppu.co.kr/zboard/data3/comment/16/ppomppu_15633116_550w?v=1782987226\"></p>",
           "meta":{"time_display":"t"}}
        ],"total_page":1,"c_page":1}
        """#
        let comments = try PpomppuParser().parseComments(html: json)
        XCTAssertEqual(
            comments.first?.stickerURL?.absoluteString,
            "https://cdn2.ppomppu.co.kr/zboard/data3/comment/16/ppomppu_15633116?v=1782987226",
            "_550w 접미사를 벗긴 원본 URL 이어야 함(쿼리는 보존)"
        )
    }

    func testPpomppuPlainCommentImageUnchanged() throws {
        // 접미사 없는 댓글 이미지는 그대로 — 원본이 이미 그 파일이다.
        let json = #"""
        {"comments":[
          {"no":11,"depth":0,"name":"<b>B</b>",
           "memo":"<p><img class=\"lazy\" src=\"//cdn2.ppomppu.co.kr/images/lazyloading.jpg\" data-original=\"//cdn2.ppomppu.co.kr/zboard/data3/comment/22/ppomppu_15633122?v=1\"></p>",
           "meta":{"time_display":"t"}}
        ],"total_page":1,"c_page":1}
        """#
        let comments = try PpomppuParser().parseComments(html: json)
        XCTAssertEqual(
            comments.first?.stickerURL?.absoluteString,
            "https://cdn2.ppomppu.co.kr/zboard/data3/comment/22/ppomppu_15633122?v=1"
        )
    }

    func testClienUpgradesCommentImageScaleTo740() throws {
        // 실측 마크업: 댓글 첨부는 항상 `?scale=width:480`. CDN 이 허용하는
        // 최대인 740 으로 치환돼야 한다.
        let html = """
        <html><body>
        <div class="post_article">본문</div>
        <div class="comment_row" data-role="comment-row" data-comment-sn="1" data-author-id="u1">
          <span class="nickname">홍길동</span>
          <div class="comment_view">사진</div>
          <div class="comment-img">
            <img src="https://edgio.clien.net/F03/2026/7/15767170/12fef72fc378d0.PNG?scale=width:480"
                 data-role="attach-image" data-img-width="1306" data-img-height="911" />
          </div>
        </div>
        </body></html>
        """
        let detail = try ClienParser().parseDetail(html: html, post: .fixture(site: .clien))
        XCTAssertEqual(
            detail.comments.first?.stickerURL?.absoluteString,
            "https://edgio.clien.net/F03/2026/7/15767170/12fef72fc378d0.PNG?scale=width:740",
            "scale=width:480 → width:740 (무왕복 최대 해상도)"
        )
    }

    func testClienUpgradesScaleKeepingOtherQueryItems() throws {
        // scale 만 740 으로 바꾸고 다른 쿼리 아이템(순서 포함)은 보존.
        let url = URL(string: "https://edgio.clien.net/F03/1/a.png?scale=width:480&foo=bar")!
        XCTAssertEqual(
            ClienParser.upgradingScaleWidth(url).absoluteString,
            "https://edgio.clien.net/F03/1/a.png?scale=width:740&foo=bar"
        )
    }

    func testHumorCommentGIFAttachmentExtractsOriginalFromThumbExpand() throws {
        // 실측 마크업(2026-07-12): 움짤(GIF) 댓글 첨부는 img 에 img_file_url
        // 속성이 없고, 원본 URL 이 `<a href="javascript:comment_thumb_expand(
        // 'id','원본','썸네일')">` 의 둘째 인자에만 있다. 이걸 안 뽑으면 timg
        // 썸네일 프록시(정지 JPEG, 실측 17KB)가 나가고 원본 애니메이션
        // GIF(실측 2MB, 무보호 200)는 버려진다.
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="comment"><ul>
          <li id="comment_li_515096502">
            <div class="nick"><span class="hu_nick_txt">닉</span></div>
            <span class="etc">2026-07-12 10:00</span>
            <div class="comment_body">
              <div class="comment_text">움짤</div>
              <div class="comment_file">
                <a href="javascript:comment_thumb_expand('cmt515096502','//down.humoruniv.com/board/data/comment/r_r269078001_abc.gif','//timg.humoruniv.com/thumb.php?url=//down.humoruniv.com/board/data/comment/r_r269078001_abc.gif?SIZE=236x196?WEBP')">
                  <img class="comment_thumb_img" src="//timg.humoruniv.com/thumb.php?url=//down.humoruniv.com/board/data/comment/r_r269078001_abc.gif?SIZE=236x196?WEBP">
                </a>
              </div>
            </div>
          </li>
        </ul></div>
        </body></html>
        """
        let detail = try HumorParser().parseDetail(
            html: html,
            post: .fixture(site: .humor, url: URL(string: "https://m.humoruniv.com/board/read.html?table=pds&number=1")!)
        )
        XCTAssertEqual(
            detail.comments.first?.stickerURL?.absoluteString,
            "https://down.humoruniv.com/board/data/comment/r_r269078001_abc.gif",
            "comment_thumb_expand href 의 둘째 인자(원본 GIF)여야 함 — timg 프록시 아님"
        )
    }

    func testHumorCommentImgFileURLAttachmentStillPreferred() throws {
        // 기존 처리 가드 — img_compress 첨부는 img_file_url(원본)을 그대로.
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="comment"><ul>
          <li id="comment_li_515096503">
            <div class="nick"><span class="hu_nick_txt">닉2</span></div>
            <span class="etc">2026-07-12 10:01</span>
            <div class="comment_body">
              <div class="comment_text">사진</div>
              <div class="comment_file">
                <img src='/images/loading_bar2.gif'>
                <img class="img_compress"
                     src="//timg.humoruniv.com/thumb.php?url=//down.humoruniv.com/board/data/comment/photo1.png"
                     img_file_url="//down.humoruniv.com/board/data/comment/photo1.png">
              </div>
            </div>
          </li>
        </ul></div>
        </body></html>
        """
        let detail = try HumorParser().parseDetail(
            html: html,
            post: .fixture(site: .humor, url: URL(string: "https://m.humoruniv.com/board/read.html?table=pds&number=2")!)
        )
        XCTAssertEqual(
            detail.comments.first?.stickerURL?.absoluteString,
            "https://down.humoruniv.com/board/data/comment/photo1.png"
        )
    }

    func testClienImageWithoutScaleQueryUnchanged() throws {
        let html = """
        <html><body>
        <div class="post_article">본문</div>
        <div class="comment_row" data-role="comment-row" data-comment-sn="2" data-author-id="u2">
          <span class="nickname">김철수</span>
          <div class="comment_view">사진</div>
          <div class="comment-img">
            <img src="https://edgio.clien.net/F03/2026/7/999/abc.png" data-role="attach-image" />
          </div>
        </div>
        </body></html>
        """
        let detail = try ClienParser().parseDetail(html: html, post: .fixture(site: .clien))
        XCTAssertEqual(
            detail.comments.first?.stickerURL?.absoluteString,
            "https://edgio.clien.net/F03/2026/7/999/abc.png"
        )
    }
}
