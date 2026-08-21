import Foundation
import MetricKit
import os
import UIKit
import SDWebImage
import SDWebImageWebPCoder

/// MetricKit 시그포스트 핸들. 여기 이름으로 묶인 구간의 누적 CPU/지속시간이
/// `MXMetricPayload.signpostMetrics` 에 집계돼(심볼리케이션·dSYM 불필요) 기존
/// MetricsReporter 파이프라인으로 서버 `metric_payloads` 에 올라간다.
///
/// 배경: cpuException 진단(6/27, 93초 중 90초 CPU)이 백그라운드 큐의 이미지
/// 디코드(앱 바이너리 82% — 정적 링크된 libwebp 포함 + ImageIO 16%)를 가리켰는데,
/// payload 가 주소/오프셋뿐이라 어느 디코드가 CPU 를 먹는지 함수명으로 못 봤다.
/// 디코드 구간에 이름표를 달아 다음 payload 에서 "webpStatic/webpFrame" 의
/// CPU 기여도를 이름으로 확인한다.
// nonisolated: OSLog 핸들은 스레드 세이프 불변값 — SD 백그라운드 디코드 큐의
// SignpostWebPCoder(nonisolated)가 읽으므로 기본 MainActor 격리에서 뺀다.
nonisolated enum AppSignpost {
    static let image = MXMetricManager.makeLogHandle(category: "imageDecode")
}

/// `SDImageWebPCoder` 를 상속해 디코드 호출 앞뒤에 mxSignpost 만 끼운다. 디코드
/// 로직은 `super` 그대로 호출 — 라이브러리 수정/포크 아님. `SDWebImageSetup` 이
/// 이 인스턴스를 등록하면 SDWebImage 가 이 override 를 거쳐 디코드하므로, 정적
/// WebP 디코드(`decodedImage`)와 애니메 WebP 프레임 디코드(`animatedImageFrame`)
/// 의 CPU 가 각각 잡힌다. 동시 디코드가 겹쳐도 구간마다 고유 signpostID 라
/// begin/end 가 정확히 짝지어진다.
// `nonisolated`: 부모(SDImageWebPCoder)의 init/디코드 선언이 nonisolated 라,
// 기본 MainActor 격리 추론이 붙은 오버라이드는 Swift 6 모드에서 "different
// actor isolation" 에러가 된다. 디코드는 SD 의 백그라운드 큐에서 돈다.
nonisolated final class SignpostWebPCoder: SDImageWebPCoder {

    override func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? {
        let id = OSSignpostID(log: AppSignpost.image)
        mxSignpost(.begin, log: AppSignpost.image, name: "webpStatic", signpostID: id)
        defer { mxSignpost(.end, log: AppSignpost.image, name: "webpStatic", signpostID: id) }
        // 시그포스트는 MetricKit 의 하루 배치라 즉시 못 본다. 같은 구간을 벽시계로도
        // 재서 media 채널로 올린다 — "느린 게 디코드 자체냐, 디코드를 기다리는
        // 큐냐"를 show/net/queued 와 나란히 놓고 갈라야 한다.
        // **정적 WebP 는 ImageIO 로 돌린다.** 픽셀당 디코드 비용이 libwebp 98ms/MP vs
        // ImageIO 19~44ms/MP 였다(기기 계측 2026-08-21). 이 파이프라인은 디코드 CPU 에
        // 묶여 있고(병렬화 시도 3전 3패, `SDWebImageSetup` 주석의 표들), 총 디코드
        // 시간이 곧 체감의 하한이라(34장 합계 5,948ms ≈ 본문 show p90 5,785ms)
        // 장당 비용을 깎는 게 화질을 안 건드리는 유일한 축이다.
        //
        // 애니메는 그대로 libwebp — 다중 프레임에선 libwebp 가 2-3배 빠르다는 기존
        // 실측이 있고, 그게 애초에 이 코더를 등록한 이유다.
        //
        // ImageIO 가 nil 을 주면 libwebp 로 폴백한다. 코더 선택(`canDecode`)을
        // 건드리지 않고 여기서 갈라야 하는 이유가 이 폴백이다 — `canDecode` 에서
        // 거절하면 ImageIO 가 실패했을 때 되돌아올 곳이 없어 이미지가 통째로 깨진다.
        // 라이브러리의 공용 ImageIO 코더를 직접 쓴다. 우리 `SignpostIOCoder` 로 보내면
        // `ioStatic` 으로 기록돼 JPEG/PNG 와 섞이는데, 정작 재려는 건 "WebP 를 ImageIO 로
        // 돌렸을 때" 의 비용이라 표에서 갈려야 한다 — 여기서 `webpViaIO` 로 따로 남긴다.
        if let data, !WebPFormat.isAnimated(data) {
            // **지연 디코드를 끈다.** 정적 코더의 기본값은 lazy(YES)이고
            // (`SDImageCoder.h:73`), 그러면 비용이 사라지는 게 아니라 픽셀을 처음
            // 만지는 시점 — 즉 CoreAnimation 이 레이어를 그리는 **메인 스레드** — 으로
            // 옮겨간다. 헤더가 그 대가를 명시한다("consumer may access bitmap buffer
            // when running on main queue, like CoreAnimation layer render image").
            //
            // 실제로 이 경로를 켠 첫 세션에서 디코드 합계가 5,948ms → 19ms 로 찍혔는데
            // 본문 show p90 은 5,785 → 5,208ms(10%)에 그쳤다. 비용이 우리 계측 밖으로
            // 나간 것이지 없어진 게 아니라는 뜻이다. 끄면 진짜 비용이 여기 잡히고,
            // 메인 스레드로 새는 것도 막는다.
            var eager = options ?? [:]
            eager[.decodeUseLazyDecoding] = false
            let startedAt = Date()
            if let image = SDImageIOCoder.shared.decodedImage(with: data, options: eager) {
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                let event = MediaLoadEventDTO.decode(kind: "webpViaIO", ms: ms,
                                                     pixels: Self.pixelCount(of: image),
                                                     bytes: data.count)
                Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
                return image
            }
        }

        // 애니메로 판정된 WebP 는 여기(libwebp)로 온다. 판정 결과를 데이터에 남긴다 —
        // 파서 라벨은 확장자로만 세서 애니메 WebP 가 정적 WebP 와 `webp=` 안에 섞여
        // 있고, 그래서 "움짤 글을 찾아 열어본다" 는 확인 방법이 통하지 않는다.
        // 평소처럼 쓰다 애니메를 만나면 이 이벤트가 찍히고, 그게 libwebp 로 갔다는
        // 사실까지 같이 확인된다.
        if let data, WebPFormat.isAnimated(data) {
            let marker = MediaLoadEventDTO.decode(kind: "webpAnimated", ms: 0,
                                                  pixels: 0, bytes: data.count)
            Task { @MainActor in MediaLoadTelemetry.shared.record(marker) }
        }

        let startedAt = Date()
        let image = super.decodedImage(with: data, options: options)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let pixels = Self.pixelCount(of: image)
        let event = MediaLoadEventDTO.decode(kind: "webpStatic", ms: ms,
                                             pixels: pixels,
                                             bytes: data?.count ?? 0)
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
        return image
    }

    /// 디코드 **출력** 픽셀 수. 다운샘플(`imageThumbnailPixelSize`)이 걸리면 원본이
    /// 아니라 이 값이 비용을 대표한다. `cgImage` 가 없으면(드묾) point×scale 로 환산.
    static func pixelCount(of image: UIImage?) -> Int {
        guard let image else { return 0 }
        if let cg = image.cgImage { return cg.width * cg.height }
        return Int(image.size.width * image.scale * image.size.height * image.scale)
    }

    override func animatedImageFrame(at index: UInt) -> UIImage? {
        let id = OSSignpostID(log: AppSignpost.image)
        mxSignpost(.begin, log: AppSignpost.image, name: "webpFrame", signpostID: id)
        defer { mxSignpost(.end, log: AppSignpost.image, name: "webpFrame", signpostID: id) }
        // **표시 경로의 진짜 디코드가 여기다.** SDWebImageSwiftUI 의 `AnimatedImage` 는
        // 컨텍스트에 `animatedImageClass = SDAnimatedImage` 를 심으므로
        // (AnimatedImage.swift:255) 본문/아이콘 이미지는 `decodedImage(with:)` 가 아니라
        // 애니메 코더 경로로 열린다. 정적 WebP 도 마찬가지라 frame 0 디코드가 곧 그 이미지의
        // 전체 디코드 비용이다. 프레임 0 만 재는 이유: 움짤은 100~300 프레임이라 전 프레임을
        // 기록하면 배치가 프레임 이벤트로 뒤덮인다(그 비용은 signpost 쪽이 이미 본다).
        guard index == 0 else { return super.animatedImageFrame(at: index) }
        let startedAt = Date()
        let frame = super.animatedImageFrame(at: index)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let event = MediaLoadEventDTO.decode(kind: "webpFrame0", ms: ms,
                                             pixels: Self.pixelCount(of: frame), bytes: 0)
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
        return frame
    }
}

/// `SDImageIOCoder`(JPEG/PNG/HEIC — ImageIO 경로)를 상속해 디코드 구간만 계측한다.
///
/// WebP 만 재던 동안 디코드 이벤트가 net 이벤트의 1/5 밖에 안 잡혔다(94 vs 495).
/// 보드 이미지가 전부 WebP 인 건 aagag/inven 같은 일부이고 나머지는 JPEG 이라,
/// "디코드는 싸다" 는 판단의 근거가 반쪽이었다 — 슬롯 폭 실험이 반증된 뒤 남은
/// 후보(디코드가 CPU 로 포화)를 재려면 이쪽 숫자가 있어야 한다.
///
/// 등록 순서 주의: `SDImageCodersManager` 는 **나중에 등록된 코더를 먼저** 본다.
/// iOS 14+ 의 ImageIO 는 WebP 도 디코드할 수 있어서, 이 코더를 WebP 코더보다
/// 뒤에 등록하면 libwebp 경로를 가로챈다. `SDWebImageSetup` 은 이걸 먼저, WebP 를
/// 나중에 등록한다(그 순서를 `SDWebImageSetupTests` 가 지킨다).
nonisolated final class SignpostIOCoder: SDImageIOCoder {
    override func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? {
        let id = OSSignpostID(log: AppSignpost.image)
        mxSignpost(.begin, log: AppSignpost.image, name: "ioStatic", signpostID: id)
        defer { mxSignpost(.end, log: AppSignpost.image, name: "ioStatic", signpostID: id) }
        let startedAt = Date()
        let image = super.decodedImage(with: data, options: options)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let pixels = SignpostWebPCoder.pixelCount(of: image)
        let event = MediaLoadEventDTO.decode(kind: "ioStatic", ms: ms,
                                             pixels: pixels,
                                             bytes: data?.count ?? 0)
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
        return image
    }
}
