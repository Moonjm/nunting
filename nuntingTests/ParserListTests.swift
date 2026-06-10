import XCTest
@testable import nunting
/// Fixture-based regression tests for parser `parseList` selectors.
///
/// Fixtures are intentionally embedded as Swift string literals rather
/// than bundled resources to keep the test target self-contained — no
/// `PBXResourcesBuildPhase` plumbing needed for synced groups, and a
/// failing fixture diff is readable straight from the test source.
///
/// What these protect against: silent regressions when SwiftSoup
/// selector strings drift away from the live site DOM (notice rows
/// leaking into the feed, dedup keys collapsing, source-tag class
/// extraction breaking, etc.). They do *not* replace fetching real
/// HTML — they pin the parser's behavior against the smallest legal
/// DOM that exercises each selector branch.
final class ParserListTests: XCTestCase {

    // MARK: - Clien

    func testClienListSkipsNoticeRowsAndAdSlots() throws {
        let html = """
        <html><body>
        <a class="list_item symph-row" href="/service/board/news/19000001"
           data-board-sn="19000001" data-comment-count="42" data-author-id="someone">
            <span data-role="list-title-text">실제 글 제목</span>
            <div class="list_author"><span class="nickname">정상유저</span></div>
            <div class="list_time"><span>2026-05-01 12:34</span></div>
        </a>
        <a class="list_item notice symph-row" href="/service/board/news/19000002"
           data-board-sn="19000002" data-comment-count="0">
            <span data-role="list-title-text">고정 공지</span>
        </a>
        <a class="list_item symph-row" href="/service/board/news/19000003"
           data-board-sn="19000003" data-comment-count="0">
            <div class="ad">알리정보</div>
            <span data-role="list-title-text">스폰서 글</span>
        </a>
        <a class="list_item symph-row" href="/service/board/news/19000004"
           data-board-sn="19000004" data-comment-count="3">
            <span data-role="list-title-text">두번째 정상글</span>
            <div class="list_author"><span class="nickname">유저B</span></div>
            <div class="list_time"><span>2026-05-01 13:00</span></div>
        </a>
        </body></html>
        """
        let parser = ClienParser()
        let posts = try parser.parseList(html: html, board: .clienNews)
        XCTAssertEqual(posts.count, 2, "공지 + ad 행은 결과에서 제외되어야 함")
        XCTAssertEqual(posts[0].title, "실제 글 제목")
        XCTAssertEqual(posts[0].author, "정상유저")
        XCTAssertEqual(posts[0].dateText, "2026-05-01 12:34")
        XCTAssertEqual(posts[0].commentCount, 42)
        XCTAssertEqual(posts[0].id, "clien-news-19000001")
        XCTAssertEqual(posts[0].url.absoluteString, "https://www.clien.net/service/board/news/19000001")
        XCTAssertEqual(posts[1].title, "두번째 정상글")
        XCTAssertEqual(posts[1].id, "clien-news-19000004")
    }

    func testClienListAuthorFallsBackToDataAttribute() throws {
        // When the markup omits `.list_author span.nickname` the parser
        // should fall back to `data-author-id` rather than emitting a
        // post with an empty author string.
        let html = """
        <html><body>
        <a class="list_item symph-row" href="/service/board/news/19000010"
           data-board-sn="19000010" data-comment-count="0" data-author-id="anonymous_v3">
            <span data-role="list-title-text">닉네임 빠진 글</span>
        </a>
        </body></html>
        """
        let parser = ClienParser()
        let posts = try parser.parseList(html: html, board: .clienNews)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].author, "anonymous_v3")
    }

    // MARK: - Inven

    func testInvenListBasicRowParsesAllFields() throws {
        let html = """
        <html><body>
        <section class="mo-board-list">
        <ul>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/12345">
                <span class="subject">메이플 인벤 글 제목</span>
            </a>
            <span class="layerNickName">메이플유저<span class="maple"></span></span>
            <span class="time">2분전</span>
            <span class="lv">Lv.42</span>
            <span class="view">조회 1,234</span>
            <span class="reco">추천 5</span>
            <a class="com-btn"><span class="num">7</span></a>
        </li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/12346">
                <span class="subject">댓글 0인 글</span>
            </a>
            <span class="layerNickName">다른유저</span>
            <span class="time">10분전</span>
            <a class="com-btn"><span class="num">0</span></a>
        </li>
        </ul>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let posts = try parser.parseList(html: html, board: .invenMaple)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].title, "메이플 인벤 글 제목")
        XCTAssertEqual(posts[0].author, "메이플유저")
        XCTAssertEqual(posts[0].dateText, "2분전")
        XCTAssertEqual(posts[0].levelText, "Lv.42")
        XCTAssertEqual(posts[0].viewCount, 1234, "콤마 포함된 조회수도 숫자만 추출")
        XCTAssertEqual(posts[0].recommendCount, 5)
        XCTAssertEqual(posts[0].commentCount, 7)
        XCTAssertTrue(posts[0].hasAuthIcon, "span.maple 인증 아이콘 감지")
        XCTAssertEqual(posts[0].id, "inven-maple-12345")
        XCTAssertEqual(posts[1].commentCount, 0)
        XCTAssertNil(posts[1].viewCount, "view span 없을 땐 nil")
        XCTAssertNil(posts[1].recommendCount)
        XCTAssertFalse(posts[1].hasAuthIcon)
    }

    func testInvenListSkipsRowsWithoutTitleOrLink() throws {
        // Empty / link-less rows must not surface as ghost posts with
        // blank titles — they're commonly section dividers in inven HTML.
        let html = """
        <html><body>
        <section class="mo-board-list">
        <ul>
        <li class="list"><div class="divider"></div></li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/99999">
                <span class="subject"></span>
            </a>
            <span class="layerNickName">유저</span>
        </li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/77777">
                <span class="subject">유효한 글</span>
            </a>
            <span class="layerNickName">유저</span>
            <a class="com-btn"><span class="num">1</span></a>
        </li>
        </ul>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let posts = try parser.parseList(html: html, board: .invenMaple)
        XCTAssertEqual(posts.count, 1, "title 없는 빈 row 와 contentLink 없는 row 는 모두 skip")
        XCTAssertEqual(posts[0].title, "유효한 글")
    }

    // MARK: - Aagag

    func testAagagMirrorListExtractsSourceTagAndDeduplicates() throws {
        // Mirror entries carry `bc_<site>` on `span.rank`/`span.lo`; the parser
        // strips the prefix and stores the bare site code in `levelText`.
        // Duplicate `ss=` keys (hot reposts at the bottom of issue pages)
        // must collapse to one Post.
        let html = """
        <html><body>
        <table class="aalist">
        <tr>
            <td>
                <a class="article" href="re?ss=ppomppu_111" ss="ppomppu_111">
                    <span class="rank bc_ppomppu">1</span>
                    <span class="title">뽐뿌 인기글<span class="cmt">5</span></span>
                    <span class="date"><u>2분전</u></span>
                    <span class="hit"><u>1,234</u></span>
                    <span class="nick"><u>뽐뿌유저</u></span>
                </a>
            </td>
        </tr>
        <tr>
            <td>
                <a class="article" href="./re?ss=humor_222" ss="humor_222">
                    <span class="rank bc_humor">2</span>
                    <span class="title">웃대 인기글<span class="cmt">12</span></span>
                    <span class="date"><u>5분전</u></span>
                </a>
            </td>
        </tr>
        <tr>
            <td>
                <a class="article" href="re?ss=ppomppu_111" ss="ppomppu_111">
                    <span class="rank bc_ppomppu">3</span>
                    <span class="title">중복 항목</span>
                </a>
            </td>
        </tr>
        </table>
        </body></html>
        """
        let parser = AagagParser()
        let posts = try parser.parseList(html: html, board: .aagag)
        XCTAssertEqual(posts.count, 2, "ss=ppomppu_111 두 건은 dedup 되어 1건으로 합쳐짐")
        XCTAssertEqual(posts[0].title, "뽐뿌 인기글")
        XCTAssertEqual(posts[0].levelText, "ppomppu", "bc_ 접두사 제거된 site 코드")
        XCTAssertEqual(posts[0].commentCount, 5, "title 안의 span.cmt 댓글 수")
        XCTAssertEqual(posts[0].viewCount, 1234)
        XCTAssertEqual(posts[0].author, "뽐뿌유저")
        XCTAssertEqual(posts[0].id, "aagag-ppomppu_111")
        XCTAssertEqual(posts[0].url.path, "/mirror/re", "rawHref 're?...' 가 /mirror/re 로 prefixed")
        XCTAssertEqual(posts[1].title, "웃대 인기글")
        XCTAssertEqual(posts[1].levelText, "humor")
        XCTAssertEqual(posts[1].url.path, "/mirror/re", "'./re?...' 도 동일하게 정규화")
    }

    func testAagagListWithoutSSAttrKeepsStableUniqueIDs() throws {
        // `ss` 속성이 빈 항목이 UUID 기반 id 를 받으면 새로고침마다 identity 가
        // 바뀌어 List diffing 전체 재생성 + 읽음 표시 무효화. URL 기반으로
        // 파싱마다 동일해야 하고, 항목 간에는 고유해야 한다.
        let html = """
        <html><body>
        <table class="aalist">
        <tr><td>
            <a class="article" href="re?idx=111">
                <span class="title">ss 없는 글 하나</span>
            </a>
        </td></tr>
        <tr><td>
            <a class="article" href="re?idx=222">
                <span class="title">ss 없는 글 둘</span>
            </a>
        </td></tr>
        </table>
        </body></html>
        """
        let parser = AagagParser()
        let first = try parser.parseList(html: html, board: .aagag)
        let second = try parser.parseList(html: html, board: .aagag)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "항목 간 id 고유해야 함")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "같은 목록 재파싱 시 id 가 흔들리면 안 됨")
    }

    // MARK: - Title cleanup (broken HTML entity from server-side truncation)

    func testCleanTitleStripsBrokenTrailingEntityFragment() {
        // 82cook's enti.php list truncates by encoded byte length, which can
        // slice in the middle of `&quot;` and produce `…&quo..` — SwiftSoup
        // can't decode the partial fragment so it leaks as literal text.
        XCTAssertEqual(
            ParserText.cleanTitle("최근 주위에 \"힘들다&quo.."),
            "최근 주위에 \"힘들다…"
        )
        XCTAssertEqual(
            ParserText.cleanTitle("어떤 글 &amp..."),
            "어떤 글 …"
        )
        XCTAssertEqual(
            ParserText.cleanTitle("끝 &quot…"),
            "끝 …"
        )
        // Numeric entity (`&#39;` for apostrophe) sliced mid-fragment.
        XCTAssertEqual(
            ParserText.cleanTitle("아빠 &#3.."),
            "아빠 …"
        )
        // Hex numeric entity.
        XCTAssertEqual(
            ParserText.cleanTitle("문자 &#x2..."),
            "문자 …"
        )
        // Digit-bearing named entity (`&sup2;`).
        XCTAssertEqual(
            ParserText.cleanTitle("수식 &sup2..."),
            "수식 …"
        )
    }

    func testCleanTitleLeavesIntactTitlesAlone() {
        // Valid Q&A / Tom&Jerry style titles must NOT be touched — the
        // pattern is anchored by the truncation marker (`..` / `…`).
        XCTAssertEqual(ParserText.cleanTitle("Q&A 정리"), "Q&A 정리")
        XCTAssertEqual(ParserText.cleanTitle("Tom&Jerry"), "Tom&Jerry")
        XCTAssertEqual(
            ParserText.cleanTitle("최근 주위에 \"힘들다\" 토로"),
            "최근 주위에 \"힘들다\" 토로"
        )
        // No `&` short-circuit path.
        XCTAssertEqual(ParserText.cleanTitle("일반 제목"), "일반 제목")
    }

    func testUnescapeJSStringDecodesEscapesAndSurrogatePairs() {
        // Basic escapes.
        XCTAssertEqual(ParserText.unescapeJSString(#"a\nb\tc\\d\/e\"f"#), "a\nb\tc\\d/e\"f")
        // Single `\uXXXX` (BMP) — Korean syllable 한 = U+D55C.
        XCTAssertEqual(ParserText.unescapeJSString(#"한글"#), "한글")
        // Surrogate pair — 🐶 = U+1F436 = 🐶.
        XCTAssertEqual(ParserText.unescapeJSString(#"멍🐶멍"#), "멍🐶멍")
        // Unknown escape passes the second char through (`\'` → `'`).
        XCTAssertEqual(ParserText.unescapeJSString(#"it\'s"#), "it's")
    }

    func testUnescapeJSStringDoesNotEatTextAfterUnpairedSurrogate() {
        // Regression: an unpaired high surrogate must drop only itself, not
        // the characters that follow. The old iterator-based scan consumed
        // the peeked chars and lost them on the bail-out path.
        XCTAssertEqual(ParserText.unescapeJSString(#"\uD83Dabc"#), "abc")
        // High surrogate followed by a non-low-surrogate `\uXXXX`: drop the
        // unpaired high surrogate, keep the valid BMP scalar that follows.
        XCTAssertEqual(ParserText.unescapeJSString(#"\uD83D가"#), "가")
        // Truncated `\u` at end of string passes the backslash through.
        XCTAssertEqual(ParserText.unescapeJSString(#"x\uD"#), #"x\uD"#)
    }

    func testFirstIntegerExtractsLeadingRunWithSeparators() {
        XCTAssertEqual(ParserText.firstInteger(in: "조회 1,234"), 1234)
        XCTAssertEqual(ParserText.firstInteger(in: "  42 회"), 42)
        XCTAssertEqual(ParserText.firstInteger(in: "1,000,000 plus 99"), 1_000_000)
        XCTAssertNil(ParserText.firstInteger(in: "no digits here"))
        XCTAssertNil(ParserText.firstInteger(in: ""))
    }

    func testAagagListCleansBrokenTitleEntity() throws {
        let html = """
        <html><body>
        <table class="aalist">
        <tr><td>
            <a class="article" href="re?ss=cook82_999" ss="cook82_999">
                <span class="rank bc_cook82">1</span>
                <span class="title">최근 주위에 &quot;힘들다&quo..<span class="cmt">5</span></span>
                <span class="date"><u>2분전</u></span>
            </a>
        </td></tr>
        </table>
        </body></html>
        """
        let parser = AagagParser()
        let posts = try parser.parseList(html: html, board: .aagag)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].title, "최근 주위에 \"힘들다…")
    }

    // MARK: - Aagag bot-check detector
    //
    // Pin the heuristic against three samples: a representative challenge
    // body (positive), a short non-challenge response (negative — most
    // important, this is what the retry-false-positive bug would have
    // looked like with the prior OR'd `captcha` substring branch), and
    // a normal list-page-sized body (negative). The detector is
    // intentionally narrow — when the real challenge page is captured
    // in the wild, replace these fixtures with the real markup.

    func testAagagBotCheckDetectorFlagsKoreanChallengeStub() {
        let challenge = """
        <html><body>
        <h2>자동등록방지</h2>
        <p>아래 문자를 입력하세요</p>
        <form><input name="cap" /></form>
        </body></html>
        """
        XCTAssertTrue(AagagParser.looksLikeBotCheck(html: challenge))
    }

    func testAagagBotCheckDetectorDoesNotFlagShortBodyWithoutKoreanPhrase() {
        // The pre-tightened heuristic would have triggered on this body
        // because of the literal "captcha" substring. The AND-on-Korean
        // requirement now rejects it — protecting the post-recovery
        // retry path from throwing `.captchaChallenge` on a short normal
        // response that happens to mention the word.
        let benign = """
        <html><body>
        <p>This page references captcha tooling but isn't a challenge.</p>
        </body></html>
        """
        XCTAssertFalse(AagagParser.looksLikeBotCheck(html: benign))
    }

    func testAagagBotCheckDetectorDoesNotFlagNormalSizedBody() {
        // Even if the Korean phrase appears, a normal-sized page is not
        // the challenge interstitial (real Aagag list / detail pages
        // are tens of KB). Size gate prevents a forum post that quotes
        // the phrase from masquerading as a challenge.
        let body = String(repeating: "x", count: 10_000) + "자동등록방지"
        XCTAssertFalse(AagagParser.looksLikeBotCheck(html: body))
    }

    func testAagagBotCheckDetectorFlagsRealWorldInterstitial() {
        // Captured from a real Aagag bot-check page on 2026-05-25
        // (screenshot via Safari). The page is bilingual — Korean
        // body + an English "judged as a bot" line — and uses none
        // of the keywords the pre-2026-05 detector matched on. Detector
        // must recognise at least one of the actual markers or the
        // sheet never fires and the user sees raw "HTTP 303".
        let interstitial = """
        <html><body>
        <p>봇으로 판단되었습니다.</p>
        <p>judged as a bot.</p>
        <p>계속 이용하시려면 Captcha인증을 통과해야 합니다.</p>
        <form><img src="cap.png"><input name="cap"><button>submit</button></form>
        </body></html>
        """
        XCTAssertTrue(AagagParser.looksLikeBotCheck(html: interstitial))
    }

    // MARK: - Bot-check status-code surface

    func testBotCheckRegistryFlags303ForAagagHost() {
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_123")!
        XCTAssertTrue(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 303))
    }

    func testBotCheckRegistryDoesNotFlagSuccessOrNotFoundForAagag() {
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_123")!
        XCTAssertFalse(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 200))
        XCTAssertFalse(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 404))
        XCTAssertFalse(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 500))
    }

    func testBotCheckRegistryIgnoresUnrelatedHostsAt303() {
        // 303 from any other site is a normal redirect signal we don't
        // want to mistake for a challenge. Bot-check surface stays
        // host-scoped to keep noise off other parsers.
        let url = URL(string: "https://www.clien.net/service/board/park")!
        XCTAssertFalse(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 303))
    }

    func testBotCheckRegistryRejectsImpostorHostnameAt303() {
        // `not-aagag.com` ends with `aagag.com` but is a different
        // registered domain. A pre-fix `hasSuffix("aagag.com")` would
        // misroute its 303 into the captcha sheet.
        let url = URL(string: "https://not-aagag.com/foo")!
        XCTAssertFalse(BotCheckRegistry.statusIndicatesChallenge(for: url, status: 303))
    }

    // MARK: - Host-matching helper

    func testSiteHostMatchesExactAndSubdomain() {
        XCTAssertTrue(Site.host("aagag.com", matches: "aagag.com"))
        XCTAssertTrue(Site.host("www.aagag.com", matches: "aagag.com"))
        XCTAssertTrue(Site.host("a.b.aagag.com", matches: "aagag.com"))
    }

    func testSiteHostRejectsSuffixImpostors() {
        // The whole point of the helper: refuse hosts whose suffix
        // *happens* to be the domain but live under a different
        // registered owner.
        XCTAssertFalse(Site.host("not-aagag.com", matches: "aagag.com"))
        XCTAssertFalse(Site.host("evilaagag.com", matches: "aagag.com"))
    }

    func testSiteHostIsCaseInsensitive() {
        XCTAssertTrue(Site.host("AAGAG.COM", matches: "aagag.com"))
        XCTAssertTrue(Site.host("Www.Aagag.Com", matches: "aagag.com"))
    }

    func testSiteHostRejectsNil() {
        XCTAssertFalse(Site.host(nil, matches: "aagag.com"))
    }

    // MARK: - Bot-check status-surface catch path
    //
    // Drives `recoverFromBotCheckStatus` in isolation so the
    // catch-and-recover contract is verified without a real URLSession
    // or a real `BotCheckCoordinator` sheet. The challenger is the
    // side-effecting seam — in production it presents the SwiftUI
    // captcha sheet; here we record the URLs it received.

    private actor ChallengerSpy {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    func testRecoverFromBotCheckStatusReturnsRetryBodyAndInvokesChallenger() async throws {
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_1")!
        let spy = ChallengerSpy()

        let body = try await Networking.recoverFromBotCheckStatus(
            url: url,
            error: NetworkError.badResponse(303),
            retry: { "<html>real body content well past 5KB " + String(repeating: "x", count: 6000) + "</html>" },
            detector: AagagParser.looksLikeBotCheck(html:),
            challenger: { await spy.record($0) }
        )

        XCTAssertTrue(body.contains("real body content"))
        let recorded = await spy.urls
        XCTAssertEqual(recorded, [url])
    }

    func testRecoverFromBotCheckStatusConvertsRetry303IntoCaptchaChallenge() async {
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_1")!

        do {
            _ = try await Networking.recoverFromBotCheckStatus(
                url: url,
                error: NetworkError.badResponse(303),
                retry: { throw NetworkError.badResponse(303) },
                detector: AagagParser.looksLikeBotCheck(html:),
                challenger: { _ in }
            )
            XCTFail("expected captchaChallenge throw")
        } catch let NetworkError.captchaChallenge(failedURL) {
            XCTAssertEqual(failedURL, url)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRecoverFromBotCheckStatusConvertsRetryDetectorPositiveIntoCaptchaChallenge() async {
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_1")!

        do {
            _ = try await Networking.recoverFromBotCheckStatus(
                url: url,
                error: NetworkError.badResponse(303),
                retry: { "<html><p>봇으로 판단되었습니다</p></html>" },
                detector: AagagParser.looksLikeBotCheck(html:),
                challenger: { _ in }
            )
            XCTFail("expected captchaChallenge throw")
        } catch let NetworkError.captchaChallenge(failedURL) {
            XCTAssertEqual(failedURL, url)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRecoverFromBotCheckStatusPassesThroughNonChallengeError() async {
        let url = URL(string: "https://aagag.com/x")!

        do {
            _ = try await Networking.recoverFromBotCheckStatus(
                url: url,
                error: NetworkError.badResponse(500),
                retry: { XCTFail("retry must not run for non-challenge error"); return "" },
                detector: AagagParser.looksLikeBotCheck(html:),
                challenger: { _ in XCTFail("challenger must not run for non-challenge error") }
            )
            XCTFail("expected re-throw")
        } catch NetworkError.badResponse(let code) where code == 500 {
            // expected: passes the error through untouched
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRecoverFromBotCheckStatusPassesThroughNon303BadResponse() async {
        // Even on the bot-check-registered host, only the registered
        // status codes route to the challenge surface. A 500 must
        // bubble up like any other server error.
        let url = URL(string: "https://aagag.com/mirror/re?ss=humor_1")!

        do {
            _ = try await Networking.recoverFromBotCheckStatus(
                url: url,
                error: NetworkError.badResponse(404),
                retry: { "" },
                detector: AagagParser.looksLikeBotCheck(html:),
                challenger: { _ in XCTFail("challenger must not run for non-challenge status") }
            )
            XCTFail("expected re-throw")
        } catch NetworkError.badResponse(let code) where code == 404 {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
