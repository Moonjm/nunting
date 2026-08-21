import XCTest
@testable import nunting

/// `WebPFormat.isAnimated` — 정적/애니메 WebP 판별.
///
/// 왜 필요한가: 픽셀당 디코드 비용이 libwebp 98ms/MP, ImageIO 19~44ms/MP 다. 정적
/// WebP 만 ImageIO 로 보내면 화질을 안 깎고 디코드 CPU 를 줄일 수 있다. 반대로 애니메
/// WebP 는 libwebp 가 유리하다는 기존 실측(2-3배)이 있어 그대로 둬야 한다.
///
/// **오판의 대가가 크다**: 애니메를 정적으로 잘못 보면 움짤이 정지컷이 되거나 디코드가
/// 실패한다. 그래서 헤더 규격대로 판별하고 경계를 전부 테스트로 잠근다.
final class WebPFormatTests: XCTestCase {

    /// RIFF 컨테이너 한 겹. `chunk` 는 첫 청크 4바이트, `payload` 는 그 뒤 바이트.
    private func webp(chunk: String, payload: [UInt8] = []) -> Data {
        var bytes: [UInt8] = Array("RIFF".utf8)
        bytes += [0, 0, 0, 0]                 // 파일 크기(판별에 안 쓴다)
        bytes += Array("WEBP".utf8)
        bytes += Array(chunk.utf8)
        bytes += [0, 0, 0, 0]                 // 청크 크기
        bytes += payload
        return Data(bytes)
    }

    /// VP8X 확장 헤더의 애니메이션 비트(0x02)가 서면 애니메다.
    func testDetectsAnimatedFromVP8XAnimationFlag() {
        let data = webp(chunk: "VP8X", payload: [0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(WebPFormat.isAnimated(data))
    }

    /// VP8X 여도 애니메 비트가 없으면 정적이다(알파/EXIF 만 있는 확장 헤더).
    func testVP8XWithoutAnimationFlagIsStatic() {
        // 0x10 = 알파 비트만.
        let data = webp(chunk: "VP8X", payload: [0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(WebPFormat.isAnimated(data))
    }

    /// 확장 헤더가 없는 평범한 정적 WebP.
    func testSimpleLossyIsStatic() {
        XCTAssertFalse(WebPFormat.isAnimated(webp(chunk: "VP8 ", payload: [0, 0, 0, 0])))
    }

    func testSimpleLosslessIsStatic() {
        XCTAssertFalse(WebPFormat.isAnimated(webp(chunk: "VP8L", payload: [0, 0, 0, 0])))
    }

    /// WebP 가 아니면 판별 대상이 아니다 — "정적" 으로 답해 ImageIO 로 보내면 안 되고,
    /// 애초에 이 경로를 타지 않게 false 를 준다(호출부가 libwebp 로 그대로 넘긴다).
    func testNonWebPDataIsNotAnimated() {
        XCTAssertFalse(WebPFormat.isAnimated(Data([0xFF, 0xD8, 0xFF, 0xE0])))  // JPEG
    }

    /// 잘린 데이터(프로그레시브 수신 중 등)에서 인덱스 밖을 읽으면 크래시다.
    /// 판별이 불가능하면 애니메로 **간주**한다 — libwebp 로 가면 최악이 느린 것이지만,
    /// 정적으로 오판해 ImageIO 로 보내면 움짤이 깨진다.
    func testTruncatedDataIsTreatedAsAnimated() {
        XCTAssertTrue(WebPFormat.isAnimated(Data(Array("RIFF".utf8))))
        XCTAssertTrue(WebPFormat.isAnimated(Data()))
        // VP8X 라고만 하고 플래그 바이트가 없는 경우.
        var bytes: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        bytes += Array("VP8X".utf8)
        XCTAssertTrue(WebPFormat.isAnimated(Data(bytes)))
    }
}
