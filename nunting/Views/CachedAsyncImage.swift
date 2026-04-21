import SwiftUI
import UIKit
import ImageIO

struct CachedAsyncImage: View {
    let url: URL
    var maxDimension: CGFloat = 1600
    var maxPixelArea: CGFloat = 20_000_000
    var aspectRatio: CGFloat?
    var cacheVariant: String = "default"
    /// When false, the loading state renders as an empty transparent view
    /// rather than the gray-box + spinner placeholder. Use this for small
    /// inline icons (comment level/auth icons) where the placeholder visibly
    /// flashes in and looks worse than a blank spot.
    var showsPlaceholder: Bool = true

    @State private var image: UIImage?
    @State private var animatedFrames: [UIImage]?
    @State private var animatedDuration: TimeInterval = 0
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

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
            if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
        .task(id: url) { await load() }

        if let aspectRatio {
            content.aspectRatio(aspectRatio, contentMode: .fit)
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
            return
        }

        let scale = displayScale
        let limit = maxDimension
        let areaLimit = maxPixelArea

        // Limit concurrent decodes globally so opening a 20-image post
        // doesn't spike the main thread with rapid-fire @State updates.
        //
        // Release via an explicit async call at every exit path — the old
        // `defer { Task { await release() } }` pattern spawned a detached
        // task for the release, so release ordering relative to a sibling
        // view's next `acquire` wasn't guaranteed and could subtly violate
        // the `maxConcurrent` budget under cancellation. `acquire()` now
        // throws on cancellation so a cancelled wait doesn't hold a slot
        // — if it throws, we never entered the work block and must not
        // call `release()`.
        do {
            try await ImageDecodeThrottle.shared.acquire()
        } catch {
            return
        }

        do {
            let (data, response) = try await Networking.session.data(for: URLRequest(url: url))
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed = true
                await ImageDecodeThrottle.shared.release()
                return
            }

            let decoded = try await decodeOffMain(data: data, limit: limit, maxPixelArea: areaLimit, scale: scale)
            try Task.checkCancellation()

            switch decoded {
            case .still(let img):
                ImageCache.shared.store(img, for: url, variant: variant)
                image = img
            case .animated(let frames, let duration):
                // Animated GIFs aren't cached (the frame count × frame size
                // can balloon past the 200MB NSCache budget quickly, and
                // GIFs re-decode cheaply on re-entry).
                animatedFrames = frames
                animatedDuration = duration
            case nil:
                failed = true
            }
            await ImageDecodeThrottle.shared.release()
        } catch is CancellationError {
            await ImageDecodeThrottle.shared.release()
            return
        } catch {
            failed = true
            await ImageDecodeThrottle.shared.release()
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

    private static func decode(data: Data, maxDimension: CGFloat, maxPixelArea: CGFloat, scale: CGFloat) -> DecodeResult? {
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
                longSide: longSide
            )
        }

        let cg: CGImage?
        if ratio >= 1 {
            // Source already fits both caps — full decode keeps native detail.
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
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

    /// Upper bound on how many decoded frames we keep resident for a single
    /// animated source. Keep-alive overlays hold their GIFs for the
    /// lifetime of the active post, so a 300-frame Twitch clip (surfaced
    /// as a GIF embed) would otherwise sit on ~1GB of decoded pixels and
    /// push the app toward jetsam. We subsample the source to fit this
    /// cap — animation plays at a slightly lower frame rate but still
    /// reads as motion.
    private static let animatedFrameLimit = 60

    /// Long-edge cap (pixels) applied to animated frames. Lower than the
    /// still path's `maxDimension` to bound per-frame memory. Boards like
    /// Ppomppu and Clien rarely ship retina-quality GIFs; 1080px stays
    /// sharp on a 390pt column while cutting per-frame decode size by
    /// roughly half vs the still ceiling.
    private static let animatedLongEdgeCap: CGFloat = 1080

    /// Walks every frame of a multi-image source (animated GIF / APNG) and
    /// sums the per-frame delay metadata into a total duration for
    /// UIImageView's `animationDuration`. Falls back to a 0.1s / frame
    /// default when the source omits delay properties so the animation
    /// still plays at a reasonable speed instead of flashing a single
    /// composite frame.
    private static func decodeAnimated(
        source: CGImageSource,
        frameCount: Int,
        downsampleRatio ratio: CGFloat,
        longSide: CGFloat
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

        // Subsample stride when the source exceeds our frame budget. A
        // 120-frame source maps to stride=2 (every other frame), yielding
        // a 60-frame loop at half the frame rate. The window's delay is
        // summed so the total loop duration stays close to the source's
        // original playback speed.
        let stride = max(1, (frameCount + animatedFrameLimit - 1) / animatedFrameLimit)
        var frames: [UIImage] = []
        frames.reserveCapacity(min(frameCount, animatedFrameLimit))
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

    private static func frameDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
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
        let v = FlexibleAnimatedImageView()
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

/// Caps the number of in-flight image decodes. Prevents a 20-image post from
/// firing all decodes simultaneously, which spammed the main thread with
/// `@State image` updates and stuttered the open animation.
actor ImageDecodeThrottle {
    static let shared = ImageDecodeThrottle()
    private let maxConcurrent = 2
    private var inFlight = 0
    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    /// Throws `CancellationError` when the caller's task is cancelled while
    /// waiting for a slot. Previously this used a non-throwing continuation
    /// with no cancellation hook, which could strand a cancelled waiter in
    /// the queue until an unrelated future `release()` happened along — in
    /// the worst case pinning `inFlight` at `maxConcurrent` indefinitely.
    /// Callers must only pair a successful `acquire()` with `release()`.
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

    func image(for url: URL, variant: String = "default") -> UIImage? {
        cache.object(forKey: key(for: url, variant: variant))
    }

    func store(_ image: UIImage, for url: URL, variant: String = "default") {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let cost = Int(pixelW * pixelH * 4)
        cache.setObject(image, forKey: key(for: url, variant: variant), cost: cost)
    }

    private func key(for url: URL, variant: String) -> NSString {
        "\(variant)|\(url.absoluteString)" as NSString
    }
}
