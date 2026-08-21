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
        let startedAt = Date()
        let image = super.decodedImage(with: data, options: options)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let event = MediaLoadEventDTO.decode(kind: "webpStatic", ms: ms,
                                             pixels: Self.pixelCount(of: image),
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
