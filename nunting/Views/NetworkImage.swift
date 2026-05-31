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
    /// demand. Small inline GIFs/WebP keep animating (this stays `false`).
    var decodesFirstFrameOnly: Bool = false

    /// Long-edge cap in *points*. Multiplied by `displayScale` to derive
    /// the pixel cap SD's `imageThumbnailPixelSize` expects, so callers
    /// pass the same units the legacy `maxDimension` param used. `nil`
    /// = decode at native resolution (rare; mostly for callers that
    /// know the source is already small).
    var thumbnailMaxPointSize: CGFloat? = nil

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
    @State private var measuredNaturalPointWidth: CGFloat?
    @State private var failed = false

    var body: some View {
        let effectiveAspect = aspectRatio ?? measuredAspect

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
            } else if !visibilityGated || hasBeenVisible {
                // Heavy animated WebP (humoruniv 짤방) renders through `WebImage`
                // with first-frame-only decode; everything else animates inline
                // via `AnimatedImage`. The split exists because
                // `SDAnimatedImageView` (AnimatedImage's backing view) ignores
                // `.decodeFirstFrameOnly` and decodes the whole 354-frame
                // animation (~14 s, blocking SDImageCache's serial decode queue
                // so the rest of the post stays blank), whereas `WebImage` goes
                // through `SDWebImageManager`, which honours the option (~0.1 s,
                // static still). Verified by direct timing — see commit msg.
                if decodesFirstFrameOnly {
                    staticBodyImage
                } else {
                    animatedBodyImage
                }
            } else {
                // Closed-gate placeholder — frame-identical to the loading
                // placeholder's base so the swap when `hasBeenVisible` flips
                // only *adds* the spinner / blurred poster (load starting)
                // rather than resizing. Deliberately bare: a gated image that
                // hasn't scrolled into view isn't loading yet, so no spinner
                // and — crucially — no poster fetch.
                gatePlaceholder
            }
        }
        .applyAspect(effectiveAspect)
        .frame(maxWidth: clampsToNaturalWidth ? (measuredNaturalPointWidth ?? .infinity) : .infinity)
        .gateOnVisibility(enabled: visibilityGated) { visible in
            // visibility callback 자체는 SwiftUI 의 view-update 사이클
            // 안에서 fire 될 수 있음. 검사(`!hasBeenVisible`)+쓰기 둘 다
            // async block 안으로 묶어서 (a) view-update 중 @State 읽기
            // 표면 0, (b) 빠른 두 번 fire 시 redundant write 차단.
            guard visible else { return }
            DispatchQueue.main.async {
                guard !hasBeenVisible else { return }
                hasBeenVisible = true
                reportVisibleIfNeeded()
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
        .onFailure { _ in handleLoadFailure() }
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
        .onFailure { _ in handleLoadFailure() }
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
        DispatchQueue.main.async {
            if measuredAspect == nil, let aspect { measuredAspect = aspect }
            if measuredNaturalPointWidth == nil { measuredNaturalPointWidth = naturalPointWidth }
        }
    }

    private func handleLoadFailure() {
        DispatchQueue.main.async { failed = true }
    }

    /// Fire `onBecameVisible` at most once. Called from the gate-open path
    /// (gated) and from `.onAppear` (eager); the `didReportVisible` latch
    /// makes repeated appears / callbacks idempotent.
    private func reportVisibleIfNeeded() {
        guard !didReportVisible else { return }
        didReportVisible = true
        onBecameVisible?()
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

    private var thumbnailContext: [SDWebImageContextOption: Any]? {
        guard let pointSize = thumbnailMaxPointSize else { return nil }
        // Pixel cap on the long edge — square `CGSize` because SD treats
        // the value as a max-bounding-box, not a per-axis cap, so the
        // shorter edge naturally scales down with the longer.
        let pixels = pointSize * displayScale
        return [.imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: pixels, height: pixels))]
    }
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
