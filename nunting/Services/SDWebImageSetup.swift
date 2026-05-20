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
/// Cache and downloader limits are sized for the same memory budget and
/// concurrent-fetch profile the previous pipeline used (200 MB memory
/// cache, 4 concurrent downloads); will tune from measurement once the
/// wrapper has run in production for a release.
enum SDWebImageSetup {
    static func configure() {
        // `addCoder` appends to the coders array, but
        // `SDImageCodersManager` walks coders **last-added-first** when
        // resolving a decoder — so the libwebp path wins over the
        // built-in ImageIO coder for `.webp` data without needing
        // explicit positioning. This is the registration form the
        // SDWebImage docs recommend.
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)

        // Redirect http→https on the URLSession redirect callback. ATS
        // blocks `https → 302 → http` chains and Korean board image
        // CDNs hit that constantly (fmkorea getfile proxy → ext.fmkorea
        // → plaync.co.kr 처럼) — without this, those images silently
        // 404 to the retry placeholder.
        SDWebImageDownloader.shared.config.operationClass = HTTPSRedirectingDownloaderOperation.self

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
        // 4 concurrent fetches. Higher values let more images race
        // for handshakes after scene-phase resume but spike the
        // gestures-unresponsive window; lower starves the queue on
        // long detail pages.
        downloader.config.maxConcurrentDownloads = 4
        // 8s timeout per attempt to fast-fail stale keep-alive
        // connections (the iOS pool's -1005 / -1001 case after
        // backgrounding). SDWebImage's internal retry re-issues with
        // the same `downloadTimeout`, so worst-case end-to-end is
        // ~16s (8s timeout × 2 attempts) before a failure surfaces —
        // still inside the placeholder-fatigue threshold and an order
        // of magnitude better than the URLSession 60s default that
        // would freeze the slot for a full minute on a single bad
        // pool entry.
        downloader.config.downloadTimeout = 8

        // Match the mobile Safari UA the rest of the app uses. Several
        // Korean board image CDNs (the ones embedded in ppomppu /
        // humor / aagag bodies) reject the default `SDWebImage/x.y.z`
        // UA with 403 — observed regression after the migration:
        // body images flipping to the "다시 시도" retry placeholder en
        // masse on first load. `Networking.userAgent` is the same
        // string `URLSession` uses for HTML fetches, so the image and
        // HTML legs of a single post visit identify identically and
        // CDNs treat the second leg as a continuation of the first.
        downloader.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
    }
}
