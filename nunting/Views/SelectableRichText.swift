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
struct SelectableRichText: UIViewRepresentable {
    let attributedString: AttributedString
    let font: UIFont
    /// Raised whenever the wrapped `UITextView` reports a non-empty
    /// selection so `ContentView.panGesture` knows to stay out of a
    /// selection-handle drag's way — a rightward handle drag was
    /// previously racing the back-swipe pan and pulling the detail
    /// overlay off-screen mid-selection. Optional so previews and
    /// other call sites without a host pan gesture can omit it.
    var selectionGate: TextSelectionGate? = nil

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
        context.coordinator.selectionGate = selectionGate

        let ns = NSMutableAttributedString(attributedString)
        let full = NSRange(location: 0, length: ns.length)
        // Apply base font/color only where the AttributedString hasn't
        // set its own — preserves the parser's link accent color,
        // markdown bold/italic, and mention tints.
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
        tv.attributedText = ns
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

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        // Defensive clear: if the SwiftUI view is removed mid-selection
        // (e.g. user navigates away while text is selected), the
        // coordinator's didChangeSelection cleanup won't fire and the
        // gate would strand `true`, blocking every future back-drag
        // until app restart.
        coordinator.selectionGate?.isActive = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTap: (URL) -> Void = { _ in }
        weak var selectionGate: TextSelectionGate?

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

        /// Fires on every selection range update — including each
        /// tick while the user is dragging a selection handle. Mirror
        /// the "is there a visible selection right now" question into
        /// `selectionGate` so `ContentView.panGesture` can bail before
        /// classifying the same finger movement as a back-drag.
        func textViewDidChangeSelection(_ textView: UITextView) {
            let hasSelection: Bool
            if let range = textView.selectedTextRange, !range.isEmpty {
                hasSelection = true
            } else {
                hasSelection = false
            }
            selectionGate?.isActive = hasSelection
        }
    }
}
