import SwiftUI

struct BoardListView: View {
    let board: Board
    var scrollLocked: Bool = false
    let onSelectPost: (Post) -> Void

    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
        .task(id: board.id) { await load() }
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
            Button {
                onSelectPost(post)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.title).font(.body)
                    HStack(spacing: 8) {
                        Text(post.author)
                        Text(post.dateText)
                        if post.commentCount > 0 {
                            Text("💬 \(post.commentCount)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .scrollDisabled(scrollLocked)
        .refreshable { await load() }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        posts = []
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let parser = try ParserFactory.parser(for: board.site)
            let html = try await Networking.fetchHTML(url: board.url, encoding: board.site.encoding)
            try Task.checkCancellation()
            posts = try parser.parseList(html: html, board: board)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
