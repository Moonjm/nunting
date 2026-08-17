import SwiftUI
import SDWebImage
import SDWebImageSwiftUI

/// SDWebImage-backed body / icon / sticker / poster image view.
/// Replaces every legacy `CachedAsyncImage` callsite with a single
/// configurable wrapper so the routing decision (placeholder vs not,
/// gated vs eager, natural-width clamp on/off) lives in the call site
/// instead of the loader.
///
/// Why one wrapper instead of one per caller:
/// - All callers want the same SDWebImage backing (libwebp animated
///   coder, shared `SDImageCache`, request dedup) — only the rendering
///   policy differs.
/// - The toggles map cleanly onto `CachedAsyncImage`'s former params
///   (`visibilityGated`, `showsPlaceholder`, `clampsToNaturalWidth`),
///   so the migration is a 1-for-1 rename + param transcribe at each
///   call site rather than a redesign.
struct NetworkImage: View {
    let url: URL

    /// Parser-supplied aspect ratio. When set, the placeholder reserves
    /// the final frame size from first layout — stops the 120pt-stub →
    /// natural-height jump that shifts scroll position when body images
    /// late-resolve. Falls back to a `.onSuccess`-derived
    /// `measuredAspect` when the parser couldn't determine it from the
    /// HTML (older posts / sites without `<img width=…>` markup).
    var aspectRatio: CGFloat? = nil

    /// Optional low-res still (e.g. humoruniv's `thumb.php` ~2 KB thumbnail)
    /// shown — heavily blurred — *behind* the loading spinner while the real
    /// image downloads. Large animated WebP bodies (354-frame / 15 MB 짤방)
    /// take seconds to arrive and decode; without this the slot was a flat
    /// gray box that read as "broken" rather than "loading" (the symptom that
    /// motivated this). The poster fetch is itself gated — it only fires from
    /// the loading placeholder, which only renders once the viewport gate is
    /// open — so off-screen gated images don't eagerly pull thumbnails.
    /// `nil` (every non-humoruniv caller today) → spinner over plain surface.
    var posterURL: URL? = nil

    /// Long-edge cap in *points*. Multiplied by `displayScale` to derive
    /// the pixel cap SD's `imageThumbnailPixelSize` expects, so callers
    /// pass the same units the legacy `maxDimension` param used. `nil`
    /// = decode at native resolution (rare; mostly for callers that
    /// know the source is already small).
    var thumbnailMaxPointSize: CGFloat? = nil

    /// 비정방 다운샘플 박스의 *폭* 캡(포인트). 본문 사진용 — 정사각 캡
    /// (`thumbnailMaxPointSize`)은 긴 변을 깎으므로 aagag 세로 패널
    /// (800×6000)이 뭉개지지만, `imageThumbnailPixelSize` 는 aspect 유지
    /// bounding box 라 폭만 캡하고 높이를 사실상 무제한으로 주면 세로
    /// 패널은 박스 안에 들어가 무손실 통과하고 일반 대형 사진(4000×3000)
    /// 만 화면폭으로 다운샘플된다 — 디코드 시간과 비트맵 메모리(48MB→
    /// ~4MB)가 줄고, 직렬 디코드 큐에서 대형 사진이 뒤 이미지를 막는
    /// 효과도 완화. `thumbnailMaxPointSize` 가 있으면 그쪽이 우선(기존
    /// 아이콘/스티커/포스터 호출부 보호).
    var thumbnailMaxPointWidth: CGFloat? = nil

    /// When `true`, defers the SDWebImage fetch until this image's
    /// frame intersects the enclosing ScrollView's viewport. Used by
    /// body images so a 30-image post doesn't queue 30 fetches at the
    /// moment the detail commits — only viewport-region images trigger
    /// work.
    ///
    /// When `false` (icons / stickers / posters), the fetch starts the
    /// moment the view materialises. Justification: those callers sit
    /// in fixed slots that should fill on first appearance, and gating
    /// them would add `onScrollVisibilityChange` callback overhead per
    /// 100+ comment icons for minimal fetch-deferral benefit (icons
    /// are ~5 KB each, not the body-image MB scale that motivated the
    /// gate).
    var visibilityGated: Bool = false

    /// When `true`, the decoded image is *dropped* (swapped back to a
    /// frame-pinned placeholder) once the view scrolls fully off-screen, and
    /// re-decoded on return. Bounds a long post's live decode to ~viewport
    /// worth instead of holding every body image's bitmap for the whole post.
    ///
    /// Why body images need this: the article body is an **eager `VStack`**
    /// (PostDetailView), chosen so every block's height stays pinned —
    /// dropping that for a `LazyVStack` reintroduced the "back-drag from
    /// comments → blank screen" collapse. But eager means SwiftUI never
    /// derealizes off-screen rows, so each body image's `SDAnimatedImageView`
    /// keeps its decoded bitmap (a tall aagag panel downsamples to width-only
    /// → ~40 MB each) *and* its animation frame buffer alive for the whole
    /// post. A 15-panel webtoon held ~640 MB of un-evictable view-owned decode
    /// (confirmed: `SDImageCache.clearMemory()` recovered almost none of it) —
    /// the frontmost-OOM driver.
    ///
    /// This flag keeps the layout eager (height stays pinned via
    /// `effectiveAspect` — see `pinnedToAspect`, which is what actually makes
    /// the swap invisible) while making the *decode* viewport-bound:
    /// off-screen → placeholder → bitmap freed; on-screen → re-shown from cache.
    /// Trades a re-decode (CPU, brief spinner if evicted past SD's memory
    /// cache) for a hard ceiling on resident decode — the right trade when the
    /// alternative is a jetsam kill. Release is debounced (`releaseDelayNanos`)
    /// so a small scroll across the viewport edge doesn't thrash.
    var releasesWhenOffscreen: Bool = false

    /// When `false`, the loading state and the failed state both
    /// render as `Color.clear` instead of the gray box / retry button.
    /// Used for inline icons (comment level / auth) where the
    /// placeholder visibly flashes in and looks worse than a blank
    /// spot — and where "broken-icon" UI would be more distracting
    /// than the icon's absence.
    var showsPlaceholder: Bool = true

    /// When `true`, caps the rendered frame at the source's natural
    /// point width once known. Mirrors the browser
    /// `width: auto; max-width: 100%` behaviour boards apply to body
    /// `<img>` tags — keeps small attachments (e.g. SLR's 127×100
    /// failed-upload placeholder) at their natural size instead of
    /// upscaling 3× into a full-column white box.
    var clampsToNaturalWidth: Bool = false

    /// 파서도, 디코드 실측도 종횡비를 못 줄 때 쓰는 최후의 예약 비율(폭/높이).
    /// 본문 이미지 호출부만 설정한다(아이콘/스티커는 nil 유지). 크기 정보를
    /// 안 주는 보드의 이미지 슬롯이 0 높이로 무너져 뷰포트에 수십 장이 겹쳐
    /// 한꺼번에 디코드되는 것을 막고(throttle), `releasesWhenOffscreen` 의
    /// `effectiveAspect != nil` 가드를 통과시켜 off-screen 디코드 폐기가 동작하게
    /// 한다. 디코드되면 `measuredAspect` 가 이 값을 덮어써 실제 비율로 보정된다.
    var fallbackAspect: CGFloat? = nil

    /// Fired once, the first time this image becomes eligible to load — for
    /// gated images that's when the viewport gate opens; for eager
    /// (`visibilityGated == false`) images it's on first appear. Body images
    /// use it to drive `BodyImagePrefetcher` look-ahead; default `nil` so
    /// icon / sticker / poster callers pay nothing.
    var onBecameVisible: (() -> Void)? = nil

    // Per-image priority intentionally absent. The legacy `loadPriority:
    // index` integer queue is not faithfully expressible against
    // SDWebImage's binary `.highPriority` flag (only the front-of-queue
    // bucket exists) — the obvious mapping degenerated to "image 0
    // gets the bump, images 1..N race FIFO," which preserves none of
    // the ordering the comment claimed. Drop the parameter rather than
    // ship a misleading no-op; if measurement (plan section 10) shows
    // that fetch-queue depth on entry is the dominant first-image
    // latency cost, revisit with `SDWebImageDownloaderConfig.executionOrder`
    // = `.LIFO` plus the right enqueue order.

    @Environment(\.displayScale) private var displayScale
    @State private var hasBeenVisible = false
    @State private var didReportVisible = false
    @State private var measuredAspect: CGFloat?
    /// 1차 디코드가 높이 캡(8192)에 실제로 닿았는지 — 측정 aspect 기반 tall
    /// 리마운트의 발동 조건. 좁지만 작은 이미지(예: 100×1000)는 환산 높이가
    /// 8192 를 넘어도 이미 native 완전 디코드라 재디코드가 순수 낭비다.
    @State private var measuredDecodeHitHeightCap = false
    @State private var measuredNaturalPointWidth: CGFloat?
    @State private var failed = false
    /// Current viewport intersection for `releasesWhenOffscreen` images.
    /// Starts `true` so eager (image-0) and pre-gate images render without
    /// waiting for a first visibility callback; gated images are still held
    /// back by `hasBeenVisible`, so this defaulting to `true` never leaks an
    /// off-screen gated image on-screen.
    @State private var isOnscreen = true
    /// Pending debounced release; cancelled if the view re-enters the viewport
    /// before it fires.
    @State private var releaseTask: Task<Void, Never>?

    #if DEBUG
    /// 테스트 전용 수신 카운터. 이 구독이 살아 있는지를 **뷰 계층으로는
    /// 확인할 수 없다** — SwiftUI 는 실패 UI(`Text`/`Button`)를 호스팅 뷰의
    /// 레이어에 직접 그려서 UIView 도 접근성 요소도 남기지 않는다(계층 덤프로
    /// 확인). 그래서 "방송을 받긴 하는가" 만 여기서 세어 회귀를 막는다 —
    /// Codex 리뷰 P2 가 지적한 결함이 정확히 "받는 쪽이 없음" 이었다.
    @MainActor static var failuresClearedReceiptsForTests = 0
    #endif

    /// Off-screen dwell before a `releasesWhenOffscreen` image drops its
    /// decode. Long enough that a small scroll wobble across the viewport edge
    /// (or a fast fling that briefly uncovers a row) doesn't drop-and-redecode;
    /// short enough that the resident decode set stays near viewport size.
    private static let releaseDelayNanos: UInt64 = 500 * 1_000_000

    var body: some View {
        let effectiveAspect = Self.effectiveAspect(
            aspectRatio: aspectRatio,
            measuredAspect: measuredAspect,
            fallbackAspect: fallbackAspect
        )
        // Load gate (gated images wait for the viewport) AND decode gate
        // (`releasesWhenOffscreen` images drop their bitmap off-screen). Both
        // fall through to `gatePlaceholder`. 어느 쪽으로 뒤집혀도 행 크기가 안
        // 변하는 건 아래 `pinnedToAspect` 덕분이다 — 브랜치가 스스로 크기를
        // 맞춘다고 믿으면 안 된다(그렇게 믿었다가 난 버그가 pinnedToAspect 주석).
        let showsHeavyImage = Self.shouldShowHeavyImage(
            visibilityGated: visibilityGated,
            hasBeenVisible: hasBeenVisible,
            releasesWhenOffscreen: releasesWhenOffscreen,
            isOnscreen: isOnscreen
        )

        Group {
            if failed {
                if showsPlaceholder {
                    // 핀된 슬롯 안에서는 상자를 채우기만 한다 — 자기 최소 높이를
                    // 고집하면 행 밖으로 삐져나온다(overlay 는 부모에 제약되지
                    // 않고 클립되지도 않는다). `pinnedToAspect` 참고.
                    retryButton(pinned: effectiveAspect != nil)
                } else {
                    // Match browser behaviour for broken `<img>` on
                    // decorative slots — render nothing, don't draw
                    // attention to the failure.
                    Color.clear
                }
            } else if showsHeavyImage {
                // 모든 본문 이미지(대형 애니메이션 WebP 포함)를 `AnimatedImage`
                // 로 렌더한다. 종전엔 heavy webp 를 first-frame 정지컷으로
                // 강등했는데(#82), 직접 타이밍 재측정 결과 14s 프리즈의 진범은
                // `animatedImageClass` 없이 도는 디코드(프리페처 경로)의 전
                // 프레임 실체화였다 — 287프레임/13.6MB 실측: lazy 27ms vs
                // 실체화 9,032ms. `AnimatedImage` 는 항상 lazy
                // `SDAnimatedImage` 로 열므로(뷰어와 동일 경로) 인라인 재생이
                // 안전하다. 프리페치도 같은 lazy 경로를 쓴다
                // (`BodyImagePrefetcher.lazyAnimatedContext`).
                animatedBodyImage
                // 디코드 박스가 바뀌면 강제 리마운트 — SDWebImageSwiftUI 는 URL
                // 이 같으면 context 변경만으로 재디코드하지 않는다. 파서가
                // aspect 를 안 주는 보드(aagag 등)의 극단 세로형은 1차 디코드의
                // measuredAspect 가 tall 재배분을 발동시키는 순간 키가 딱 한 번
                // 바뀌어(std 박스 → tall 박스) 선명한 2차 디코드로 교체된다.
                // 데이터는 디스크 캐시에 있어 네트워크 재요청은 없다.
                .id(decodeBoxID)
            } else {
                // Placeholder for two cases, both frame-pinned by
                // `effectiveAspect` so the swap never resizes the row:
                //  1. gated image not yet scrolled into view (never loaded), and
                //  2. `releasesWhenOffscreen` image scrolled away (decode dropped).
                // Frame-identical to the loading placeholder's base, so the swap
                // back to the heavy image only *adds* the spinner / blurred
                // poster rather than resizing. Deliberately bare: not loading
                // right now → no spinner and — crucially — no poster fetch.
                gatePlaceholder
            }
        }
        .pinnedToAspect(effectiveAspect)
        .frame(maxWidth: clampsToNaturalWidth ? (measuredNaturalPointWidth ?? .infinity) : .infinity)
        .gateOnVisibility(enabled: visibilityGated || releasesWhenOffscreen) { visible in
            // visibility callback 자체는 SwiftUI 의 view-update 사이클
            // 안에서 fire 될 수 있음 → 검사+쓰기 둘 다 async block 안으로
            // 묶어 view-update 중 @State 읽기/쓰기 표면을 0 으로.
            DispatchQueue.main.async {
                if visible {
                    // 화면 재진입: 대기 중인 release 취소 + 디코드 복귀, 그리고
                    // (gated 라면) 최초 1회 로드 게이트 개방 + 프리페치 보고.
                    releaseTask?.cancel()
                    releaseTask = nil
                    if !isOnscreen { isOnscreen = true }
                    // 로드 게이트는 gated 이미지에만 의미 — non-gated(image-0)는
                    // 이미 loadEligible 이므로 hasBeenVisible("게이트 열림")을
                    // 건드리지 않는다(프리페치 보고는 onAppear 가 담당).
                    if visibilityGated, !hasBeenVisible {
                        hasBeenVisible = true
                        reportVisibleIfNeeded()
                    }
                } else if releasesWhenOffscreen, isOnscreen, releaseTask == nil,
                          effectiveAspect != nil {
                    // 완전히 화면 밖(threshold 0): 디바운스 후 디코드 폐기. 이미
                    // release 예약 중(releaseTask != nil)이거나 이미 해제됨
                    // (!isOnscreen)이면 재예약 안 함 — onScrollVisibilityChange 가
                    // invisible 을 중복 emit 해도 디바운스 타이머가 리셋돼 release
                    // 가 무한 연기되는 것(starvation) 방지.
                    //
                    // effectiveAspect != nil 가드: placeholder 를 핀할 aspect 가
                    // 없으면 폐기 시 높이가 무너져 eager VStack 스크롤 위치가
                    // 어긋난다(Req2). 본문 이미지는 `fallbackAspect: 1.0` 이 항상
                    // 깔려 이 가드를 바로 통과 → 첫 디코드 전이라도 1:1 로 핀된 채
                    // release 된다(재진입 시 1:1 → measuredAspect 로 보정). aspect
                    // 를 안 주는 비-본문 release 호출부가 생기면 그땐 이 가드가
                    // 종전처럼 미측정 이미지를 보호한다.
                    scheduleRelease()
                }
            }
        }
        .onAppear {
            // Eager (non-gated) images never receive a visibility callback,
            // so report on appear instead — keeps the prefetch look-ahead
            // anchored at the first body image (which loads immediately).
            if !visibilityGated { reportVisibleIfNeeded() }
        }
        // 실패 이력이 통째로 비워졌다(포그라운드 복귀) — 굳어 있던 실패
        // 슬롯을 되살린다. 블랙리스트만 풀면 화면은 그대로다: `failed` 는
        // 이 뷰의 @State 이고 상세 오버레이는 keep-alive 라 뷰가 살아 있어
        // 재평가만으론 안 풀린다(Codex 리뷰 P2). 실패가 아닌 슬롯은 값만
        // 읽고 아무것도 하지 않는다.
        .onReceive(NotificationCenter.default.publisher(
            for: ImageRetryPolicy.failuresClearedNotification)) { _ in
            #if DEBUG
            Self.failuresClearedReceiptsForTests += 1
            #endif
            if failed { failed = false }
        }
        #if DEBUG
        .task(id: url) {
            // DEBUG misuse guard, ported from `CachedAsyncImage`. Only
            // applies to gated callers — `onScrollVisibilityChange`
            // silently no-ops outside `ScrollView` per Apple's contract,
            // and a gated image stuck on its placeholder forever is the
            // worst kind of bug to chase.
            guard visibilityGated else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !hasBeenVisible
            else { return }
            print("[NetworkImage] WARNING: gated image at \(url) hasn't received an onScrollVisibilityChange callback after 1s — is it inside a ScrollView?")
        }
        #endif
    }

    /// Default body-image view: animates inline via `AnimatedImage`
    /// (libwebp). `.atsSafe` upgrades plain `http://` to `https://` so
    /// ATS-clean CDNs serve through without an `NSAllowsArbitraryLoads`
    /// exception — board CDNs that publish their canonical `<img src>` as
    /// `http://` (carisyou, some tistory mirrors) otherwise flooded the retry
    /// placeholder after the SD migration.
    private var animatedBodyImage: some View {
        // 한때 여기서 메모리 캐시의 "오염"(정지 UIImage) 엔트리를 로드 전에
        // 선제 제거했다 — 구버전 first-frame 정지컷 경로(#82)가 같은 키에
        // 남긴 잔재를 집어가면 움짤이 멈춰 보였기 때문. 지웠다. 그 생산자가
        // 이제 없다: first-frame 게이트는 #141 에서 제거됐고, 남은 다른
        // 생산자였던 프리페치도 `lazyAnimatedContext` 로 표시 경로와 같은
        // 클래스를 저장한다. 메모리 캐시는 프로세스 수명이라 이전 실행분이
        // 넘어올 일도 없다.
        //
        // 반대로 비용은 실재했다. 정적 webp 는 표시 경로에서도 최종적으로
        // 평범한 `UIImage` 로 캐시된다(`SDAnimatedImage` 로 열려도
        // `sd_isAnimated == false` 면 force-decode 가 평범한 UIImage 사본을
        // 돌려준다 — `SDImageCoderHelper.shouldDecodeImage:policy:`). 즉
        // "webp 인데 SDAnimatedImage 가 아니면 오염" 이라는 판정은 정적 webp
        // 전체에 대한 오탐이라, 남겨두면 프리페치가 채운 정상 엔트리를 표시
        // 직전에 도로 지워 룩어헤드를 무효화한다.
        AnimatedImage(url: url.atsSafe, context: thumbnailContext) {
            loadingPlaceholder
        }
        .onSuccess { image, _, cacheType in handleLoadSuccess(image, cacheType: cacheType) }
        .onFailure { error in handleLoadFailure(error) }
        // Cap decoded-frame memory for animated WebP/GIF (짤방 are 100-300
        // frames; SDAnimatedImageView's default `maxBufferSize = 0` decodes
        // all frames upfront → 60-100 MB per long animation, a jetsam driver).
        .maxBufferSize(16 * 1024 * 1024)
        // `.purgeable(true)` maps to `clearBufferWhenStopped`: release decoded
        // frames when the animation stops (off-screen via LazyVStack recycle).
        .purgeable(true)
        .resizable()
        .scaledToFit()
    }

    /// 디스크 히트를 메모리 캐시로 승격한다.
    ///
    /// SDWebImage 5.21.7 의 디스크 조회 경로는 **메모리 캐시에 되쓰지 않는다**
    /// — `SDImageCache.m` 의 `queryDiskImageBlock` 이 `shouldCacheToMemory` 를
    /// 계산만 하고 `storeImageToMemory:` 를 부르는 곳이 없다(소스 확인).
    /// 메모리 저장은 **다운로드 직후 한 번**뿐이라, 한 번 디스크에 들어간
    /// 이미지는 그 뒤 표시할 때마다 디스크 읽기 + 디코드를 다시 문다.
    ///
    /// 본문 이미지엔 그 비용이 크다 — 기기 실측(aagag 세로 패널 2장):
    /// 백그라운드 왕복마다 `src=disk` 0.5s / 1.2~4.2s, 그동안 슬롯이 흰 채로
    /// 남는다. `releasesWhenOffscreen` 이 디코드를 버리는 설계라 재조회가
    /// 잦은데, 그 재조회가 전부 풀 디코드로 떨어지고 있었다.
    ///
    /// 되쓰기의 메모리 성격은 뷰가 붙들던 것과 다르다: NSCache 소유라
    /// 압박이 오면 시스템이 걷어간다(뷰 소유 비트맵은 그러지 못해 OOM 의
    /// 원인이었다). 상한은 `SDWebImageSetup` 의 200MB.
    private func promoteToMemoryCache(_ image: PlatformImage, cacheType: SDImageCacheType) {
        guard cacheType == .disk,
              let key = SDWebImageManager.shared.cacheKey(for: url.atsSafe,
                                                          context: thumbnailContext)
        else { return }
        SDImageCache.shared.storeImage(toMemory: image, forKey: key)
    }

    /// Shared `.onSuccess` handler for the body-image path.
    ///
    /// SDWebImage decodes UIImages at the device scale (≈3 on retina), so
    /// `image.size.width` is the *point* width = pixel width / scale.
    /// Multiplying back by `image.scale` recovers the source pixel count,
    /// matching the legacy `CachedAsyncImage` (scale-1) convention — without
    /// it `clampsToNaturalWidth` shrinks every body image to a third of its
    /// frame on retina. `DispatchQueue.main.async` defers the `@State` write
    /// past the in-flight render (SD can fire `.onSuccess` synchronously on a
    /// memory-cache hit, which would trip "Modifying state during view update").
    private func handleLoadSuccess(_ image: PlatformImage, cacheType: SDImageCacheType) {
        promoteToMemoryCache(image, cacheType: cacheType)
        let aspect: CGFloat? = (image.size.height > 0) ? image.size.width / image.size.height : nil
        let naturalPointWidth = image.size.width * image.scale
        let decodedPixels = CGSize(width: image.size.width * image.scale,
                                   height: image.size.height * image.scale)
        DispatchQueue.main.async {
            if measuredAspect == nil, let aspect { measuredAspect = aspect }
            if Self.decodeWasHeightCapped(decodedPixels: decodedPixels) {
                measuredDecodeHitHeightCap = true
            }
            // 갱신 규칙은 resolvedNaturalWidth 참조 — "한 번만" 래치하면 극단
            // 세로형의 1차(다운샘플) 폭이 고정돼 2차 선명 디코드 후에도
            // clampsToNaturalWidth 가 프레임을 1차 폭에 묶는다.
            measuredNaturalPointWidth = Self.resolvedNaturalWidth(
                current: measuredNaturalPointWidth, incoming: naturalPointWidth)
        }
    }

    /// natural width 갱신 규칙 — 더 큰(선명한) 디코드가 오면 따라 커지고,
    /// 더 작은 값(다운샘플 1차 재발화 등)으로는 되돌아가지 않는다. 다운샘플
    /// 디코드의 "natural" 은 원본이 아니라 디코드 폭이므로 max 가 원본에 가장
    /// 근접한 추정치다.
    nonisolated static func resolvedNaturalWidth(current: CGFloat?, incoming: CGFloat) -> CGFloat {
        max(current ?? 0, incoming)
    }

    private func handleLoadFailure(_ error: Error) {
        // 취소는 실패가 아니다 — failed 로 승격하면 retry UI 전환으로
        // AnimatedImage 가 뷰에서 제거되며 후속 로드까지 dismantle-취소돼
        // "다시 시도" 가 고착된다 (실측: aagag 첫 진입, SD 2002 "cancelled
        // during querying the cache"). 무시하면 뷰가 살아 있는 한 다음
        // updateUIView 가 same-URL/no-image 경로로 자동 재로드한다.
        guard !Self.isCancellation(error) else { return }
        DispatchQueue.main.async { failed = true }
    }

    /// SD/URLSession 의 취소 신호 판별 — 뷰 교체·identity 변경·로드 경합에서
    /// 이전 오퍼레이션이 취소될 때 onFailure 로 전달되는 에러들.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SDWebImageErrorDomain && ns.code == SDWebImageError.cancelled.rawValue {
            return true
        }
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return true
        }
        return false
    }

    /// 표시 게이트 진리표 — `static` 이라 4-corner 케이스를 단위 테스트로 핀
    /// (`thumbnailContext`/`isCancellation` 과 같은 추출 패턴). 두 게이트의 AND:
    /// - 로드 게이트: gated 이미지는 `hasBeenVisible`(뷰포트 진입) 전엔 안 뜸.
    /// - 디코드 게이트: `releasesWhenOffscreen` 이미지는 off-screen(`!isOnscreen`)
    ///   에서 비트맵을 폐기(placeholder 로). 둘 다 통과해야 heavy 이미지를 그린다.
    /// gated + 미진입 이미지는 `isOnscreen` 기본값(true) 과 무관하게 항상 false
    /// — off-screen gated 누출 불변식.
    /// 한때 여기에 `appActive`(scenePhase != .background) 축이 하나 더 있었다 —
    /// 백그라운드 진입 시 on-screen 본문 디코드까지 버려 suspend 중 footprint 를
    /// 줄이려던 장치. 제거했다. 이유는 측정이다:
    ///  - 아끼는 게 없다. 뷰가 놓아도 같은 비트맵을 `SDImageCache` 가 들고
    ///    있으므로(promoteToMemoryCache) 실제로 해제되는 메모리가 없다.
    ///  - 그런데 복귀 비용은 확실하다. 시스템이 백그라운드에서 NSCache 를
    ///    걷어가므로(기기 실측: 저장 직후 readback=ok, 같은 키가 복귀 시
    ///    mem=miss) 복귀할 때마다 디스크 재디코드를 문다 — 세로 패널 장당
    ///    0.5~2.9s, 그동안 슬롯이 흰 채로 남는다.
    /// OOM ratchet 의 진짜 원인은 SwiftSoup `.select()` 누수였고 2.13.6 으로
    /// 해소됐다(peak 3.27GB→0.58GB). 뷰포트 기반 해제(`isOnscreen`)는 그와
    /// 별개의 실측(15패널 웹툰 640MB 뷰-소유 디코드)에 근거하므로 그대로 둔다.
    /// 표시/예약에 쓸 종횡비 결정 — 우선순위: 디코드 실측값 > 파서 선언값 >
    /// fallback. `static` 이라 우선순위 계약을 단위테스트로 핀. fallback 이
    /// nil 이면(아이콘/스티커 등 비-본문 호출부) 셋 다 없을 때 nil 을 반환해
    /// 종전 `pinnedToAspect(nil)` no-op 동작을 유지한다.
    ///
    /// 실측값이 파서값보다 앞서는 이유 — `pinnedToAspect` 가 이 값으로 행 높이를
    /// **확정**하기 때문이다. 종전엔 이 함수가 파서값을 돌려줘도 디코드 후
    /// `scaledToFit` 이 실제 비율로 행을 다시 잡아 틀린 파서값이 스스로 교정됐다.
    /// 이제 그 교정 경로가 없으므로, 파서값을 계속 우선하면 `<img width height>`
    /// 가 실물과 다른 사이트에서 이미지가 상자 안에 레터박스로 갇힌다. 파서값은
    /// **디코드 전 예약**에만 쓰고(그 구간엔 실측값이 없어 자연히 파서값이 선택
    /// 된다), 실물이 확인되면 실물을 따른다 — 화면에 나오는 결과는 종전과 같다.
    nonisolated static func effectiveAspect(
        aspectRatio: CGFloat?,
        measuredAspect: CGFloat?,
        fallbackAspect: CGFloat?
    ) -> CGFloat? {
        measuredAspect ?? aspectRatio ?? fallbackAspect
    }

    /// 본문 이미지 프리페치 제외 판정 — BodyImagePrefetcher 입력(PostDetailView
    /// 의 skip 목록) 전용.
    ///
    /// 스킵 대상은 poster-backed(웃대 직접첨부 짤방) 하나다. 그 파일들은
    /// 15MB 급이라 **다운로드 자체**가 비싼데, blur-up 포스터가 이미 대기
    /// 화면을 채우고 있어 룩어헤드로 벌 게 거의 없다.
    ///
    /// 종전엔 `.webp`/`.gif` 확장자도 전부 스킵했다. 근거는 프리페처가
    /// `animatedImageClass` 없이 디코드해 전 프레임을 즉시 실체화한다는
    /// 것이었다(287프레임/13.6MB 실측 9,032ms 가 `SDImageCache` 직렬 큐를
    /// 점유 → #82 의 14s 프리즈, Clien 본문 GIF footprint 1.4GB peak). 그런데
    /// 그건 프리페치 컨텍스트를 안 채운 탓이지 확장자 탓이 아니었다 —
    /// `BodyImagePrefetcher.lazyAnimatedContext` 가 워밍에도 뷰어/인라인과
    /// 같은 lazy `SDAnimatedImage`(같은 파일 27ms)를 지정하면서 원천에서
    /// 사라졌다. 한국 게시판 본문 이미지의 상당수가 그 두 확장자라, 스킵을
    /// 유지하면 룩어헤드가 사실상 무력했다.
    nonisolated static func skipsPrefetch(url: URL, posterURL: URL?) -> Bool {
        posterURL != nil
    }

    nonisolated static func shouldShowHeavyImage(
        visibilityGated: Bool,
        hasBeenVisible: Bool,
        releasesWhenOffscreen: Bool,
        isOnscreen: Bool
    ) -> Bool {
        let loadEligible = !visibilityGated || hasBeenVisible
        return loadEligible && (!releasesWhenOffscreen || isOnscreen)
    }

    /// Fire `onBecameVisible` at most once. Called from the gate-open path
    /// (gated) and from `.onAppear` (eager); the `didReportVisible` latch
    /// makes repeated appears / callbacks idempotent.
    private func reportVisibleIfNeeded() {
        guard !didReportVisible else { return }
        didReportVisible = true
        onBecameVisible?()
    }

    /// Debounced off-screen release: after `releaseDelayNanos` of continuous
    /// invisibility, flip `isOnscreen` so the heavy image view leaves the tree.
    /// The new win is dropping the **static decoded bitmap** (the ~40 MB tall
    /// panels) — the animation frame buffer was already released off-screen by
    /// `.purgeable(true)`/`clearBufferWhenStopped`, but that did nothing for
    /// still images, which is where the eager-VStack memory actually piled up.
    /// A re-entry (`visible == true`) cancels the pending task before it fires;
    /// re-scheduling cancels any prior pending release first.
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.releaseDelayNanos)
            guard !Task.isCancelled else { return }
            isOnscreen = false
            releaseTask = nil
        }
    }

    /// Pre-load state for gated images that haven't scrolled into view:
    /// plain surface (or clear for decorative slots). No spinner, no poster.
    @ViewBuilder
    private var gatePlaceholder: some View {
        if showsPlaceholder {
            Color("AppSurface2")
        } else {
            Color.clear
        }
    }

    /// In-flight load state: a centered spinner over the surface, plus — when
    /// a `posterURL` exists — the low-res still scaled to fill and heavily
    /// blurred behind it (blur-up). `Color("AppSurface2")` stays the sizing
    /// anchor so the frame matches `gatePlaceholder` exactly; the poster and
    /// spinner are overlays that fill / center within it, then `.clipped()`
    /// trims the blur bleed. SDWebImage swaps this whole view out for the real
    /// image on `.onSuccess`.
    @ViewBuilder
    private var loadingPlaceholder: some View {
        if showsPlaceholder {
            Color("AppSurface2")
                .overlay {
                    if let posterURL {
                        AnimatedImage(url: posterURL.atsSafe) {
                            Color.clear
                        }
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 18, opaque: true)
                        .allowsHitTesting(false)
                    }
                }
                .overlay { ProgressView() }
                .clipped()
        } else {
            Color.clear
        }
    }

    /// 실패 슬롯의 재시도 UI. `pinned` 이면 프레임을 `pinnedToAspect` 상자에
    /// 맡기고(채우기만), 아니면 종전대로 최소 120pt 를 스스로 확보한다 —
    /// 비율을 모르는 호출부(아이콘/스티커)는 상자가 없어 그 최소치가 유일한
    /// 탭 영역이다.
    private func retryButton(pinned: Bool) -> some View {
        Button {
            // SD 의 실패 URL 블랙리스트에서 먼저 뺀다 — 이게 없으면 버튼이
            // 거짓말이 된다. 블랙리스트에 걸린 URL 은 네트워크를 타지 않고
            // 즉시 같은 실패로 되돌아오므로(실측 0.00s), 눌러도 화면은 그대로
            // "다시 시도" 다(`ImageRetryPolicy` 참조).
            ImageRetryPolicy.shared.prepareRetry(for: url)
            failed = false
            // Force the gate open on retry — if the user is tapping
            // they're plainly looking at it. Gated images that haven't
            // had a visibility callback yet would otherwise stay on
            // the placeholder after the failed → not-failed flip.
            hasBeenVisible = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                Text("다시 시도")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity,
                   minHeight: pinned ? nil : 120,
                   maxHeight: pinned ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 디코드 박스의 identity 키. tall 재배분 박스(높이 > 8192)일 때만 크기를
    /// 키에 반영 — 그 외 경로는 전부 "std" 로 고정한다. containerWidth 가
    /// 0→측정값으로 바뀌거나 native↔legacy 박스가 오가는 일반 케이스에서
    /// 리마운트(=전체 재디코드)가 발생하면 안 되기 때문. tall 박스는 조건상
    /// 높이가 항상 8192 초과라 이 판별로 정확히 구분된다.
    private var decodeBoxID: String {
        guard let box = (thumbnailContext?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue,
              box.height > Self.tallImageMaxPixelHeight
        else { return "std" }
        return "tall-\(Int(box.width))x\(Int(box.height))"
    }

    private var thumbnailContext: [SDWebImageContextOption: Any]? {
        Self.thumbnailContext(
            maxPointSize: thumbnailMaxPointSize,
            maxPointWidth: thumbnailMaxPointWidth,
            // 실제 지식이 있는 aspect 만 — fallbackAspect(1:1 예약값)를 넣으면
            // 극단 세로형이 정사각으로 오판돼 tall 재배분이 망가진다. 측정
            // aspect 는 1차 디코드가 높이 캡에 닿았을 때만 — 안 닿았으면 이미
            // native 완전 디코드라 tall 전환(리마운트+재디코드)이 순수 낭비.
            aspect: aspectRatio ?? (measuredDecodeHitHeightCap ? measuredAspect : nil),
            scale: displayScale
        )
    }

    /// 다운샘플 박스 매핑 — internal static 이라 박스 모양 계약(정사각 우선,
    /// 비정방은 aspect 인지 버짓 박스)을 단위 테스트로 고정할 수 있다.
    nonisolated static func thumbnailContext(
        maxPointSize: CGFloat?,
        maxPointWidth: CGFloat?,
        aspect: CGFloat? = nil,
        scale: CGFloat
    ) -> [SDWebImageContextOption: Any]? {
        // Pixel cap on the long edge — square `CGSize` because SD treats
        // the value as a max-bounding-box, not a per-axis cap, so the
        // shorter edge naturally scales down with the longer.
        if let pointSize = maxPointSize {
            let pixels = pointSize * scale
            return [.imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: pixels, height: pixels))]
        }
        if let pointWidth = maxPointWidth {
            // 높이 캡 8192px: 원래 65535(사실상 무제한)였으나, 폭이 이미 화면폭
            // 이하인 초대형 세로 패널(예: 1000×30000)이 캡을 통째로 우회해
            // 30MP 풀 디코드가 일어났다 — footprint +400~500MB 순간 스파이크와
            // 수 초 hang(ImageIO 전역 락이 메인 레이아웃과 경합)의 실측 주범.
            // 8192 면 통상 세로 패널(800×6000 급)은 무손실 통과한다.
            let pixels = pointWidth * scale
            // 극단 세로형(native-width 디코드에 8192 초과 높이 필요)이고 aspect
            // 를 알면, 같은 픽셀 버짓(화면폭px×8192 ≈ 종전 worst-case 40MB) 안
            // 에서 폭↓·높이↑ 재배분한다. 고정 박스는 aspect 비율로 폭까지 깎아
            // (예: 800×24000 → 273px 폭) 화면폭 대비 4배+ 업스케일 — 글자가
            // 뭉개지는 실사용 화질 버그(aagag 이슈 짤)였다. 재배분 후 546px 폭
            // — 완전 native 는 아니나 2배 선명, 메모리 상한은 동일.
            if let aspect, aspect > 0, pixels / aspect > Self.tallImageMaxPixelHeight {
                let budget = pixels * Self.tallImageMaxPixelHeight
                let width = min(pixels, (budget * aspect).squareRoot())
                let height = min(width / aspect, Self.tallImageHardMaxPixelHeight)
                return [.imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: width, height: height))]
            }
            return [.imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: pixels, height: Self.tallImageMaxPixelHeight))]
        }
        return nil
    }

    /// 1차 디코드가 기본 높이 캡에 닿았는지(=원본이 더 큼) — 뷰어의
    /// `needsTallRedecode` 와 같은 결. -2 는 다운샘플 반올림 여유.
    nonisolated static func decodeWasHeightCapped(decodedPixels: CGSize) -> Bool {
        decodedPixels.height >= tallImageMaxPixelHeight - 2
    }

    /// 비정방(폭 기준) 박스의 기본 높이 캡 — 계약 테스트와 공유.
    nonisolated static let tallImageMaxPixelHeight: CGFloat = 8192

    /// aspect 인지 tall 재배분 시의 높이 hard max. 8192 의 2 배 — 버짓이 픽셀
    /// 총량을 이미 묶으므로(폭이 그만큼 좁아짐) 메모리 상한은 그대로다.
    nonisolated static let tallImageHardMaxPixelHeight: CGFloat = 16384
}

private extension View {
    /// 행 높이를 `aspect` 로 **확정**한다 — 알려진 비율이 없으면 no-op
    /// (SwiftUI 의 `aspectRatio(_:contentMode:)` 는 nil 을 못 받는다).
    ///
    /// 왜 `.aspectRatio` 를 그냥 걸지 않는가 — 그건 자식이 자기 크기를 스스로
    /// 정하면 무력하다. `AnimatedImage.resizable().scaledToFit()` 은 비트맵이
    /// 없는 동안 정사각으로 배치되고, 그 크기가 바깥 `aspectRatio` 를 이긴다
    /// (기기 실측: eff=0.1636 이라 370x2261 이어야 할 프레임이 **370x370**). 비트맵이
    /// 없는 구간은 드물지 않다 — 첫 마운트, SD 메모리 캐시 축출, 그리고
    /// `releasesWhenOffscreen` 이 백그라운드에서 디코드를 버린 뒤의 복귀가 전부
    /// 여기에 해당한다. 그때마다 이미지 행이 정사각으로 무너지면서 상세
    /// contentSize 가 통째로 줄고, UIScrollView 가 contentOffset 을 clamp 한다.
    /// 재디코드가 끝나 높이가 돌아와도 offset 은 clamp 된 자리에 남는다 —
    /// "백그라운드 갔다 오면 스크롤 위치가 튄다" 의 정체(실측: 7049 → 1710 로
    /// 붕괴, offset 4181 → 870 clamp, 이후 7049 복구되지만 offset 은 그대로).
    ///
    /// 그래서 높이의 주인을 이미지에서 뺏어 온다: 비율만 아는 빈 상자가 행
    /// 크기를 잡고, 이미지/플레이스홀더는 그 안에 overlay 로 들어간다. overlay
    /// 는 부모 크기에 영향을 주지 못하므로 비트맵 유무와 무관하게 높이가
    /// 고정된다. 비율을 아는 경로가 `measuredAspect` 든 파서 값이든 동일.
    @ViewBuilder
    func pinnedToAspect(_ aspect: CGFloat?) -> some View {
        if let aspect, aspect > 0 {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { self }
        } else {
            self
        }
    }

    /// Conditional `onScrollVisibilityChange` — non-gated callers
    /// should not pay the per-callback overhead, which becomes
    /// noticeable at 100+ comment icons.
    @ViewBuilder
    func gateOnVisibility(enabled: Bool, action: @escaping (Bool) -> Void) -> some View {
        if enabled {
            self.onScrollVisibilityChange(threshold: 0, action)
        } else {
            self
        }
    }
}
