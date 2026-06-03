import SwiftUI
import UIKit

struct PostDetailCommentsSection: View {
    let comments: [PostComment]
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void
    let onVideoDismissBegin: () -> Void

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
            // parses / image fetches / AVPlayer setup at the same time
            // the user is trying to scroll the top of a long thread.
            // Back-drag is a SwiftUI `.offset(x:)` transform rather than
            // a SwiftUI layout op, so contentSize churn as new rows
            // materialise doesn't bleed into the drag position either.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    PostDetailCommentRow(
                        comment: comment,
                        tapGate: tapGate,
                        onImageTap: onImageTap,
                        onVideoDismissBegin: onVideoDismissBegin
                    )
                    if index < comments.count - 1 {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

struct PostDetailCommentRow: View {
    let comment: PostComment
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void
    let onVideoDismissBegin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let levelURL = comment.levelIconURL {
                    NetworkImage(url: levelURL, thumbnailMaxPointSize: 48, showsPlaceholder: false)
                        .frame(width: 16, height: 16)
                }
                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)
                if let iconURL = comment.authIconURL {
                    NetworkImage(url: iconURL, thumbnailMaxPointSize: 48, showsPlaceholder: false)
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
            let display = displayContent(for: comment)
            if !display.characters.isEmpty {
                SelectableRichText(
                    attributedString: display,
                    font: .preferredFont(forTextStyle: .subheadline)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let videoURL = comment.videoURL {
                HStack(spacing: 0) {
                    InlineVideoPlayer(
                        url: videoURL,
                        tapGate: tapGate,
                        onDismissBegin: onVideoDismissBegin
                    )
                        .frame(maxWidth: 320, maxHeight: 240)
                    Spacer(minLength: 0)
                }
            } else if let stickerURL = comment.stickerURL {
                HStack(spacing: 0) {
                    NetworkImage(url: stickerURL, thumbnailMaxPointSize: 280)
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

    /// Wraps `AttributedString` so it can live in `NSCache`, which only
    /// stores `AnyObject` values.
    private final class StyledBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Memoizes `computeStyledContent` keyed by the raw comment string.
    /// Output is a pure function of the input, so two comments with the
    /// same text reuse the same parse. NSCache handles eviction under
    /// memory pressure and bounds steady-state size via `countLimit`,
    /// which keeps long-running sessions from accumulating every comment
    /// the user has scrolled past.
    private static let styledCache: NSCache<NSString, StyledBox> = {
        let cache = NSCache<NSString, StyledBox>()
        cache.countLimit = 1000
        return cache
    }()

    private func styledContent(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = Self.styledCache.object(forKey: key) {
            return cached.value
        }
        let result = Self.computeStyledContent(text)
        Self.styledCache.setObject(StyledBox(result), forKey: key)
        return result
    }

    /// 본문 styled content 앞에 답글 대상 멘션(`@이름`, 파란 볼드)을 붙인다.
    /// SLR 처럼 대상이 구조화 필드(`replyTarget`)로 오는 경우 — 본문 텍스트
    /// 스캔(`@`+영숫자)으로는 특수문자 닉네임이 잘리므로 여기서 정확히 렌더.
    /// 뽐뿌(본문에 `@닉` 이 박혀 스캔으로 강조)와 외형이 동일해진다.
    private func displayContent(for comment: PostComment) -> AttributedString {
        var styled = comment.content.isEmpty ? AttributedString() : styledContent(comment.content)
        guard let target = comment.replyTarget, !target.isEmpty else { return styled }

        var mention = AttributedString(styled.characters.isEmpty ? "@\(target)" : "@\(target) ")
        mention.uiKit.foregroundColor = .systemBlue
        mention.uiKit.font = Self.mentionFont
        return mention + styled
    }

    /// 멘션(@닉) 강조용 볼드 폰트. computeStyledContent 와 displayContent 가 공유.
    static let mentionFont: UIFont = {
        let baseFont = UIFont.preferredFont(forTextStyle: .subheadline)
        if let desc = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: desc, size: 0)
        }
        return baseFont
    }()

    private static func computeStyledContent(_ text: String) -> AttributedString {
        // First parse markdown so any `[label](<url>)` anchors that the
        // parser preserved become real `.link` spans. Falls back to plain
        // text if the parser rejects the input. Then apply the @mention
        // coloring on top of whatever the markdown parser produced.
        //
        // Escape `~` before parsing so range notations like "1995~1996"
        // don't trigger the markdown parser's strikethrough handling
        // (which consumed the tilde and rendered the trailing digits with
        // a line through them — Aagag comments use `~` for ranges/aliases
        // far more often than they use intentional strikethrough).
        let escaped = text.replacingOccurrences(of: "~", with: "\\~")
        var base: AttributedString
        if let attributed = try? AttributedString(
            markdown: escaped,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            base = attributed
        } else {
            base = AttributedString(text)
        }

        // Apply consistent link styling so embedded URLs are visibly tappable.
        // NOTE: SwiftUI `.foregroundColor` / `.underlineStyle` here don't
        // survive the `NSMutableAttributedString` bridge in SelectableRichText
        // (they land on `SwiftUI.*` keys, not standard NSAttributedString
        // keys) — the visible blue+underline you see comes from UITextView's
        // default `.linkTextAttributes` fallback applied to spans carrying a
        // `.link` attribute. The mention pass below switched to `\.uiKit`
        // scope to fix the bridge loss because mention has no `.link`
        // fallback; links are deferred until someone disables the system
        // styling or wants a non-default accent.
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
        // Apply mention styling through the UIKit attribute scope so it
        // survives the `NSMutableAttributedString(_:)` bridge inside
        // `SelectableRichText`. The SwiftUI `.foregroundColor` / `.font`
        // attributes bridge to NSAttributedString under separate
        // `SwiftUI.ForegroundColor` / `SwiftUI.Font` keys (not the
        // standard UIKit keys), so SelectableRichText's "fill where the
        // attribute is nil" pass treated mention runs as unstyled and
        // overwrote them with `UIColor.label` + base font — mention
        // rendered as plain text in the comment view. Writing the UIKit
        // attributes directly lands on the keys NSAttributedString
        // actually reads.
        for range in mentionRanges {
            if let attrRange = Range(range, in: base) {
                base[attrRange].uiKit.foregroundColor = .systemBlue
                base[attrRange].uiKit.font = Self.mentionFont
            }
        }
        return base
    }
}
