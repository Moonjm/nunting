import XCTest
@testable import nunting

/// Aagag 댓글 첨부 분류 — 이미지 vs 영상.
///
/// Aagag 은 댓글의 gif/영상 첨부를 `<img>` 태그로 내려보내지만 src 가
/// 실제로는 mp4 파일이다 (`<img src=https://i.aagag.com/IZbvG.mp4?v=1>`,
/// aagag.com/issue/?idx=1633837 의 댓글에서 확인). 이걸 stickerURL 로
/// 분류하면 이미지 디코더가 영원히 실패해 "다시 시도" 플레이스홀더만
/// 남는다 — mp4 src 는 videoURL 로 라우팅해 InlineVideoPlayer 로 재생해야
/// 한다.
final class AagagCommentAttachmentTests: XCTestCase {

    private let parser = AagagParser()

    func testMP4ImgSrcRoutesToVideoURL() {
        // 실제 응답 그대로: 따옴표 없는 src + 쿼리스트링 + 뒤따르는 텍스트.
        let html = "<img src=https://i.aagag.com/IZbvG.mp4?v=1><br><br>자 이제 다음 전술은 뭐죠?"
        let attachment = parser.commentAttachmentURLs(fromHTML: html)
        XCTAssertEqual(
            attachment.video?.absoluteString,
            "https://i.aagag.com/IZbvG.mp4?v=1",
            "mp4 src 는 videoURL 로 가야 InlineVideoPlayer 가 재생한다"
        )
        XCTAssertNil(attachment.sticker, "영상 첨부가 stickerURL 로도 새면 이미지 로드 실패 UI 가 같이 뜬다")
    }

    func testUppercaseExtensionStillRoutesToVideo() {
        // 확장자 비교는 case-insensitive 여야 한다 — `.lowercased()` 가
        // "단순화"로 제거되면 여기서 잡는다.
        let html = "<img src=\"https://i.aagag.com/IZbvG.MP4\">"
        let attachment = parser.commentAttachmentURLs(fromHTML: html)
        XCTAssertNotNil(attachment.video)
        XCTAssertNil(attachment.sticker)
    }

    func testStillImageSrcStaysSticker() {
        let html = "<img src=\"https://i.aagag.com/abCdE.jpg\"> 움짤 아님"
        let attachment = parser.commentAttachmentURLs(fromHTML: html)
        XCTAssertEqual(attachment.sticker?.absoluteString, "https://i.aagag.com/abCdE.jpg")
        XCTAssertNil(attachment.video)
    }

    func testGifImageSrcStaysSticker() {
        // 진짜 .gif 파일은 SDWebImage 가 애니메이션으로 디코딩하므로 이미지 경로 유지.
        let html = "<img src=\"https://i.aagag.com/abCdE.gif\">"
        let attachment = parser.commentAttachmentURLs(fromHTML: html)
        XCTAssertEqual(attachment.sticker?.absoluteString, "https://i.aagag.com/abCdE.gif")
        XCTAssertNil(attachment.video)
    }

    func testTextOnlyCommentHasNoAttachment() {
        let attachment = parser.commentAttachmentURLs(fromHTML: "그냥 텍스트 댓글")
        XCTAssertNil(attachment.sticker)
        XCTAssertNil(attachment.video)
    }
}
