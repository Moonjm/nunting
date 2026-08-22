import Foundation

/// WebP 헤더에서 정적/애니메를 가른다.
///
/// 쓰는 곳: `SignpostWebPCoder` 가 **정적** WebP 만 ImageIO 로 돌린다. 픽셀당 디코드
/// 비용이 libwebp 98ms/MP vs ImageIO 19~44ms/MP 라(기기 계측 2026-08-21) 화질을 안
/// 깎고 디코드 CPU 를 줄일 수 있는 유일한 축이다. 애니메 WebP 는 libwebp 가 유리하다는
/// 기존 실측(2-3배)이 있어 그대로 둔다.
///
/// 판별 규칙(RIFF/WebP 컨테이너 규격):
/// - `RIFF` + 크기 4바이트 + `WEBP` 다음이 첫 청크.
/// - `VP8X`(확장 헤더)면 그 뒤 첫 바이트가 플래그이고 **0x02 비트가 애니메이션**이다.
/// - `VP8 `(손실)·`VP8L`(무손실)이면 확장 헤더 자체가 없으므로 정적이다.
///
/// 애매하면 **애니메로 간주한다**. 오판의 대가가 비대칭이라서다 — 애니메를 정적으로
/// 잘못 보면 움짤이 깨지고, 정적을 애니메로 잘못 보면 그냥 종전만큼 느릴 뿐이다.
nonisolated enum WebPFormat {

    static func isAnimated(_ data: Data) -> Bool {
        // 검사 순서가 중요하다: **WebP 인지 먼저** 보고, 그다음 잘렸는지 본다.
        // 순서가 뒤집히면 짧은 non-WebP 데이터(예: 4바이트 JPEG 조각)가 "판별 불가"로
        // 묶여 애니메 WebP 취급을 받는다.
        guard data.count >= 4 else { return true }   // 아무것도 모른다 → 안전한 쪽
        guard data.prefix(4).elementsEqual(Array("RIFF".utf8)) else { return false }

        // 첫 청크의 플래그 바이트까지 읽으려면 21바이트가 필요하다(0..<12 컨테이너,
        // 12..<16 청크 태그, 16..<20 청크 크기, 20 플래그).
        guard data.count >= 16 else { return true }  // RIFF 인데 잘렸다 → 안전한 쪽
        guard data[data.startIndex + 8 ..< data.startIndex + 12]
            .elementsEqual(Array("WEBP".utf8)) else { return false }

        let chunk = data[data.startIndex + 12 ..< data.startIndex + 16]
        guard chunk.elementsEqual(Array("VP8X".utf8)) else {
            // 단순 컨테이너(`VP8 ` / `VP8L`) — 확장 헤더가 없으니 정적.
            return false
        }
        guard data.count >= 21 else { return true }  // VP8X 인데 플래그가 안 왔다
        let flags = data[data.startIndex + 20]
        return flags & 0x02 != 0
    }
}
