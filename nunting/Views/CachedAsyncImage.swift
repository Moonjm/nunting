import SwiftUI
import UIKit
import ImageIO

struct CachedAsyncImage: View {
    let url: URL
    let maxDimension: CGFloat
    let maxPixelArea: CGFloat
    let aspectRatio: CGFloat?
    let cacheVariant: String
    /// When false, the loading state renders as an empty transparent view
    /// rather than the gray-box + spinner placeholder. Use this for small
    /// inline icons (comment level/auth icons) where the placeholder visibly
    /// flashes in and looks worse than a blank spot.
    let showsPlaceholder: Bool
    /// Lower value loads earlier when the fetch / decode throttle queue
    /// fills. Body images pass their block index so a long detail page
    /// loads top-down instead of in arrival order. Default `.max` keeps
    /// non-priority callers (comment icons, sticker, video poster, YouTube
    /// thumb) behind any indexed caller and FIFO among themselves.
    let loadPriority: Int
    /// When true, the rendered frame caps at the source's natural point
    /// width instead of stretching to fill the parent. Mirrors the browser
    /// `width: auto; max-width: 100%` behaviour boards apply on body
    /// `<img>` — keeps small attachments (e.g. SLR's failed-upload 127×100
    /// white placeholder) at their natural size instead of upscaling 3×
    /// into a full-column white box. Default `false` preserves the
    /// fixed-slot fill that level / auth icon callers rely on.
    let clampsToNaturalWidth: Bool
    /// When true, defers the network fetch + decode pipeline until this
    /// image's frame intersects the enclosing ScrollView's viewport.
    /// Used by body images so a 30-image post doesn't queue 30 fetches
    /// at the moment the detail commits — only viewport-region images
    /// trigger work, and bottom-of-post images stay idle until the
    /// user actually scrolls there. Default `false` keeps icons /
    /// stickers / video posters loading the moment they mount, which
    /// they need because they sit in fixed slots that should fill on
    /// first appearance, not on viewport crossing.
    ///
    /// **Required:** the view must be mounted inside a `ScrollView` for
    /// the gate ever to open. `onScrollVisibilityChange` silently
    /// no-ops outside scroll views per Apple's contract, which would
    /// leave the image stuck on its placeholder forever. A DEBUG-only
    /// guard in `body` warns if a gated view hasn't received a
    /// visibility callback within 1 s of appearing.
    let visibilityGated: Bool

    @State private var image: UIImage?
    @State private var animatedPayload: AnimatedImagePayload?
    @State private var failed = false
    /// Aspect ratio discovered from the decoded image (or primed from the
    /// session aspect cache on init). Used when the caller didn't supply an
    /// explicit `aspectRatio` so the final-sized frame is reserved up-front
    /// on re-appearances — stops the 120pt placeholder → natural-height
    /// jump that shifts scroll position when images load.
    @State private var intrinsicAspectRatio: CGFloat?
    /// Source pixel width treated as point width (the decoded UIImage uses
    /// `scale = 1`, so `size.width` equals the pixel count). Read by
    /// `clampsToNaturalWidth` callers to bound the rendered frame so the
    /// view never upscales beyond the source. Primed from the aspect-cache
    /// sibling on init for the same re-realize-doesn't-jump reason.
    @State private var intrinsicPointWidth: CGFloat?
    /// Tracks `.onScrollVisibilityChange` for `visibilityGated` callers.
    /// `nil` while we haven't received a callback yet (treated as "not
    /// visible" so loads stay deferred); flipped to `true` / `false` by
    /// the modifier as the image's frame crosses the enclosing
    /// ScrollView's viewport. Non-gated callers ignore this entirely.
    @State private var isVisible: Bool = false
    @Environment(\.displayScale) private var displayScale

    init(
        url: URL,
        maxDimension: CGFloat = 1600,
        maxPixelArea: CGFloat = 20_000_000,
        aspectRatio: CGFloat? = nil,
        cacheVariant: String = "default",
        showsPlaceholder: Bool = true,
        loadPriority: Int = .max,
        clampsToNaturalWidth: Bool = false,
        visibilityGated: Bool = false
    ) {
        self.url = url
        self.maxDimension = maxDimension
        self.maxPixelArea = maxPixelArea
        self.aspectRatio = aspectRatio
        self.cacheVariant = cacheVariant
        self.showsPlaceholder = showsPlaceholder
        self.loadPriority = loadPriority
        self.clampsToNaturalWidth = clampsToNaturalWidth
        self.visibilityGated = visibilityGated
        // Prime from the aspect cache so LazyVStack re-materialisation (and
        // re-scroll over previously-decoded images) renders at final size
        // on the FIRST layout pass instead of starting with a 120pt stub
        // and jumping once the decode resolves.
        _intrinsicAspectRatio = State(
            initialValue: aspectRatio
                ?? ImageCache.shared.aspectRatio(for: url, variant: cacheVariant)
        )
        _intrinsicPointWidth = State(
            initialValue: ImageCache.shared.naturalPointWidth(for: url, variant: cacheVariant)
        )
    }

    var body: some View {
        // Single ZStack keeps the view identity stable so SwiftUI doesn't
        // play its default slide/fade transition when the image swaps in
        // for the placeholder. Suppressing the inherited animation also
        // stops the visible "slide-from-right" jank during loading.
        let content = ZStack {
            if image == nil && animatedPayload == nil && !failed && showsPlaceholder {
                Color("AppSurface2")
                    .overlay(ProgressView())
                    // Placeholder exists purely to fill the slot; without
                    // this the Color absorbs the initial touch of a scroll
                    // gesture and SwiftUI delays handing it back to the
                    // parent ScrollView long enough to feel like a freeze.
                    .allowsHitTesting(false)
            }
            if let animatedPayload {
                // `UIImageView.animationImages` equi-spaces per-frame time
                // (total / frameCount), which flattens GIFs with varying
                // delays into a jerky stutter vs. Safari. Use a custom
                // CADisplayLink player that honours per-frame delays and
                // decodes frames lazily from the shared CGImageSource.
                AnimatedImageView(payload: animatedPayload)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
            if failed && showsPlaceholder {
                // Sporadic mid-post load misses are hard to reproduce, so
                // surface a tap-to-retry affordance instead of leaving the
                // slot stuck on the broken-image icon. Child tap wins over
                // any parent `.onTapGesture` (e.g. PostDetailView's
                // full-screen image viewer trigger) so a retry tap doesn't
                // open the viewer on a missing image.
                //
                // Only shown when `showsPlaceholder == true` (body images).
                // Decorative icons (`false`) — comment level / auth badges —
                // render empty on failure instead, matching the broken-
                // `<img>` behaviour in mobile browsers for sources that
                // 200 with the wrong bytes (e.g. Humor's `icon-file` serving
                // an MP4 container under `image/jpeg`).
                VStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                    Text("다시 시도")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await load() }
                }
            }
        }
        // Body-image callers (`clampsToNaturalWidth: true`) pin the upper
        // bound to the source's natural point width once known so 127px
        // placeholders don't get upscaled 3× into a full-column white box.
        // Falling back to `.infinity` while the width is still unknown
        // keeps the placeholder full-width during first load — there's no
        // size to clamp against yet, and re-visits prime the width from
        // ImageCache at init so the cap is in effect on first layout.
        .frame(maxWidth: clampsToNaturalWidth ? (intrinsicPointWidth ?? .infinity) : .infinity)
        .transaction { $0.animation = nil }
        // Task identity includes the visibility gate state so the load
        // re-fires (kicks the pipeline) when a deferred image first
        // crosses the viewport. Non-gated callers' `loadGateOpen` is
        // always `true`, so for them this is identical to keying on
        // just `url` — no behavioural change.
        .task(id: LoadGate(url: url, open: !visibilityGated || isVisible)) {
            guard !visibilityGated || isVisible else { return }
            await load()
        }
        // iOS 18+ viewport-intersection callback. Fires only when the
        // view sits inside a ScrollView (every CachedAsyncImage caller
        // does today). `threshold: 0` flips `isVisible` the moment any
        // pixel of the image's frame enters the viewport — that's
        // when we want fetch + decode to start. A larger threshold
        // would delay the trigger past first-pixel, which translates
        // to longer placeholder time on scroll-in.
        //
        // Apple's contract: this callback fires once on the initial
        // layout pass with the current visibility state, NOT only on
        // transitions — so an above-the-fold body image gets
        // `visible = true` on first layout and the gate opens before
        // any scroll input. That's load-bearing for the experiment;
        // without it, body images visible on detail entry would never
        // load.
        .onScrollVisibilityChange(threshold: 0) { visible in
            if visibilityGated { isVisible = visible }
        }
        // DEBUG-only misuse guard. If a `visibilityGated` caller is
        // accidentally placed outside a `ScrollView` (or any other
        // configuration where `onScrollVisibilityChange` doesn't
        // fire), the gate stays closed and the image silently never
        // loads — the worst kind of bug to chase. After 1 s of
        // appearance, if the gate is still closed and there's no
        // cached image, log a one-shot warning so the misuse surfaces
        // immediately during development. Stripped from release
        // builds via `#if DEBUG`.
        #if DEBUG
        .task(id: url) {
            guard visibilityGated else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !isVisible, image == nil, animatedPayload == nil
            else { return }
            print("[CachedAsyncImage] WARNING: visibilityGated image at \(url) hasn't received an onScrollVisibilityChange callback after 1s — is it inside a ScrollView?")
        }
        #endif

        let effective = aspectRatio ?? intrinsicAspectRatio
        if let effective {
            content.aspectRatio(effective, contentMode: .fit)
        } else {
            content.frame(minHeight: image == nil && animatedPayload == nil && showsPlaceholder ? 120 : nil)
        }
    }

    private func load() async {
        image = nil
        animatedPayload = nil
        failed = false

        let variant = cacheVariant

        if let cached = ImageCache.shared.image(for: url, variant: variant) {
            image = cached
            if cached.size.height > 0 {
                let aspect = cached.size.width / cached.size.height
                if intrinsicAspectRatio == nil {
                    intrinsicAspectRatio = aspect
                }
                if intrinsicPointWidth == nil {
                    intrinsicPointWidth = cached.size.width
                }
                // Opportunistically back-fill the aspect / natural-width
                // caches on cache hits too, so images decoded by a pre-fix
                // build (UIImage stored, sibling caches missing) get a
                // stable frame on the next re-realize instead of bouncing
                // through minHeight 120 / `.infinity` width.
                if ImageCache.shared.aspectRatio(for: url, variant: variant) == nil {
                    ImageCache.shared.storeAspectRatio(aspect, for: url, variant: variant)
                }
                if ImageCache.shared.naturalPointWidth(for: url, variant: variant) == nil {
                    ImageCache.shared.storeNaturalPointWidth(cached.size.width, for: url, variant: variant)
                }
            }
            return
        }

        let scale = displayScale
        let limit = maxDimension
        let areaLimit = maxPixelArea

        // `ImageDataLoader` deduplicates in-flight fetches by URL and runs
        // the network leg on a detached, non-cancellable task. When the
        // caller (this view's `.task(id: url)`) is cancelled — e.g. user
        // taps a different post mid-load — we just stop awaiting; the
        // shared fetch still completes and populates URLCache, so the next
        // visit to the same post finds it cached instead of re-downloading.
        // The loader also owns the `ImageThrottle.fetch` semaphore so we
        // don't hold a slot while a cancelled view's Task is unwinding.
        let data = await ImageDataLoader.shared.data(for: url.atsSafe, priority: loadPriority)
        guard !Task.isCancelled else { return }
        guard let data else {
            failed = true
            return
        }

        do {
            try await ImageThrottle.decode.acquire(priority: loadPriority)
        } catch {
            return
        }

        do {
            let decoded = try await decodeOffMain(data: data, limit: limit, maxPixelArea: areaLimit, scale: scale)
            try Task.checkCancellation()

            switch decoded {
            case .still(let img):
                ImageCache.shared.store(img, for: url, variant: variant)
                image = img
                if img.size.height > 0 {
                    let aspect = img.size.width / img.size.height
                    intrinsicAspectRatio = aspect
                    intrinsicPointWidth = img.size.width
                    // Persist the ratio so subsequent re-realizations (LazyVStack
                    // derealize/realize during back-drag) reserve the final
                    // frame size from `init`, instead of collapsing to the
                    // minHeight: 120 placeholder for the duration of the
                    // cache-hit `.task`. Without this, a long post's body
                    // images briefly shrink to 120pt on re-realize, total
                    // content height contracts, and the viewport at deep
                    // scroll ends up past the new content end — blank screen.
                    ImageCache.shared.storeAspectRatio(aspect, for: url, variant: variant)
                    ImageCache.shared.storeNaturalPointWidth(img.size.width, for: url, variant: variant)
                }
            case .animated(let payload):
                // Animated GIFs aren't stored in ImageCache — the frame
                // data stays alive as long as this view's CGImageSource
                // reference does, and re-decode from URLCache on re-entry
                // is cheap. Aspect ratio + natural width are still cached
                // so re-renders reserve the final frame (and respect
                // `clampsToNaturalWidth`) before the payload is ready.
                animatedPayload = payload
                intrinsicAspectRatio = payload.aspect
                intrinsicPointWidth = payload.naturalPointWidth
                ImageCache.shared.storeAspectRatio(payload.aspect, for: url, variant: variant)
                ImageCache.shared.storeNaturalPointWidth(payload.naturalPointWidth, for: url, variant: variant)
            case nil:
                failed = true
            }
            await ImageThrottle.decode.release()
        } catch is CancellationError {
            await ImageThrottle.decode.release()
            return
        } catch {
            await ImageThrottle.decode.release()
            failed = true
        }
    }

    private func decodeOffMain(data: Data, limit: CGFloat, maxPixelArea: CGFloat, scale: CGFloat) async throws -> DecodeResult? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let img = Self.decode(data: data, maxDimension: limit, maxPixelArea: maxPixelArea, scale: scale)
            try Task.checkCancellation()
            return img
        }.value
    }

    fileprivate enum DecodeResult {
        case still(UIImage)
        case animated(AnimatedImagePayload)
    }

    /// Composite `.task(id:)` key combining URL with the visibility
    /// gate's open/closed state. Non-gated callers always pass
    /// `open: true`, which makes the key collapse to URL-equivalent
    /// behaviour (no spurious re-fires on isVisible changes the caller
    /// is supposed to ignore). Gated callers see two key transitions
    /// per scroll-through: false→true (kicks load), true→false (cancels
    /// in-flight task; the shared `ImageDataLoader` continues the fetch
    /// in the background and stores it in URLCache for the next time).
    private struct LoadGate: Hashable {
        let url: URL
        let open: Bool
    }

    nonisolated private static func decode(data: Data, maxDimension: CGFloat, maxPixelArea: CGFloat, scale: CGFloat) -> DecodeResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // Fetch native dimensions up-front so we can cap by width + area
        // instead of CG's built-in "max on the long edge" heuristic. The
        // long-edge heuristic shrinks tall aagag issue images below the
        // device's retina width (e.g. 800×6000 → 640×4800), which visibly
        // softens the result when SwiftUI renders them in the column.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceW = (properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let sourceH = (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

        let targetWidth = max(maxDimension * scale, 256)
        let widthRatio = sourceW > 0 ? min(1, targetWidth / sourceW) : 1
        let sourceArea = max(sourceW * sourceH, 1)
        let areaRatio = sourceArea > maxPixelArea ? sqrt(maxPixelArea / sourceArea) : 1
        let ratio = min(widthRatio, areaRatio)
        let longSide = max(sourceW, sourceH) * ratio

        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            return decodeAnimated(
                source: source,
                frameCount: frameCount,
                downsampleRatio: ratio,
                longSide: longSide,
                sourceWidth: sourceW,
                sourceHeight: sourceH
            )
        }

        let cg: CGImage?
        if ratio >= 1 {
            // Source already fits both caps — full decode keeps native detail.
            // Pass `ShouldCacheImmediately` so the pixel decode happens here
            // on the detached task; without it CGImage stays lazy and
            // SwiftUI's first `Image(uiImage:)` render triggers the decode
            // on the main actor, which stutters scroll / gesture delivery
            // on large images.
            let fullOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
            ]
            cg = CGImageSourceCreateImageAtIndex(source, 0, fullOptions as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longSide,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let cg else { return nil }
        // UIImage.scale = 1 keeps the intrinsic point size equal to the pixel
        // size, so SwiftUI's scaledToFit downsamples large images cleanly and
        // upscales small ones (humoruniv 480px originals) without treating
        // them as already rendered for a 3x display.
        return .still(UIImage(cgImage: cg, scale: 1, orientation: .up))
    }

    /// Long-edge cap (pixels) applied to animated frames. Lower than the
    /// still path's `maxDimension` to bound per-frame memory. Boards like
    /// Ppomppu and Clien rarely ship retina-quality GIFs; 1080px stays
    /// sharp on a 390pt column while cutting per-frame decode size by
    /// roughly half vs the still ceiling. Used as the thumbnail target
    /// when the source exceeds the display column budget.
    nonisolated private static let animatedLongEdgeCap: CGFloat = 1080

    /// Prepare a lightweight `AnimatedImagePayload` for the custom
    /// `CADisplayLink`-based player. Unlike the previous implementation
    /// this does NOT eagerly decode every frame into `[UIImage]` — it
    /// pre-reads per-frame delays (needed to drive the display link
    /// scheduler) and decodes a single first frame so the view has
    /// something to show on its first layout pass. Remaining frames are
    /// decoded on demand from the shared `CGImageSource` inside the
    /// player's LRU cache. This preserves per-frame timing (GIFs with
    /// variable delays no longer flatten to the average, which was the
    /// visible "frame-drop" stutter vs. the browser) and removes the
    /// stride-subsampling fallback that halved the effective framerate
    /// on long sources.
    nonisolated private static func decodeAnimated(
        source: CGImageSource,
        frameCount: Int,
        downsampleRatio ratio: CGFloat,
        longSide: CGFloat,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> DecodeResult? {
        let targetLongSide = min(
            longSide > 0 ? longSide : animatedLongEdgeCap,
            animatedLongEdgeCap
        )
        let needsThumbnail = !(ratio >= 1 && targetLongSide >= max(longSide, 1))

        // Prewarm frame 0 on the decode task (we're off-main here) so the
        // view's first layout pass has something to present immediately,
        // rather than flashing blank while the display link schedules its
        // first tick on main.
        let firstFrame = Self.decodeFrame(
            at: 0,
            source: source,
            useThumbnail: needsThumbnail,
            thumbnailMaxPixelSize: targetLongSide
        )
        guard let firstFrame else { return nil }

        let aspect: CGFloat
        if sourceWidth > 0 && sourceHeight > 0 {
            aspect = sourceWidth / sourceHeight
        } else {
            let w = CGFloat(firstFrame.width)
            let h = CGFloat(firstFrame.height)
            aspect = h > 0 ? w / h : 1
        }

        // Source pixel width treated as point width — same `scale = 1`
        // convention `.still` UIImages use, so `clampsToNaturalWidth`
        // callers can cap GIFs at their source size the same way.
        let naturalPointWidth = sourceWidth > 0 ? sourceWidth : CGFloat(firstFrame.width)

        let payload = AnimatedImagePayload(
            source: source,
            frameCount: frameCount,
            firstFrame: firstFrame,
            aspect: aspect,
            useThumbnail: needsThumbnail,
            thumbnailMaxPixelSize: targetLongSide,
            naturalPointWidth: naturalPointWidth
        )
        return .animated(payload)
    }

    /// Decode a single animated-image frame at `index`. Runs off-main
    /// from the decode pipeline and on-main from the display-link
    /// player; both are valid because `CGImageSource`'s read APIs are
    /// thread-safe once the source itself has been created.
    nonisolated fileprivate static func decodeFrame(
        at index: Int,
        source: CGImageSource,
        useThumbnail: Bool,
        thumbnailMaxPixelSize: CGFloat
    ) -> CGImage? {
        if useThumbnail {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
        } else {
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateImageAtIndex(source, index, opts as CFDictionary)
        }
    }

    nonisolated fileprivate static func frameDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return 0.1 }
        // GIF and APNG both surface delay metadata, but under their own
        // dictionary keys. Check GIF first since it's the dominant animated
        // image format on the boards we scrape.
        let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? 0
        let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double)
            ?? 0
        let delay = unclamped > 0 ? unclamped : clamped
        // Browsers clamp sub-20ms delays up to 100ms because many GIFs from
        // the 90s shipped with 0ms "as fast as possible" frames that spin
        // CPUs; mirror that behavior to keep animations from hogging the
        // main thread when the decode budget is tight.
        return delay < 0.02 ? 0.1 : delay
    }
}

/// Lightweight animated-image description passed from the decoder to the
/// UIKit player. Holds the raw `CGImageSource` and a prewarmed first
/// frame — per-frame delays are NOT pre-computed here because reading
/// `CGImageSourceCopyPropertiesAtIndex` for every frame of a long GIF
/// (300+ frames) forces the file parser to walk to the end of the
/// stream before the decode task can return, which the user perceived
/// as slow initial loading. The player reads delays lazily, one frame
/// at a time, inside its CADisplayLink tick.
/// `@unchecked Sendable` because `CGImageSource` is immutable + reference-
/// typed and Apple documents its read APIs as thread-safe; we only ever
/// read, so crossing the decode-task → main-actor boundary is sound.
struct AnimatedImagePayload: @unchecked Sendable {
    let source: CGImageSource
    let frameCount: Int
    let firstFrame: CGImage
    let aspect: CGFloat
    let useThumbnail: Bool
    let thumbnailMaxPixelSize: CGFloat
    /// Source's natural pixel width treated as point width (matches the
    /// `scale = 1` convention `.still` UIImages use). Threaded through so
    /// `clampsToNaturalWidth` callers can cap GIFs the same way they cap
    /// stills.
    let naturalPointWidth: CGFloat
}

/// SwiftUI wrapper. The prior implementation fed `UIImageView.animationImages`
/// which flattens per-frame delays to a uniform `duration / frameCount`
/// interval — that's what made GIFs with varying delays stutter vs. the
/// browser. The underlying UIView now drives its own CADisplayLink and
/// honours each delay directly.
private struct AnimatedImageView: View {
    let payload: AnimatedImagePayload

    var body: some View {
        AnimatedImageUIView(payload: payload)
            .aspectRatio(payload.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }
}

private struct AnimatedImageUIView: UIViewRepresentable {
    let payload: AnimatedImagePayload

    func makeUIView(context: Context) -> DisplayLinkAnimatedImageView {
        let v = DisplayLinkAnimatedImageView(frame: .zero)
        v.setPayload(payload)
        return v
    }

    func updateUIView(_ v: DisplayLinkAnimatedImageView, context: Context) {
        // Only rebind when the underlying source changed — reusing the
        // same payload on unrelated re-renders would reset the playhead
        // to frame 0 and make the GIF visibly jump.
        guard v.source !== payload.source else { return }
        v.setPayload(payload)
    }
}

/// Custom `UIView` that drives GIF / APNG playback through a
/// `CADisplayLink`, honouring each frame's native delay and decoding
/// frames lazily from the shared `CGImageSource`. Replaces the previous
/// `UIImageView.animationImages` path for two reasons:
/// 1. **Per-frame timing.** UIImageView distributes the total
///    `animationDuration` evenly across frames, which flattens GIFs with
///    variable delays (hold-and-release patterns common in reaction
///    GIFs) into a perceived stutter.
/// 2. **Memory bound.** The old path eager-decoded every frame into
///    `[UIImage]` and fell back to stride-subsampling past ~280MB — a
///    120-frame source ended up at 60 frames, i.e. half framerate. The
///    LRU cache here is capped at `frameCacheCapacity` decoded CGImages
///    regardless of source length, and `CGImageSource` itself holds
///    encoded bytes only.
private final class DisplayLinkAnimatedImageView: UIView {
    private(set) var source: CGImageSource?
    private var frameCount: Int = 0

    /// Cumulative per-frame delays, filled lazily as the player walks
    /// forward. `cumulativeDelays[i]` = sum of delays for frames [0, i].
    /// Starts empty; each tick extends it as far as the current elapsed
    /// time demands. Avoids the up-front `CGImageSourceCopyPropertiesAtIndex`
    /// scan the decoder used to run over every frame before returning.
    private var cumulativeDelays: [TimeInterval] = []
    /// Total duration once every frame's delay has been read. 0 while the
    /// table is still being filled — in that window `tick` treats the
    /// playhead as still advancing forward through the first loop without
    /// modulo.
    private var totalDuration: TimeInterval = 0
    private var useThumbnail: Bool = false
    private var thumbnailMaxPixelSize: CGFloat = 0

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    /// Elapsed seconds at the moment the display link was last paused
    /// (window detach). Restored on resume so playback continues from the
    /// frame that was on-screen instead of jumping back to frame 0 — the
    /// behaviour the LazyVStack derealize / realize cycle would otherwise
    /// produce every time a GIF cell scrolled back into view.
    private var pausedElapsed: TimeInterval = 0
    private var lastFrameIndex: Int = -1

    /// LRU frame cache — bounded by count so memory stays predictable
    /// regardless of total source length. 12 frames at the 1080px long-
    /// edge cap is ≈55MB peak, small enough to coexist with several
    /// concurrent GIFs on a detail page. Picked to cover a typical
    /// reaction GIF (8–20 frames) so the second loop serves entirely
    /// from cache once prefetch has filled it.
    private static let frameCacheCapacity = 12
    private var frameCache: [Int: CGImage] = [:]
    private var cacheOrder: [Int] = []

    /// Background queue for speculative next-frame decodes. Keeps the
    /// per-tick main-thread cost at ~0 on the happy path (frame already
    /// in cache by the time we need it) instead of paying a
    /// CGImageSourceCreateThumbnailAtIndex (~5–10ms at 1080px) inline
    /// inside a 16.67ms / 8.33ms display-link budget.
    private static let prefetchQueue = DispatchQueue(
        label: "nunting.gif.prefetch",
        qos: .userInitiated
    )
    /// Frame indices currently being decoded on the prefetch queue.
    /// Prevents duplicate work if two ticks ask for the same frame
    /// before the first decode finishes. Read/written on main only.
    private var prefetchInFlight: Set<Int> = []

    private var memoryWarningObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspect
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushFrameCache()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        displayLink?.invalidate()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// Suspend the display link when the view leaves a window (e.g.
    /// LazyVStack derealize on scroll) so off-screen GIFs don't spin
    /// the CPU. Resume when re-attached.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            pauseDisplayLink()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, source != nil {
            resumeDisplayLink()
        }
    }

    func setPayload(_ payload: AnimatedImagePayload) {
        pauseDisplayLink()
        source = payload.source
        frameCount = payload.frameCount
        useThumbnail = payload.useThumbnail
        thumbnailMaxPixelSize = payload.thumbnailMaxPixelSize

        cumulativeDelays = []
        cumulativeDelays.reserveCapacity(payload.frameCount)
        totalDuration = 0

        frameCache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        lastFrameIndex = -1
        startTime = nil
        // Fresh payload = fresh playhead. A mid-playback source swap
        // shouldn't inherit the previous GIF's pause offset.
        pausedElapsed = 0

        // Seed the cache and the layer with the prewarmed first frame so
        // the view shows content on its first layout pass — before the
        // display link even ticks.
        frameCache[0] = payload.firstFrame
        cacheOrder.append(0)
        layer.contents = payload.firstFrame
        lastFrameIndex = 0

        if window != nil {
            resumeDisplayLink()
        }
    }

    private func resumeDisplayLink() {
        guard displayLink == nil, source != nil, frameCount > 0 else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // `.common` runs the tick during scroll tracking too — otherwise
        // GIFs freeze the moment the user starts dragging the feed.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func pauseDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        // Snapshot elapsed so resume picks up where we left off instead
        // of snapping back to frame 0. Using `CACurrentMediaTime()` lines
        // up with the display link's clock; subtracting `startTime` gives
        // the playhead position at the moment of pause.
        if let start = startTime {
            pausedElapsed = CACurrentMediaTime() - start
        }
        startTime = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let source, frameCount > 0 else { return }
        let now = link.targetTimestamp
        if startTime == nil {
            // Offset the virtual start by `pausedElapsed` so the first
            // tick after resume computes the SAME elapsed as the pause
            // moment — playback continues seamlessly from the visible
            // frame rather than cutting to frame 0.
            startTime = now - pausedElapsed
            pausedElapsed = 0
        }
        let elapsed = now - (startTime ?? now)

        // Extend the cumulative-delay table lazily: read one frame's delay
        // metadata at a time via `CGImageSourceCopyPropertiesAtIndex` until
        // the accumulated total covers `elapsed` (first-loop progression)
        // or until every frame has been scanned (then `totalDuration`
        // locks in and subsequent loops use modulo). Reading a single
        // frame's properties is O(μs) after the initial parse, well
        // inside a display-link tick budget.
        if totalDuration == 0 {
            let cap = cumulativeDelays.last ?? 0
            if cumulativeDelays.count < frameCount && cap <= elapsed {
                var running = cap
                // `elapsed + 1` reads ~1s of lookahead beyond the current
                // playhead so the binary search below always has a bucket
                // that strictly exceeds `t`. Without the lookahead a tick
                // landing exactly at `running` would binary-search past
                // the last known entry and flicker to frame 0.
                while cumulativeDelays.count < frameCount && running <= elapsed + 1 {
                    let d = CachedAsyncImage.frameDelay(at: cumulativeDelays.count, in: source)
                    running += d
                    cumulativeDelays.append(running)
                }
                if cumulativeDelays.count == frameCount {
                    // Last frame sum locks in the loop duration for
                    // subsequent modulo playback. Fall back to 0.1s/frame
                    // if every delay came back 0 (degenerate metadata).
                    totalDuration = running > 0 ? running : Double(frameCount) * 0.1
                }
            }
        }

        guard !cumulativeDelays.isEmpty else { return }
        let t: TimeInterval
        if totalDuration > 0 {
            t = elapsed.truncatingRemainder(dividingBy: totalDuration)
        } else {
            // Still walking through the first loop — advance linearly.
            t = elapsed
        }

        // Binary search for the first cumulative delay strictly greater
        // than `t` — that index is the frame currently on-screen.
        var lo = 0
        var hi = cumulativeDelays.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulativeDelays[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        let frameIndex = lo

        guard frameIndex != lastFrameIndex else { return }
        if let cg = frame(at: frameIndex) {
            layer.contents = cg
            lastFrameIndex = frameIndex
        }
        // Speculatively decode the next frame so it's ready when the
        // next tick needs it. Cheap to do on miss (one background
        // decode), free to do on hit (guarded).
        prefetchFrame(at: (frameIndex + 1) % frameCount)
    }

    /// Kick off a background decode for `index` if it isn't already
    /// cached or in-flight. The result is grafted onto the LRU from the
    /// main thread so the cache itself remains single-threaded.
    private func prefetchFrame(at index: Int) {
        guard frameCount > 1 else { return }
        guard let source else { return }
        if frameCache[index] != nil { return }
        if prefetchInFlight.contains(index) { return }
        prefetchInFlight.insert(index)
        let useThumb = useThumbnail
        let maxPx = thumbnailMaxPixelSize
        // `CGImageSource` is reference-typed but Apple documents its
        // read APIs as thread-safe, and this path only reads. Box it in
        // a `@unchecked Sendable` shell so Swift 6 strict-concurrency
        // lets us cross the DispatchQueue boundary without dropping the
        // whole class into `@unchecked Sendable`.
        struct SourceBox: @unchecked Sendable { let source: CGImageSource }
        let boxed = SourceBox(source: source)
        Self.prefetchQueue.async { [weak self] in
            let cg = CachedAsyncImage.decodeFrame(
                at: index,
                source: boxed.source,
                useThumbnail: useThumb,
                thumbnailMaxPixelSize: maxPx
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.prefetchInFlight.remove(index)
                // Another path (synchronous miss on the display link
                // tick) may have raced ahead and populated the cache
                // while we were decoding; skip the insert so we don't
                // shuffle LRU order and evict a frame the player is
                // actively using.
                guard let cg, self.frameCache[index] == nil else { return }
                self.insertCache(index: index, image: cg)
            }
        }
    }

    private func frame(at index: Int) -> CGImage? {
        if let cached = frameCache[index] {
            touchLRU(index)
            return cached
        }
        guard let source else { return nil }
        guard let cg = CachedAsyncImage.decodeFrame(
            at: index,
            source: source,
            useThumbnail: useThumbnail,
            thumbnailMaxPixelSize: thumbnailMaxPixelSize
        ) else { return nil }
        insertCache(index: index, image: cg)
        return cg
    }

    private func insertCache(index: Int, image: CGImage) {
        frameCache[index] = image
        cacheOrder.append(index)
        while cacheOrder.count > Self.frameCacheCapacity {
            let evict = cacheOrder.removeFirst()
            if evict != lastFrameIndex {
                frameCache.removeValue(forKey: evict)
            } else {
                // Don't evict the currently-displayed frame — bounce it
                // to the end of the LRU order so the next eviction takes
                // an actually-stale entry instead.
                cacheOrder.append(evict)
            }
        }
    }

    private func touchLRU(_ index: Int) {
        if let pos = cacheOrder.firstIndex(of: index) {
            cacheOrder.remove(at: pos)
        }
        cacheOrder.append(index)
    }

    private func flushFrameCache() {
        // Keep the currently-displayed frame so the view doesn't flash
        // blank on memory pressure; the LRU will refill as the display
        // link walks forward.
        var preserved: [Int: CGImage] = [:]
        if lastFrameIndex >= 0, let current = frameCache[lastFrameIndex] {
            preserved[lastFrameIndex] = current
        }
        frameCache = preserved
        cacheOrder = Array(preserved.keys)
    }
}

/// Bounded async semaphore with cancellation-safe waiters. Used by image
/// loading to cap concurrent network fetches and CPU decodes separately —
/// separating the two budgets lets I/O and CPU overlap rather than
/// serialising both through one queue.
///
/// `acquire(priority:)` orders the wait queue ascending by priority value
/// (lower = served first); ties stay FIFO. Default priority is `.max`, so
/// callers that don't pass one keep the original FIFO behaviour relative
/// to one another while always queueing behind any caller with a numerical
/// priority. Used by `PostDetailView` body images to load top-down: each
/// image's block index becomes its priority, while comment icons / video
/// posters / sticker images keep the default and load after.
actor AsyncSemaphore {
    let maxConcurrent: Int
    private var inFlight = 0
    private struct Waiter {
        let id: UUID
        let priority: Int
        let cont: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    /// Throws `CancellationError` when the caller's task is cancelled while
    /// waiting for a slot. A non-throwing continuation with no cancellation
    /// hook would strand a cancelled waiter in the queue until an unrelated
    /// future `release()` happened along — worst case pinning `inFlight` at
    /// `maxConcurrent` indefinitely. Callers must only pair a successful
    /// `acquire()` with `release()`.
    func acquire(priority: Int = .max) async throws {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let waiter = Waiter(id: id, priority: priority, cont: cont)
                // Sorted insert: find the first existing waiter with a
                // strictly greater priority and insert before it. Equal
                // priorities keep FIFO order (new entry lands after them),
                // so default `.max` callers behave exactly like the prior
                // append-only queue relative to each other.
                let insertAt = waiters.firstIndex(where: { $0.priority > priority }) ?? waiters.count
                waiters.insert(waiter, at: insertAt)
            }
        } onCancel: {
            // `onCancel` is nonisolated; hop back onto the actor to touch
            // the waiter queue. If `release()` already resumed this waiter
            // before we got here, `cancelWaiter` becomes a no-op.
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if let next = waiters.first {
            // Hand the slot directly to the next waiter — keeps inFlight
            // pinned at maxConcurrent until the queue drains.
            waiters.removeFirst()
            next.cont.resume()
        } else {
            inFlight -= 1
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.cont.resume(throwing: CancellationError())
    }
}

/// Deduplicates in-flight image fetches by URL. When two views (e.g. the
/// previous detail's `CachedAsyncImage` on teardown, and the new detail's
/// on appear) ask for the same URL concurrently, they share one network
/// request. The shared task is non-cancellable via a consumer's cancel —
/// that matters because cancelling a mid-transfer download and immediately
/// restarting it on the next view wastes the partial bytes and the TLS
/// slot. Here, a cancelled consumer just stops awaiting; the shared task
/// completes and URLCache stores the body so the next request is served
/// from local cache.
actor ImageDataLoader {
    static let shared = ImageDataLoader()

    private var inFlight: [URL: Task<Data?, Never>] = [:]

    /// `priority` is forwarded to `ImageThrottle.fetch.acquire`. Two
    /// concurrent callers for the same URL share one in-flight task —
    /// the FIRST caller's priority wins because the second sees the task
    /// already created and just awaits it. In practice the body's top
    /// images dispatch first (eager VStack creates them in tree order)
    /// so the lowest-index priority is the one that registers, which is
    /// what we want.
    func data(for url: URL, priority: Int = .max) async -> Data? {
        if let existing = inFlight[url] {
            return await existing.value
        }
        let task = Task<Data?, Never> {
            defer {
                Task { await ImageDataLoader.shared.cleanup(url: url) }
            }
            do {
                try await ImageThrottle.fetch.acquire(priority: priority)
            } catch {
                return nil
            }
            let request = URLRequest(url: url)
            do {
                let (data, response) = try await Networking.session.data(for: request)
                await ImageThrottle.fetch.release()
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                return data
            } catch {
                await ImageThrottle.fetch.release()
                return nil
            }
        }
        inFlight[url] = task
        return await task.value
    }

    private func cleanup(url: URL) {
        inFlight[url] = nil
    }
}

enum ImageThrottle {
    /// Concurrent `session.data(for:)` image fetches. Widened to 4 because
    /// after scene-phase returns from background the URLSession pool is
    /// stale; letting only 2 images handshake in parallel stretched the
    /// "gestures unresponsive" window to several seconds on a 20+-image
    /// detail page (observed on Humor posts after ~10 min backgrounded).
    /// Splitting fetch from decode lets I/O overlap with CPU so the total
    /// loading window contracts.
    static let fetch = AsyncSemaphore(maxConcurrent: 4)

    /// Concurrent CPU-heavy decodes. Kept at 2 so a detail-view open doesn't
    /// spike the main thread with rapid-fire `@State image` updates as
    /// decodes complete. Decode is ~50–100 ms per frame; any higher and the
    /// open animation stuttered in the original measurement.
    static let decode = AsyncSemaphore(maxConcurrent: 2)
}

// maxDimension 1200pt × scale 3 = 3600px on the long edge — overkill for an
// iPhone (≈1290px native) but leaves headroom for landscape full-screen.
// At ~38MB per fully-decoded image, the 200MB cap holds ~5 images comfortably,
// matching a typical scroll context (one screen of post body images).
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        // NSCache evicts on its own cost cap, but the 200MB cap is high
        // enough that on memory-tight devices jetsam can fire before
        // NSCache's own eviction has contracted us. Drop the pixel cache
        // eagerly on iOS memory warning so we shrink ahead of jetsam.
        // Aspect / natural-width siblings stay (tiny footprint, and
        // dropping them would make the next re-realize bounce frames).
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Session-scoped aspect ratio cache keyed by (variant, url). Survives
    /// NSCache UIImage eviction so a recycled `CachedAsyncImage` can still
    /// render at the right proportion on first layout even if the pixel
    /// cache was flushed. Tiny footprint (8 bytes × 1000 entries).
    private let aspects: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 1000
        return c
    }()

    /// Sibling of `aspects` storing the source's natural point width so
    /// `clampsToNaturalWidth: true` callers (body images) reserve the
    /// capped frame on first layout after re-realize / cache eviction.
    /// Same footprint and key shape as `aspects`.
    private let naturalWidths: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 1000
        return c
    }()

    func image(for url: URL, variant: String = "default") -> UIImage? {
        cache.object(forKey: key(for: url, variant: variant))
    }

    func aspectRatio(for url: URL, variant: String = "default") -> CGFloat? {
        aspects.object(forKey: key(for: url, variant: variant)).map { CGFloat(truncating: $0) }
    }

    func naturalPointWidth(for url: URL, variant: String = "default") -> CGFloat? {
        naturalWidths.object(forKey: key(for: url, variant: variant)).map { CGFloat(truncating: $0) }
    }

    func store(_ image: UIImage, for url: URL, variant: String = "default") {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let cost = Int(pixelW * pixelH * 4)
        cache.setObject(image, forKey: key(for: url, variant: variant), cost: cost)
        if pixelW > 0 && pixelH > 0 {
            aspects.setObject(
                NSNumber(value: Double(pixelW / pixelH)),
                forKey: key(for: url, variant: variant)
            )
            // `CachedAsyncImage` decodes UIImages with `scale = 1`, so
            // `image.size.width` already equals the pixel width and is the
            // value `clampsToNaturalWidth` callers cap on.
            naturalWidths.setObject(
                NSNumber(value: Double(image.size.width)),
                forKey: key(for: url, variant: variant)
            )
        }
    }

    func storeAspectRatio(_ ratio: CGFloat, for url: URL, variant: String = "default") {
        guard ratio > 0, ratio.isFinite else { return }
        aspects.setObject(NSNumber(value: Double(ratio)), forKey: key(for: url, variant: variant))
    }

    func storeNaturalPointWidth(_ width: CGFloat, for url: URL, variant: String = "default") {
        guard width > 0, width.isFinite else { return }
        naturalWidths.setObject(NSNumber(value: Double(width)), forKey: key(for: url, variant: variant))
    }

    private func key(for url: URL, variant: String) -> NSString {
        "\(variant)|\(url.absoluteString)" as NSString
    }
}
