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
                    case .richText(let segments):
                        Text(attributedString(from: segments))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url):
                        CachedAsyncImage(url: url)
                    case .video(let url):
                        InlineVideoPlayer(url: url)
                    case .dealLink(let url, let label):
                        DealLinkBanner(url: url, label: label)
                    case .youtube(let videoID):
                        YouTubeBanner(videoID: videoID)
                    }
                }
            }
        }
    }

    private func attributedString(from segments: [InlineSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let s):
                result.append(AttributedString(s))
            case .link(let url, let label):
                var part = AttributedString(label)
                part.link = url
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
                result.append(part)
            }
        }
        return result
    }

    /// Aagag mirror items have URLs of the form `aagag.com/mirror/re?ss=...`
    /// which 301-redirect to the source site. Resolve and rebuild the post so
    /// the rest of the load pipeline uses the source site's parser/encoding.
    private func resolveDispatchedPost(_ post: Post) async throws -> Post {
        guard post.site == .aagag,
              let host = post.url.host?.lowercased(),
              host.hasSuffix("aagag.com"),
              post.url.path.contains("/re")
        else { return post }

        let resolved = await Networking.resolveFinalURL(post.url)
        guard resolved != post.url, let sourceSite = Site.detect(host: resolved.host)
        else { return post }
        return Post(
            id: post.id,
            site: sourceSite,
            boardID: post.boardID,
            title: post.title,
            author: post.author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: resolved,
            viewCount: post.viewCount,
            recommendCount: post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Aagag mirror items are HTTP redirects to a source site; resolve the
            // target URL and dispatch to the source parser when supported.
            let resolved = try await resolveDispatchedPost(post)
            try Task.checkCancellation()
            let parser = try ParserFactory.parser(for: resolved.site)
            let html = try await Networking.fetchHTML(url: resolved.url, encoding: resolved.site.encoding)
            try Task.checkCancellation()
            var parsed = try parser.parseDetail(html: html, post: resolved)

            // Always run fetchAllComments when the parser provides a comments URL — the
            // default protocol impl returns [] for parsers without a real override (Clien),
            // so detail-page comments survive. Parsers with overrides (Coolenjoy, Inven,
            // Ppomppu) handle pagination authoritatively.
            if parser.commentsURL(for: resolved) != nil {
                let postSite = resolved.site
                let extras = try? await parser.fetchAllComments(for: resolved) { url in
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

private struct YouTubeBanner: View {
    let videoID: String

    private var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoID)")! }
    private var thumbnailURL: URL { URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")! }

    var body: some View {
        Link(destination: watchURL) {
            ZStack(alignment: .center) {
                CachedAsyncImage(url: thumbnailURL, maxDimension: 720)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.red, Color.white)
                    .shadow(radius: 4)

                VStack {
                    HStack {
                        Spacer()
                        Label("YouTube", systemImage: "play.tv")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red, in: Capsule())
                            .padding(8)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text("youtu.be/\(videoID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("YouTube 영상 \(videoID), 외부 앱에서 열기")
    }
}

private struct DealLinkBanner: View {
    let url: URL
    let label: String

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(label)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("딜 링크 \(label), 외부 사이트 열기")
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
                    CachedAsyncImage(url: levelURL, maxDimension: 48)
                        .frame(width: 16, height: 16)
                }
                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)
                if let iconURL = comment.authIconURL {
                    CachedAsyncImage(url: iconURL, maxDimension: 48)
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
                    CachedAsyncImage(url: stickerURL, maxDimension: 280)
                        .frame(maxWidth: 200, maxHeight: 140)
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

        func isMentionBodyChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        for char in text {
            if char == "@" {
                flush()
                inMention = true
                current.append(char)
            } else if inMention && !isMentionBodyChar(char) {
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
