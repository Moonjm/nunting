import SwiftUI
import UIKit

/// 댓글 목록을 한 번에 다 그리지 않고 앞에서부터 잘라 그리기 위한 창(window)
/// 규칙. **오직 늘어나기만 한다** — 이미 그린 행은 절대 되돌리지 않는다.
///
/// eager VStack 은 화면 밖 행까지 진입 즉시 실체화한다. 행마다 UITextView
/// (SelectableRichText) 가 붙어 있어 비용이 댓글 수에 정비례하고, 그 값을
/// 상세 커밋 순간 메인스레드에서 통째로 지불한다. 계측(iPhone 17 Pro
/// 시뮬레이터, 댓글 1개당 약 6ms — 구분선 포함 섹션 전체 기준):
///   100개 575ms · 200개 1,193ms · 400개 2,464ms
/// "댓글 많은 글 들어갈 때 버벅"의 정체가 이 블록이다. 창을 씌운 뒤 같은
/// 하네스에서 진입 비용은 댓글 수와 무관하게 155~170ms 로 고정된다.
///
/// 참고로 이 비용은 마크다운 파싱(1개당 0.025ms)도, AttributedString →
/// NSAttributedString 브릿지(0.4ms, 게다가 행마다 한 번뿐 — 스크롤 중
/// updateUIView 재호출은 계측상 0회)도 아니다. 대부분 UITextView 생성과
/// TextKit 높이 측정이라 "행을 덜 만드는 것" 말고 줄일 방법이 마땅치 않다.
///
/// LazyVStack 으로 되돌리는 건 답이 아니다 — 화면 밖 행을 derealize 했다가
/// 되돌릴 때 높이를 복원하지 못해 스크롤이 뒤로 튀는 게 #160 에서 고친 바로
/// 그 증상이다. 여기서는 *제거 없이 추가만* 하므로 그 실패 모드가 없다:
/// 새 행은 항상 이미 그려진 마지막 행 아래에 붙고, 위쪽 콘텐츠 높이는 변하지
/// 않으므로 스크롤 오프셋이 흔들리지 않는다.
enum CommentRenderWindow {
    /// 진입 시 그리는 행 수. 393pt 폭에서 댓글 1개가 대략 100pt 이므로
    /// 30개면 뷰포트(852pt) 기준 3화면 이상의 스크롤 여유가 생긴다.
    static let initialCount = 30
    /// 한 번 늘릴 때 붙이는 행 수. 성장은 스크롤 도중 한 프레임에 일어나므로
    /// 청크가 클수록 그 순간의 히치가 길다(위 계측 기준 20개면 100ms 안팎).
    /// 총 작업량은 어차피 같으니 히치를 잘게 쪼개는 쪽을 택했다. 연쇄 성장은
    /// 청크 크기와 무관하게 막힌다 — 센티넬은 사용자가 실제로 그 지점까지
    /// 내려와야 반응하므로, 한 번의 성장 뒤 다음 센티넬은 그만큼 더 내려가야
    /// 닿는다.
    static let chunkSize = 20
    /// 끝에서 이만큼 남은 지점을 지나면 다음 청크를 붙인다. 사용자가 실제
    /// 끝에 닿기 전에(대략 한 화면 앞) 미리 늘려, 빈 구간이 보이지 않게 한다.
    static let growthMargin = 10

    /// 현재 그린 개수를 전체 개수 안에서 정규화한다. 새로고침으로 댓글이
    /// 줄어도 prefix 가 알아서 잘리므로 별도 리셋이 필요 없다.
    static func clamped(_ count: Int, total: Int) -> Int {
        min(max(count, initialCount), total)
    }

    /// 다음 성장 후의 개수.
    static func grown(from current: Int, total: Int) -> Int {
        clamped(current + chunkSize, total: total)
    }

    /// `index` 행 뒤에 성장 센티넬을 두는지. 청크 경계에 **고정**으로 둔다 —
    /// "마지막 행"을 따라 옮겨 다니면 옮길 때마다 그 행의 뷰 identity 나
    /// 위쪽 레이아웃이 흔들리므로, 한 번 놓인 센티넬은 그 자리에 남는다.
    /// 이미 그려진 위치에만 존재하므로 성장 시 추가되는 센티넬도 항상
    /// 콘텐츠 맨 아래쪽이다.
    static func hasSentinel(after index: Int) -> Bool {
        index >= initialCount - growthMargin
            && (index - (initialCount - growthMargin)) % chunkSize == 0
    }

    /// 그 센티넬이 지금 성장을 촉발해야 하는지 — 끝에서 `growthMargin` 안쪽에
    /// 든 센티넬만 반응한다. 위쪽에 남아 있는 과거 센티넬들은 화면에 다시
    /// 들어와도 아무 일도 하지 않는다.
    static func shouldGrow(sentinelAfter index: Int, rendered: Int, total: Int) -> Bool {
        rendered < total && index >= rendered - growthMargin
    }
}

struct PostDetailCommentsSection: View {
    let comments: [PostComment]
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void
    let onVideoDismissBegin: () -> Void
    /// 상세 오버레이가 화면에 실제로 떠 있는지 — 댓글 비디오를 오버레이 offset
    /// 기준으로도 정지시키기 위해 InlineVideoPlayer 까지 내려보낸다.
    var isOverlayVisible: Bool = true

    /// 지금까지 그린 댓글 수. 늘어나기만 한다(`CommentRenderWindow` 참고).
    @State private var renderedCount = CommentRenderWindow.initialCount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("댓글")
                    .font(.headline)
                Text("\(comments.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Eager VStack (not LazyVStack) — 본문 블록(PostDetailView
            // articleContent)과 같은 이유다. LazyVStack 은 뷰포트를 벗어난
            // 댓글 행을 derealize 했다가 되돌릴 때 행 높이를 정확히 복원하지
            // 못해, 스크롤 도중 contentSize 가 수십~수백 pt 씩 오르내렸다
            // (계측: 3377↔3568). 그 순간 스크롤 오프셋이 뒤로 끌려가
            // "내려가다 튕겨 올라오는" 증상이 된다. 영상 첨부 댓글(200pt
            // 슬롯)이 섞이면 진폭이 커져 사실상 스크롤이 안 내려간다.
            //
            // 다만 eager 는 "화면 밖 행까지 진입 즉시 전부" 라 비용이 댓글 수에
            // 정비례한다. 그래서 전체가 아니라 `CommentRenderWindow` 만큼만
            // 그리고, 끝에 다가가면 청크를 덧붙인다 — 추가만 하고 제거하지
            // 않으므로 위 실패 모드는 그대로 없다. (성장 트리거는 청크 경계에
            // 고정된 1pt 센티넬 — `growthSentinel` 참고.)
            //
            // 남는 eager 비용: 그려진 행의 측정 + UITextView, 그리고 스티커
            // 이미지 fetch 다. AVPlayer 는 여전히 뷰포트 게이트
            // (InlineVideoPlayer 의 onScrollVisibilityChange + VideoPlayerPool
            // 3슬롯 상한)가 막아 화면 밖 영상은 만들어지지 않고, 댓글 스티커
            // NetworkImage 는 `visibilityGated: false`(아이콘/스티커 정책)라
            // 화면 밖 것도 바로 받지만 이제 "그려진 창" 안의 것만 받는다.
            let rendered = CommentRenderWindow.clamped(renderedCount, total: comments.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.prefix(rendered).enumerated()), id: \.element.id) { index, comment in
                    PostDetailCommentRow(
                        comment: comment,
                        tapGate: tapGate,
                        onImageTap: onImageTap,
                        onVideoDismissBegin: onVideoDismissBegin,
                        isOverlayVisible: isOverlayVisible
                    )
                    if CommentRenderWindow.hasSentinel(after: index) {
                        growthSentinel(after: index, rendered: rendered)
                    }
                    // 경계 조건을 `rendered` 가 아니라 전체 개수로 잡는다:
                    // 마지막으로 그린 행에도 구분선이 남아 있어야 청크가
                    // 붙을 때 기존 행의 높이가 1pt 도 바뀌지 않는다.
                    if index < comments.count - 1 {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
            // 진단 계측 — 실체화된 행 수를 FrameHitchRecorder 가 히치 리포트의
            // context 로 쓴다. body 안에서 직접 쓰지 않고 onChange 로 흘리는
            // 이유: 뷰 평가는 부작용이 없어야 한다(재평가마다 중복 실행됨).
            .onChange(of: rendered, initial: true) { _, count in
                CommentRenderProbe.shared.update(rendered: count, total: comments.count)
            }
        }
    }

    /// 청크 경계에 고정으로 놓이는 성장 트리거. 1pt 인 이유: 0pt 프레임은
    /// 면적이 없어 가시성 판정에서 빠질 수 있다. 센티넬은 한 번 놓이면 그
    /// 자리에 남으므로, 1pt 는 성장 때마다 누적되는 게 아니라 청크당 한 번
    /// 콘텐츠 맨 아래에 붙는다.
    ///
    /// 판정을 `onScrollVisibilityChange` 로 하지 않는 이유: 그 API 는 **첫
    /// 레이아웃 패스에서 화면 밖 뷰까지 visible=true 로 보고한다**(계측:
    /// 뷰포트 852pt 아래 3,100pt 에 있는 센티넬까지 true). 그대로 쓰면
    /// 사용자가 스크롤도 하기 전에 청크가 붙어 진입 비용이 두 배가 됐다.
    /// `bounds(of: .scrollView)` 는 같은 시점에 정확한 값을 준다(위 센티넬
    /// 기준 -3103..-2305 = 가시 영역이 한참 위에 있음).
    ///
    /// 조건이 "보인다" 가 아니라 "여기까지 내려왔다"(가시 영역 하단이 센티넬에
    /// 닿음)인 이유: 보이는 순간에만 반응하면 빠른 플링처럼 센티넬 구간을
    /// 건너뛰는 프레임에서 트리거를 놓칠 수 있고, 그러면 댓글이 잘린 채 영영
    /// 늘어나지 않는다 — 버벅임보다 나쁜 결함이다. 지나친 뒤에도 계속 참인
    /// 단조 조건이라 다음 레이아웃 패스에서 반드시 잡힌다.
    @ViewBuilder
    private func growthSentinel(after index: Int, rendered: Int) -> some View {
        Color.clear
            .frame(height: 1)
            .onGeometryChange(for: Bool.self) { proxy in
                // 가시 영역을 센티넬 로컬 좌표로 환산한 값(센티넬은 로컬 0..1).
                // maxY >= 0 = 가시 영역 하단이 센티넬에 도달했거나 지나갔다.
                // 스크롤 뷰 밖이거나 지오메트리가 아직 없으면 nil — 성장 금지.
                guard let visible = proxy.bounds(of: .scrollView) else { return false }
                return visible.maxY >= 0
            } action: { reached in
                guard reached,
                      CommentRenderWindow.shouldGrow(
                          sentinelAfter: index,
                          rendered: rendered,
                          total: comments.count
                      )
                else { return }
                renderedCount = CommentRenderWindow.grown(from: rendered, total: comments.count)
            }
    }
}

struct PostDetailCommentRow: View {
    let comment: PostComment
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void
    let onVideoDismissBegin: () -> Void
    var isOverlayVisible: Bool = true

    /// 댓글 비디오 슬롯이 차지하는 고정 높이. 종전 최대 높이(240)보다 낮게
    /// 잡은 이유: 고정 예약이라 남는 공간이 그대로 빈칸으로 보이는데, 가로
    /// 영상(320×180, 흔한 쪽)에서 240 은 60pt 나 비어 눈에 띈다. 200 이면
    /// 가로는 20pt 만 남고, 세로 영상(500×786)은 127×200 으로 종전
    /// 152×240 대비 조금 작아지는 선에서 그친다.
    static let videoSlotHeight: CGFloat = 200
    /// 슬롯 최대 폭 — 종전 `.frame(maxWidth: 320)` 과 동일.
    static let videoSlotWidth: CGFloat = 320

    /// 댓글 비디오 슬롯. **높이를 고정 예약**하는 게 핵심이다.
    ///
    /// InlineVideoPlayer 는 AVAsset 메타데이터를 비동기로 읽어 종횡비를
    /// 16:9 기본값에서 실제 비율로 갈아끼운다. 슬롯 높이를 플레이어에게
    /// 맡기면 그 순간 행 높이가 통째로 바뀌고(실측: 16:9 180pt → 세로
    /// 500×786 240pt, 2.35:1 136pt), 그 행이 뷰포트 *위쪽*에 있으면
    /// 스크롤 콘텐츠가 손가락 밑에서 밀린다 — "스크롤이 안 내려가고 튄다".
    /// 특히 humoruniv 댓글 mp4 는 moov atom 이 파일 끝에 있는 non-faststart
    /// 인코딩(25MB 짜리도 있음)이라 메타데이터가 몇 초 뒤 도착해, 사용자가
    /// 한참 스크롤한 뒤에 뜬금없이 튀는 형태로 나타났다.
    ///
    /// 높이를 고정하면 비율이 언제 도착하든 행 높이는 그대로고, 플레이어는
    /// 그 안에서 자기 비율대로 맞춰진다(가로 영상은 위아래 여백이 남음).
    @ViewBuilder
    static func videoSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
                // `.leading`: 세로 영상은 320 슬롯보다 좁아서(127pt) 기본
                // 가운데 정렬이면 혼자 안쪽으로 들여쓴 것처럼 보였다 — 닉네임/
                // 본문/스티커와 같은 왼쪽 라인에 맞춘다.
                .frame(maxWidth: videoSlotWidth, maxHeight: videoSlotHeight, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: videoSlotHeight)
    }

    /// 다모앙 앙티콘(`damoang.net/emoticons/…`) 판정 — 사이트 표시 크기
    /// (40~50px)에 맞춘 소형 프레임으로 구분 렌더한다. 밈/짤 스티커와 달리
    /// 크게 키울 정보가 없는 이모지성 이미지라 일반 프레임이 과하다.
    nonisolated static func isEmoticonSticker(_ url: URL) -> Bool {
        Site.host(url.host, matches: "damoang.net") && url.path.hasPrefix("/emoticons/")
    }

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
                Self.videoSlot {
                    InlineVideoPlayer(
                        url: videoURL,
                        tapGate: tapGate,
                        onDismissBegin: onVideoDismissBegin,
                        isOverlayVisible: isOverlayVisible
                    )
                }
            } else if let stickerURL = comment.stickerURL {
                // 다모앙 앙티콘은 사이트 표시 크기(40~50px)에 맞춘 소형
                // 프레임 — 일반 스티커(밈 이미지) 프레임(200×140)으로
                // 렌더하면 과하게 커진다.
                let isEmoticon = Self.isEmoticonSticker(stickerURL)
                HStack(spacing: 0) {
                    NetworkImage(
                        url: stickerURL,
                        thumbnailMaxPointSize: isEmoticon ? 112 : 280
                    )
                        .frame(
                            maxWidth: isEmoticon ? 56 : 200,
                            maxHeight: isEmoticon ? 56 : 140
                        )
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
        let styled = comment.content.isEmpty ? AttributedString() : styledContent(comment.content)
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
