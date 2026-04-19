import SwiftUI
import UIKit
import ImageIO

struct CachedAsyncImage: View {
    let url: URL
    var maxDimension: CGFloat = 1600
    /// When false, the loading state renders as an empty transparent view
    /// rather than the gray-box + spinner placeholder. Use this for small
    /// inline icons (comment level/auth icons) where the placeholder visibly
    /// flashes in and looks worse than a blank spot.
    var showsPlaceholder: Bool = true

    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Single ZStack keeps the view identity stable so SwiftUI doesn't
        // play its default slide/fade transition when the image swaps in
        // for the placeholder. Suppressing the inherited animation also
        // stops the visible "slide-from-right" jank during loading.
        ZStack {
            if image == nil && !failed && showsPlaceholder {
                Color("AppSurface2")
                    .overlay(ProgressView())
            }
            if let image {
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
        .frame(minHeight: image == nil && showsPlaceholder ? 120 : nil)
        .transaction { $0.animation = nil }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        failed = false

        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }

        let scale = displayScale
        let limit = maxDimension

        // Limit concurrent decodes globally so opening a 20-image post
        // doesn't spike the main thread with rapid-fire @State updates.
        await ImageDecodeThrottle.shared.acquire()
        defer { Task { await ImageDecodeThrottle.shared.release() } }

        do {
            let (data, response) = try await Networking.session.data(for: URLRequest(url: url))
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed = true
                return
            }

            let decoded = try await decodeOffMain(data: data, limit: limit, scale: scale)
            try Task.checkCancellation()

            if let decoded {
                ImageCache.shared.store(decoded, for: url)
                image = decoded
            } else {
                failed = true
            }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    private func decodeOffMain(data: Data, limit: CGFloat, scale: CGFloat) async throws -> UIImage? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let img = Self.decode(data: data, maxDimension: limit, scale: scale)
            try Task.checkCancellation()
            return img
        }.value
    }

    private static func decode(data: Data, maxDimension: CGFloat, scale: CGFloat) -> UIImage? {
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
        // ~80 MB at 4 bytes/pixel — keeps a few decoded images under the
        // 200 MB NSCache cap while still letting tall-but-narrow images
        // through at native resolution.
        let maxPixelArea: CGFloat = 20_000_000

        let widthRatio = sourceW > 0 ? min(1, targetWidth / sourceW) : 1
        let sourceArea = max(sourceW * sourceH, 1)
        let areaRatio = sourceArea > maxPixelArea ? sqrt(maxPixelArea / sourceArea) : 1
        let ratio = min(widthRatio, areaRatio)

        let cg: CGImage?
        if ratio >= 1 {
            // Source already fits both caps — full decode keeps native detail.
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let longSide = max(sourceW, sourceH) * ratio
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
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

/// Caps the number of in-flight image decodes. Prevents a 20-image post from
/// firing all decodes simultaneously, which spammed the main thread with
/// `@State image` updates and stuttered the open animation.
actor ImageDecodeThrottle {
    static let shared = ImageDecodeThrottle()
    private let maxConcurrent = 3
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        // The releaser hands its slot to us via resume() without decrementing
        // inFlight, so the count already reflects this acquire — do NOT bump
        // it here or the gate drifts upward by one per release-with-waiter.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if let next = waiters.first {
            // Hand the slot directly to the next waiter — keeps inFlight
            // pinned at maxConcurrent until the queue drains.
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }
}

// maxDimension 1200pt × scale 3 = 3600px on the long edge — overkill for an
// iPhone (≈1290px native) but leaves headroom for landscape full-screen.
// At ~38MB per fully-decoded image, the 200MB cap holds ~5 images comfortably,
// matching a typical scroll context (one screen of post body images).
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let cost = Int(pixelW * pixelH * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
