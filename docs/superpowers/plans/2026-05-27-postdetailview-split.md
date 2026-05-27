# PostDetailView 5분할 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Views/PostDetailView.swift` (932줄) 를 본체 + 4개 보조 파일로 분할, 행위 변경 없는 mechanical move.

**Architecture:** 기존 file-private struct (`CommentsSection`, `CommentRow`, `YouTubeBanner`, `DealLinkBanner`, `SourceBanner`, `WrappingTitleLabel`, `StatusBarTapScrollClaimer`) 들을 새 파일로 옮기고, comments/banners 류는 `PostDetail` 접두사로 rename, `private` → `internal` 가시성 완화. 데이터 흐름·콜백 시그니처 그대로.

**Tech Stack:** Swift 6, SwiftUI, UIKit (UIViewRepresentable bridges), Xcode 15+ filesystem synchronized groups (자동 파일 포함).

**Spec:** `docs/superpowers/specs/2026-05-27-postdetailview-split-design.md`

---

## File Structure

| 파일 | 책임 | 신규/수정 |
|---|---|---|
| `nunting/Views/PostDetailView.swift` | `PostDetailView` 본체 (body, header, articleContent, attributedString, linkify) | 수정 (~440줄로 축소) |
| `nunting/Views/PostDetailComments.swift` | `PostDetailCommentsSection`, `PostDetailCommentRow`, `StyledBox`, styled cache, markdown/mention 처리 | 신규 (~190줄) |
| `nunting/Views/PostDetailBanners.swift` | `PostDetailYouTubeBanner`, `PostDetailDealLinkBanner`, `PostDetailSourceBanner` | 신규 (~110줄) |
| `nunting/Views/WrappingTitleLabel.swift` | UILabel 브리지 — 제목 줄바꿈 strategy | 신규 (~40줄) |
| `nunting/Views/StatusBarTapScrollClaimer.swift` | window-level scrollsToTop claim + `ClaimerView` | 신규 (~125줄) |

Xcode 프로젝트 (`nunting.xcodeproj/project.pbxproj`) 는 `PBXFileSystemSynchronizedRootGroup` 사용 — `Views/` 안에 swift 파일 떨어뜨리면 자동 포함, pbxproj 수정 불필요.

---

## Task 1: WrappingTitleLabel 추출

가장 단순한 단위(40줄, 외부 의존 없음, ContentView 등 다른 파일에서 참조 없음)부터.

**Files:**
- Create: `nunting/Views/WrappingTitleLabel.swift`
- Modify: `nunting/Views/PostDetailView.swift` (749-784줄 제거)

- [ ] **Step 1: 새 파일 생성**

`nunting/Views/WrappingTitleLabel.swift` 작성:

```swift
import SwiftUI
import UIKit

/// Bridges to UILabel so the title can use `.lineBreakStrategy = .standard`,
/// which SwiftUI `Text` doesn't expose. SwiftUI's default for Korean text
/// keeps mixed-script tokens like "(gpt-image-2)" glued to the preceding
/// Hangul word, leaving the previous line short. The standard strategy
/// allows breaking between Hangul and adjacent punctuation/Latin tokens.
struct WrappingTitleLabel: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = .standard
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        if label.text != text {
            label.text = text
            label.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
```

- [ ] **Step 2: 기존 파일에서 제거**

`nunting/Views/PostDetailView.swift` 의 다음 블록 (대략 744–784줄, `/// Bridges to UILabel ...` 주석 + `struct WrappingTitleLabel: UIViewRepresentable { ... }` 통째로) 삭제. 호출부 `WrappingTitleLabel(text: post.title)` 는 그대로 둠 (이름 동일).

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: 커밋**

```bash
git add nunting/Views/WrappingTitleLabel.swift nunting/Views/PostDetailView.swift
git commit -m "$(cat <<'EOF'
refactor(detail): WrappingTitleLabel → 별도 파일

PostDetailView.swift 5분할 1/4. 외부 의존 없는 가장 단순한 단위부터.
spec: docs/superpowers/specs/2026-05-27-postdetailview-split-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: StatusBarTapScrollClaimer 추출

`ClaimerView` 내부 class 까지 통째로 이동. ContentView 등 외부 참조 없음 (확인 완료).

**Files:**
- Create: `nunting/Views/StatusBarTapScrollClaimer.swift`
- Modify: `nunting/Views/PostDetailView.swift` (785-932줄 제거)

- [ ] **Step 1: 새 파일 생성**

`nunting/Views/StatusBarTapScrollClaimer.swift` 작성:

```swift
import SwiftUI
import UIKit

/// When the detail view is visible, iOS's status-bar-tap scroll-to-top
/// quietly stops working because both the list's backing `UIScrollView`
/// (from `List`) and the detail's `ScrollView` sit in the window with
/// `scrollsToTop = true`. iOS only fires the behaviour when exactly one
/// candidate is eligible; ties resolve to none.
///
/// Drop this zero-sized view inside the detail's `ScrollView`. When
/// `isActive` is true it walks up to the enclosing scroll view (the
/// detail's), pins that one as the claimant, and disables
/// `scrollsToTop` on every *other* scroll view in the same window.
/// When `isActive` flips to false it restores each original setting.
///
/// `isActive` must be driven by the caller, not by UIKit lifecycle —
/// the detail overlay is keep-alive (`activePost` stays set after
/// `hideDetail`, so `willMove(toWindow: nil)` would never fire on a
/// plain dismissal). Without an explicit signal from the `detailOffset`
/// state the list's `scrollsToTop` would stay `false` for the rest of
/// the session after the first dismissal, silently breaking the
/// list's own status-bar-tap behaviour.
struct StatusBarTapScrollClaimer: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> ClaimerView {
        let v = ClaimerView()
        v.isActive = isActive
        return v
    }

    func updateUIView(_ view: ClaimerView, context: Context) {
        // SwiftUI fires `updateUIView` on every parent re-eval. Scanning
        // the window tree on each call is wasteful and — worse — breaks
        // transient scroll views (e.g. the Safari reader sheet) whose
        // `scrollsToTop` we shouldn't be disabling at all. Only re-apply
        // when the caller actually flipped `isActive`; mount-time apply
        // still runs from `didMoveToWindow`.
        guard view.isActive != isActive else { return }
        view.isActive = isActive
        view.apply()
    }

    final class ClaimerView: UIView {
        private struct Managed {
            weak var scrollView: UIScrollView?
            let originalScrollsToTop: Bool
        }
        private var managed: [Managed] = []
        var isActive: Bool = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard isActive, let window else {
                restoreManaged()
                return
            }
            // Our enclosing scroll view is the detail view's ScrollView.
            // Walk the superview chain to find it.
            var current: UIView? = self
            var enclosing: UIScrollView?
            while let c = current {
                if let sv = c as? UIScrollView {
                    enclosing = sv
                    break
                }
                current = c.superview
            }
            enclosing?.scrollsToTop = true

            // Find every *other* UIScrollView in the window. Disable
            // scrollsToTop on them and remember the prior value so we can
            // restore when `isActive` flips to false.
            //
            // Scope to scroll views whose owning view controller shares a
            // top-level parent with ours. That's the rootVC's subtree,
            // which contains the list behind our overlay (both are child
            // VCs of the app's root hosting controller). Presented sheets
            // and full-screen covers (SafariView, ImageViewer) live under
            // a different top-level chain — their scroll views are THEIRS
            // to manage, not ours.
            let ourTopVC = Self.topLevelViewController(of: self)
            var all: [UIScrollView] = []
            Self.collectScrollViews(in: window, into: &all)
            let alreadyManaged = Set(managed.compactMap { $0.scrollView.map(ObjectIdentifier.init) })
            for sv in all {
                if sv === enclosing { continue }
                if alreadyManaged.contains(ObjectIdentifier(sv)) { continue }
                let theirTopVC = Self.topLevelViewController(of: sv)
                if let ourTopVC, let theirTopVC, ourTopVC !== theirTopVC {
                    continue
                }
                managed.append(Managed(
                    scrollView: sv,
                    originalScrollsToTop: sv.scrollsToTop
                ))
                sv.scrollsToTop = false
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil {
                restoreManaged()
            }
            super.willMove(toWindow: newWindow)
        }

        private func restoreManaged() {
            for m in managed {
                m.scrollView?.scrollsToTop = m.originalScrollsToTop
            }
            managed.removeAll()
        }

        private static func collectScrollViews(in root: UIView, into acc: inout [UIScrollView]) {
            if let sv = root as? UIScrollView {
                acc.append(sv)
            }
            for sub in root.subviews {
                collectScrollViews(in: sub, into: &acc)
            }
        }

        /// Walks the responder chain to find the view's owning
        /// UIViewController, then follows `.parent` to the top. Presented
        /// (modal) view controllers have no `.parent`, so `topLevel` on a
        /// sheet's VC returns the sheet's own root VC — different object
        /// from the app's rootVC, which is how we tell them apart.
        private static func topLevelViewController(of view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            var owner: UIViewController?
            while let r = responder {
                if let vc = r as? UIViewController {
                    owner = vc
                    break
                }
                responder = r.next
            }
            var current = owner
            while let c = current, let p = c.parent {
                current = p
            }
            return current
        }
    }
}
```

- [ ] **Step 2: 기존 파일에서 제거**

`nunting/Views/PostDetailView.swift` 의 `/// When the detail view is visible, ...` 주석 + `struct StatusBarTapScrollClaimer: UIViewRepresentable { ... }` 통째 (현재 파일 끝부분) 삭제. 호출부 `StatusBarTapScrollClaimer(isActive: isOverlayVisible)` 는 그대로.

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: 커밋**

```bash
git add nunting/Views/StatusBarTapScrollClaimer.swift nunting/Views/PostDetailView.swift
git commit -m "$(cat <<'EOF'
refactor(detail): StatusBarTapScrollClaimer → 별도 파일

PostDetailView.swift 5분할 2/4. window-level scroll claim utility 추출.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PostDetailBanners 추출 (YouTube / DealLink / Source)

3개 배너를 한 파일로 묶고 `PostDetail` 접두사 추가. 호출부 3곳 (`articleContent` 의 `.embed(.youtube, ...)`, `.dealLink`, `.embed(.instagram, ...)` 그리고 `body` 의 `SourceBanner(source:)`) 동시 갱신.

**Files:**
- Create: `nunting/Views/PostDetailBanners.swift`
- Modify: `nunting/Views/PostDetailView.swift` (442-551줄 제거, 호출부 4곳 rename)

- [ ] **Step 1: 새 파일 생성**

`nunting/Views/PostDetailBanners.swift` 작성:

```swift
import SwiftUI

struct PostDetailYouTubeBanner: View {
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

                NetworkImage(url: thumbnailURL, thumbnailMaxPointSize: 720)
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

struct PostDetailDealLinkBanner: View {
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
            .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("딜 링크 \(label), 외부 사이트 열기")
    }
}

struct PostDetailSourceBanner: View {
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
            .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("출처 \(source.name), 외부 사이트 열기")
    }
}
```

- [ ] **Step 2: 기존 파일에서 제거**

`nunting/Views/PostDetailView.swift` 에서 `private struct YouTubeBanner: View { ... }`, `private struct DealLinkBanner: View { ... }`, `private struct SourceBanner: View { ... }` 세 블록 통째 삭제 (대략 442–551줄).

- [ ] **Step 3: 호출부 4곳 rename**

`nunting/Views/PostDetailView.swift` 의 호출부 갱신:

`body` 안:
```swift
                    if let source = loader.detail?.source {
                        SourceBanner(source: source)
                    }
```
→
```swift
                    if let source = loader.detail?.source {
                        PostDetailSourceBanner(source: source)
                    }
```

`articleContent` 안 3곳:
```swift
                    case .dealLink(let url, let label):
                        DealLinkBanner(url: url, label: label)
                    case .embed(.youtube, let id):
                        YouTubeBanner(videoID: id)
                    case .embed(.instagram, let id):
                        if let url = URL(string: "https://www.instagram.com/p/\(id)/") {
                            DealLinkBanner(url: url, label: "Instagram 게시물 보기")
                        }
```
→
```swift
                    case .dealLink(let url, let label):
                        PostDetailDealLinkBanner(url: url, label: label)
                    case .embed(.youtube, let id):
                        PostDetailYouTubeBanner(videoID: id)
                    case .embed(.instagram, let id):
                        if let url = URL(string: "https://www.instagram.com/p/\(id)/") {
                            PostDetailDealLinkBanner(url: url, label: "Instagram 게시물 보기")
                        }
```

- [ ] **Step 4: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: 커밋**

```bash
git add nunting/Views/PostDetailBanners.swift nunting/Views/PostDetailView.swift
git commit -m "$(cat <<'EOF'
refactor(detail): Banners → PostDetailBanners.swift (3종)

PostDetailView.swift 5분할 3/4.
YouTubeBanner / DealLinkBanner / SourceBanner 를 PostDetail 접두사로
rename 후 한 파일로 묶음.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: PostDetailComments 추출

가장 큰 단위. `CommentsSection` + `CommentRow` + `StyledBox` + `styledCache` + markdown/mention 처리 통째 이동. 호출부 1곳 (`body` 안 `CommentsSection(...)`) rename.

**Files:**
- Create: `nunting/Views/PostDetailComments.swift`
- Modify: `nunting/Views/PostDetailView.swift` (553-742줄 제거, 호출부 1곳 rename)

- [ ] **Step 1: 새 파일 생성**

`nunting/Views/PostDetailComments.swift` 작성:

```swift
import SwiftUI

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
            if !comment.content.isEmpty {
                SelectableRichText(
                    attributedString: styledContent(comment.content),
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
```

- [ ] **Step 2: 기존 파일에서 제거**

`nunting/Views/PostDetailView.swift` 에서 `private struct CommentsSection: View { ... }` + `private struct CommentRow: View { ... }` (StyledBox / styledCache / styledContent / computeStyledContent 포함) 통째 삭제 (대략 553–742줄).

- [ ] **Step 3: 호출부 rename**

`nunting/Views/PostDetailView.swift` 의 `body` 안:

```swift
                    if let comments = loader.detail?.comments, !comments.isEmpty {
                        CommentsSection(
                            comments: comments,
                            tapGate: tapGate,
                            onImageTap: { url in
                                if tapGate?.suppressed == true { return }
                                selectedImage = ImageViewerItem(url: url)
                            },
                            onVideoDismissBegin: { beginDismissCover() }
                        )
                            .padding(.top, 8)
                    }
```
→
```swift
                    if let comments = loader.detail?.comments, !comments.isEmpty {
                        PostDetailCommentsSection(
                            comments: comments,
                            tapGate: tapGate,
                            onImageTap: { url in
                                if tapGate?.suppressed == true { return }
                                selectedImage = ImageViewerItem(url: url)
                            },
                            onVideoDismissBegin: { beginDismissCover() }
                        )
                            .padding(.top, 8)
                    }
```

- [ ] **Step 4: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: 라인수 확인**

```
wc -l nunting/Views/PostDetailView.swift nunting/Views/PostDetailComments.swift nunting/Views/PostDetailBanners.swift nunting/Views/WrappingTitleLabel.swift nunting/Views/StatusBarTapScrollClaimer.swift
```

Expected: `PostDetailView.swift` ~440 lines (was 932); total ~905 lines (close to original, slight overhead from per-file imports).

- [ ] **Step 6: 커밋**

```bash
git add nunting/Views/PostDetailComments.swift nunting/Views/PostDetailView.swift
git commit -m "$(cat <<'EOF'
refactor(detail): Comments → PostDetailComments.swift

PostDetailView.swift 5분할 4/4. CommentsSection + CommentRow + markdown
캐시(StyledBox/styledCache)까지 통째 이동. PostDetail 접두사 적용.

이 PR 4커밋으로 PostDetailView 932 → ~440줄로 축소.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 기존 unit test 통과 검증 + 수동 QA

기존 테스트 그린 확인 + 수동 QA 체크리스트 실행.

**Files:** 없음 (검증만)

- [ ] **Step 1: Unit test 실행**

```
xcodebuild test -scheme nunting -project nunting.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -50
```

(iPhone Simulator 이름이 환경에 따라 다를 수 있음 — `xcrun simctl list devices available` 으로 확인 후 한 개 골라 쓰기.)

Expected: 모든 test PASS. 본 분할은 parser/loader 미터치이므로 기존 test 동작 동일해야 함.

- [ ] **Step 2: 수동 QA — 본문 + 댓글 있는 글 1개 열어서 확인**

`docs/superpowers/specs/2026-05-27-postdetailview-split-design.md` 의 "QA" 섹션 체크리스트:

- [ ] 제목 줄바꿈 정상 (`WrappingTitleLabel`)
- [ ] 본문 NSDataDetector 자동 링크 + 명시적 `<a>` 링크 → SafariView 라우팅
- [ ] 댓글 `@nickname` mention 파란 굵게
- [ ] 댓글 markdown `[label](url)` 링크 색 + 탭 라우팅
- [ ] 댓글 `~` 이스케이프 (1995~1996 같은 텍스트에 strikethrough 안 걸리는지)
- [ ] 출처 배너 / YouTube 배너 / DealLink 배너 렌더
- [ ] pull-to-refresh
- [ ] detail 진입 후 status bar tap → 본문 ScrollView 최상단으로
- [ ] detail dismiss 후 list 화면에서 status bar tap → list 최상단 (claimer 복구)
- [ ] 본문 이미지 탭 → ImageViewer 진입 / dismiss cover 정상

- [ ] **Step 3: push 승인 대기**

QA 통과 시 사용자에게 보고하고 `git push` 승인 받기. (auto-push 금지 메모리에 따라.)

---

## Self-Review (작성자 체크)

**Spec coverage:**
- WrappingTitleLabel 추출 → Task 1 ✓
- StatusBarTapScrollClaimer 추출 → Task 2 ✓
- PostDetail{YouTube,DealLink,Source}Banner 추출 → Task 3 ✓
- PostDetailComments{Section,Row} 추출 → Task 4 ✓
- 접근 수준 `private` → `internal` → Task 1-4 각각 새 파일에서 `struct ...` 키워드 ✓
- PostDetail 접두사 rename → Task 3, 4 ✓
- 빌드 검증 → Task 1-4 매 task ✓
- 기존 test + 수동 QA → Task 5 ✓
- 작업 순서 (WrappingTitleLabel → StatusBarTap → Banners → Comments) → 안전 → 위험 순서 (외부 의존 없음 → 호출부 3+1곳) ✓

**Placeholder scan:** 없음. 모든 step 에 실제 코드/명령/기대 결과 포함.

**Type consistency:**
- `PostDetailYouTubeBanner(videoID:)`, `PostDetailDealLinkBanner(url:label:)`, `PostDetailSourceBanner(source:)` — Task 3 정의 ↔ Task 3 호출부 시그니처 동일 ✓
- `PostDetailCommentsSection(comments:tapGate:onImageTap:onVideoDismissBegin:)` — Task 4 정의 ↔ Task 4 호출부 동일 ✓
- `PostDetailCommentRow(comment:tapGate:onImageTap:onVideoDismissBegin:)` — Task 4 안에서 `PostDetailCommentsSection` 이 호출. 시그니처 동일 ✓
- `StyledBox`, `styledCache`, `styledContent`, `computeStyledContent` 는 `PostDetailCommentRow` 의 private 멤버로 유지 — 외부 접근 없음 ✓

---

## 범위 밖

- `InlineVideoPlayer.swift` 분할 (refactor-followups §2 후반): 별도 후속 PR.
- 행위 변경, 새 기능, 무관한 리팩토링.
