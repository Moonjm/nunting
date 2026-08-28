import Foundation
/// Single-writer gate for `Networking.prewarmConnections`. Callers
/// request `claimRun()`; the actor returns `true` only if enough time
/// has passed since the last successful claim, which throttles scene-
/// phase bounce-induced redundant HEAD bursts. An `actor` (not
/// `@MainActor`) so the gate read/write stays off the main thread.
actor PrewarmThrottle {
    static let shared = PrewarmThrottle()
    /// Any request within this interval of the last run is dropped.
    /// Chosen to be well under the URLSession keep-alive window
    /// (~60 s) so the pool is reliably warm between successful runs.
    private let interval: TimeInterval = 30
    private var lastRun: Date?

    func claimRun(now: Date = Date()) -> Bool {
        if let lastRun, now.timeIntervalSince(lastRun) < interval {
            return false
        }
        lastRun = now
        return true
    }
}

enum NetworkError: Error, LocalizedError {
    case badResponse(Int)
    case decodingFailed
    /// Site served a CAPTCHA / bot-check interstitial twice in a row
    /// (once on the original fetch, once after the user-driven recovery
    /// via `BotCheckCoordinator`). Surfaced as a normal error so the
    /// loader's existing catch path renders a message instead of
    /// looping the sheet.
    case captchaChallenge(URL)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "HTTP \(code)"
        case .decodingFailed: "응답 디코딩 실패"
        case .captchaChallenge: "자동등록방지 통과 실패 — 다시 시도해 주세요"
        }
    }
}

struct Networking {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// Desktop UA for endpoints that serve a JS-redirect to mobile when given
    /// a mobile UA (e.g. ppomppu's `www.` host).
    nonisolated static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // `nonisolated` so the `session` initializer below — also nonisolated —
    // can reference this without crossing isolation boundaries. Default
    // isolation under Swift 6 would otherwise infer MainActor for a plain
    // `static let` on a non-actor type and break the default-argument
    // references on `fetchHTML` / `resolveFinalURL` / `postForm`.
    nonisolated static let sharedCache: URLCache = {
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            directory: nil
        )
        URLCache.shared = cache
        return cache
    }()

    // `nonisolated` so the default-argument references on `fetchHTML` /
    // `resolveFinalURL` / `postForm` can read this from a nonisolated context
    // under Swift 6 default-isolation. URLSession is documented thread-safe.
    nonisolated static let session: URLSession = {
        _ = sharedCache
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.urlCache = sharedCache
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config, delegate: redirectUpgrader, delegateQueue: nil)
    }()

    /// URLSession transient errors retried by `fetchHTML` (and image
    /// fetches in `ImageDataLoader`). Same root cause as the image-side
    /// retry: the iOS pool occasionally hands out a stale keep-alive
    /// connection whose remote half the server has already closed —
    /// the first write hits a TCP RST and surfaces as -1005 in
    /// ~280 ms, or as -1001 / -1004 when the connect leg itself fails.
    /// Observed on `m.slrclub.com` HTML body fetches where one in N
    /// detail opens used to fail with "본문이 안 나옴". A single retry
    /// after a short backoff dials a fresh connection and clears it
    /// in practice. See radar #21663589.
    static let transientURLErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost,    // -1005
        .timedOut,                 // -1001
        .cannotConnectToHost,      // -1004
    ]

    /// Per-request idle timeout applied to the FIRST attempt only. Session
    /// default (`timeoutIntervalForRequest = 15`) still backs the retry
    /// attempt. Rationale: -1001 (timed out) on the first attempt almost
    /// always means the keep-alive connection is dead, not that the host
    /// is genuinely slow — fail it faster so the retry's fresh-dial path
    /// kicks in earlier. iOS's `timeoutInterval` is an *idle* timeout
    /// (resets on every byte received), so 8 s of zero data flow is well
    /// past the threshold for "live but slow" and squarely in
    /// "connection is wedged" territory. Worst-case fetchHTML latency
    /// drops from ~30 s (15+15) to ~23 s (8+15).
    static let firstAttemptIdleTimeout: TimeInterval = 8

    /// `429 Too Many Requests` 재시도 백오프 스케줄 — 길이가 곧 재시도 횟수다
    /// (기본 2회 → 최대 3시도). 게시판들은 nginx `limit_req` 로 IP 당 토큰
    /// 버킷을 돌린다: 뽐뿌 `m.ppomppu.co.kr` 실측(2026-08-27)이 버스트 ~10,
    /// 리필 ~2/s, 거절 후 회복 2~4초였다. 앱은 목록 페이징 + 상세 프리페치
    /// (`DetailPrefetcher`, 3건 동시) + 댓글 페이지 fan-out 을 같은 호스트로
    /// 보내므로 평범한 세션에서도 버킷이 마른다 — 그때의 429 는 "이 요청이
    /// 틀렸다"가 아니라 "몇 백 ms 뒤에 다시 오라"는 신호라 transient 로 다룬다.
    /// 이걸 영구 실패로 올리면 목록 하단이 "다시 시도" 로 굳고 멀쩡한 글이
    /// 안 열린다(둘 다 재현된 증상).
    ///
    /// 간격을 **서버 토큰 주기에 맞춘다**(뽐뿌 실측 3초에 1건 → 3.5초).
    ///
    /// 종전엔 0.5 / 1.5 / 3초로 점증시켰는데, 토큰이 3초에 하나씩 생기는
    /// 서버에서 0.5초·1.5초 재시도는 거의 확정적으로 또 429 다 — 헛수고이면서
    /// 그만큼 성공이 늦어진다. 실기기 로그의 전형적인 모양이 그랬다:
    ///
    ///     t+13s 429 att=1 / t+13s 429 att=2 / t+16s 200 att=3   (성공까지 3초)
    ///     t+19s 429 att=1 / t+23s 200 att=2                     (정렬 후 예상 모양)
    ///
    /// 토큰 주기에 맞추면 첫 재시도에서 붙는다. 재시도가 버킷을 더 태우지는
    /// 않는다(`limit_req` 는 거절한 요청에 토큰을 쓰지 않는다) — 문제는 낭비된
    /// 왕복이 아니라 **그동안 사용자가 기다린다**는 것이다.
    ///
    /// 2회면 충분하다. `HostRequestPacer` 가 앞단에서 요청률을 지키므로 여기까지
    /// 오는 429 는 "우리 버킷이 서버 버킷보다 앞선" 드문 경우고, 한 토큰 주기를
    /// 기다리면 대개 해소된다. 이 스케줄은 전 사이트 공통이지만 실제로 타는 건
    /// 요청률 제한이 있는 사이트뿐이라, 관측된 것 중 가장 빡빡한 주기를 쓴다.
    /// URLError transient 재시도(150ms)보다 긴 이유: 저쪽은 죽은 keep-alive
    /// 연결을 새로 다이얼하는 문제라 즉시 재시도가 맞고, 이쪽은 서버가
    /// 시간이 지나야 토큰을 채운다.
    /// `nonisolated`: 기본 인자로 쓰이므로 비격리 호출부에서 읽혀야 한다
    /// (`session` 이 같은 이유로 nonisolated 인 것과 동일).
    nonisolated static let rateLimitBackoff: [Duration] = [
        .milliseconds(3500), .milliseconds(3500),
    ]

    /// 재시도 대상 상태 코드. 429 만 — 5xx 는 재시도가 장애를 키우고,
    /// 4xx 나머지는 재요청해도 같은 답이다.
    nonisolated static let rateLimitedStatus = 429

    /// 서버가 `Retry-After` 로 지시한 대기를 존중하는 상한.
    ///
    /// 지시가 이 값 **이하**면 고정 스케줄 대신 그 값을 쓴다 — 서버가 자기
    /// 버킷 상태를 우리보다 잘 안다. **초과**하면 재시도하지 않고 즉시
    /// 던진다: 60초를 기다리라는 응답에 3.5초 간격으로 두 번 두드려 봐야
    /// 확정적으로 또 429 고(피할 수 있는 실패 — Codex 리뷰 P2), 그렇다고
    /// 60초를 스피너 뒤에서 자면 사용자에겐 멈춘 앱이다. 그 판단은 화면 쪽
    /// (다시 시도 버튼)에 넘기는 게 맞다.
    ///
    /// 현재 관측된 rate limit 사이트(뽐뿌)는 `Retry-After` 를 **안 보낸다**
    /// (429 응답 헤더 실측: Server/Date/Content-Type/Content-Length/Connection
    /// 뿐). 그래서 이 경로는 지금 폴백(고정 스케줄)만 타지만, 헤더를 버리는
    /// 구현은 다른 사이트가 보내기 시작하면 조용히 틀린 동작을 한다.
    nonisolated static let rateLimitRetryAfterCap: Duration = .seconds(10)

    /// `Retry-After` 헤더 해석. delta-seconds(정수)와 HTTP-date 둘 다 규격이다.
    /// 이미 지난 시각이거나 음수면 `.zero`(= 즉시 재시도) — 서버가 "지금 다시
    /// 와도 된다"고 말한 것이다. 해석 불가면 `nil` 로 폴백에 맡긴다.
    nonisolated static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = Int(raw) {
            return seconds > 0 ? .seconds(seconds) : .zero
        }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? .seconds(interval) : .zero
    }

    /// RFC 9110 IMF-fixdate. 로케일/타임존을 못박지 않으면 기기 설정에 따라
    /// 파싱이 깨진다(한국 로케일에서 영문 요일/월 약어를 못 읽는다).
    nonisolated private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func fetchHTML(
        url: URL,
        encoding: String.Encoding = .utf8,
        userAgent: String? = nil,
        handlesCookies: Bool = true,
        /// HTTP 캐시 정책. 기본은 세션 기본값(`.useProtocolCachePolicy`).
        /// 보드 목록처럼 "항상 최신"이 중요한 호출은 `.reloadIgnoringLocalCacheData`
        /// 를 넘겨 URLSession HTTP 캐시를 우회한다(전환 시 stale 목록 방지).
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        /// Referer 헤더 — 이를 요구하는 GET 엔드포인트용(`postForm` 의 referer
        /// 와 같은 계약). 다모앙 댓글 API 가 page≥2 를 무-Referer 요청에
        /// 403 으로 거절하는 게 현재 유일한 수요처.
        referer: URL? = nil,
        /// `Accept` 헤더 override. 기본(`nil`)은 브라우저용 HTML Accept —
        /// 그런데 그걸 content negotiation 하는 JSON API 가 있어(이토랜드 댓글
        /// API 는 XML 로 답한다) 파서가 `BoardParser.acceptHeader(for:)` 로
        /// URL 단위 override 를 내려보낸다.
        accept: String? = nil,
        session: URLSession = Networking.session,
        /// 429 백오프 스케줄 override — 테스트 전용 시임(`session:` 과 같은 계약).
        /// 프로덕션 호출부는 기본값을 쓴다.
        rateLimitBackoff: [Duration] = Networking.rateLimitBackoff,
        /// 계측 라벨용 — 프리페치는 사용자가 기다리는 요청이 아니지만 rate limit
        /// 버킷은 똑같이 태운다. 대시보드에서 갈리지 않으면 "느리다"의 원인이
        /// 프리페치인지 본 요청인지 못 가른다.
        prefetch: Bool = false,
        /// 시도 단위 계측 싱크. 기본은 실제 텔레메트리, 테스트는 스파이를 넣는다.
        recorder: FetchAttemptRecorder = Networking.defaultFetchRecorder,
        /// 요청률 게이트. 테스트는 가짜 시계를 물린 인스턴스를 넣는다.
        pacer: HostRequestPacer = .shared
    ) async throws -> String {
        let retry: @Sendable () async throws -> String = {
            try await fetchHTMLOnce(
                url: url,
                encoding: encoding,
                userAgent: userAgent,
                handlesCookies: handlesCookies,
                cachePolicy: cachePolicy,
                referer: referer,
                accept: accept,
                session: session,
                rateLimitBackoff: rateLimitBackoff,
                prefetch: prefetch,
                recorder: recorder,
                pacer: pacer
            )
        }
        do {
            let html = try await fetchHTMLOnce(
                url: url,
                encoding: encoding,
                userAgent: userAgent,
                handlesCookies: handlesCookies,
                cachePolicy: cachePolicy,
                referer: referer,
                accept: accept,
                session: session,
                rateLimitBackoff: rateLimitBackoff,
                prefetch: prefetch,
                recorder: recorder,
                pacer: pacer
            )
            return try await applyBotCheckGuard(url: url, body: html, retry: retry)
        } catch {
            return try await recoverFromBotCheckStatus(
                url: url,
                error: error,
                retry: retry,
                detector: BotCheckRegistry.detector(for: url),
                challenger: { challengeURL in
                    await BotCheckCoordinator.shared.challenge(url: challengeURL)
                }
            )
        }
    }

    private static func fetchHTMLOnce(
        url: URL,
        encoding: String.Encoding,
        userAgent: String?,
        handlesCookies: Bool,
        cachePolicy: URLRequest.CachePolicy,
        referer: URL? = nil,
        accept: String? = nil,
        session: URLSession,
        rateLimitBackoff: [Duration] = Networking.rateLimitBackoff,
        prefetch: Bool = false,
        recorder: FetchAttemptRecorder = Networking.defaultFetchRecorder,
        pacer: HostRequestPacer = .shared
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = handlesCookies
        request.cachePolicy = cachePolicy
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        // 호출부가 지정한 Referer 가 우선. 없으면 사이트 기본값(`defaultReferer`)
        // — 뽐뿌는 Referer 없는 요청을 훨씬 빡빡한 요청률로 취급한다(근거는
        // `Site.defaultReferer` 주석의 실측).
        if let referer = referer ?? Site.detect(host: url.host)?.defaultReferer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.setValue(
            accept ?? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        // 429 재시도와 URLError transient 재시도는 예산이 따로다 — 두 실패는
        // 원인이 달라(죽은 소켓 vs. 서버 토큰 고갈) 서로의 시도 횟수를 잡아먹으면
        // 안 된다. 그래서 **각자 카운터를 센다**: 공유 `attempt` 로 판정하면
        // "429 → 타임아웃" 순서일 때 transient 재시도가 이미 소진된 것으로 읽혀
        // 약속한 재다이얼이 사라진다(Codex 리뷰 P2). `attempt` 는 첫-시도
        // 타임아웃 판정에만 쓴다.
        let maxTransientRetries = 1
        var attempt = 0
        var transientRetriesUsed = 0
        var rateLimitRetriesUsed = 0
        /// 직전 시도의 `Retry-After`. 응답에서 캡처해 catch 로 넘긴다.
        var retryAfterHint: Duration?
        while true {
            attempt += 1
            // 재시도도 게이트를 통과한다 — 429 를 맞고 다시 쏘는 요청이야말로
            // 남은 토큰을 태우는 주범이었다(계측: 429 하나가 요청 4개로 불어남).
            try await pacer.acquire(site: Site.detect(host: url.host))
            var attemptRequest = request
            if attempt == 1 {
                attemptRequest.timeoutInterval = firstAttemptIdleTimeout
            }
            let startedAt = DispatchTime.now()
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode
                recorder(FetchAttemptOutcome(
                    url: url, attempt: attempt, prefetch: prefetch,
                    elapsedMs: Self.elapsedMs(since: startedAt),
                    status: status, error: nil, via: FetchReason.current))
                if let status, !(200..<300).contains(status) {
                    // 헤더는 여기서만 볼 수 있다 — 에러로 던지고 나면 사라진다.
                    retryAfterHint = http.flatMap(Self.retryAfter(from:))
                    throw NetworkError.badResponse(status)
                }
                return decodeHTML(data: data, encoding: encoding)
            } catch let NetworkError.badResponse(status)
                        where status == Self.rateLimitedStatus
                        && rateLimitRetriesUsed < rateLimitBackoff.count {
                let hint = retryAfterHint
                retryAfterHint = nil
                if let hint, hint > Self.rateLimitRetryAfterCap {
                    // 서버가 한참 뒤에 오라고 했다. 그 전에 두드리는 재시도는
                    // 확정적으로 또 429 다 — 기다림만 늘리고 실패는 그대로다.
                    throw NetworkError.badResponse(status)
                }
                let delay = hint ?? rateLimitBackoff[rateLimitRetriesUsed]
                rateLimitRetriesUsed += 1
                try? await Task.sleep(for: delay)
                try Task.checkCancellation()
                continue
            } catch {
                // 응답 없는 실패만 여기서 기록한다 — 위 do 블록이 이미 기록하고
                // 던진 `badResponse` 는 재기록하면 상태 분포가 두 배가 된다.
                if !(error is NetworkError) {
                    recorder(FetchAttemptOutcome(
                        url: url, attempt: attempt, prefetch: prefetch,
                        elapsedMs: Self.elapsedMs(since: startedAt),
                        status: nil, error: error, via: FetchReason.current))
                }
                let isTransient = (error as? URLError)
                    .map { Self.transientURLErrorCodes.contains($0.code) }
                    ?? false
                if isTransient && transientRetriesUsed < maxTransientRetries {
                    transientRetriesUsed += 1
                    try? await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    continue
                }
                throw error
            }
        }
    }

    /// 시도 소요 시간(ms). `DispatchTime` 을 쓰는 이유는 `Date` 와 달리 시스템
    /// 시계 조정에 영향받지 않아서다 — 백그라운드 복귀 때 시계가 튀면 음수
    /// 소요가 섞인다.
    nonisolated static func elapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Strict-then-lossy decode shared with the redirect-resolver path that
    /// reuses an already-fetched body to avoid a second round-trip.
    static func decodeHTML(data: Data, encoding: String.Encoding) -> String {
        if let html = String(data: data, encoding: encoding) {
            return html
        }
        if encoding == .utf8 {
            return String(decoding: data, as: UTF8.self)
        }
        // Legacy-encoding lossy fallback: walk bytes and replace any sequence the
        // strict decoder rejected with U+FFFD so the user sees a partial page
        // instead of a hard failure (e.g. truncated CP949 multi-byte at EOF).
        return lossyDecode(data: data, encoding: encoding)
    }

    private static func lossyDecode(data: Data, encoding: String.Encoding) -> String {
        // Try chunks separated by ASCII boundaries; replace failed chunks with U+FFFD.
        var output = ""
        var idx = data.startIndex
        var pending = Data()

        func flush(_ buf: inout Data) {
            guard !buf.isEmpty else { return }
            if let s = String(data: buf, encoding: encoding) {
                output.append(s)
            } else {
                output.append("\u{FFFD}")
            }
            buf.removeAll(keepingCapacity: true)
        }

        while idx < data.endIndex {
            let byte = data[idx]
            if byte < 0x80 {
                // ASCII boundary — flush accumulated multibyte run, then append ASCII directly.
                flush(&pending)
                output.append(Character(UnicodeScalar(byte)))
            } else {
                pending.append(byte)
            }
            idx = data.index(after: idx)
        }
        flush(&pending)
        return output
    }

    /// Fire a best-effort `HEAD /` to every supported-site host so the
    /// shared `URLSession` opens a TLS + HTTP/2 connection pool entry
    /// per host. Subsequent real requests (list / detail fetches) reuse
    /// the pooled connection and skip the 300-700 ms TLS handshake that
    /// the perf log showed on the first access per host per session.
    ///
    /// All requests run in parallel on a detached `.utility` task, have
    /// a short 5-second timeout, ignore errors, and do *not* persist
    /// cookies — the goal is TLS pool population, not populating the
    /// shared `HTTPCookieStorage` with session trackers before the user
    /// has navigated anywhere. Worst case on failure is the same cold
    /// handshake the app used to pay, not a regression.
    ///
    /// Throttled via `PrewarmThrottle` to skip re-warming on rapid
    /// scenePhase bounces (notification peek, Control Center pull-down,
    /// quick foreground→background→foreground cycles). The pool stays
    /// warm for ~60 s of idle anyway, so re-warming more often than
    /// once every 30 s is pure noise.
    nonisolated static func prewarmConnections(hosts: [URL] = Site.allCases.map(\.baseURL)) {
        // Dedup as a defensive step — all 10 current `Site` cases have
        // distinct base hosts, but a future case sharing a host (or an
        // override caller passing duplicates) shouldn't fire the same
        // HEAD twice.
        let uniqueHosts = Set(hosts)
        Task.detached(priority: .utility) {
            guard await PrewarmThrottle.shared.claimRun() else { return }
            await withTaskGroup(of: Void.self) { group in
                for host in uniqueHosts {
                    group.addTask {
                        var request = URLRequest(url: host)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = 5
                        request.httpShouldHandleCookies = false
                        _ = try? await session.data(for: request)
                    }
                }
            }
        }
    }

    /// Same transient-retry policy as `fetchHTML`. Every current caller is a
    /// read-only POST endpoint (SLR / Ddanzi / Inven / Aagag comment loaders
    /// implemented as POST-as-GET), so a retry on -1005 / -1001 / -1004 cannot
    /// cause a double-submit. Without this, a single wedged keep-alive
    /// connection on the comment-host pool used to silently swallow the
    /// comment list — `PostDetailLoader` `try?`-wraps `fetchAllComments`,
    /// turning a transient network blip into "본문은 보이는데 댓글이 안 뜸".
    static func postForm(
        url: URL,
        parameters: [String: String],
        referer: URL? = nil,
        /// Override the outgoing `Content-Type` header for endpoints that
        /// expect a value not matching the URL-encoded body shape. The
        /// default is correct for normal form POSTs; only override when a
        /// server specifically branches on this header. See `DdanziParser`
        /// for the current caller that needs this.
        contentType: String = "application/x-www-form-urlencoded; charset=utf-8",
        session: URLSession = Networking.session
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = referer.scheme, let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }

        var comps = URLComponents()
        comps.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let maxAttempts = 2
        var attempt = 0
        while true {
            attempt += 1
            var attemptRequest = request
            if attempt == 1 {
                attemptRequest.timeoutInterval = firstAttemptIdleTimeout
            }
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    #if DEBUG
                    let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<binary>"
                    print("[Networking.postForm] HTTP \(http.statusCode) for \(url.absoluteString): \(preview)")
                    #endif
                    throw NetworkError.badResponse(http.statusCode)
                }
                return data
            } catch {
                let isTransient = (error as? URLError)
                    .map { Self.transientURLErrorCodes.contains($0.code) }
                    ?? false
                if isTransient && attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    continue
                }
                throw error
            }
        }
    }
}
