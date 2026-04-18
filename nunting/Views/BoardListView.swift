import SwiftUI

struct BoardListView: View {
    let board: Board
    var filter: BoardFilter? = nil
    var scrollLocked: Bool = false
    let onSelectPost: (Post) -> Void

    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadedKey: String?

    private var taskKey: String {
        "\(board.id)|\(filter?.id ?? "_all")"
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
        List(posts) { post in
            postRow(post: post)
        }
        .listStyle(.plain)
        .scrollDisabled(scrollLocked)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func postRow(post: Post) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.title).font(.body)
            HStack(spacing: 6) {
                Text(post.author)
                if let lv = post.levelText, !lv.isEmpty {
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
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let parser = try ParserFactory.parser(for: board.site)
            let url = board.url(filter: filter)
            let html = try await Networking.fetchHTML(url: url, encoding: board.site.encoding)
            try Task.checkCancellation()
            posts = try parser.parseList(html: html, board: board)
            loadedKey = taskKey
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
