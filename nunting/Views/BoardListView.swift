import SwiftUI
struct BoardListView: View, Equatable {
    let board: Board
    var filter: BoardFilter? = nil
    var searchQuery: String? = nil
    var scrollLocked: Bool = false
    /// Returns `true` when ContentView's panGesture has just observed any
    /// horizontal-dominant movement. Row taps consult this so a tiny `→`
    /// drag that doesn't reach the drawer commit threshold doesn't fall
    /// through and trigger a row navigation on touch-up.
    var shouldSuppressRowTap: () -> Bool = { false }
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    // PostDetailView 와 동일한 패턴 — ContentView 는 드로어/백 드래그 중
    // 매 프레임 재평가되고(drawerProgress / detail.offset 읽기) 그때마다 새
    // closure(shouldSuppressRowTap / onSelectPost)를 만들어 넘긴다. SwiftUI
    // 는 closure 동등성을 판단할 수 없어 매 프레임 이 뷰의 body — 페이징으로
    // 수백 행 쌓인 ForEach diff — 를 재평가한다. diffable 입력만 비교해
    // `.equatable()` 이 그 churn 을 끊는다.
    //
    // `==` 에서 의도적으로 제외:
    // - closures: 탭 시점에만 호출되고 ContentView 의 @State 를 out-of-line
    //   storage 로 mutate 하므로 첫 평가본을 계속 써도 동작 동일.
    // - `readStore`: @Observable — body 의 `isRead` 읽기는 property 단위
    //   추적으로 무효화되므로 `==` 가 true 여도 변경이 전파됨.
    static func == (lhs: BoardListView, rhs: BoardListView) -> Bool {
        lhs.board == rhs.board
            && lhs.filter == rhs.filter
            && lhs.searchQuery == rhs.searchQuery
            && lhs.scrollLocked == rhs.scrollLocked
    }

    @State private var loader = BoardListLoader()

    var body: some View {
        Group {
            if loader.isLoading && loader.posts.isEmpty {
                loadingView
            } else if let errorMessage = loader.errorMessage, loader.posts.isEmpty {
                ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if loader.posts.isEmpty {
                ContentUnavailableView("글이 없습니다", systemImage: "doc.text")
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: BoardListLoader.taskKey(board: board, filter: filter, searchQuery: searchQuery)) {
            await loader.refresh(board: board, filter: filter, searchQuery: searchQuery)
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
        List {
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
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // List background no longer needs `.ignoresSafeArea()` — the
        // ZStack's bottom-most `Color("AppSurface").ignoresSafeArea()`
        // (ContentView.body) already covers every safe-area band, so a
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
