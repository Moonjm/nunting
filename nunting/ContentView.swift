import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var favorites: FavoritesStore
    @State private var catalog = BoardCatalogStore()
    @State private var readStore = ReadStore()
    /// Session cache so a freshly-opened post (one whose overlay wasn't the
    /// keep-alive target) skips the network + parse on first render.
    @State private var detailCache = PostDetailCache()
    /// Owns selectedBoard / selectedFilter / searchQuery / boardNavScope /
    /// reloadToken plus the atomic transitions that make taskKey changes
    /// happen exactly once per user action.
    @State private var selection: BoardSelection
    /// Owns the keep-alive PostDetailView's activePost / offset / animation
    /// lock. The pan gesture below still drives the interactive drag
    /// directly against this controller's `offset` / `offsetBase`.
    @State private var detail = DetailOverlayController()

    @State private var drawerOpen = false
    @State private var drawerSection: DrawerSection = .favorites
    @State private var searchSheetPresented = false

    @State private var dragOffset: CGFloat = 0
    @State private var dragDirection: DragDirection?
    @State private var dragLockBaseline: CGFloat = 0
    @State private var scrollLocked = false
    @State private var containerHeight: CGFloat = 0
    /// Y position (in the body's coordinate space) where the combined
    /// filter-bar + bottom-bar area begins. Drags that start at or below
    /// this line belong to the bar/chips, not the drawer/detail overlay.
    /// `.infinity` until first measurement so the fallback exclusion runs.
    @State private var bottomAreaTopY: CGFloat = .infinity
    /// Lightweight gate the panGesture flips on whenever it sees any
    /// horizontal-dominant movement, even below the drawer/detail commit
    /// thresholds. Read by list rows in `onTapGesture` to suppress an
    /// otherwise-firing tap when the user just intended a tiny `→` / `←`
    /// drag — kept as a class instance so flipping it doesn't re-render
    /// the whole tree, and reset asynchronously after `onEnded` so the
    /// row's tap closure (which fires on the same touch-up) sees the
    /// blocked state before it clears.
    @State private var rowTapGate = TapSuppressionGate()
    /// Same shape as `rowTapGate` but flipped by the detail overlay's
    /// back-drag branch in `panGesture`. Read by image / video tap
    /// handlers inside `PostDetailView` so a `→` back-drag doesn't
    /// accidentally tap an image or video sitting under the user's
    /// finger when they release.
    @State private var detailMediaTapGate = TapSuppressionGate()

    /// Set by `SelectableRichText` while a `UITextView` selection is
    /// non-empty (handle drag in progress or text selected awaiting
    /// menu action). Read at the top of `panGesture` to bail the
    /// back-drag entirely so a rightward selection-handle drag
    /// doesn't pull the overlay off-screen.
    @State private var textSelectionGate = TextSelectionGate()

    private let drawerWidth: CGFloat = 300
    /// Height of the bottom bar area (bar + filter chips + safe area buffer)
    /// where horizontal swipes should belong to the board-step gesture, not
    /// the drawer-open gesture.
    private let bottomGestureExclusion: CGFloat = 110

    init() {
        // Open the user's top favorite on launch so the first thing they see
        // is the board they care about. Falls back to Clien news for fresh
        // installs that haven't favorited anything yet.
        let store = FavoritesStore()
        _favorites = State(initialValue: store)
        if let firstFav = store.favoriteBoards().first {
            _selection = State(initialValue: BoardSelection(
                initialBoard: firstFav,
                initialNavScope: .favorites
            ))
        } else {
            _selection = State(initialValue: BoardSelection(
                initialBoard: .clienNews,
                initialNavScope: .site(.clien)
            ))
        }
    }

    var body: some View {
        @Bindable var selection = selection
        ZStack(alignment: .leading) {
            Color("AppSurface")
                .ignoresSafeArea()

            mainScreen
                .id(selection.reloadToken)

            Color("AppSurface")
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            Color.black
                .opacity(0.3 * drawerProgress)
                .ignoresSafeArea()
                .allowsHitTesting(drawerOpen)
                .onTapGesture { closeDrawer() }

            SideDrawer(
                favorites: favorites,
                catalog: catalog,
                currentBoardID: selection.board.id,
                selectedSection: $drawerSection,
                onSelectBoard: { board in
                    selection.select(board, navScope: drawerSection)
                    closeDrawer()
                },
                onClose: closeDrawer
            )
            .frame(width: drawerWidth)
            .offset(x: drawerXOffset)

            // Permanent-mount detail overlay. Once `activePost` is set,
            // the PostDetailView stays live in the SwiftUI tree for the
            // rest of the session — dismiss is nothing more than a
            // `.offset(x:)` animation that pushes the view off-screen
            // right. The underlying UIScrollView, loaded images, GIF
            // frames, and every `@State` inside PostDetailView are all
            // preserved by inertia: nothing is ever detached from the
            // view hierarchy. `.id(post.id)` forces a rebuild only when
            // the user actively opens a DIFFERENT post (single-post
            // state preservation; multi-post would need an LRU layered
            // on top of this).
            if let post = detail.activePost {
                PostDetailView(
                    post: post,
                    readStore: readStore,
                    cache: detailCache,
                    tapGate: detailMediaTapGate,
                    textSelectionGate: textSelectionGate,
                    isOverlayVisible: detail.isOverlayVisible,
                    // `scrollLocked` is set by `panGesture`'s horizontal
                    // classification; `detail.animating` extends the lock
                    // across the post-release spring so the inner scroll
                    // position can't drift while the overlay slides in/out.
                    isScrollingBlocked: scrollLocked || detail.animating,
                    onDismiss: { detail.hide() }
                )
                // `.equatable()` pairs with PostDetailView's custom `==` to
                // short-circuit body re-evaluation when only the `onDismiss`
                // closure identity changed (ContentView re-evaluates every
                // frame of a back-drag as `detail.offset` animates, creating
                // a fresh closure each time). Without this the inner
                // ScrollView + body VStack + comments LazyVStack rebuild
                // per frame on long posts — expensive churn that compounds
                // with heavy async image decode.
                .equatable()
                .id(post.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // PostDetailView already owns its background + ignores
                // safe area for that background, so NO additional
                // `.ignoresSafeArea()` here — applying it at this level
                // would push the detail header (chevron, site name,
                // Safari button) up behind the status bar / notch.
                .offset(x: detail.offset)
                // Interactive back-drag drives `detail.offset` via the
                // ContentView-level `panGesture`. Block hit-testing on
                // the detail whenever it's visibly off-screen so the
                // list beneath receives taps/scrolls without the stale
                // (but still-mounted) PostDetailView intercepting.
                .allowsHitTesting(detail.allowsHitTesting)
                .zIndex(10)
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContainerHeightKey.self, value: proxy.size.height)
                    .preference(key: ContainerWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ContainerHeightKey.self) { containerHeight = $0 }
        .onPreferenceChange(ContainerWidthKey.self) { newWidth in
            detail.updateContainerWidth(newWidth)
        }
        .onPreferenceChange(BottomAreaTopKey.self) { bottomAreaTopY = $0 }
        .simultaneousGesture(panGesture)
        .task {
            // One-shot on first view appearance per app launch — open
            // TLS + HTTP/2 connections to every supported host so the
            // first real list/detail fetch per host skips the 300-700ms
            // handshake cost (measured in perf log as the dominant
            // cold-hit outlier). `ImageWarmup` primes ImageIO so the
            // first real image decode doesn't pay the plugin cold-load
            // (instrumentation showed a ~2.5 s main-actor stall after
            // long background otherwise).
            Networking.prewarmConnections()
            ImageWarmup.warm()
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-warm on foreground re-entry: iOS may have torn down
            // pooled connections and evicted ImageIO plugins during
            // background time, so the first request / decode after
            // coming back pays the respective cold cost otherwise.
            // Same trigger silently revalidates any board catalog
            // older than `staleTTL` (default 6h) so apps backgrounded
            // overnight pick up upstream board renames / additions.
            if phase == .active {
                Networking.prewarmConnections()
                ImageWarmup.warm()
                Task { await catalog.revalidateLoadedCatalogs() }
            }
        }
    }

    private var mainScreen: some View {
        @Bindable var selection = selection
        // Bar (filter chips + bottom bar) is declared as the list's
        // bottom safe-area inset rather than a sibling in a VStack so
        // SwiftUI computes the List's `contentInset.bottom` as
        // `bar height + home-indicator inset` for us. The previous
        // VStack arrangement had a race where, after a slow first
        // load (e.g. switching to a heavy Inven board), the late
        // `loadingView → listView` body swap materialised
        // `.background(...ignoresSafeArea())` on the List against an
        // already-settled layout — the List's bottom inset stayed at
        // 0, letting rows render past the bar into the home-indicator
        // zone. `.safeAreaInset` makes the inset declarative and
        // race-immune, which is also the canonical pattern Mail /
        // Messages use for their bottom bars.
        return BoardListView(
            board: selection.board,
            filter: selection.filter,
            searchQuery: selection.searchQuery,
            scrollLocked: scrollLocked,
            shouldSuppressRowTap: { [rowTapGate] in rowTapGate.suppressed },
            readStore: readStore,
            onSelectPost: { post in
                detail.show(post)
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !selection.board.filters.isEmpty {
                    BoardFilterBar(board: selection.board, selection: $selection.filter)
                }
                MainBottomBar(
                    board: selection.board,
                    onBoardDoubleTap: { selection.requestReload() },
                    onSearch: { searchSheetPresented = true },
                    onPrev: { stepBoard(by: -1) },
                    onNext: { stepBoard(by: 1) }
                )
            }
            .background(
                GeometryReader { proxy in
                    // `.global` so the value lines up with the
                    // `.global` panGesture's `value.startLocation.y`
                    // — both are now in window coordinates and the
                    // existing `>= bottomAreaTopY` comparison stays
                    // correct without converting at gesture time.
                    Color.clear.preference(
                        key: BottomAreaTopKey.self,
                        value: proxy.frame(in: .global).minY
                    )
                }
            )
        }
        .onChange(of: selection.filter) { _, _ in
            // Filter switches can swap the path entirely (BoardFilter.replacementPath),
            // so the prior search query may not be meaningful on the new endpoint.
            selection.searchQuery = nil
        }
        .sheet(isPresented: $searchSheetPresented) {
            SearchSheet(
                board: selection.board,
                initialQuery: selection.searchQuery ?? "",
                onSubmit: { q in selection.searchQuery = q },
                onClear: { selection.searchQuery = nil }
            )
        }
    }

    private var drawerProgress: CGFloat {
        let base: CGFloat = drawerOpen ? drawerWidth : 0
        let target = base + drawerApplicableDrag
        return max(0, min(1, target / drawerWidth))
    }

    /// Portion of the current drag that should feed `drawerProgress`. Zero
    /// whenever the drag is classified as a detail back/forward swipe, so
    /// the drawer doesn't flash open while the detail overlay is tracking
    /// the same finger.
    private var drawerApplicableDrag: CGFloat {
        guard detail.activePost != nil else { return dragOffset }
        // Overlay exists. Detail back-swipe (base 0) and forward-reveal
        // (dragging left) both own the drag; only a rightward drag started
        // while the overlay is hidden still belongs to the drawer.
        if detail.offsetBase == 0 { return 0 }
        return dragOffset > 0 ? dragOffset : 0
    }

    private var drawerXOffset: CGFloat {
        -drawerWidth + drawerWidth * drawerProgress
    }

    /// Walk the key window's view hierarchy and return `true` if
    /// `point` lies within 44pt of either selection handle on any
    /// UITextView that currently has a non-empty selection. UITextView's
    /// own handle hit-area is tight (~22pt diameter), so a touch
    /// landing slightly off the visible blue circle isn't recognized
    /// by UITextView as a handle drag — which then leaves the touch
    /// to be classified as a back-swipe even though the user clearly
    /// meant to grab the handle. Inflate the effective hit zone to
    /// the Apple-HIG-standard 44pt tap target so "close enough"
    /// touches block back-drag.
    ///
    /// `point` is in key-window coordinates (panGesture uses
    /// `coordinateSpace: .global`).
    private func touchStartedNearSelectionHandle(at point: CGPoint) -> Bool {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        return windowContainsSelectionHandleNear(point, radius: 44, in: window)
    }

    private func windowContainsSelectionHandleNear(
        _ point: CGPoint,
        radius: CGFloat,
        in view: UIView
    ) -> Bool {
        if let tv = view as? UITextView,
           let range = tv.selectedTextRange,
           !range.isEmpty {
            let startRect = tv.caretRect(for: range.start)
            let endRect = tv.caretRect(for: range.end)
            // Start handle sits at the top of the start caret rect;
            // end handle sits at the bottom of the end caret rect.
            // `convert(_:to: nil)` walks the superview chain up to
            // the window's coordinate system.
            let startHandle = tv.convert(CGPoint(x: startRect.midX, y: startRect.minY), to: nil)
            let endHandle = tv.convert(CGPoint(x: endRect.midX, y: endRect.maxY), to: nil)
            if hypot(point.x - startHandle.x, point.y - startHandle.y) <= radius { return true }
            if hypot(point.x - endHandle.x, point.y - endHandle.y) <= radius { return true }
        }
        for sub in view.subviews {
            if windowContainsSelectionHandleNear(point, radius: radius, in: sub) { return true }
        }
        return false
    }

    private var panGesture: some Gesture {
        // `.global` so `value.startLocation` shares the same window-
        // coordinate space as `bottomAreaTopY` (which `BottomAreaTopKey`
        // publishes via `frame(in: .global).minY`). Without the match,
        // the local-coordinate start point sits below the top safe-
        // area inset and `startedInBottomBar`'s `>=` comparison was
        // ~47-59pt off on iPhones with notch / Dynamic Island.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // Expand UITextView's tight selection-handle hit area
                // to the HIG-standard 44pt tap target. A touch that
                // starts within 44pt of either handle is treated as
                // handle-grab intent — refresh the gate every tick so
                // its 180ms TTL stays hot through the entire drag.
                let nearHandle = touchStartedNearSelectionHandle(at: value.startLocation)
                if nearHandle {
                    textSelectionGate.touch()
                }
                if nearHandle || textSelectionGate.isActive {
                    // Selection-interaction guard. The gate is touched
                    // by SelectableRichText's coordinator from three
                    // signals, each excluding pure swipes on body text:
                    //   1. `SelectionTrackingTextView.becomeFirstResponder`
                    //      — UITextView entering selection mode.
                    //   2. A 0.12s `UILongPressGestureRecognizer` —
                    //      loupe / hold intent.
                    //   3. Filtered `textViewDidChangeSelection` — range
                    //      modifications (handle drag, menu Select →
                    //      drag).
                    //
                    // If a prior tick had already classified as
                    // horizontal and moved `detail.offset` before the
                    // gate flipped on, snap the overlay back to its
                    // pre-drag base so it doesn't sit stranded mid-
                    // screen for the rest of the drag.
                    if dragDirection == .horizontal,
                       detail.activePost != nil,
                       detail.offset != detail.offsetBase {
                        detail.beginAnimationLock()
                        let target = detail.offsetBase
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            detail.offset = target
                            dragOffset = 0
                        }
                    }
                    return
                }
                // Don't fight the bottom-bar swipe (board step) when the drag
                // started inside the bar's hit area.
                if startedInBottomBar(value) { return }
                let absW = abs(value.translation.width)
                let absH = abs(value.translation.height)
                // Block list-row taps as soon as we see *any* horizontal
                // intent (≥ 4pt and dominant) — even a small `→` drag that
                // never reaches the drawer commit threshold should not
                // surface as a tap on the row underneath when the user
                // releases. The gate uses a TTL deadline so we don't have
                // to schedule a reset; if the gesture is cancelled and
                // `onEnded` never fires, the deadline lapses on its own.
                if absW >= 4 && absW >= absH {
                    rowTapGate.suppress()
                }
                if dragDirection == nil {
                    if absW > 10 && absW >= absH {
                        dragDirection = .horizontal
                        dragLockBaseline = value.translation.width
                        scrollLocked = true
                        detail.offsetBase = detail.offset
                    } else if absH > 10 && absH > absW {
                        dragDirection = .vertical
                    }
                }
                if dragDirection == .horizontal {
                    dragOffset = value.translation.width - dragLockBaseline
                    if detail.activePost != nil && detail.offsetBase == 0 {
                        // Back-drag from the visible overlay. Track the
                        // finger so the detail follows the drag out to
                        // the right; the inner ScrollView is gated by
                        // `isScrollingBlocked` so its pan can't drift
                        // under us during the drag.
                        detailMediaTapGate.suppress()
                        detail.offset = max(0, min(detail.containerWidth, dragOffset))
                    } else if detail.activePost != nil && detail.offsetBase >= detail.containerWidth {
                        // Forward-swipe reveal: overlay hidden at drag
                        // start and finger moving leftward pulls it in.
                        // If the finger reverses back rightward past
                        // the start, snap the overlay fully hidden again
                        // so the next swipe re-enters forward-reveal
                        // mode cleanly instead of getting stuck at a
                        // partial reveal.
                        if dragOffset < 0 {
                            detail.offset = max(0, min(detail.containerWidth, detail.containerWidth + dragOffset))
                        } else {
                            detail.offset = detail.containerWidth
                        }
                    }
                }
            }
            .onEnded { value in
                // No explicit gate reset — `TapSuppressionGate` uses a
                // TTL deadline that lapses on its own (see the class
                // doccomment for why this matters when `.onEnded` is
                // skipped entirely).
                if textSelectionGate.isActive {
                    // Mid-drag the gate activated, and a prior tick may
                    // have already moved `detail.offset` interactively
                    // — without this snap-back, the overlay strands at
                    // wherever the last pre-gate tick left it and the
                    // user sees a screenshot like the bug report
                    // (overlay frozen at ~30% offset).
                    if dragDirection == .horizontal,
                       detail.activePost != nil,
                       detail.offset != detail.offsetBase {
                        detail.beginAnimationLock()
                        let target = detail.offsetBase
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            detail.offset = target
                            dragOffset = 0
                        }
                    }
                    resetDragState()
                    return
                }
                if startedInBottomBar(value) {
                    resetDragState()
                    return
                }
                let lockedHorizontal = dragDirection == .horizontal
                let baseline = dragLockBaseline
                let base = detail.offsetBase
                let hasActive = detail.activePost != nil
                let containerW = detail.containerWidth
                resetDragState()

                guard lockedHorizontal else {
                    dragOffset = 0
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let traveled = value.translation.width - baseline

                // Detail overlay modes take precedence — the drag already
                // moved `detail.offset` interactively, so committing the
                // correct end state here preserves continuity with the
                // finger's position.
                if hasActive && base == 0 {
                    // Back-drag: overlay was fully visible at drag
                    // start. Commit to hidden if the finger travelled
                    // past the distance / velocity thresholds, else
                    // snap back to fully visible.
                    let shouldDismiss = detail.shouldDismissSwipe(dx: traveled, velocityX: velocity)
                    detail.beginAnimationLock()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        detail.offset = shouldDismiss ? containerW : 0
                        dragOffset = 0
                    }
                    return
                }
                if hasActive && base >= containerW && traveled < 0 {
                    // Forward-swipe reveal: low threshold matches the old
                    // lastOpenedPost re-push so a light flick from the right
                    // edge is enough to pull the overlay back in.
                    let shouldReveal = traveled < -32 || velocity < -120
                    detail.beginAnimationLock()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        detail.offset = shouldReveal ? 0 : containerW
                        dragOffset = 0
                        if shouldReveal && drawerOpen {
                            drawerOpen = false
                        }
                    }
                    return
                }

                // Drawer commit (overlay absent, or overlay hidden + drag
                // went rightward).
                let shouldOpen: Bool
                if drawerOpen {
                    shouldOpen = !(traveled < -drawerWidth / 3 || velocity < -150)
                } else {
                    shouldOpen = (traveled > 50 || velocity > 90)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    drawerOpen = shouldOpen
                    dragOffset = 0
                    // If forward-reveal was mid-drag and the user reversed
                    // into a drawer gesture, the overlay may still sit at a
                    // partial reveal from `onChanged`. Snap it fully hidden
                    // here so the next forward-swipe sees the expected base.
                    if hasActive && base >= containerW && detail.offset != containerW {
                        detail.offset = containerW
                    }
                }
            }
    }

    private func resetDragState() {
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
    }

    private func startedInBottomBar(_ value: DragGesture.Value) -> Bool {
        // Prefer the measured top of the filter+bar area so a tap-with-jitter
        // on a chip ("10추", "이슈모음 전체", etc.) is always classified as
        // belonging to the bar, regardless of chip height / Dynamic Type.
        if bottomAreaTopY.isFinite {
            return value.startLocation.y >= bottomAreaTopY
        }
        guard containerHeight > 0 else { return false }
        return value.startLocation.y > containerHeight - bottomGestureExclusion
    }

    /// Cycle through whichever list the user opened the current board from
    /// (favorites vs. a site's catalog). Wraps around so swipe browsing stays
    /// continuous; no-ops if the scope only has one board.
    private func stepBoard(by delta: Int) {
        let pool: [Board]
        switch selection.navScope {
        case .favorites:
            pool = favorites.favoriteBoards()
        case .site(let s):
            pool = catalog.boards(for: s)
        }
        // Atomic state batch — see `BoardSelection.select` for why a
        // single mutation matters (taskKey debouncing, no double-fetch).
        withAnimation(.easeInOut(duration: 0.15)) {
            selection.step(by: delta, within: pool)
        }
    }

    private func closeDrawer() {
        resetDragState()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            drawerOpen = false
            dragOffset = 0
        }
    }
}

private enum DragDirection {
    case horizontal
    case vertical
}

private struct ContainerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reference-typed gate that gestures use to tell child taps
/// "you just saw a horizontal drag — don't fire on release". A class
/// (not @State value type) so that mutating the deadline from a gesture
/// closure doesn't invalidate the SwiftUI body. Both drivers — the list-
/// row drag-vs-tap discriminator and the detail overlay back-drag
/// suppressor for embedded image / video taps — live inside
/// `ContentView.panGesture`.
///
/// Stored as an absolute deadline (`suppressedUntil`) instead of a flat
/// `Bool` so a missed reset (drag interrupted by a system alert / app
/// backgrounding mid-gesture / SwiftUI gesture cancellation that doesn't
/// fire `.onEnded`) can't strand the gate `true` and silently kill all
/// future taps. The 250ms TTL covers the longest plausible gap between
/// the last `onChanged` tick and the SwiftUI tap closure firing on the
/// same touch-up — so nothing has to schedule an explicit unblock.
final class TapSuppressionGate {
    var suppressedUntil: Date = .distantPast
    var suppressed: Bool { Date() < suppressedUntil }

    func suppress(for duration: TimeInterval = 0.25) {
        suppressedUntil = Date().addingTimeInterval(duration)
    }
}

/// Mirrors `TapSuppressionGate`'s "shared mutable flag" pattern but for
/// the inverse case — children (e.g. `SelectableRichText`'s wrapped
/// `UITextView`) reporting *up* to `ContentView.panGesture` that a
/// selection-handle drag is in progress so the back-swipe pan should
/// stay out of its way.
///
/// Drag-right on a selection handle previously raced
/// `panGesture.onChanged`'s horizontal classifier and pulled the
/// detail overlay off-screen mid-selection. With this gate active,
/// `panGesture` bails before mutating any drag state, leaving the
/// UITextView's handle pan to win unopposed.
///
/// TTL-based: `UITextView.textViewDidChangeSelection` fires every
/// tick while a handle or loupe is being dragged and goes silent the
/// moment the user lifts their finger. Storing the timestamp of the
/// most recent fire and reading `isActive` as "less than 180ms ago"
/// gives:
///   * Active drag → gate continuously `true` (next tick refreshes it
///     before TTL elapses)
///   * Settled selection (text still highlighted, user idle) → gate
///     decays to `false`, so back-swipe works as soon as the user
///     stops moving their finger — they don't have to tap-away first
///   * Programmatic `attributedText` writes from `updateUIView` also
///     fire `textViewDidChangeSelection`, but the delegate's
///     `NSEqualRanges` filter rejects them because the range stays
///     identical to the previous report — so SwiftUI re-evals don't
///     phantom-activate the gate.
final class TextSelectionGate {
    var lastChangeAt: Date = .distantPast
    static let ttl: TimeInterval = 0.18

    var isActive: Bool {
        Date().timeIntervalSince(lastChangeAt) < Self.ttl
    }

    func touch() {
        lastChangeAt = Date()
    }
}

private struct BottomAreaTopKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

#Preview {
    ContentView()
}
