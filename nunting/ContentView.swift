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
    @State private var selectedBoard: Board
    @State private var selectedFilter: BoardFilter? = nil
    @State private var searchQuery: String? = nil
    @State private var drawerOpen = false
    @State private var drawerSection: DrawerSection = .favorites
    /// Which list the bottom-bar swipe should cycle through (favorites vs.
    /// a specific site's catalog). Updated whenever the user taps a board
    /// in the drawer.
    @State private var boardNavScope: DrawerSection = .favorites
    @State private var searchSheetPresented = false
    /// Most recently opened post. Kept alive as a ZStack overlay so the
    /// rendered view, scroll position, image state, and video playback all
    /// survive back-swipes. A right-edge leftward drag re-slides the same
    /// view back in; tapping a different post rebuilds the overlay via
    /// `.id(post.id)` (old view destroyed, data still hot in `detailCache`).
    @State private var activePost: Post?
    /// 0 = overlay fully shown; `containerWidth` = fully hidden off the right
    /// edge. Animated by `showDetail`/`hideDetail` on tap/back, dragged
    /// directly in the pan handler during interactive swipes.
    @State private var detailOffset: CGFloat = 0
    /// `detailOffset` at the moment the horizontal drag lock engages. Used
    /// to classify the drag as back-swipe (base 0) vs forward-reveal (base
    /// containerWidth) regardless of how far the finger has travelled.
    @State private var detailOffsetBase: CGFloat = 0
    /// Bumped on bottom-bar double-tap. Attached to `mainScreen` via `.id()`
    /// so the whole list + filter bar + bottom bar subtree is rebuilt,
    /// triggering a fresh load regardless of current search/filter state.
    @State private var reloadToken: Int = 0

    @State private var dragOffset: CGFloat = 0
    @State private var dragDirection: DragDirection?
    @State private var dragLockBaseline: CGFloat = 0
    @State private var scrollLocked = false
    @State private var containerHeight: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
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
    /// Same shape as `rowTapGate` but driven by the detail overlay's UIKit
    /// back-swipe recognizer. Read by image / video tap handlers inside
    /// `PostDetailView` so a `→` back-swipe doesn't accidentally tap an
    /// image or video sitting under the user's finger when they release.
    @State private var detailMediaTapGate = TapSuppressionGate()

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
            _selectedBoard = State(initialValue: firstFav)
            _selectedFilter = State(initialValue: Self.defaultFilter(for: firstFav))
            _boardNavScope = State(initialValue: .favorites)
        } else {
            _selectedBoard = State(initialValue: .clienNews)
            _selectedFilter = State(initialValue: Self.defaultFilter(for: .clienNews))
            _boardNavScope = State(initialValue: .site(.clien))
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            mainScreen
                .id(reloadToken)

            Color.black
                .opacity(0.3 * drawerProgress)
                .ignoresSafeArea()
                .allowsHitTesting(drawerOpen)
                .onTapGesture { closeDrawer() }

            SideDrawer(
                favorites: favorites,
                catalog: catalog,
                currentBoardID: selectedBoard.id,
                selectedSection: $drawerSection,
                onSelectBoard: { board in
                    selectedBoard = board
                    boardNavScope = drawerSection
                    closeDrawer()
                },
                onClose: closeDrawer
            )
            .frame(width: drawerWidth)
            .offset(x: drawerXOffset)

            // Keep-alive detail overlay. Once set, `activePost` stays
            // non-nil so the rendered PostDetailView survives back-swipes
            // (scroll state, image decode, video playback all preserved).
            // `.id(post.id)` forces a rebuild only when a different post is
            // opened, which is the sole case where we intentionally trade
            // keep-alive for a fresh view.
            if let post = activePost {
                // Wrap the detail view in a UIHostingController whose root
                // UIView carries a UIPanGestureRecognizer. SwiftUI's
                // `.simultaneousGesture` alone doesn't fire reliably here
                // because UIScrollView tends to claim the touch first. The
                // UIKit recognizer stays simultaneous with the scroll pan,
                // but only begins for clearly rightward horizontal drags.
                // During the drag it moves a UIKit snapshot, avoiding
                // per-frame SwiftUI state writes that can make long
                // LazyVStack details blank or jump.
                SwipeToDismissOverlay(
                    onChange: { dx in
                        detailOffset = max(0, min(containerWidth, dx))
                    },
                    shouldDismiss: { dx, velocityX in
                        shouldDismissDetailSwipe(dx: dx, velocityX: velocityX)
                    },
                    onEnd: { dx, velocityX in
                        let shouldDismiss = shouldDismissDetailSwipe(dx: dx, velocityX: velocityX)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            detailOffset = shouldDismiss ? containerWidth : 0
                        }
                    },
                    tapGate: detailMediaTapGate
                ) {
                    PostDetailView(
                        post: post,
                        readStore: readStore,
                        cache: detailCache,
                        tapGate: detailMediaTapGate,
                        // `containerWidth > 0` guards against the pre-
                        // first-measurement window where detailOffset
                        // defaults to 0 but the overlay is effectively
                        // hidden (nothing rendered yet).
                        isOverlayVisible: containerWidth > 0 && detailOffset < containerWidth - 0.5,
                        onDismiss: { hideDetail() }
                    )
                }
                .id(post.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Extend the hosted container edge-to-edge so the
                // UIHostingController's view covers the status-bar /
                // notch band. Without this the ZStack clips the overlay
                // to the ContentView's safe area and the list underneath
                // shows through the top of the detail. The PostDetailView
                // root inside still respects safe area for its header, so
                // the chevron still lands below the status bar.
                .ignoresSafeArea()
                .offset(x: detailOffset)
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
            // If the overlay was hidden at the previous width, keep it fully
            // hidden at the new width — otherwise a rotation / window resize
            // could leave a sliver of it visible on the right edge.
            let wasHidden = detailOffset >= containerWidth - 0.5 && containerWidth > 0
            containerWidth = newWidth
            if wasHidden { detailOffset = newWidth }
        }
        .coordinateSpace(name: "contentRoot")
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
            if phase == .active {
                Networking.prewarmConnections()
                ImageWarmup.warm()
            }
        }
    }

    private var mainScreen: some View {
        VStack(spacing: 0) {
            BoardListView(
                board: selectedBoard,
                filter: selectedFilter,
                searchQuery: searchQuery,
                scrollLocked: scrollLocked,
                shouldSuppressRowTap: { [rowTapGate] in rowTapGate.suppressed },
                readStore: readStore,
                onSelectPost: { post in
                    showDetail(post)
                }
            )
            VStack(spacing: 0) {
                if !selectedBoard.filters.isEmpty {
                    BoardFilterBar(board: selectedBoard, selection: $selectedFilter)
                }
                MainBottomBar(
                    board: selectedBoard,
                    favorites: favorites,
                    onBoardTap: { openDrawer(targetSection: boardNavScope) },
                    onBoardDoubleTap: {
                        searchQuery = nil
                        reloadToken &+= 1
                    },
                    onSearch: { searchSheetPresented = true },
                    onPrev: { stepBoard(by: -1) },
                    onNext: { stepBoard(by: 1) }
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BottomAreaTopKey.self,
                        value: proxy.frame(in: .named("contentRoot")).minY
                    )
                }
            )
        }
        .onChange(of: selectedBoard) { _, _ in
            selectedFilter = Self.defaultFilter(for: selectedBoard)
            searchQuery = nil
        }
        .onChange(of: selectedFilter) { _, _ in
            // Filter switches can swap the path entirely (BoardFilter.replacementPath),
            // so the prior search query may not be meaningful on the new endpoint.
            searchQuery = nil
        }
        .sheet(isPresented: $searchSheetPresented) {
            SearchSheet(
                board: selectedBoard,
                initialQuery: searchQuery ?? "",
                onSubmit: { q in searchQuery = q },
                onClear: { searchQuery = nil }
            )
        }
    }

    private static func defaultFilter(for board: Board) -> BoardFilter? {
        guard board.id == Board.invenMaple.id else { return nil }
        return board.filters.first { $0.id == "chu" }
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
        guard activePost != nil else { return dragOffset }
        // Overlay exists. Detail back-swipe (base 0) and forward-reveal
        // (dragging left) both own the drag; only a rightward drag started
        // while the overlay is hidden still belongs to the drawer.
        if detailOffsetBase == 0 { return 0 }
        return dragOffset > 0 ? dragOffset : 0
    }

    private var drawerXOffset: CGFloat {
        -drawerWidth + drawerWidth * drawerProgress
    }

    private func showDetail(_ post: Post) {
        // Re-revealing the already-active post: keep-alive path. Just slide
        // the existing overlay (which still holds its scroll/image state)
        // back into view. `.id(post.id)` unchanged, so SwiftUI reuses the
        // same PostDetailView instance and `.task(id:)` doesn't re-fire.
        if activePost?.id == post.id {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                detailOffset = 0
            }
            return
        }
        // Different or first post: park the overlay offscreen right, swap
        // `activePost` (forcing the view to rebuild), then animate in on
        // the next runloop so SwiftUI actually observes the offscreen
        // starting position. Coalescing all three into one transaction
        // collapses the animation and the overlay pops in.
        detailOffset = containerWidth > 0 ? containerWidth : 1000
        activePost = post
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                detailOffset = 0
            }
        }
    }

    private func hideDetail() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            detailOffset = containerWidth
        }
        // Intentionally leaves `activePost` non-nil so the view survives and
        // the next right-edge forward-swipe can restore it instantly.
    }

    private func shouldDismissDetailSwipe(dx: CGFloat, velocityX: CGFloat) -> Bool {
        dx > detailSwipeDistanceThreshold || velocityX > 320
    }

    private var detailSwipeDistanceThreshold: CGFloat {
        min(containerWidth * 0.12, 48)
    }


    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
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
                        detailOffsetBase = detailOffset
                    } else if absH > 10 && absH > absW {
                        dragDirection = .vertical
                    }
                }
                if dragDirection == .horizontal {
                    dragOffset = value.translation.width - dragLockBaseline
                    // Forward-swipe reveal: overlay hidden at drag start and
                    // finger moving leftward pulls it in. If the finger
                    // reverses back rightward past the start, snap the
                    // overlay fully hidden again — otherwise a subsequent
                    // drawer-open commit would leave `detailOffset` parked
                    // at a partial reveal, and the next left-swipe would
                    // lock with `detailOffsetBase < containerWidth` and
                    // never re-enter forward-reveal mode. Back-swipe is
                    // owned by the overlay's UIKit recognizer.
                    if activePost != nil && detailOffsetBase >= containerWidth {
                        if dragOffset < 0 {
                            detailOffset = max(0, min(containerWidth, containerWidth + dragOffset))
                        } else {
                            detailOffset = containerWidth
                        }
                    }
                }
            }
            .onEnded { value in
                // No explicit gate reset — `TapSuppressionGate` uses a
                // TTL deadline that lapses on its own (see the class
                // doccomment for why this matters when `.onEnded` is
                // skipped entirely).
                if startedInBottomBar(value) {
                    resetDragState()
                    return
                }
                let lockedHorizontal = dragDirection == .horizontal
                let baseline = dragLockBaseline
                let base = detailOffsetBase
                let hasActive = activePost != nil
                resetDragState()

                guard lockedHorizontal else {
                    dragOffset = 0
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let traveled = value.translation.width - baseline

                // Detail overlay modes take precedence — the drag already
                // moved `detailOffset` interactively, so committing the
                // correct end state here preserves continuity with the
                // finger's position.
                if hasActive && base == 0 {
                    // Overlay visible: back-swipe is owned by the edge
                    // strip, and this gesture fired either on a stray
                    // horizontal drag that the ScrollView didn't consume
                    // or from a simultaneous dispatch. Do nothing so we
                    // don't double-commit an animation the edge gesture
                    // already handled.
                    dragOffset = 0
                    return
                }
                if hasActive && base >= containerWidth && traveled < 0 {
                    // Forward-swipe reveal: low threshold matches the old
                    // lastOpenedPost re-push so a light flick from the right
                    // edge is enough to pull the overlay back in.
                    let shouldReveal = traveled < -50 || velocity < -180
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        detailOffset = shouldReveal ? 0 : containerWidth
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
                    if hasActive && base >= containerWidth && detailOffset != containerWidth {
                        detailOffset = containerWidth
                    }
                }
            }
    }

    private func resetDragState() {
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
    }

    private func openDrawer(targetSection: DrawerSection) {
        drawerSection = targetSection
        resetDragState()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            drawerOpen = true
            dragOffset = 0
        }
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
        switch boardNavScope {
        case .favorites:
            pool = favorites.favoriteBoards()
        case .site(let s):
            pool = catalog.boards(for: s)
        }
        guard pool.count > 1,
              let idx = pool.firstIndex(where: { $0.id == selectedBoard.id })
        else { return }
        let next = ((idx + delta) % pool.count + pool.count) % pool.count
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedBoard = pool[next]
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
/// closure doesn't invalidate the SwiftUI body. Used in two places:
/// the list-row drag-vs-tap discriminator (driven by `panGesture`),
/// and the detail overlay back-swipe suppressor for embedded image /
/// video taps (driven by `SwipeToDismissOverlay.Coordinator`).
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

private struct BottomAreaTopKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

#Preview {
    ContentView()
}

/// Hosts the detail overlay inside a UIHostingController and attaches a
/// UIKit pan recognizer that coexists with the embedded
/// UIScrollView's own pan. We deliberately avoid `require(toFail:)`:
/// pinning the ScrollView pan in `.possible` caused long lazy-rendered
/// detail pages to jump or temporarily blank near the comments tail. Once
/// a rightward horizontal pan begins, we preserve the embedded
/// ScrollView's offset, stop that same scroll view's pan from recognizing
/// simultaneously, and move a UIKit snapshot instead of the live SwiftUI
/// tree. That keeps the page visually attached to the finger without
/// invalidating a long LazyVStack on every drag frame or letting a slightly
/// diagonal back-swipe scroll the detail underneath.
struct SwipeToDismissOverlay<Content: View>: UIViewControllerRepresentable {
    let onChange: (CGFloat) -> Void
    let shouldDismiss: (CGFloat, CGFloat) -> Bool
    /// Called with (final translation.x, velocity.x in pts/sec) on the
    /// recognizer's terminal state. Parent decides whether to commit the
    /// dismiss based on distance + velocity.
    let onEnd: (CGFloat, CGFloat) -> Void
    /// Flipped to `true` while the recognizer is actively tracking a
    /// back-swipe so embedded image / video tap handlers can suppress
    /// their action when the user releases their finger over media.
    var tapGate: TapSuppressionGate? = nil
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Host<Content> {
        let host = Host(rootView: content())
        host.view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        pan.delegate = context.coordinator
        // Taps on buttons/links inside the detail view must still reach
        // their SwiftUI handlers, so don't swallow touches while the pan
        // is merely "possible".
        pan.cancelsTouchesInView = false
        host.view.addGestureRecognizer(pan)
        return host
    }

    func updateUIViewController(_ host: Host<Content>, context: Context) {
        host.rootView = content()
        context.coordinator.onChange = onChange
        context.coordinator.shouldDismiss = shouldDismiss
        context.coordinator.onEnd = onEnd
        context.coordinator.tapGate = tapGate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: onChange,
            shouldDismiss: shouldDismiss,
            onEnd: onEnd,
            tapGate: tapGate
        )
    }

    /// Accept the parent's size proposal verbatim so the representable
    /// fills the overlay slot in the ContentView ZStack instead of
    /// collapsing to the hosted SwiftUI view's ideal size (which left the
    /// detail vertically centred and leaked the list through the top/bottom
    /// bands). `replacingUnspecifiedDimensions()` resolves nil dimensions
    /// to SwiftUI's documented fallback (10×10) rather than
    /// `UIView.noIntrinsicMetric` — the latter is -1 and trips layout math
    /// that assumes a non-negative extent.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: Host<Content>,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Host<V: View>: UIHostingController<V> {
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void
        var shouldDismiss: (CGFloat, CGFloat) -> Bool
        var onEnd: (CGFloat, CGFloat) -> Void
        var tapGate: TapSuppressionGate?
        weak var lockedScrollView: UIScrollView?
        var lockedContentOffset: CGPoint?
        var lockedDistanceToBottom: CGFloat?
        var lockedScrollWasEnabled: Bool?
        /// Captured at touch-down (`shouldReceive`) before the embedded
        /// ScrollView has had a chance to nudge its `contentOffset` in
        /// response to the touch's vertical component. `lockScroll` reads
        /// from here so a tiny `→` drag's restore lands on the offset the
        /// user was actually at, not the few-pt-drifted offset present
        /// when `shouldBegin` finally fires.
        weak var earliestScrollView: UIScrollView?
        var earliestOffset: CGPoint?
        weak var snapshotContainer: UIView?
        var dragSnapshot: UIView?
        var liveViewAlphaBeforeSnapshot: CGFloat = 1

        init(
            onChange: @escaping (CGFloat) -> Void,
            shouldDismiss: @escaping (CGFloat, CGFloat) -> Bool,
            onEnd: @escaping (CGFloat, CGFloat) -> Void,
            tapGate: TapSuppressionGate? = nil
        ) {
            self.onChange = onChange
            self.shouldDismiss = shouldDismiss
            self.onEnd = onEnd
            self.tapGate = tapGate
        }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // Snapshot scroll position at touch-down — before the embedded
            // ScrollView has had any chance to move in response to an
            // initial vertical nudge. `lockScroll` consults this so a
            // tiny `→` drag's restore lands on where the user actually
            // was, not a drifted offset.
            //
            // Scope the write to *our* back-swipe recognizer only. Today
            // the coordinator is delegate for a single pan, but the guard
            // defends against a future refactor attaching the same
            // coordinator to another recognizer (e.g. a tap-gate) and
            // accidentally capturing an unrelated touch's baseline.
            // Also note: a capture here from one scroll view can leak
            // across a navigation / sheet dismiss into the next
            // presentation — that's why `lockScroll` re-checks with
            // `earliestScrollView === scrollView` before trusting the
            // snapshot, and falls back to the live `contentOffset` if
            // they differ.
            if let pan = g as? UIPanGestureRecognizer,
               let view = pan.view,
               pan.delegate === self,
               let scrollView = Self.findScrollView(in: view) {
                earliestScrollView = scrollView
                earliestOffset = scrollView.contentOffset
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer,
                  let view = pan.view
            else { return true }
            let v = pan.velocity(in: view)
            let shouldBegin = v.x > 0 && abs(v.x) >= abs(v.y)
            if shouldBegin, let scrollView = Self.findScrollView(in: view) {
                lockScroll(scrollView)
            }
            return shouldBegin
        }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Once the back-swipe has claimed a rightward horizontal drag,
            // don't let the detail ScrollView's vertical pan also consume a
            // small diagonal component. Other recognizers stay simultaneous
            // so controls nested inside the detail view remain responsive.
            if let scrollView = lockedScrollView,
               other === scrollView.panGestureRecognizer {
                return false
            }
            return true
        }

        @objc func handle(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let t = pan.translation(in: view)
            let v = pan.velocity(in: view)
            switch pan.state {
            case .began:
                // Pan recognized → block child taps for the rest of this
                // touch sequence. `cancelsTouchesInView = false` lets the
                // touch keep flowing to SwiftUI handlers, so we need this
                // explicit gate to stop image / video taps from firing on
                // touch-up just because the user happened to release over
                // a media block. Re-suppress on every `.changed` so the
                // 250ms TTL keeps refreshing while the drag is live.
                tapGate?.suppress()
                // Zero out so subsequent `.changed` translations are
                // measured from the claim point — otherwise the overlay
                // would jump by the 8pt classifier threshold the moment
                // the swipe is recognised.
                pan.setTranslation(.zero, in: view)
                if lockedScrollView == nil, let scrollView = Self.findScrollView(in: view) {
                    lockScroll(scrollView)
                }
                freezeScrollOffset()
                beginSnapshot(for: view)
            case .changed:
                tapGate?.suppress()
                freezeScrollOffset()
                updateSnapshot(dx: max(0, t.x))
            case .ended, .cancelled:
                freezeScrollOffset()
                let dx = max(0, t.x)
                let commitsDismiss = shouldDismiss(dx, v.x)
                finishSnapshot(for: view, dx: dx, commitsDismiss: commitsDismiss)
                restoreScroll()
                if commitsDismiss {
                    onEnd(dx, v.x)
                } else {
                    onEnd(0, 0)
                }
                // No explicit unblock — the gate's TTL deadline (set in
                // `.began` / `.changed`) lapses on its own, which also
                // covers the missed-terminal-state edge case.
            case .failed:
                cancelSnapshot(for: view)
                restoreScroll()
            default:
                break
            }
        }

        private func lockScroll(_ scrollView: UIScrollView) {
            guard lockedScrollView == nil else { return }
            lockedScrollView = scrollView
            // Prefer the touch-down snapshot if we have one for the same
            // scroll view — that's the position the user perceives as
            // "where I was", before any vertical jitter nudged it.
            let baseline: CGPoint
            if let earliestOffset, earliestScrollView === scrollView {
                baseline = earliestOffset
            } else {
                baseline = scrollView.contentOffset
            }
            lockedContentOffset = baseline
            lockedDistanceToBottom = Self.distanceToBottom(in: scrollView)
            lockedScrollWasEnabled = scrollView.isScrollEnabled
            // While the snapshot is visible, the live SwiftUI ScrollView sits
            // hidden behind it. If that live scroll view keeps accepting the
            // same touch's small vertical component, it can drift underneath
            // the snapshot and then appear to jump when the snapshot is
            // removed. Disable scrolling for the duration of the back-swipe
            // and restore it after the final offset is written.
            //
            // `isScrollEnabled = false` also serves the role the prior
            // `panGestureRecognizer.isEnabled = false; panGestureRecognizer
            // .isEnabled = true` toggle used to play — it cancels any
            // in-flight pan recognition on the inner ScrollView so a
            // `.changed` or deceleration step can't fire after we snap
            // back to `baseline`. `gestureRecognizer(_:shouldRecognize
            // SimultaneouslyWith:)` returning `false` only blocks *future*
            // simultaneous arbitration; it doesn't interrupt a recognizer
            // that's already mid-recognition, which happens whenever the
            // initial touch had a small vertical component.
            scrollView.isScrollEnabled = false
            if scrollView.contentOffset != baseline {
                scrollView.setContentOffset(baseline, animated: false)
            }
        }

        private func beginSnapshot(for view: UIView) {
            guard dragSnapshot == nil,
                  let container = view.superview,
                  let snapshot = view.snapshotView(afterScreenUpdates: false)
            else { return }
            snapshot.frame = view.frame
            snapshot.isUserInteractionEnabled = false
            container.addSubview(snapshot)
            snapshotContainer = container
            dragSnapshot = snapshot
            liveViewAlphaBeforeSnapshot = view.alpha
            view.alpha = 0
        }

        private func updateSnapshot(dx: CGFloat) {
            dragSnapshot?.transform = CGAffineTransform(translationX: dx, y: 0)
        }

        private func finishSnapshot(for view: UIView, dx: CGFloat, commitsDismiss: Bool) {
            onChange(commitsDismiss ? dx : 0)
            view.alpha = liveViewAlphaBeforeSnapshot
            dragSnapshot?.removeFromSuperview()
            dragSnapshot = nil
            snapshotContainer = nil
            liveViewAlphaBeforeSnapshot = 1
        }

        private func cancelSnapshot(for view: UIView) {
            view.alpha = liveViewAlphaBeforeSnapshot
            dragSnapshot?.removeFromSuperview()
            dragSnapshot = nil
            snapshotContainer = nil
            liveViewAlphaBeforeSnapshot = 1
        }

        private func freezeScrollOffset() {
            guard let scrollView = lockedScrollView,
                  let lockedOffset = lockedContentOffset
            else { return }
            let offset = resolvedLockedOffset(in: scrollView, fallback: lockedOffset)
            guard scrollView.contentOffset != offset else { return }
            scrollView.setContentOffset(offset, animated: false)
        }

        private func resolvedLockedOffset(in scrollView: UIScrollView, fallback: CGPoint) -> CGPoint {
            guard let distanceToBottom = lockedDistanceToBottom else { return fallback }
            let minY = -scrollView.adjustedContentInset.top
            let maxY = Self.maxOffsetY(in: scrollView)
            let targetY: CGFloat
            if distanceToBottom <= 2 {
                targetY = maxY
            } else {
                targetY = max(minY, min(maxY, fallback.y))
            }
            return CGPoint(x: fallback.x, y: targetY)
        }

        private func restoreScroll() {
            guard let scrollView = lockedScrollView,
                  let targetOffset = lockedContentOffset
            else {
                clearScrollLock()
                return
            }

            // Finish the restore while the coordinator still owns the scroll
            // lock. Deferring this to the next runloop left a narrow window
            // where the cancelled inner ScrollView pan could process its
            // terminal state after we had cleared `lockedScrollView`, which
            // showed up as a small but visible jump when a back-swipe began
            // over a tappable comment image.
            //
            // `resolvedLockedOffset` already encapsulates the
            // `distanceToBottom <= 2 → maxY` behaviour, so no separate
            // branch is needed here.
            let resolvedTarget = resolvedLockedOffset(in: scrollView, fallback: targetOffset)
            if scrollView.contentOffset != resolvedTarget {
                scrollView.setContentOffset(resolvedTarget, animated: false)
            }
            clearScrollLock()
        }

        private func clearScrollLock() {
            if let scrollView = lockedScrollView,
               let lockedScrollWasEnabled {
                scrollView.isScrollEnabled = lockedScrollWasEnabled
            }
            lockedScrollView = nil
            lockedContentOffset = nil
            lockedDistanceToBottom = nil
            lockedScrollWasEnabled = nil
            // Drop the touch-down snapshot so the next touch re-samples
            // rather than reusing a stale baseline.
            earliestScrollView = nil
            earliestOffset = nil
        }

        private static func distanceToBottom(in scrollView: UIScrollView) -> CGFloat {
            maxOffsetY(in: scrollView) - scrollView.contentOffset.y
        }

        private static func maxOffsetY(in scrollView: UIScrollView) -> CGFloat {
            max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            )
        }

        private static func findScrollView(in v: UIView) -> UIScrollView? {
            if let sv = v as? UIScrollView { return sv }
            for sub in v.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }
    }
}
