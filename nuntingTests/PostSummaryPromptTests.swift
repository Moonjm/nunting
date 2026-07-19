import XCTest
@testable import nunting

/// 온디바이스 요약 프롬프트 조립 회귀 테스트. 온디바이스 모델 컨텍스트가
/// 작아(iOS 26 기준 ~4K 토큰, 한국어 ~1.5-2자/토큰) 본문·댓글 예산이
/// 핵심 로직이다 — 예산 초과 입력이 그대로 들어가면 세션이
/// exceededContextWindowSize 로 통째로 실패한다.
final class PostSummaryPromptTests: XCTestCase {

    private func detail(
        blocks: [ContentBlock],
        comments: [PostComment] = []
    ) -> PostDetail {
        PostDetail(
            post: .fixture(title: "테스트 글 제목"),
            blocks: blocks,
            fullDateText: nil,
            viewCount: nil,
            source: nil,
            comments: comments,
            fullTitle: "테스트 글 제목"
        )
    }

    private func comment(_ content: String, likes: Int, id: Int = .random(in: 1...99999)) -> PostComment {
        PostComment(
            id: "c-\(id)", author: "작성자\(id)", dateText: "",
            content: content, likeCount: likes, isReply: false
        )
    }

    // MARK: - 본문 추출

    func testBodyTextJoinsRichTextAndLinkLabelsSkippingMedia() {
        let blocks: [ContentBlock] = [
            .richText([.text("첫 문단"), .link(url: URL(string: "https://a.b")!, label: "링크라벨")]),
            .image(URL(string: "https://img.example/1.jpg")!),
            .video(URL(string: "https://vid.example/1.mp4")!),
            .text("둘째 문단"),
        ]
        let text = PostSummaryPrompt.bodyText(from: blocks)
        XCTAssertTrue(text.contains("첫 문단"))
        XCTAssertTrue(text.contains("링크라벨"))
        XCTAssertTrue(text.contains("둘째 문단"))
        XCTAssertFalse(text.contains("img.example"), "미디어 URL 은 본문 텍스트가 아니다")
    }

    // MARK: - 예산

    func testBuildTruncatesLongBody() {
        let long = String(repeating: "가", count: PostSummaryPrompt.maxBodyChars + 500)
        let prompt = PostSummaryPrompt.build(detail: detail(blocks: [.text(long)]))
        // 본문 문자 예산 + 프레이밍 여유 안쪽이어야 한다.
        XCTAssertLessThan(prompt.count, PostSummaryPrompt.maxBodyChars + 400)
        XCTAssertTrue(prompt.contains("테스트 글 제목"))
    }

    func testBuildPicksTopLikedCommentsWithinCap() {
        // 내용 마커에 종결 문자(.)를 붙여 "댓글내용1." 이 "댓글내용10." 의
        // 부분문자열로 오탐되지 않게 한다.
        let comments = (1...10).map { i in
            self.comment("댓글내용\(i).", likes: i, id: i)
        }
        let prompt = PostSummaryPrompt.build(detail: detail(blocks: [.text("본문")], comments: comments))
        // 공감 상위 5개(6..10)만 포함, 하위(1..5)는 제외.
        for i in 6...10 { XCTAssertTrue(prompt.contains("댓글내용\(i)."), "상위 댓글 \(i) 누락") }
        for i in 1...5 { XCTAssertFalse(prompt.contains("댓글내용\(i)."), "하위 댓글 \(i) 이 포함됨") }
    }

    func testBuildTruncatesEachCommentToCharCap() {
        let long = String(repeating: "나", count: PostSummaryPrompt.maxCommentChars + 200)
        let prompt = PostSummaryPrompt.build(detail: detail(blocks: [.text("본문")], comments: [comment(long, likes: 1)]))
        let run = prompt.split(separator: "\n").first { $0.contains("나나") } ?? ""
        XCTAssertLessThan(run.count, PostSummaryPrompt.maxCommentChars + 50)
    }

    func testBuildOmitsCommentsSectionWhenEmpty() {
        let prompt = PostSummaryPrompt.build(detail: detail(blocks: [.text("본문만")]))
        XCTAssertFalse(prompt.contains("댓글"), "댓글 없으면 댓글 섹션 자체가 없어야 한다")
    }

    // MARK: - 자동 요약 판정

    /// 임계 미만 글은 요약 UI 자체가 뜨지 않는다 — 한눈에 읽히는 글에서
    /// 요약은 노이즈고, 자동 실행이라 짧은 글마다 생성을 도는 낭비도 크다.
    func testQualifiesForAutoSummaryByBodyLength() {
        let short = detail(blocks: [.text(String(repeating: "가", count: PostSummaryPrompt.autoSummarizeMinChars - 1))])
        XCTAssertFalse(PostSummaryPrompt.qualifiesForAutoSummary(short))

        let long = detail(blocks: [.text(String(repeating: "가", count: PostSummaryPrompt.autoSummarizeMinChars))])
        XCTAssertTrue(PostSummaryPrompt.qualifiesForAutoSummary(long))
    }

    /// 판정 기준은 텍스트 길이 — 이미지 개수/URL 은 본문 길이에 안 섞인다.
    func testQualifiesIgnoresMediaBlocks() {
        let imageHeavy = detail(blocks: [
            .text("짧은 캡션"),
            .image(URL(string: "https://img.example/very-long-url-that-should-not-count-1.jpg")!),
            .image(URL(string: "https://img.example/very-long-url-that-should-not-count-2.jpg")!),
        ])
        XCTAssertFalse(PostSummaryPrompt.qualifiesForAutoSummary(imageHeavy))
    }
}
