import Foundation
import SDWebImage
import SDWebImageWebPCoder

/// One-shot SDWebImage configuration applied at app launch.
///
/// Registers the libwebp-backed coder so animated WebP (the dominant heavy
/// format on ppomppu / aagag bodies) decodes through libwebp instead of
/// ImageIO — measured 2-3× faster on multi-frame WebP and avoids the
/// per-frame `CGImageSource` random-access cost that pinned the previous
/// custom player's main thread.
///
/// Cache and downloader limits mirror the legacy `ImageCache` / `ImageThrottle`
/// budgets so the first cut behaves equivalently to the prior pipeline on
/// memory + concurrent fetches; we'll tune from measurement once the wrapper
/// is in production.
enum SDWebImageSetup {
    static func configure() {
        // libwebp coder must be inserted at the FRONT of the coder list,
        // not appended. SDWebImage walks coders in order and the first one
        // that claims the data wins; ImageIO's coder claims animated WebP
        // (badly — same slow path as the old pipeline) so without
        // `insertCoder` at index 0 the libwebp path never runs.
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)

        let cache = SDImageCache.shared
        // 200MB memory cap matches the prior `ImageCache` budget. NSCache-
        // backed under the hood so jetsam-time eviction is automatic.
        cache.config.maxMemoryCost = 200 * 1024 * 1024
        // 500MB disk cap with a 7-day expiry. Cold-start to a recently-read
        // post should serve images from disk (the gap the old pipeline had —
        // URLCache evicts aggressively for image-sized payloads). 7 days is
        // a compromise between "user re-reads the same hot post" and
        // unbounded disk growth on heavy users.
        cache.config.maxDiskSize = 500 * 1024 * 1024
        cache.config.maxDiskAge = 7 * 24 * 60 * 60

        let downloader = SDWebImageDownloader.shared
        // Match `ImageThrottle.fetch` (4). Higher values let more images
        // race for handshakes after scene-phase resume but spike the
        // gestures-unresponsive window; lower starves the fetch queue on
        // long detail pages.
        downloader.config.maxConcurrentDownloads = 4
        // 8s first-attempt timeout to fast-fail stale keep-alive
        // connections (the iOS pool's -1005 / -1001 case after
        // backgrounding). SDWebImage retries internally on transient
        // failures, so the second dial gets the session default.
        downloader.config.downloadTimeout = 8
    }
}
