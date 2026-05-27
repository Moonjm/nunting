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
