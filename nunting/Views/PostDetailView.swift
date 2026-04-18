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

                if let source = detail?.source {
                    SourceBanner(source: source)
                }

                Divider()

                articleContent

                if let comments = detail?.comments, !comments.isEmpty {
                    CommentsSection(comments: comments)
                        .padding(.top, 8)
                }
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
        .task(id: post.id) { await load() }
    }

    @ViewBuilder
    private var articleContent: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if let errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let detail {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.blocks) { block in
                    switch block.kind {
                    case .text(let text):
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url):
                        CachedAsyncImage(url: url)
                    case .video(let url):
                        InlineVideoPlayer(url: url)
                    }
                }
            }
        }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let parser = try ParserFactory.parser(for: post.site)
            let html = try await Networking.fetchHTML(url: post.url, encoding: post.site.encoding)
            try Task.checkCancellation()
            var parsed = try parser.parseDetail(html: html, post: post)

            if parsed.comments.isEmpty, parser.commentsURL(for: post) != nil {
                let postSite = post.site
                let extras = try? await parser.fetchAllComments(for: post) { url in
                    try await Networking.fetchHTML(url: url, encoding: postSite.encoding)
                }
                if let extras, !extras.isEmpty {
                    parsed = PostDetail(
                        post: parsed.post,
                        blocks: parsed.blocks,
                        fullDateText: parsed.fullDateText,
                        viewCount: parsed.viewCount,
                        source: parsed.source,
                        comments: extras
                    )
                }
            }

            detail = parsed
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SourceBanner: View {
    let source: PostSource

    var body: some View {
        Link(destination: source.url) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text("출처").font(.caption2).foregroundStyle(.secondary)
                    Text(source.name).font(.callout).fontWeight(.medium)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("출처 \(source.name), 외부 사이트 열기")
    }
}

private struct CommentsSection: View {
    let comments: [Comment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("댓글")
                    .font(.headline)
                Text("\(comments.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    CommentRow(comment: comment)
                    if index < comments.count - 1 {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let levelURL = comment.levelIconURL {
                    AsyncImage(url: levelURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)
                if let iconURL = comment.authIconURL {
                    AsyncImage(url: iconURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                Text(comment.dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if comment.likeCount > 0 {
                    Label("\(comment.likeCount)", systemImage: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                }
            }
            if !comment.content.isEmpty {
                Text(styledContent(comment.content))
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let stickerURL = comment.stickerURL {
                HStack(spacing: 0) {
                    AsyncImage(url: stickerURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 140)
                        case .empty:
                            ProgressView().frame(width: 100, height: 100)
                        case .failure:
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                                .frame(width: 80, height: 80)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, comment.isReply ? 20 : 0)
    }

    private func styledContent(_ text: String) -> AttributedString {
        var result = AttributedString()
        var current = ""
        var inMention = false

        func flush() {
            guard !current.isEmpty else { return }
            var part = AttributedString(current)
            if inMention {
                part.foregroundColor = .blue
                part.font = .subheadline.bold()
            }
            result.append(part)
            current = ""
        }

        for char in text {
            if char == "@" {
                flush()
                inMention = true
                current.append(char)
            } else if inMention && char.isWhitespace {
                flush()
                inMention = false
                current.append(char)
            } else {
                current.append(char)
            }
        }
        flush()
        return result
    }
}
