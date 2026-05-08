import SwiftUI
import SDWebImage
import SDWebImageSwiftUI

/// SDWebImage-backed body-image view. Replaces `CachedAsyncImage`
/// (visibilityGated: true, clampsToNaturalWidth: true) for `.image` blocks
/// in `PostDetailView`. Two reasons to switch:
///
/// 1. `AnimatedImage` decodes animated WebP / GIF / APNG via libwebp /
///    SDWebImage's native decoders instead of ImageIO. The custom
///    `DisplayLinkAnimatedImageView` still works but ImageIO's per-frame
///    random-access cost on animated WebP is the bottleneck the previous
///    investigation surfaced; libwebp brings that down 2-3×.
/// 2. `AnimatedImage` handles the static-vs-animated branch internally,
///    so callers don't need the `if multiFrame { player } else { Image }`
///    plumbing. One view for both.
///
/// `visibilityGated` is preserved (now via toggling the URL between nil
/// and the real value) — `LazyVStack` materialises ~2-3 viewports of
/// cells, and without this every realised cell would kick a fetch the
/// moment the detail commits, pushing the actually-visible images behind
/// 30+ off-screen ones in `SDWebImageDownloader`'s queue.
struct VisibilityGatedAnimatedImage: View {
    let url: URL
    let aspectRatio: CGFloat?
    let priority: Float

    @State private var hasBeenVisible = false
    /// Aspect cap discovered after first decode — read from
    /// `state.image.size` once SDWebImage delivers the image. Used for
    /// the layout reservation when the parser didn't supply an aspect
    /// up-front (older posts, sites without `<img width=…>` markup).
    @State private var measuredAspect: CGFloat?
    @State private var failed = false

    init(url: URL, aspectRatio: CGFloat? = nil, priority: Float = 0.5) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.priority = priority
    }

    var body: some View {
        // Layout reservation: explicit parser-supplied aspect wins;
        // otherwise the post-decode `measuredAspect`; otherwise no
        // aspect modifier (caller's parent decides minHeight).
        let effectiveAspect = aspectRatio ?? measuredAspect

        Group {
            if failed {
                // Tap-to-retry parity with the old `CachedAsyncImage` —
                // sporadic mid-post 5xx / connection-reset cases are
                // recoverable and silently leaving a placeholder is
                // worse UX than offering an explicit retry.
                Button {
                    failed = false
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
            } else if hasBeenVisible {
                // SDWebImage exposes a binary priority — the
                // `.highPriority` option moves a fetch to the front of
                // the downloader queue, replacing the legacy fine-grained
                // integer priority. Treat the top quartile of body
                // images (`priority > 0.5`) as high so the first
                // viewport wins races with deeper-but-already-realised
                // LazyVStack cells; everything else is FIFO.
                //
                // TODO: if SDWebImage adds a continuous priority API
                // later (or we find the queue starves at saturation),
                // upgrade this to a `downloadRequestModifier`-based
                // URLSessionTask.priority shim.
                AnimatedImage(
                    url: url,
                    options: priority > 0.5 ? [.highPriority] : []
                ) {
                    Color("AppSurface2")
                }
                .onSuccess { image, _, _ in
                    if measuredAspect == nil, image.size.height > 0 {
                        measuredAspect = image.size.width / image.size.height
                    }
                }
                .onFailure { _ in
                    failed = true
                }
                // SD's `.indicator(.activity)` would overlay the
                // placeholder — skip it to keep the loading state
                // identical to the prior gray box (the indicator
                // visibly flashes on cache hits and felt jankier).
                .resizable()
                .scaledToFit()
            } else {
                // Closed-gate placeholder — must be the same color +
                // shape as `AnimatedImage`'s placeholder so the swap
                // when `hasBeenVisible` flips doesn't visibly redraw.
                Color("AppSurface2")
            }
        }
        .applyAspect(effectiveAspect)
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0) { visible in
            // Single-direction flip: once an image is loaded we keep it
            // resident across scroll-aways. A two-way flip would
            // unmount `AnimatedImage` on scroll-out → SDWebImage
            // memory cache hit on scroll-back → still a placeholder
            // flash because the AnimatedImage view starts mid-decode.
            if visible { hasBeenVisible = true }
        }
        #if DEBUG
        .task(id: url) {
            // DEBUG misuse guard, ported from `CachedAsyncImage`. If a
            // visibility-gated image ends up outside a `ScrollView`,
            // `onScrollVisibilityChange` silently no-ops per Apple's
            // contract and the placeholder stays forever — stripped
            // from release builds via `#if DEBUG`.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !hasBeenVisible
            else { return }
            print("[VisibilityGatedAnimatedImage] WARNING: gate at \(url) hasn't received an onScrollVisibilityChange callback after 1s — is it inside a ScrollView?")
        }
        #endif
    }
}

private extension View {
    /// SwiftUI's `aspectRatio(_:contentMode:)` rejects nil — but we want
    /// the modifier to be a no-op when no aspect is known yet. Wrap it
    /// in a small @ViewBuilder so callers stay clean.
    @ViewBuilder
    func applyAspect(_ aspect: CGFloat?) -> some View {
        if let aspect, aspect > 0 {
            self.aspectRatio(aspect, contentMode: .fit)
        } else {
            self
        }
    }
}
