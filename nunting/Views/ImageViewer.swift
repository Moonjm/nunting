import SwiftUI
import UIKit
import SDWebImage

struct ImageViewerItem: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

struct ImageViewer: View {
    let url: URL
    /// Fires the moment the viewer commits a dismiss (X tap or drag-down
    /// past threshold), BEFORE SwiftUI starts animating the cover off.
    /// The host (PostDetailView) raises a full-screen black overlay
    /// during the slide-down so the underlying detail doesn't reveal
    /// progressively under the dismissing cover. See the matching
    /// callback on `InlineVideoPlayer` for the full reasoning.
    var onDismissBegin: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image, isZoomed: $isZoomed)
                    .offset(y: isZoomed ? 0 : dismissOffset)
                    .simultaneousGesture(dismissDrag)
                    .ignoresSafeArea()
            } else if failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                onDismissBegin()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 12)
            .accessibilityLabel("이미지 닫기")
        }
        .statusBarHidden()
        .task(id: url) { await loadImage() }
    }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isZoomed else { return }
                dismissOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed else { return }
                if value.translation.height > 120 || value.predictedEndTranslation.height > 220 {
                    onDismissBegin()
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func loadImage() async {
        image = nil
        failed = false

        // Cap the long edge so ultra-high-DPI devices don't ask the
        // decoder to materialise a ~14k px image and peak memory
        // unnecessarily. 4096 covers every iPhone/iPad retina class
        // with headroom for pinch-to-zoom.
        let maxPixelSize = min(max(2400 * displayScale, 1024), 4096)
        let context: [SDWebImageContextOption: Any] = [
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: maxPixelSize, height: maxPixelSize)),
            // Decode animated WebP/GIF as a *lazy* `SDAnimatedImage` (frames
            // decoded on demand during playback) instead of the default path,
            // which materialises every frame into `UIImage.images` up front —
            // for a 354-frame / 720×1280 짤방 that's ~14s + ~1.2 GB and froze
            // the viewer behind a spinner. The lazy image returns in ~50ms;
            // `SDAnimatedImageView` (below) then plays it within a bounded
            // buffer. Static images are unaffected (single-frame SDAnimatedImage).
            .animatedImageClass: SDAnimatedImage.self,
        ]

        // SDWebImageManager.loadImage handles fetch + decode + memory /
        // disk cache. The `imageThumbnailPixelSize` context derives a
        // separate cache key from the inline-body entry (which decodes
        // at native resolution), so the viewer's thumbnail decode is
        // its own cache namespace — same isolation the legacy
        // `cacheVariant: "viewer"` provided.
        let result: UIImage? = await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: url.atsSafe,
                options: [.retryFailed],
                context: context,
                progress: nil
            ) { uiImage, _, _, _, _, _ in
                continuation.resume(returning: uiImage)
            }
        }

        guard !Task.isCancelled else { return }

        if let result {
            image = result
        } else {
            failed = true
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast

        // `SDAnimatedImageView` (a `UIImageView` subclass) plays a lazy
        // `SDAnimatedImage` frame-by-frame; a plain `UIImageView` would show
        // only its poster frame. `maxBufferSize` caps decoded-frame residency
        // (default 0 = buffer every frame → ~1.2 GB on a 354-frame 짤방).
        let imageView = SDAnimatedImageView()
        imageView.image = image
        imageView.maxBufferSize = 16 * 1024 * 1024
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        // setZoomScale fires scrollViewDidZoom, which resets isZoomed — no
        // need to push a SwiftUI state mutation from inside updateUIView.
        scrollView.setZoomScale(1, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isZoomed = scrollView.zoomScale > 1.01
            centerImage(in: scrollView)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                isZoomed = false
            } else {
                let point = recognizer.location(in: imageView)
                let targetScale = min(scrollView.maximumZoomScale, 2.5)
                let size = CGSize(
                    width: scrollView.bounds.width / targetScale,
                    height: scrollView.bounds.height / targetScale
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
                isZoomed = true
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let bounds = scrollView.bounds.size
            let content = imageView.frame.size
            let horizontal = max(0, (bounds.width - content.width) / 2)
            let vertical = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }
}
