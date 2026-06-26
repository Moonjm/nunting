import SwiftUI

// 상세 오버레이 백드래그(우→ 스와이프 닫기). 구앱 GestureCoordinator 에서
// detail 백드래그만 떼어낸 경량판 — 드로어/forward-reveal 분기 없음(새 셸의
// 보드 페이저 가로 스와이프와 충돌하지 않게). DetailOverlayController 의
// offset/show/hide/shouldDismissSwipe 와 짝으로 동작한다.
//
// 닫을 때 슬라이드 아웃 뒤 activePost 를 비워 오버레이를 언마운트한다(구앱의
// keep-alive 미사용): 메모리 회수 + "마지막 글 재노출"이 보드 스와이프와
// 겹치는 문제를 원천 차단.
@Observable @MainActor
final class DetailBackDrag {
    /// 가로 드래그가 잠긴 동안 true → PostDetailView 의 내부 ScrollView 잠금.
    var scrollLocked = false
    /// 백드래그 중 손가락 밑 이미지/영상이 touch-up 에 탭 발화하지 않게.
    let tapGate = TapSuppressionGate()
    /// 하단(탭바/필터) 영역 제외 판정용.
    var containerHeight: CGFloat = 0

    @ObservationIgnored private var horizontalLock: Bool? = nil  // nil 미정 / true 가로 / false 세로
    @ObservationIgnored private var baseline: CGFloat = 0

    private var detail: DetailOverlayController { .shared }

    var gesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { [self] v in onChanged(v) }
            .onEnded { [self] v in onEnded(v) }
    }

    private func onChanged(_ v: DragGesture.Value) {
        // 오버레이가 보이는 동안에만 — 닫혀있으면(보드 목록) 보드 페이저에 양보.
        guard detail.activePost != nil, detail.isOverlayVisible else { return }
        // 하단 ~110pt(탭바/필터)에서 시작한 드래그는 백드래그로 잡지 않는다.
        if containerHeight > 0, v.startLocation.y > containerHeight - 110 { return }
        let w = abs(v.translation.width), h = abs(v.translation.height)
        if horizontalLock == nil {
            if w > 10 && w >= h {
                horizontalLock = true
                baseline = v.translation.width
                scrollLocked = true
                detail.offsetBase = detail.offset
            } else if h > 10 && h > w {
                horizontalLock = false
            }
        }
        if horizontalLock == true {
            tapGate.suppress()
            let dx = v.translation.width - baseline
            detail.offset = max(0, min(detail.containerWidth, dx))  // 우→(닫기) 방향만
        }
    }

    private func onEnded(_ v: DragGesture.Value) {
        let horizontal = horizontalLock == true
        let base = baseline
        horizontalLock = nil
        baseline = 0
        scrollLocked = false
        guard horizontal, detail.activePost != nil else { return }
        let traveled = v.translation.width - base
        let velocity = v.predictedEndTranslation.width - v.translation.width
        if detail.shouldDismissSwipe(dx: traveled, velocityX: velocity) {
            dismiss()
        } else {
            detail.beginAnimationLock()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { detail.offset = 0 }
        }
    }

    /// 닫기 — 슬라이드 아웃 후 activePost 를 비워 언마운트(헤더 뒤로 버튼·백드래그 공용).
    func dismiss() {
        let token = detail.activePost?.id
        detail.hide()
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(380))
            if detail.activePost?.id == token, detail.offset >= detail.containerWidth - 0.5 {
                detail.activePost = nil
            }
        }
    }
}

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
    // 모음의 현재 보드 — 페이저/헤더/검색이 공유한다.
    @State private var currentBoardID: String?
    // 보드별 활성 검색어(옛 앱처럼 검색은 보드에 묶임). 하단 검색 버튼과
    // 모음 목록/배너가 공유하므로 셸 레벨에 둔다.
    @State private var searchByBoard: [String: String] = [:]
    @State private var showingSearch = false
    // 상세 오버레이 백드래그(우→ 스와이프 닫기) 상태기계.
    @State private var backDrag = DetailBackDrag()

    @Environment(\.scenePhase) private var scenePhase

    private var currentBoard: Board? {
        let boards = favorites.favoriteBoards()
        return boards.first { $0.id == currentBoardID } ?? boards.first
    }
    // 현재 보드에 검색이 걸려 있으면 검색 버튼을 채운 아이콘으로 — 활성
    // 표시 겸 해제 경로(눌러서 SearchSheet → 검색 해제) 안내.
    private var searchActive: Bool {
        currentBoard.flatMap { searchByBoard[$0.id] } != nil
    }

    var body: some View {
        ZStack {
            // 검색은 별도 목적지가 아니라, 하단 탭바 오른쪽에 분리된 돋보기
            // 버튼(role:.search). 탭하면 모음 컨텍스트로 이동해 SearchSheet 를
            // 띄운다 — 검색 탭 자체는 선택되지 않으므로 통합검색이 활성화되지 않음.
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == 3 {
                        selectedTab = 0
                        if currentBoard != nil { showingSearch = true }
                    } else {
                        selectedTab = newValue
                    }
                }
            )) {
                Tab("모음", systemImage: "tray.full.fill", value: 0) {
                    ArchiveHome(
                        favorites: favorites,
                        readStore: readStore,
                        onSelectPost: { detail.show($0) },
                        searchByBoard: $searchByBoard,
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
                Tab("검색", systemImage: searchActive ? "magnifyingglass.circle.fill" : "magnifyingglass",
                    value: 3, role: .search) {
                    Color.clear
                }
            }
            .sheet(isPresented: $showingSearch) {
                if let board = currentBoard {
                    SearchSheet(
                        board: board,
                        initialQuery: searchByBoard[board.id] ?? "",
                        onSubmit: { searchByBoard[board.id] = $0 },
                        onClear: { searchByBoard[board.id] = nil }
                    )
                }
            }

            // 상세 오버레이 — TabView 위 ZStack 최상단 레이어로 화면 전체(탭바
            // 포함)를 덮는다. show() 가 우측에서 슬라이드 인, 백드래그가 offset 을
            // 추적해 우→ 스와이프로 닫는다. 인앱 글 탭·푸시·받은알림 모두 이 경로.
            if let post = detail.activePost {
                NavigationStack {
                    PostDetailScreen(
                        post: post,
                        readStore: readStore,
                        cache: detailCache,
                        tapGate: backDrag.tapGate,
                        isOverlayVisible: detail.isOverlayVisible,
                        isScrollingBlocked: backDrag.scrollLocked || detail.animating,
                        onBack: { backDrag.dismiss() }
                    )
                }
                .background(Color(.systemBackground).ignoresSafeArea())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(post.id)
                .offset(x: detail.offset)
                .allowsHitTesting(detail.allowsHitTesting)
                .zIndex(10)
            }
        }
        // 이미지 다운샘플/프리페치가 읽는 containerWidth + 백드래그 하단 제외용
        // containerHeight 공급(기존엔 ContentView 담당).
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in
                        detail.updateContainerWidth(size.width)
                        backDrag.containerHeight = size.height
                    }
            }
        )
        .simultaneousGesture(backDrag.gesture)
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
}

// MARK: - 상세 화면 (유리 내비바 + 원문) — 인앱 push 와 딥링크 모달이 공유

private struct PostDetailScreen: View {
    let post: Post
    let readStore: ReadStore
    let cache: PostDetailCache
    // 백드래그 공존용 — 드래그 중 내부 ScrollView 잠금 + 미디어 탭 억제.
    var tapGate: TapSuppressionGate? = nil
    var isOverlayVisible: Bool = true
    var isScrollingBlocked: Bool = false
    /// 좌상단 뒤로(닫기) 버튼 동작. 오버레이를 닫는다.
    var onBack: (() -> Void)? = nil

    @State private var browserItem: WebBrowserItem?

    var body: some View {
        PostDetailView(
            post: post,
            readStore: readStore,
            cache: cache,
            tapGate: tapGate,
            isOverlayVisible: isOverlayVisible,
            isScrollingBlocked: isScrollingBlocked,
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
    /// 글 탭 → 상세 열기(detail.show). 상세는 RootTabView 의 ZStack 오버레이로
    /// 우측에서 슬라이드 인하며 화면 전체(탭바 포함)를 덮는다.
    let onSelectPost: (Post) -> Void
    // 보드별 활성 검색어 — 하단 검색 버튼이 띄우는 SearchSheet 와 공유(셸 소유).
    @Binding var searchByBoard: [String: String]
    @Binding var currentBoardID: String?

    @State private var filterByBoard: [String: BoardFilter] = [:]
    // 기본 필터를 이미 심은 보드(중복 시드 방지). 이후 사용자가 전체를
    // 골라도 재시드하지 않는다.
    @State private var seededFilterIDs: Set<String> = []

    private var boards: [Board] { favorites.favoriteBoards() }
    private var currentBoard: Board? {
        boards.first { $0.id == currentBoardID } ?? boards.first
    }
    private var currentQuery: String? {
        currentBoard.flatMap { searchByBoard[$0.id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if boards.isEmpty {
                ContentUnavailableView("즐겨찾기한 보드가 없어요", systemImage: "star",
                                       description: Text("둘러보기에서 ⭐로 추가하세요"))
            } else {
                BoardPager(
                    boards: boards,
                    currentBoardID: $currentBoardID,
                    filterByBoard: filterByBoard,
                    searchByBoard: searchByBoard,
                    readStore: readStore,
                    onSelectPost: onSelectPost
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
        // 보드 내 필터 탭은 인벤·애객처럼 *필터가 실제로 있는* 보드에서만,
        // 탭바 바로 위(엄지 존)에. 검색 중이면 숨겨 혼동 방지.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let board = currentBoard, currentQuery == nil, showsFilterBar(board) {
                GlassFilterBar(board: board, selection: filterBinding(board.id))
            }
        }
        .onAppear {
            if currentBoardID == nil { currentBoardID = boards.first?.id }
            seedDefaultFilters()
        }
        .onChange(of: boards.map(\.id)) { _, _ in seedDefaultFilters() }
    }

    // 보드별 기본 필터(예: 메이플 인벤 → 10추)를 처음 보일 때 한 번 적용.
    // 전체 피드가 시끄러운 보드의 초기 로딩을 기본 필터로 시작시킨다.
    private func seedDefaultFilters() {
        for b in boards where !seededFilterIDs.contains(b.id) {
            if let def = b.defaultListFilter { filterByBoard[b.id] = def }
            seededFilterIDs.insert(b.id)
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

    // 슬림 헤더 — 가운데 보드명 메뉴 + 사이트색 페이지 인디케이터.
    // (검색은 하단 탭바 오른쪽 돋보기 버튼으로 분리됨.)
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

// MARK: - 보드 페이저 (좌우 스와이프 + 무한 순환)

// TabView .page 는 끝에서 더 밀면 멈추므로, 앞뒤에 센티넬(맨끝/맨앞 복제) 페이지를
// 두고 거기 닿으면 무애니메이션으로 반대편 실제 페이지로 점프 → 끊김 없는 순환.
private struct BoardPager: View {
    let boards: [Board]
    @Binding var currentBoardID: String?
    let filterByBoard: [String: BoardFilter]
    let searchByBoard: [String: String]
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    // 가상 인덱스: 0=헤드 센티넬(boards.last) / 1…n=실제 / n+1=테일 센티넬(boards.first)
    @State private var index = 1

    var body: some View {
        if boards.count <= 1 {
            if let board = boards.first {
                BoardListView(board: board, filter: filterByBoard[board.id],
                              searchQuery: searchByBoard[board.id], readStore: readStore,
                              onSelectPost: onSelectPost)
                    .equatable()
            }
        } else {
            TabView(selection: $index) {
                page(boards.last!, tag: 0)
                ForEach(Array(boards.enumerated()), id: \.offset) { i, board in
                    page(board, tag: i + 1)
                }
                page(boards.first!, tag: boards.count + 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: index) { _, idx in handleIndex(idx) }
            .onChange(of: currentBoardID) { _, id in syncFromID(id) }
            .onChange(of: boards.map(\.id)) { _, _ in index = realIndex(currentBoardID) ?? 1 }
            .onAppear { index = realIndex(currentBoardID) ?? 1 }
        }
    }

    @ViewBuilder private func page(_ board: Board, tag: Int) -> some View {
        BoardListView(board: board, filter: filterByBoard[board.id],
                      searchQuery: searchByBoard[board.id], readStore: readStore,
                      onSelectPost: onSelectPost)
            .equatable()
            .tag(tag)
    }

    private func realIndex(_ id: String?) -> Int? {
        guard let id, let i = boards.firstIndex(where: { $0.id == id }) else { return nil }
        return i + 1
    }

    // 센티넬에 닿으면 반대편 실제 페이지로 무애니메이션 점프(같은 보드라 끊김 없음).
    private func handleIndex(_ idx: Int) {
        if idx == 0 {
            jump(boards.count)
        } else if idx == boards.count + 1 {
            jump(1)
        } else {
            let id = boards[idx - 1].id
            if currentBoardID != id { currentBoardID = id }
        }
    }

    private func jump(_ target: Int) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { index = target }
        let id = boards[target - 1].id
        if currentBoardID != id { currentBoardID = id }
    }

    // 보드명 메뉴/인디케이터 탭으로 currentBoardID 가 바뀌면 페이저도 따라간다.
    private func syncFromID(_ id: String?) {
        guard let target = realIndex(id) else { return }
        if index != target, index != 0, index != boards.count + 1 {
            index = target
        }
    }
}

// MARK: - 유리 필터 바 (탭바 위에 떠 있는 Liquid Glass 알약)

private struct GlassFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    chip(label: item.label, filter: item.filter)
                }
            }
            .padding(5)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private struct Item: Identifiable {
        let id: String
        let label: String
        let filter: BoardFilter?
    }

    /// 칩 순서 — 기존 BoardFilterBar 와 동일. 인벤 메이플만 커스텀 순서
    /// (10추 · 인방 · 전체 · 30추), 그 외는 전체 + 보드 필터 순.
    private var items: [Item] {
        let all = Item(id: "_all", label: "전체", filter: nil)
        if board.id == Board.invenMaple.id {
            let byID = Dictionary(uniqueKeysWithValues: board.filters.map { ($0.id, $0) })
            return [
                byID["chu"].map { Item(id: $0.id, label: $0.name, filter: $0) },
                byID["inbang"].map { Item(id: $0.id, label: $0.name, filter: $0) },
                all,
                byID["chuchu"].map { Item(id: $0.id, label: $0.name, filter: $0) },
            ].compactMap { $0 }
        }
        return [all] + board.filters.map { Item(id: $0.id, label: $0.name, filter: $0) }
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
