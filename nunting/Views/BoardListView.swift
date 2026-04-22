import SwiftUI

struct BoardListView: View {
    let board: Board
    var filter: BoardFilter? = nil
    var searchQuery: String? = nil
    var scrollLocked: Bool = false
    let readStore: ReadStore
    let onSelectPost: (Post) -> Void

    @State private var posts: [Post] = []
    @State private var seenIDs: Set<String> = []
    @State private var currentPage: Int = 1
    @State private var hasMorePages: Bool = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadMoreError: Bool = false
    @State private var errorMessage: String?
    @State private var loadedKey: String?
    @State private var nextSearchURL: URL?

    private var taskKey: String {
        "\(board.id)|\(filter?.id ?? "_all")|\(searchQuery ?? "")"
    }

    var body: some View {
        Group {
            if isLoading && posts.isEmpty {
                loadingView
            } else if let errorMessage, posts.isEmpty {
                ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if posts.isEmpty {
                ContentUnavailableView("글이 없습니다", systemImage: "doc.text")
            } else {
                listView
            }
        }
        .task(id: taskKey) {
            guard loadedKey != taskKey else { return }
            posts = []
            seenIDs = []
            currentPage = 1
            hasMorePages = true
            loadMoreError = false
            errorMessage = nil
            nextSearchURL = nil
            await load()
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
            ForEach(posts) { post in
                postRow(post: post)
                    .onAppear {
                        if board.supportsPaging,
                           hasMorePages,
                           !isLoadingMore,
                           !loadMoreError,
                           !isInvenSearch,
                           post.id == posts.last?.id {
                            Task { await loadMore() }
                        }
                    }
            }
            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.regular)
                    Spacer()
                }
                .padding(.vertical, 12)
                .listRowSeparator(.hidden)
                .onAppear {
                    guard board.supportsPaging,
                          hasMorePages,
                          !isLoadingMore,
                          !loadMoreError
                    else { return }
                    Task { await loadMore() }
                }
            } else if loadMoreError {
                Button {
                    Task { await loadMore() }
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
                    Task { await loadMore() }
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
        .background(Color("AppSurface"))
        .scrollDisabled(scrollLocked)
        .refreshable { await load() }
    }

    private var shouldShowLoadMorePrompt: Bool {
        board.site == .inven && nextSearchURL != nil && hasMorePages
    }

    /// Inven search results require a tap-to-load-more flow rather than the
    /// scroll-triggered auto-paging used elsewhere, so duplicate-heavy pages
    /// can't chain into a runaway burst of background requests.
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
                if post.commentCount > 0 {
                    Text("💬 \(post.commentCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .opacity(isRead ? 0.45 : 1.0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Tap-vs-drag discrimination: a `DragGesture(minimumDistance: 0)`
        // captures the touch-down/touch-up cycle, and we only treat it as
        // a row tap when the finger barely moved (≤ 6pt in either axis).
        // This aligns with the parent `panGesture` in ContentView which
        // locks `dragDirection = .horizontal` at ~10pt — so any drag that
        // reaches the gesture's commit threshold (drawer open / detail
        // forward-reveal) is past our tap threshold here, eliminating the
        // accidental row tap during a `→` drawer-open swipe. Bare
        // `.onTapGesture` and the previous `Button` wrapper both fired
        // even when the parent gesture had already taken over.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onEnded { value in
                    if abs(value.translation.width) < 6
                        && abs(value.translation.height) < 6 {
                        onSelectPost(post)
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelectPost(post) }
        .accessibilityValue(isRead ? "읽음" : "")
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        // Capture taskKey at the start so a stale fetch (board switched mid-flight)
        // can't overwrite the new task's posts/errorMessage on completion.
        let key = taskKey
        errorMessage = nil
        isLoading = true
        defer {
            if key == taskKey {
                isLoading = false
            }
        }
        do {
            let url = board.url(filter: filter, search: searchQuery, page: nil)
            let html = try await fetchListHTML(url: url)
            try Task.checkCancellation()
            let parsed = try await parseListOffMain(html: html, board: board)
            guard key == taskKey else { return }
            posts = parsed
            seenIDs = Set(parsed.map(\.id))
            currentPage = 1
            nextSearchURL = nextSearchPageURL(from: html)
            hasMorePages = board.supportsPaging && (!parsed.isEmpty || nextSearchURL != nil)
            loadedKey = key
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard key == taskKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard board.supportsPaging, hasMorePages, !isLoadingMore else { return }
        let key = taskKey
        let nextPage = currentPage + 1
        loadMoreError = false
        isLoadingMore = true
        defer {
            if key == taskKey {
                isLoadingMore = false
            }
        }
        do {
            let url = nextSearchURL ?? board.url(filter: filter, search: searchQuery, page: nextPage)
            let html = try await fetchListHTML(url: url)
            try Task.checkCancellation()
            let parsed = try await parseListOffMain(html: html, board: board)
            guard key == taskKey else { return }
            let loadedSearchURL = nextSearchURL
            nextSearchURL = nextSearchPageURL(from: html)

            // Insert into seenIDs *during* the filter so an intra-page duplicate
            // (e.g. parsed = [A, A, B]) only appends once.
            var fresh: [Post] = []
            for p in parsed where seenIDs.insert(p.id).inserted {
                fresh.append(p)
            }
            if fresh.isEmpty {
                hasMorePages = nextSearchURL != nil
                return
            }
            posts.append(contentsOf: fresh)
            currentPage = loadedSearchURL == nil ? nextPage : 1
            hasMorePages = if loadedSearchURL != nil {
                nextSearchURL != nil
            } else {
                board.supportsPaging && (nextSearchURL != nil || !fresh.isEmpty)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            // Surface a "다시 시도" footer so users can retry without losing scroll
            // position. `hasMorePages` stays true so the retry button can fire loadMore.
            guard key == taskKey else { return }
            loadMoreError = true
        }
    }

    private func parseListOffMain(html: String, board: Board) async throws -> [Post] {
        try await Task.detached(priority: .userInitiated) {
            let parser = try ParserFactory.parser(for: board.site)
            return try parser.parseList(html: html, board: board)
        }.value
    }

    private func fetchListHTML(url: URL) async throws -> String {
        do {
            return try await Networking.fetchHTML(url: url, encoding: board.site.encoding)
        } catch NetworkError.badResponse(400)
            where board.site == .clien && searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // Clien's /service/search returns HTTP 400 when the shared session
            // cookie carries residual state from a prior search (sort/boardCd
            // sticky values). A clean, cookieless request recovers.
            return try await Networking.fetchHTML(
                url: url,
                encoding: board.site.encoding,
                userAgent: Networking.userAgent,
                handlesCookies: false
            )
        }
    }

    private func nextSearchPageURL(from html: String) -> URL? {
        guard board.site == .inven,
              searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        let pattern = #"<a\s+href="([^"]*sterm=[^"]*)"\s+class="search-total""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }

        let href = String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: href, relativeTo: board.site.baseURL)?.absoluteURL
    }
}
