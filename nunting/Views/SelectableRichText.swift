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
/// Coordinates with `ContentView.panGesture` purely via the host's
/// `touchStartedNearSelectionHandle` proximity check (±28pt × ±16pt
/// box around each visible selection handle — see that doccomment for
/// why not a 44pt circle) — no shared gate needed. Every other
/// touch on this view falls through to the host pan gesture exactly
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
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
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
