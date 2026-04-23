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

    @State private var image: UIImage?
    @State private var animatedFrames: [UIImage]?
    @State private var animatedDuration: TimeInterval = 0
    @State private var failed = false
    /// Aspect ratio discovered from the decoded image (or primed from the
    /// session aspect cache on init). Used when the caller didn't supply an
    /// explicit `aspectRatio` so the final-sized frame is reserved up-front
    /// on re-appearances — stops the 120pt placeholder → natural-height
    /// jump that shifts scroll position when images load.
    @State private var intrinsicAspectRatio: CGFloat?
    @Environment(\.displayScale) private var displayScale

    init(
        url: URL,
        maxDimension: CGFloat = 1600,
        maxPixelArea: CGFloat = 20_000_000,
        aspectRatio: CGFloat? = nil,
        cacheVariant: String = "default",
        showsPlaceholder: Bool = true
    ) {
        self.url = url
        self.maxDimension = maxDimension
        self.maxPixelArea = maxPixelArea
        self.aspectRatio = aspectRatio
        self.cacheVariant = cacheVariant
        self.showsPlaceholder = showsPlaceholder
        // Prime from the aspect cache so LazyVStack re-materialisation (and
        // re-scroll over previously-decoded images) renders at final size
        // on the FIRST layout pass instead of starting with a 120pt stub
        // and jumping once the decode resolves.
        _intrinsicAspectRatio = State(
            initialValue: aspectRatio
                ?? ImageCache.shared.aspectRatio(for: url, variant: cacheVariant)
        )
    }

    var body: some View {
        // Single ZStack keeps the view identity stable so SwiftUI doesn't
        // play its default slide/fade transition when the image swaps in
        // for the placeholder. Suppressing the inherited animation also
        // stops the visible "slide-from-right" jank during loading.
        let content = ZStack {
            if image == nil && animatedFrames == nil && !failed && showsPlaceholder {
                Color("AppSurface2")
                    .overlay(ProgressView())
                    // Placeholder exists purely to fill the slot; without
                    // this the Color absorbs the initial touch of a scroll
                    // gesture and SwiftUI delays handing it back to the
                    // parent ScrollView long enough to feel like a freeze.
                    .allowsHitTesting(false)
            }
            if let frames = animatedFrames, !frames.isEmpty {
                // SwiftUI's `Image(uiImage:)` renders only the first frame
                // of a multi-frame UIImage, so animated GIFs need a
                // UIImageView bridge to actually animate.
                AnimatedImageView(frames: frames, duration: animatedDuration)
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
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
        .task(id: url) { await load() }

        let effective = aspectRatio ?? intrinsicAspectRatio
        if let effective {
            content.aspectRatio(effective, contentMode: .fit)
        } else {
            content.frame(minHeight: image == nil && animatedFrames == nil && showsPlaceholder ? 120 : nil)
        }
    }

    private func load() async {
        image = nil
        animatedFrames = nil
        animatedDuration = 0
        failed = false

        let variant = cacheVariant

        if let cached = ImageCache.shared.image(for: url, variant: variant) {
            image = cached
            if cached.size.height > 0 {
                let aspect = cached.size.width / cached.size.height
                if intrinsicAspectRatio == nil {
                    intrinsicAspectRatio = aspect
                }
                // Opportunistically back-fill the aspect-ratio cache on
                // cache hits too, so images decoded by a pre-fix build
                // (image stored, ratio not) get a stable frame on the
                // next re-realize instead of bouncing through minHeight 120.
                if ImageCache.shared.aspectRatio(for: url, variant: variant) == nil {
                    ImageCache.shared.storeAspectRatio(aspect, for: url, variant: variant)
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
        let data = await ImageDataLoader.shared.data(for: url.atsSafe)
        guard !Task.isCancelled else { return }
        guard let data else {
            failed = true
            return
        }

        do {
            try await ImageThrottle.decode.acquire()
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
                    // Persist the ratio so subsequent re-realizations (LazyVStack
                    // derealize/realize during back-drag) reserve the final
                    // frame size from `init`, instead of collapsing to the
                    // minHeight: 120 placeholder for the duration of the
                    // cache-hit `.task`. Without this, a long post's body
                    // images briefly shrink to 120pt on re-realize, total
                    // content height contracts, and the viewport at deep
                    // scroll ends up past the new content end — blank screen.
                    ImageCache.shared.storeAspectRatio(aspect, for: url, variant: variant)
                }
            case .animated(let frames, let duration):
                // Animated GIFs aren't cached (the frame count × frame size
                // can balloon past the 200MB NSCache budget quickly, and
                // GIFs re-decode cheaply on re-entry). Aspect is cached
                // from the first frame so re-renders stay stable.
                animatedFrames = frames
                animatedDuration = duration
                if let first = frames.first, first.size.height > 0 {
                    let aspect = first.size.width / first.size.height
                    intrinsicAspectRatio = aspect
                    ImageCache.shared.storeAspectRatio(aspect, for: url, variant: variant)
                }
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
        case animated(frames: [UIImage], duration: TimeInterval)
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

    /// Memory budget for resident decoded frames of a single animated
    /// source. Keep-alive overlays hold their GIFs for the lifetime of
    /// the active post, so a 300-frame Twitch clip at 1080px would
    /// otherwise sit on ~1GB of decoded pixels and push the app toward
    /// jetsam. We fit as many frames as this budget allows and stride-
    /// subsample past it. 280MB matches the legacy envelope at 1080px
    /// (~4.6MB/frame × 60 frames) while letting smaller board GIFs —
    /// e.g. a 566×540 Bobaedream clip at 1.2MB/frame — keep all 200
    /// frames instead of being thinned to 60. That thinning stretched
    /// each sampled frame's dwell time to 4× the source, which users
    /// saw as the GIF playing in slow motion vs. the browser.
    nonisolated private static let animatedFrameByteBudget = 280 * 1024 * 1024

    /// Absolute frame ceiling so a pathological source (thousands of
    /// tiny frames well inside the byte budget) can't balloon decode
    /// time. 300 covers the longest sane board embed.
    nonisolated private static let animatedFrameCeiling = 300

    /// Floor so an exceptionally large in-cap frame can't drive the
    /// limit below this. 30 × animatedLongEdgeCap² × 4 ≈ 140MB, safely
    /// under budget even in the worst case.
    nonisolated private static let animatedFrameFloor = 30

    /// Long-edge cap (pixels) applied to animated frames. Lower than the
    /// still path's `maxDimension` to bound per-frame memory. Boards like
    /// Ppomppu and Clien rarely ship retina-quality GIFs; 1080px stays
    /// sharp on a 390pt column while cutting per-frame decode size by
    /// roughly half vs the still ceiling.
    nonisolated private static let animatedLongEdgeCap: CGFloat = 1080

    /// Walks every frame of a multi-image source (animated GIF / APNG) and
    /// sums the per-frame delay metadata into a total duration for
    /// UIImageView's `animationDuration`. Falls back to a 0.1s / frame
    /// default when the source omits delay properties so the animation
    /// still plays at a reasonable speed instead of flashing a single
    /// composite frame.
    nonisolated private static func decodeAnimated(
        source: CGImageSource,
        frameCount: Int,
        downsampleRatio ratio: CGFloat,
        longSide: CGFloat,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> DecodeResult? {
        // Tighter long-edge cap than the still path — frames compound, and
        // a keep-alive overlay sitting on 40 retina-scale frames adds up
        // fast. `longSide` can be 0 when the source reports no pixel
        // dimensions (corrupt header); clamp to the animated cap so we
        // still produce a viewable image.
        let targetLongSide = min(
            longSide > 0 ? longSide : animatedLongEdgeCap,
            animatedLongEdgeCap
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetLongSide,
        ]

        // Per-frame resident cost after downsampling (RGBA8888).
        // effectiveRatio is the 1D scale from source long edge down to
        // targetLongSide; squaring it converts to a 2D pixel-count ratio.
        // When the source reports no pixel dimensions (corrupt header),
        // fall back to a square frame at the long-edge cap — otherwise
        // sourceWidth×sourceHeight collapses to 0, the `max(…, 1)` guard
        // rescues it to 1 pixel, and `budgetFrames` explodes to the
        // ceiling (300). The subsequent native-decode branch would then
        // try to hold 300 full-resolution frames, which is exactly the
        // jetsam risk the budget exists to prevent.
        let sourceLong = max(sourceWidth, sourceHeight)
        let effectiveRatio = sourceLong > 0 ? min(1, targetLongSide / sourceLong) : 1
        let framePixels: CGFloat
        if sourceWidth > 0 && sourceHeight > 0 {
            framePixels = sourceWidth * sourceHeight * effectiveRatio * effectiveRatio
        } else {
            framePixels = targetLongSide * targetLongSide
        }
        let frameBytes = max(framePixels, 1) * 4
        let budgetFrames = Int(CGFloat(animatedFrameByteBudget) / frameBytes)
        let limit = max(animatedFrameFloor, min(animatedFrameCeiling, budgetFrames))

        // Subsample stride when the source exceeds our dynamic frame
        // limit. The window's delay is summed so the total loop duration
        // stays close to the source's original playback speed.
        let stride = max(1, (frameCount + limit - 1) / limit)
        var frames: [UIImage] = []
        frames.reserveCapacity(min(frameCount, limit))
        var totalDuration: TimeInterval = 0

        var sampleIndex = 0
        while sampleIndex < frameCount {
            let cg: CGImage?
            if ratio >= 1 && targetLongSide >= max(longSide, 1) {
                // Source already fits every cap — native decode preserves
                // pixel fidelity (e.g. a small meme GIF doesn't get
                // needlessly re-thumbnailed).
                cg = CGImageSourceCreateImageAtIndex(source, sampleIndex, nil)
            } else {
                cg = CGImageSourceCreateThumbnailAtIndex(source, sampleIndex, thumbnailOptions as CFDictionary)
            }
            if let cg {
                frames.append(UIImage(cgImage: cg, scale: 1, orientation: .up))
                // Sum the delays of every frame in this stride window so
                // the rendered loop keeps the source's total duration
                // instead of running stride× faster.
                let windowEnd = Swift.min(sampleIndex + stride, frameCount)
                for j in sampleIndex..<windowEnd {
                    totalDuration += frameDelay(at: j, in: source)
                }
            }
            sampleIndex += stride
        }
        guard !frames.isEmpty else { return nil }
        // Guard against degenerate sources whose per-frame delay values are
        // all zero — UIImageView treats duration = 0 as "render first frame
        // only", which would look identical to the bug we're fixing.
        let safeDuration = totalDuration > 0 ? totalDuration : Double(frames.count) * 0.1
        return .animated(frames: frames, duration: safeDuration)
    }

    nonisolated private static func frameDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
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

/// UIKit bridge that actually animates a multi-frame UIImage. SwiftUI's
/// `Image(uiImage:)` quietly renders only the first frame of an animated
/// UIImage, so detail views that relied on it showed every GIF as a still.
private struct AnimatedImageView: View {
    let frames: [UIImage]
    let duration: TimeInterval

    var body: some View {
        // Apply the first frame's aspect ratio on the SwiftUI side so the
        // view sizes itself against the available column width instead of
        // inheriting the GIF's native pixel dimensions. Without this a
        // 900×600 GIF in a ddanzi post pushed the detail ScrollView wider
        // than the screen, which in turn made the horizontal back-swipe
        // leave the overlay partially visible over the list on dismiss.
        let first = frames.first
        let aspect = first.map { $0.size.width / max($0.size.height, 1) } ?? 1
        AnimatedImageUIView(frames: frames, duration: duration)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }
}

private struct AnimatedImageUIView: UIViewRepresentable {
    let frames: [UIImage]
    let duration: TimeInterval

    func makeUIView(context: Context) -> FlexibleAnimatedImageView {
        let v = FlexibleAnimatedImageView(frame: .zero)
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.image = frames.first
        v.animationImages = frames
        v.animationDuration = duration
        v.animationRepeatCount = 0
        v.startAnimating()
        return v
    }

    func updateUIView(_ v: FlexibleAnimatedImageView, context: Context) {
        // Only rebind the frames when the array identity changed — reusing
        // the same arrays on unrelated re-renders would restart the
        // animation from frame 0 and make the GIF visibly stutter.
        guard v.animationImages?.first !== frames.first else { return }
        v.stopAnimating()
        v.image = frames.first
        v.animationImages = frames
        v.animationDuration = duration
        v.startAnimating()
    }
}

/// UIImageView that does *not* propagate its image's native pixel size as
/// an intrinsic content size. SwiftUI reads `intrinsicContentSize` to
/// compute a default frame for UIViewRepresentable, and for a regular
/// UIImageView that's the image's pixel dimensions — a big GIF would then
/// try to be 900pt wide inside a 390pt column. Returning `noIntrinsicMetric`
/// hands sizing back to SwiftUI's aspectRatio + frame modifiers.
///
/// Also listens for memory warnings so animated frame arrays can be
/// released under pressure without taking the whole app down. The still
/// `image` (first frame) stays set, so the post continues to render as a
/// frozen poster instead of a blank box. A later `updateUIView` call with
/// the same frames will rebind and restart animation — acceptable
/// degradation that prioritises keeping the app alive.
private final class FlexibleAnimatedImageView: UIImageView {
    private var memoryWarningObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stopAnimating()
            self.animationImages = nil
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

/// Bounded async semaphore with cancellation-safe waiters. Used by image
/// loading to cap concurrent network fetches and CPU decodes separately —
/// separating the two budgets lets I/O and CPU overlap rather than
/// serialising both through one queue.
actor AsyncSemaphore {
    let maxConcurrent: Int
    private var inFlight = 0
    private struct Waiter {
        let id: UUID
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
    func acquire() async throws {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append(Waiter(id: id, cont: cont))
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

    func data(for url: URL) async -> Data? {
        if let existing = inFlight[url] {
            return await existing.value
        }
        let task = Task<Data?, Never> {
            defer {
                Task { await ImageDataLoader.shared.cleanup(url: url) }
            }
            do {
                try await ImageThrottle.fetch.acquire()
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

    /// Session-scoped aspect ratio cache keyed by (variant, url). Survives
    /// NSCache UIImage eviction so a recycled `CachedAsyncImage` can still
    /// render at the right proportion on first layout even if the pixel
    /// cache was flushed. Tiny footprint (8 bytes × 1000 entries).
    private let aspects: NSCache<NSString, NSNumber> = {
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
        }
    }

    func storeAspectRatio(_ ratio: CGFloat, for url: URL, variant: String = "default") {
        guard ratio > 0, ratio.isFinite else { return }
        aspects.setObject(NSNumber(value: Double(ratio)), forKey: key(for: url, variant: variant))
    }

    private func key(for url: URL, variant: String) -> NSString {
        "\(variant)|\(url.absoluteString)" as NSString
    }
}
