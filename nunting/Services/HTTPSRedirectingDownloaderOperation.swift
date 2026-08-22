import Foundation
import SDWebImage

/// SDWebImage downloader operation that rewrites `http://` redirect
/// Locations to `https://` before URLSession follows them.
///
/// ATS blocks `https → 302 → http` chains by default — Korean board image
/// CDNs frequently 302 through legacy `getfile.php` proxies that emit a
/// cleartext Location even when the final origin is reachable over HTTPS
/// (observed: fmkorea getfile → ext.fmkorea.com → plaync.co.kr; aagag
/// 65G 댓글의 GIF). `URL.atsSafe` only upgrades source URLs; this hook
/// extends the same upgrade to redirect targets so the chain survives.
///
/// If the target really doesn't support HTTPS, the upgraded request fails
/// fast at the TLS handshake — same end-user outcome as the ATS block
/// (placeholder + retry button) with clearer logs.
// `@unchecked Sendable` restates the conformance the ObjC parent
// (`SDWebImageDownloaderOperation`) already declares — Swift 6 requires
// subclasses to repeat inherited unchecked conformances even when
// nothing new is added. The downloader runs on its own NSOperationQueue
// and never mutates shared state from this subclass, so the unchecked
// promise stays accurate.
// `nonisolated`: 부모(SDWebImageDownloaderOperation)의 init/딜리게이트 선언이
// nonisolated 라, 기본 MainActor 격리 추론이 붙은 오버라이드는 Swift 6 모드에서
// "different actor isolation" 에러가 된다. 이 오퍼레이션은 자체 NSOperationQueue
// 에서 돌므로 main actor 소속이어서도 안 된다.
nonisolated class HTTPSRedirectingDownloaderOperation: SDWebImageDownloaderOperation, @unchecked Sendable {
    /// 이 오퍼레이션이 만들어진 시각 = 다운로더 큐에 들어간 순간. `fetchStart` 와의
    /// 차이가 **슬롯 대기 시간**이다 — 디코드가 오퍼레이션 안에서 돌고(`done` 은 그
    /// 뒤 barrier) 슬롯을 붙잡으므로(SDWebImageDownloaderOperation.m:363-425),
    /// 이미지가 몰린 글에서 대기가 생긴다면 이 값에 그대로 나타난다.
    /// 불변이라 `@unchecked Sendable` 약속을 깨지 않는다.
    private let enqueuedAt = Date()






    // Combination required for the ObjC runtime to actually install this
    // selector into the dispatch table when overriding an optional
    // protocol method (NSURLSessionTaskDelegate, declared on
    // SDWebImageDownloaderOperation via its `<SDWebImageDownloaderOperation>`
    // protocol conformance — see SDWebImageDownloaderOperation.h):
    //
    //   • `@objc(URLSession:...)` — pins the exact uppercase selector
    //     (Swift auto-bridge would otherwise lowercase it).
    //   • `dynamic` — forces ObjC runtime dispatch instead of Swift vtable,
    //     so SDWebImageDownloader's respondsToSelector / objc_msgSend chain
    //     can actually find this method.
    //   • no `final` on the class — Swift treats `final` as a hint to use
    //     static dispatch, which can leave the @objc entry unregistered.
    //
    // No `super` call. The parent class `SDWebImageDownloaderOperation`
    // never implements `willPerformHTTPRedirection` (the conformance is
    // protocol-only). The fallback "follow redirect as-is" lives instead
    // on the session delegate side in `SDWebImageDownloader.m`:
    // when the operation doesn't respond to this selector, the downloader
    // just invokes `completionHandler(request)` itself. Calling `super`
    // from here would hit NSObject and crash; we replicate that fallback
    // inline by invoking `completionHandler(rewritten)` directly.
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    dynamic override func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.upgradeHTTPToHTTPS(request))
    }

    /// 이미지 **다운로드 계층** 계측. `SDWebImageDownloader` 는 수집된 태스크 메트릭을
    /// 같은 포워딩 경로로 이 오퍼레이션에 넘긴다(`SDWebImageDownloader.m:541`) —
    /// 리다이렉트 훅과 같은 대문자 셀렉터 함정이 있어 `@objc(...)` + `dynamic` 이 필요하다
    /// (등록 여부는 `HTTPSRedirectingDownloaderOperationTests` 가 지킨다).
    ///
    /// 리다이렉트 훅과 **다른 점: `super` 를 반드시 부른다.** 부모는 이 셀렉터를 실제로
    /// 구현하고 있고(`SDWebImageDownloaderOperation.m:702` — `self.metrics = metrics`),
    /// 안 부르면 SD 가 노출하는 `metrics` 프로퍼티가 빈 채로 남는다.
    ///
    /// 소요 시간은 **마지막** 트랜잭션이 대표한다 — 리다이렉트 체인(fmkorea getfile
    /// → …)에서 실제 사진을 가져온 홉이 그것이다. 반면 슬롯 대기는 **첫** 트랜잭션의
    /// fetch 시작에서 잰다. 마지막 홉에서 재면 앞선 302 왕복이 통째로 대기로 잡히고,
    /// 우리는 그 백분위로 슬롯 폭을 정하므로 판정을 뒤집는다.
    @objc(URLSession:task:didFinishCollectingMetrics:)
    dynamic override func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        super.urlSession(session, task: task, didFinishCollecting: metrics)

        guard let tx = metrics.transactionMetrics.last,
              let host = tx.request.url?.host else { return }
        let phases = MediaLoadNetworkPhases(
            fetchStart: tx.fetchStartDate,
            firstFetchStart: metrics.transactionMetrics.first?.fetchStartDate,
            domainLookupStart: tx.domainLookupStartDate,
            domainLookupEnd: tx.domainLookupEndDate,
            connectStart: tx.connectStartDate,
            connectEnd: tx.connectEndDate,
            secureConnectionStart: tx.secureConnectionStartDate,
            secureConnectionEnd: tx.secureConnectionEndDate,
            requestStart: tx.requestStartDate,
            responseStart: tx.responseStartDate,
            responseEnd: tx.responseEndDate,
            reusedConnection: tx.isReusedConnection,
            networkProtocol: tx.networkProtocolName,
            statusCode: (tx.response as? HTTPURLResponse)?.statusCode,
            bytes: Int(tx.countOfResponseBodyBytesReceived))
        // 프리페치는 `.lowPriority` 로 나간다(`BodyImagePrefetcher` — 표시 로드가
        // 슬롯을 이기게 하려는 기존 의도). 대기의 정체를 가르는 축이 이것뿐이라
        // 이벤트에 실어 보낸다: 5초 기다린 요청이 프리페치인지 표시용인지.
        let isPrefetch = options.contains(.lowPriority)
        guard let event = MediaLoadEventDTO.network(host: host, phases: phases,
                                                    enqueuedAt: enqueuedAt,
                                                    prefetch: isPrefetch) else { return }
        // 이 콜백은 다운로더 세션 큐. 버퍼는 MainActor 소속이라 Sendable 인 DTO 만 넘긴다.
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
    }


    /// Returns the request with `http://` upgraded to `https://`; any other
    /// scheme passes through unchanged. Headers/body/method are preserved.
    /// Delegates the URL transform itself to `URL.atsSafe` so source-URL
    /// upgrades (Networking.swift) and redirect-URL upgrades share one
    /// rule — if we ever need a host blocklist for genuinely-http-only
    /// origins, it lives in one place.
    /// Static so tests can exercise the rewrite without spinning up an
    /// SDWebImage downloader.
    static func upgradeHTTPToHTTPS(_ request: URLRequest) -> URLRequest {
        guard let url = request.url, url.scheme?.lowercased() == "http" else { return request }
        var newReq = request
        newReq.url = url.atsSafe
        return newReq
    }
}
