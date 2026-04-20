import SwiftUI

struct ContentView: View {
    @State private var favorites: FavoritesStore
    @State private var catalog = BoardCatalogStore()
    @State private var readStore = ReadStore()
    /// Session cache so re-entering a post (fresh tap, or forward-swipe
    /// re-push of `lastOpenedPost`) skips the network + parse.
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
    @State private var navigationPath = NavigationPath()
    @State private var searchSheetPresented = false
    /// Most recently opened post — re-pushed when the user swipes from the
    /// right edge toward the left, mirroring iOS's left-edge back-swipe.
    @State private var lastOpenedPost: Post?
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
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .leading) {
                mainScreen
                    .id(reloadToken)
                    .toolbar(.hidden, for: .navigationBar)

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

                // Right-edge forward-swipe preview: a lightweight detail-page
                // header that slides in from the right tracking the finger
                // while the gesture is active and eligible. On commit it's
                // dropped synchronously and the NavigationStack's push
                // animation takes over (the real PostDetailView then reads
                // PostDetailCache for instant restore).
                if forwardPreviewActive, let preview = lastOpenedPost {
                    forwardPreviewCard(for: preview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(x: containerWidth + forwardPeekOffset)
                        .allowsHitTesting(false)
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
            .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
            .simultaneousGesture(panGesture)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post, readStore: readStore, cache: detailCache)
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
                readStore: readStore,
                onSelectPost: { post in
                    lastOpenedPost = post
                    navigationPath.append(post)
                }
            )
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
        let target = base + dragOffset
        return max(0, min(1, target / drawerWidth))
    }

    private var drawerXOffset: CGFloat {
        -drawerWidth + drawerWidth * drawerProgress
    }

    /// How far the forward-swipe preview card has been pulled in from the
    /// right edge. Negative values mean the card has advanced leftward; 0
    /// pins it fully offscreen right. Clamped so the card can't overshoot
    /// the container width while the finger keeps moving.
    private var forwardPeekOffset: CGFloat {
        guard forwardPreviewActive else { return 0 }
        let maxPeek = max(containerWidth * 0.85, 200)
        return max(dragOffset, -maxPeek)
    }

    /// Gesture is eligible to re-push the last viewed post and the finger
    /// is currently pulling leftward — show the preview card.
    private var forwardPreviewActive: Bool {
        !drawerOpen
            && dragOffset < 0
            && navigationPath.isEmpty
            && lastOpenedPost != nil
    }

    /// Lightweight stand-in for the incoming detail page. Not a real
    /// `PostDetailView` so we avoid duplicating its `.task` side effects
    /// (markRead, cache read/write) or fighting its `.toolbar` setup
    /// outside a navigation destination. Renders just enough chrome —
    /// hidden-back chevron, site title, post header — that the card reads
    /// as "the detail view arriving" while the user drags.
    @ViewBuilder
    private func forwardPreviewCard(for post: Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(post.site.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color("AppSurface"))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(post.title)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Text(post.author)
                    Text(post.dateText)
                    if post.commentCount > 0 {
                        Text("💬 \(post.commentCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            Spacer(minLength: 0)
        }
        .background(Color("AppSurface"))
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                // Don't fight the bottom-bar swipe (board step) when the drag
                // started inside the bar's hit area.
                if startedInBottomBar(value) { return }
                if dragDirection == nil {
                    let absW = abs(value.translation.width)
                    let absH = abs(value.translation.height)
                    if absW > 10 && absW >= absH {
                        dragDirection = .horizontal
                        dragLockBaseline = value.translation.width
                        scrollLocked = true
                    } else if absH > 10 && absH > absW {
                        dragDirection = .vertical
                    }
                }
                if dragDirection == .horizontal {
                    dragOffset = value.translation.width - dragLockBaseline
                }
            }
            .onEnded { value in
                if startedInBottomBar(value) {
                    dragDirection = nil
                    dragLockBaseline = 0
                    scrollLocked = false
                    dragOffset = 0
                    return
                }
                let lockedHorizontal = dragDirection == .horizontal
                let baseline = dragLockBaseline
                dragDirection = nil
                dragLockBaseline = 0
                scrollLocked = false

                guard lockedHorizontal else {
                    dragOffset = 0
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let traveled = value.translation.width - baseline

                let shouldOpen: Bool
                if drawerOpen {
                    shouldOpen = !(traveled < -drawerWidth / 3 || velocity < -150)
                } else {
                    // Leftward swipe with no drawer open → re-push the last
                    // opened post (right-edge "forward" gesture). Threshold
                    // mirrors the drawer-open gesture's sensitivity so both
                    // directions feel equally responsive; `forwardPeekOffset`
                    // provides the interactive follow-through during drag.
                    if (traveled < -50 || velocity < -180),
                       navigationPath.isEmpty,
                       let last = lastOpenedPost {
                        navigationPath.append(last)
                        dragOffset = 0
                        return
                    }
                    // Smaller distance + lower fling velocity → opens with a
                    // quick flick instead of needing to drag a third of the
                    // screen across.
                    shouldOpen = (traveled > 50 || velocity > 90)
                }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    drawerOpen = shouldOpen
                    dragOffset = 0
                }
            }
    }

    private func openDrawer(targetSection: DrawerSection) {
        drawerSection = targetSection
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            drawerOpen = true
            dragOffset = 0
        }
    }

    private func startedInBottomBar(_ value: DragGesture.Value) -> Bool {
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
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
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

#Preview {
    ContentView()
}
