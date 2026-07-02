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
        return super.decodedImage(with: data, options: options)
    }

    override func animatedImageFrame(at index: UInt) -> UIImage? {
        let id = OSSignpostID(log: AppSignpost.image)
        mxSignpost(.begin, log: AppSignpost.image, name: "webpFrame", signpostID: id)
        defer { mxSignpost(.end, log: AppSignpost.image, name: "webpFrame", signpostID: id) }
        return super.animatedImageFrame(at: index)
    }
}
