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
                if v.translation.width > 0 {
                    // 우측(닫기) 가로 드래그만 백드래그로 잡는다.
                    horizontalLock = true
                    baseline = v.translation.width
                    scrollLocked = true
                    detail.offsetBase = detail.offset
                } else {
                    // 좌측 가로 드래그는 닫기와 무관 — 스크롤/탭을 막지 않게 양보.
                    horizontalLock = false
                }
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
// 기존 서비스·뷰(BoardListView/PostDetailView/KeywordListView)를 그대로
// 재사용하고, 여기선 네비게이션 골격과 보드 전환/필터/검색만 조립한다.
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
    // 하단 히스토리 탭 → 최근 읽은 글 시트.
    @State private var showingHistory = false
    // 둘러보기에서 현재 열어둔 보드(글 목록). nil = 사이트 목록/미진입.
    @State private var browsingBoard: Board?
    // 상세 오버레이 백드래그(우→ 스와이프 닫기) 상태기계.
    @State private var backDrag = DetailBackDrag()

    @Environment(\.scenePhase) private var scenePhase

    private var currentBoard: Board? {
        let boards = favorites.favoriteBoards()
        return boards.first { $0.id == currentBoardID } ?? boards.first
    }
    // 하단 검색 버튼이 검색할 대상 — 모음에선 현재 보드, 둘러보기에선 열어둔
    // 보드. 그 외 탭에선 없음(버튼도 숨김).
    private var searchContextBoard: Board? {
        switch selectedTab {
        case 0: return currentBoard
        case 1: return browsingBoard
        default: return nil
        }
    }
    var body: some View {
        ZStack {
            // 검색은 하단 탭이 아니라, 필터 바와 같은 하단 행 우측 끝에 떠 있는
            // 유리 동그라미 버튼(BoardSearchButton — 모음/둘러보기 보드 화면에 위치).
            // 탭 구성은 4개(모음/둘러보기/알림/히스토리)로 고정 — 조건부 탭이 없어야
            // 재평가 시 탭 콘텐츠 identity 가 안정돼 히스토리 탭에 목록이 재로딩되지
            // 않는다.
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == 4 {
                        // 히스토리 탭 — 탭 전환 없이 최근 읽은 글 시트를 띄운다.
                        showingHistory = true
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
                        isActive: selectedTab == 0,
                        searchByBoard: $searchByBoard,
                        currentBoardID: $currentBoardID,
                        onPresentSearch: { showingSearch = true }
                    )
                }
                Tab("둘러보기", systemImage: "square.grid.2x2", value: 1) {
                    BrowseTab(catalog: catalog, favorites: favorites,
                              readStore: readStore, onSelectPost: { detail.show($0) },
                              searchByBoard: $searchByBoard, browsingBoard: $browsingBoard,
                              onPresentSearch: { showingSearch = true })
                }
                Tab("알림", systemImage: "bell", value: 2) {
                    NavigationStack {
                        KeywordListView()
                            .navigationTitle("알림")
                            // 모음과 같은 처리 — 화면 배경을 리스트 색까지 깔아
                            // 상단 유리 네비바·하단 탭바가 이 톤을 블러해 일체감.
                            .background(Color(.systemGroupedBackground).ignoresSafeArea())
                    }
                }
                .badge(alertBadge.unread)
                // 히스토리 — 탭하면 전환 대신 최근 읽은 글 시트를 띄운다(검색과
                // 같은 패턴). 묶음 탭 마지막 자리.
                Tab("히스토리", systemImage: "clock.arrow.circlepath", value: 4) {
                    Color.clear
                }
            }
            .sheet(isPresented: $showingSearch) {
                if let board = searchContextBoard {
                    SearchSheet(
                        board: board,
                        initialQuery: searchByBoard[board.id] ?? "",
                        onSubmit: { searchByBoard[board.id] = $0 }
                    )
                }
            }
            .sheet(isPresented: $showingHistory) {
                HistorySheet(
                    posts: Array(readStore.recentPosts.prefix(5)),
                    onOpen: { post in
                        // 시트 닫기 + 상세 열기를 같은 틱에. 상세는 시트가 아니라
                        // 항상 떠 있는 ZStack 오버레이(activePost 갱신)라 시트
                        // dismiss 트랜잭션과 독립적 → 드롭/이중표시 없이 안전.
                        showingHistory = false
                        detail.show(post)
                    }
                )
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
        // 게시판(사이트)명은 상세에서 표시하지 않는다 — 빈 타이틀로 두고
        // 툴바 버튼(뒤로/원문)만 남긴다.
        .navigationTitle("")
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
    // 모음 탭이 활성인지 — 다른 탭 갔다 돌아오면 첫 필터로 리셋하기 위함.
    let isActive: Bool
    // 보드별 활성 검색어 — 하단 검색 버튼이 띄우는 SearchSheet 와 공유(셸 소유).
    @Binding var searchByBoard: [String: String]
    @Binding var currentBoardID: String?
    // 검색 버튼 탭 → 셸의 SearchSheet 띄우기.
    let onPresentSearch: () -> Void

    @State private var filterByBoard: [String: BoardFilter] = [:]
    // 떠 있는 탭바가 가리는 하단 안전영역 높이(측정). 리스트를 탭바 밑까지
    // 깔되 이만큼 콘텐츠 인셋을 줘 마지막 글 가림을 막는다.
    @State private var bottomSafeInset: CGFloat = 0

    private var boards: [Board] { favorites.favoriteBoards() }
    private var currentBoard: Board? {
        boards.first { $0.id == currentBoardID } ?? boards.first
    }
    private var currentQuery: String? {
        currentBoard.flatMap { searchByBoard[$0.id] }
    }
    // 떠 있는 하단 컨트롤(필터 바/검색 버튼)이 가리는 높이만큼 목록 하단에 줄 여백.
    static let bottomControlsInset: CGFloat = 60
    // 지금 하단 컨트롤이 떠 있는 보드 id 집합. 검색 버튼만 떠 있는 보드도 포함한다.
    private var bottomControlsBoardIDs: Set<String> {
        Set(boards.filter { board in
            board.supportsSearch || (showsFilterBar(board) && searchByBoard[board.id] == nil)
        }.map(\.id))
    }

    var body: some View {
        // 헤더를 VStack 으로 쌓지 않고 safeAreaInset(.top) 으로 올린다. 그래야
        // 페이저(리스트)가 루트로서 화면 전체를 차지해 탭바 밑까지 스크롤되고,
        // 유리 탭바가 그 밑을 지나가는 콘텐츠를 비춘다(알림 탭과 동일한 느낌).
        Group {
            if boards.isEmpty {
                ContentUnavailableView("즐겨찾기한 보드가 없어요", systemImage: "star",
                                       description: Text("둘러보기에서 ⭐로 추가하세요"))
            } else {
                BoardPager(
                    boards: boards,
                    currentBoardID: $currentBoardID,
                    filterByBoard: filterByBoard,
                    searchByBoard: searchByBoard,
                    bottomControlsBoardIDs: bottomControlsBoardIDs,
                    bottomControlsInset: Self.bottomControlsInset,
                    baseBottomInset: bottomSafeInset,
                    readStore: readStore,
                    onSelectPost: onSelectPost
                )
                // 탭바 밑까지 리스트가 깔려 유리 탭바에 콘텐츠가 비치게 한다.
                .ignoresSafeArea(edges: .bottom)
            }
        }
        // 헤더 밴드 없이 목록이 상단까지 꽉 차고, 보드 메뉴 버튼만 우상단에 떠
        // 있는 유리 동그라미로 겹쳐 띄운다. (검색·히스토리는 하단 탭바로 이동.)
        .overlay(alignment: .topTrailing) { boardMenu }
        // 탭바가 가리는 하단 안전영역 높이를 측정해 인셋으로 환원.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeInset = $0 }
        // 모음 화면 배경을 탭바 밑까지 깔아, 떠 있는 유리 탭바가 이 AppSurface 를
        // 블러하도록 한다 — 목록 배경과 톤이 같아져 탭바가 목록과 일체감 있게 보임.
        // (안 깔면 탭바가 그 뒤 기본 윈도우 배경을 블러해 다른 톤이 된다.)
        .background(Color("AppSurface").ignoresSafeArea())
        // 필터 바는 safeAreaInset 이 아니라 overlay 로 띄운다. safeAreaInset 은
        // 떠 있는 탭바의 안전영역에 흡수돼 탭바 플랫폼이 위로 자라 보였다.
        // overlay 는 레이아웃·탭바를 건드리지 않고 목록 위에 독립적으로 떠 있고,
        // 가림 방지는 BoardListView 의 bottomContentInset 이 담당한다.
        // 필터 바(좌, 내용에 맞게 hug) + 검색 버튼(우)을 한 행에 세로 중앙
        // 정렬로 띄운다. 둘이 같은 HStack 이라 겹치지 않고 센터가 맞는다.
        .overlay(alignment: .bottom) {
            if let board = currentBoard {
                HStack(alignment: .center, spacing: 8) {
                    if currentQuery == nil, showsFilterBar(board) {
                        // layoutPriority: 캡슐과 Spacer 가 둘 다 flexible 이라
                        // 우선순위 없으면 캡슐이 가용폭 절반만 받아 hug 가 깨진다.
                        // 우선순위를 주면 전체 가용폭을 먼저 받아 min(가용,내용)으로
                        // 줄어든다 — 인벤 4칩=hug, 애객 11칩=가용폭 캡 후 스크롤.
                        GlassFilterBar(board: board, selection: filterBinding(board.id))
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    BoardSearchButton(board: board, searchByBoard: $searchByBoard,
                                      onPresentSearch: onPresentSearch)
                }
                // 필터 바 시작 위치는 원래대로 좌측 28pt, 검색 버튼은 우측 16pt.
                .padding(.leading, 28)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            if currentBoardID == nil { currentBoardID = boards.first?.id }
            resetFilterToDefault(currentBoard)
        }
        // 보드를 바꾸거나(스와이프·메뉴) 모음 탭에 (다시) 들어올 때마다 무조건
        // 첫 필터 탭으로 리셋한다. 인벤 → 10추, 전체 피드가 첫 탭인 보드 → 전체.
        .onChange(of: currentBoardID) { _, _ in resetFilterToDefault(currentBoard) }
        .onChange(of: isActive) { _, active in if active { resetFilterToDefault(currentBoard) } }
    }

    // 보드의 첫 필터 탭(= defaultListFilter; 없으면 전체=nil)으로 되돌린다.
    private func resetFilterToDefault(_ board: Board?) {
        guard let board else { return }
        filterByBoard[board.id] = board.defaultListFilter
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

    // 우상단에 떠 있는 보드 카드 메뉴 버튼 — 검정 아이콘 + 유리 동그라미(하단
    // 검색 버튼과 동일 룩). 누르면 모음에 담긴 보드(사이트) 목록이 드롭다운으로
    // 뜨고 선택하면 그 보드로 전환(현재 보드 체크). 목록은 그 밑으로 겹쳐 흐른다.
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
            Image(systemName: "rectangle.stack")
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                // 하단 검색 버튼(44pt 유리 동그라미)과 크기 맞춤.
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
        }
        .tint(.black)
        .accessibilityLabel("보드 선택")
        .padding(.top, 6)
        .padding(.trailing, 16)
    }

}

// MARK: - 둘러보기 (사이트 → 보드, 별표로 모음 추가)

private struct BrowseTab: View {
    let catalog: BoardCatalogStore
    let favorites: FavoritesStore
    let readStore: ReadStore
    /// 보드 글 목록에서 글 탭 → 상세 열기(모음과 동일하게 detail.show).
    let onSelectPost: (Post) -> Void
    // 검색은 하단 검색 버튼으로(모음과 동일) — 보드별 검색어 공유 + 지금 열어둔
    // 보드를 셸에 알려 하단 버튼이 그 보드를 검색하게 한다.
    @Binding var searchByBoard: [String: String]
    @Binding var browsingBoard: Board?
    // 검색 버튼 탭 → 셸의 SearchSheet 띄우기(모음과 공유).
    let onPresentSearch: () -> Void

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
                SiteBoardsView(site: site, catalog: catalog, favorites: favorites,
                               readStore: readStore, onSelectPost: onSelectPost)
            }
            // 보드 탭 → 그 보드 글 목록.
            .navigationDestination(for: Board.self) { board in
                BoardPostsView(board: board, readStore: readStore, onSelectPost: onSelectPost,
                               searchByBoard: $searchByBoard, browsingBoard: $browsingBoard,
                               onPresentSearch: onPresentSearch)
            }
        }
    }
}

/// 둘러보기에서 보드를 탭했을 때 그 보드의 글 목록(기본 필터로). 글 탭은
/// 모음과 동일하게 상세 오버레이를 띄운다. 검색은 모음처럼 하단 검색 버튼이
/// 담당 — 진입 시 이 보드를 셸의 browsingBoard 로 보고하면 하단 버튼이 뜬다.
private struct BoardPostsView: View {
    let board: Board
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void
    @Binding var searchByBoard: [String: String]
    @Binding var browsingBoard: Board?
    let onPresentSearch: () -> Void

    private var query: String? { searchByBoard[board.id] }

    var body: some View {
        BoardListView(
            board: board,
            // 검색 중엔 필터 해제(모음 검색과 동일).
            filter: query == nil ? board.defaultListFilter : nil,
            searchQuery: query,
            bottomContentInset: board.supportsSearch ? ArchiveHome.bottomControlsInset : 0,
            readStore: readStore,
            onSelectPost: onSelectPost
        )
        .equatable()
        // 검색 버튼 — 모음과 같은 하단 우측 떠있는 유리 동그라미.
        .overlay(alignment: .bottomTrailing) {
            BoardSearchButton(board: board, searchByBoard: $searchByBoard,
                              onPresentSearch: onPresentSearch)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
        .navigationTitle(board.name)
        .toolbarTitleDisplayMode(.inline)
        // 이 보드를 셸에 알려 하단 검색 버튼이 이 보드를 검색하게 한다.
        .onAppear { browsingBoard = board }
        .onDisappear { if browsingBoard?.id == board.id { browsingBoard = nil } }
    }
}

private struct SiteBoardsView: View {
    let site: Site
    let catalog: BoardCatalogStore
    let favorites: FavoritesStore
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    var body: some View {
        List {
            ForEach(catalog.groups(for: site)) { group in
                Section(group.name ?? "") {
                    ForEach(group.boards) { board in
                        // 행 탭 → 글 목록(NavigationLink), 별표 버튼은 모음 추가/제거.
                        NavigationLink(value: board) {
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
    // 떠 있는 하단 컨트롤을 가진 보드 id → 그만큼 목록 하단 인셋.
    let bottomControlsBoardIDs: Set<String>
    let bottomControlsInset: CGFloat
    // 탭바 밑까지 리스트가 깔리도록 ignoresSafeArea 하므로, 탭바가 가리는
    // 만큼(측정값)을 목록 하단 인셋으로 직접 돌려준다.
    let baseBottomInset: CGFloat
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    // 가상 인덱스: 0=헤드 센티넬(boards.last) / 1…n=실제 / n+1=테일 센티넬(boards.first)
    @State private var index = 1
    // 보드별 재로딩 토큰 — 다른 보드로 전환해 들어올 때 그 보드 토큰을 올려
    // BoardListView 가 새로 불러오게 한다(첫 진입 제외).
    @State private var reloadTokens: [String: Int] = [:]

    private func inset(_ board: Board) -> CGFloat {
        baseBottomInset + (bottomControlsBoardIDs.contains(board.id) ? bottomControlsInset : 0)
    }

    var body: some View {
        if boards.count <= 1 {
            if let board = boards.first {
                BoardListView(board: board, filter: filterByBoard[board.id],
                              searchQuery: searchByBoard[board.id],
                              bottomContentInset: inset(board),
                              reloadToken: reloadTokens[board.id] ?? 0, readStore: readStore,
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
            .onChange(of: currentBoardID) { old, id in
                syncFromID(id)
                // 첫 진입(nil→첫 보드)은 .task 가 로드하므로 제외, 그 외 전환은
                // 도착한 보드를 새로 불러온다.
                if old != nil, let id { reloadTokens[id, default: 0] += 1 }
            }
            .onChange(of: boards.map(\.id)) { _, _ in index = realIndex(currentBoardID) ?? 1 }
            .onAppear { index = realIndex(currentBoardID) ?? 1 }
        }
    }

    @ViewBuilder private func page(_ board: Board, tag: Int) -> some View {
        BoardListView(board: board, filter: filterByBoard[board.id],
                      searchQuery: searchByBoard[board.id],
                      bottomContentInset: inset(board),
                      reloadToken: reloadTokens[board.id] ?? 0, readStore: readStore,
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

// 보드 화면 하단 우측에 떠 있는 검색 버튼 — 보드 메뉴 버튼과 동일한 유리
// 동그라미 룩(44pt). 검색 중이면 X(해제)로 바뀐다. 필터 바와 같은 하단 행
// 반대편 끝. 모음(ArchiveHome)·둘러보기(BoardPostsView) 가 공유한다 — 둘 다
// 탭 안이라 safe area 에 탭바 높이가 포함돼 필터 바와 같은 행에 정렬된다.
private struct BoardSearchButton: View {
    let board: Board
    @Binding var searchByBoard: [String: String]
    /// 검색 시작(시트 띄우기). 해제는 로컬에서 searchByBoard 만 비운다.
    let onPresentSearch: () -> Void

    var body: some View {
        if board.supportsSearch {
            let active = searchByBoard[board.id] != nil
            Button {
                if active { searchByBoard[board.id] = nil } else { onPresentSearch() }
            } label: {
                Image(systemName: active ? "xmark" : "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
            .tint(.black)
            .accessibilityLabel(active ? "검색 해제" : "검색")
        }
    }
}

private struct GlassFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    chip(label: item.label, filter: item.filter)
                }
            }
            .padding(4)
            // 칩 내용 폭을 측정해 캡슐을 내용에 맞게 줄인다(인벤 4칩=hug). 가용
            // 폭은 부모 HStack 이 캡하므로 애객 11칩은 그 안에서 스크롤된다.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .frame(maxWidth: contentWidth == 0 ? nil : contentWidth)
        .glassEffect(.regular, in: .capsule)
        // 스크롤 시 선택 칩(파란 배경)이 캡슐의 둥근 양끝 밖으로 새지 않게
        // 콘텐츠를 캡슐 모양으로 클리핑.
        .clipShape(.capsule)
    }

    private struct Item: Identifiable {
        let id: String
        let label: String
        let filter: BoardFilter?
    }

    /// 칩 순서 — 인벤 메이플만 커스텀 순서(10추 · 인방 · 전체 · 30추),
    /// 그 외는 전체 + 보드 필터 순.
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
            .font(.footnote.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selection = filter } }
    }
}
