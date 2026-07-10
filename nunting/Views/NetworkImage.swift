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

    /// When `true`, the inline decode is forced to the first frame only
    /// (`SDWebImageDecodeFirstFrameOnly`) — a static still, no animation.
    ///
    /// Why: a heavy animated WebP (the humoruniv 짤방 case — 354 frames /
    /// 720×1280 / 15 MB) decodes ALL frames at load (~41 ms/frame on device =
    /// ~14 s, ~1.2 GB if held). Worse, that decode runs on SDImageCache's
    /// *serial* ioQueue, so it blocks every image queued behind it — the post
    /// below the 짤방 stays blank for the full ~14 s. First-frame-only collapses
    /// that to a single-frame decode (~40 ms): the feed shows a static frame
    /// instantly and the queue is freed. The animation is still viewable —
    /// tapping opens the fullscreen `ImageViewer`, which decodes + plays it on
    /// demand. Small inline GIFs keep animating (this stays `false`); body
    /// callers decide via `rendersFirstFrameOnly` (poster-backed or `.webp`).
    var decodesFirstFrameOnly: Bool = false

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
    /// `effectiveAspect`, so the placeholder swap is invisible and can't
    /// collapse the scroll position) while making the *decode* viewport-bound:
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

    /// Phase-3 teardown: drives the `appActive` decode gate so backgrounding
    /// drops `releasesWhenOffscreen` body decodes (keep-alive detail's resident
    /// bitmaps) without waiting for a scroll-driven release.
    @Environment(\.scenePhase) private var scenePhase

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
        // fall through to `gatePlaceholder`, which is frame-pinned by
        // `effectiveAspect` — so neither swap resizes the row.
        let showsHeavyImage = Self.shouldShowHeavyImage(
            visibilityGated: visibilityGated,
            hasBeenVisible: hasBeenVisible,
            releasesWhenOffscreen: releasesWhenOffscreen,
            isOnscreen: isOnscreen,
            // Drop `releasesWhenOffscreen` decodes while suspended; `.inactive`
            // (app switcher / control center) keeps them so the snapshot looks
            // right — only true `.background` tears down.
            appActive: scenePhase != .background
        )

        Group {
            if failed {
                if showsPlaceholder {
                    retryButton
                } else {
                    // Match browser behaviour for broken `<img>` on
                    // decorative slots — render nothing, don't draw
                    // attention to the failure.
                    Color.clear
                }
            } else if showsHeavyImage {
                // Heavy animated WebP (humoruniv 짤방) renders through `WebImage`
                // with first-frame-only decode; everything else animates inline
                // via `AnimatedImage`. The split exists because
                // `SDAnimatedImageView` (AnimatedImage's backing view) ignores
                // `.decodeFirstFrameOnly` and decodes the whole 354-frame
                // animation (~14 s, blocking SDImageCache's serial decode queue
                // so the rest of the post stays blank), whereas `WebImage` goes
                // through `SDWebImageManager`, which honours the option (~0.1 s,
                // static still). Verified by direct timing — see commit msg.
                Group {
                    if decodesFirstFrameOnly {
                        staticBodyImage
                    } else {
                        animatedBodyImage
                    }
                }
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
        .applyAspect(effectiveAspect)
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
        AnimatedImage(url: url.atsSafe, context: thumbnailContext) {
            loadingPlaceholder
        }
        .onSuccess { image, _, _ in handleLoadSuccess(image) }
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

    /// Heavy-animated-WebP body view: first-frame-only static still via
    /// `WebImage`. See the call-site comment for why this can't be
    /// `AnimatedImage`. No `maxBufferSize`/`purgeable` — there's no animation
    /// buffer to manage.
    private var staticBodyImage: some View {
        WebImage(
            url: url.atsSafe,
            options: [.decodeFirstFrameOnly],
            context: thumbnailContext
        ) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            loadingPlaceholder
        }
        .onSuccess { image, _, _ in handleLoadSuccess(image) }
        .onFailure { error in handleLoadFailure(error) }
    }

    /// Shared `.onSuccess` handler for both body-image paths.
    ///
    /// SDWebImage decodes UIImages at the device scale (≈3 on retina), so
    /// `image.size.width` is the *point* width = pixel width / scale.
    /// Multiplying back by `image.scale` recovers the source pixel count,
    /// matching the legacy `CachedAsyncImage` (scale-1) convention — without
    /// it `clampsToNaturalWidth` shrinks every body image to a third of its
    /// frame on retina. `DispatchQueue.main.async` defers the `@State` write
    /// past the in-flight render (SD can fire `.onSuccess` synchronously on a
    /// memory-cache hit, which would trip "Modifying state during view update").
    private func handleLoadSuccess(_ image: PlatformImage) {
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
    /// `appActive` (scenePhase != .background) is the phase-3 background-teardown
    /// gate: a keep-alive detail's body images sit on-screen with no scroll to
    /// fire a visibility release, so they'd hold their decode the whole time the
    /// app is suspended (a documented suspended-OOM contributor). Treating
    /// background as "everything off-screen" drops every `releasesWhenOffscreen`
    /// decode on suspend; on foreground `isOnscreen` (preserved @State, still the
    /// last viewport value) re-shows only the visible ones. Non-releasing images
    /// are unaffected — `appActive` only gates the release-eligible ones.
    /// 표시/예약에 쓸 종횡비 결정 — 우선순위: 파서 선언값 > 디코드 실측값 >
    /// fallback. `static` 이라 우선순위 계약을 단위테스트로 핀. fallback 이
    /// nil 이면(아이콘/스티커 등 비-본문 호출부) 셋 다 없을 때 nil 을 반환해
    /// 종전 `applyAspect(nil)` no-op 동작을 유지한다.
    nonisolated static func effectiveAspect(
        aspectRatio: CGFloat?,
        measuredAspect: CGFloat?,
        fallbackAspect: CGFloat?
    ) -> CGFloat? {
        aspectRatio ?? measuredAspect ?? fallbackAspect
    }

    /// 인라인 first-frame-only 게이트 — 본문 이미지 호출부(PostDetailView)와
    /// 프리페치 skip 목록(BodyImagePrefetcher 입력)이 공유하는 단일 판정.
    ///
    /// 대형 애니메이션 WebP 를 `AnimatedImage` 로 열면 전 프레임 직렬 디코드
    /// (354프레임 ≈ 14s)가 `SDImageCache` 직렬 큐를 점유해 아래 이미지 전부가
    /// blank 로 멈춘다(#82). 종전엔 `posterURL != nil`(HumorParser 전용)로만
    /// 판정해 다른 보드의 대형 WebP 는 프리즈가 재발했다(improvement-review
    /// §3.1) — URL 확장자 `.webp` 로 일반화한다. 정적 webp 는 first-frame 으로
    /// 그려도 시각 결과가 동일하고(1프레임), 애니메이션 webp 는 인라인 정지컷
    /// + 탭 → 전체화면 재생으로 강등. GIF 는 프리즈 실측이 없어 인라인
    /// 애니메이션 유지. 확장자 없는 URL 은 판별 불가 — 종전 동작(best-effort).
    nonisolated static func rendersFirstFrameOnly(url: URL, posterURL: URL?) -> Bool {
        posterURL != nil || url.pathExtension.lowercased() == "webp"
    }

    nonisolated static func shouldShowHeavyImage(
        visibilityGated: Bool,
        hasBeenVisible: Bool,
        releasesWhenOffscreen: Bool,
        isOnscreen: Bool,
        appActive: Bool
    ) -> Bool {
        let loadEligible = !visibilityGated || hasBeenVisible
        return loadEligible && (!releasesWhenOffscreen || (isOnscreen && appActive))
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

    private var retryButton: some View {
        Button {
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
            .frame(maxWidth: .infinity, minHeight: 120)
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
    /// SwiftUI's `aspectRatio(_:contentMode:)` rejects nil — but we want
    /// the modifier to be a no-op when no aspect is known yet.
    @ViewBuilder
    func applyAspect(_ aspect: CGFloat?) -> some View {
        if let aspect, aspect > 0 {
            self.aspectRatio(aspect, contentMode: .fit)
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
