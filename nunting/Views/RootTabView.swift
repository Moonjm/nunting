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
    // 푸시 탭·받은알림 탭 모두 DetailOverlayController.present(url:title:) →
    // activePost 로 funnel 된다. 새 셸은 그 activePost 를 관찰해 상세를 띄운다.
    @State private var detail = DetailOverlayController.shared

    @State private var selectedTab = 0
    // 모음의 현재 보드 — 검색 탭이 "지금 보고 있는 보드"를 검색하도록 공유.
    @State private var currentBoardID: String?

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
                    currentBoardID: $currentBoardID
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
            Tab("검색", systemImage: "magnifyingglass", value: 3, role: .search) {
                SearchTab(board: currentBoard, readStore: readStore,
                          onSelectPost: { detail.show($0) })
            }
        }
        // 스크롤 시 탭바만 줄고 그 위 유리 필터 알약(safeAreaInset)은 그대로라
        // 둘이 따로 놀아 이질감이 생긴다 — 탭바 축소를 끄고 둘 다 고정으로.
        // (보드 리더에선 필터·탭이 항상 닿는 게 더 편하기도 함.)
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
        // 푸시/받은알림 딥링크 → activePost 가 세팅되면 상세를 모달로 띄운다.
        // 현재 탭과 무관하게 동작(크로스탭 네비게이션 불필요). 읽음 처리는
        // PostDetailView.task 가 담당.
        .fullScreenCover(item: Binding(
            get: { detail.activePost },
            set: { if $0 == nil { detail.hide() } }
        )) { post in
            NavigationStack {
                PostDetailScreen(post: post, readStore: readStore, cache: detailCache,
                                 onBack: { detail.hide() })
            }
        }
    }
}

// MARK: - 상세 화면 (유리 내비바 + 원문) — 인앱 push 와 딥링크 모달이 공유

private struct PostDetailScreen: View {
    let post: Post
    let readStore: ReadStore
    let cache: PostDetailCache
    /// nil = NavigationStack push(시스템 뒤로 버튼 사용). non-nil = 모달 루트라
    /// 명시적 뒤로(닫기) 버튼을 좌상단에 단다.
    var onBack: (() -> Void)? = nil

    @State private var browserItem: WebBrowserItem?

    var body: some View {
        PostDetailView(
            post: post,
            readStore: readStore,
            cache: cache,
            onDismiss: {},
            showsHeader: false
        )
        .equatable()
        .navigationTitle(post.site.displayName)
        .toolbarTitleDisplayMode(.inline)
        // 탭바는 상세에서도 고정(숨기면 push/pop 시 사라졌다 나타나며 깜빡임).
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("뒤로")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    browserItem = WebBrowserItem(url: post.url)
                } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("원문 보기")
            }
        }
        .sheet(item: $browserItem) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
    }
}

// MARK: - 모음 홈 (보드 페이저 + 슬림 헤더 + 컨텍스트 검색)

private struct ArchiveHome: View {
    let favorites: FavoritesStore
    let readStore: ReadStore
    /// 글 탭 → 상세 열기. 상세는 RootTabView 의 fullScreenCover 로 전체화면을
    /// 덮어 띄운다(탭바째 통째로 가려 목록 쪽 chrome 이 사라졌다/나타났다 하지
    /// 않게 — push + tabBar 숨김의 깜빡임 회피).
    let cache: PostDetailCache
    // 검색은 하단 검색 탭으로 분리됐다(RootTabView). 현재 보드를 검색 탭이
    // 알아야 하므로 selection 을 위로 올려 공유한다.
    @Binding var currentBoardID: String?

    @State private var filterByBoard: [String: BoardFilter] = [:]
    // 인앱 글 탭은 NavigationStack push(시스템 가장자리 스와이프 뒤로). 탭바는
    // 숨기지 않아 상세에서도 고정 — push/pop 시 탭바가 사라졌다 나타나는
    // 깜빡임이 없다. (딥링크/푸시는 RootTabView 의 fullScreenCover 로 별도.)
    @State private var path: [Post] = []

    private var boards: [Board] { favorites.favoriteBoards() }
    private var currentBoard: Board? {
        boards.first { $0.id == currentBoardID } ?? boards.first
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
                                searchQuery: nil,
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
            // 보드 내 필터 탭은 인벤·애객처럼 *필터가 실제로 있는* 보드에서만,
            // 탭바 바로 위(엄지 존)에. 다른 보드/다른 탭에선 자리 안 차지.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let board = currentBoard, showsFilterBar(board) {
                    GlassFilterBar(board: board, selection: filterBinding(board.id))
                }
            }
            // 목록은 커스텀 슬림 헤더를 쓰므로 시스템 내비바 숨김(상세는 자체
            // navigationTitle/toolbar 로 유리 내비바를 다시 켠다).
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Post.self) { post in
                // push → 시스템 가장자리 스와이프 뒤로. 탭바는 안 숨겨 깜빡임 없음.
                PostDetailScreen(post: post, readStore: readStore, cache: cache)
            }
        }
        .onAppear {
            if currentBoardID == nil { currentBoardID = boards.first?.id }
        }
    }

    /// 필터 탭 바를 띄울 보드인지 — 인벤(10추/30추/인방)·애객(소스 필터)처럼
    /// 필터가 실제로 있는 보드만. 그 외(클리앙 등)는 띄우지 않는다.
    private func showsFilterBar(_ board: Board) -> Bool {
        (board.site == .inven || board.site == .aagag) && !board.filters.isEmpty
    }

    private func filterBinding(_ id: String) -> Binding<BoardFilter?> {
        Binding(
            get: { filterByBoard[id] },
            set: { filterByBoard[id] = $0 }
        )
    }

    // 슬림 헤더 — 보드명 메뉴 + 사이트색 페이지 인디케이터. (검색은 하단 탭으로 이동.)
    private var header: some View {
        VStack(spacing: 6) {
            boardMenu
            if boards.count > 1 { pageIndicator }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 7)
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

}

// MARK: - 검색 탭 (하단 검색 버튼 → 키패드+입력, 현재 보드 검색)

private struct SearchTab: View {
    let board: Board?
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    @State private var draft = ""
    @State private var committed = ""

    var body: some View {
        NavigationStack {
            Group {
                if let board, !committed.isEmpty {
                    BoardListView(
                        board: board,
                        filter: nil,
                        searchQuery: committed,
                        readStore: readStore,
                        onSelectPost: onSelectPost
                    )
                    .equatable()
                } else if board?.supportsSearch == false {
                    ContentUnavailableView("이 보드는 검색을 지원하지 않아요",
                                           systemImage: "magnifyingglass")
                } else {
                    ContentUnavailableView {
                        Label("검색", systemImage: "magnifyingglass")
                    } description: {
                        Text(board.map { "'\($0.name)'에서 검색어를 입력하세요" } ?? "보드를 먼저 선택하세요")
                    }
                }
            }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
        }
        .searchable(text: $draft, prompt: board.map { "'\($0.name)' 검색" } ?? "검색")
        .onSubmit(of: .search) {
            committed = draft.trimmingCharacters(in: .whitespaces)
        }
        .onChange(of: draft) { _, v in
            if v.isEmpty { committed = "" }
        }
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

// MARK: - 유리 필터 바 (탭바 위에 떠 있는 Liquid Glass 알약)

private struct GlassFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(label: "전체", filter: nil)
                ForEach(board.filters) { f in
                    chip(label: f.name, filter: f)
                }
            }
            .padding(5)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func chip(label: String, filter: BoardFilter?) -> some View {
        let isSelected = selection?.id == filter?.id
        return Text(label)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selection = filter } }
    }
}
