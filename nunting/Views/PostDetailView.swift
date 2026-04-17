import SwiftUI

struct PostDetailView: View {
    let post: Post

    @State private var detail: PostDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(post.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Text(post.author)
                    Text(detail?.fullDateText ?? post.dateText)
                    if let views = detail?.viewCount {
                        Text("👁 \(views)")
                    }
                    if post.commentCount > 0 {
                        Text("💬 \(post.commentCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                content
            }
            .padding()
        }
        .navigationTitle(post.site.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: post.url) {
                    Image(systemName: "safari")
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if let errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let detail {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.blocks) { block in
                    switch block {
                    case .text(let text):
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url):
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                            case .failure:
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 80)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let html = try await Networking.fetchHTML(url: post.url, encoding: post.site.encoding)
            let parser = ClienParser()
            detail = try parser.parseDetail(html: html, post: post)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
