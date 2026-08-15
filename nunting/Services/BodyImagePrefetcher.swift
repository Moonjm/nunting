import Foundation
import SDWebImage

/// Look-ahead prefetcher for a detail screen's body images.
///
/// Body images render through `NetworkImage(visibilityGated: true)`, which
/// defers each fetch until the image scrolls into the viewport — that bounds
/// the fetch burst on a 30-image post, but it also means every scroll lands
/// on a *cold* image (gray placeholder → late fill). This coordinator warms
/// the next `window` images each time one becomes visible, at low priority,
/// so the user scrolls into cache hits without reintroducing the burst the
/// gate exists to prevent.
///
/// Bounded + dedup'd: each URL is prefetched at most once, and only `window`
/// ahead of the most-recently-seen image are ever in flight. Low priority
/// means on-screen (gated / eager) fetches always win the downloader's
/// concurrency slots — prefetch fills idle capacity only.
@MainActor
final class BodyImagePrefetcher {
    /// Body image URLs in document order. Index passed to
    /// `imageBecameVisible(at:)` is a position in this list.
    private let urls: [URL]
    private let window: Int
    /// `atsSafe` URLs that must never be prefetched — poster-backed 웃대
    /// 직접첨부 짤방(15 MB 급)뿐이다. 다운로드 자체가 비싼데 blur-up 포스터가
    /// 이미 대기 화면을 채워 룩어헤드의 실익이 거의 없다. 확장자 기반
    /// (`.webp`/`.gif`) 제외는 걷어냈다 — 그 근거였던 전-프레임 실체화는
    /// `lazyAnimatedContext` 가 원천에서 없앤다(`NetworkImage.skipsPrefetch`).
    /// They still occupy their slot in `urls` (index math / dedup unchanged).
    private let skipPrefetch: Set<URL>
    /// A dedicated instance (not `.shared`) so `cancel()` only drops this
    /// screen's prefetch tokens, never another consumer's. Note the
    /// underlying `SDWebImageDownloader` / `SDImageCache` are still the shared
    /// singletons — which is exactly why `.lowPriority` matters: prefetch and
    /// on-screen loads compete for the same 4 downloader slots, and the
    /// priority is what lets visible images win.
    private let prefetcher = SDWebImagePrefetcher()
    /// URLs already handed to the prefetcher — never re-issued.
    private var requested = Set<URL>()

    /// 표시 로드(`NetworkImage`)와 동일한 thumbnail 컨텍스트. thumbnail
    /// 컨텍스트는 SD 캐시 키를 `URL-Thumbnail({w,h},1)` 로 변형하므로,
    /// 여기와 표시 로드의 컨텍스트가 다르면 워밍이 엉뚱한 키에 저장돼
    /// 프리페치 전체가 무효가 된다 — `atsSafe` URL 일치(아래 doccomment)와
    /// 같은 결의 키-일치 불변식. internal 인 이유: 테스트가 이 불변식을 핀.
    let prefetchContext: [SDWebImageContextOption: Any]?

    /// 이미지별 override 컨텍스트(키는 `atsSafe` URL) — 파서 aspect 를 아는
    /// 극단 세로형은 표시 로드가 처음부터 tall 박스를 쓰므로, 공유 컨텍스트
    /// (표준 박스)로 워밍하면 캐시 키가 어긋나 look-ahead 가 무효가 된다.
    /// 해당 이미지만 tall 컨텍스트로 워밍한다.
    let contextByURL: [URL: [SDWebImageContextOption: Any]]

    init(
        // 룩어헤드 2장. 한때 메모리 선형 증가 때문에 3→2→1 로 줄였지만, 그 선형
        // 증가의 진짜 원인은 SwiftSoup 파싱 누수였고(2.13.5 업그레이드로 해결),
        // 룩어헤드와 무관했다 — 그래서 스크롤 체감이 더 나은 2 로 복원한다.
        // 프리페치는 .lowPriority(아래 prefetchURLs)라 4개 다운로더 슬롯을 on-screen
        // 로드에 양보하므로, 2장이어도 표시 이미지를 굶기지 않는다.
        urls: [URL],
        window: Int = 2,
        skipPrefetch: Set<URL> = [],
        thumbnailContext: [SDWebImageContextOption: Any]? = nil,
        contextByURL: [URL: [SDWebImageContextOption: Any]] = [:]
    ) {
        self.urls = urls
        self.window = window
        self.skipPrefetch = skipPrefetch
        self.prefetchContext = thumbnailContext
        self.contextByURL = contextByURL
    }

    /// URL 별 워밍 컨텍스트 — override 맵 우선, 없으면 공유 컨텍스트.
    /// internal 인 이유: 표시 로드와의 키-일치 불변식을 테스트가 핀.
    func prefetchContext(for url: URL) -> [SDWebImageContextOption: Any] {
        Self.lazyAnimatedContext(contextByURL[url.atsSafe] ?? prefetchContext)
    }

    /// 프리페치 컨텍스트에 **항상** 얹는 지연 디코드 지시자.
    ///
    /// `SDWebImagePrefetcher` 는 스스로 `animatedImageClass` 를 붙이지 않아,
    /// 이게 없으면 애니메이션 WebP/GIF 가 워밍 시점에 전 프레임을 실체화한다
    /// (287프레임/13.6MB 실측 9,032ms 가 `SDImageCache` 직렬 디코드 큐를 점유,
    /// Clien 본문 GIF 는 footprint 1.4GB peak). 종전엔 그래서 `.webp`/`.gif` 를
    /// 프리페치에서 통째로 뺐는데, 한국 게시판 본문 이미지의 상당수가 그 두
    /// 확장자라 룩어헤드가 사실상 무력했다. `SDAnimatedImage` 를 지정하면
    /// 워밍도 표시 경로(`AnimatedImage`)와 **같은 lazy 디코드**(같은 파일
    /// 27ms)로 열리므로 제외할 이유 자체가 사라진다 — 워밍이 버는 건
    /// 다운로드 + 디스크 저장 + 메모리 엔트리이고, 프레임 디코드는 재생
    /// 시점으로 그대로 미뤄진다.
    ///
    /// 캐시 키 불변식에 안전하다: SD 의 키는 `thumbnailPixelSize` 와
    /// `cacheKeyFilter` 만 변형하고 `animatedImageClass` 는 키에 안 들어간다
    /// (`SDWebImageManager.cacheKeyForURL:context:`). 덤으로 워밍이 표시
    /// 경로와 **같은 클래스**로 메모리 캐시를 채우게 돼, 정지컷이 섞여
    /// 들어가 움짤이 멈춰 보이던 오염 경로가 원천에서 닫힌다.
    nonisolated static func lazyAnimatedContext(
        _ base: [SDWebImageContextOption: Any]?
    ) -> [SDWebImageContextOption: Any] {
        var context = base ?? [:]
        context[.animatedImageClass] = SDAnimatedImage.self
        return context
    }

    /// The image at `index` became visible — warm the next `window` URLs that
    /// haven't been queued yet. No-op when `index` is out of range (e.g. a
    /// stale callback after the URL list changed) or when nothing fresh
    /// remains ahead.
    func imageBecameVisible(at index: Int) {
        let fresh = claimFreshURLs(forVisibleIndex: index)
        guard !fresh.isEmpty else { return }
        // `.lowPriority` yields the 4 downloader slots to on-screen loads;
        // prefetch only consumes otherwise-idle capacity.
        // override 컨텍스트(tall 박스) 이미지는 개별 발행 — prefetchURLs 는
        // 배치당 컨텍스트 하나라, 섞으면 캐시 키가 표시 로드와 어긋난다.
        let standard = fresh.filter { contextByURL[$0] == nil }
        if !standard.isEmpty {
            _ = prefetcher.prefetchURLs(standard, options: .lowPriority, context: Self.lazyAnimatedContext(prefetchContext), progress: nil, completed: nil)
        }
        for url in fresh where contextByURL[url] != nil {
            _ = prefetcher.prefetchURLs([url], options: .lowPriority, context: prefetchContext(for: url), progress: nil, completed: nil)
        }
    }

    /// The not-yet-requested `atsSafe` URLs in the `window` ahead of
    /// `index`, marking them requested as a side effect. Split out from
    /// `imageBecameVisible(at:)` so the window-bounds + dedup math is unit
    /// testable without driving `SDWebImagePrefetcher`'s side effects.
    ///
    /// `atsSafe` matches the exact URL `NetworkImage` loads, so the prefetch
    /// warms the same `SDImageCache` key the on-screen fetch will later hit —
    /// a raw `http://` URL would cache under a different key and the prefetch
    /// would be wasted.
    func claimFreshURLs(forVisibleIndex index: Int) -> [URL] {
        guard index >= 0 else { return [] }
        // The visible image is loaded by its on-screen `NetworkImage`, not by
        // the prefetcher — mark it requested so a later duplicate occurrence
        // of the same image isn't redundantly warmed.
        if index < urls.count { requested.insert(urls[index].atsSafe) }
        let start = index + 1
        let end = min(start + window, urls.count)
        guard start < end else { return [] }
        // Explicit loop rather than `filter { requested.insert(...).inserted }`
        // — mutating `requested` inside a functional chain is an anti-pattern
        // that would silently break under a future `.lazy`.
        var fresh: [URL] = []
        for url in urls[start..<end] {
            let safe = url.atsSafe
            // Mark requested regardless (dedup), but suppress the fetch for
            // skip-listed heavy webp — they'd block the serial decode queue.
            let isNew = requested.insert(safe).inserted
            if isNew && !skipPrefetch.contains(safe) { fresh.append(safe) }
        }
        return fresh
    }

    /// Stop any in-flight prefetch. Called when the overlay hides
    /// (`isOverlayVisible` → false) or the image set changes (post swap /
    /// pull-to-refresh) so a left-behind post doesn't keep warming its tail.
    /// The detail overlay is keep-alive (it survives dismissal with only an
    /// offset animation), so cancellation is driven by those explicit signals
    /// rather than `.onDisappear`, which doesn't fire on a normal dismiss.
    func cancel() {
        prefetcher.cancelPrefetching()
    }
}
