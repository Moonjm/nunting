import Foundation
import Network
import SDWebImage
import os

/// 서버 `/me/metrics?kind=media` 로 보내는 미디어 로드 이벤트 한 건.
/// 키는 Go `mediaPayloadJSON` 과 합의.
///
/// 세 종류를 한 형태에 담고 `t` 로 가른다:
/// - `net`   이미지 **다운로드 계층**(URLSessionTaskMetrics). 순수 네트워크 시간과 그 분해.
/// - `show`  이미지 **표시 계층**. 슬롯이 뜬 뒤 그림이 채워지기까지 = 사용자가 체감하는 시간.
/// - `video` 인라인 영상이 재생 준비되기까지(mp4=readyToPlay, webm=loadedmetadata).
///
/// 두 계층을 나눠 싣는 이유: "느리다"의 원인이 네트워크인지 캐시 미스인지 갈라야
/// 대응이 갈린다(전자면 프리페치/다운샘플, 후자면 캐시 정책). 한쪽만 봐서는 못 가른다.
///
/// nil 필드는 인코딩에서 빠진다 — 이벤트가 글 하나에 수십 건이라 키 하나가
/// 배치 크기에 그대로 곱해진다. 특히 `ok` 는 실패일 때만 싣는다(성공이 기본값).
nonisolated struct MediaLoadEventDTO: Encodable, Sendable {
    let t: String      // "net" | "show" | "video"
    let ts: Int        // epoch seconds
    let ms: Int        // 이 이벤트가 대표하는 소요 시간
    var host: String?
    var ctx: String?   // show/video: body|icon|viewer
    var src: String?   // show: mem|disk|net (SDImageCacheType)
    var kind: String?  // video: mp4|webm
    var link: String?  // wifi|cell|wired|none — record() 시점에 찍힌다
    var bytes: Int?
    var dns: Int?      // net: 도메인 조회
    var conn: Int?     // net: TCP+TLS(URLSession 원값 — TLS 를 포함한다)
    var tls: Int?      // net: TLS 핸드셰이크
    var ttfb: Int?     // net: 요청 송신 → 첫 응답 바이트
    var proto: String? // net: h2 / http/1.1 …
    var reused: Bool?  // net: 커넥션 재사용 여부
    var status: Int?   // net: HTTP 상태
    var queued: Int?   // net: 요청 생성 → 실제 전송 시작(다운로더 슬롯 대기)
    var px: Int?       // decode: 출력 픽셀 수 — 디코드 비용은 픽셀에 비례한다
    var pf: Bool?      // net: 프리페치 요청일 때만 true(표시 요청이 기본)
    var slot: Int?     // net: 슬롯 획득(오퍼레이션 start) → 전송 시작. 큐 대기와 분리
    var post: Int?     // op: 전송 완료 → 오퍼레이션 종료(디코드 + 완료 처리)
    var ok: Bool?      // 실패일 때만 false 로 실린다
}

/// `URLSessionTaskTransactionMetrics` 에서 뽑아낸 값들. 프레임워크 타입은 테스트에서
/// 만들 수 없어(생성자 비공개) 순수 값으로 한 겹 떼어낸다 — 변환 규칙은 이쪽에서 검증한다.
nonisolated struct MediaLoadNetworkPhases: Sendable {
    let fetchStart: Date?
    let domainLookupStart: Date?
    let domainLookupEnd: Date?
    let connectStart: Date?
    let connectEnd: Date?
    let secureConnectionStart: Date?
    let secureConnectionEnd: Date?
    let requestStart: Date?
    let responseStart: Date?
    let responseEnd: Date?
    let reusedConnection: Bool
    let networkProtocol: String?
    let statusCode: Int?
    let bytes: Int
}

nonisolated extension MediaLoadEventDTO {

    /// 다운로드 계층 이벤트. 총 시간을 못 재면(취소·실패로 `responseEnd` 부재) `nil` —
    /// 0ms 로 실으면 분포의 p50 을 끌어내려 "빠르다"는 착시를 만든다.
    /// - Parameter enqueuedAt: 이 요청이 만들어진 시각(다운로더 큐에 들어간 순간).
    ///   주면 `queued` = 슬롯 대기 시간이 실린다. 모르면 필드를 비운다 — 0 을 넣으면
    ///   "대기 없음" 과 구분이 안 된다.
    static func network(host: String,
                        phases: MediaLoadNetworkPhases,
                        enqueuedAt: Date? = nil,
                        startedAt: Date? = nil,
                        prefetch: Bool = false,
                        ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO? {
        guard let total = elapsedMs(phases.fetchStart, phases.responseEnd) else { return nil }
        return MediaLoadEventDTO(
            t: "net", ts: ts, ms: total,
            host: host,
            bytes: phases.bytes > 0 ? phases.bytes : nil,
            // 재사용 커넥션은 이 단계들이 아예 없다(nil). 0 으로 채우면
            // "핸드셰이크 0ms" 로 읽혀 분포가 오염되므로 그대로 비운다.
            dns: elapsedMs(phases.domainLookupStart, phases.domainLookupEnd),
            conn: elapsedMs(phases.connectStart, phases.connectEnd),
            tls: elapsedMs(phases.secureConnectionStart, phases.secureConnectionEnd),
            ttfb: elapsedMs(phases.requestStart ?? phases.fetchStart, phases.responseStart),
            proto: phases.networkProtocol,
            reused: phases.reusedConnection,
            status: phases.statusCode,
            queued: elapsedMs(enqueuedAt, phases.fetchStart),
            pf: prefetch ? true : nil,
            slot: elapsedMs(startedAt, phases.fetchStart))
    }

    /// 오퍼레이션 수명 이벤트 — 슬롯을 잡고 있던 총 시간.
    ///
    /// 대기의 마지막 사각지대다. `slot`(획득→전송)이 6ms 로 확인됐으니 지연은 전부
    /// "슬롯을 못 잡아서" 인데, 앞선 오퍼레이션의 측정된 작업량(다운로드+디코드
    /// ≈90ms)으로는 실측 대기(p90 4.1초)가 설명되지 않는다. 전송이 끝난 **뒤에도**
    /// 슬롯이 붙잡혀 있는 시간을 여기서 잡는다.
    static func operation(host: String, ms: Int, postTransferMs: Int? = nil, prefetch: Bool,
                          ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO {
        MediaLoadEventDTO(t: "op", ts: ts, ms: ms, host: host,
                          pf: prefetch ? true : nil, post: postTransferMs)
    }

    /// 메인 큐 관련 이벤트. `kind` 는 "lag"(큐 정체) | "apply"(도착한 이미지를 뷰에
    /// 반영하는 우리 핸들러의 실행 시간). 둘이 갈려야 "메인이 밀려서" 와 "우리 핸들러가
    /// 무거워서" 를 구분할 수 있다.
    static func mainQueue(kind: String, ms: Int,
                          ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO {
        MediaLoadEventDTO(t: "main", ts: ts, ms: ms, kind: kind)
    }

    /// 디코드 구간 이벤트. `pixels` 를 같이 실어야 "무거운 이미지였다"와
    /// "큐가 막혀 밀렸다"를 사후에 구분할 수 있다(디코드 비용 ∝ 픽셀).
    static func decode(kind: String, ms: Int, pixels: Int, bytes: Int,
                       ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO {
        MediaLoadEventDTO(t: "decode", ts: ts, ms: ms, kind: kind,
                          bytes: bytes > 0 ? bytes : nil,
                          px: pixels > 0 ? pixels : nil)
    }

    /// 표시 계층 이벤트.
    static func show(host: String, ms: Int, src: String, ctx: String, ok: Bool,
                     ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO {
        MediaLoadEventDTO(t: "show", ts: ts, ms: ms, host: host, ctx: ctx, src: src,
                          ok: ok ? nil : false)
    }

    /// 영상 준비 이벤트.
    static func video(kind: String, host: String, ms: Int, ctx: String, ok: Bool,
                      ts: Int = Int(Date().timeIntervalSince1970)) -> MediaLoadEventDTO {
        MediaLoadEventDTO(t: "video", ts: ts, ms: ms, host: host, ctx: ctx, kind: kind,
                          ok: ok ? nil : false)
    }

    private static func elapsedMs(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to else { return nil }
        return Int((to.timeIntervalSince(from) * 1000).rounded())
    }
}

/// 현재 링크 종류(wifi/cell/…)를 들고 있는 관찰자.
///
/// 같은 이미지도 LTE 냐 Wi-Fi 냐로 체감이 갈리므로, 로드 이벤트마다 그때의 링크를
/// 같이 실어야 "느린 게 앱이냐 회선이냐"를 사후에 가를 수 있다. `NWPathMonitor` 는
/// 변화가 있을 때만 콜백하므로 상시 비용이 사실상 없다.
///
/// 격리: 다운로더 스레드에서도 읽으므로 `nonisolated` + 락. `NWPath` 는 테스트에서
/// 만들 수 없어 분류 규칙만 `label(satisfied:wifi:cellular:wired:)` 로 떼어놨다.
nonisolated final class MediaLinkMonitor: Sendable {
    static let shared = MediaLinkMonitor()

    /// 아직 첫 경로 업데이트를 못 받은 상태. "none"(연결 없음)과 섞이면 안 된다.
    static let unknown = "unknown"

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: MediaLinkMonitor.unknown)

    /// 앱 시작 시 1회.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.withLock { $0 = MediaLinkMonitor.label(of: path) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    var link: String { state.withLock { $0 } }

    private static func label(of path: NWPath) -> String {
        label(satisfied: path.status == .satisfied,
              wifi: path.usesInterfaceType(.wifi),
              cellular: path.usesInterfaceType(.cellular),
              wired: path.usesInterfaceType(.wiredEthernet))
    }

    /// 셀룰러가 Wi-Fi 를 이긴다 — 두 인터페이스가 같이 서는 경우(핫스팟, Wi-Fi Assist)
    /// 실제로 바이트가 흐르는 쪽은 셀룰러이고, 우리가 알고 싶은 것도 그쪽이다.
    static func label(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool) -> String {
        guard satisfied else { return "none" }
        if cellular { return "cell" }
        if wifi { return "wifi" }
        if wired { return "wired" }
        return "none"
    }
}

/// 서버로 나가는 배치 한 건. `cfg` 는 이 배치가 나온 실행 설정.
nonisolated struct MediaLoadBatch: Encodable, Sendable {
    let events: [MediaLoadEventDTO]
    let cfg: String?
}

/// 배치에 같이 싣는 실행 설정 라벨.
///
/// 슬롯 폭 4→8 실험을 판정할 때 **어느 세션이 어느 빌드였는지 알 방법이 없어** 귀속이
/// 막혔다(계측은 정상이었는데 결론을 못 냈다). 설정을 배치에 실어 그 구멍을 닫는다.
nonisolated enum MediaRunConfig {
    static func label(slots: Int, build: String) -> String {
        var parts = ["slots=\(slots)"]
        if !build.isEmpty { parts.append("build=\(build)") }
        return parts.joined(separator: " ")
    }

    /// 빌드 식별자. **`CFBundleVersion` 은 쓰지 않는다** — 이 프로젝트에선 항상 "1"
    /// 이라 재빌드해도 그대로여서, 정작 A/B 판정에서 두 빌드를 구분하지 못했다
    /// (중복 디코드 수정을 판정하려다 여기서 막혔다). 실행 파일의 수정 시각은
    /// 빌드할 때마다 바뀌므로 사이드로드 개발 빌드에서도 세션을 갈라준다.
    static func buildStamp(executableModified: Date?) -> String {
        guard let executableModified else { return "" }
        // 초 단위 epoch 의 하위 6자리 — 표에서 눈으로 구분하기 좋은 길이.
        return String(Int(executableModified.timeIntervalSince1970) % 1_000_000)
    }
}

/// 미디어 로드 이벤트를 모아 서버로 배치 전송한다.
///
/// `FootprintLogger` 와 같은 모양(버퍼 → 임계에서 flush → 백그라운드 진입 시 잔량 flush,
/// 실패해도 재시도 없음)을 의도적으로 따른다. 이벤트가 건별로 작고 매우 잦아서
/// 건마다 POST 하면 글 하나 여는 데 수십 번이 된다.
///
/// 샘플링은 하지 않는다 — 1인용 앱이라 양이 감당되고, 캐시 히트율 자체가 알고 싶은
/// 값이라 "느린 것만" 남기면 분모가 사라진다.
@MainActor
final class MediaLoadTelemetry {
    static let shared = MediaLoadTelemetry()

    private var buffer: [MediaLoadEventDTO] = []
    private let flushThreshold: Int
    private let linkProvider: () -> String
    private let configProvider: () -> String
    private let injectedFlush: (([MediaLoadEventDTO]) -> Void)?
    private let flushWindow = BackgroundFlushWindow()

    init(flushThreshold: Int = 60,
         linkProvider: @escaping () -> String = { MediaLinkMonitor.shared.link },
         configProvider: @escaping () -> String = MediaLoadTelemetry.currentConfigLabel,
         onFlush: (([MediaLoadEventDTO]) -> Void)? = nil) {
        self.flushThreshold = flushThreshold
        self.linkProvider = linkProvider
        self.configProvider = configProvider
        self.injectedFlush = onFlush
    }

    /// 지금 돌고 있는 설정 — 실험의 주 변수인 슬롯 폭과 빌드 번호.
    nonisolated private static func currentConfigLabel() -> String {
        let modified = Bundle.main.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        } ?? nil
        return MediaRunConfig.label(
            slots: SDWebImageDownloader.shared.config.maxConcurrentDownloads,
            build: MediaRunConfig.buildStamp(executableModified: modified))
    }

    /// 이벤트 한 건 적재. 링크 종류는 여기서 찍는다 — 호출부(다운로더 스레드/메인)마다
    /// 따로 조회하면 같은 로드의 두 이벤트가 다른 링크로 기록될 수 있다.
    func record(_ event: MediaLoadEventDTO) {
        var stamped = event
        stamped.link = linkProvider()
        buffer.append(stamped)
        if buffer.count >= flushThreshold { flush() }
    }

    /// 버퍼를 내보내고 비운다. 비우지 않으면 같은 이벤트가 배치마다 다시 실려
    /// 서버 쪽 분포가 왜곡된다.
    func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        if let injectedFlush {
            injectedFlush(batch)
            return
        }
        upload(batch)
    }

    /// 백그라운드 진입: 임계 미만이어도 잔량을 내보낸다(안 그러면 세션 끝의 이벤트가 증발).
    func onBackground() { flush() }

    /// 진단 데이터라 실패해도 재시도하지 않는다. `BackgroundFlushWindow` 로 감싸는
    /// 이유는 `FootprintLogger` 와 동일 — 백그라운드 진입 직후의 flush 는 감싸지 않으면
    /// 출발도 못 하고 증발한다.
    private func upload(_ batch: [MediaLoadEventDTO]) {
        let cfg = configProvider()
        let ticket = flushWindow.enter()
        Task { @MainActor in
            defer { flushWindow.leave(ticket) }
            do {
                try await AlertSubscriptionService.shared.reportMediaLoads(batch, cfg: cfg)
            } catch {
                NSLog("[MediaLoadTelemetry] flush failed: \(error.localizedDescription)")
            }
        }
    }
}
