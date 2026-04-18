import SwiftUI
import UIKit
import ImageIO

struct CachedAsyncImage: View {
    let url: URL
    var maxDimension: CGFloat = 1600

    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Color(uiColor: .secondarySystemBackground)
                    .overlay(ProgressView())
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
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

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            try Task.checkCancellation()

            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(data: data, maxDimension: limit, scale: scale)
            }.value

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

    private static func decode(data: Data, maxDimension: CGFloat, scale: CGFloat) -> UIImage? {
        let pixelLimit = max(maxDimension * scale, 256)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
