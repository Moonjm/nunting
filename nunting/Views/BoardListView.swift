import SwiftUI

struct BoardListView: View {
    let board: Board
    var filter: BoardFilter? = nil
    var searchQuery: String? = nil
    var scrollLocked: Bool = false
    let onSelectPost: (Post) -> Void

    @State private var posts: [Post] = []
    @State private var seenIDs: Set<String> = []
    @State private var currentPage: Int = 1
    @State private var hasMorePages: Bool = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
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
            }
        }
        .listStyle(.plain)
        .scrollDisabled(scrollLocked)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func postRow(post: Post) -> some View {
        let isAagag = post.site == .aagag
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelectPost(post) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

            let fresh = parsed.filter { !seenIDs.contains($0.id) }
            if fresh.isEmpty {
                hasMorePages = false
                return
            }
            posts.append(contentsOf: fresh)
            for p in fresh { seenIDs.insert(p.id) }
            currentPage = nextPage
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            // Silently stop paging on error so the user can still keep reading what loaded.
            guard key == taskKey else { return }
            hasMorePages = false
        }
    }
}
