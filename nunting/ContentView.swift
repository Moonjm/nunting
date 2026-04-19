import SwiftUI

struct ContentView: View {
    @State private var favorites: FavoritesStore
    @State private var catalog = BoardCatalogStore()
    @State private var readStore = ReadStore()
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

    @State private var dragOffset: CGFloat = 0
    @State private var dragDirection: DragDirection?
    @State private var dragLockBaseline: CGFloat = 0
    @State private var scrollLocked = false
    @State private var containerHeight: CGFloat = 0

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
            }
            .ignoresSafeArea(.keyboard)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContainerHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ContainerHeightKey.self) { containerHeight = $0 }
            .simultaneousGesture(panGesture)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post, readStore: readStore)
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
                onBoardDoubleTap: { searchQuery = nil },
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
                    // opened post (right-edge "forward" gesture).
                    if (traveled < -120 || velocity < -250),
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

#Preview {
    ContentView()
}
