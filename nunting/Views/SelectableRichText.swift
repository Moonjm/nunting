import SwiftUI
import UIKit

/// SwiftUI `Text` + `.textSelection(.enabled)` only surfaces the system
/// "select all + copy" context menu — it does not support the
/// magnifying-glass + drag-handle range selection users expect from
/// every other iOS app. That capability lives on `UITextView` with
/// `isSelectable = true`. This representable wraps one in the
/// minimum-friction way: takes an `AttributedString` (so the existing
/// `attributedString(from: segments)` and `styledContent(_:)` builders
/// drop in unchanged), preserves `.link` / `.foregroundColor` /
/// `.underlineStyle` spans, and routes link taps through the SwiftUI
/// `openURL` environment so the host's SFSafariViewController override
/// still wins.
///
/// Coordinates with `DetailBackDrag` purely via the host's
/// `touchStartedNearSelectionHandle` proximity check (±28pt × ±16pt
/// box around each visible selection handle — see that doccomment for
/// why not a 44pt circle) — no shared gate needed. Every other
/// touch on this view falls through to the host back-drag gesture exactly
/// as before, including loupe / long-press / menu interactions: the
/// user explicitly opted into the simpler "only handle drags block
/// back-swipe" contract.
struct SelectableRichText: UIViewRepresentable {
    let attributedString: AttributedString
    let font: UIFont

    /// `openURL` is read from this view's own environment, NOT the
    /// parent's — `.environment(\.openURL, …)` set on an ancestor
    /// applies to that ancestor's *descendants*, which includes this
    /// representable. So a PostDetailView that installs an in-app
    /// browser override propagates correctly into the UITextView's
    /// link-tap handler.
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        // Disable internal scrolling so SwiftUI's parent ScrollView
        // owns the scroll. With this off, UITextView reports its full
        // intrinsic height via `sizeThatFits` and grows the layout
        // instead of clipping to its frame.
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        // Strip the default insets/padding so the rendered glyph box
        // matches a plain SwiftUI `Text` — otherwise UITextView's
        // 8pt top/bottom inset and 5pt line-fragment lead shift
        // every paragraph and break visual continuity with adjacent
        // SwiftUI views (image blocks, video players).
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        // The parser already converts anchors to `.link` spans and
        // NSDataDetector runs at the parse stage; enabling
        // dataDetectorTypes here would double-linkify and re-style
        // already-linked text.
        tv.dataDetectorTypes = []
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Re-bind the openURL handler on every state update so the
        // closure sees the current environment (which may change
        // when ancestors swap out the OpenURLAction — e.g. a
        // deep-link mode toggle).
        context.coordinator.onLinkTap = { url in openURL(url) }

        let ns = NSMutableAttributedString(attributedString)
        let full = NSRange(location: 0, length: ns.length)

        // `AttributedString(markdown:)` (used by `styledContent` for
        // comments) encodes `**bold**` / `*italic*` as
        // `inlinePresentationIntent` attributes, not `.font` with bold
        // /italic traits. SwiftUI's `Text` renderer consults that
        // attribute; UIKit's TextKit does not, so without this
        // translation step bold and italic spans render in plain roman.
        // Synthesize a `.font` with the appropriate `UIFontDescriptor`
        // traits for every intent run BEFORE the base-font fallback so
        // those ranges win.
        ns.enumerateAttribute(.inlinePresentationIntent, in: full, options: []) { value, range, _ in
            // `InlinePresentationIntent` rawValue is `UInt` but the
            // attribute round-trips through `NSNumber` when bridged
            // into `NSAttributedString`, so cast via that and extract
            // `.uintValue` instead of forcing `as? UInt` (which fails
            // for the boxed NSNumber).
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            guard !traits.isEmpty else { return }
            let base = (ns.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? font
            if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                // `size: 0` keeps the descriptor's own size — preserves
                // Dynamic Type scaling that the base font carries.
                ns.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
            }
        }

        // Apply base font/color only where the AttributedString hasn't
        // set its own — preserves the parser's link accent color,
        // markdown bold/italic (now translated above), and mention tints.
        ns.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil {
                ns.addAttribute(.font, value: font, range: range)
            }
        }
        ns.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil {
                ns.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }

        // Guard against `attributedText` reassignment when the content
        // hasn't actually changed — every assignment resets
        // `selectedRange` to (0, 0), which would clobber an in-progress
        // user selection during the SwiftUI re-eval cascades that fire
        // continuously during back-drag animations or container-size
        // updates. `isEqual(to:)` is content equality (string + attribute
        // runs) and cheap relative to a TextKit layout pass.
        if !ns.isEqual(to: tv.attributedText ?? NSAttributedString()) {
            tv.attributedText = ns
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // Use the proposed width (= parent's available width) to
        // compute the required height. Without this, UITextView's
        // intrinsicContentSize returns a single-line width that
        // overflows the layout for any multi-line paragraph.
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }

        // 측정 결과는 (텍스트, 폰트, 폭)의 순수 함수라 캐시한다. 이유는
        // 기기에서 뜬 백드래그 정체 스택이다 — SwiftUI 레이아웃 패스가
        // 이 함수를 타고 TextKit 측정으로 내려간 자리에서 메인 스레드가
        // 175ms 멈췄다(댓글 159행):
        //   7  nunting  SelectableRichText.sizeThatFits
        //   5  UIKitCore / 1~4 UIFoundation (TextKit 레이아웃)
        // 드래그 중 레이아웃이 한 번이라도 돌면 그려진 행 전부를 다시 재는데,
        // 내용이 그대로면 잴 필요가 없다.
        let key = HeightKey(text: attributedString, font: font, width: width.rounded())
        if let cached = Self.heightCache[key] {
            return CGSize(width: width, height: cached)
        }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitted.height)
        Self.cacheHeight(height, for: key)
        return CGSize(width: width, height: height)
    }

    /// 폭까지 키에 넣는다 — 회전/분할화면으로 폭이 바뀌면 높이도 달라진다.
    /// 폰트는 Dynamic Type 을 반영한 실제 폰트라 글자 크기 변경도 여기서 갈린다.
    nonisolated struct HeightKey: Hashable {
        let text: AttributedString
        let font: UIFont
        let width: CGFloat
    }

    /// 화면에 살아 있는 행 수(수백)의 몇 배면 충분하다. 넘으면 통째로 비운다 —
    /// LRU 를 굴릴 만큼 값이 비싸지 않고(재측정 1~2ms), 폭·폰트가 바뀌는
    /// 순간에는 어차피 전부 무효가 된다.
    static let heightCacheLimit = 2000
    private static var heightCache: [HeightKey: CGFloat] = [:]

    private static func cacheHeight(_ height: CGFloat, for key: HeightKey) {
        if heightCache.count >= heightCacheLimit { heightCache.removeAll(keepingCapacity: true) }
        heightCache[key] = height
    }

    /// 테스트 전용 — 캐시 상태에 의존하는 검증을 격리한다.
    static func resetHeightCacheForTesting() {
        heightCache.removeAll()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTap: (URL) -> Void = { _ in }

        /// iOS 17+ primary-action API. Intercept link taps and route
        /// through the SwiftUI `openURL` environment so the host's
        /// SFSafariViewController override applies — without this the
        /// system would open the URL in Safari via
        /// `UIApplication.shared.open(_:)` and bypass the in-app
        /// browser flow.
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            if case .link(let url) = textItem.content {
                let handler = onLinkTap
                return UIAction(title: defaultAction.title) { _ in handler(url) }
            }
            return defaultAction
        }
    }
}
