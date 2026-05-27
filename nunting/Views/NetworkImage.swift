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
                // `.atsSafe` upgrades plain `http://` to `https://` so
                // ATS-clean CDNs serve through without an
                // `NSAllowsArbitraryLoads` exception. Mirrors the
                // legacy `CachedAsyncImage` pre-fetch URL transform —
                // missing this caused board image CDNs that publish
                // their canonical `<img src>` as `http://` (carisyou,
                // some tistory mirrors) to silently fail on first
                // load, which surfaced as a flood of "다시 시도"
                // retry placeholders right after the SD migration.
                AnimatedImage(
                    url: url.atsSafe,
                    context: thumbnailContext
                ) {
                    placeholder
                }
                .onSuccess { image, _, _ in
                    // SDWebImage fires `.onSuccess` synchronously on
                    // memory-cache hit, which can land during a SwiftUI
                    // body evaluation — direct `@State` mutation then
                    // trips "Modifying state during view update".
                    // `DispatchQueue.main.async` defers to the next
                    // runloop tick, guaranteed outside the in-flight
                    // render (more bulletproof than Task { @MainActor }
                    // which the Swift cooperative executor MAY schedule
                    // within the same runloop iteration).
                    //
                    // SDWebImage decodes UIImages at the device scale
                    // (typically 3 on retina iPhones), so
                    // `image.size.width` is the *point* width =
                    // pixel width / scale. Multiplying back by
                    // `image.scale` recovers the source's pixel count,
                    // which matches the legacy `CachedAsyncImage`
                    // convention of decoding at scale 1 (where points
                    // and pixels were the same number). Without this
                    // conversion the `clampsToNaturalWidth` cap shrinks
                    // every body image to one-third of its intended
                    // frame on retina — observed regression: aagag's
                    // tall ~800px wide images rendering at ~133pt on a
                    // 390pt column.
                    let aspect: CGFloat? = (image.size.height > 0)
                        ? image.size.width / image.size.height : nil
                    let naturalPointWidth = image.size.width * image.scale
                    DispatchQueue.main.async {
                        if measuredAspect == nil, let aspect {
                            measuredAspect = aspect
                        }
                        if measuredNaturalPointWidth == nil {
                            measuredNaturalPointWidth = naturalPointWidth
                        }
                    }
                }
                .onFailure { _ in
                    DispatchQueue.main.async {
                        failed = true
                    }
                }
                // Cap decoded-frame memory for animated WebP/GIF (Korean
                // board 짤방 are typically 100-300 frames; SDAnimatedImageView's
                // default `maxBufferSize = 0` means "decode all frames upfront"
                // which can balloon to 60-100 MB per long animation and was a
                // main contributor to jetsam kills during detail loading).
                // 16 MB caps a single animation at ~80 RGBA frames @ retina
                // 800×500 — enough to keep the visible loop smooth, while
                // forcing re-decode on long animations rather than holding
                // every frame in RAM forever.
                .maxBufferSize(UInt(16 * 1024 * 1024))
                // Mark the decoded frame buffer as `NSCache`-purgeable so
                // a memory pressure event evicts frames eagerly instead
                // of waiting for the cap.
                .purgeable(true)
                .resizable()
                .scaledToFit()
            } else {
                // Closed-gate placeholder — must be shape-identical to
                // `AnimatedImage`'s placeholder so the swap when
                // `hasBeenVisible` flips doesn't visibly redraw.
                placeholder
            }
        }
        .applyAspect(effectiveAspect)
        .frame(maxWidth: clampsToNaturalWidth ? (measuredNaturalPointWidth ?? .infinity) : .infinity)
        .gateOnVisibility(enabled: visibilityGated) { visible in
            if visible { hasBeenVisible = true }
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

    @ViewBuilder
    private var placeholder: some View {
        if showsPlaceholder {
            Color("AppSurface2")
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
