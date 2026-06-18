import SwiftUI
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
    @State private var detail = DetailOverlayController.shared
    /// Bot-check sheet presenter. Driven by `Networking.fetchHTML` calling
    /// `BotCheckCoordinator.shared.challenge(url:)` when a site returns a
    /// CAPTCHA interstitial; the sheet hosts a WKWebView so the user can
    /// solve it interactively and the cookies it issues flow back into
    /// `HTTPCookieStorage.shared` for the retry.
    @State private var botCheck = BotCheckCoordinator.shared
    /// Owns the entire pan-gesture machine: drawer open/close, detail
    /// back-swipe dismiss, forward-swipe reveal, plus bottom-bar /
    /// selection-handle / scrub-strip exclusions. ContentView reads
    /// `coord.drawerOpen` / `coord.drawerProgress` / `coord.scrollLocked`
    /// to drive layout but never mutates the gesture state directly —
    /// `coord.closeDrawer()` and `coord.dismissDetailOverlay()` are the
    /// only outside entry points.
    @State private var coord = GestureCoordinator()

    @State private var drawerSection: DrawerSection = .favorites
    @State private var searchSheetPresented = false
    @State private var keywordListPresented = false
    @State private var alertBadge = AlertBadge.shared

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
                .opacity(0.3 * coord.drawerProgress)
                .ignoresSafeArea()
                .allowsHitTesting(coord.drawerOpen)
                .onTapGesture { coord.closeDrawer() }

            SideDrawer(
                favorites: favorites,
                catalog: catalog,
                currentBoardID: selection.board.id,
                selectedSection: $drawerSection,
                onSelectBoard: { board in
                    selection.select(board, navScope: drawerSection)
                    coord.closeDrawer()
                },
                onClose: coord.closeDrawer
            )
            // SideDrawer 의 custom `==` 와 한 쌍 — 드래그 매 프레임 재평가가
            // closure 필드 때문에 드로어 body 까지 전파되는 것을 차단.
            // offset 애니메이션은 이 뷰 바깥(.offset)에서 일어나므로 영향 없음.
            .equatable()
            .frame(width: coord.drawerWidth)
            .offset(x: coord.drawerXOffset)

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
                    tapGate: coord.detailMediaTapGate,
                    isOverlayVisible: detail.isOverlayVisible,
                    // `scrollLocked` is set by the coordinator's horizontal
                    // classification; `detail.animating` extends the lock
                    // across the post-release spring so the inner scroll
                    // position can't drift while the overlay slides in/out.
                    isScrollingBlocked: coord.scrollLocked || detail.animating,
                    onDismiss: { coord.dismissDetailOverlay() }
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
        .onPreferenceChange(ContainerHeightKey.self) { coord.containerHeight = $0 }
        .onPreferenceChange(ContainerWidthKey.self) { newWidth in
            detail.updateContainerWidth(newWidth)
        }
        .onPreferenceChange(BottomAreaTopKey.self) { coord.bottomAreaTopY = $0 }
        .simultaneousGesture(coord.panGesture)
        // Bot-check interactive recovery. `pending` is `private(set)` on
        // the coordinator (only its `resolve()` clears it), so we drive
        // the sheet through a custom binding that funnels SwiftUI's
        // dismiss-to-nil writes back through `resolve()`. That keeps
        // the awaiting `Networking.fetchHTML` task wake-up centralized
        // in one place even when the sheet dismisses via the system
        // (drag-down) rather than the toolbar Close button.
        .sheet(item: Binding(
            get: { botCheck.pending },
            set: { newValue in
                if newValue == nil { botCheck.resolve() }
            }
        )) { challenge in
            BotCheckSheet(url: challenge.url) {
                botCheck.resolve()
            }
        }
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
            await alertBadge.refresh()
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
                // background 동안 도착했을 수 있는 알림 반영.
                Task { await alertBadge.refresh() }
                FootprintLogger.shared.record("scenePhase:active")
            } else if phase == .background {
                // 백그라운드 진입 시 in-memory 캐시 해제. 지금까진 메모리 경고
                // 때만 비웠는데, 백그라운드 전환엔 안 비워 ~1GB 쥔 채 suspend →
                // jetsam 이 "제일 큰 백그라운드 앱"인 우리를 먼저 kill 했다(확인된
                // JetsamEvent 2건). 백그라운드에도 같은 flush 를 적용해 막는다.
                MemoryPressureResponder.shared.respond()
                // Phase-3: 세션 detail 캐시(최대 20글 파싱본)도 해제 — keep-alive
                // 로 열려있는 현재 글은 loader 가 쥐고 있어 안전. 본문 이미지
                // 디코드는 NetworkImage 가 scenePhase=.background 를 보고 스스로 떨군다.
                detailCache.clear()
                FootprintLogger.shared.onBackground()
            }
        }
        // 메모리 footprint 계측 — 보드 전환/글 열기 순간을 타임라인에 태깅해,
        // 어느 동작에서 메모리가 치솟거나 안 풀리는지 서버 admin 뷰에서 본다.
        .onChange(of: selection.board) { _, board in
            FootprintLogger.shared.record("board:\(board.name)")
        }
        .onChange(of: detail.activePost?.id) { _, id in
            if id != nil { FootprintLogger.shared.record("post-open") }
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
            scrollLocked: coord.scrollLocked,
            shouldSuppressRowTap: { [gate = coord.rowTapGate] in gate.suppressed },
            readStore: readStore,
            onSelectPost: { post in
                detail.show(post)
            }
        )
        // BoardListView 의 custom `==` 와 한 쌍 — 백 드래그 중 뒤에 보이는
        // 목록(수백 행 ForEach diff)이 매 프레임 재평가되는 것을 차단.
        .equatable()
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
                    onNext: { stepBoard(by: 1) },
                    unreadCount: alertBadge.unread,
                    onAlerts: { keywordListPresented = true }
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
        .sheet(isPresented: $keywordListPresented, onDismiss: {
            // 시트에서 알림을 열어 읽었을 수 있으니 닫힐 때 뱃지 최신화.
            Task { await alertBadge.refresh() }
        }) {
            NavigationStack {
                KeywordListView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("닫기") { keywordListPresented = false }
                        }
                    }
            }
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

private struct BottomAreaTopKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

#Preview {
    ContentView()
}
