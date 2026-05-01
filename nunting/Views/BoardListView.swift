import SwiftUI

struct BoardListView: View {
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
    let cache: BoardListCache
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskKey) {
            guard loadedKey != taskKey else { return }
            // Stale-while-revalidate: a recent first-page snapshot shows
            // immediately, then a silent background load swaps in fresh
            // content. Cold path (no cache hit) clears state and shows
            // the spinner as before.
            if let cached = cache.get(taskKey: taskKey) {
                posts = cached.posts
                seenIDs = Set(cached.posts.map(\.id))
                currentPage = 1
                hasMorePages = cached.hasMorePages
                nextSearchURL = cached.nextSearchURL
                loadMoreError = false
                errorMessage = nil
                // Clear stale `isLoading` from a cancelled prior task —
                // its `defer` is gated on `key == taskKey` so an
                // in-flight cold load that we just superseded leaves
                // `isLoading = true` behind. Silent revalidate doesn't
                // touch `isLoading`, so without this reset the body's
                // `loadingView` branch could fire later if `posts` ever
                // transiently empties (refresh, filter swap mid-flight).
                isLoading = false
                loadedKey = taskKey
                await load(silent: true)
                return
            }
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

    private func load(silent: Bool = false) async {
        guard !Task.isCancelled else { return }
        // Capture taskKey at the start so a stale fetch (board switched mid-flight)
        // can't overwrite the new task's posts/errorMessage on completion.
        let key = taskKey
        if !silent {
            errorMessage = nil
            isLoading = true
        }
        defer {
            if !silent, key == taskKey {
                isLoading = false
            }
        }
        do {
            let url = board.url(filter: filter, search: searchQuery, page: nil)
            let html = try await fetchListHTML(url: url)
            try Task.checkCancellation()
            let parsed = try await parseListOffMain(html: html, board: board)
            guard key == taskKey else { return }
            // Silent revalidation only owns the first page. If the user has
            // already paginated past it (`currentPage > 1`), keep their
            // merged list — replacing it with a fresh page-1 response would
            // drop the loadMore'd tail and jumble scroll position.
            if silent, currentPage > 1 { return }
            posts = parsed
            seenIDs = Set(parsed.map(\.id))
            currentPage = 1
            nextSearchURL = nextSearchPageURL(from: html)
            hasMorePages = board.supportsPaging && (!parsed.isEmpty || nextSearchURL != nil)
            loadedKey = key
            cache.put(
                taskKey: key,
                posts: parsed,
                hasMorePages: hasMorePages,
                nextSearchURL: nextSearchURL
            )
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            // On silent revalidate, leave the cached list visible — the user
            // already sees something useful and a transient network blip
            // shouldn't surface as an error overlay.
            guard !silent, key == taskKey else { return }
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
