import Foundation
import CoreGraphics
import ImageIO

/// Forces ImageIO + CoreGraphics framework initialization by decoding a
/// tiny bundled PNG on a detached task. After a long background period
/// iOS evicts the framework's decoder plugins; the first real post-image
/// decode then pays ~2.5 s of plugin reload, and that reload acquires a
/// process-wide lock that SwiftUI's layout path also needs — so the main
/// thread stalls for the same duration and scroll / back-swipe gestures
/// feel dead. Running a throwaway decode on scene-phase `.active`
/// takes that hit off the critical path so the user's first real image
/// decodes in milliseconds.
enum ImageWarmup {
    /// Smallest valid PNG (1×1 transparent, 67 bytes). Exercises the same
    /// `CGImageSourceCreateWithData` + `CreateThumbnailAtIndex` path that
    /// `CachedAsyncImage.decode` uses, so the plugin load is comprehensive.
    /// `nonisolated` because the detached task reads it off the main actor;
    /// the value is immutable `Data` (Sendable), so unsynchronised access
    /// is safe.
    nonisolated private static let tinyPNG: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])

    /// Fire-and-forget. Safe to call on every foreground — subsequent
    /// calls cost ~1 ms because the framework is already warm.
    nonisolated static func warm() {
        Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(tinyPNG as CFData, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
            ]
            _ = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
    }
}
