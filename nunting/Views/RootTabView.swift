import SwiftUI

// 2026/27 재디자인 셸 — Liquid Glass 탭바(모음/둘러보기/알림).
// ContentView(드로어+오버레이+제스처)를 대체한다. 데이터/로더/상세 렌더는
// 기존 서비스·뷰(BoardListView/PostDetailView/BoardFilterBar/KeywordListView)를
// 그대로 재사용하고, 여기선 네비게이션 골격과 보드 전환/필터/검색만 조립한다.
struct RootTabView: View {
    @State private var favorites = FavoritesStore()
    @State private var catalog = BoardCatalogStore()
    @State private var readStore = ReadStore()
    @State private var detailCache = PostDetailCache()
    @State private var alertBadge = AlertBadge.shared

    @State private var selectedTab = 0
    // 모음 탭의 현재 보드/필터 — 하단 필터 액세서리가 읽어야 하므로 여기서 소유.
    @State private var currentBoardID: String?
    @State private var filterByBoard: [String: BoardFilter] = [:]
    // 리더 상세에 들어가 있는 동안 true → 필터 액세서리 숨김.
    @State private var reading = false

    @Environment(\.scenePhase) private var scenePhase

    private var currentBoard: Board? {
        let boards = favorites.favoriteBoards()
        return boards.first { $0.id == currentBoardID } ?? boards.first
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("모음", systemImage: "tray.full.fill", value: 0) {
                ArchiveHome(
                    favorites: favorites,
                    readStore: readStore,
                    cache: detailCache,
                    currentBoardID: $currentBoardID,
                    filterByBoard: $filterByBoard,
                    reading: $reading
                )
            }
            Tab("둘러보기", systemImage: "square.grid.2x2", value: 1) {
                BrowseTab(catalog: catalog, favorites: favorites)
            }
            Tab("알림", systemImage: "bell", value: 2) {
                NavigationStack {
                    KeywordListView()
                        .navigationTitle("알림")
                }
            }
            .badge(alertBadge.unread)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // 보드 내 필터(전체/10추/30추…)는 하단 유리 액세서리(엄지 존)에.
        // 모음 탭이고 읽는 중이 아니며 현재 보드에 필터가 있을 때만.
        .tabViewBottomAccessory {
            if selectedTab == 0, !reading, let board = currentBoard, !board.filters.isEmpty {
                BoardFilterBar(board: board, selection: filterBinding(board.id))
            }
        }
        // 이미지 다운샘플/프리페치가 읽는 containerWidth 공급(기존엔 ContentView 담당).
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        DetailOverlayController.shared.updateContainerWidth(width)
                    }
            }
        )
        .task {
            Networking.prewarmConnections()
            ImageWarmup.warm()
            await alertBadge.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Networking.prewarmConnections()
            ImageWarmup.warm()
            Task { await catalog.revalidateLoadedCatalogs() }
            Task { await alertBadge.refresh() }
        }
    }

    private func filterBinding(_ id: String) -> Binding<BoardFilter?> {
        Binding(
            get: { filterByBoard[id] },
            set: { filterByBoard[id] = $0 }
        )
    }
}

// MARK: - 모음 홈 (보드 페이저 + 슬림 헤더 + 컨텍스트 검색)

private struct ArchiveHome: View {
    let favorites: FavoritesStore
    let readStore: ReadStore
    let cache: PostDetailCache
    @Binding var currentBoardID: String?
    @Binding var filterByBoard: [String: BoardFilter]
    @Binding var reading: Bool

    @State private var path: [Post] = []
    // 보드별 확정 검색어(빈/없음 = 검색 안 함). BoardListView 가 searchQuery 로
    // 받아 결과를 같은 목록 자리에 표출한다.
    @State private var queryByBoard: [String: String] = [:]
    @State private var searchActive = false
    @State private var queryText = ""
    @FocusState private var searchFocused: Bool

    private var boards: [Board] { favorites.favoriteBoards() }
    private var currentBoard: Board? {
        boards.first { $0.id == currentBoardID } ?? boards.first
    }
    private var activeQuery: String? {
        guard let id = currentBoard?.id, let q = queryByBoard[id], !q.isEmpty else { return nil }
        return q
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                if boards.isEmpty {
                    ContentUnavailableView("즐겨찾기한 보드가 없어요", systemImage: "star",
                                           description: Text("둘러보기에서 ⭐로 추가하세요"))
                } else {
                    TabView(selection: $currentBoardID) {
                        ForEach(boards) { board in
                            BoardListView(
                                board: board,
                                filter: filterByBoard[board.id],
                                searchQuery: queryByBoard[board.id],
                                readStore: readStore,
                                onSelectPost: { post in path.append(post) }
                            )
                            .equatable()
                            .tag(Optional(board.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(
                    post: post,
                    readStore: readStore,
                    cache: cache,
                    onDismiss: { if !path.isEmpty { path.removeLast() } }
                )
                .equatable()
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .onAppear { reading = true }
                .onDisappear { reading = false }
            }
        }
        .onAppear {
            if currentBoardID == nil { currentBoardID = boards.first?.id }
        }
    }

    // 슬림 헤더 — 보드명 메뉴 + 사이트색 페이지 인디케이터(or 검색 결과 표시) + 돋보기.
    @ViewBuilder private var header: some View {
        if searchActive {
            searchBar
        } else {
            ZStack {
                VStack(spacing: 6) {
                    boardMenu
                    if let q = activeQuery {
                        searchResultsRow(q)
                    } else if boards.count > 1 {
                        pageIndicator
                    }
                }
                .frame(maxWidth: .infinity)
                if currentBoard?.supportsSearch == true {
                    HStack {
                        Spacer()
                        Button {
                            queryText = activeQuery ?? ""
                            withAnimation(.snappy) { searchActive = true }
                            searchFocused = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 16)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 7)
        }
    }

    private var boardMenu: some View {
        Menu {
            ForEach(boards) { b in
                Button {
                    withAnimation(.snappy) { currentBoardID = b.id }
                } label: {
                    if b.id == currentBoard?.id {
                        Label(b.name, systemImage: "checkmark")
                    } else {
                        Text(b.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentBoard?.name ?? "모음")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(boards) { b in
                let isSel = b.id == currentBoard?.id
                Capsule()
                    .fill(isSel ? AnyShapeStyle(b.site.accentColor) : AnyShapeStyle(Color(.tertiaryLabel)))
                    .frame(width: isSel ? 18 : 6, height: 6)
                    .onTapGesture { withAnimation(.snappy) { currentBoardID = b.id } }
            }
        }
        .animation(.snappy, value: currentBoardID)
    }

    private func searchResultsRow(_ q: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption2.weight(.bold))
            Text("‘\(q)' 검색 결과").font(.caption.weight(.semibold))
            Button {
                if let id = currentBoard?.id {
                    withAnimation(.snappy) { queryByBoard[id] = nil }
                }
            } label: {
                Text("· 해제").font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.tint)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("‘\(currentBoard?.name ?? "")'에서 검색", text: $queryText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(commitSearch)
                if !queryText.isEmpty {
                    Button { queryText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemFill), in: Capsule())
            Button("취소") {
                searchActive = false
                searchFocused = false
                queryText = ""
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func commitSearch() {
        let t = queryText.trimmingCharacters(in: .whitespaces)
        if let id = currentBoard?.id {
            withAnimation(.snappy) { queryByBoard[id] = t.isEmpty ? nil : t }
        }
        searchActive = false
        searchFocused = false
    }
}

// MARK: - 둘러보기 (사이트 → 보드, 별표로 모음 추가)

private struct BrowseTab: View {
    let catalog: BoardCatalogStore
    let favorites: FavoritesStore

    private var sites: [Site] {
        DrawerSection.all.compactMap { if case .site(let s) = $0 { return s } else { return nil } }
    }

    var body: some View {
        NavigationStack {
            List(sites, id: \.self) { site in
                NavigationLink(value: site) {
                    HStack(spacing: 12) {
                        SiteEmblem(site: site)
                        Text(site.displayName).font(.body.weight(.semibold))
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("둘러보기")
            .navigationDestination(for: Site.self) { site in
                SiteBoardsView(site: site, catalog: catalog, favorites: favorites)
            }
        }
    }
}

private struct SiteBoardsView: View {
    let site: Site
    let catalog: BoardCatalogStore
    let favorites: FavoritesStore

    var body: some View {
        List {
            ForEach(catalog.groups(for: site)) { group in
                Section(group.name ?? "") {
                    ForEach(group.boards) { board in
                        HStack {
                            Text(board.name)
                            Spacer()
                            Button {
                                favorites.toggle(board)
                            } label: {
                                Image(systemName: favorites.isFavorite(board) ? "star.fill" : "star")
                                    .foregroundStyle(favorites.isFavorite(board) ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle(site.displayName)
        .toolbarTitleDisplayMode(.inline)
        .overlay {
            if catalog.isLoading(site) && catalog.groups(for: site).allSatisfy({ $0.boards.isEmpty }) {
                ProgressView()
            }
        }
        .task {
            await catalog.loadIfNeeded(site)
            favorites.merge(boards: catalog.boards(for: site))
        }
    }
}

private struct SiteEmblem: View {
    let site: Site
    var body: some View {
        Text(String(site.displayName.prefix(1)))
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(site.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
