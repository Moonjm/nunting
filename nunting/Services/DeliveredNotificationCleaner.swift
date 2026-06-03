import Foundation
import UserNotifications

/// Canonical identity used to match a delivered keyword-alert
/// notification against the post the user is currently viewing.
///
/// Built purely from a post URL — `"{boardID|site}-{postNo}"`, the same
/// shape `DetailOverlayController.present` assigns to a notification-
/// opened post's `id`. Deriving the key from URLs on *both* sides (the
/// viewed post and the stored notification) means the two resolve to the
/// same key no matter which code path constructed each one, and it folds
/// host variants: the alert server emits `m.ppomppu.co.kr/...?id=ppomppu&no=N`
/// while a feed-opened post may carry a `www.`/page-stripped URL, but
/// `Site.detect` maps both to `.ppomppu` and the `id`/`no` query pair is
/// identical, so the keys agree.
///
/// Returns nil when the URL isn't a recognisable post (host not a known
/// site, or no `no` query param) — such notifications are left untouched,
/// the same graceful no-op the app already falls back to today.
enum PostNotificationKey {
    static func make(from url: URL) -> String? {
        guard let site = Site.detect(host: url.host) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let postNo = items.first(where: { $0.name == "no" })?.value,
              !postNo.isEmpty else { return nil }
        let boardID = items.first(where: { $0.name == "id" })?.value ?? ""
        // boardID 비어있으면 site.rawValue fallback — 다른 사이트의 같은
        // postNo끼리 키 충돌 방지(예: ppomppu-123 vs clien-123).
        return "\(boardID.isEmpty ? site.rawValue : boardID)-\(postNo)"
    }
}

/// Minimal projection of a delivered notification — just the fields the
/// matcher needs, so the matching logic stays a pure function testable
/// without `UNUserNotificationCenter`.
struct DeliveredAlert: Equatable {
    let identifier: String
    let urlString: String?
    let alertID: Int?
}

enum DeliveredAlertMatcher {
    /// Delivered notifications whose payload URL resolves to the same
    /// post as `viewedPostURL`. Empty when the viewed URL isn't a
    /// recognisable post (nothing to clear) or none match.
    static func matches(viewedPostURL: URL, in delivered: [DeliveredAlert]) -> [DeliveredAlert] {
        guard let key = PostNotificationKey.make(from: viewedPostURL) else { return [] }
        return delivered.filter { entry in
            guard let urlString = entry.urlString,
                  let url = URL(string: urlString) else { return false }
            return PostNotificationKey.make(from: url) == key
        }
    }
}

/// Clears Notification Center entries — and marks their alert history
/// read — for a post the moment it's viewed, covering every entry point
/// into a post (feed tap, push-banner tap, alert-list tap) through the
/// single `PostDetailView` hook.
///
/// Previously a delivered keyword-alert lingered in Notification Center
/// unless the user tapped the banner itself; opening the post from the
/// in-app alert list or by scrolling the feed left it sitting there.
/// Now any route into the post dismisses the banner and syncs the
/// in-app unread badge.
enum DeliveredNotificationCleaner {
    static func clear(for post: Post) {
        // Cheap early-out: an unrecognisable post URL can't match any
        // delivered alert, so skip the system round-trip on the common
        // case (every non-ppomppu post the user opens).
        guard PostNotificationKey.make(from: post.url) != nil else { return }

        let center = UNUserNotificationCenter.current()
        // The completion runs on a background queue. Safe under the
        // project's Swift 5 config: `removeDeliveredNotifications` is
        // thread-safe and `AlertSubscriptionService.shared` is stateless
        // (only `let` props + URLSession), so the detached Task races
        // nothing. A future Swift 6 / strict-concurrency move would need
        // `AlertSubscriptionService: Sendable` and a hop to the actor.
        center.getDeliveredNotifications { delivered in
            let projected = delivered.map { note -> DeliveredAlert in
                let info = note.request.content.userInfo
                return DeliveredAlert(
                    identifier: note.request.identifier,
                    urlString: info["url"] as? String,
                    // JSON number → NSNumber. 0/누락이면 이력 기록 실패 케이스.
                    alertID: (info["alert_id"] as? NSNumber)?.intValue
                )
            }
            let matches = DeliveredAlertMatcher.matches(viewedPostURL: post.url, in: projected)
            guard !matches.isEmpty else { return }

            center.removeDeliveredNotifications(withIdentifiers: matches.map(\.identifier))

            // Mark each matched alert read so the in-app history badge
            // stays consistent with "viewed = read". Dedup and drop the
            // 0/nil sentinels. Fire-and-forget, mirroring the push-tap
            // path in `NotificationDelegate`.
            let alertIDs = Set(matches.compactMap(\.alertID).filter { $0 > 0 })
            guard !alertIDs.isEmpty else { return }
            Task {
                for id in alertIDs {
                    try? await AlertSubscriptionService.shared.markAlertRead(id: id)
                }
            }
        }
    }
}
