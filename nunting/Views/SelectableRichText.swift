import SwiftUI
import UIKit

/// UITextView subclass whose only job is to forward the
/// `becomeFirstResponder` transition into a `TextSelectionGate`.
/// UITextView with `isSelectable = true` becomes first responder
/// when the user initiates a selection interaction (long-press →
/// loupe, menu present, handle drag) but NOT for inert taps on
/// non-editable text. That makes it the most reliable single
/// signal of "user is starting a selection here, keep the host's
/// back-drag out of the way" — more reliable than either the
/// gesture-recognizer fires or the delegate selection callback,
/// both of which we've seen vary between long body posts and
/// short comments.
final class SelectionTrackingTextView: UITextView {
    weak var selectionGate: TextSelectionGate?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            selectionGate?.touch()
        }
        return didBecome
    }
}

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
        let tv = SelectionTrackingTextView()
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

        // Short-fuse long-press that touches `selectionGate` after
        // 0.12s of holding within 10pt. Discriminates "loupe /
        // long-press intent" from "pure swipe":
        //   - User holds still → long-press fires at 0.12s → gate
        //     active → subsequent finger movement bails ContentView's
        //     back-drag.
        //   - User moves >10pt within 0.12s (fast swipe) → long-press
        //     fails before firing → gate stays cold → back-drag
        //     proceeds normally.
        // `cancelsTouchesInView = false` and the delegate's
        // `shouldRecognizeSimultaneouslyWith` returning true keep
        // UITextView's own selection gestures alive — we're only
        // observing, not claiming the touch.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSelectionLongPress(_:))
        )
        longPress.minimumPressDuration = 0.12
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Re-bind the openURL handler on every state update so the
        // closure sees the current environment (which may change
        // when ancestors swap out the OpenURLAction — e.g. a
        // deep-link mode toggle).
        context.coordinator.onLinkTap = { url in openURL(url) }
        context.coordinator.selectionGate = selectionGate
        // Keep the subclass's gate pointer in sync — without this
        // the `becomeFirstResponder` override observes nil.
        (tv as? SelectionTrackingTextView)?.selectionGate = selectionGate

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

    // No `dismantleUIView` override: the selection gate is shared
    // across every `SelectableRichText` instance in the post (body
    // text + every comment row). LazyVStack derealizing a comment
    // row would fire `dismantleUIView` and a `reset()` here would
    // clobber an in-flight selection happening on a different,
    // still-mounted instance. The gate's 180ms TTL handles cleanup
    // naturally — far cheaper than risking cross-instance interference.

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onLinkTap: (URL) -> Void = { _ in }
        weak var selectionGate: TextSelectionGate?
        /// Previous selection range, kept so `textViewDidChangeSelection`
        /// can distinguish "user is actively modifying the selection"
        /// (range non-empty AND changed since last fire — handle drag,
        /// menu Select → drag) from "selection just cleared" (range
        /// went empty) or "no change" (idempotent fire from programmatic
        /// `attributedText` assignment). Only the first case should
        /// touch the gate; the other two would block back-swipes
        /// after a single tap on text.
        private var lastReportedRange: NSRange = NSRange(location: NSNotFound, length: 0)

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

        /// Fires whenever the wrapped UITextView's selection range
        /// changes. Touch the shared gate ONLY for "active selection
        /// modification" ticks — non-empty range that differs from
        /// the previous fire. This filters out:
        ///   - Selection clears (range goes to length 0) — happens
        ///     on a single tap that dismisses a prior selection;
        ///     activating the gate here would block the next
        ///     back-swipe over the same text.
        ///   - Idempotent fires from programmatic `attributedText`
        ///     assignment in `updateUIView` (range unchanged from
        ///     the previous report — typically still `NSNotFound`).
        /// Handle drags fire continuously with changing non-empty
        /// ranges, so they refresh the gate every ~16ms.
        func textViewDidChangeSelection(_ textView: UITextView) {
            let current = textView.selectedRange
            defer { lastReportedRange = current }
            guard current.length > 0 else { return }
            if NSEqualRanges(current, lastReportedRange) { return }
            selectionGate?.touch()
        }

        /// Fires at 0.12s of holding (within 10pt) on the wrapped
        /// UITextView. Its only job is to discriminate "long-press →
        /// loupe / selection entry" from "swipe-too-slow-to-escape-
        /// allowable-movement" — for the FIRST case the user is
        /// about to enter selection mode so we want the host's
        /// back-drag to stay out of the way.
        ///
        /// When a selection is *already* active, this recognizer fires
        /// for any touch that lingers within 10pt for 0.12s — including
        /// a gentle back-swipe the user clearly intends as
        /// navigation. Guard against that: with selection live, handle
        /// grabs are caught by `ContentView.touchStartedNearSelectionHandle`
        /// (44pt radius) and any range modification is caught by the
        /// filtered `textViewDidChangeSelection`, so we don't need
        /// this signal there too — bailing here lets the back-swipe
        /// fall through.
        @objc func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
            if let tv = gesture.view as? UITextView,
               tv.selectedTextRange?.isEmpty == false {
                return
            }
            switch gesture.state {
            case .began, .changed:
                selectionGate?.touch()
            default:
                break
            }
        }

        /// Lets our long-press observer co-exist with UITextView's
        /// internal selection / loupe / handle pan recognizers —
        /// without simultaneous recognition, one would force the
        /// other to fail and the selection gestures we're meant to
        /// observe would never start.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
