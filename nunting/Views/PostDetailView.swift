import SwiftUI
import UIKit
struct PostDetailView: View, Equatable {
    let post: Post
    let readStore: ReadStore
    let cache: PostDetailCache
    /// Flipped by ContentView's `panGesture` while a back-drag is in
    /// flight so an image / video tap firing on the same touch-up
    /// doesn't open a viewer / fullscreen player when the user was only
    /// trying to leave the detail screen.
    var tapGate: TapSuppressionGate? = nil
    /// True while the overlay is actually on-screen. Keep-alive means the
    /// view instance survives `hideDetail()` with only `detailOffset`
    /// animated off — UIKit never deallocates the hosted scrollview, so
    /// `StatusBarTapScrollClaimer` needs an explicit signal to release
    /// its grip on the list's `scrollsToTop` flag when the overlay
    /// slides off-screen.
    var isOverlayVisible: Bool = true
    /// Forwarded to `.scrollDisabled` on the inner `ScrollView` while a
    /// horizontal back-drag is in flight or the post-release spring is
    /// still settling — without it, layout callbacks during the spring
    /// can drift `contentOffset` and the scroll position the user had
    /// on dismiss isn't preserved for re-entry.
    var isScrollingBlocked: Bool = false
    /// Invoked from the custom back button in the header. The parent owns the
    /// overlay offset animation; this view just asks to be dismissed.
    let onDismiss: () -> Void

    // Without this explicit Equatable, SwiftUI can't compare `onDismiss`
    // (closures aren't Equatable) and treats PostDetailView as "possibly
    // changed" on every parent re-eval. During a back-drag the parent
    // re-evaluates every frame (detailOffset animates), so the inner
    // ScrollView + body VStack + comments LazyVStack of a long post gets
    // re-built on every frame too. Combined with heavy async image
    // decode that churn is expensive. Comparing the diffable inputs
    // (`post`, `isOverlayVisible`, `isScrollingBlocked`) lets SwiftUI
    // short-circuit the diff, while still propagating the scroll-lock
    // flip and any post-metadata change (title, commentCount, …) at
    // their edges.
    //
    // Fields deliberately excluded from `==`:
    // - `readStore`, `cache`: read only from `.task { … }`, never from
    //   `body`. Mutations don't need a body re-eval to propagate.
    // - `tapGate`: read synchronously from `.onTapGesture` closures at
    //   tap time, not from `body`. Same reasoning as readStore/cache.
    // - `onDismiss`: deliberately ignored — the closure captures
    //   ContentView's `hideDetail()`, which mutates `@State` via
    //   out-of-line storage, so calling the first-eval closure still
    //   mutates the current state.
    // - `loader`: an `@Observable` reference type owned by `@State`.
    //   SwiftUI tracks `loader.detail` / `.isLoading` / `.errorMessage`
    //   reads from `body` directly through observation, so a property
    //   mutation invalidates body even when `==` returns true. The
    //   loader instance itself is identity-stable across re-evals, so
    //   adding it to `==` would always compare equal anyway.
    static func == (lhs: PostDetailView, rhs: PostDetailView) -> Bool {
        lhs.post == rhs.post
            && lhs.isOverlayVisible == rhs.isOverlayVisible
            && lhs.isScrollingBlocked == rhs.isScrollingBlocked
    }

    @State private var loader = PostDetailLoader()
    @State private var selectedImage: ImageViewerItem?
    @State private var webItem: WebBrowserItem?
    /// True from the moment the user commits a fullscreen-cover dismiss
    /// (video drag-down, image X-tap or drag-down) until the slide-down
    /// animation + any AVKit/decode teardown has had enough time to
    /// settle. While true, a full-screen `Color.black` overlay obscures
    /// the detail content so the user doesn't see it progressively
    /// reveal under the dismissing cover and prematurely try to scroll
    /// — touches during that window route to the still-dismissing
    /// cover, not the detail, and the user perceives it as "터치가
    /// 바로 동작 안 한다". The overlay also absorbs taps in this window
    /// which keeps that intent honest. ContentView's pan gesture is
    /// `simultaneousGesture` so a back-drag still works.
    @State private var dismissCovering = false
    /// Monotonic counter bumped by `beginDismissCover()`. Each scheduled
    /// drop-timer captures the value at scheduling time and clears
    /// `dismissCovering` only if no later call superseded it. Without
    /// this guard, two dismisses inside the 450 ms window (e.g. user
    /// closes the video and immediately opens + closes an image) cause
    /// the first timer to clear the flag while the second cover is
    /// still mid-animation, flashing the detail content briefly.
    @State private var coverGeneration = 0
    /// Look-ahead warmer for body images. Rebuilt whenever the body image
    /// set changes (new post / refresh); nil until the first image arrives.
    @State private var imagePrefetcher: BodyImagePrefetcher?

    /// Body image URLs in document order — drives both the prefetcher's
    /// look-ahead list and the "is this the first image?" eager-load check.
    private var bodyImageURLs: [URL] {
        (loader.detail?.blocks ?? []).compactMap {
            if case .image(let url, _, _) = $0.kind { return url }
            return nil
        }
    }

    /// `atsSafe` URLs of heavy animated-WebP body images (the ones with a
    /// blur-up poster → rendered first-frame-only inline). The prefetcher must
    /// skip these: a full-decode prefetch of a 354-frame webp blocks the shared
    /// serial decode queue for ~14s. Matches `NetworkImage`'s
    /// `decodesFirstFrameOnly: posterURL != nil` gate.
    private var prefetchSkipURLs: Set<URL> {
        Set((loader.detail?.blocks ?? []).compactMap {
            if case .image(let url, let posterURL, _) = $0.kind, posterURL != nil {
                return url.atsSafe
            }
            return nil
        })
    }

    /// Minimum wall-clock delay between view appearance and the first
    /// `detail = ...` commit. Must exceed the iOS push animation (~350ms);
    /// committing earlier causes SwiftUI to build the image-heavy subtree
    /// on top of still-running animation frames and the push visibly
    /// stutters. Network fetch + SwiftSoup parse + comments fetch all run
    /// in parallel during this window, so the gate is "free" whenever
    /// load work is slower than animation; when load is faster, we pay the
    /// remainder to protect the animation.
    private static let renderCommitDelay: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            ScrollView {
                // Claims UIKit's status-bar-tap scroll-to-top for this
                // detail ScrollView. When the overlay is live, the list
                // screen behind is also visible with its own scrollsToTop
                // scroll view; having two in the window makes iOS scroll
                // neither. The claimer disables the other scroll views'
                // scrollsToTop while `isOverlayVisible == true`, and
                // restores them the moment the overlay slides off.
                StatusBarTapScrollClaimer(isActive: isOverlayVisible)
                    .frame(width: 0, height: 0)
                VStack(alignment: .leading, spacing: 16) {
                    WrappingTitleLabel(text: post.title)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Text(post.author)
                        Text(loader.detail?.fullDateText ?? post.dateText)
                        if let views = loader.detail?.viewCount {
                            Text("👁 \(views)")
                        }
                        if post.commentCount > 0 {
                            Text("💬 \(post.commentCount)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let source = loader.detail?.source {
                        PostDetailSourceBanner(source: source)
                    }

                    Divider()

                    articleContent

                    if let comments = loader.detail?.comments, !comments.isEmpty {
                        PostDetailCommentsSection(
                            comments: comments,
                            tapGate: tapGate,
                            onImageTap: { url in
                                if tapGate?.suppressed == true { return }
                                selectedImage = ImageViewerItem(url: url)
                            },
                            onVideoDismissBegin: { beginDismissCover() }
                        )
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
            .scrollDisabled(isScrollingBlocked)
            // Pull-to-refresh re-fetches the post from origin. Etoland's
            // SSR is non-deterministic about including comments inline
            // (sometimes comments show up, sometimes the server bails
            // out to client-side rendering and the SSR HTML lands here
            // empty); refresh gives the user a manual retry path that
            // also covers stale view counts / late-arriving edits on
            // every other site.
            .refreshable { await reloadDetail() }
        }
        // Fill the hosted container even when the SwiftUI ideal size would
        // otherwise be smaller — UIHostingController inside our overlay
        // representable sizes to its SwiftUI ideal by default, which left
        // the VStack vertically centered within a larger ZStack frame and
        // exposed the list underneath at the top/bottom bands.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Background spans the full frame including under the status
        // bar / notch so the list screen beneath the overlay doesn't
        // peek through the top safe area. The header VStack still
        // respects safe area, so the chevron / site name land below
        // the status bar as expected.
        .background(Color("AppSurface").ignoresSafeArea())
        // Intercept every link tap inside the detail view (body anchor
        // tags, NSDataDetector-autolinked URLs, comment body markdown links,
        // PostDetailDealLinkBanner, PostDetailYouTubeBanner, source badges…) and route
        // http/https targets through SFSafariViewController instead of
        // bouncing to the system Safari app. Non-web schemes fall through to
        // system handling so `tel:` / `mailto:` still work. Comment
        // @mentions are text-styled (not assigned a `.link` attribute), so
        // they don't fire `openURL` and aren't affected.
        //
        // `tapGate` short-circuit mirrors the image / video onTapGesture
        // guards: a right-edge back-drag fires `tapGate.suppress()` from
        // `ContentView.panGesture`, and on touch-up SwiftUI still delivers
        // the link tap that landed under the finger. Without this, a
        // back-swipe started over a linked span (body anchor, deal banner,
        // source badge) dismisses the detail AND opens SafariView on top
        // of the list — discard the openURL when the gate is hot.
        .environment(\.openURL, OpenURLAction { url in
            if tapGate?.suppressed == true { return .discarded }
            return presentInBrowser(url) ? .handled : .systemAction
        })
        .task(id: post.id) {
            readStore.markRead(post)
            // Anchor the commit gate at view appearance; the loader starts
            // work immediately and only waits on this deadline before
            // writing image-heavy state. Cache-hit short-circuit lives
            // inside the loader so the gate isn't paid on a warm restore.
            let renderReadyAt = ContinuousClock.now.advanced(by: Self.renderCommitDelay)
            await loader.load(post: post, cache: cache, renderReadyAt: renderReadyAt)
        }
        // Rebuild the look-ahead warmer whenever the body image set changes
        // (post load, pull-to-refresh). Cancel the old one first so a
        // superseded post stops warming its tail.
        .onChange(of: bodyImageURLs) { _, urls in
            imagePrefetcher?.cancel()
            guard !urls.isEmpty else { imagePrefetcher = nil; return }
            let prefetcher = BodyImagePrefetcher(urls: urls, skipPrefetch: prefetchSkipURLs)
            // Warm the head right away. The first image is eager (above the
            // fold), so its look-ahead shouldn't depend on whether its
            // `onAppear` fires before or after this `onChange`.
            prefetcher.imageBecameVisible(at: 0)
            imagePrefetcher = prefetcher
        }
        // The overlay is keep-alive, so `.onDisappear` doesn't fire on a
        // normal dismiss — cancel off the visibility flag instead so warming
        // stops the moment the user leaves the post. `.onDisappear` still
        // covers genuine teardown (scene exit).
        .onChange(of: isOverlayVisible) { _, visible in
            if !visible { imagePrefetcher?.cancel() }
        }
        .onDisappear { imagePrefetcher?.cancel() }
        .fullScreenCover(item: $selectedImage) { item in
            ImageViewer(url: item.url, onDismissBegin: { beginDismissCover() })
        }
        .sheet(item: $webItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        // Stays on top of every detail-screen layer (header, ScrollView,
        // background) for the duration of the fullscreen-video dismiss
        // animation. Color absorbs touches so a premature scroll attempt
        // lands on the overlay (does nothing visible) instead of on a
        // detail-content view that can't yet handle it. Removed by the
        // timer in `beginDismissCover()`.
        .overlay {
            if dismissCovering {
                Color.black.ignoresSafeArea()
            }
        }
    }

    /// Raise the full-screen black cover the moment a fullscreen cover
    /// (video or image viewer) dismiss commits, then drop it after long
    /// enough for the slide-down animation (~300 ms) and any AVKit /
    /// decode teardown (~50–150 ms on a typical short clip or image)
    /// to settle. Anything earlier and the user sees the detail revealing
    /// under the still-dismissing cover and tries to scroll into a window
    /// where touches don't yet route to the detail.
    private func beginDismissCover() {
        dismissCovering = true
        coverGeneration &+= 1
        let scheduledGeneration = coverGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            // Only clear if no later begin-call superseded this one. A
            // newer cover is responsible for its own clear; clearing here
            // would flash the detail content under the new cover.
            guard scheduledGeneration == coverGeneration else { return }
            dismissCovering = false
        }
    }

    /// Pull-to-refresh handler. Drops the cache for this post and re-runs
    /// the loader's network path. The view is already on screen, so the
    /// render-commit gate that `task(id:)` uses isn't needed — pass an
    /// already-elapsed deadline so the loader's `awaitRenderReady` is a
    /// no-op and the new `detail` writes flush as soon as parsing returns.
    private func reloadDetail() async {
        await loader.load(
            post: post,
            cache: cache,
            renderReadyAt: ContinuousClock.now,
            forceFresh: true
        )
    }

    /// Custom top bar. We present this view as a ZStack overlay (not through
    /// NavigationStack), so `.navigationTitle`/`.toolbar` have no effect and
    /// we render chrome ourselves. Fixed-width side buttons keep the site
    /// name visually centred.
    private var detailHeader: some View {
        HStack(spacing: 0) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Text(post.site.displayName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                if tapGate?.suppressed == true { return }
                presentInBrowser(post.url)
            } label: {
                Image(systemName: "safari")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color("AppSurface"))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Wraps the scheme gate + state assignment so the header button and
    /// the `openURL` environment override share one code path. Returns
    /// whether the URL was routed in-app so the OpenURLAction can report
    /// `.handled` vs `.systemAction` from the same check.
    @discardableResult
    private func presentInBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        webItem = WebBrowserItem(url: url)
        return true
    }

    @ViewBuilder
    private var articleContent: some View {
        if loader.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if let errorMessage = loader.errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let detail = loader.detail {
            // Eager VStack (not LazyVStack): keeps every body block's
            // height pinned once measured. A `LazyVStack` here let SwiftUI
            // derealize body items above the viewport when the user
            // scrolled deep into comments; on re-realize the image
            // placeholders collapsed to `minHeight: 120` before their
            // aspect-ratio frame came back, the running content height
            // contracted, and the viewport (deep at the comments) landed
            // past content-end — "back-drag from comments area → blank
            // screen". Concurrent fetches are now capped at 4 by
            // `SDWebImageDownloader.config.maxConcurrentDownloads`
            // (set in `SDWebImageSetup`), so dropping the lazy gate
            // doesn't burst the downloader.
            //
            // Computed once per render: maps each image block's id to its
            // 0-based position among image blocks, so the case below can spot
            // the first image (eager-load) and report look-ahead positions to
            // the prefetcher.
            let imageIndexByID = imageIndexMap(in: detail.blocks)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(detail.blocks.enumerated()), id: \.element.id) { _, block in
                    switch block.kind {
                    case .richText(let segments):
                        // SwiftUI `Text` + `.textSelection(.enabled)`
                        // only allows whole-paragraph copy, not the
                        // range selection iOS users expect. Route
                        // through a UITextView wrapper so the system
                        // magnifying glass + drag handles + share menu
                        // all light up; link taps still flow through
                        // the `openURL` environment override above.
                        SelectableRichText(
                            attributedString: attributedString(from: segments),
                            font: .preferredFont(forTextStyle: .body)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url, let posterURL, let aspectRatio):
                        // Body images go through SDWebImage's
                        // `AnimatedImage` (libwebp for animated WebP /
                        // GIF / APNG, native fast path for stills) via
                        // `NetworkImage` — viewport-intersection load
                        // gate + natural-width clamp + tap-to-retry,
                        // matching the behaviour the legacy
                        // `CachedAsyncImage(visibilityGated: true,
                        // clampsToNaturalWidth: true)` form had.
                        //
                        // No `thumbnailMaxPointSize` — body images can
                        // be either short-and-wide (normal photos) or
                        // tall-and-narrow (aagag long-form panels). SD's
                        // thumbnail caps the LONG edge of a single
                        // bounding box, so a 1000pt cap shrinks an
                        // 800×6000 panel to 400×3000 and the result
                        // renders blurry on the column. Decoding at
                        // native resolution costs more memory but
                        // `SDImageCache`'s 200MB cap evicts older
                        // entries to keep total residency bounded.
                        let imageIndex = imageIndexByID[block.id]
                        NetworkImage(
                            url: url,
                            aspectRatio: aspectRatio,
                            posterURL: posterURL,
                            // A poster is attached only to heavy humoruniv
                            // direct-attach WebP (animated 짤방). Those also get
                            // first-frame-only inline decode: full-animation
                            // decode is ~14s and blocks the shared serial decode
                            // queue, freezing every image below it. Static
                            // inline + tap-to-play (fullscreen) instead.
                            //
                            // KNOWN SCOPE LIMIT: this gate is humoruniv-only by
                            // design — `posterURL` is set solely by HumorParser
                            // (the one board with a thumbnail proxy to source a
                            // poster from). A large animated WebP from another
                            // board (Clien/Etoland/…) has `posterURL == nil`, so
                            // it still goes through `AnimatedImage` and would
                            // reproduce the freeze. Not yet observed elsewhere;
                            // if it surfaces, decouple first-frame-only from
                            // poster availability (its own block flag).
                            decodesFirstFrameOnly: posterURL != nil,
                            // Eager-load the first body image: it's above the
                            // fold on open, so skip the viewport gate and let
                            // its fetch start at commit instead of waiting for
                            // the first scroll-visibility callback.
                            visibilityGated: imageIndex != 0,
                            clampsToNaturalWidth: true,
                            // Each visible body image warms the next few below
                            // it so scrolling lands on cache hits.
                            onBecameVisible: {
                                if let imageIndex {
                                    imagePrefetcher?.imageBecameVisible(at: imageIndex)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if tapGate?.suppressed == true { return }
                            selectedImage = ImageViewerItem(url: url)
                        }
                    case .video(let url, let posterURL):
                        InlineVideoPlayer(
                            url: url,
                            posterURL: posterURL,
                            tapGate: tapGate,
                            onDismissBegin: { beginDismissCover() }
                        )
                    case .dealLink(let url, let label):
                        PostDetailDealLinkBanner(url: url, label: label)
                    case .embed(.youtube, let id):
                        PostDetailYouTubeBanner(videoID: id)
                    case .embed(.instagram, let id):
                        if let url = URL(string: "https://www.instagram.com/p/\(id)/") {
                            PostDetailDealLinkBanner(url: url, label: "Instagram 게시물 보기")
                        }
                    }
                }
            }
        }
    }

    /// Maps each image block's id to its 0-based index among the image
    /// blocks in `blocks` (richText / video / embed blocks don't advance the
    /// counter). Used to identify the first body image for eager-load and to
    /// give each image a stable position for prefetch look-ahead.
    private func imageIndexMap(in blocks: [ContentBlock]) -> [ContentBlock.ID: Int] {
        var map: [ContentBlock.ID: Int] = [:]
        var index = 0
        for block in blocks {
            if case .image = block.kind {
                map[block.id] = index
                index += 1
            }
        }
        return map
    }

    private func attributedString(from segments: [InlineSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let s):
                // Source sites often paste URLs as plain text (ddanzi's
                // `autolink` addon, for instance, only wraps them client-side
                // so the server HTML still exposes the bare string). Run
                // NSDataDetector so those become tappable too — explicit <a>
                // tags go through the `.link` branch below and keep their
                // original label.
                result.append(Self.linkifyPlainText(s))
            case .link(let url, let label):
                var part = AttributedString(label)
                part.link = url
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
                result.append(part)
            }
        }
        return result
    }

    /// Shared across post renders; NSDataDetector is thread-safe once
    /// constructed and allocating it per call would dwarf the actual
    /// detection cost on long bodies.
    private static let urlDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkifyPlainText(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        guard !s.isEmpty, let detector = urlDetector else { return attr }
        let ns = s as NSString
        let matches = detector.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return attr }

        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let stringRange = Range(match.range, in: s),
                  let attrRange = Range(stringRange, in: attr)
            else { continue }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = .accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }

}
