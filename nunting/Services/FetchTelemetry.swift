import Foundation

/// 서버 `/me/metrics?kind=fetch` 로 보내는 **HTML fetch 시도** 한 건.
///
/// 왜 필요했나 — 뽐뿌 429 를 재시도로 흡수한 뒤에도 "목록 하단 다시 시도"와
/// "너무 느리다"가 남았는데, 이 경로엔 로그가 한 줄도 없었다.
/// `ParserFailureTelemetry` 는 `structureChanged` 만 올리고(서버 전 기간 12건,
/// 뽐뿌 0건), 로더의 catch 는 플래그 한 줄이 전부다. 그래서 "429 라 거절된
/// 것"과 "연결이 물려 8초 타임아웃 난 것"을 사후 판별할 수단이 없다 — 둘은
/// 화면에 똑같이 "다시 시도" 로 보이지만 대응이 정반대다(전자는 요청을
/// 줄이는 문제, 후자는 커넥션/타임아웃 문제).
///
/// 성공도 싣는다. 실패만 남기면 분모가 사라져 "느리다"를 못 판정한다 —
/// 미디어 계측이 캐시 히트율을 분모로 남긴 것과 같은 이유.
///
/// **시도 단위**로 기록한다(요청 단위가 아니라). 한 요청이 429 → 백오프 →
/// 429 → 200 으로 끝났는지, 처음부터 8초를 물고 늘어졌는지는 시도별 상태와
/// 소요를 봐야만 갈린다. `try` 로 몇 번째 시도인지 표시한다.
nonisolated struct FetchEventDTO: Encodable, Sendable {
    let ts: Int         // epoch seconds
    let ms: Int         // 이 **시도** 하나의 소요 시간
    let host: String
    let path: String    // 경로 + 식별 쿼리(아래 `label(for:)`)
    var status: Int?    // HTTP 상태 (응답이 온 경우)
    var err: String?    // URLError 코드 등 (응답 자체가 없는 경우)
    var attempt: Int?   // 2 이상일 때만 — 1 이 기본
    var pf: Bool?       // 프리페치 요청일 때만 true
    var link: String?   // wifi|cell|... — record() 시점에 찍는다

    /// 대시보드에서 눈으로 갈리는 최소 라벨. 쿼리 전체를 실으면 글 번호마다
    /// 다른 문자열이 돼 집계가 안 되고, 경로만 실으면 게시판이 안 갈린다.
    /// 그래서 경로 + `id`(보드)/`page` 만 남긴다.
    static func label(for url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let keep = ["id", "page", "c_page"]
        let kept = keep.compactMap { key -> String? in
            guard let value = items.first(where: { $0.name == key })?.value else { return nil }
            return "\(key)=\(value)"
        }
        let path = comps?.path ?? url.path
        return kept.isEmpty ? path : "\(path)?\(kept.joined(separator: "&"))"
    }

    /// 응답이 아예 없는 실패의 라벨. `URLError` 는 코드 숫자로 — 이름은
    /// 플랫폼 문자열이라 길고, 숫자가 라딧/문서 검색에 그대로 쓰인다.
    static func errorLabel(_ error: Error) -> String {
        if let urlError = error as? URLError { return "urlerror \(urlError.code.rawValue)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }
}

/// 서버로 나가는 배치 한 건.
nonisolated struct FetchBatch: Encodable, Sendable {
    let events: [FetchEventDTO]
}

/// HTML fetch 이벤트를 모아 배치 전송한다.
///
/// `MediaLoadTelemetry` 와 같은 모양(버퍼 → 임계에서 flush → 백그라운드 진입 시
/// 잔량 flush, 실패해도 재시도 없음)을 의도적으로 따른다. 이벤트가 잦고 건당
/// 작아서 건마다 POST 하면 보드 하나 넘기는 데 수십 번이 된다.
///
/// 임계가 미디어(60)보다 낮은 이유: HTML fetch 는 세션당 수백 건 수준이라
/// 60 을 기다리면 짧은 세션의 이벤트가 통째로 백그라운드 flush 로 몰린다.
@MainActor
final class FetchTelemetry {
    static let shared = FetchTelemetry()

    private var buffer: [FetchEventDTO] = []
    private let flushThreshold: Int
    private let linkProvider: () -> String
    private let injectedFlush: (([FetchEventDTO]) -> Void)?
    private let flushWindow = BackgroundFlushWindow()

    init(flushThreshold: Int = 30,
         linkProvider: @escaping () -> String = { MediaLinkMonitor.shared.link },
         onFlush: (([FetchEventDTO]) -> Void)? = nil) {
        self.flushThreshold = flushThreshold
        self.linkProvider = linkProvider
        self.injectedFlush = onFlush
    }

    func record(_ event: FetchEventDTO) {
        var stamped = event
        stamped.link = linkProvider()
        buffer.append(stamped)
        if buffer.count >= flushThreshold { flush() }
    }

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

    /// 백그라운드 진입: 임계 미만이어도 잔량을 내보낸다(안 그러면 세션 끝의
    /// 이벤트가 증발한다 — `MediaLoadTelemetry` 와 동일).
    func onBackground() { flush() }

    /// 테스트 실행에서는 업로드하지 않는다.
    ///
    /// 이 계측은 기본 인자로 실 텔레메트리에 물려 있어서, `Networking.fetchHTML`
    /// 을 부르는 테스트가 그대로 프로덕션 대시보드에 배치를 올렸다 —
    /// `xcodebuild test` 한 번에 `example.com` 21건(MockURLProtocol 의 404/500/
    /// 타임아웃 zoo)이 실기기 데이터 사이에 섞여 들어갔고, 하마터면 그걸
    /// 사용자 세션으로 읽을 뻔했다. 계측의 값어치는 신뢰성이라 소스에서 막는다.
    nonisolated static func isTestRun(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    private func upload(_ batch: [FetchEventDTO]) {
        guard !Self.isTestRun() else { return }
        let ticket = flushWindow.enter()
        Task { @MainActor in
            defer { flushWindow.leave(ticket) }
            do {
                try await AlertSubscriptionService.shared.reportFetches(batch)
            } catch {
                NSLog("[FetchTelemetry] flush failed: \(error.localizedDescription)")
            }
        }
    }
}

/// `Networking` 이 시도 하나를 끝낼 때마다 넘기는 결과. 프레임워크 타입
/// (`URLResponse`/`URLError`)을 계측 레이어까지 끌고 가지 않도록 값으로 한 겹
/// 떼어낸다 — 변환 규칙(라벨링)은 이 파일에서 검증한다.
nonisolated struct FetchAttemptOutcome: Sendable {
    let url: URL
    let attempt: Int
    let prefetch: Bool
    let elapsedMs: Int
    let status: Int?
    let error: Error?

    /// 계측에 실을 형태로 변환. 취소는 싣지 않는다(`nil`) — 뷰 교체/보드 전환이
    /// 쏟아내는 정상 취소가 실패 분포를 뒤덮는다. 이미지 쪽에서 취소를 영구
    /// 실패로 승격했다가 겪은 것과 같은 함정(`NetworkImageCancellationTests`).
    func event(ts: Int = Int(Date().timeIntervalSince1970)) -> FetchEventDTO? {
        if let error {
            if error is CancellationError { return nil }
            if (error as? URLError)?.code == .cancelled { return nil }
        }
        return FetchEventDTO(
            ts: ts,
            ms: elapsedMs,
            host: url.host ?? "?",
            path: FetchEventDTO.label(for: url),
            status: status,
            err: error.map(FetchEventDTO.errorLabel),
            attempt: attempt > 1 ? attempt : nil,
            pf: prefetch ? true : nil)
    }
}

/// 시도 결과 싱크. `@Sendable` 인 이유는 `fetchHTMLOnce` 가 비격리 정적
/// 함수라 어느 스레드에서도 불릴 수 있어서다.
typealias FetchAttemptRecorder = @Sendable (FetchAttemptOutcome) -> Void

extension Networking {
    /// 프로덕션 싱크 — main actor 로 건너가 버퍼에 넣는다. fire-and-forget:
    /// 계측이 fetch 를 기다리게 하면 안 된다(미디어 계측과 같은 계약).
    nonisolated static let defaultFetchRecorder: FetchAttemptRecorder = { outcome in
        guard let event = outcome.event() else { return }
        Task { @MainActor in FetchTelemetry.shared.record(event) }
    }
}
