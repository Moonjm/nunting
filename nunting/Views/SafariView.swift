import SwiftUI
import SafariServices

/// Thin `UIViewControllerRepresentable` wrapper around `SFSafariViewController`
/// so SwiftUI code can present web pages inside the app instead of jumping out
/// to Safari.
///
/// Only http/https URLs are valid targets; callers should filter before
/// presenting (`SFSafariViewController.init(url:)` asserts on other schemes).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        // Let the user long-press links inside the web view to open them in
        // the system browser if they want — default is `true` which is fine.
        config.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // SFSafariViewController is immutable after construction — nothing
        // to update here.
    }
}

/// Wrapper that makes a URL `Identifiable` for SwiftUI's `sheet(item:)`.
struct WebBrowserItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}
