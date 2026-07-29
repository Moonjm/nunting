import SwiftUI

struct InlineVideoPlayer: View {
    let url: URL
    /// Poster image the parser already discovered (e.g. HTML5
    /// `<video poster="...">` or a site-specific CDN pattern). When nil the
    /// view falls back to the aagag `/o/{q}.jpg` convention and, failing
    /// that, a plain film-icon placeholder. Used as the visual backdrop
    /// shown until the AVPlayer produces its first frame.
    var posterURL: URL? = nil
    /// Set by `DetailBackDrag` while a back-drag is in flight
    /// so releasing a finger over the inline video doesn't push
    /// fullscreen playback when the user only intended to leave the
    /// detail screen.
    var tapGate: TapSuppressionGate? = nil
    /// Fires the moment the user's drag-down dismiss commits (touch-up
    /// past the threshold), BEFORE SwiftUI starts animating the cover
    /// off-screen. The host view (PostDetailView) raises a full-screen
    /// black overlay during the slide-down so the underlying detail
    /// doesn't progressively reveal — without this, the user sees the
    /// detail content while the cover is still mid-animation, intuits
    /// "the screen is back, I can scroll", and tries to scroll only to
    /// hit the dismiss-event window where touches don't yet route to
    /// the underlying view. The visual cue keeps the intent honest:
    /// nothing to interact with until the cover is fully gone.
    var onDismissBegin: () -> Void = {}
    /// True while the host detail overlay is actually on-screen. The
    /// overlay is keep-alive: closing it slides the whole detail view
    /// off-screen right (`.offset`) but leaves it mounted in the SwiftUI
    /// tree, so `onScrollVisibilityChange` — which only tracks position
    /// inside the detail's own ScrollView — keeps a viewport video marked
    /// `isVisible`. Without ANDing this in, a video would keep playing
    /// (audio included) after the user closes the detail. Defaults true so
    /// non-overlay callers are unaffected.
    var isOverlayVisible: Bool = true

    @State private var isPresented = false
    /// `onScrollVisibilityChange` callback target. Drives the inline
    /// AVPlayer's play/pause so an off-screen video doesn't keep its
    /// decoder spinning. Combined with `!isPresented` (see body) so the
    /// inline player also pauses while the fullscreen cover is up,
    /// avoiding two AVPlayers streaming the same asset in parallel.
    @State private var isVisible = false
    /// Aspect ratio measured from this view's own AVAsset load. `nil`
    /// until `onAspectKnown` fires; `effectiveAspect` falls back to the
    /// per-URL memo and then to the landscape default. Once the
    /// underlying `InlineAutoplayUIView` finishes reading the
    /// video track's `naturalSize` × `preferredTransform`, it
    /// fires `onAspectKnown` and we snap to the source's true
    /// aspect — vertical clips (9:16 ≈ 0.56) then render tall
    /// instead of letterbox-bound inside a 16:9 box.
    @State private var measuredAspect: CGFloat?

    var body: some View {
        ZStack {
            Color.black

            if let resolvedPoster {
                // Backdrop poster shown until the AVPlayer renders its
                // first frame. `AVPlayerLayer` with `.resizeAspect` is
                // transparent in any letterbox area, so the poster
                // also fills bars when source aspect doesn't match
                // the reserved frame (mostly during the preroll
                // window before `measuredAspect` snaps in).
                NetworkImage(
                    url: resolvedPoster,
                    thumbnailMaxPointSize: 720
                )
            } else {
                Image(systemName: "film")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // `isPlaying` ANDs visibility with NOT-presented so the
            // inline player pauses while the fullscreen cover takes
            // over. fullScreenCover doesn't unmount the underlying
            // view, so without the second clause the inline AVPlayer
            // would keep streaming alongside the fullscreen one.
            //
            // WebM container is unsupported by AVFoundation regardless
            // of the inner codec (VP9 plays fine in MP4 but not WebM),
            // so etoland's webm uploads route through a WKWebView path
            // — iOS WebKit decodes VP8/VP9-in-WebM since Safari 14.1.
            if isWebmContainer {
                WebmInlineWebView(
                    url: url,
                    isPlaying: isOverlayVisible && isVisible && !isPresented,
                    onAspectKnown: { aspect in
                        applyMeasuredAspect(aspect)
                    }
                )
            } else {
                InlineAutoplayVideoView(
                    url: url,
                    isPlaying: isOverlayVisible && isVisible && !isPresented,
                    onAspectKnown: { aspect in
                        applyMeasuredAspect(aspect)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(effectiveAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Tap-to-fullscreen overlay carved to exclude the bottom strip
        // where the scrub bar's UIKit gesture recognizers live. A
        // whole-frame `.onTapGesture` on the outer ZStack would race
        // SwiftUI's gesture system against the underlying UIKit
        // recognizers — and SwiftUI usually wins for taps that don't
        // turn into pans, so a tap on the scrub bar would open
        // fullscreen instead of seeking. Restricting the SwiftUI tap
        // to the top region leaves the bottom strip as plain SwiftUI
        // dead space; touches there fall through to the
        // `InlineAutoplayUIView` (which contains the scrub bar) and
        // its UIKit gestures fire normally. The constant is owned by
        // the UIView side so the two coordinate spaces can't drift.
        .overlay(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if tapGate?.suppressed == true { return }
                    isPresented = true
                }
                // The WebM (WKWebView) path has no custom UIKit scrub bar
                // to dodge — its WKWebView is `isUserInteractionEnabled =
                // false`, so the SwiftUI tap can safely cover the whole
                // frame and route every tap to fullscreen.
                .padding(.bottom, isWebmContainer ? 0 : InlineAutoplayUIView.scrubBarStripHeight)
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            // 0.1 (10%) instead of 0 so the player doesn't toggle
            // play/pause for sub-pixel frame movement during the
            // ScrollView's first layout pass; visible AVPlayer
            // play()/pause() are documented as cheap but on a long
            // post the back-to-back churn was visible as a frame
            // hiccup.
            isVisible = visible
        }
        .accessibilityLabel("영상 재생")
        .fullScreenCover(isPresented: $isPresented) {
            if isWebmContainer {
                WebmFullscreenPlayer(url: url, onDismissBegin: onDismissBegin)
            } else {
                FullscreenVideoPlayer(url: url, onDismissBegin: onDismissBegin)
            }
        }
    }

    // MARK: - Aspect reservation

    /// Layout reservation used before any metadata is known. Landscape
    /// (16:9) because most board-uploaded clips are landscape.
    nonisolated static let defaultAspect: CGFloat = 16.0 / 9.0

    /// Aspect ratios already measured this session, keyed by video URL.
    /// A LazyVStack row (comment list) drops its `@State` when SwiftUI
    /// derealizes it on a long scroll, so without the memo every
    /// re-realize restarts at `defaultAspect` and re-snaps to the true
    /// aspect once the asset loads — the same layout shift replayed on
    /// every pass over the same video. `NSCache` bounds the table and
    /// drops it under memory pressure; a miss is merely the old
    /// behaviour. Same storage shape as
    /// `PostDetailCommentRow.styledCache`.
    private static let aspectMemo: NSCache<NSURL, NSNumber> = {
        let cache = NSCache<NSURL, NSNumber>()
        cache.countLimit = 200
        return cache
    }()

    /// Aspect this view lays out with: own measurement first, then the
    /// session memo for the same URL, then the landscape default.
    /// Extracted (and `internal`) so the precedence is unit-testable —
    /// mirrors `NetworkImage.effectiveAspect`.
    nonisolated static func effectiveAspect(measured: CGFloat?, remembered: CGFloat?) -> CGFloat {
        measured ?? remembered ?? defaultAspect
    }

    /// Reject degenerate metadata (audio-only tracks, or assets whose
    /// `preferredTransform` makes both dimensions zero). Without the
    /// guard a bogus aspect collapses the SwiftUI frame to zero height
    /// and the slot disappears.
    nonisolated static func isUsableAspect(_ aspect: CGFloat) -> Bool {
        aspect.isFinite && aspect > 0
    }

    static func rememberedAspect(for url: URL) -> CGFloat? {
        aspectMemo.object(forKey: url as NSURL).map { CGFloat($0.doubleValue) }
    }

    static func rememberAspect(_ aspect: CGFloat, for url: URL) {
        guard isUsableAspect(aspect) else { return }
        aspectMemo.setObject(NSNumber(value: Double(aspect)), forKey: url as NSURL)
    }

    private var effectiveAspect: CGFloat {
        Self.effectiveAspect(measured: measuredAspect, remembered: Self.rememberedAspect(for: url))
    }

    private func applyMeasuredAspect(_ aspect: CGFloat) {
        guard Self.isUsableAspect(aspect) else { return }
        Self.rememberAspect(aspect, for: url)
        measuredAspect = aspect
    }

    /// Container-extension probe for the WKWebView fallback. Codec
    /// (VP8/VP9/AV1) doesn't matter for AVFoundation gating — the
    /// container itself is unsupported. Extensions on these board CDNs
    /// are reliable; URLs without extensions just default to the
    /// AVPlayer path and surface a load failure if they happen to be
    /// webm-served-as-bytes.
    private var isWebmContainer: Bool {
        url.pathExtension.lowercased() == "webm"
    }

    /// Parser-supplied poster wins; otherwise fall back to the aagag CDN's
    /// `/o/{q}.jpg` pattern, then to `nil` (→ film-icon placeholder).
    private var resolvedPoster: URL? {
        if let posterURL { return posterURL }
        return aagagPosterFallback
    }

    private var aagagPosterFallback: URL? {
        guard url.host?.contains("aagag.com") == true else { return nil }
        let last = (url.path as NSString).lastPathComponent
        guard last.hasSuffix(".mp4") else { return nil }
        let q = String(last.dropLast(4))
        return URL(string: "https://i.aagag.com/o/\(q).jpg")
    }
}
