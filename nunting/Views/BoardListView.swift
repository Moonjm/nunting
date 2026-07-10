import SwiftUI
struct BoardListView: View, Equatable {
    let board: Board
    var filter: BoardFilter? = nil
    var searchQuery: String? = nil
    /// 페이저(BoardPager)에서 이 페이지가 현재 선택 페이지인지. 비활성 페이지
    /// (센티널·이웃)는 materialize 돼도 `.task` 가 fetch 를 건너뛴다 — 안 볼
    /// 보드의 목록 fetch + 상세 프리페치 낭비 방지(§3.2). 활성화(도착) 로드는
    /// isActive 플립의 `.task` 재시작 → `loader.activate` 가 단일 경로로 담당
    /// (첫 로드=refresh, 재방문=fresh reload). 페이저 밖 호출부는 기본값 true
    /// — 종전대로 materialize 즉시 로드.
    var isActive: Bool = true
    var scrollLocked: Bool = false
    /// 떠 있는 하단 필터 바가 있을 때, 마지막 글이 그 밑으로 가려지지 않게
    /// 스크롤 콘텐츠 하단에 주는 여백. 바가 없으면 0.
    var bottomContentInset: CGFloat = 0
    /// 헤더 밴드 없는 모음(ArchiveHome)에서 스크롤 콘텐츠 맨 위에 보드명을 라지
    /// 타이틀로 얹을지. 핀 고정이 아니라 첫 콘텐츠 행이라 스크롤하면 함께 밀려
    /// 올라가 사라지고(위로 당기면 재등장), 첫 글 행을 엄지 닿기 쉬운 아래로
    /// 내린다. 내비바가 있는 둘러보기 목록에선 false(이미 내비바 타이틀이 있음).
    var showsBoardNameHeader: Bool = false
    /// 보드명 헤더를 보드 전환 스위처(⌄ 메뉴, Apple News 식)로 쓸 때의 후보 보드
    /// 목록과 선택 콜백 — showsBoardNameHeader 인 모음에서만 채워 넘긴다. 메뉴는
    /// 현재 페이지(board)에 체크를 찍는다. 비면 그냥 라벨만(단일 보드).
    var switchableBoards: [Board] = []
    var onSelectBoard: (String) -> Void = { _ in }
    /// 스위처 메뉴 하단 "보드 순서 편집" 진입 — 호스트가 재정렬 시트를 띄운다.
    var onEditOrder: () -> Void = { }
    /// 모음 탭 재탭 시 부모가 증가시켜 목록을 맨 위로 스크롤하게 한다.
    /// 토큰 패턴 — 값이 바뀐 페이지만 onChange 가 발화한다.
    var scrollTopToken: Int = 0
    /// Returns `true` when `DetailBackDrag` has just observed any
    /// horizontal-dominant movement. Row taps consult this so a tiny `→`
    /// drag that doesn't reach the back-drag commit threshold doesn't fall
    /// through and trigger a row navigation on touch-up.
    var shouldSuppressRowTap: () -> Bool = { false }
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    // PostDetailView 와 동일한 패턴 — `DetailBackDrag` 의 백드래그 중
    // 매 프레임 재평가되고(오버레이 offset 읽기) 그때마다 새
    // closure(shouldSuppressRowTap / onSelectPost)를 만들어 넘긴다. SwiftUI
    // 는 closure 동등성을 판단할 수 없어 매 프레임 이 뷰의 body — 페이징으로
    // 수백 행 쌓인 ForEach diff — 를 재평가한다. diffable 입력만 비교해
    // `.equatable()` 이 그 churn 을 끊는다.
    //
    // `==` 에서 의도적으로 제외:
    // - closures: 탭 시점에만 호출되고 새 셸(`RootTabView`)의 @State 를
    //   out-of-line storage 로 mutate 하므로 첫 평가본을 계속 써도 동작 동일.
    // - `readStore`: @Observable — body 의 `isRead` 읽기는 property 단위
    //   추적으로 무효화되므로 `==` 가 true 여도 변경이 전파됨.
    static func == (lhs: BoardListView, rhs: BoardListView) -> Bool {
        lhs.board == rhs.board
            && lhs.filter == rhs.filter
            && lhs.searchQuery == rhs.searchQuery
            // isActive 누락 금지 — .equatable() 이 body 재평가를 끊으므로,
            // 빠지면 활성화 플립이 전파되지 않아 페이지가 placeholder 에 갇힌다.
            && lhs.isActive == rhs.isActive
            && lhs.scrollLocked == rhs.scrollLocked
            && lhs.bottomContentInset == rhs.bottomContentInset
            && lhs.showsBoardNameHeader == rhs.showsBoardNameHeader
            && lhs.switchableBoards == rhs.switchableBoards
            && lhs.scrollTopToken == rhs.scrollTopToken
    }

    // 스크롤어웨이 보드명 헤더의 스크롤 타깃 id — 맨 위 스크롤 시 이 헤더로.
    private static let boardNameHeaderID = "board-name-header"

    /// `.task(id:)` 의 키 — 요청 키에 활성 상태를 접합해, 활성화 플립이 task
    /// 재시작(=지연 로드 기회)이 되게 한다. static 이라 계약을 단위 테스트로 핀.
    nonisolated static func taskID(key: String, isActive: Bool) -> String {
        isActive ? key + "|active" : key
    }

    @State private var loader = BoardListLoader()

    var body: some View {
        Group {
            if !isActive && loader.posts.isEmpty {
                // 비활성 페이지는 fetch 를 안 했으므로 빈 목록이 정상 — 드래그로
                // 살짝 노출될 때 "글이 없습니다" 로 오표시하지 않고 스피너.
                // 활성화(도착)되면 .task 재시작(activate)이 스피너를 이어받는다.
                loadingView
            } else if loader.isLoading && loader.posts.isEmpty {
                loadingView
            } else if let errorMessage = loader.errorMessage, loader.posts.isEmpty {
                ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if loader.posts.isEmpty {
                if let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !query.isEmpty {
                    ContentUnavailableView(
                        "검색 결과가 없어요",
                        systemImage: "magnifyingglass",
                        description: Text("'\(query)'에 대한 글을 찾지 못했어요.")
                    )
                } else {
                    ContentUnavailableView("글이 없습니다", systemImage: "doc.text")
                }
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // id 에 활성 상태 포함 — 활성화(false→true)가 task 를 재시작시켜
        // `activate` 를 부른다. 이 task 가 도착 로딩의 **유일한** 경로다:
        // 종전의 reloadToken bump 경로와 병행하면 첫 방문 보드가 두 번
        // fetch 됐다(Codex P2, 토큰 메커니즘 자체를 제거). 재방문 도착은
        // activate 내부에서 fresh reload 로 처리("전환은 항상 새로 로드").
        // 비활성화 시엔 떠나는 페이지의 in-flight 로드/프리페치가 취소된다
        // (의도 — "이전 보드 prefetch 중단"과 동일). 센티널·이웃 페이지는
        // materialize 돼도 guard 가 fetch 를 건너뛴다.
        .task(id: Self.taskID(
            key: BoardListLoader.taskKey(board: board, filter: filter, searchQuery: searchQuery),
            isActive: isActive
        )) {
            guard isActive else { return }
            await loader.activate(board: board, filter: filter, searchQuery: searchQuery)
            // 목록이 자리잡은 뒤 상위 글 detail HTML 을 .utility 로 워밍 —
            // 탭 시 RTT 제거. 보드 전환 시 .task(id:) 취소가 그대로 전파돼
            // 이전 보드 prefetch 는 중단된다.
            await DetailPrefetcher.shared.prefetch(posts: Array(loader.posts.prefix(3)))
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var listView: some View {
        ScrollViewReader { proxy in
        List {
            if showsBoardNameHeader {
                // 스크롤어웨이 보드명 = 보드 전환 스위처(Apple News/Reddit 식).
                // 리스트 첫 콘텐츠 행이라 스크롤 시 함께 밀려 사라지고, 쉬는 위치
                // 에선 첫 글을 아래로 내려 한손 도달 개선. ⌄ 탭 → 모음 보드 목록
                // 메뉴(현재 페이지 보드에 체크).
                Menu {
                    ForEach(switchableBoards) { b in
                        Button { onSelectBoard(b.id) } label: {
                            if b.id == board.id {
                                Label(b.name, systemImage: "checkmark")
                            } else {
                                Text(b.name)
                            }
                        }
                    }
                    Divider()
                    Button { onEditOrder() } label: {
                        Label("보드 순서 편집", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(board.site.accentColor)
                            .frame(width: 8, height: 8)
                        Text(board.name)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                // Menu 기본 accent 틴트(파란 글씨) 대신 라벨을 내가 지정한 색으로.
                .tint(.primary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 14, trailing: 20))
                .listRowSeparator(.hidden)
                // 행 배경을 흰색(기본) 대신 투명 처리 — 뒤 AppSurface 가 비쳐 글
                // 행들과 일체.
                .listRowBackground(Color.clear)
                .id(Self.boardNameHeaderID)
            }
            ForEach(loader.posts) { post in
                postRow(post: post)
                    .onAppear {
                        if board.supportsPaging,
                           loader.hasMorePages,
                           !loader.isLoadingMore,
                           !loader.loadMoreError,
                           !isInvenSearch,
                           post.id == loader.posts.last?.id {
                            Task { await loader.loadMore(board: board, filter: filter, searchQuery: searchQuery) }
                        }
                    }
            }
            if loader.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.regular)
                    Spacer()
                }
                .padding(.vertical, 12)
                .listRowSeparator(.hidden)
                // 글 행과 동일한 배경 — 기본(흰색) 행 배경이면 페이징 중
                // 스피너 행이 흰 띠로 번쩍인다.
                .listRowBackground(Color("AppSurface"))
                .onAppear {
                    guard board.supportsPaging,
                          loader.hasMorePages,
                          !loader.isLoadingMore,
                          !loader.loadMoreError
                    else { return }
                    Task { await loader.loadMore(board: board, filter: filter, searchQuery: searchQuery) }
                }
            } else if loader.loadMoreError {
                Button {
                    Task { await loader.loadMore(board: board, filter: filter, searchQuery: searchQuery) }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                        Text("불러오지 못했습니다 · 다시 시도")
                        Spacer()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color("AppSurface"))
            } else if shouldShowLoadMorePrompt {
                Button {
                    Task { await loader.loadMore(board: board, filter: filter, searchQuery: searchQuery) }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                        Text("다음 검색 더 보기")
                        Spacer()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color("AppSurface"))
            }
        }
        .listStyle(.plain)
        // 떠 있는 필터 바만큼 스크롤 콘텐츠 하단에 여백 — 바는 레이아웃에
        // 영향 주지 않는 overlay 라, 가림 방지는 이 인셋이 담당한다.
        .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        // List background no longer needs `.ignoresSafeArea()` — the
        // `Color("AppSurface").ignoresSafeArea()` fill in the host shell
        // (`ArchiveHome` / `RootTabView`) already covers every safe-area
        // band, so a
        // second extending background here is redundant *and* was the
        // race trigger that let `contentInset.bottom` settle at 0 on
        // late `loadingView → listView` body swaps. With the bar moved
        // to `.safeAreaInset(.bottom)`, this is just cosmetic — keep
        // the AppSurface fill for the rows-area, drop the extension.
        .background(Color("AppSurface"))
        .scrollDisabled(scrollLocked)
        .refreshable {
            await loader.reload(board: board, filter: filter, searchQuery: searchQuery)
        }
        // 모음 탭 재탭 신호 → 첫 글로 맨 위 스크롤(같은 보드라 reload 없음).
        // 보이지 않는(다른 보드) 페이지도 발화하지만 무해하고, 빈 목록은
        // 스크롤 대상이 없어 no-op. (보드 전환은 activate 의 목록-비움이
        // 자연히 맨 위에서 다시 그리므로 여기서 따로 스크롤하지 않는다.)
        .onChange(of: scrollTopToken) { _, _ in
            // 헤더가 있으면 헤더까지(보드명 재노출) 맨 위로, 없으면 첫 글로.
            if showsBoardNameHeader {
                withAnimation { proxy.scrollTo(Self.boardNameHeaderID, anchor: .top) }
            } else if let firstID = loader.posts.first?.id {
                withAnimation { proxy.scrollTo(firstID, anchor: .top) }
            }
        }
        }
    }

    /// Inven search results expose a "다음 검색 더 보기" link that the
    /// loader follows via `nextSearchURL`. The list shows a tap-to-load
    /// prompt rather than auto-paging because inven search pages
    /// frequently overlap and auto-chaining can burst the network.
    private var shouldShowLoadMorePrompt: Bool {
        board.site == .inven && loader.hasNextSearchPage && loader.hasMorePages
    }

    /// Inven search results require a tap-to-load-more flow rather than
    /// the scroll-triggered auto-paging used elsewhere, so duplicate-
    /// heavy pages can't chain into a runaway burst of background
    /// requests.
    private var isInvenSearch: Bool {
        board.site == .inven
            && searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private func postRow(post: Post) -> some View {
        let isAagag = post.site == .aagag
        let isRead = readStore.isRead(post)
        postRowContent(post: post, isAagag: isAagag, isRead: isRead)
            .listRowBackground(Color("AppSurface"))
    }

    @ViewBuilder
    private func postRowContent(post: Post, isAagag: Bool, isRead: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isAagag, let lv = post.levelText, !lv.isEmpty {
                        AagagSourceTag(code: lv)
                    }
                    Text(post.title).font(.body)
                }
                HStack(spacing: 6) {
                    Text(post.author)
                    if !isAagag, let lv = post.levelText, !lv.isEmpty {
                        Text(lv)
                    }
                    Text(post.dateText)
                    if let views = post.viewCount {
                        Text("조회 \(views)")
                    }
                    if let recos = post.recommendCount, recos > 0 {
                        Text("추천 \(recos)").foregroundStyle(.pink)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if post.commentCount > 0 {
                commentBadge(count: post.commentCount)
            }
        }
        .opacity(isRead ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if shouldSuppressRowTap() { return }
            onSelectPost(post)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isRead ? "읽음" : "")
    }

    @ViewBuilder
    private func commentBadge(count: Int) -> some View {
        let tint = commentBadgeTint(for: count)
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(minWidth: 20)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .foregroundStyle(tint)
            .accessibilityLabel("댓글 \(count)개")
    }

    private func commentBadgeTint(for count: Int) -> Color {
        switch count {
        case ..<10: return .gray
        case 10..<30: return .blue
        case 30..<60: return .orange
        default: return .red
        }
    }
}
