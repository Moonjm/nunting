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
            if loadedKey != taskKey {
                posts = []
                seenIDs = []
                currentPage = 1
                hasMorePages = true
                loadMoreError = false
                errorMessage = nil
            }
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
            }
        }
        .listStyle(.plain)
        .scrollDisabled(scrollLocked)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func postRow(post: Post) -> some View {
        let isAagag = post.site == .aagag
        let isRead = readStore.isRead(post)
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
        .onTapGesture { onSelectPost(post) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
            let parser = try ParserFactory.parser(for: board.site)
            let url = board.url(filter: filter, search: searchQuery, page: nil)
            let html = try await Networking.fetchHTML(url: url, encoding: board.site.encoding)
            try Task.checkCancellation()
            let parsed = try parser.parseList(html: html, board: board)
            guard key == taskKey else { return }
            posts = parsed
            seenIDs = Set(parsed.map(\.id))
            currentPage = 1
            hasMorePages = board.supportsPaging && !parsed.isEmpty
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
            let parser = try ParserFactory.parser(for: board.site)
            let url = board.url(filter: filter, search: searchQuery, page: nextPage)
            let html = try await Networking.fetchHTML(url: url, encoding: board.site.encoding)
            try Task.checkCancellation()
            let parsed = try parser.parseList(html: html, board: board)
            guard key == taskKey else { return }

            // Insert into seenIDs *during* the filter so an intra-page duplicate
            // (e.g. parsed = [A, A, B]) only appends once.
            var fresh: [Post] = []
            for p in parsed where seenIDs.insert(p.id).inserted {
                fresh.append(p)
            }
            if fresh.isEmpty {
                hasMorePages = false
                return
            }
            posts.append(contentsOf: fresh)
            currentPage = nextPage
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
}
