import XCTest
import SDWebImage
import UIKit
@testable import nunting

/// `NetworkImage` 의 다운샘플 박스 매핑 계약.
///
/// 본문 사진은 그동안 풀사이즈 디코드였다 — 정사각 thumbnail 캡이 aagag
/// 세로 패널(800×6000)의 긴 변을 깎아 뭉개버리기 때문. 비정방 박스(폭만
/// 화면폭 px, 높이는 넉넉한 캡)는 통상 세로 패널을 무손실 통과시키면서
/// 일반 대형 사진(4000×3000)은 화면폭으로, 초대형 패널(수만 px)은 높이
/// 캡으로 다운샘플한다 — 무제한 높이는 30MP 풀 디코드(메모리 스파이크 +
/// ImageIO 락 hang)를 그대로 통과시켰다.
final class NetworkImageThumbnailTests: XCTestCase {
    func testSquareCapKeepsLegacyBehavior() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: 100, maxPointWidth: nil, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 300, height: 300), "기존 정사각 캡: 포인트×스케일")
    }

    func testWidthOnlyBoxCapsWidthAndTallHeight() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size?.width, 1179, "폭 = 화면폭 pt × scale")
        XCTAssertEqual(size?.height, NetworkImage.tallImageMaxPixelHeight,
            "높이 캡 = 통상 세로 패널(800×6000)은 무손실 통과할 만큼 넉넉하되, 수만 px 패널의 풀 디코드는 차단")
        XCTAssertGreaterThanOrEqual(size?.height ?? 0, 6000,
            "문서화된 aagag 세로 패널(800×6000)이 높이 캡에 걸려 폭까지 깎이면 안 됨")
    }

    func testSquareCapWinsWhenBothSet() {
        // 기존 호출부(아이콘/스티커/포스터) 보호 — 정사각 캡이 우선.
        let ctx = NetworkImage.thumbnailContext(maxPointSize: 100, maxPointWidth: 393, scale: 2)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 200, height: 200))
    }

    func testNoCapsReturnsNilContext() {
        XCTAssertNil(NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: nil, scale: 3),
                     "캡 없음 = 네이티브 해상도 디코드 (context 자체가 nil)")
    }

    // MARK: - aspect 인지 tall 박스 (화질 재배분)

    /// 극단 세로형(예: 800×24000, aspect 1/30)은 고정 (폭, 8192) 박스가 폭을
    /// 8192/24000 비율로 같이 깎아 273px 로 디코드했다 — 화면폭으로 4.4배
    /// 업스케일되며 글자가 뭉개지는 실사용 화질 버그(aagag 이슈 짤).
    /// aspect 를 알면 같은 픽셀 버짓(폭px×8192) 안에서 폭↓·높이↑ 재배분한다.
    func testTallAspectReallocatesBudgetToHeight() throws {
        let ctx = NetworkImage.thumbnailContext(
            maxPointSize: nil, maxPointWidth: 402, aspect: 1.0 / 30.0, scale: 3)
        let size = try XCTUnwrap((ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue)

        XCTAssertEqual(size.height, NetworkImage.tallImageHardMaxPixelHeight,
                       "높이를 hard max(16384)까지 벌린다")
        // 폭 = min(화면폭, sqrt(버짓×aspect)) — 1206×8192 버짓에서 ≈574.
        XCTAssertEqual(size.width, (1206.0 * 8192.0 / 30.0).squareRoot(), accuracy: 1.0)
        XCTAssertLessThanOrEqual(size.width * size.height, 1206.0 * 8192.0 * 1.01,
                                 "총픽셀은 종전 worst-case(폭px×8192) 이하 유지")
    }

    /// 통상 세로 패널(800×6000급)·일반 사진은 aspect 를 알아도 종전 박스 유지 —
    /// native-width 디코드에 8192 가 이미 충분하므로 동작 변화 없음.
    func testNonExtremeAspectKeepsLegacyBox() {
        let ctx = NetworkImage.thumbnailContext(
            maxPointSize: nil, maxPointWidth: 402, aspect: 4.0 / 3.0, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 1206, height: NetworkImage.tallImageMaxPixelHeight))
    }

    /// aspect 미상(파서 미제공 + 미디코드)은 종전과 동일한 legacy 박스.
    func testNilAspectKeepsLegacyBox() {
        let ctx = NetworkImage.thumbnailContext(
            maxPointSize: nil, maxPointWidth: 402, aspect: nil, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 1206, height: NetworkImage.tallImageMaxPixelHeight))
    }

    // MARK: - natural width 갱신 규칙

    /// 극단 세로형은 1차(흐린) 디코드 폭이 natural width 로 래치되면
    /// clampsToNaturalWidth 가 2차 선명 디코드 후에도 프레임을 1차 폭
    /// (예: 212pt)에 묶는다 — "본문에서 가로가 꽉 안 참" 기기 실측 버그.
    /// 더 큰(선명한) 디코드가 오면 natural width 도 따라 커져야 한다.
    func testNaturalWidthGrowsWithSharperDecode() {
        XCTAssertEqual(NetworkImage.resolvedNaturalWidth(current: nil, incoming: 212), 212)
        XCTAssertEqual(NetworkImage.resolvedNaturalWidth(current: 212, incoming: 425), 425,
                       "2차 디코드가 더 크면 갱신")
        XCTAssertEqual(NetworkImage.resolvedNaturalWidth(current: 425, incoming: 212), 425,
                       "더 작은 값(캐시된 1차 등)으로 되돌아가면 안 됨")
    }

    // MARK: - 실제 디코드 검증 (context 값이 아니라 decode output 을 핀)

    /// context 값 매핑만 믿지 않고, 생성한 PNG 를 SDImageIOCoder 로 실제
    /// 디코드해 출력 비트맵이 박스 계약을 지키는지 확인한다 — 프로덕션과
    /// 같은 coder 경로(`.imageThumbnailPixelSize` → `decodeThumbnailPixelSize`).
    private func decodeWithWidthBox(_ png: Data) -> UIImage? {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        guard let box = ctx?[.imageThumbnailPixelSize] as? NSValue else { return nil }
        return SDImageIOCoder.shared.decodedImage(with: png, options: [
            .decodeThumbnailPixelSize: box,
            .decodePreserveAspectRatio: true,  // 파이프라인 기본값을 명시적으로 고정
        ])
    }

    private func flatPNG(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixelSize(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testRealDecodeOfExtremeTallImageIsBoundedByHeightCap() throws {
        // 폭(300)이 화면폭 캡(1179) 이하라 폭 캡을 우회하는 초대형 세로 패널 —
        // 높이 캡이 없으면 6MP 통과(실환경에선 30MP 급). 캡 적용 시 비율 유지
        // 축소로 박스 안에 들어와야 한다.
        let decoded = try XCTUnwrap(decodeWithWidthBox(flatPNG(width: 300, height: 20000)))
        let px = pixelSize(decoded)
        XCTAssertLessThanOrEqual(px.height, NetworkImage.tallImageMaxPixelHeight,
                                 "초대형 세로 패널의 실제 디코드 높이는 캡 이하")
        XCTAssertLessThanOrEqual(px.width, 1179, "폭도 박스 안")
        XCTAssertLessThan(px.height, 20000, "풀 디코드(무캡 회귀) 방지")
        XCTAssertEqual(px.width / px.height, 300.0 / 20000.0, accuracy: 0.01,
                       "비율 유지 다운샘플 (왜곡 없음)")
    }

    func testRealDecodeOfTypicalTallPanelPassesLossless() throws {
        // 원 설계가 보호하려던 aagag 세로 패널(800×6000) — 높이 캡(8192) 아래라
        // 다운샘플 없이 원본 해상도 그대로 나와야 한다.
        let decoded = try XCTUnwrap(decodeWithWidthBox(flatPNG(width: 800, height: 6000)))
        XCTAssertEqual(pixelSize(decoded), CGSize(width: 800, height: 6000),
                       "통상 세로 패널은 무손실 통과 (높이 캡이 실효 캡이 되면 안 됨)")
    }
}
