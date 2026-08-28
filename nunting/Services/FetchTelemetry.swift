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
    var via: String?    // 이 요청을 낸 경로(activate|refresh|more) — 아래 참조
    var link: String?   // wifi|cell|... — record() 시점에 찍는다

    /// 대시보드에서 눈으로 갈리는 최소 라벨. 쿼리 전체를 실으면 글 번호마다
    /// 다른 문자열이 돼 집계가 안 되고, 경로만 실으면 게시판이 안 갈린다.
    /// 그래서 집계 축이 되는 `id`(보드)/`page` 만 **값째** 남기고, 나머지 쿼리는
    /// **키 이름만** 남긴다.
    ///
    /// 남은 키를 통째로 버리지 않는 이유 — 목록과 상세가 같은 경로를 쓰고 글
    /// 번호만 쿼리로 다는 사이트가 있다(aagag 이슈모음: 목록 `/issue/`, 상세
    /// `/issue/?idx=1633837`). 키를 버리면 둘이 같은 문자열로 접혀, 서로 다른
    /// 글 30개를 연 것이 "같은 URL 을 3분 반에 30번 쳤다"로 보인다 — 실제로
    /// 그렇게 오진했다(2026-08-28). 값까지 실으면 글마다 라벨이 달라져 집계가
    /// 깨지므로, 가르는 데 필요한 최소치인 이름만 남긴다. 사이트별 키 목록을
    /// 두지 않은 건 같은 함정이 다른 사이트에 생겨도 저절로 갈리게 하려는 것.
    static func label(for url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let keep = ["id", "page", "c_page"]
        var kept: [String] = []
        var keptKeys: Set<String> = []
        for key in keep {
            guard let value = items.first(where: { $0.name == key })?.value else { continue }
            kept.append("\(key)=\(value)")
            keptKeys.insert(key)
        }
        // 이름만 남는 쪽은 정렬 + 중복 제거 — 같은 요청이 쿼리 순서나 중복
        // 파라미터 때문에 두 라벨로 갈리면 집계가 쪼개진다.
        let marked = Set(items.map(\.name)).subtracting(keptKeys).sorted()
        let parts = kept + marked
        let path = comps?.path ?? url.path
        return parts.isEmpty ? path : "\(path)?\(parts.joined(separator: "&"))"
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
    /// 이벤트가 증발한다).
    ///
    /// **두 번 비운다.** 이벤트는 `Task { @MainActor in ... }` 로 건너와 버퍼에
    /// 담기는데, 백그라운드 직전에 끝난 시도의 hop 은 이 메서드가 도는 시점에
    /// 아직 큐에 남아 있을 수 있다. 그러면 그 이벤트는 유일한 flush 를 놓치고
    /// 임계 미만인 버퍼에 얹힌 채 프로세스가 정지한다 — 하필 "마지막에 무엇이
    /// 실패했나"가 거기 있다. 두 번째 flush 를 뒤에 걸어 그 hop 들이 도착한
    /// 뒤를 훑는다. 순서 보장은 실행자 FIFO 에 기대는 best-effort 지만, 계측은
    /// 원래 best-effort 이고 지금은 **확정적으로** 놓치고 있다.
    ///
    /// 두 번째 flush 도 `BackgroundFlushWindow` 로 감싼다 — 안 감싸면 그게
    /// 돌기 전에 앱이 정지해 무의미하다.
    func onBackground() {
        flush()
        let ticket = flushWindow.enter()
        Task { @MainActor in
            defer { flushWindow.leave(ticket) }
            flush()
        }
    }

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
    /// `FetchReason.current` 를 요청 시점에 떠 온 값. 구조체에 명시적으로 담는
    /// 이유는 `event()` 가 task-local 을 몰래 읽으면 테스트가 만든 outcome 의
    /// 결과가 실행 문맥에 따라 달라지기 때문이다.
    var via: String? = nil

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
            pf: prefetch ? true : nil,
            via: via)
    }
}

/// 목록 요청이 **왜** 나갔는지 전달하는 task-local.
///
/// 왜 이 형태인가 — 계측은 "요청이 나갔다"는 남기지만 "왜 나갔는지"는 안
/// 남긴다. 그래서 aagag 이슈 보드에 3분 반 동안 같은 URL 요청이 30번 찍혔을 때
/// (2초 간격이 8회) 그게 사용자가 당겨서 새로고침한 것인지, 페이저에서 살짝
/// 밀었다 되돌아오며 `.task(id:)` 가 재시작된 것인지 가를 수 없었다.
/// 페이징(`page=N`)은 URL 로 이미 갈리므로 필요한 건 사실상 한 비트다.
///
/// `BoardListLoader.Fetcher` 시그니처를 늘리지 않은 이유: 그 typealias 는
/// 테스트 fake 61곳이 물려 있어, 한 비트 때문에 그 전부를 건드리게 된다.
/// task-local 은 같은 태스크 트리 안에서 await 를 건너 전파되므로 로더가
/// 감싸기만 하면 `fetchHTMLOnce` 가 읽는다.
/// `nonisolated`: 이 타겟의 기본 격리가 MainActor 라 그냥 두면 비격리인
/// `fetchHTMLOnce` 에서 못 읽는다(`MediaLoadEventDTO` 와 같은 처리).
nonisolated enum FetchReason {
    @TaskLocal static var current: String?

    /// 페이지 도착(페이저 활성화)으로 인한 재로드.
    static let activate = "activate"
    /// 사용자가 당긴 새로고침.
    static let refresh = "refresh"
    /// 하단 스크롤 페이징.
    static let more = "more"
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
