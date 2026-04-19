import SwiftUI

struct PostDetailView: View {
    let post: Post
    let readStore: ReadStore

    @State private var detail: PostDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedImage: ImageViewerItem?

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
                    CommentsSection(
                        comments: comments,
                        onImageTap: { url in selectedImage = ImageViewerItem(url: url) }
                    )
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
        .task(id: post.id) {
            readStore.markRead(post)
            await load()
        }
        .fullScreenCover(item: $selectedImage) { item in
            ImageViewer(url: item.url)
        }
    }

    @ViewBuilder
    private var articleContent: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if let errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let detail {
            // Lazy so only the blocks near the viewport materialise — keeps
            // image-heavy posts from kicking off ~20 simultaneous fetches and
            // decode passes the moment the screen opens.
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(detail.blocks) { block in
                    switch block.kind {
                    case .richText(let segments):
                        Text(attributedString(from: segments))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url):
                        CachedAsyncImage(url: url)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedImage = ImageViewerItem(url: url)
                            }
                    case .video(let url):
                        InlineVideoPlayer(url: url)
                    case .dealLink(let url, let label):
                        DealLinkBanner(url: url, label: label)
                    case .embed(.youtube, let id):
                        YouTubeBanner(videoID: id)
                    case .embed(.instagram, let id):
                        if let url = URL(string: "https://www.instagram.com/p/\(id)/") {
                            DealLinkBanner(url: url, label: "Instagram 게시물 보기")
                        }
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

    private enum Dispatch {
        /// Use the given Post with its site's parser. Optional prefetched body
        /// is the GET response captured by `resolveFinalURL` (avoids re-fetch).
        case parser(Post, prefetched: Data?)
        /// Resolved redirect points at a site we don't parse; render an
        /// external-link banner and skip the parser pipeline.
        case external(URL)
    }

    /// Aagag mirror items have URLs of the form `aagag.com/mirror/re?ss=...`
    /// which 301-redirect to the source site. Resolve and decide how to load:
    /// dispatch to a source parser if we recognise the host, else surface a
    /// "외부 사이트로 이동" banner.
    private func resolveDispatchedPost(_ post: Post) async throws -> Dispatch {
        guard post.site == .aagag,
              let host = post.url.host?.lowercased(),
              host.hasSuffix("aagag.com"),
              post.url.path.hasSuffix("/re") || post.url.path.hasSuffix("/mirror/re")
        else { return .parser(post, prefetched: nil) }

        let resolved = await Networking.resolveFinalURL(post.url)
        guard resolved.url != post.url else {
            return .parser(post, prefetched: nil)
        }
        guard let sourceSite = Site.detect(host: resolved.url.host) else {
            return .external(resolved.url)
        }
        let dispatched = Post(
            id: post.id,
            site: sourceSite,
            boardID: post.boardID,
            title: post.title,
            author: post.author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: resolved.url,
            viewCount: post.viewCount,
            recommendCount: post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )
        return .parser(dispatched, prefetched: resolved.prefetchedBody)
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Aagag mirror items are HTTP redirects to a source site; resolve the
            // target URL and dispatch to the source parser when supported.
            let dispatch = try await resolveDispatchedPost(post)
            try Task.checkCancellation()

            switch dispatch {
            case .external(let externalURL):
                detail = PostDetail(
                    post: post,
                    blocks: [.dealLink(externalURL, label: "외부 사이트로 이동: \(externalURL.host ?? externalURL.absoluteString)")],
                    fullDateText: post.dateText,
                    viewCount: post.viewCount,
                    source: nil,
                    comments: []
                )
                return

            case .parser(let resolved, let prefetched):
                let parser = try ParserFactory.parser(for: resolved.site)
                let html: String
                if let prefetched {
                    html = Networking.decodeHTML(data: prefetched, encoding: resolved.site.encoding)
                } else {
                    html = try await Networking.fetchHTML(url: resolved.url, encoding: resolved.site.encoding)
                }
                try Task.checkCancellation()
                // Run the heavy SwiftSoup parse + per-chunk text stripping off
                // the main actor so opening an image-heavy post doesn't freeze
                // the scroll for hundreds of milliseconds.
                let parsedHTML = html
                let parsedPost = resolved
                var parsed = try await Task.detached(priority: .userInitiated) {
                    try parser.parseDetail(html: parsedHTML, post: parsedPost)
                }.value

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
            }
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
                // Branded gradient backstop so layout stays intact when the
                // thumbnail 404s (e.g. very new uploads, age-restricted, deleted).
                LinearGradient(
                    colors: [Color.red.opacity(0.55), Color.black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
    let onImageTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("댓글")
                    .font(.headline)
                Text("\(comments.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // LazyVStack so off-screen comments don't kick off markdown
            // parses / image fetches / AVPlayer setup at the same time the
            // user is trying to scroll the top of a long thread.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    CommentRow(comment: comment, onImageTap: onImageTap)
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
    let onImageTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let levelURL = comment.levelIconURL {
                    CachedAsyncImage(url: levelURL, maxDimension: 48, showsPlaceholder: false)
                        .frame(width: 16, height: 16)
                }
                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)
                if let iconURL = comment.authIconURL {
                    CachedAsyncImage(url: iconURL, maxDimension: 48, showsPlaceholder: false)
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
            if let videoURL = comment.videoURL {
                HStack(spacing: 0) {
                    InlineVideoPlayer(url: videoURL)
                        .frame(maxWidth: 320, maxHeight: 240)
                    Spacer(minLength: 0)
                }
            } else if let stickerURL = comment.stickerURL {
                HStack(spacing: 0) {
                    CachedAsyncImage(url: stickerURL, maxDimension: 280)
                        .frame(maxWidth: 200, maxHeight: 140)
                        .contentShape(Rectangle())
                        .onTapGesture { onImageTap(stickerURL) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, comment.isReply ? 20 : 0)
    }

    private func styledContent(_ text: String) -> AttributedString {
        // First parse markdown so any `[label](<url>)` anchors that the
        // parser preserved become real `.link` spans. Falls back to plain
        // text if the parser rejects the input. Then apply the @mention
        // coloring on top of whatever the markdown parser produced.
        var base: AttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            base = attributed
        } else {
            base = AttributedString(text)
        }

        // Apply consistent link styling so embedded URLs are visibly tappable.
        for run in base.runs {
            if run.link != nil {
                base[run.range].foregroundColor = .accentColor
                base[run.range].underlineStyle = .single
            }
        }

        // Highlight `@nickname` mentions. Walks the plain-string view of the
        // attributed result so we don't have to re-parse the original input.
        let plain = String(base.characters)
        var mentionRanges: [Range<String.Index>] = []
        var i = plain.startIndex
        while i < plain.endIndex {
            guard plain[i] == "@" else {
                i = plain.index(after: i)
                continue
            }
            var end = plain.index(after: i)
            while end < plain.endIndex,
                  plain[end].isLetter || plain[end].isNumber || plain[end] == "_" {
                end = plain.index(after: end)
            }
            if end > plain.index(after: i) {
                mentionRanges.append(i..<end)
            }
            i = end
        }
        for range in mentionRanges {
            if let attrRange = Range(range, in: base) {
                base[attrRange].foregroundColor = .blue
                base[attrRange].font = .subheadline.bold()
            }
        }
        return base
    }
}
