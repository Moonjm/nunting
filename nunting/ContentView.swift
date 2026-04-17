import SwiftUI

struct ContentView: View {
    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let board = Board.clienNews
    private let parser = ClienParser()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(board.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && posts.isEmpty {
            ProgressView().controlSize(.large)
        } else if let errorMessage, posts.isEmpty {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            List(posts) { post in
                NavigationLink(value: post) {
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
                }
            }
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post)
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let html = try await Networking.fetchHTML(url: board.url, encoding: board.site.encoding)
            posts = try parser.parseList(html: html, board: board)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    ContentView()
}
